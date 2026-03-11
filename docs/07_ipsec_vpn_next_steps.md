# IPsec Site-to-Site VPN — Next Steps & Verification Guide

**Author:** James Barrett | **Company:** Xinle, LLC  
**Version:** 1.0.0 | **Last Modified:** March 11, 2025

---

## Overview

This guide covers everything required after `01_master_setup.sh` completes to bring the IPsec site-to-site VPN tunnel fully online between your VPS (`rmmx.xinle.biz`) and your home network behind the UDM Pro.

| Side         | Device         | LAN Subnet      | Tunnel Role  |
|--------------|----------------|-----------------|--------------|
| VPS (server) | Ubuntu 24.04   | 172.20.0.0/16   | Listens/Responds |
| Home (client)| UDM Pro        | 10.1.0.0/24     | Initiates    |

---

## Step 1 — Retrieve Your Pre-Shared Key

After `01_master_setup.sh` completes, the auto-generated PSK is printed in the deployment summary and saved on the VPS at:

```bash
sudo cat /etc/ipsec.d/psk.txt
```

Copy this value — you will need it for the UDM Pro configuration in Step 3.

---

## Step 2 — Verify the VPS Side Is Ready

SSH into your VPS and run the following checks:

### 2a. Confirm strongSwan is running
```bash
sudo systemctl status ipsec
sudo ipsec status
```
Expected output: `Security Associations (0 up, 0 connecting)` — this is correct. The VPS is in **listen/respond** mode. The tunnel count will increase once the UDM Pro initiates.

### 2b. Confirm xfrm0 interface exists
```bash
ip link show xfrm0
ip addr show xfrm0
ip route | grep xfrm0
```
Expected output:
```
xfrm0: <...> state UP
    inet 172.20.10.1/32 scope global xfrm0
10.1.0.0/24 dev xfrm0
```

### 2c. Confirm UFW ports are open
```bash
sudo ufw status numbered | grep -E "500|4500"
```
You should see both `500/udp` and `4500/udp` listed as ALLOW.

### 2d. Confirm IP forwarding is active
```bash
sysctl net.ipv4.ip_forward
```
Expected: `net.ipv4.ip_forward = 1`

---

## Step 3 — Configure the UDM Pro

Log in to your UniFi Network application and navigate to:  
**Settings → Networks → Create New Network**

| Field                     | Value                                       |
|---------------------------|---------------------------------------------|
| **Network Type**          | Site-to-Site VPN                            |
| **VPN Type**              | IPsec                                       |
| **Pre-Shared Key**        | *(value from Step 1)*                       |
| **Server Address**        | *(your VPS public IP or `rmmx.xinle.biz`)*  |
| **Local IP**              | *(your UDM Pro WAN IP)*                     |
| **Remote Subnets**        | `172.20.0.0/16`                             |
| **Local Subnets**         | `10.1.0.0/24`                               |
| **IKE Version**           | IKEv2                                       |
| **Encryption**            | AES-256                                     |
| **Hash**                  | SHA-256                                     |
| **DH Group**              | 14 (2048-bit MODP)                          |
| **PFS Group**             | 14 (2048-bit MODP)                          |
| **Key Lifetime**          | 3600 seconds (1 hour)                       |
| **IKE Lifetime**          | 28800 seconds (8 hours)                     |

> **Important:** The UDM Pro **must initiate** the tunnel. The VPS is configured with `auto=add` (listen/respond only). Make sure the UDM Pro network is set to initiate, not respond.

Save the network and apply the configuration.

---

## Step 4 — Verify Tunnel is Up

### On the VPS — Check tunnel status
```bash
sudo ipsec status
```
Expected once UDM Pro initiates:
```
Security Associations (1 up, 0 connecting):
    xinle-s2s[1]: ESTABLISHED ...
    xinle-s2s{1}: INSTALLED, TUNNEL ...
```

### On the VPS — Ping the UDM Pro LAN gateway
```bash
ping -c 4 10.1.0.1
```

### From your home network — Ping a Docker container on the VPS
```bash
# Test NPM (first container to come up)
ping -c 4 172.20.0.x   # Replace with actual container IP
```

To find container IPs:
```bash
# On the VPS
docker network inspect xinle_network | grep -A 4 '"Name"'
```

---

## Step 5 — Test Application Access Over VPN

Once the tunnel is up, Docker services on the VPS are accessible directly from your 10.1.0.0/24 home network using container IPs or via the VPS internal IP `172.20.10.1`:

| Service         | VPN-Direct URL                           |
|-----------------|------------------------------------------|
| NPM Admin       | `http://172.20.10.1:81`                  |
| n8n             | `http://172.20.10.1:5678`               |
| pgAdmin         | Proxied via NPM at rmmx.xinle.biz/pgadmin|
| phpMyAdmin      | Proxied via NPM                          |
| Forgejo         | `https://rmmx.xinle.biz/git`            |

---

## Step 6 — Configure Dead Peer Detection (DPD) Behavior

The VPN is already configured with DPD in the `ipsec.conf` deployed by `05_setup_ipsec_vpn.sh`:

```
dpdaction=restart
dpddelay=30s
dpdtimeout=120s
```

This means if the UDM Pro becomes unreachable for 120 seconds, strongSwan will automatically attempt to restart the connection when the peer comes back. No manual intervention is needed after reboots or internet drops.

---

## Step 7 — Autostart Verification After Reboot

Both services are set to start automatically. To simulate a reboot test:

```bash
sudo systemctl reboot
# After reboot, SSH back in:
sudo systemctl status ipsec
sudo systemctl status xfrm0-interface.service
ip route | grep xfrm0
sudo ipsec status
```

---

## Troubleshooting

### Tunnel not establishing — check strongSwan logs
```bash
sudo journalctl -u ipsec -f
# Or for detailed charon daemon logs:
sudo tail -f /var/log/syslog | grep charon
```

### xfrm0 interface missing after reboot
```bash
sudo systemctl status xfrm0-interface.service
sudo systemctl start xfrm0-interface.service
sudo journalctl -u xfrm0-interface.service --no-pager
```

### Routing issue — traffic not reaching home network
```bash
# Check routing table
ip route show

# Manually re-add route if missing
sudo ip route replace 10.1.0.0/24 dev xfrm0

# Check FORWARD chain
sudo iptables -L FORWARD -n -v | grep xfrm0
```

### UDM Pro side — check UniFi VPN event log
Navigate to: **UniFi Network → Events** and filter for VPN events. Look for IKE negotiation failures which indicate a PSK mismatch or proposal incompatibility.

### Firewall blocking IKE traffic
```bash
# Confirm UFW allows IKE/NAT-T
sudo ufw status verbose | grep -E "500|4500"

# If missing, re-add:
sudo ufw allow 500/udp comment 'IPsec IKE'
sudo ufw allow 4500/udp comment 'IPsec NAT-T'
sudo ufw reload
```

---

## Useful Commands Reference

| Command | Purpose |
|---------|---------|
| `sudo ipsec status` | Show tunnel status and SA count |
| `sudo ipsec statusall` | Full detailed tunnel info |
| `sudo ipsec restart` | Restart strongSwan daemon |
| `sudo ipsec down xinle-s2s` | Manually tear down the tunnel |
| `sudo ipsec up xinle-s2s` | Manually bring up the tunnel |
| `ip route show` | Show routing table including xfrm0 route |
| `ip xfrm state` | Show active XFRM security associations |
| `ip xfrm policy` | Show active XFRM policies |
| `sudo tcpdump -i any esp` | Capture ESP (encrypted tunnel) traffic |
| `sudo tcpdump -n -i any port 500 or port 4500` | Capture IKE negotiation packets |
