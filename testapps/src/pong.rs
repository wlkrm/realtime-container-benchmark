//! Pong application - responds to UDP ping messages with timestamps.
//!
//! This application listens for incoming UDP packets and responds with
//! timing information for latency measurement.

use clap::Parser;
use linux_rt::mman;
use std::net::UdpSocket;
mod cli;

/// Helper function to get monotonic time in nanoseconds
pub fn get_time_ns(clock: linux_rt::clock::ClockId) -> i64 {
    linux_rt::clock::get_time(clock).unwrap().as_nanoseconds()
}

fn main() -> anyhow::Result<()> {
    env_logger::Builder::from_default_env()
        .target(env_logger::Target::Stdout)
        .init();

    let args = cli::Args::parse();
    log::info!("Starting pong app on {}", args.bind_addr);

    // Set CPU affinity and real-time scheduling
    let mut cpu = linux_rt::CpuSet::empty();
    cpu.set(args.cpu);
    let _ = linux_rt::sched::set_affinity(linux_rt::sched::Pid::this(), cpu)
        .inspect_err(|e| println!("Error in cpu {}", e));
    let _ = linux_rt::sched::set_fifo(linux_rt::sched::Pid::this(), args.priority)
        .inspect_err(|e| println!("Error in prio {}", e));
    let _ = mman::mlockall(mman::MmanFlags::MCL_CURRENT | mman::MmanFlags::MCL_FUTURE)
        .inspect_err(|e| println!("Error in memlock {}", e));

    // UDP socket for receiving pings
    let udp_socket = UdpSocket::bind(&args.bind_addr)?;
    log::info!("Pong listening on {}", args.bind_addr);

    let clock = linux_rt::clock::ClockId::ClockMonotonic;

    // Run pong loop
    run_pong_loop(&udp_socket, clock)?;

    Ok(())
}

/// Run the pong response loop
fn run_pong_loop(socket: &UdpSocket, clock: linux_rt::clock::ClockId) -> anyhow::Result<()> {
    let mut recv_buf = [0u8; 2048];

    loop {
        let (len, src) = socket.recv_from(&mut recv_buf)?;
        if len < 8 {
            continue;
        }

        // Record receive time
        let recv_time = get_time_ns(clock);

        // Build reply: ping_send (8) | pong_recv (8) | pong_send (8) - all big-endian
        let mut reply = [0u8; 24];

        // Copy original ping timestamp (already big-endian)
        reply[0..8].copy_from_slice(&recv_buf[..8]);

        // Add pong receive time (big-endian)
        reply[8..16].copy_from_slice(&(recv_time as u64).to_be_bytes());

        // Add pong send time (big-endian)
        let send_time = get_time_ns(clock);
        reply[16..24].copy_from_slice(&(send_time as u64).to_be_bytes());

        // Send reply
        let _ = socket.send_to(&reply, src);
    }
}
