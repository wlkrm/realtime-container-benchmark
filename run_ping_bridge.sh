#!/bin/bash
set -e

# Run the ping benchmark (sender) inside ns1
cargo build --release -p auswertung --bin ping

sudo RUST_LOG=info ip netns exec ns1 ./target/release/ping \
    veth1 \
    10.0.0.1:0 \
    10.0.0.2:9000 \
    100000 \
    1000
