# Xinle RMMX — Post-Install Runbook & Credentials

**Version 4.0.0** | **Author:** James Barrett | **Company:** Xinle, LLC | **Last Modified:** March 2026

---

## Quick Reference: Deploy Command

```bash
curl -fsSL https://raw.githubusercontent.com/XinleSA/rmmx/main/scripts/bootstrap.sh | sudo bash
```

> **v14.0.0:** Automatically detects pre-existing installs and offers a full purge + fresh start. Select **[1] PURGE EVERYTHING** when prompted, then type `CONFIRM`.

---

## Default Credentials

> ⚠ **Change all of these immediately after first login.**

### Nginx Proxy Manager

| Field | Value |
|-------|-------|
| URL | `http://184.105.7.78:81` |
| Email | `admin@example.com` |
| Password | `changeme` |

### NetLock RMM

| Field | Value |
|-------|-------|
| URL | `https://rmm.xinle.biz` |
| First login | Set during first-run wizard (no default) |

### n8n

| Field | Value |
|-------|-------|
| URL | `https://rmmx.xinle.biz/n8n` |
| First login | Set during first-run wizard (no default) |

### Forgejo

| Field | Value |
|-------|-------|
| URL | `https://rmmx.xinle.biz/git` |
| First login | Set during first-run wizard (no default) |

### pgAdmin 4

| Field | Value |
|-------|-------|
| URL | `https://rmmx.xinle.biz/pgadmin/` |
| Email | `admin@xinle.biz` |
| Password | *(PGADMIN_PASSWORD you set during install)* |

### phpMyAdmin

| Field | Value |
|-------|-------|
| URL | `https://rmmx.xinle.biz/pma/` |
| Username | `sar` |
| Password | *(MYSQL_PASSWORD you set during install)* |

### PostgreSQL (direct / DBeaver / pgAdmin)

| Field | Value |
|-------|-------|
| Host (via VPN) | `172.20.x.x` *(docker inspect postgres \| grep IPAddress)* |
| Port | `5432` |
| Username | *(POSTGRES_USER from .env)* |
| Password | *(POSTGRES_PASSWORD from .env)* |
| Databases | `xinle_db`, `n8n`, `forgejo` |

### MySQL (direct / phpMyAdmin)

| Field | Value |
|-------|-------|
| Host (via VPN) | `172.20.x.x` *(docker inspect mysql \| grep IPAddress)* |
| Port | `3306` |
| Root user | `root` / *(MYSQL_ROOT_PASSWORD from .env)* |
| App user | `sar` / *(MYSQL_PASSWORD from .env)* |
| Database | `netlockrmm` |

### Grafana Alloy UI

| Field | Value |
|-------|-------|
| URL | `http://184.105.7.78:12345` |
| Auth | None (no login required) |

---

## Service URLs at a Glance

| Service | Public URL | Internal (Docker) |
|---------|-----------|-------------------|
| Landing page | `https://rmmx.xinle.biz` | — |
| NPM Admin | `http://184.105.7.78:81` | `npm:81` |
| NetLock RMM | `https://rmm.xinle.biz` | `netlockrmm-web:5000` |
| n8n | `https://rmmx.xinle.biz/n8n/` | `n8n:5678` |
| Forgejo | `https://rmmx.xinle.biz/git/` | `forgejo:3000` |
| pgAdmin | `https://rmmx.xinle.biz/pgadmin/` | `pgadmin:80` |
| phpMyAdmin | `https://rmmx.xinle.biz/pma/` | `phpmyadmin:80` |
| Alloy UI | `http://184.105.7.78:12345` | `alloy:12345` |

---

## ✅ Post-Deployment Checklist

Work through these **in order**.

---

### Step 1 — Cloudflare DNS

> Full guide: [`docs/05_cloudflare_dns_guide.md`](./05_cloudflare_dns_guide.md)

1. Log into [Cloudflare Dashboard](https://dash.cloudflare.com/) → `xinle.biz` → **DNS → Records**
2. Create/verify these records:

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `rmmx` | `184.105.7.78` | **DNS Only (Grey)** ← must be grey for SSL |
| A | `@` | `184.105.7.78` | Proxied (Orange) |
| CNAME | `www` | `rmmx.xinle.biz` | Proxied (Orange) |

> The `rmmx` record **must stay DNS Only** until after the SSL cert is issued in Step 3.

---

### Step 2 — Verify All Containers Are Running

```bash
cd /home/ubuntu/xinle-infra
docker compose ps
```

All 10 containers should show `Up`. If any show `Exited`:
```bash
docker compose logs --tail=50 <service-name>
docker compose restart <service-name>
```

---

### Step 3 — Nginx Proxy Manager Setup

> Full guide: [`npm_configs/NPM_SETUP_GUIDE.md`](../npm_configs/NPM_SETUP_GUIDE.md)

**The install script auto-configures NPM** (Stage 12). Verify it worked:

```bash
curl -sf http://127.0.0.1:81/api/nginx/proxy-hosts \
  -H "Authorization: Bearer $(curl -sf -X POST http://127.0.0.1:81/api/tokens \
    -H 'Content-Type: application/json' \
    -d '{"identity":"admin@example.com","secret":"changeme"}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')" \
  | python3 -c 'import sys,json; [print(h["domain_names"]) for h in json.load(sys.stdin)]'
```

#### 3a. Change NPM Default Credentials

1. Open: `http://184.105.7.78:81`
2. Log in: `admin@example.com` / `changeme`
3. **Change email and password immediately** when prompted

#### 3b. Request SSL Certificate

The proxy host for `rmmx.xinle.biz` was auto-created by the install script. Now add SSL:

1. Go to **Hosts → Proxy Hosts**
2. Click **Edit** on `rmmx.xinle.biz`
3. Go to the **SSL tab**
4. SSL Certificate: **Request a new SSL Certificate**
5. Enable: Force SSL, HTTP/2 Support
6. Agree to Let's Encrypt ToS
7. Click **Save** — cert issues in ~30-60 seconds

#### 3c. Switch Cloudflare to Proxied

After SSL is verified at `https://rmmx.xinle.biz`, go to Cloudflare and change the `rmmx` A record to **Proxied (Orange Cloud)**.

---

### Step 4 — IPsec VPN — UDM Pro Configuration

> Full guide: [`docs/06_site_to_site_vpn_guide.md`](./06_site_to_site_vpn_guide.md)
> Next steps: [`docs/07_ipsec_vpn_next_steps.md`](./07_ipsec_vpn_next_steps.md)

#### 4a. Get PSK

```bash
sudo cat /etc/ipsec.d/psk.txt
```

#### 4b. Configure UDM Pro

1. Log in to [UniFi Network Controller](https://ai.xinle.biz/)
2. Go to **Settings → VPN → Site-to-Site VPN → Create New**

| Field | Value |
|-------|-------|
| Name | `Xinle RMMX VPS` |
| VPN Type | IPsec |
| IKE Version | IKEv2 |
| Pre-Shared Key | *(from psk.txt)* |
| Remote Host | `184.105.7.78` |
| Remote Network | `172.20.0.0/16` |
| Local Network | `10.1.0.0/24` |
| Encryption | AES-256 |
| Hash | SHA-256 |
| DH Group | 14 (2048-bit) |
| PFS | Enabled |

3. Click **Save** — UDM Pro initiates tunnel immediately

#### 4c. Verify Tunnel

```bash
sudo ipsec status           # → ESTABLISHED
ip addr show xfrm0          # → 172.20.10.1/32
ip route show | grep 10.1   # → via xfrm0
ping -c 3 10.1.0.1          # → 0% loss
```

---

### Step 5 — Application First-Run

#### NetLock RMM — `https://rmm.xinle.biz`

1. Complete first-run wizard — create admin account
2. **Settings → Server Settings** → set Server Address: `https://rmm.xinle.biz``
3. Save settings
4. **Agents → Install Agent** → select platform → deploy to endpoints

#### n8n — `https://rmmx.xinle.biz/n8n/`

1. Create owner account (name, email, password)
2. Import existing workflows if migrating from another instance
3. Verify webhook base URL is `https://rmmx.xinle.biz/n8n/`

#### Forgejo — `https://rmmx.xinle.biz/git/`

1. Complete initial configuration page
2. **Do not change** database settings (pre-configured via Docker env)
3. Set Application URL: `https://rmmx.xinle.biz/git`
4. Create admin user account → click **Install Forgejo**
5. Mirror the `XinleSA/rmmx` repo locally for offline access

#### pgAdmin — `https://rmmx.xinle.biz/pgadmin/`

1. Log in: `admin@xinle.biz` / *(PGADMIN_PASSWORD from .env)*
2. Right-click **Servers → Register → Server**
3. Connection tab: Host `postgres`, Port `5432`, User/Pass from `.env`
4. Verify databases: `xinle_db`, `n8n`, `forgejo`

#### phpMyAdmin — `https://rmmx.xinle.biz/pma/`

1. Log in: user `sar`, password *(MYSQL_PASSWORD from .env)*
2. Verify `netlockrmm` database is present and populated

---

### Step 6 — Post-Deployment Verification

| Check | Command / URL | Expected |
|-------|--------------|---------|
| All containers up | `docker compose ps` | All `Up` |
| Landing page | `https://rmmx.xinle.biz` | Page loads |
| SSL valid | Browser padlock | Let's Encrypt cert |
| IPsec tunnel | `sudo ipsec status` | `ESTABLISHED` |
| Route to home LAN | `ip route show \| grep 10.1` | via `xfrm0` |
| Ping home gateway | `ping -c 3 10.1.0.1` | 0% loss |
| NetLock RMM | `https://rmm.xinle.biz` | Login page |
| n8n | `https://rmmx.xinle.biz/n8n/` | Login/setup |
| Forgejo | `https://rmmx.xinle.biz/git/` | Git homepage |
| pgAdmin | `https://rmmx.xinle.biz/pgadmin/` | Login page |
| phpMyAdmin | `https://rmmx.xinle.biz/pma/` | Login page |

---

## Useful Commands

```bash
# Container management
cd /home/ubuntu/xinle-infra
docker compose ps                            # Status of all containers
docker compose logs -f <service>             # Follow logs
docker compose restart <service>             # Restart one service
docker compose pull && docker compose up -d  # Update all images

# Re-run installer (detects existing install, offers purge)
curl -fsSL https://raw.githubusercontent.com/XinleSA/rmmx/main/scripts/bootstrap.sh | sudo bash

# IPsec VPN
sudo ipsec status           # Tunnel status
sudo ipsec statusall        # Full tunnel details
sudo ipsec restart          # Restart strongSwan daemon
sudo ipsec down xinle-s2s  # Tear down tunnel
sudo ipsec up xinle-s2s    # Bring up tunnel

# Credentials retrieval
sudo cat /etc/ipsec.d/psk.txt          # IPsec PSK
sudo cat /home/ubuntu/xinle-infra/.env  # All service passwords
docker exec -it postgres psql -U sar -d xinle_db   # psql shell
docker exec -it mysql mysql -u sar -p netlockrmm   # mysql shell

# Firewall status
sudo iptables -L -n -v | grep -E "ACCEPT|DROP|REJECT" | head -20
sudo systemctl status xinle-firewall.service

# Alloy metrics
curl -s http://localhost:12345/-/healthy
curl -s http://localhost:12345/metrics | head -20
```

---

## Key File Locations

| File | Path |
|------|------|
| Docker Compose | `/home/ubuntu/xinle-infra/docker-compose.yml` |
| Environment vars | `/home/ubuntu/xinle-infra/.env` |
| Container data | `/docker_apps/` |
| IPsec config | `/etc/ipsec.conf` |
| IPsec PSK | `/etc/ipsec.d/psk.txt` |
| Alloy config | `/home/ubuntu/xinle-infra/monitoring/alloy-config.alloy` |
| Firewall service | `/etc/systemd/system/xinle-firewall.service` |
| Install logs | `/tmp/xinle-install-*.log` and `error_logs/` in repo |

---

## Additional Documentation

| Document | Description |
|----------|-------------|
| [`docs/05_cloudflare_dns_guide.md`](./05_cloudflare_dns_guide.md) | Cloudflare DNS setup |
| [`docs/06_site_to_site_vpn_guide.md`](./06_site_to_site_vpn_guide.md) | Full IPsec VPN guide |
| [`docs/07_ipsec_vpn_next_steps.md`](./07_ipsec_vpn_next_steps.md) | VPN verification steps |
| [`docs/04_vps_reset_guide.md`](./04_vps_reset_guide.md) | VPS reset and OS reinstall |
| [`npm_configs/NPM_SETUP_GUIDE.md`](../npm_configs/NPM_SETUP_GUIDE.md) | NPM proxy setup |
