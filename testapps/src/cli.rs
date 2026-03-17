use clap::Parser;

/// Real-time test application for cyclic timing and pong tests
#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
pub struct Args {
    /// Target address to send UDP packets (for cyclic mode)
    #[arg(short, long, default_value = "127.0.0.1:8000")]
    pub target_addr: String,

    /// Bind address for receiving UDP packets (for pong mode)
    #[arg(short, long, default_value = "127.0.0.1:9000")]
    pub bind_addr: String,

    /// Unix domain socket path (for UDS pong mode)
    #[arg(short = 'u', long, default_value = "/tmp/isobench_uds_pong.sock")]
    pub uds_path: String,

    /// Interval between cyclic packets in nanoseconds
    #[arg(short, long, default_value_t = 1_000_000)]
    pub interval_ns: i64,

    /// Number of iterations for cyclic mode (0 = infinite)
    #[arg(short = 'n', long, default_value_t = 1000)]
    pub iterations: u64,

    /// CPU core to pin the application to
    #[arg(short, long, default_value_t = 0)]
    pub cpu: usize,

    /// Real-time priority (SCHED_FIFO)
    #[arg(short, long, default_value_t = 90)]
    pub priority: u32,
}
