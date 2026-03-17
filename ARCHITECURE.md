# IsoBench Architecture

This document describes the two benchmark modes and their message formats.

## Network Topology

```
┌─────────────────────────────────────────────────────────────────────┐
│                              HOST                                   │
│                                                                     │
│   ┌──────────────────┐              ┌──────────────────┐            │
│   │   Namespace ns1  │              │   Namespace ns2  │            │
│   │                  │              │                  │            │
│   │  ┌────────────┐  │              │  ┌────────────┐  │            │
│   │  │  cyclic /  │  │              │  │  receiver  │  │            │
│   │  │    ping    │  │              │  │   / pong   │  │            │
│   │  └─────┬──────┘  │              │  └─────┬──────┘  │            │
│   │        │         │              │        │         │            │
│   │   veth1│         │              │        │veth2    │            │
│   │  10.0.0.1        │              │        10.0.0.2  │            │
│   └────────┼─────────┘              └────────┼─────────┘            │
│            │                                 │                      │
│       veth1-br                          veth2-br                    │
│            │                                 │                      │
│            └─────────────┬───────────────────┘                      │
│                          │                                          │
│                     ┌────┴────┐                                     │
│                     │   br0   │                                     │
│                     │ (bridge)│                                     │
│                     └─────────┘                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Benchmark 1: Cyclic Timing

Measures the jitter of a periodic task by comparing planned vs actual wakeup times,
plus network transmission latency.

### Data Flow

```
┌─────────────────────────────────┐       ┌─────────────────────────────────┐
│           cyclic (ns1)          │       │      cyclic_receiver (ns2)      │
│                                 │       │                                 │
│  for each iteration:            │       │  while receiving:               │
│    1. sleep_until(planned)      │       │                                 │
│    2. actual = get_time()       │       │    1. recv_time = get_time()    │
│    3. send_time = get_time()    │  UDP  │    2. parse message             │
│    4. send(message) ──────────────────────> 3. record timestamps          │
│    5. planned += interval       │       │    4. generate plots            │
│                                 │       │                                 │
└─────────────────────────────────┘       └─────────────────────────────────┘
```

### Message Format (24 bytes, Big-Endian)

```
┌────────────────┬────────────────┬────────────────┐
│  Byte 0-7      │  Byte 8-15     │  Byte 16-23    │
├────────────────┼────────────────┼────────────────┤
│ planned_wakeup │ actual_wakeup  │   send_time    │
│    (i64 ns)    │    (i64 ns)    │    (i64 ns)    │
└────────────────┴────────────────┴────────────────┘
```

### Metrics Calculated

```
Timeline:
    planned_wakeup ─────┬───────────────────────────────────────────────────>
                        │
    actual_wakeup  ─────┼──┬────────────────────────────────────────────────>
                        │  │
    send_time      ─────┼──┼──┬─────────────────────────────────────────────>
                        │  │  │
    recv_time      ─────┼──┼──┼───┬─────────────────────────────────────────>
                        │  │  │   │
                        │  │  │   │
                        ▼  ▼  ▼   ▼

    wakeup_latency = actual_wakeup - planned_wakeup    (scheduling jitter)
    message_latency = recv_time - send_time             (network latency)
```

---

## Benchmark 2: Ping-Pong (Round-Trip Latency)

Measures full round-trip latency with timestamps at each hop.

### Data Flow

```
┌─────────────────────────────────┐       ┌─────────────────────────────────┐
│           ping (ns1)            │       │           pong (ns2)            │
│                                 │       │                                 │
│  for each iteration:            │       │  while receiving:               │
│    1. ping_send = get_time()    │       │                                 │
│    2. send(ping_send) ──────────────────────> 1. pong_recv = get_time()   │
│                                 │       │    2. copy ping_send            │
│                       <───────────────────── 3. pong_send = get_time()    │
│    3. ping_recv = get_time()    │       │    4. send(reply)               │
│    4. parse reply timestamps    │       │                                 │
│    5. calculate latencies       │       │                                 │
│                                 │       │                                 │
└─────────────────────────────────┘       └─────────────────────────────────┘
```

### Ping Request (8 bytes, Big-Endian)

```
┌────────────────┐
│  Byte 0-7      │
├────────────────┤
│   ping_send    │
│   (u64 ns)     │
└────────────────┘
```

### Pong Response (24 bytes, Big-Endian)

```
┌────────────────┬────────────────┬────────────────┐
│  Byte 0-7      │  Byte 8-15     │  Byte 16-23    │
├────────────────┼────────────────┼────────────────┤
│   ping_send    │   pong_recv    │   pong_send    │
│   (u64 ns)     │   (u64 ns)     │   (u64 ns)     │
└────────────────┴────────────────┴────────────────┘
```

### Metrics Calculated

```
Timeline:
    ping_send ────┬─────────────────────────────────────────────────────────>
                  │
                  │  outbound (ns1 -> ns2)
                  │  ─────────────────────>
                  │
    pong_recv ────┼─────────────────────┬───────────────────────────────────>
                  │                     │
                  │                     │ remote (processing on pong)
                  │                     │ ────>
                  │                     │
    pong_send ────┼─────────────────────┼──┬────────────────────────────────>
                  │                     │  │
                  │                     │  │ inbound (ns2 -> ns1)
                  │                     │  │ ─────────────────────>
                  │                     │  │
    ping_recv ────┼─────────────────────┼──┼─────────────────────┬──────────>
                  │                     │  │                     │
                  │<────────────────────┼──┼─────────────────────>
                           RTT (round-trip time)


    rtt      = ping_recv - ping_send     (total round-trip)
    outbound = pong_recv - ping_send     (ns1 → ns2)
    remote   = pong_send - pong_recv     (pong processing time)
    inbound  = ping_recv - pong_send     (ns2 → ns1)
```

---

## Usage

### Setup Network Namespaces

```bash
sudo bash scripts/bridge_network.sh
```

### Run Cyclic Benchmark

Terminal 1 (receiver in ns2):

```bash
bash run_cyclic_bridge_auswertung.sh
```

Terminal 2 (sender in ns1):

```bash
bash run_cyclic_bridge.sh
```

### Run Ping-Pong Benchmark

Terminal 1 (pong responder in ns2):

```bash
bash run_pong_bridge.sh
```

Terminal 2 (ping sender in ns1):

```bash
bash run_ping_bridge.sh
```

Or run both together:

```bash
bash run_ping_bridge_auswertung.sh
```

### View Results

```bash
python3 -m http.server
# Open browser to http://localhost:8000
# View generated HTML plots:
#   - veth2_cyclic_timestamps.html
#   - veth2_cyclic_inter_packet_latency.html
#   - veth1_ping_latency.html
#   - veth1_ping_inter_packet.html
```

---

## Real-Time Configuration

Both sender and receiver use:

- `SCHED_FIFO` real-time scheduling (priority 90)
- CPU affinity pinning
- `mlockall()` to prevent page faults
- `CLOCK_MONOTONIC` for timestamps
