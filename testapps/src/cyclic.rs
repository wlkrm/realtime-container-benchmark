//! Cyclic timing application - sends periodic UDP messages with timestamps.
//!
//! This application runs a cyclic loop, sending UDP packets at a fixed interval
//! with timing information (planned time, actual time, iteration count).

use clap::Parser;
use linux_rt::mman;
use std::net::UdpSocket;
mod cli;

/// Helper function to get monotonic time in nanoseconds
pub fn get_time_ns(clock: linux_rt::clock::ClockId) -> i64 {
    linux_rt::clock::get_time(clock).unwrap().as_nanoseconds()
}

/// Sleep until a specific absolute time
pub fn sleep_until_ns(clock: linux_rt::clock::ClockId, time_ns: i64) {
    let ts = linux_rt::TimeSpec::nanoseconds(time_ns);
    linux_rt::clock::nanosleep_absolute(clock, ts).unwrap();
}

fn main() -> anyhow::Result<()> {
    env_logger::Builder::from_default_env()
        .target(env_logger::Target::Stdout)
        .init();

    let args = cli::Args::parse();
    log::info!(
        "Starting cyclic app with interval {}ns, iterations {}",
        args.interval_ns,
        args.iterations
    );

    // Set CPU affinity and real-time scheduling
    let mut cpu = linux_rt::CpuSet::empty();
    cpu.set(args.cpu);
    let _ = linux_rt::sched::set_affinity(linux_rt::sched::Pid::this(), cpu)
        .inspect_err(|e| println!("Error in cpu {}", e));
    let _ = linux_rt::sched::set_fifo(linux_rt::sched::Pid::this(), args.priority)
        .inspect_err(|e| println!("Error in prio {}", e));
    let _ = mman::mlockall(mman::MmanFlags::MCL_CURRENT | mman::MmanFlags::MCL_FUTURE)
        .inspect_err(|e| println!("Error in memlock {}", e));

    // UDP socket for sending timestamps
    let udp_socket = UdpSocket::bind("0.0.0.0:0")?;
    udp_socket.connect(&args.target_addr)?;
    log::info!("Sending to {}", args.target_addr);

    let clock = linux_rt::clock::ClockId::ClockMonotonic;

    // Run cyclic loop
    run_cyclic(&udp_socket, clock, args.interval_ns, args.iterations)?;

    Ok(())
}

/// Run the cyclic timing loop
fn run_cyclic(
    socket: &UdpSocket,
    clock: linux_rt::clock::ClockId,
    interval_ns: i64,
    iterations: u64,
) -> anyhow::Result<()> {
    let start_time = get_time_ns(clock);
    let mut next_wakeup = start_time + interval_ns;

    for i in 0..iterations {
        // Sleep until next planned wakeup
        sleep_until_ns(clock, next_wakeup);

        // Record actual wakeup time
        let actual_time = get_time_ns(clock);

        // Build message: planned (8) | actual_wakeup (8) | send_time (8) - all big-endian
        let mut buffer = [0u8; 24];
        buffer[0..8].copy_from_slice(&(next_wakeup as u64).to_be_bytes());
        buffer[8..16].copy_from_slice(&(actual_time as u64).to_be_bytes());

        // Record send time right before sending
        let send_time = get_time_ns(clock);
        buffer[16..24].copy_from_slice(&(send_time as u64).to_be_bytes());

        // Send UDP message
        let _ = socket.send(&buffer);

        // Calculate next wakeup
        next_wakeup += interval_ns;
    }

    log::info!("Cyclic loop completed after {} iterations", iterations);
    Ok(())
}
