#!/bin/bash
set -e

# Run the pong UDP responder application inside ns2
cargo build --release -p testapps --bin pong

sudo RUST_LOG=info ip netns exec ns2 ./target/release/pong \
    --bind-addr=10.0.0.2:9000 \
    --cpu=0 \
    --priority=90
