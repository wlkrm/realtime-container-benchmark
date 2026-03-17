#!/bin/bash
set -e

# Run the cyclic timing test application inside ns1
cargo build --release -p testapps --bin cyclic

sudo RUST_LOG=info ip netns exec ns1 ./target/release/cyclic \
    --target-addr=10.0.0.2:9000 \
    --interval-ns=1000000 \
    --iterations=1000000 \
    --cpu=0 \
    --priority=90