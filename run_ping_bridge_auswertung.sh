#!/bin/bash
set -e

# Setup network namespaces first
sudo bash scripts/bridge_network.sh

# Build both binaries
cargo build --release -p auswertung --bin ping
cargo build --release -p testapps --bin pong

echo "Starting pong responder in ns2..."
sudo RUST_LOG=info ip netns exec ns2 ./target/release/pong \
    --bind-addr=10.0.0.2:9000 \
    --cpu=1 \
    --priority=90 &
PONG_PID=$!

sleep 1

echo "Starting ping sender in ns1..."
# ping positional args: <iface> <pong_addr> <sample_limit> <cycle_time_us>
sudo RUST_LOG=info ip netns exec ns1 ./target/release/ping \
    veth1 \
    10.0.0.2:9000 \
    100000 \
    1000

# Cleanup
kill $PONG_PID 2>/dev/null || true
