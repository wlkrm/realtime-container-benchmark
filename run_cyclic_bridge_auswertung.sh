#!/bin/bash
sudo bash scripts/bridge_network.sh

cargo build --release -p auswertung --bin cyclic_receiver

# Run auswertung inside ns2 (listening on 10.0.0.2:9000)
sudo RUST_LOG=info ip netns exec ns2 ./target/release/cyclic_receiver \
    veth2 \
    10.0.0.2:9000 \
    100000 \
    1000