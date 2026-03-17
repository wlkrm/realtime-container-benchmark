//! UDS Pong application - responds to Unix domain socket ping messages with timestamps.
//!
//! Like the UDP pong, but communicates over AF_UNIX SOCK_DGRAM for IPC
//! latency measurement without any network stack involvement.

use clap::Parser;
use linux_rt::mman;
use std::os::unix::net::UnixDatagram;
use std::path::Path;
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
    let socket_path = &args.uds_path;
    log::info!("Starting UDS pong on {}", socket_path);

    // Set CPU affinity and real-time scheduling
    let mut cpu = linux_rt::CpuSet::empty();
    cpu.set(args.cpu);
    let _ = linux_rt::sched::set_affinity(linux_rt::sched::Pid::this(), cpu)
        .inspect_err(|e| println!("Error in cpu {}", e));
    let _ = linux_rt::sched::set_fifo(linux_rt::sched::Pid::this(), args.priority)
        .inspect_err(|e| println!("Error in prio {}", e));
    let _ = mman::mlockall(mman::MmanFlags::MCL_CURRENT | mman::MmanFlags::MCL_FUTURE)
        .inspect_err(|e| println!("Error in memlock {}", e));

    // Remove stale socket file if it exists
    if Path::new(socket_path).exists() {
        std::fs::remove_file(socket_path)?;
    }

    let socket = UnixDatagram::bind(socket_path)?;
    log::info!("UDS Pong listening on {}", socket_path);

    let clock = linux_rt::clock::ClockId::ClockMonotonic;

    // Run pong loop
    run_pong_loop(&socket, clock)?;

    Ok(())
}

/// Run the pong response loop over Unix domain socket
fn run_pong_loop(socket: &UnixDatagram, clock: linux_rt::clock::ClockId) -> anyhow::Result<()> {
    let mut recv_buf = [0u8; 2048];

    loop {
        let (len, src_addr) = socket.recv_from(&mut recv_buf)?;
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

        // Send reply back to the sender's bound path
        if let Some(path) = src_addr.as_pathname() {
            let _ = socket.send_to(&reply, path);
        }
    }
}
