//! UDS Ping application - measures IPC latency over Unix domain sockets.
//!
//! Like the UDP ping, but communicates over AF_UNIX SOCK_DGRAM.
//! Records the same 4 timestamps (ping_send, pong_recv, pong_send, ping_recv)
//! for direct comparison with the network-based ping-pong benchmark.
//!
//! Positional args: <uds_pong_path> <sample_limit> <cycle_time_us>
//!
//! Environment variables:
//!   ISOBENCH_PREFIX     - output filename prefix (default: "uds")
//!   ISOBENCH_OUTPUT_DIR - output directory (default: ".")

use linux_rt::mman;
use plotly::common::Mode;
use plotly::{Plot, Scatter};
use std::io;
use std::os::unix::net::UnixDatagram;
use std::sync::mpsc;
use std::thread;

fn parse_u64_be(buf: &[u8]) -> u64 {
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(buf);
    u64::from_be_bytes(bytes)
}

fn write_u64_be(buf: &mut [u8], val: u64) {
    buf.copy_from_slice(&val.to_be_bytes());
}

fn realtime_ns() -> io::Result<u64> {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    let rc = unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok((ts.tv_sec as u64)
        .saturating_mul(1_000_000_000)
        .saturating_add(ts.tv_nsec as u64))
}

/// Message sent on the channel to the writer thread.
struct Snapshot {
    count: usize,
    ping_send: Vec<u64>,
    pong_recv: Vec<u64>,
    pong_send: Vec<u64>,
    ping_recv: Vec<u64>,
}

fn build_series(snap: &Snapshot) -> (Vec<f64>, Vec<f64>, Vec<f64>, Vec<f64>, Vec<f64>) {
    let n = snap.count;
    let ps0 = snap.ping_send[0] as i128;

    let mut x = Vec::with_capacity(n);
    let mut rtt = Vec::with_capacity(n);
    let mut outbound = Vec::with_capacity(n);
    let mut remote = Vec::with_capacity(n);
    let mut inbound = Vec::with_capacity(n);

    for i in 0..n {
        let ps = snap.ping_send[i] as i128;
        let pr_recv = snap.pong_recv[i] as i128;
        let pr_send = snap.pong_send[i] as i128;
        let pi = snap.ping_recv[i] as i128;

        x.push((ps - ps0) as f64 / 1000.0);
        rtt.push((pi - ps) as f64 / 1000.0);
        outbound.push((pr_recv - ps) as f64 / 1000.0);
        remote.push((pr_send - pr_recv) as f64 / 1000.0);
        inbound.push((pi - pr_send) as f64 / 1000.0);
    }

    (x, rtt, outbound, remote, inbound)
}

fn build_inter_packet_series(ping_send: &[u64], count: usize) -> (Vec<f64>, Vec<f64>) {
    if count < 2 {
        return (Vec::new(), Vec::new());
    }
    let mut x = Vec::with_capacity(count - 1);
    let mut deltas = Vec::with_capacity(count - 1);
    for i in 1..count {
        x.push(i as f64);
        let d = ping_send[i].saturating_sub(ping_send[i - 1]);
        deltas.push(d as f64 / 1000.0);
    }
    (x, deltas)
}

fn main() -> io::Result<()> {
    const WRITE_EVERY: usize = 10_000;

    let args: Vec<String> = std::env::args().collect();
    let pong_path = args
        .get(1)
        .map(String::as_str)
        .unwrap_or("/tmp/isobench_uds_pong.sock");
    let sample_limit: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(2000);
    let cycle_time_us: u64 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(1000);

    let cycle_time_ns: u64 = cycle_time_us.saturating_mul(1000);

    let output_prefix = std::env::var("ISOBENCH_PREFIX").unwrap_or_else(|_| "uds".to_string());
    let output_dir = std::env::var("ISOBENCH_OUTPUT_DIR").unwrap_or_else(|_| ".".to_string());
    if output_dir != "." {
        let _ = std::fs::create_dir_all(&output_dir);
    }

    // Bind our own datagram socket to a unique path so pong can reply
    let ping_path = format!("{}.ping.sock", pong_path);
    // Remove stale socket if it exists
    let _ = std::fs::remove_file(&ping_path);
    let socket = UnixDatagram::bind(&ping_path)?;

    println!(
        "UDS Pinging {} (limit {}, cycle {}µs)",
        pong_path, sample_limit, cycle_time_us
    );

    // ── Writer (NRT) thread ────────────────────────────────────────────
    let (tx, rx) = mpsc::channel::<Snapshot>();
    let writer = thread::spawn({
        let prefix = output_prefix;
        let dir = output_dir;
        move || {
            while let Ok(snap) = rx.recv() {
                let count = snap.count;

                let result = std::panic::catch_unwind(|| {
                    let (x, rtt, outbound, remote, inbound) = build_series(&snap);
                    let (inter_x, inter_deltas) = build_inter_packet_series(&snap.ping_send, count);
                    (x, rtt, outbound, remote, inbound, inter_x, inter_deltas)
                });
                let (x, rtt, outbound, remote, inbound, inter_x, inter_deltas) = match result {
                    Ok(v) => v,
                    Err(err) => {
                        eprintln!("Writer panic while building series: {:?}", err);
                        continue;
                    }
                };

                // ── main latency plot ──────────────────────────────────────
                let mut plot = Plot::new();
                plot.add_trace(Scatter::new(x.clone(), rtt).mode(Mode::Lines).name("rtt"));
                plot.add_trace(
                    Scatter::new(x.clone(), outbound)
                        .mode(Mode::Lines)
                        .name("outbound"),
                );
                plot.add_trace(
                    Scatter::new(x.clone(), remote)
                        .mode(Mode::Lines)
                        .name("remote processing"),
                );
                plot.add_trace(Scatter::new(x, inbound).mode(Mode::Lines).name("inbound"));

                let html = plot.to_html();
                if let Err(err) =
                    std::fs::write(format!("{}/{}_uds_latency.html", dir, prefix), html)
                {
                    eprintln!("Failed to write uds_latency.html: {}", err);
                    continue;
                }
                println!(
                    "Wrote {}/{}_uds_latency.html ({} samples)",
                    dir, prefix, count
                );

                // ── inter-packet latency plot ──────────────────────────────
                let mut ip_plot = Plot::new();
                ip_plot.add_trace(
                    Scatter::new(inter_x, inter_deltas)
                        .mode(Mode::Lines)
                        .name("inter_packet_latency"),
                );
                let ip_html = ip_plot.to_html();
                if let Err(err) =
                    std::fs::write(format!("{}/{}_uds_inter_packet.html", dir, prefix), ip_html)
                {
                    eprintln!("Failed to write uds_inter_packet.html: {}", err);
                    continue;
                }
                println!(
                    "Wrote {}/{}_uds_inter_packet.html ({} samples)",
                    dir, prefix, count
                );

                // ── CSV data for benchmark analysis ────────────────────────
                let csv_path = format!("{}/{}_uds_data.csv", dir, prefix);
                let mut csv = String::with_capacity(count * 80);
                csv.push_str("ping_send_ns,pong_recv_ns,pong_send_ns,ping_recv_ns\n");
                for i in 0..count {
                    use std::fmt::Write;
                    let _ = writeln!(
                        csv,
                        "{},{},{},{}",
                        snap.ping_send[i], snap.pong_recv[i], snap.pong_send[i], snap.ping_recv[i]
                    );
                }
                if let Err(err) = std::fs::write(&csv_path, &csv) {
                    eprintln!("Failed to write CSV {}: {}", csv_path, err);
                } else {
                    println!("Wrote {} ({} samples)", csv_path, count);
                }
            }
        }
    });

    // ── Pre-allocate all buffers before going RT ───────────────────────
    let mut ping_send = Vec::with_capacity(sample_limit);
    let mut pong_recv = Vec::with_capacity(sample_limit);
    let mut pong_send = Vec::with_capacity(sample_limit);
    let mut ping_recv = Vec::with_capacity(sample_limit);

    let mut send_buf = [0u8; 32];
    let mut recv_buf = [0u8; 2048];

    // ── Enter RT context ───────────────────────────────────────────────
    let _ = mman::mlockall(mman::MmanFlags::MCL_CURRENT | mman::MmanFlags::MCL_FUTURE)
        .inspect_err(|e| println!("Error in memlock {}", e));
    let mut cpu = linux_rt::CpuSet::empty();
    cpu.set(1);
    let _ = linux_rt::sched::set_affinity(linux_rt::sched::Pid::this(), cpu)
        .inspect_err(|e| println!("Error in cpu {}", e));
    let _ = linux_rt::sched::set_fifo(linux_rt::sched::Pid::this(), 90)
        .inspect_err(|e| println!("Error in prio {}", e));

    // ── RT loop – no allocations past this point ───────────────────────
    let mut _seq: u64 = 0;
    let mut next_wakeup_ns = realtime_ns()? + cycle_time_ns;

    let mut cnt: i32 = 0;
    while ping_send.len() < sample_limit {
        cnt += 1;
        // Sleep until the next cycle boundary
        let ts = libc::timespec {
            tv_sec: (next_wakeup_ns / 1_000_000_000) as i64,
            tv_nsec: (next_wakeup_ns % 1_000_000_000) as i64,
        };
        unsafe {
            libc::clock_nanosleep(
                libc::CLOCK_MONOTONIC,
                libc::TIMER_ABSTIME,
                &ts,
                std::ptr::null_mut(),
            );
        }
        next_wakeup_ns += cycle_time_ns;

        // Stamp & send
        let ts_send = realtime_ns()?;
        write_u64_be(&mut send_buf[0..8], ts_send);

        socket.send_to(&send_buf, pong_path)?;

        // Receive response
        let len = socket.recv(&mut recv_buf)?;
        let ts_recv = realtime_ns()?;

        if len < 24 {
            eprintln!("Short response ({} bytes), skipping", len);
            _seq += 1;
            continue;
        }

        // Parse [ping_send(8) | pong_recv(8) | pong_send(8)] from response
        let echo_send = parse_u64_be(&recv_buf[0..8]);
        let ts_pong_recv = parse_u64_be(&recv_buf[8..16]);
        let ts_pong_send = parse_u64_be(&recv_buf[16..24]);

        if cnt > 10 {
            ping_send.push(echo_send);
            pong_recv.push(ts_pong_recv);
            pong_send.push(ts_pong_send);
            ping_recv.push(ts_recv);
        }
        _seq += 1;

        // Offload snapshot to writer
        if ping_send.len() > 0
            && (ping_send.len() % WRITE_EVERY == 0 || ping_send.len() == sample_limit)
        {
            let snap = Snapshot {
                count: ping_send.len(),
                ping_send: ping_send.clone(),
                pong_recv: pong_recv.clone(),
                pong_send: pong_send.clone(),
                ping_recv: ping_recv.clone(),
            };
            if tx.send(snap).is_err() {
                eprintln!("Writer thread disconnected; skipping plot output.");
            }
        }
    }

    // Clean up our socket file
    let _ = std::fs::remove_file(&ping_path);

    drop(tx);
    if let Err(err) = writer.join() {
        eprintln!("Writer thread panicked: {:?}", err);
    }

    Ok(())
}
