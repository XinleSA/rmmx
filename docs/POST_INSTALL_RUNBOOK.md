# Xinle RMMX: Post-Installation Runbook

**Version 1.2.0** | **Author:** James Barrett | **Company:** Xinle, LLC | **Last Modified:** March 11, 2025

---

## Introduction

This document provides the essential manual steps required to fully configure your Xinle RMMX instance **after** the `01_master_setup.sh` script has completed successfully. Following these steps will enable DNS resolution, activate the secure VPN tunnel, configure public-facing access to all applications, and guide you through the initial setup of each service.

## Prerequisites

- You have a fresh Ubuntu 24.04.4 LTS server.
- You have created and filled in your `.env` file from the template:
  ```bash
  cp .env.example .env
  # Edit .env and fill in all passwords before running setup
  ```
- You have successfully executed the master setup script without it rolling back:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/XinleSA/rmmx/main/scripts/01_master_setup.sh | sudo bash
  ```
- The script has printed the **"DEPLOYMENT COMPLETE — ACTION REQUIRED"** message, which includes the auto-generated Pre-Shared Key (PSK) for the VPN.

---

## Step 1: Cloudflare DNS Configuration

First, you must point your domain name (`rmmx.xinle.biz`) to the server's public IP address. This allows Nginx Proxy Manager to request a valid SSL certificate.

1.  Log in to your [Cloudflare Dashboard](https://dash.cloudflare.com/).
2.  Select your domain (`xinle.biz`).
3.  Navigate to the **DNS** > **Records** section.
4.  Click **Add record** and configure it as follows:

| Field | Value |
| :--- | :--- |
| **Type** | `A` |
| **Name** | `rmmx` |
| **IPv4 address** | `184.105.7.78` |
| **TTL** | Auto |
| **Proxy status** | **DNS only** (Grey Cloud) |

> **IMPORTANT**: The Proxy status **must** be set to "DNS only" initially. This allows Let's Encrypt to verify your domain ownership. You will change this to "Proxied" (Orange Cloud) in a later step after the SSL certificate is successfully issued.

---

## Step 2: UDM Pro IPsec VPN Configuration

Next, configure your UniFi Dream Machine (UDM) Pro to establish the site-to-site VPN tunnel. Use the values that were printed at the end of the installation script.

> **Architecture note**: The **UDM Pro is the initiator** of this tunnel. The VPS listens and responds. This is because the VPS has a static public IP and the UDM Pro's WAN IP may change. The VPS `ipsec.conf` uses `auto=add` (listen) and `right=%any` (accept any peer).

### 2a. UDM Pro Configuration

1.  Log in to your [UniFi Network Controller](https://ai.xinle.biz/).
2.  Go to **Settings** > **Networks**.
3.  Click **Create New Network**.
4.  Select **Site-to-Site VPN** and choose **Manual IPsec**.
5.  Fill in the fields using the information from the script's output:

| UniFi Field | Value |
| :--- | :--- |
| **Name** | `Xinle RMMX VPS` |
| **Pre-Shared Key** | The `PSK` value printed by the script |
| **Server Address** | `184.105.7.78` (VPS public IP) |
| **Remote Subnets** | `172.20.0.0/16` (VPS Docker subnet) |
| **Local Subnets** | `10.1.0.0/24` (UDM Pro LAN) |
| **IKE Version** | `IKEv2` |
| **Encryption** | `AES-256` |
| **Hash** | `SHA-256` |
| **DH Group** | `14 (2048-bit MODP)` |
| **PFS** | Enabled (Group 14) |

6.  Save the configuration. The UDM Pro will initiate the tunnel immediately.

### 2b. Verify the Tunnel on the VPS

SSH into the VPS and run the following commands to confirm the tunnel is established:

```bash
# Check IPsec SA (Security Association) status — should show ESTABLISHED
sudo ipsec status

# Check that the xfrm0 interface is up and has the tunnel IP
ip addr show xfrm0

# Check that the route to the UDM Pro LAN is present
ip route show | grep 10.1.0.0

# Ping the UDM Pro gateway
ping -c 3 10.1.0.1

# Ping a device on the UDM Pro LAN (replace with a real device IP)
ping -c 3 10.1.0.100
```

### 2c. Troubleshooting

If the tunnel does not come up, check the strongSwan log for errors:

```bash
sudo journalctl -u ipsec -f --no-pager
```

Common issues and fixes:

| Symptom | Likely Cause | Fix |
| :--- | :--- | :--- |
| `NO_PROPOSAL_CHOSEN` | IKE/ESP cipher mismatch | Verify AES-256/SHA-256/Group-14 on both sides |
| `AUTHENTICATION_FAILED` | PSK mismatch | Re-check the PSK value on the UDM Pro |
| `TS_UNACCEPTABLE` | Subnet mismatch | Verify Local/Remote subnets match exactly |
| Tunnel up but no ping | Missing route or iptables | Run `ip route show` and `iptables -L FORWARD` on VPS |

---

## Step 3: Nginx Proxy Manager (NPM) Setup

Now, you will configure NPM to route traffic from your domain's subpaths (e.g., `rmmx.xinle.biz/n8n`) to the correct Docker container.

1.  **Access NPM**: Open your browser and navigate to `http://rmmx.xinle.biz:81`.
2.  **Log In**: Use the default administrator credentials:
    *   **Email**: `admin@example.com`
    *   **Password**: `changeme`
    *   You will be forced to change these immediately.
3.  **Create a Proxy Host**:
    *   Go to **Hosts** > **Proxy Hosts**.
    *   Click **Add Proxy Host**.
    *   On the **Details** tab, enter `rmmx.xinle.biz` in the Domain Names field.
    *   Set the **Scheme** to `http`, the **Forward Hostname / IP** to `172.20.0.100`, and the **Forward Port** to `80` (this points to the landing page).
4.  **Configure Locations (Subpaths)**:
    *   Go to the **Locations** tab for the host you just created.
    *   Click **Add Location** and create an entry for each application as defined below. The **Forward Hostname / IP** will be the service name from `docker-compose.yml`, and the port is the service's internal port.

| Path | Forward Hostname / IP | Forward Port |
| :--- | :--- | :--- |
| `/home` | `landing-page` | `80` |
| `/npm` | `npm-app` | `81` |
| `/n8n` | `n8n` | `5678` |
| `/git` | `forgejo` | `3000` |
| `/rmm` | `netlock-rmm` | `7000` |
| `/pgdba` | `pgadmin` | `80` |
| `/dba` | `phpmyadmin` | `80` |

5.  **Request SSL Certificate**:
    *   Go to the **SSL** tab.
    *   In the SSL Certificate dropdown, select **Request a new SSL Certificate**.
    *   Enable **Force SSL** and **HTTP/2 Support**.
    *   Agree to the Let's Encrypt ToS and click **Save**.
    *   NPM will now obtain a certificate. This may take a minute.
6.  **Enable Cloudflare Proxy**: Once you confirm that `https://rmmx.xinle.biz` is working correctly with SSL, go back to your Cloudflare DNS settings and change the proxy status for the `rmmx` record to **Proxied** (Orange Cloud).

---

## Step 4: Application First-Run Configuration

### NetLock RMM (`/rmm`)

1.  Navigate to `https://rmmx.xinle.biz/rmm`.
2.  You will be prompted to create the first administrator account. Use a secure password.
3.  Once logged in, go to **Settings** > **Server Settings** > **Agent Heartbeat**.
4.  Set the **Server Address** to your public domain: `https://rmmx.xinle.biz`.
5.  Save the settings.
6.  To deploy an agent, go to **Agents** > **Install Agent**. This will provide you with installer links and commands for Windows, Linux, and macOS.

### n8n (`/n8n`)

1.  Navigate to `https://rmmx.xinle.biz/n8n`.
2.  You will be prompted to create an owner account. Fill in your details.
3.  You can now start creating automated workflows.

### Forgejo (`/git`)

1.  Navigate to `https://rmmx.xinle.biz/git`.
2.  You will see the initial configuration page.
3.  **Database Settings**: The PostgreSQL database settings are pre-configured via environment variables in Docker Compose. You do not need to change them.
4.  **General Settings**: Set the **Server Domain** to `rmmx.xinle.biz` and the **Application URL** to `https://rmmx.xinle.biz/git`.
5.  **Administrator Account**: Scroll down and create your admin user account.
6.  Click **Install Forgejo**.

### pgAdmin (`/pgdba`) & phpMyAdmin (`/dba`)

These services are ready to use. You just need to connect them to their respective databases.

1.  Navigate to `https://rmmx.xinle.biz/pgdba` (for PostgreSQL) or `https://rmmx.xinle.biz/dba` (for MariaDB).
2.  When adding a new server connection, use the following credentials:

| Database | Hostname (Service Name) | Port | Username | Password |
| :--- | :--- | :--- | :--- | :--- |
| PostgreSQL | `postgres` | `5432` | `sar` | `tb,Xinle2026!` |
| MariaDB | `mariadb` | `3306` | `sar` | `tb,Xinle2026!` |

> **Security Note**: The hostnames (`postgres`, `mariadb`) are the Docker service names. They are only resolvable from within the Docker network (`xinle_network`), which pgAdmin and phpMyAdmin are part of. This is a secure configuration.

---

## IPsec VPN — Detailed Next Steps

For full post-install VPN verification, UDM Pro configuration, and troubleshooting, see the dedicated guide:

📄 [`docs/07_ipsec_vpn_next_steps.md`](./07_ipsec_vpn_next_steps.md)

