# Cloudflare Tunnel Configuration & Installation Guide for `guacamole-node1` (VM 102)

## Overview

This guide provides a complete, step-by-step installation and configuration runbook for exposing **Apache Guacamole on Proxmox `node1` VM 102 (`guacamole-node1`)** securely through a **Cloudflare Tunnel (`cloudflared`)** without opening any inbound firewall ports.

### Current VM 102 Environment Summary

| Property | Value |
|---|---|
| **Proxmox Node / VM ID** | `node1` / VM `102` (`guacamole-node1` / `apache-guacamole-template`) |
| **OS** | Ubuntu 24.04.5 LTS (Noble Numbat) |
| **Management IP (`ens19`)** | `10.2.229.60/24` (Gateway: `10.2.229.1`, Bridge: `vmbr0`) |
| **Lab IP (`ens18`)** | `10.100.0.60/24` (Gateway: `10.100.0.1`, Bridge: `vmbr1`) |
| **Guacamole Compose Path** | `/home/analyst/guacamole/docker-compose.yml` |
| **Caddy Frontend Compose Path** | `/home/analyst/guacamole-frontend/docker-compose.yml` |
| **Local Guacamole Backend** | `http://127.0.0.1:8080/guacamole/` (Container: `guacamole` on `guacamole-net`) |
| **Local Caddy Reverse Proxy** | `https://10.2.229.60:443` (Node 1) & `https://10.2.229.60:8443` (Node 2 proxy to `10.2.229.50`) |
| **Outbound Internet Access** | Working (`ens19` via `10.2.229.1`, DNS `8.8.8.8`, `10.2.196.11`, `10.2.196.12`) |

---

## Architecture Options

Because `cloudflared` initiates outbound-only connections (`TCP/UDP 7844`) to the Cloudflare Edge, no inbound port forwarding or UFW incoming rules are required on VM 102.

```text
Internet Client (Browser)
   │
   │ HTTPS (TLS 1.3 + WebSockets + Cloudflare Access Zero-Trust MFA)
   ▼
Cloudflare Edge Network (guac1.example.com)
   ▲
   │ Outbound QUIC / HTTP2 Tunnel (Port 7844)
   │
node1 VM 102 (10.2.229.60) — cloudflared service / container
   │
   ├──► Option A (Recommended): Via Local Caddy (https://127.0.0.1:443) or Direct Tomcat (http://127.0.0.1:8080)
   │       └──► Node 1 Guacamole (127.0.0.1:8080 -> guacd -> Node 1 Lab VMs)
   │
   └──► Optional Second Hostname (guac2.example.com)
           └──► Node 2 Guacamole (https://10.2.229.50:443 -> Node 2 Lab VMs)
```

---

## Prerequisites

1. **A Cloudflare Account** with an active domain name (e.g., `example.com`) whose nameservers point to Cloudflare.
2. **Cloudflare Zero Trust** enabled on your account (Free tier supports up to 50 users):
   - Navigate to [https://one.dash.cloudflare.com/](https://one.dash.cloudflare.com/)
3. **SSH or Proxmox Guest Agent access** to VM 102 (`ssh analyst@10.2.229.60` or `qm guest exec 102` from `node1`).

---

## Step 1 — Prepare Guacamole & Caddy on VM 102

Before connecting `cloudflared`, update the Guacamole and Caddy configurations on VM 102 so that:
1. Guacamole logs the **real client IP** (`CF-Connecting-IP` / `X-Forwarded-For`) via Tomcat's `RemoteIpValve`.
2. Port `8080` is strictly bound to `127.0.0.1:8080` (not exposed on `0.0.0.0:8080`).
3. Caddy allows requests arriving from `127.0.0.1` (if routing through Caddy so `/` automatically redirects to `/guacamole/`).

### 1.1 Update `/home/analyst/guacamole/docker-compose.yml`

SSH into VM 102:

```bash
ssh analyst@10.2.229.60
```

Back up the existing compose file:

```bash
cd /home/analyst/guacamole
sudo cp -a docker-compose.yml docker-compose.yml.bak-$(date +%F-%H%M%S)
```

Edit `/home/analyst/guacamole/docker-compose.yml` so that `ports` binds to `127.0.0.1:8080:8080` and `REMOTE_IP_VALVE_ENABLED: "true"` is enabled:

```yaml
services:
  guacd:
    image: guacamole/guacd:latest
    container_name: guacd
    restart: unless-stopped
    networks:
      - guacamole-net

  mysql:
    image: mysql:8.0
    container_name: guacamole_mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: your_root_password
      MYSQL_DATABASE: guacamole_db
      MYSQL_USER: guacuser
      MYSQL_PASSWORD: guacpassword
    volumes:
      - ./data/mysql:/var/lib/mysql
      - ./init:/docker-entrypoint-initdb.d
    networks:
      - guacamole-net

  guacamole:
    image: guacamole/guacamole:latest
    container_name: guacamole
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"
    environment:
      GUACD_HOSTNAME: guacd
      MYSQL_HOSTNAME: mysql
      MYSQL_DATABASE: guacamole_db
      MYSQL_USER: guacuser
      MYSQL_PASSWORD: guacpassword
      MYSQL_ENABLED: "true"
      REMOTE_IP_VALVE_ENABLED: "true"
      # Optional: Serve Guacamole at root "/" instead of "/guacamole/"
      # WEBAPP_CONTEXT: "ROOT"
    depends_on:
      - guacd
      - mysql
    networks:
      - guacamole-net

networks:
  guacamole-net:
    driver: bridge
```

Apply the changes:

```bash
cd /home/analyst/guacamole
sudo docker compose up -d
```

### 1.2 Allow Localhost (`127.0.0.1`) in Caddy (So `/` Redirects to `/guacamole/`)

Currently, `/home/analyst/guacamole-frontend/Caddyfile` blocks any IP outside `10.2.228.0/24` and `10.2.229.0/24` with `403 Forbidden`, and only matches `https://10.2.229.60:443`.

If you want `cloudflared` to route through Caddy (giving you automatic `/` -> `/guacamole/` redirect and security headers while keeping internal LAN access working), update `/home/analyst/guacamole-frontend/Caddyfile` to add an HTTP listener on `http://127.0.0.1:8081` dedicated to Cloudflare Tunnel:

```bash
cd /home/analyst/guacamole-frontend
sudo cp -a Caddyfile Caddyfile.bak-$(date +%F-%H%M%S)
```

Update `/home/analyst/guacamole-frontend/Caddyfile`:

```caddyfile
{
    auto_https off
}

# Dedicated local listener for Cloudflare Tunnel (cloudflared)
http://127.0.0.1:8081 {
    @root path /
    redir @root /guacamole/ 302

    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "no-referrer"
    }

    reverse_proxy 127.0.0.1:8080 {
        header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
        header_up X-Forwarded-Proto https
        flush_interval -1
    }

    log {
        output stdout
        format console
    }
}

# Existing LAN HTTPS endpoint for Node 1 Guacamole
https://10.2.229.60:443 {
    tls /etc/caddy/certs/guac.crt /etc/caddy/certs/guac.key

    @denied not remote_ip 10.2.228.0/24 10.2.229.0/24 127.0.0.1/32
    respond @denied "Forbidden" 403

    @root path /
    redir @root /guacamole/ 302

    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "no-referrer"
    }

    reverse_proxy 127.0.0.1:8080

    log {
        output stdout
        format console
    }
}

# Existing LAN HTTPS endpoint for Node 2 Guacamole (VM 108)
https://10.2.229.60:8443 {
    tls /etc/caddy/certs/guac.crt /etc/caddy/certs/guac.key

    @denied not remote_ip 10.2.228.0/24 10.2.229.0/24 127.0.0.1/32
    respond @denied "Forbidden" 403

    @root path /
    redir @root /guacamole/ 302

    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "no-referrer"
    }

    reverse_proxy https://10.2.229.50 {
        transport http {
            tls_insecure_skip_verify
        }
    }

    log {
        output stdout
        format console
    }
}
```

> **Why `flush_interval -1` matters for Guacamole:** Guacamole uses both WebSockets and an HTTP tunnel fallback (`/guacamole/tunnel`). Setting `flush_interval -1` prevents proxy response buffering so remote desktop frames stream with zero lag.

Reload Caddy and verify `127.0.0.1:8081`:

```bash
sudo docker exec guac1_caddy caddy reload --config /etc/caddy/Caddyfile
curl -sI http://127.0.0.1:8081/
curl -sI http://127.0.0.1:8081/guacamole/
```

Expected output:
- `http://127.0.0.1:8081/` returns `HTTP/1.1 302 Found` with `Location: /guacamole/`
- `http://127.0.0.1:8081/guacamole/` returns `HTTP/1.1 200 OK`

---

## Step 2 — Install & Configure Cloudflare Tunnel (`cloudflared`)

You can deploy `cloudflared` using **Method A (Cloudflare Zero Trust Dashboard — Remotely Managed Token)** or **Method B (CLI — Locally Managed `config.yml`)**. Both support running either as a native `systemd` service or inside Docker Compose.

---

### Method A (Recommended): Remotely Managed Tunnel via Cloudflare Zero Trust Dashboard

#### 2A.1 Create the Tunnel in Cloudflare Dashboard

1. Log in to the [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/).
2. In the left sidebar, go to **Networks** -> **Tunnels**.
3. Click **Create a tunnel**.
4. Select **Cloudflared** as the connector type and click **Next**.
5. Name the tunnel: `guacamole-node1-vm102` and click **Save tunnel**.
6. Copy the generated **Tunnel Token** (the long string starting with `eyJhIjoi...`).

#### 2A.2 Install `cloudflared` on VM 102 (Choose Systemd OR Docker)

##### Option 1: Install as a Native Ubuntu Systemd Service (Recommended on VM 102)

Run on VM 102 (`10.2.229.60`):

```bash
# 1. Add Cloudflare GPG key
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

# 2. Add Cloudflare apt repository
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list

# 3. Install cloudflared
sudo apt-get update && sudo apt-get install -y cloudflared

# 4. Verify installation
cloudflared --version
```

Register and start the tunnel service with your token:

```bash
sudo cloudflared service install <YOUR_CLOUDFLARE_TUNNEL_TOKEN>
sudo systemctl enable --now cloudflared
sudo systemctl status cloudflared --no-pager
```

##### Option 2: Run `cloudflared` in Docker Compose Alongside Caddy

Alternatively, add `cloudflared` to `/home/analyst/guacamole-frontend/docker-compose.yml`:

```yaml
services:
  caddy:
    image: caddy:2
    container_name: guac1_caddy
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./certs:/etc/caddy/certs:ro

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: guac1_cloudflared
    restart: unless-stopped
    network_mode: host
    command: tunnel --no-autoupdate run --token ${TUNNEL_TOKEN}
```

Create `/home/analyst/guacamole-frontend/.env`:

```bash
cat << 'EOF' > /home/analyst/guacamole-frontend/.env
TUNNEL_TOKEN=eyJhIjoiYourActualTokenHere...
EOF
chmod 600 /home/analyst/guacamole-frontend/.env
```

Start the container:

```bash
cd /home/analyst/guacamole-frontend
sudo docker compose up -d
sudo docker logs guac1_cloudflared --tail 50
```

#### 2A.3 Configure Public Hostname in Cloudflare Dashboard

In the Cloudflare Zero Trust Dashboard under your `guacamole-node1-vm102` tunnel -> **Public Hostname** tab -> click **Add a public hostname**:

##### Public Hostname 1 — Node 1 Guacamole (VM 102)
- **Subdomain**: `guac1` (or `guac`)
- **Domain**: `yourdomain.com`
- **Path**: *(leave blank)*
- **Service Type**: `HTTP`
- **URL**: `127.0.0.1:8081` *(if using the Caddy local listener from Step 1.2)* **OR** `127.0.0.1:8080` *(if connecting directly to Tomcat)*
- Expand **Additional application settings** -> **HTTP Settings**:
  - **Disable Chunked Encoding**: `Off` (leave default)
  - **HTTP2 connection**: *(Optional)* Enable if you want HTTP/2 between `cloudflared` and edge

##### Public Hostname 2 (Optional) — Node 2 Guacamole (VM 108 via VM 102)
Since VM 102 can reach Node 2's Guacamole (`10.2.229.50`), the same tunnel can also publish Node 2:
- **Subdomain**: `guac2`
- **Domain**: `yourdomain.com`
- **Service Type**: `HTTPS`
- **URL**: `10.2.229.50:443`
- Expand **Additional application settings** -> **TLS**:
  - **No TLS Verify**: **Enabled** *(Required because `10.2.229.50` uses a self-signed certificate)*

Click **Save hostname**. Cloudflare automatically creates the proxied `CNAME` DNS record (`guac1.yourdomain.com` -> `<TUNNEL_ID>.cfargotunnel.com`).

---

### Method B: Locally Managed Tunnel via CLI (`config.yml`)

If you prefer managing the tunnel configuration entirely via files on VM 102 instead of the Zero Trust web UI:

#### 2B.1 Authenticate and Create the Tunnel

```bash
# 1. Authenticate cloudflared with your Cloudflare account (opens a login URL)
cloudflared tunnel login

# 2. Create the tunnel
cloudflared tunnel create guacamole-node1-vm102
```

Note the **Tunnel UUID** (e.g. `a1b2c3d4-e5f6-7890-abcd-ef1234567890`) and credentials file path output by the command.

#### 2B.2 Create `/etc/cloudflared/config.yml`

```bash
sudo mkdir -p /etc/cloudflared
sudo cp ~/.cloudflared/*.json /etc/cloudflared/
sudo cp ~/.cloudflared/cert.pem /etc/cloudflared/
```

Create `/etc/cloudflared/config.yml`:

```yaml
tunnel: <TUNNEL_UUID>
credentials-file: /etc/cloudflared/<TUNNEL_UUID>.json

ingress:
  # Node 1 Guacamole (via Caddy localhost listener on 8081 so / redirects to /guacamole/)
  - hostname: guac1.yourdomain.com
    service: http://127.0.0.1:8081
    originRequest:
      keepAliveTimeout: 90s
      noHappyEyeballs: true

  # Optional: Node 2 Guacamole (VM 108) proxied through VM 102
  - hostname: guac2.yourdomain.com
    service: https://10.2.229.50:443
    originRequest:
      noTLSVerify: true
      keepAliveTimeout: 90s

  # Catch-all rule (required by cloudflared)
  - service: http_status:404
```

#### 2B.3 Route DNS and Start the Service

```bash
# Create CNAME records in Cloudflare DNS automatically
cloudflared tunnel route dns guacamole-node1-vm102 guac1.yourdomain.com
# Optional for Node 2:
# cloudflared tunnel route dns guacamole-node1-vm102 guac2.yourdomain.com

# Install and start the systemd service using /etc/cloudflared/config.yml
sudo cloudflared --config /etc/cloudflared/config.yml service install
sudo systemctl enable --now cloudflared
sudo systemctl status cloudflared --no-pager
```

---

## Step 3 — Cloudflare Domain Settings for Guacamole (Critical)

Apache Guacamole relies heavily on **WebSockets** (`wss://guac1.yourdomain.com/guacamole/websocket-tunnel`) and real-time unbuffered streaming. Verify these settings in your Cloudflare Domain Dashboard (`dash.cloudflare.com` -> select your domain):

1. **Network -> WebSockets**:
   - Ensure **WebSockets** is set to **ON** (enabled by default on Cloudflare).
2. **Speed -> Optimization -> Content Optimization**:
   - Turn **Rocket Loader** **OFF** (or create a Configuration Rule to disable Rocket Loader for `guac1.yourdomain.com/*`), as Rocket Loader can break Guacamole's AngularJS scripts.
3. **Caching -> Cache Rules**:
   - Create a Cache Rule for `Hostname equals guac1.yourdomain.com` -> **Bypass cache** (prevents caching of dynamic Guacamole API/tunnel responses).

---

## Step 4 — Secure with Cloudflare Access (Zero Trust MFA Gate)

> **IMPORTANT SECURITY RECOMMENDATION:** Exposing Apache Guacamole directly to the public internet without a pre-authentication gate exposes the login page to brute-force attacks and potential zero-day vulnerabilities. Put a **Cloudflare Access** policy in front of `guac1.yourdomain.com` so users must authenticate with Email OTP, Google Workspace, Microsoft Entra ID, or GitHub **before** reaching the Guacamole login screen.

1. Open [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/).
2. Go to **Access** -> **Applications** -> **Add an application**.
3. Select **Self-hosted**.
4. Configure Application:
   - **Application name**: `Node1 Guacamole (VM 102)`
   - **Session Duration**: `24 hours` (or `8 hours`)
   - **Application domain**: `guac1.yourdomain.com`
5. Click **Next** to create an Access Policy:
   - **Policy name**: `Authorized Lab Users`
   - **Action**: `Allow`
   - **Include rule**:
     - Selector: `Emails` (or `Emails ending in`)
     - Value: `your-email@example.com` (or `@yourdomain.com`)
6. Click **Next** -> Under **Setup**:
   - Leave **CORS Settings** default.
   - Click **Add application**.

Now any external visitor to `https://guac1.yourdomain.com` is prompted by Cloudflare Access for a One-Time PIN (or SSO login) at the Cloudflare Edge before a single packet reaches VM 102!

---

## Step 5 — Firewall (UFW) & Routing Verification on VM 102

Cloudflare Tunnel requires **outbound** connections to Cloudflare's edge on port `7844` (UDP/QUIC and TCP/HTTP2) and port `443`.

### 5.1 Check UFW Outbound Policy on VM 102

```bash
sudo ufw status verbose
```

Confirm default outgoing policy is `allow (outgoing)`:

```text
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), allow (routed)
```

No new `ALLOW IN` UFW rules are needed because `cloudflared` connects outbound and talks to Caddy/Guacamole over `lo` (`127.0.0.1`).

### 5.2 Verify Outbound Connectivity to Cloudflare Tunnel Edge

```bash
# Test DNS resolution of Cloudflare tunnel endpoints
dig +short region1.v2.argotunnel.com
dig +short region2.v2.argotunnel.com

# Check active cloudflared connections
sudo journalctl -u cloudflared -n 30 --no-pager
```

Look for 4 active connections registered in the logs:

```text
INF Registered tunnel connection connIndex=0 ... protocol=quic
INF Registered tunnel connection connIndex=1 ... protocol=quic
INF Registered tunnel connection connIndex=2 ... protocol=quic
INF Registered tunnel connection connIndex=3 ... protocol=quic
```

> **Note if UDP 7844 (QUIC) is blocked by upstream campus/lab firewall:**
> If `cloudflared` logs show QUIC timeouts (`failed to dial to edge with quic`), force HTTP/2 (TCP) by running `cloudflared` with `--protocol http2` (or adding `protocol: http2` in `/etc/cloudflared/config.yml`).

---

## Step 6 — Verification & End-to-End Testing

### 6.1 Local Health Checks on VM 102

```bash
# 1. Check all Docker containers are up
sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# 2. Check cloudflared service status
sudo systemctl is-active cloudflared

# 3. Test local Caddy tunnel port (8081) and Guacamole backend (8080)
curl -sI http://127.0.0.1:8081/
curl -sI http://127.0.0.1:8080/guacamole/
```

### 6.2 External Client Verification

From an external network (outside the lab LAN):

```bash
curl -sI https://guac1.yourdomain.com/
```

Expected:
- If **Cloudflare Access** is enabled: `HTTP/2 302` redirecting to `https://<your-team>.cloudflareaccess.com/...`
- If **Cloudflare Access** is not enabled: `HTTP/2 302` redirecting to `/guacamole/`

### 6.3 Verify WebSocket Tunnel Inside Browser

1. Open `https://guac1.yourdomain.com` in your browser.
2. Authenticate with Cloudflare Access (if enabled) and log in to Guacamole.
3. Open a VM connection (RDP, VNC, or SSH).
4. Open Browser DevTools (`F12` -> **Network** -> **WS** tab) and verify that `/guacamole/websocket-tunnel` shows status **`101 Switching Protocols`** (confirming WebSockets are active and not falling back to slow HTTP polling).

---

## Troubleshooting

### 1. Error `HTTP 403 Forbidden` When Opening the Tunnel URL
- **Cause**: `cloudflared` is pointing to `https://10.2.229.60:443`, and Caddy's `@denied not remote_ip 10.2.228.0/24 10.2.229.0/24` rule is rejecting `127.0.0.1` or `10.2.229.60`.
- **Fix**: Point `cloudflared` to the dedicated `http://127.0.0.1:8081` Caddy block (or `http://127.0.0.1:8080`), or add `127.0.0.1/32` to the `remote_ip` matcher in `/home/analyst/guacamole-frontend/Caddyfile` and reload Caddy.

### 2. Error `HTTP 404 Not Found` at Root URL `https://guac1.yourdomain.com/`
- **Cause**: `cloudflared` is pointing directly to Tomcat (`http://127.0.0.1:8080`), which serves Guacamole under `/guacamole/` and has nothing at `/`.
- **Fix**: Either:
  - Visit `https://guac1.yourdomain.com/guacamole/`, **or**
  - Point `cloudflared` to `http://127.0.0.1:8081` (Caddy local listener from Step 1.2 which redirects `/` -> `/guacamole/`), **or**
  - Add `WEBAPP_CONTEXT: "ROOT"` to the `guacamole` service in `/home/analyst/guacamole/docker-compose.yml`.

### 3. Error `502 Bad Gateway` from Cloudflare
- **Cause**: Either the `guacamole` container or `guac1_caddy` is stopped, or `cloudflared` is configured with `https://` against an `http://` port.
- **Fix**:
  ```bash
  sudo docker ps
  ss -tlnp | grep -E '8080|8081|443'
  sudo journalctl -u cloudflared -n 50 --no-pager
  ```

### 4. Guacamole Logs In, But Clicking Any VM Connection Disconnects Immediately
- **Cause**: `guacd` is disconnected from `guacamole_guacamole-net` or UFW routed traffic is blocked.
- **Fix**:
  ```bash
  sudo docker exec guacamole getent hosts guacd
  sudo ufw status verbose
  ```
  Ensure `guacd` resolves on `guacamole_guacamole-net` (`172.18.0.x`) and UFW default routed policy is `allow (routed)`.

---

## Rollback Procedure

To completely remove the Cloudflare Tunnel without affecting local LAN access (`https://10.2.229.60/guacamole/`):

```bash
# If installed via systemd:
sudo cloudflared service uninstall
sudo apt-get remove -y cloudflared

# If installed via Docker Compose:
cd /home/analyst/guacamole-frontend
sudo docker compose stop cloudflared
sudo docker compose rm -f cloudflared
```
