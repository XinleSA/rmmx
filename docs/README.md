# Xinle 欣乐 Self-Hosted Infrastructure

**Version 9.0.0** | **Author:** James Barrett | **Company:** Xinle, LLC | **Target OS: Ubuntu 24.04.4 LTS (Noble Numbat)** | **Last Modified:** March 11, 2025

> **[🌐 View Landing Page Preview →](https://xinlesa.github.io/rmmx/)**

This repository contains the complete, automated setup for the Xinle 欣乐 self-hosted infrastructure on a fresh VPS. It includes all scripts, Docker configurations, documentation, and a landing page to deploy and manage a suite of powerful open-source tools.

---

## Table of Contents

1.  [Core Philosophy](#1--core-philosophy)
2.  [What You Get](#2--what-you-get)
3.  [Network Architecture](#3--network-architecture)
4.  [One-Line Deployment](#4--one-line-deployment)
5.  [Monitoring](#5--monitoring)
6.  [Network File Shares](#6--network-file-shares)
7.  [IPsec Site-to-Site VPN](#7--ipsec-site-to-site-vpn)
8.  [Updating the System](#8--updating-the-system)
9.  [IPsec VPN Next Steps](./07_ipsec_vpn_next_steps.md)
9.  [Server Reinstallation](#9--server-reinstallation)
10. [GitHub to Forgejo Migration](#10--github-to-forgejo-migration)

---

## 1. Core Philosophy

-   **Automation First:** The entire stack is deployed from a single master script.
-   **Dockerized:** All services run in isolated Docker containers for portability and easy management.
-   **Secure by Default:** The setup includes a site-to-site IPsec VPN and a reverse proxy with SSL.
-   **Single Source of Truth:** This GitHub repository (`XinleSA/rmmx`) contains all code and documentation.
-   **Self-Updating:** All scripts automatically pull the latest version from this repository before running.

## 2. What You Get

| Service                 | Category                    | Purpose                                             |
| :---------------------- | :-------------------------- | :-------------------------------------------------- |
| **NetLock RMM**         | Remote Monitoring           | Monitor and manage endpoints.                       |
| **n8n**                 | Workflow Automation         | Connect apps and automate tasks.                    |
| **Forgejo**             | Self-Hosted Git             | Manage code repositories, issues, and CI/CD.        |
| **Nginx Proxy Manager** | Reverse Proxy & SSL         | Manage public access and SSL certificates.          |
| **PostgreSQL 16**       | Database                    | Powers n8n and Forgejo.                             |
| **pgAdmin 4**           | Database Admin              | Web UI for managing PostgreSQL.                     |
| **MySQL 8.0**           | Database                    | Powers NetLock RMM.                                 |
| **phpMyAdmin**          | Database Admin              | Web UI for managing MySQL.                          |
| **strongSwan**          | IPsec VPN Server            | Creates a secure tunnel to the AI site.             |
| **Grafana Alloy**       | Metrics Agent               | Collects host and Docker metrics.                   |
| **Landing Page**        | Central Hub                 | A single page with links to all services.           |

## 3. Network Architecture

The entire system is designed for security and ease of access. Public traffic is routed through Cloudflare and Nginx Proxy Manager, while private traffic between the VPS and the AI site is encrypted via an IPsec tunnel.

![Network Overview](diagrams/01_network_overview.png)

## 4. One-Line Deployment

To deploy the entire infrastructure on a fresh **Ubuntu 24.04.4 LTS** server, run the following command as root:

```bash
curl -fsSL https://raw.githubusercontent.com/XinleSA/rmmx/main/scripts/01_master_setup.sh | sudo bash
```

This command will:
1.  Clone this repository to `/home/ubuntu/xinle-infra`.
2.  Create a dedicated system user `sar`.
3.  Install all system dependencies (Docker, Git, IPsec, Grafana Alloy, etc.).
4.  Configure the system (timezone, NTP, network shares).
5.  Start all services via `docker compose up`.
6.  Print the final credentials and VPN configuration details.

## 5. Monitoring

This server uses **Grafana Alloy** to collect and send metrics to your central Grafana instance at `https://fenix.xinle.biz/grafana`.

-   **Host Metrics:** CPU, memory, disk, network I/O (via `prometheus.exporter.unix`).
-   **Docker Metrics:** Container health, CPU/memory usage (via `prometheus.exporter.cadvisor`).

Two official Grafana dashboards are included in the `/monitoring` directory and should be imported into your Grafana instance:

-   `node-exporter-full-dashboard.json` (ID: 1860)
-   `cadvisor-dashboard.json` (ID: 13946)

## 6. Network File Shares

The system comes pre-installed with `nfs-common` and `cifs-utils`, allowing you to mount network shares from other servers. 

**Example fstab entry for an NFS share:**

```
10.1.0.10:/exports/data  /mnt/data  nfs  defaults,auto  0  0
```

**Example fstab entry for a CIFS (Samba) share:**

```
//10.1.0.11/share  /mnt/share  cifs  credentials=/etc/samba/credentials,uid=1001,gid=1001  0  0
```

## 7. IPsec Site-to-Site VPN

A secure IPsec IKEv2 tunnel connects the VPS (`172.20.0.0/16`) to the AI site LAN (`10.1.0.0/24`).

-   **Technology:** strongSwan on the VPS, native Site-to-Site VPN on the UDM Pro.
-   **Encryption:** AES-256 with SHA-256 hash and DH Group 14.

> For full setup instructions, see the [**Site-to-Site VPN Guide**](06_site_to_site_vpn_guide.md).

## 8. Updating the System

The update script manages all system components: Git self-update, Grafana Alloy, and Docker images.

```bash
# Show all options
sudo /home/ubuntu/xinle-infra/scripts/02_update_images.sh --help

# Interactive mode — prompts before each step
sudo /home/ubuntu/xinle-infra/scripts/02_update_images.sh

# Unattended mode — auto-confirms everything (used by cron)
sudo /home/ubuntu/xinle-infra/scripts/02_update_images.sh -y

# Install a daily 2:00 AM Central Time cron job (runs with -y)
sudo /home/ubuntu/xinle-infra/scripts/02_update_images.sh --install-cron
```

The cron job logs all output to `/var/log/xinle-update.log`.

## 9. Server Reinstallation

> **WARNING:** This is a fully destructive action.

```bash
sudo /home/ubuntu/xinle-infra/scripts/04_reinstall_os.sh
```

> For a full walkthrough, see the [**VPS Reset Guide**](04_vps_reset_guide.md).

## 10. GitHub to Forgejo Migration

```bash
sudo /home/ubuntu/xinle-infra/scripts/03_migrate_github_to_forgejo.sh
```
