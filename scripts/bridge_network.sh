#!/bin/bash
set -e

# CONFIG
NS1="ns1"
NS2="ns2"
BRIDGE="br0"
VETH1="veth1"
VETH1_BR="veth1-br"
VETH2="veth2"
VETH2_BR="veth2-br"
IP1="10.0.0.1/24"
IP2="10.0.0.2/24"

# CLEANUP FUNCTION
cleanup() {
    echo "Cleaning up..."
    # Remove iptables rules
    iptables -D FORWARD -m physdev --physdev-in $VETH1_BR -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -m physdev --physdev-out $VETH1_BR -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -m physdev --physdev-in $VETH2_BR -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -m physdev --physdev-out $VETH2_BR -j ACCEPT 2>/dev/null || true
    # Remove network namespaces and devices
    ip netns del $NS1 2>/dev/null || true
    ip netns del $NS2 2>/dev/null || true
    ip link del $BRIDGE 2>/dev/null || true
    ip link del $VETH1 2>/dev/null || true
    ip link del $VETH1_BR 2>/dev/null || true
    ip link del $VETH2 2>/dev/null || true
    ip link del $VETH2_BR 2>/dev/null || true
}

# Clean up existing setup first
cleanup

# Create namespaces
echo "Creating network namespaces..."
ip netns add $NS1
ip netns add $NS2

# Create bridge
echo "Creating bridge..."
ip link add name $BRIDGE type bridge
ip link set $BRIDGE up

# Create veth pairs
echo "Creating veth pairs..."
ip link add $VETH1 type veth peer name $VETH1_BR
ip link add $VETH2 type veth peer name $VETH2_BR

# Assign one end to namespaces
ip link set $VETH1 netns $NS1
ip link set $VETH2 netns $NS2

# Attach other end to bridge
ip link set $VETH1_BR master $BRIDGE
ip link set $VETH2_BR master $BRIDGE
ip link set $VETH1_BR up
ip link set $VETH2_BR up

# Assign IP addresses inside namespaces
ip netns exec $NS1 ip addr add $IP1 dev $VETH1
ip netns exec $NS2 ip addr add $IP2 dev $VETH2

ip netns exec $NS1 ip link set $VETH1 up
ip netns exec $NS2 ip link set $VETH2 up
ip netns exec $NS1 ip link set lo up
ip netns exec $NS2 ip link set lo up

# Add iptables rules to allow bridge traffic (needed when bridge-nf-call-iptables=1)
echo "Adding iptables rules for bridge forwarding..."
iptables -I FORWARD -m physdev --physdev-in $VETH1_BR -j ACCEPT
iptables -I FORWARD -m physdev --physdev-out $VETH1_BR -j ACCEPT
iptables -I FORWARD -m physdev --physdev-in $VETH2_BR -j ACCEPT
iptables -I FORWARD -m physdev --physdev-out $VETH2_BR -j ACCEPT

echo "Network setup complete!"
echo "  NS1 ($NS1): $IP1 on $VETH1"
echo "  NS2 ($NS2): $IP2 on $VETH2"
