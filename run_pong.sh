#!/bin/bash
# Run the pong UDP responder application
RUST_LOG=info cargo rrun --release -p testapps --bin pong -- \
    --bind-addr=127.0.0.1:9000 \
    --cpu=0 \
    --priority=90
