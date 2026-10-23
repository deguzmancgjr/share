# Secure Remote Desktop Access via node1 VM 102 and node2 VM 108

## Purpose

Provide HTTPS access from the authorized client subnet `10.2.228.0/24` to:

- **Option C**: the existing Guacamole stack on node1 VM 102 at
  `https://10.2.229.60/guacamole/`.
- **Option B**: the working Guacamole stack on node2 VM 108, proxied by
  VM 102 at `https://10.2.229.60:8443/guacamole/`.

Both endpoints are protected by a Caddy source-IP allowlist, TLS, and UFW.

## Current Working URLs

| Path | URL | Backend | Use |
|---|---|---|---|
| C | `https://10.2.229.60/guacamole/` | VM 102 local Guacamole `127.0.0.1:8080` | node1-side VM connections |
| B | `https://10.2.229.60:8443/guacamole/` | node2 VM 108 `https://10.2.229.50/guacamole/` | node2-side VM connections |

## Implemented Values

| Item | Value |
|---|---|
| node1 Guacamole VM | `102` (`apache-guacamole-template`) |
| VM 102 management IP | `10.2.229.60/24` on `ens19` |
| VM 102 management gateway | `10.2.229.1` |
| VM 102 lab IP | `10.100.0.60/24` on `ens18` |
| VM 102 lab gateway | `10.100.0.1` |
| VM 102 management MAC | `BC:24:11:81:CD:9E` (`vmbr0`) |
| VM 102 lab MAC | `BC:24:11:01:C1:C0` (`vmbr1`) |
| DNS | `10.2.196.11`, `10.2.196.12` |
| DNS search | `ad.phl-imcite.net` |
| node2 Guacamole backend | `https://10.2.229.50/guacamole/` |
| Allowed client subnet | `10.2.228.0/24` |
| Allowed management subnet | `10.2.229.0/24` |
| Certificate CN | `10.2.229.60` |
| Certificate SAN | `IP:10.2.229.60`, `DNS:guac1.ad.phl-imcite.net` |
| Certificate validity | `2026-10-23` to `2029-01-25` |
| Certificate SHA256 | `44:0A:D6:2A:72:A5:F9:56:10:82:20:5B:7D:93:10:7C:6E:E3:84:B6:A5:9B:29:2C:20:BA:AF:F5:7F:4E:66:D8` |
| Caddy config | `/home/analyst/guacamole-frontend/Caddyfile` |
| Caddy cert/key | `/home/analyst/guacamole-frontend/certs/` |
| netplan backup | `/root/50-cloud-init.yaml.bak-2026-10-23-032358` |
| compose backup | `/home/analyst/guacamole/docker-compose.yml.bak-2026-10-23-032510` |

## Architecture

```text
Authorized PC 10.2.228.134
  |
  | HTTPS 443
  v
node1 VM 102 Caddy 10.2.229.60
  |-- /guacamole/  -> 127.0.0.1:8080 (local Guacamole, Option C)
  |
  | HTTPS 8443
  v
node1 VM 102 Caddy 10.2.229.60:8443
  |-- /guacamole/  -> https://10.2.229.50 (node2 VM 108, Option B)
                       |
                       v
                 node2 VMs (RDP/VNC/SSH)
```

## Why Option B Uses Port 8443

VM 102 already has a complete Guacamole stack, so Option C occupies HTTPS
port 443. The node2 proxy uses port 8443 to avoid conflicting with the local
Guacamole site. Caddy has one site block per port, both with the same
certificate and the same source-IP allowlist.

## Reachability Notes

- VM 102 can reach node2 VM 108 management at `10.2.229.50`.
- VM 102 can reach node1-local lab targets `10.100.0.82` and `10.100.0.83`
  on VNC port `5901`.
- VM 102 cannot currently reach node2 lab targets such as `10.100.0.84`,
  `10.100.0.85`, `10.100.0.86`, `10.5.0.x`, or `10.7.0.x`.
- For node2 lab VMs, use the Option B URL. For node1-local targets, use
  Option C.
- Do not expect the local VM 102 Guacamole stack to reach node2 lab VMs
  until the node1/node2 lab L2 path is fixed.

## Step 1 - Verify Both HTTPS Endpoints

From an allowed host, for example node2:

```bash
curl -skI https://10.2.229.60/guacamole/
curl -skI https://10.2.229.60:8443/guacamole/
```

Expected:

```text
HTTP/2 200
```

Root redirects:

```bash
curl -skI https://10.2.229.60/
curl -skI https://10.2.229.60:8443/
```

Expected:

```text
HTTP/2 302
location: /guacamole/
```

Verify the certificate:

```bash
openssl s_client -connect 10.2.229.60:443 \
  -servername 10.2.229.60 </dev/null 2>/dev/null | \
  openssl x509 -noout -subject -dates -ext subjectAltName
```

Expected:

```text
subject=CN = 10.2.229.60
X509v3 Subject Alternative Name:
    IP Address:10.2.229.60, DNS:guac1.ad.phl-imcite.net
```

Verify port exposure:

```bash
nmap -Pn -p 22,80,443,8080,8443 10.2.229.60
```

Expected:

```text
22/tcp    open
80/tcp    closed
443/tcp   open
8080/tcp  closed or filtered
8443/tcp  open
```

`8080` must not be reachable from the network. On VM 102 it is bound to
`127.0.0.1:8080`.

## Step 2 - Test From Your PC

PowerShell:

```powershell
Test-NetConnection 10.2.229.60 -Port 443
Test-NetConnection 10.2.229.60 -Port 8443
curl.exe -k -I https://10.2.229.60/guacamole/
curl.exe -k -I https://10.2.229.60:8443/guacamole/
```

Expected:

```text
TcpTestSucceeded : True
HTTP/2 200
```

Open in the browser:

```text
https://10.2.229.60/guacamole/          (VM 102 local Guacamole)
https://10.2.229.60:8443/guacamole/     (node2 VM 108 via proxy)
```

Use your existing Guacamole credentials for each backend. The two
Guacamole instances have separate databases, users, and connections.

## Step 3 - Trust the Certificate on Windows

Copy the certificate from VM 102:

```bash
scp analyst@10.2.229.60:/home/analyst/guacamole-frontend/certs/guac.crt .
```

PowerShell as Administrator:

```powershell
Import-Certificate -FilePath "$env:USERPROFILE\Downloads\guac.crt" `
  -CertStoreLocation Cert:\LocalMachine\Root
```

Or double-click the certificate and choose:

```text
Install Certificate
-> Local Machine
-> Place all certificates in the following store
-> Trusted Root Certification Authorities
-> Finish
```

Restart the browser after importing.

## Applied VM 102 Configuration

### netplan

File: `/etc/netplan/50-cloud-init.yaml`

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ens18:
      match:
        macaddress: "bc:24:11:01:c1:c0"
      dhcp4: false
      addresses:
        - 10.100.0.60/24
      routes:
        - to: default
          via: 10.100.0.1
          metric: 100
      optional: true
    ens19:
      match:
        macaddress: "bc:24:11:81:cd:9e"
      dhcp4: false
      dhcp6: false
      accept-ra: false
      addresses:
        - 10.2.229.60/24
      routes:
        - to: default
          via: 10.2.229.1
          metric: 0
        - to: 10.2.228.0/24
          via: 10.2.229.1
        - to: 10.2.196.0/24
          via: 10.2.229.1
      nameservers:
        addresses: [10.2.196.11, 10.2.196.12]
        search: [ad.phl-imcite.net]
```

Critical return route:

```text
10.2.228.134 via 10.2.229.1 dev ens19 src 10.2.229.60
```

Verify:

```bash
ip route get 10.2.228.134
ip route get 10.2.229.50
ip route get 10.2.196.11
```

If the client route points at `10.100.0.1` or source `10.100.0.60`, replies
to the PC will be asymmetric and the browser will time out.

### QEMU guest agent

Installed and active:

```bash
systemctl is-active qemu-guest-agent
```

From node1:

```bash
qm agent 102 ping
qm guest exec 102 --timeout 10 -- ip -br a
```

### Local Guacamole binding

`/home/analyst/guacamole/docker-compose.yml` now publishes:

```yaml
ports:
  - "127.0.0.1:8080:8080"
```

Verify:

```bash
ss -tlnp | grep 8080
```

Expected:

```text
LISTEN 127.0.0.1:8080
```

### Caddy compose

`/home/analyst/guacamole-frontend/docker-compose.yml`

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
```

### Caddyfile

`/home/analyst/guacamole-frontend/Caddyfile`

```caddyfile
{
    auto_https off
}

https://10.2.229.60:443 {
    tls /etc/caddy/certs/guac.crt /etc/caddy/certs/guac.key

    @denied not remote_ip 10.2.228.0/24 10.2.229.0/24
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

https://10.2.229.60:8443 {
    tls /etc/caddy/certs/guac.crt /etc/caddy/certs/guac.key

    @denied not remote_ip 10.2.228.0/24 10.2.229.0/24
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

`tls_insecure_skip_verify` is used only for the node2 backend's self-signed
certificate. Remove it after the node2 backend uses a trusted internal CA
certificate.

Apply changes:

```bash
cd /home/analyst/guacamole-frontend
docker compose config --quiet
docker compose up -d
docker logs guac1_caddy --tail 50
```

### UFW on VM 102

Current policy:

```text
Default: deny (incoming), allow (outgoing), allow (routed)
```

Rules:

```text
22/tcp    ALLOW IN  10.2.229.0/24
22/tcp    ALLOW IN  10.2.228.0/24
22/tcp    ALLOW IN  10.100.0.0/24
443/tcp   ALLOW IN  10.2.228.0/24
443/tcp   ALLOW IN  10.2.229.0/24
8443/tcp  ALLOW IN  10.2.228.0/24
8443/tcp  ALLOW IN  10.2.229.0/24
443/udp   ALLOW IN  10.2.228.0/24
443/udp   ALLOW IN  10.2.229.0/24
8443/udp  ALLOW IN  10.2.228.0/24
8443/udp  ALLOW IN  10.2.229.0/24
```

The UDP rules support Caddy HTTP/3. Browsers fall back to TCP if HTTP/3
is unavailable.

`allow routed` is required so Docker bridge traffic from `guacd` can reach
lab targets. Without it, local Guacamole connections can fail even though
the host itself can reach the target.

Verify:

```bash
sudo ufw status verbose
```

## Operations

### Restart the frontend

```bash
cd /home/analyst/guacamole-frontend
docker compose restart
```

### Reload Caddy after a Caddyfile change

```bash
docker exec guac1_caddy caddy reload --config /etc/caddy/Caddyfile
```

### View Caddy logs

```bash
docker logs guac1_caddy --tail 100
```

Look for:

```text
remote_ip
status
Via
```

The Option B responses contain two `Via` values, showing the request passed
through both Caddy instances.

### Check all containers

```bash
docker ps --format '{{.Names}} {{.Status}} {{.Ports}}'
```

Expected:

```text
guac1_caddy        Up
guacamole          Up   127.0.0.1:8080->8080/tcp
guacamole_mysql    Up
guacd              Up (healthy)
```

## Troubleshooting

### Browser times out

On VM 102:

```bash
tcpdump -ni any host 10.2.228.134 and port 443
```

Retry from the PC.

- No packets: campus ACL, wrong IP, or client proxy.
- SYN arrives but no reply: return route or UFW.
- Check:

```bash
ip route get 10.2.228.134
sudo ufw status verbose
```

### HTTP 403 Forbidden

The client IP is not in the Caddy allowlist.

```bash
docker logs guac1_caddy --tail 50 | grep <CLIENT_IP>
```

Update the `remote_ip` matcher and reload Caddy.

### HTTP 502 Bad Gateway on 8443

VM 102 cannot reach the node2 backend.

```bash
curl -skI https://10.2.229.50/guacamole/
ip route get 10.2.229.50
```

Fix node2 VM 108 or the management route first.

### HTTP 502 Bad Gateway on 443

The local Guacamole container is not listening.

```bash
ss -tlnp | grep 8080
docker ps
docker logs guacamole --tail 50
```

### Login works but node1-local VM connections fail

Test from the `guacd` container, not only from the host:

```bash
sudo docker exec guacd nc -z -w2 10.100.0.82 5901
sudo docker exec guacd nc -z -w2 10.100.0.83 5901
```

If the container fails but the host succeeds, check:

```bash
sudo ufw status verbose
```

`Default routed` must be `allow`, or an equivalent route rule must exist.

### Certificate warning

Confirm the URL host matches the certificate:

```text
IP: 10.2.229.60
DNS: guac1.ad.phl-imcite.net
```

Re-import `guac.crt` into Windows Trusted Root.

### DNS name does not resolve

`guac1.ad.phl-imcite.net` has no working A record yet. Use the IP address
until the record is created on `10.2.196.11` / `10.2.196.12`.

## Optional DNS Record

Add an internal DNS A record:

```text
guac1.ad.phl-imcite.net  A  10.2.229.60
```

Then use:

```text
https://guac1.ad.phl-imcite.net/guacamole/
https://guac1.ad.phl-imcite.net:8443/guacamole/
```

## Security Hardening Remaining

1. Enable TOTP/MFA for both Guacamole instances.
2. Replace the self-signed certificate with an internal CA certificate.
3. Replace weak/placeholder Guacamole MySQL passwords on VM 102.
4. Restrict Proxmox `8006` access; do not expose it publicly.
5. Keep Guacamole `8080` bound to `127.0.0.1` on both VMs.
6. Back up the VM 102 Guacamole database and configuration.
7. Review the UFW rules after any management subnet change.

## Rollback

Stop the VM 102 frontend:

```bash
cd /home/analyst/guacamole-frontend
docker compose down
```

Restore the original netplan:

```bash
sudo cp -a /root/50-cloud-init.yaml.bak-2026-10-23-032358 \
           /etc/netplan/50-cloud-init.yaml
sudo netplan generate
sudo netplan apply
```

Restore the original Guacamole compose binding:

```bash
cd /home/analyst/guacamole
sudo cp -a docker-compose.yml.bak-2026-10-23-032510 docker-compose.yml
sudo docker compose up -d
```

Disable UFW if required:

```bash
sudo ufw disable
```

## Validation Checklist

- [x] VM 102 management IP `10.2.229.60/24` is up.
- [x] Return route to `10.2.228.0/24` uses `10.2.229.1`.
- [x] QEMU guest agent is active.
- [x] Local Guacamole is bound to `127.0.0.1:8080`.
- [x] Caddy serves `https://10.2.229.60/guacamole/` with HTTP 200.
- [x] Caddy proxies `https://10.2.229.60:8443/guacamole/` with HTTP 200.
- [x] Port `8080` is not exposed to the network.
- [x] UFW allows only approved subnets.
- [ ] PC `10.2.228.134` browser test completed.
- [ ] Certificate imported into Windows Trusted Root.
- [ ] TOTP/MFA enabled.
