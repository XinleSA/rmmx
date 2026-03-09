#!/bin/bash
# =============================================================================
#  Xinle 欣乐 — IPsec Site-to-Site VPN Setup Script
# =============================================================================
#  Version: 7.0
#
#  Fixes in 7.0 (vs 6.1):
#  1. Enable kernel IP forwarding (net.ipv4.ip_forward=1) — without this the
#     VPS drops all forwarded packets between the tunnel and Docker network.
#  2. Add static route: ip route add 10.1.0.0/24 dev xfrm0 — without this
#     the VPS has no route to the UDM Pro LAN.
#  3. Add iptables FORWARD rules to allow traffic between xfrm0 and the
#     Docker bridge — Docker's default FORWARD policy is DROP.
#  4. Bind the xfrm0 interface to the IPsec SA via if_id in ipsec.conf —
#     without this the XFRM policy and the virtual interface are disconnected.
#  5. Change auto=start to auto=add — the UDM Pro initiates the tunnel,
#     so the VPS should listen (add) not initiate (start). Using start with
#     right=%any is contradictory and causes connection instability.
#  6. Make the route and iptables rules persistent across reboots via the
#     xfrm0-interface.service unit.
# =============================================================================

set -e

# --- Configuration ---
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly AI_SITE_SUBNET="10.1.0.0/24"
readonly DOCKER_SUBNET="172.20.0.0/16"
readonly TUNNEL_IP="172.20.10.1"
readonly XFRM_IF_ID="42"

# --- Helper Functions ---
print_header() { echo -e "\n\e[1;35m--- $1 ---\e[0m"; }
print_info()   { echo -e "\e[1;36m  $1\e[0m"; }

# --- 1. Install strongSwan ---
print_header "Installing strongSwan IPsec VPN"
apt-get update -qq
apt-get install -y strongswan strongswan-starter iptables-persistent

# --- 2. Enable IP Forwarding ---
print_header "Enabling Kernel IP Forwarding"
# Set immediately
sysctl -w net.ipv4.ip_forward=1
# Persist across reboots
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
print_info "IP forwarding enabled."

# --- 3. Generate Pre-Shared Key (PSK) ---
print_header "Generating Pre-Shared Key"
PSK=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
print_info "PSK generated successfully."

# --- 4. Configure IPsec ---
print_header "Configuring IPsec (ipsec.conf & ipsec.secrets)"

# Write ipsec.secrets
cat > /etc/ipsec.secrets << EOF
: PSK "${PSK}"
EOF
chmod 600 /etc/ipsec.secrets

# Write ipsec.conf
# Notes:
#   - leftsubnet is what we advertise to the peer (our Docker network)
#   - rightsubnet is the remote network we want to reach (UDM Pro LAN)
#   - if_id links this connection to the xfrm0 virtual interface
#   - auto=add means we wait for the UDM Pro to initiate (it has a dynamic IP)
#   - mark/if_id must match the xfrm0 interface if_id
cat > /etc/ipsec.conf << EOF
config setup
    charondebug="ike 1, knl 1, cfg 1"
    uniqueids=yes
    strictcrlpolicy=no

conn %default
    ikelifetime=60m
    keylife=20m
    rekeymargin=3m
    keyingtries=%forever
    keyexchange=ikev2
    authby=secret
    dpdaction=restart
    dpddelay=30s
    dpdtimeout=120s

conn xinle-s2s
    left=%defaultroute
    leftid=@rmmx.xinle.biz
    leftsubnet=${DOCKER_SUBNET}
    leftupdown=/etc/ipsec.d/xinle-updown.sh
    right=%any
    rightsubnet=${AI_SITE_SUBNET}
    ike=aes256-sha256-modp2048!
    esp=aes256-sha256!
    if_id_in=${XFRM_IF_ID}
    if_id_out=${XFRM_IF_ID}
    auto=add
EOF

print_info "strongSwan configuration files created."

# --- 5. Create updown Script for Route Management ---
print_header "Creating IPsec updown Script"
mkdir -p /etc/ipsec.d
cat > /etc/ipsec.d/xinle-updown.sh << 'UPDOWN'
#!/bin/bash
# Called by strongSwan when tunnel comes up or goes down
case "$PLUTO_VERB" in
    up-client)
        ip route replace ${AI_SITE_SUBNET} dev xfrm0 2>/dev/null || true
        ;;
    down-client)
        ip route del ${AI_SITE_SUBNET} dev xfrm0 2>/dev/null || true
        ;;
esac
UPDOWN
# Substitute the actual subnet value
sed -i "s|\${AI_SITE_SUBNET}|${AI_SITE_SUBNET}|g" /etc/ipsec.d/xinle-updown.sh
chmod +x /etc/ipsec.d/xinle-updown.sh
print_info "updown script created at /etc/ipsec.d/xinle-updown.sh"

# --- 6. Configure Firewall (UFW + iptables) ---
print_header "Configuring Firewall (UFW + iptables)"

# Open IKE/NAT-T ports
ufw allow 500/udp
ufw allow 4500/udp
print_info "UFW ports 500/udp and 4500/udp opened for IPsec."

# Allow forwarding between xfrm0 (tunnel) and the Docker network
# These rules allow the VPS to act as a router between the two networks
iptables -C FORWARD -i xfrm0 -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -i xfrm0 -j ACCEPT
iptables -C FORWARD -o xfrm0 -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -o xfrm0 -j ACCEPT

# Save iptables rules so they persist across reboots
# (iptables-persistent was installed above)
netfilter-persistent save
print_info "iptables FORWARD rules added and saved."

# --- 7. Create Virtual Tunnel Interface (xfrm0) ---
print_header "Creating Virtual Tunnel Interface (xfrm0)"
cat > /etc/systemd/system/xfrm0-interface.service << EOF
[Unit]
Description=Persistent xfrm0 Tunnel Interface for Xinle IPsec VPN
After=network.target ipsec.service
Wants=ipsec.service

[Service]
Type=oneshot
RemainAfterExit=yes

# Create the xfrm interface bound to if_id ${XFRM_IF_ID}
ExecStart=/sbin/ip link add xfrm0 type xfrm dev eth0 if_id ${XFRM_IF_ID}
ExecStart=/sbin/ip addr add ${TUNNEL_IP}/32 dev xfrm0
ExecStart=/sbin/ip link set xfrm0 up

# Add static route to the remote LAN via the tunnel interface
ExecStart=/sbin/ip route replace ${AI_SITE_SUBNET} dev xfrm0

# Re-apply iptables FORWARD rules (in case they were lost)
ExecStart=/sbin/iptables -C FORWARD -i xfrm0 -j ACCEPT || /sbin/iptables -I FORWARD -i xfrm0 -j ACCEPT
ExecStart=/sbin/iptables -C FORWARD -o xfrm0 -j ACCEPT || /sbin/iptables -I FORWARD -o xfrm0 -j ACCEPT

ExecStop=/sbin/ip route del ${AI_SITE_SUBNET} dev xfrm0
ExecStop=/sbin/ip link del xfrm0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xfrm0-interface.service
systemctl start xfrm0-interface.service
print_info "xfrm0 interface created (if_id=${XFRM_IF_ID}) at ${TUNNEL_IP} and will persist on reboot."

# --- 8. Start & Enable IPsec Service ---
print_header "Starting and Enabling strongSwan Service"
systemctl restart ipsec
systemctl enable ipsec
print_info "strongSwan service started and enabled."

# --- 9. Display UDM Pro Configuration ---
VPS_PUBLIC_IP=$(curl -s ifconfig.me)
print_header "ACTION REQUIRED: UDM Pro Configuration"
echo ""
echo "  Use the following values to configure the Site-to-Site VPN in your UniFi controller:"
echo "  ───────────────────────────────────────────────────────────────────────────"
echo "    Pre-Shared Key : ${PSK}"
echo "    Remote Host    : ${VPS_PUBLIC_IP}"
echo "    Remote Network : ${DOCKER_SUBNET}   (VPS Docker subnet)"
echo "    Local Network  : ${AI_SITE_SUBNET}  (UDM Pro LAN — already set)"
echo "    Tunnel IP      : ${TUNNEL_IP}"
echo "    IKE Version    : IKEv2"
echo "    Encryption     : AES-256"
echo "    Hash           : SHA-256"
echo "    DH Group       : 14 (2048-bit MODP)"
echo "    Initiator      : UDM Pro (the VPS listens and responds)"
echo "  ───────────────────────────────────────────────────────────────────────────"
echo ""
echo "  IMPORTANT: After configuring the UDM Pro, verify the tunnel with:"
echo "    sudo ipsec status"
echo "    ping -c 3 10.1.0.1   # Should reach UDM Pro gateway"
echo ""
