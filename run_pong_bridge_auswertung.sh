#!/bin/bash
set -e

# Run the ping latency measurement application inside ns1
# This sends pings to the pong responder in ns2 and generates latency plots

cargo build --release -p auswertung --bin ping

# Args: interface, target_addr, sample_limit, cycle_time_us
sudo RUST_LOG=info ip netns exec ns1 ./target/release/ping \
    veth1 \
    10.0.0.2:9000 \
    100000 \
    1000
