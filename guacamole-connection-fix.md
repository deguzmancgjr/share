# Guacamole Connection Fix - VM 102 and node2 VM 108

## Purpose

Fix Guacamole connections that fail in the web UI, and document how to
create new connections correctly.

Two separate Guacamole instances are in use:

| URL | Backend | Targets it should be used for |
|---|---|---|
| `https://10.2.229.60/guacamole/` | node1 VM 102 local Guacamole | node1-side lab VMs |
| `https://10.2.229.60:8443/guacamole/` | node2 VM 108 Guacamole (proxied) | node2-side lab VMs |

The two instances have separate databases, users, and connections. A
connection created on one instance does not appear on the other.

## Confirmed Root Cause on VM 102

The VM 102 web UI works and users can log in, but starting a connection
fails with:

```text
java.net.UnknownHostException: guacd: Name or service not known
```

The `guacd` container is attached to the wrong Docker network:

```text
guacd              -> guacamole_default
guacamole          -> guacamole_guacamole-net
guacamole_mysql    -> guacamole_guacamole-net
```

Because `guacd` is not on `guacamole_guacamole-net`, the `guacamole`
container cannot resolve the hostname `guacd`. The connection tunnel is
never created.

This happened when the `guacamole` container was recreated after the
`127.0.0.1:8080` port binding change. The old container could likely reach
both networks; the new container only joined `guacamole_guacamole-net`.

## Confirmed Issues on node2 VM 108

VM 108 has the correct Docker network layout and `guacd` resolves
correctly. Its failures are at the target VM:

```text
VNC: Unable to connect to VNC server
RDP: Authentication failure (invalid credentials?)
```

That means:

- VNC server is not running, is on a different port, or is firewalled.
- RDP username, password, domain, or security mode is wrong.

## Phase 1 - Immediate VM 102 Fix

Log in to VM 102:

```bash
ssh analyst@10.2.229.60
```

Use `sudo` for Docker commands.

### 1.1 Record the current state

```bash
sudo docker network ls

for c in guacamole guacd guacamole_mysql; do
  echo "=== $c ==="
  sudo docker inspect -f '{{json .NetworkSettings.Networks}}' "$c"
done
```

Expected before the fix:

```text
guacd -> guacamole_default
guacamole -> guacamole_guacamole-net
guacamole_mysql -> guacamole_guacamole-net
```

### 1.2 Attach guacd to the correct network immediately

This is a runtime fix that restores service without restarting anything:

```bash
sudo docker network connect guacamole_guacamole-net guacd
```

Verify:

```bash
sudo docker exec guacamole getent hosts guacd
```

Expected:

```text
172.18.0.x      guacd
```

Use the IP shown by `docker network inspect guacamole_guacamole-net` if
you want to confirm it is in the `172.18.0.0/16` subnet.

Check that guacd is now on both networks:

```bash
sudo docker inspect -f '{{json .NetworkSettings.Networks}}' guacd
```

Expected: both `guacamole_default` and `guacamole_guacamole-net`.

### 1.3 Test an existing connection

In the browser:

```text
https://10.2.229.60/guacamole/
```

Log in as `guacadmin`, open an existing connection, and confirm the
session starts.

Check the log:

```bash
sudo docker logs guacamole --since 5m 2>&1 | grep -iE 'guacd|UnknownHost|ERROR'
```

The `UnknownHostException: guacd` error must be gone.

If the session now starts, the runtime fix worked. Continue with 1.4 to
make the fix persistent.

### 1.4 Make the fix persistent

Back up the compose file:

```bash
cd /home/analyst/guacamole
sudo cp -a docker-compose.yml \
  docker-compose.yml.bak-$(date +%F-%H%M%S)
```

Edit the file:

```bash
sudo nano /home/analyst/guacamole/docker-compose.yml
```

Find the `guacd` service:

```yaml
  guacd:
    image: guacamole/guacd:latest
    container_name: guacd
    restart: unless-stopped
```

Add the network lines so it looks like this:

```yaml
  guacd:
    image: guacamole/guacd:latest
    container_name: guacd
    restart: unless-stopped
    networks:
      - guacamole-net
```

The `mysql` and `guacamole` services must already have:

```yaml
    networks:
      - guacamole-net
```

At the bottom of the file, the network definition must remain:

```yaml
networks:
  guacamole-net:
    driver: bridge
```

Validate the Compose file:

```bash
cd /home/analyst/guacamole
sudo docker compose config --quiet
```

Recreate only the affected containers:

```bash
sudo docker compose up -d --force-recreate guacd guacamole
```

This restarts `guacd` and `guacamole`. Active Guacamole sessions will be
disconnected.

### 1.5 Verify the persistent fix

```bash
sudo docker inspect -f '{{json .NetworkSettings.Networks}}' guacd
sudo docker exec guacamole getent hosts guacd
sudo docker exec guacd getent hosts guacamole
sudo docker logs guacamole --since 5m 2>&1 | grep -iE 'guacd|UnknownHost|ERROR'
```

Expected:

- `guacd` is only on `guacamole_guacamole-net` after recreation.
- `guacamole` resolves `guacd`.
- `guacd` resolves `guacamole`.
- No `UnknownHostException`.

Check container health:

```bash
sudo docker ps --format '{{.Names}} {{.Status}} {{.Ports}}'
```

Expected:

```text
guac1_caddy       Up
guacamole         Up   127.0.0.1:8080->8080/tcp
guacamole_mysql   Up
guacd             Up (healthy)
```

### 1.6 If the compose edit is not desired

The runtime `docker network connect` from 1.2 is enough until the
container is recreated. On the next `docker compose up` or container
restart, the fix is lost. Use 1.4 for a permanent fix.

## Phase 2 - Verify Target Reachability

A Guacamole connection can only work if the Guacamole host can reach the
target IP and port, and the target service is running.

### 2.1 VM 102 local targets (node1 side)

Run on VM 102:

```bash
sudo docker exec guacd sh -c '
for ip in 10.100.0.80 10.100.0.81 10.100.0.82 10.100.0.83; do
  printf "%s:5901 " "$ip"
  nc -z -w2 "$ip" 5901 && echo OK || echo FAIL
done
'

sudo docker exec guacd sh -c '
for ip in 10.1.0.2 10.1.0.4 10.1.0.5 10.2.0.4 10.2.0.5; do
  printf "%s:3389 " "$ip"
  nc -z -w2 "$ip" 3389 && echo OK || echo FAIL
done
'
```

Interpretation:

- `OK` means the port is reachable from `guacd`.
- `FAIL` means the target VM is off, the service is not listening, a
  firewall is blocking the port, or the route is missing.

If `nc` is not present in the container, test from the VM 102 host:

```bash
for ip in 10.100.0.80 10.100.0.81 10.100.0.82 10.100.0.83; do
  printf "%s:5901 " "$ip"
  timeout 2 bash -c "</dev/tcp/$ip/5901" 2>/dev/null && echo OK || echo FAIL
done
```

The container test is more accurate because it matches Guacamole's
routing and firewall path.

### 2.2 node2 VM 108 targets

Log in to VM 108:

```bash
ssh analyst@10.2.229.50
```

Run:

```bash
sudo docker exec guacd sh -c '
for ip in 10.100.0.84 10.100.0.85 10.100.0.86; do
  printf "%s:5901 " "$ip"
  nc -z -w2 "$ip" 5901 && echo OK || echo FAIL
done
'

sudo docker exec guacd sh -c '
for ip in 10.5.0.2 10.5.0.4 10.7.0.4; do
  printf "%s:3389 " "$ip"
  nc -z -w2 "$ip" 3389 && echo OK || echo FAIL
done
'

sudo docker exec guacd sh -c '
printf "10.5.0.4:5900 "
nc -z -w2 10.5.0.4 5900 && echo OK || echo FAIL
'
```

### 2.3 Fix target-side failures

If VNC is not listening:

On the target VM:

```bash
ss -tlnp | grep -E ':5900|:5901'
sudo systemctl status vncserver 2>/dev/null || true
```

Start the VNC server for display `:1`:

```bash
vncserver :1
```

Confirm the port:

```bash
ss -tlnp | grep 5901
```

If RDP is reachable but authentication fails:

- Verify the username and password.
- Verify the domain, for example `ncrcom.local` or `nolcom.local`.
- Try the connection with security mode `any`.
- If that fails, try `nla`.
- Confirm the account is allowed to log on remotely.
- Confirm the target Windows firewall allows RDP from the lab subnet.

If `nc` fails on 3389:

On the target Windows VM, verify:

```text
System Properties -> Remote -> Allow remote connections
Windows Firewall -> Remote Desktop rule enabled
```

## Phase 3 - Create Connections in the Web UI

### 3.1 Choose the correct Guacamole instance

Use the instance that can reach the target:

| Target location | URL to use |
|---|---|
| node1 lab VMs (`10.100.0.80-83`, `10.1.0.x`, `10.2.0.x`) | `https://10.2.229.60/guacamole/` |
| node2 lab VMs (`10.100.0.84-86`, `10.5.0.x`, `10.7.0.x`) | `https://10.2.229.60:8443/guacamole/` |

A connection created on VM 102 will not reach a node2 lab VM, and a
connection created on VM 108 will not reach a node1 lab VM, until the
missing cross-node lab L2 path is fixed.

### 3.2 Verify you are an administrator

Log in as `guacadmin`.

The admin account can create connections. The `redteam` account is
currently READ-only.

If `guacadmin` cannot see Settings, check its permissions in the
Guacamole database or use another account with `ADMINISTER`.

### 3.3 Create a new connection

1. Open the correct URL.
2. Log in as `guacadmin`.
3. Open the menu in the top-right corner and choose **Settings**.
4. Select **Connections**.
5. Choose **New Connection**.
6. Enter a clear **Name**, for example `RedTeam4-VNC`.
7. Select the **Protocol**.
8. Enter the **Hostname** and **Port**.
9. Enter the target credentials.
10. Save the connection.
11. Open the connection from the home screen and test it.

### 3.4 RDP parameters

Use these values for a Windows VM:

| Parameter | Value |
|---|---|
| Protocol | `RDP` |
| Hostname | Target IP, for example `10.5.0.2` |
| Port | `3389` |
| Username | Windows account, for example `Administrator` |
| Password | The target account password |
| Domain | The AD domain, for example `ncrcom.local` or `nolcom.local` |
| Security mode | Start with `any`; use `nla` if required |
| Ignore server certificate | Enabled |
| Cert TOFU | Enabled |

If authentication fails, verify the domain and try `DOMAIN\username` as
the username.

### 3.5 VNC parameters

Use these values for a Linux VM running a VNC server:

| Parameter | Value |
|---|---|
| Protocol | `VNC` |
| Hostname | Target IP, for example `10.100.0.84` |
| Port | `5901` for display `:1`; `5900` for display `:0` |
| Username | Optional; usually blank for VNC |
| Password | The VNC password |
| Color depth | Start with `32` or `24` |

If the connection fails, confirm the target is listening:

```bash
ss -tlnp | grep -E ':5900|:5901'
```

### 3.6 SSH parameters

Use these values for a Linux VM:

| Parameter | Value |
|---|---|
| Protocol | `SSH` |
| Hostname | Target IP |
| Port | `22` |
| Username | Linux account |
| Password | Linux account password, or configure a private key |

### 3.7 Grant access to the redteam user

After creating the connection:

1. Open **Settings**.
2. Open **Users**.
3. Select `redteam`.
4. Open **Permissions**.
5. Enable READ access to the new connection.
6. Save.

Alternatively, open the connection's edit dialog and use its
**Permissions** tab if your Guacamole version provides one.

Do not grant `redteam` system-wide administrator access unless the user
must create or manage connections themselves.

## Phase 4 - Test the Connection

### 4.1 From the web UI

1. Log out of `guacadmin`.
2. Log in as `redteam`.
3. Open the connection.
4. Confirm the desktop appears.

### 4.2 From the logs

On VM 102:

```bash
sudo docker logs -f guacamole
```

On VM 108:

```bash
sudo docker logs -f guacamole
```

In another terminal, watch `guacd`:

```bash
sudo docker logs -f guacd
```

Expected when a connection starts:

```text
Creating new client for protocol "rdp" or "vnc"
Connection ID is "..."
User "..." joined connection "..."
```

Expected when it fails:

```text
Unable to connect to VNC server
RDP server closed/refused connection: Authentication failure
UnknownHostException: guacd
```

Match the message to the correct fix:

| Log message | Fix |
|---|---|
| `UnknownHostException: guacd` | Reconnect/recreate `guacd` on `guacamole_guacamole-net` |
| `Unable to connect to VNC server` | Start VNC, fix port or firewall |
| `Authentication failure` | Correct username, password, or domain |
| `Connection refused` | Target service is not listening |
| `No route to host` | Target network path is missing |

## Troubleshooting

### Every connection fails immediately

Check the DNS path inside the `guacamole` container:

```bash
sudo docker exec guacamole getent hosts guacd
sudo docker exec guacamole getent hosts mysql
```

If either fails, inspect the networks:

```bash
sudo docker network inspect guacamole_guacamole-net
```

All three containers must appear under `Containers`.

### Only one connection fails

The problem is specific to that target:

```bash
sudo docker exec guacd nc -z -w2 <TARGET_IP> <TARGET_PORT>
```

Fix the target VM, its service, its firewall, or its route.

### Web UI returns 502 Bad Gateway

On VM 102:

```bash
curl -skI https://10.2.229.60/guacamole/
sudo docker logs guac1_caddy --tail 50
sudo docker logs guacamole --tail 50
```

On VM 108:

```bash
curl -skI https://10.2.229.50/guacamole/
sudo docker logs guacamole_caddy --tail 50
sudo docker logs guacamole --tail 50
```

### Container-to-target traffic is blocked

On VM 102, confirm UFW routing is allowed:

```bash
sudo ufw status verbose
```

Expected:

```text
Default: deny (incoming), allow (outgoing), allow (routed)
```

If routed is denied, Docker bridge traffic from `guacd` to the lab can
fail even though the host itself can reach the target.

### User cannot see Settings or create connections

The account is not an administrator.

Use `guacadmin`, or grant the required permission from an administrator
account. Do not give `redteam` full system administration unless needed.

## Rollback

### Roll back the runtime network change

Only do this if you did not apply the persistent Compose fix:

```bash
sudo docker network disconnect guacamole_guacamole-net guacd
```

This will break connections again. It is listed only for completeness.

### Roll back the Compose change

```bash
cd /home/analyst/guacamole
ls -1 docker-compose.yml.bak-*
sudo cp -a docker-compose.yml.bak-YYYY-MM-DD-HHMMSS docker-compose.yml
sudo docker compose config --quiet
sudo docker compose up -d --force-recreate guacd guacamole
```

Replace `YYYY-MM-DD-HHMMSS` with the actual backup suffix.

### Verify rollback

```bash
sudo docker inspect -f '{{json .NetworkSettings.Networks}}' guacd
sudo docker logs guacamole --since 5m 2>&1 | tail -50
```

## Validation Checklist

- [ ] `guacd` is attached to `guacamole_guacamole-net`.
- [ ] `guacamole` can resolve `guacd`.
- [ ] `guacd` can resolve `guacamole`.
- [ ] `UnknownHostException: guacd` no longer appears.
- [ ] Existing VM 102 connection starts successfully.
- [ ] Target ports respond from the correct `guacd` container.
- [ ] New connection is created on the correct Guacamole instance.
- [ ] `redteam` has READ permission to the new connection.
- [ ] Connection is tested from the browser.
- [ ] Compose file backup exists.
