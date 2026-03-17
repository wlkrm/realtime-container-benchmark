#!/bin/bash
# Run the cyclic timing test application
RUST_LOG=info cargo rrun --release -p testapps --bin cyclic -- \
    --target-addr=127.0.0.1:9000 \
    --interval-ns=1000000 \
    --iterations=1000000 \
    --cpu=0 \
    --priority=90