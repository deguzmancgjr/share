# RedTeam Lab VMs - Access, Configure, and Publish in Guacamole

## 1. Purpose and scope

This runbook explains how to:

1. Access the RedTeam Kali VMs on Proxmox `node1` and `node2`.
2. Configure a persistent VNC service on each VM.
3. Add or repair the RedTeam connections in the two Guacamole instances:
   - `guacamole-node1` = node1 VM `102` at `10.2.229.60`
   - `guacamole-node2` = node2 VM `108` at `10.2.229.50`
4. Validate access end to end.
5. Roll back safely if needed.

The RedTeam VMs are Kali Linux, user `kali`, with TightVNC (`vncserver`)
and XFCE already installed. The existing Guacamole connections expect
VNC on port `5901` (display `:1`).

## 2. Environment and current state

### 2.1 Proxmox and Guacamole endpoints

| Item | Value |
|---|---|
| node1 Proxmox | `10.2.229.9` (`https://10.2.229.9:8006`) |
| node2 Proxmox | `10.2.229.10` (`https://10.2.229.10:8006`) |
| Guacamole VM node1 | VM `102`, `guacamole-node1`, `10.2.229.60` |
| Guacamole VM node2 | VM `108`, `guacamole-node2`, `10.2.229.50` |
| node1 lab bridge | `vmbr1`, subnet `10.100.0.0/24`, gateway `10.100.0.1` |
| node2 lab bridge | `vmbr1`, subnet `10.100.0.0/24`, gateway `10.100.0.1` |
| node1 Guac URL | `https://10.2.229.60/guacamole/` |
| node1 proxy to node2 | `https://10.2.229.60:8443/guacamole/` |
| node2 Guac URL | `https://10.2.229.50/guacamole/` |
| Allowed client subnet | `10.2.228.0/24` |
| Allowed management subnet | `10.2.229.0/24` |

`node1` and `node2` have **separate lab L2 segments**, even though both use
`10.100.0.0/24`. This is the most important constraint in this document.
See section 2.4.

### 2.2 RedTeam VM inventory (verified 2026-11-03)

| VM name | Proxmox node | VMID | Lab IP | MAC | Guac instance | Existing conn ID |
|---|---|---:|---|---|---|---:|
| RedTeam0 | node1 | 170 | `10.100.0.80` | `BC:24:11:EF:01:08` | VM 102 | 10 |
| RedTeam1 | node1 | 117 | `10.100.0.81` | `BC:24:11:C6:6A:DE` | VM 102 | 7 |
| RedTeam2 | node1 | 127 | `10.100.0.82` | `BC:24:11:CD:10:83` | VM 102 | 8 |
| RedTeam3 | node1 | 134 | `10.100.0.83` | `BC:24:11:E6:06:F6` | VM 102 | 9 |
| RedTeam4 | node2 | 131 | `10.100.0.84` | `BC:24:11:41:C8:04` | VM 108 | 29 |
| RedTeam5 | node2 | 111 | `10.100.0.85` | `BC:24:11:59:71:56` | VM 108 | 30 |
| RedTeam6 | node2 | 110 | `10.100.0.86` | `BC:24:11:DB:7C:CB` | VM 108 | 11 |
| RedTeam7 | node2 | 201 | `10.100.0.87` | `BC:24:11:ED:72:57` | VM 108 | 31 |
| RedTeam8 | node2 | 221 | `10.100.0.88` | `BC:24:11:FB:23:E8` | VM 108 | 32 |
| RedTeam9 | node2 | 222 | `10.100.0.89` | `BC:24:11:A9:F8:A6` | VM 108 | 33 |
| RedTeam10 | node2 | 223 | `10.100.0.90` | `BC:24:11:70:96:4B` | VM 108 | 34 |
| RedTeam11 | node2 | 224 | `10.100.0.91` | `BC:24:11:BD:BB:F2` | VM 108 | 35 |

Notes:

- VM `201` was a `qmclone` temporary file during preparation. The clone has
  completed and `qm config 201` now shows `name: RedTeam7`, 2 cores, 4 GB,
  32 GB disk, `net0` on `vmbr1`, and `firewall=1`. It is currently stopped.
- All RedTeam VMs are Kali `2026.3` with user `kali`, TightVNC 1.3.10,
  XFCE, and `startxfce4` installed.
- The lab IPs above were confirmed by ARP/MAC matching from VM 102
  (node1) and VM 108 (node2), not guessed from DHCP.

### 2.3 Guacamole connection inventory (verified 2026-11-03)

Node1 VM 102 database:

| Conn ID | Name | Protocol | Hostname | Port | Username |
|---:|---|---|---|---:|---|
| 10 | RedTeam0 | vnc | `10.100.0.80` | 5901 | kali |
| 7 | RedTeam1 | vnc | `10.100.0.81` | 5901 | kali |
| 8 | RedTeam2 | vnc | `10.100.0.82` | 5901 | kali |
| 9 | RedTeam3 | vnc | `10.100.0.83` | 5901 | kali |

Node1 users: `guacadmin` (entity 1), `redteam` (entity 5), `socteam`
(entity 6). The `redteam` user already has full permissions on connections
7-10.

Node2 VM 108 database:

| Conn ID | Name | Protocol | Hostname | Port | Username | Notes |
|---:|---|---|---|---:|---|---|
| 9 | RedTeam4 | vnc | `10.100.0.84` | 5901 | kali | redteam + guacuser READ |
| 10 | RedTeam5 | vnc | `10.100.0.85` | 5901 | kali | redteam + guacuser READ |
| 11 | RedTeam6 | vnc | `10.100.0.86` | 5901 | kali | redteam + guacuser READ |
| 15 | RedTeam0 | vnc | `10.100.0.80` | 5901 | kali | **stale/unreachable from node2** |

Node2 users/groups: `guacadmin` (1), `redteam` (5), `guacuser` (6),
`BT6-DND` group (7), `BT6_User` (8), `BT7-WESCOM` group (9),
`BT7-User` (10).

Connection `15` on node2 points at a node1 lab VM. Node2 cannot reach that
address. Remove it or ignore it; do not use it. Node1 already has a working
RedTeam0 connection (ID 10).

### 2.4 Architecture constraint: do not cross the nodes

Verified on 2026-11-03:

```text
VM 108 (node2) -> 10.100.0.80:3389  UNREACHABLE
VM 102 (node1) -> 10.100.0.84:5901  UNREACHABLE
VM 102 (node1) -> 10.2.229.50:443   OPEN
```

Therefore:

- Publish **node1 RedTeam0-3** only in the **VM 102 Guacamole**.
- Publish **node2 RedTeam4-7** only in the **VM 108 Guacamole**.
- Do not add node1 lab VMs to VM 108 Guacamole, and do not add node2 lab
  VMs to VM 102 Guacamole. They will fail with "No route to host" or
  timeout even though the connection record exists.
- To reach both from one hostname, use VM 102's Caddy:
  - `https://10.2.229.60/guacamole/` -> VM 102 local Guacamole
  - `https://10.2.229.60:8443/guacamole/` -> proxied to VM 108 Guacamole
  These are still two separate Guacamole databases and logins.

### 2.5 Current VNC state

As of 2026-11-03:

- `5901/tcp` is closed on all RedTeam VMs. VNC is **not** enabled at boot.
- RedTeam0 and RedTeam1 (`10.100.0.80`, `.81`) have RDP `3389/tcp` open.
- RedTeam2 and RedTeam3 (`.82`, `.83`) have neither RDP nor VNC open.
- RedTeam4-6 (`.84`-`.86`) have no `22`, `3389`, or `5901` listener.
- During preparation, VNC was started briefly on RedTeam1 (117) and
  RedTeam5 (111) to validate the procedure, then stopped. No persistent
  changes were made.

All existing Guacamole RedTeam connections will fail until the VNC
configuration in sections 5 and 6 is completed.

## 3. Access the Guacamole instances

### 3.1 URLs

From an allowed PC (`10.2.228.0/24` or `10.2.229.0/24`):

| Purpose | URL |
|---|---|
| node1 RedTeam0-3 | `https://10.2.229.60/guacamole/` |
| node2 RedTeam4-7 (direct) | `https://10.2.229.50/guacamole/` |
| node2 RedTeam4-7 (via node1) | `https://10.2.229.60:8443/guacamole/` |

Log in with an account that can see the connections:

- node1: `guacadmin` for administration, `redteam` for daily use.
- node2: `guacadmin` for administration, `redteam` or `guacuser` for
  daily use.

The two instances have separate databases, users, and connections.

### 3.2 Certificate trust

Both Guacamole endpoints use self-signed certificates.

- VM 102 certificate: `/home/analyst/guacamole-frontend/certs/guac.crt`
  (CN/SAN `10.2.229.60`, also `guac1.ad.phl-imcite.net`).
- VM 108 certificate: `/home/analyst/guacamole/certs/guac.crt`
  (CN/SAN `10.2.229.50`, also `guac.ad.phl-imcite.net`).

Copy the certificate to Windows and import it:

```powershell
Import-Certificate -FilePath "$env:USERPROFILE\Downloads\guac.crt" `
  -CertStoreLocation Cert:\LocalMachine\Root
```

Or double-click the certificate:

```text
Install Certificate
-> Local Machine
-> Place all certificates in the following store
-> Trusted Root Certification Authorities
-> Finish
```

Restart the browser. For the `10.2.229.60:8443` proxy, the VM 102
certificate is the one presented.

### 3.3 HTTP 403 Forbidden

Caddy only allows `10.2.228.0/24` and `10.2.229.0/24`. If you get `403`:

```bash
# on the Guacamole VM
docker logs guacamole_caddy --tail 50 | grep <YOUR_CLIENT_IP>
docker logs guac1_caddy --tail 50 | grep <YOUR_CLIENT_IP>
```

Use a client in an allowed subnet, or update the `remote_ip` matcher in the
Caddyfile and reload Caddy. Do not expose `8080`.

## 4. Pre-flight and backups

### 4.1 Confirm VM state

On node1:

```bash
ssh root@10.2.229.9
qm list | grep -i redteam
qm status 170; qm status 117; qm status 127; qm status 134
```

On node2:

```bash
qm list | grep -i redteam
qm status 131; qm status 111; qm status 110; qm status 201
```

All should be `running` except `201` (`RedTeam7`), which is currently
`stopped`.

### 4.2 Take snapshots

On the node that owns the VM:

```bash
qm snapshot 170 pre-redteam-vnc --description "before VNC + Guac changes"
qm snapshot 117 pre-redteam-vnc --description "before VNC + Guac changes"
qm snapshot 127 pre-redteam-vnc --description "before VNC + Guac changes"
qm snapshot 134 pre-redteam-vnc --description "before VNC + Guac changes"
```

```bash
qm snapshot 131 pre-redteam-vnc --description "before VNC + Guac changes"
qm snapshot 111 pre-redteam-vnc --description "before VNC + Guac changes"
qm snapshot 110 pre-redteam-vnc --description "before VNC + Guac changes"
qm snapshot 201 pre-redteam-vnc --description "before VNC + Guac changes"
```

Snapshots are optional but recommended. Remove them after validation:

```bash
qm delsnapshot <vmid> pre-redteam-vnc
```

### 4.3 Back up the Guacamole databases

On VM 102 (`analyst@10.2.229.60`) and VM 108 (`analyst@10.2.229.50`):

```bash
cd /home/analyst/guacamole

cp -a docker-compose.yml docker-compose.yml.bak-$(date +%F-%H%M%S)

docker exec guacamole_mysql sh -c \
  'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" guacamole_db' \
  > guacamole_db-$(date +%F-%H%M%S).sql

ls -lh docker-compose.yml.bak-* guacamole_db-*.sql
```

Do not commit database dumps to git. Guacamole stores connection passwords
in plain text in the database.

### 4.4 Know the database access

Both Guacamole VMs currently use:

```text
database: guacamole_db
user:     guacuser
password: guacpassword
```

These are weak lab credentials. Rotate them later. For administration:

```bash
docker exec -it guacamole_mysql \
  mysql -u guacuser -pguacpassword guacamole_db
```

In this Guacamole schema, user and group names are in
`guacamole_entity` (`type` = `USER` or `USER_GROUP`), not in
`guacamole_user.username`.

## 5. Configure VNC on node1 RedTeam0-3

Repeat this section on VMs `170`, `117`, `127`, and `134`.

### 5.1 Open a console

Use one of:

- Proxmox UI: `https://10.2.229.9:8006` -> VM -> Console.
- `qm guest exec` for VMs that have the QEMU guest agent enabled:
  `117` currently has `agent: 1`. `170`, `127`, and `134` do not.

For VMs without the agent, use the Proxmox console and log in as `kali`.
If the `kali` console password is unknown, see Appendix C.

Optional: enable the guest agent on the other VMs. Inside each VM:

```bash
sudo apt update
sudo apt install -y qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
```

Then, on node1:

```bash
qm set 170 --agent 1
qm set 127 --agent 1
qm set 134 --agent 1
qm reboot 170
qm reboot 127
qm reboot 134
```

After that, `qm guest exec <vmid> ...` works for all four.

### 5.2 Set the VNC password

TightVNC passwords are limited to **8 characters**. A longer password is
silently truncated. The existing VNC password files are 8 bytes (verified
on RedTeam5), and the existing Guacamole entries use `Password12!@`, which
TightVNC truncates to the effective password `Password`.

Pick one 8-character value and use it on every RedTeam VM. Example:

```text
R3dT3am!
```

Inside the VM, as `kali`:

```bash
mkdir -p /home/kali/.vnc
chmod 700 /home/kali/.vnc

# interactive; enter the same 8-character password twice
vncpasswd
```

Or non-interactive (TightVNC filter mode):

```bash
su - kali -c 'printf "R3dT3am!\n" | vncpasswd -f > /home/kali/.vnc/passwd'
chown kali:kali /home/kali/.vnc/passwd
chmod 600 /home/kali/.vnc/passwd
```

Verify:

```bash
stat -c '%s %a %U:%G' /home/kali/.vnc/passwd
# expected: 8 600 kali:kali
```

Do not use `Password12!@` as the VNC password. It is longer than 8
characters and only `Password` is actually used. Keep the Guacamole
password field to the same 8-character value.

### 5.3 Normalize the XFCE startup file

The existing `xstartup` starts XFCE, but it contains a typo
(`xrdp` instead of `xrdb`) and an unnecessary `/etc/vnc/xstartup` exec.
Use a clean file:

```bash
cat > /home/kali/.vnc/xstartup <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
[ -r "$HOME/.Xresources" ] && xrdb "$HOME/.Xresources"
xsetroot -solid grey
vncconfig -iconic &
startxfce4 &
EOF

chown kali:kali /home/kali/.vnc/xstartup
chmod 755 /home/kali/.vnc/xstartup
```

### 5.4 Start VNC and verify the listener

As `kali`:

```bash
# clean up any stale session first
vncserver -kill :1 2>/dev/null || true

vncserver :1 -geometry 1920x1080 -depth 24

ss -tlnp | grep 5901
```

Expected:

```text
LISTEN 0  5  0.0.0.0:5901  0.0.0.0:*  users:(("Xtightvnc",pid=...,fd=3))
```

TightVNC listens on all interfaces by default. Do **not** add
`-localhost no`; that is TigerVNC syntax and will be misread by
TightVNC.

### 5.5 Persist VNC with systemd

Create the unit on each VM:

```bash
sudo tee /etc/systemd/system/vncserver@.service >/dev/null <<'EOF'
[Unit]
Description=TightVNC server :%i
After=network.target

[Service]
Type=forking
User=kali
Group=kali
Environment=HOME=/home/kali
WorkingDirectory=/home/kali
PIDFile=/home/kali/.vnc/%H:%i.pid
ExecStartPre=-/usr/bin/vncserver -kill :%i
ExecStart=/usr/bin/vncserver :%i -geometry 1920x1080 -depth 24
ExecStop=/usr/bin/vncserver -kill :%i
Restart=on-failure
RestartSec=5
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now vncserver@1.service
sudo systemctl status vncserver@1.service --no-pager
```

If it fails:

```bash
journalctl -u vncserver@1 -n 50 --no-pager
tail -50 /home/kali/.vnc/kali:1.log
```

Common cause: a stale `/tmp/.X1-lock` or `/tmp/.X11-unix/X1`. Clean up only
when no VNC process is running:

```bash
vncserver -kill :1 2>/dev/null || true
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1
sudo systemctl restart vncserver@1.service
```

### 5.6 Firewall for node1

Inside each node1 RedTeam VM, if UFW is active:

```bash
sudo ufw status
sudo ufw allow from 10.100.0.60 to any port 5901 proto tcp
```

The Proxmox VM firewall is enabled (`firewall=1`) on `170`, `117`, `127`,
and `134`. If VNC is listening locally but unreachable from VM 102, add a
Proxmox firewall rule on node1:

```bash
pvesh create /nodes/node1/qemu/170/firewall/rules \
  --action ACCEPT --proto tcp --dport 5901 \
  --source 10.100.0.60/32 --comment "Guac VM102 VNC"

pvesh create /nodes/node1/qemu/117/firewall/rules \
  --action ACCEPT --proto tcp --dport 5901 \
  --source 10.100.0.60/32 --comment "Guac VM102 VNC"

pvesh create /nodes/node1/qemu/127/firewall/rules \
  --action ACCEPT --proto tcp --dport 5901 \
  --source 10.100.0.60/32 --comment "Guac VM102 VNC"

pvesh create /nodes/node1/qemu/134/firewall/rules \
  --action ACCEPT --proto tcp --dport 5901 \
  --source 10.100.0.60/32 --comment "Guac VM102 VNC"
```

The same rules can be added in the UI: VM -> Firewall -> Add.

### 5.7 Verify from the correct Guacamole VM

On node1, run inside VM 102:

```bash
for ip in 80 81 82 83; do
  nc -vz -w2 10.100.0.$ip 5901
done
```

Or from node1 host with the guest agent:

```bash
qm guest exec 102 --timeout 30 -- bash -c \
  'for ip in 80 81 82 83; do nc -z -w2 10.100.0.$ip 5901 && echo "10.100.0.$ip OPEN" || echo "10.100.0.$ip closed"; done'
```

All four must be `OPEN` before you change Guacamole.

## 6. Configure VNC on node2 RedTeam4-6

Repeat section 5 on VMs `131` (RedTeam4), `111` (RedTeam5), and `110`
(RedTeam6), with these differences:

- Run the Proxmox commands on **node2** (`10.2.229.10`).
- The Guacamole VM is VM `108` at `10.100.0.50`.
- The firewall source is `10.100.0.50/32`.
- `111` has `agent: 1`; `131` and `110` do not.

Firewall rules on node2:

```bash
pvesh create /nodes/node2/qemu/131/firewall/rules \
  --action ACCEPT --proto tcp --dport 5901 \
  --source 10.100.0.50/32 --comment "Guac VM108 VNC"

pvesh create /nodes/node2/qemu/111/firewall/rules \
  --action ACCEPT --proto tcp --dport 5901 \
  --source 10.100.0.50/32 --comment "Guac VM108 VNC"

pvesh create /nodes/node2/qemu/110/firewall/rules \
  --action ACCEPT --proto tcp --dport 5901 \
  --source 10.100.0.50/32 --comment "Guac VM108 VNC"
```

VM `111` does not currently have `firewall=1`; its Proxmox rule is stored
but is not enforced until the VM firewall is enabled. The rule is harmless
and can be skipped for `111`.

If UFW is active inside the VMs:

```bash
sudo ufw allow from 10.100.0.50 to any port 5901 proto tcp
```

Verify from VM 108:

```bash
for ip in 84 85 86; do
  nc -vz -w2 10.100.0.$ip 5901
done
```

Or from node2 host:

```bash
qm guest exec 108 --timeout 30 -- bash -c \
  'for ip in 84 85 86; do nc -z -w2 10.100.0.$ip 5901 && echo "10.100.0.$ip OPEN" || echo "10.100.0.$ip closed"; done'
```

## 7. Start and register RedTeam7 (VM 201)

### 7.1 Confirm the clone finished

On node2:

```bash
qm status 201
qm config 201
```

Expected:

```text
status: stopped
name: RedTeam7
net0: e1000=BC:24:11:ED:72:57,bridge=vmbr1,firewall=1
```

If `qm status 201` still shows `lock: clone`, wait for the clone task to
finish. Do not run `qm unlock` while a clone is active. Check:

```bash
pvesh get /nodes/node2/tasks --limit 20
ps aux | grep '[q]mclone'
```

Only unlock after confirming no clone process or task is running:

```bash
qm unlock 201
```

### 7.2 Start the VM and find its IP

```bash
qm start 201
qm status 201
```

Expected IP: `10.100.0.87` (next free address after `.86`). Confirm by
MAC, not by guessing. From VM 108:

```bash
nmap -sn 10.100.0.0/24 | grep -B1 -i 'BC:24:11:ED:72:57'
```

Or, inside VM 108, after a ping sweep (the node2 host has no IP on
`vmbr1`, so run this in the Guacamole VM, not on the Proxmox host):

```bash
for i in $(seq 1 254); do ping -c1 -W1 10.100.0.$i >/dev/null 2>&1 & done
wait
ip neigh | grep -i 'bc:24:11:ed:72:57'
```

If the VM gets a different address, use that address in the Guacamole
connection. If it gets no address:

- Check the node2 core pfSense (`132`, `CydexCorePfsenseN2`) DHCP service.
- Or set a static address inside Kali with NetworkManager:

```bash
nmcli -t -f NAME,DEVICE con show
sudo nmcli con mod "<CONNECTION_NAME>" \
  ipv4.method manual \
  ipv4.addresses 10.100.0.87/24 \
  ipv4.gateway 10.100.0.1 \
  ipv4.dns 10.100.0.1
sudo nmcli con up "<CONNECTION_NAME>"
```

Do not set a static address that conflicts with `.84`-`.86`.

### 7.3 Configure VNC on RedTeam7

Follow section 5 inside VM 201:

- Set the 8-character VNC password with `vncpasswd`.
- Normalize `/home/kali/.vnc/xstartup`.
- Start `vncserver :1 -geometry 1920x1080 -depth 24`.
- Install and enable `vncserver@1.service`.

VM 201 has `firewall=1`. Add the node2 firewall rule:

```bash
pvesh create /nodes/node2/qemu/201/firewall/rules \
  --action ACCEPT --proto tcp --dport 5901 \
  --source 10.100.0.50/32 --comment "Guac VM108 VNC"
```

Verify from VM 108:

```bash
nc -vz -w2 10.100.0.87 5901
```

## 8. Update Guacamole on node1 (VM 102)

The four node1 connections already exist. You only need to confirm their
parameters and password after VNC is configured. Optionally group them.

### 8.1 GUI method

1. Open `https://10.2.229.60/guacamole/`.
2. Log in as `guacadmin`.
3. Open the user menu -> **Settings**.
4. Open **Connections**.
5. Edit `RedTeam0`, `RedTeam1`, `RedTeam2`, `RedTeam3`.
6. For each, confirm:
   - Protocol: `VNC`
   - Hostname: `10.100.0.80` / `.81` / `.82` / `.83`
   - Port: `5901`
   - Username: `kali`
   - Password: the same 8-character VNC password set in section 5.2
   - Color depth: `24-bit`
   - Resize method: `Display update`
   - Cursor: `Local`
7. Save.
8. Optional: **Settings -> Connection Groups -> New Connection Group**,
   name it `RedTeam`, type `Organizational`. Move the four connections
   into it.
9. Optional: **Settings -> Users -> redteam -> Permissions** and grant
   `READ` on the `RedTeam` group. The user already has direct full
   permissions on connections 7-10.

### 8.2 SQL method

Run on VM 102:

```bash
cd /home/analyst/guacamole
cat > /tmp/redteam-node1.sql <<'SQL'
SET @vncpass = 'R3dT3am!';   -- must match vncpasswd on the VMs

UPDATE guacamole_connection_parameter
SET parameter_value = '10.100.0.80'
WHERE connection_id = 10 AND parameter_name = 'hostname';
UPDATE guacamole_connection_parameter
SET parameter_value = '10.100.0.81'
WHERE connection_id = 7 AND parameter_name = 'hostname';
UPDATE guacamole_connection_parameter
SET parameter_value = '10.100.0.82'
WHERE connection_id = 8 AND parameter_name = 'hostname';
UPDATE guacamole_connection_parameter
SET parameter_value = '10.100.0.83'
WHERE connection_id = 9 AND parameter_name = 'hostname';

UPDATE guacamole_connection_parameter
SET parameter_value = '5901'
WHERE connection_id IN (7,8,9,10) AND parameter_name = 'port';
UPDATE guacamole_connection_parameter
SET parameter_value = 'kali'
WHERE connection_id IN (7,8,9,10) AND parameter_name = 'username';
UPDATE guacamole_connection_parameter
SET parameter_value = @vncpass
WHERE connection_id IN (7,8,9,10) AND parameter_name = 'password';

-- Optional group
INSERT INTO guacamole_connection_group (connection_group_name, type)
SELECT 'RedTeam', 'ORGANIZATIONAL'
WHERE NOT EXISTS (
  SELECT 1 FROM guacamole_connection_group WHERE connection_group_name = 'RedTeam'
);
SET @gid = (
  SELECT connection_group_id FROM guacamole_connection_group
  WHERE connection_group_name = 'RedTeam' ORDER BY connection_group_id LIMIT 1
);
UPDATE guacamole_connection SET parent_id = @gid
WHERE connection_id IN (7,8,9,10);

INSERT IGNORE INTO guacamole_connection_group_permission
  (connection_group_id, entity_id, permission)
SELECT @gid, entity_id, 'READ'
FROM guacamole_entity
WHERE name = 'redteam' AND type = 'USER';
SQL

docker exec -i guacamole_mysql \
  mysql -u guacuser -pguacpassword guacamole_db < /tmp/redteam-node1.sql
```

Verify:

```bash
docker exec guacamole_mysql mysql -u guacuser -pguacpassword -N -e \
"SELECT c.connection_id,c.connection_name,p.parameter_name,p.parameter_value
 FROM guacamole_db.guacamole_connection c
 JOIN guacamole_db.guacamole_connection_parameter p
   ON p.connection_id=c.connection_id
 WHERE c.connection_name LIKE 'RedTeam%'
 ORDER BY c.connection_id,p.parameter_name;"
```

## 9. Update Guacamole on node2 (VM 108)

### 9.1 GUI method

1. Open `https://10.2.229.50/guacamole/` or
   `https://10.2.229.60:8443/guacamole/`.
2. Log in as `guacadmin`.
3. Open **Settings -> Connections**.
4. Edit `RedTeam4`, `RedTeam5`, `RedTeam6` and confirm:
   - Protocol: `VNC`
   - Hostname: `10.100.0.84` / `.85` / `.86`
   - Port: `5901`
   - Username: `kali`
   - Password: the 8-character VNC password
5. Create a new connection:
   - Name: `RedTeam7`
   - Protocol: `VNC`
   - Hostname: the IP found in section 7.2 (expected `10.100.0.87`)
   - Port: `5901`
   - Username: `kali`
   - Password: the 8-character VNC password
6. Optional: create an organizational group named `RedTeam` and move
   `RedTeam4`-`RedTeam7` into it.
7. Grant `READ` on the group (or on each connection) to `redteam` and
   `guacuser`:
   **Settings -> Users -> redteam -> Permissions** and
   **Settings -> Users -> guacuser -> Permissions**.

### 9.2 SQL method

Run on VM 108:

```bash
cd /home/analyst/guacamole
cat > /tmp/redteam-node2.sql <<'SQL'
SET @vncpass = 'R3dT3am!';   -- must match vncpasswd on the VMs
SET @rt7ip   = '10.100.0.87'; -- change if section 7.2 found another IP

-- Existing connections
UPDATE guacamole_connection_parameter
SET parameter_value = '10.100.0.84'
WHERE connection_id = 9 AND parameter_name = 'hostname';
UPDATE guacamole_connection_parameter
SET parameter_value = '10.100.0.85'
WHERE connection_id = 10 AND parameter_name = 'hostname';
UPDATE guacamole_connection_parameter
SET parameter_value = '10.100.0.86'
WHERE connection_id = 11 AND parameter_name = 'hostname';

UPDATE guacamole_connection_parameter
SET parameter_value = '5901'
WHERE connection_id IN (9,10,11) AND parameter_name = 'port';
UPDATE guacamole_connection_parameter
SET parameter_value = 'kali'
WHERE connection_id IN (9,10,11) AND parameter_name = 'username';
UPDATE guacamole_connection_parameter
SET parameter_value = @vncpass
WHERE connection_id IN (9,10,11) AND parameter_name = 'password';

-- RedTeam7
INSERT INTO guacamole_connection (connection_name, protocol)
SELECT 'RedTeam7', 'vnc'
WHERE NOT EXISTS (
  SELECT 1 FROM guacamole_connection WHERE connection_name = 'RedTeam7'
);
SET @rt7 = (
  SELECT connection_id FROM guacamole_connection
  WHERE connection_name = 'RedTeam7' ORDER BY connection_id LIMIT 1
);

INSERT INTO guacamole_connection_parameter
  (connection_id, parameter_name, parameter_value)
VALUES
  (@rt7, 'hostname', @rt7ip),
  (@rt7, 'port',     '5901'),
  (@rt7, 'username', 'kali'),
  (@rt7, 'password', @vncpass)
ON DUPLICATE KEY UPDATE parameter_value = VALUES(parameter_value);

-- Optional group
INSERT INTO guacamole_connection_group (connection_group_name, type)
SELECT 'RedTeam', 'ORGANIZATIONAL'
WHERE NOT EXISTS (
  SELECT 1 FROM guacamole_connection_group WHERE connection_group_name = 'RedTeam'
);
SET @gid = (
  SELECT connection_group_id FROM guacamole_connection_group
  WHERE connection_group_name = 'RedTeam' ORDER BY connection_group_id LIMIT 1
);
UPDATE guacamole_connection SET parent_id = @gid
WHERE connection_id IN (9,10,11,@rt7);

-- Permissions for redteam and guacuser
INSERT IGNORE INTO guacamole_connection_permission
  (connection_id, entity_id, permission)
SELECT @rt7, entity_id, 'READ'
FROM guacamole_entity
WHERE name IN ('redteam','guacuser') AND type = 'USER';

INSERT IGNORE INTO guacamole_connection_group_permission
  (connection_group_id, entity_id, permission)
SELECT @gid, entity_id, 'READ'
FROM guacamole_entity
WHERE name IN ('redteam','guacuser') AND type = 'USER';

-- Keep existing direct READ permissions on RedTeam4-6; nothing to add.
SQL

docker exec -i guacamole_mysql \
  mysql -u guacuser -pguacpassword guacamole_db < /tmp/redteam-node2.sql
```

Verify:

```bash
docker exec guacamole_mysql mysql -u guacuser -pguacpassword -N -e \
"SELECT c.connection_id,c.connection_name,c.parent_id,
        MAX(CASE WHEN p.parameter_name='hostname' THEN p.parameter_value END) AS host,
        MAX(CASE WHEN p.parameter_name='port'     THEN p.parameter_value END) AS port
 FROM guacamole_db.guacamole_connection c
 JOIN guacamole_db.guacamole_connection_parameter p
   ON p.connection_id=c.connection_id
 WHERE c.connection_name LIKE 'RedTeam%'
 GROUP BY c.connection_id,c.connection_name,c.parent_id
 ORDER BY c.connection_id;"
```

### 9.3 Remove the stale node2 RedTeam0 connection

Connection `15` points to `10.100.0.80`, which is on node1's lab segment
and is unreachable from VM 108. Node1 Guacamole already has RedTeam0.

Verify it is the stale record:

```bash
docker exec guacamole_mysql mysql -u guacuser -pguacpassword -N -e \
"SELECT c.connection_id,c.connection_name,p.parameter_name,p.parameter_value
 FROM guacamole_db.guacamole_connection c
 JOIN guacamole_db.guacamole_connection_parameter p
   ON p.connection_id=c.connection_id
 WHERE c.connection_id=15;"
```

If it is the `10.100.0.80` VNC connection, remove it:

```bash
docker exec guacamole_mysql mysql -u guacuser -pguacpassword guacamole_db -e \
"DELETE FROM guacamole_connection_parameter WHERE connection_id=15;
 DELETE FROM guacamole_connection_permission WHERE connection_id=15;
 DELETE FROM guacamole_connection WHERE connection_id=15;"
```

Do not remove node1's RedTeam0 connection (ID 10 on VM 102).

## 10. End-to-end validation

### 10.1 Network reachability

From VM 102:

```bash
for ip in 80 81 82 83; do nc -vz -w2 10.100.0.$ip 5901; done
```

From VM 108:

```bash
for ip in 84 85 86 87; do nc -vz -w2 10.100.0.$ip 5901; done
```

From the `guacd` container on each Guacamole VM:

```bash
docker exec guacd nc -vz -w2 10.100.0.80 5901
docker exec guacd nc -vz -w2 10.100.0.84 5901
```

If the host succeeds but the container fails, check the host firewall and
Docker routing (`ufw` must allow routed traffic, or the equivalent rule).

### 10.2 Guacamole logs

```bash
docker logs guacd --tail 50
docker logs guacamole --tail 50
```

A successful session shows a VNC connection to the target. An
authentication failure shows a VNC handshake/auth error.

### 10.3 Browser test

1. From `10.2.228.0/24`, open:
   - `https://10.2.229.60/guacamole/` for RedTeam0-3.
   - `https://10.2.229.50/guacamole/` or
     `https://10.2.229.60:8443/guacamole/` for RedTeam4-7.
2. Log in as `redteam` (or `guacadmin`).
3. Launch each connection.
4. Confirm the XFCE desktop appears.
5. Disconnect and reconnect to confirm the systemd VNC service stays up.

### 10.4 Reboot test

Reboot one VM per node and confirm VNC returns automatically:

```bash
qm reboot 117
qm reboot 111
```

After boot:

```bash
qm guest exec 117 --timeout 20 -- bash -c 'ss -tlnp | grep 5901'
qm guest exec 111 --timeout 20 -- bash -c 'ss -tlnp | grep 5901'
```

If VNC does not return, check `systemctl is-enabled vncserver@1` and
`journalctl -u vncserver@1`.

## 11. Troubleshooting

### 11.1 VNC port is closed

Inside the VM:

```bash
ss -tlnp | grep 5901
systemctl status vncserver@1 --no-pager
tail -50 /home/kali/.vnc/kali:1.log
```

Start it manually:

```bash
su - kali -c 'vncserver :1 -geometry 1920x1080 -depth 24'
```

### 11.2 `vncserver: The HOME environment variable is not set`

You ran it as root without a login shell. Use:

```bash
su - kali -c 'vncserver :1 -geometry 1920x1080 -depth 24'
```

### 11.3 Authentication failure

- TightVNC uses only the first 8 characters of the password.
- Reset the password with `vncpasswd` as `kali`.
- Update the Guacamole `password` parameter to the same 8-character value.
- Restart VNC after changing the password.

### 11.4 Black screen or no desktop

Check the VNC log and `xstartup`:

```bash
cat /home/kali/.vnc/kali:1.log
cat /home/kali/.vnc/xstartup
command -v startxfce4
```

Use the clean `xstartup` from section 5.3 and restart:

```bash
vncserver -kill :1
vncserver :1 -geometry 1920x1080 -depth 24
```

### 11.5 `Couldn't start Xtightvnc; trying default font path`

This usually means an invalid option was passed or the X font path is
missing. Verify you used TightVNC syntax:

```bash
vncserver :1 -geometry 1920x1080 -depth 24
```

If it still fails:

```bash
sudo apt install -y xfonts-base
```

### 11.6 Connection refused from Guacamole but VNC is listening

Check the Proxmox VM firewall and the guest firewall:

```bash
# node1
pvesh get /nodes/node1/qemu/117/firewall/rules
# node2
pvesh get /nodes/node2/qemu/111/firewall/rules
```

Add the ACCEPT rule from section 5.6 or 6.

### 11.7 Connection times out with "No route to host"

You are using the wrong Guacamole instance. Node1 and node2 lab segments
are isolated. Use:

- VM 102 Guacamole for RedTeam0-3.
- VM 108 Guacamole for RedTeam4-7.

### 11.8 HTTP 502 on `10.2.229.60:8443`

VM 102 cannot reach the node2 Guacamole backend:

```bash
# on VM 102
curl -skI https://10.2.229.50/guacamole/
ip route get 10.2.229.50
```

Fix VM 108 or the management route first.

### 11.9 HTTP 403

Your client IP is not in the Caddy allowlist. See section 3.3.

### 11.10 RedTeam7 has no IP

- Check the clone completed: `qm status 201`.
- Check the node2 core pfSense DHCP service on VM 132.
- Set a static address with `nmcli` (section 7.2), avoiding `.84`-`.86`.
- Confirm the MAC in the VM matches `BC:24:11:ED:72:57`.

## 12. Rollback

### 12.1 Stop and disable VNC

On each RedTeam VM:

```bash
sudo systemctl disable --now vncserver@1.service
sudo rm -f /etc/systemd/system/vncserver@.service
sudo systemctl daemon-reload
vncserver -kill :1 2>/dev/null || true
```

### 12.2 Restore the Guacamole databases

On VM 102 and VM 108:

```bash
cd /home/analyst/guacamole
docker exec -i guacamole_mysql sh -c \
  'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" guacamole_db' \
  < guacamole_db-YYYY-MM-DD-HHMMSS.sql
```

### 12.3 Remove the RedTeam7 connection

```bash
docker exec guacamole_mysql mysql -u guacuser -pguacpassword guacamole_db -e \
"DELETE FROM guacamole_connection_parameter
 WHERE connection_id=(SELECT connection_id FROM guacamole_connection WHERE connection_name='RedTeam7' LIMIT 1);
 DELETE FROM guacamole_connection_permission
 WHERE connection_id=(SELECT connection_id FROM guacamole_connection WHERE connection_name='RedTeam7' LIMIT 1);
 DELETE FROM guacamole_connection WHERE connection_name='RedTeam7';"
```

### 12.4 Revert VM 201

If you created or changed RedTeam7 and want to remove it:

```bash
qm stop 201
qm destroy 201 --purge
```

Only do this after confirming the disk is not needed. The VM was a clone;
the source VM is unaffected.

### 12.5 Revert snapshots

```bash
qm rollback <vmid> pre-redteam-vnc
qm delsnapshot <vmid> pre-redteam-vnc
```

## 13. Security notes

1. VNC passwords are limited to 8 characters. Use a random 8-character
   value, not `Password`. Rotate it periodically.
2. Guacamole stores connection passwords in plain text in MySQL. Protect
   database dumps and never commit them.
3. The Guacamole database credentials are currently `guacuser` /
   `guacpassword`. Rotate them after the lab is stable.
4. Keep Guacamole `8080` bound to `127.0.0.1`; only Caddy should expose
   `443`/`8443`.
5. Do not expose Proxmox `8006` or VNC `5901` to untrusted networks. The
   Proxmox firewall rules above restrict VNC to the Guacamole VM lab IPs.
6. Enable TOTP/MFA for Guacamole accounts when the lab is stable.
7. Replace the self-signed certificates with an internal CA certificate.

## Appendix A: Command cheat sheet

### Node1

```bash
ssh root@10.2.229.9

# status
qm list | grep -i redteam

# console/agent
qm guest exec 117 --timeout 30 -- bash -c 'ss -tlnp | grep 5901'

# start/stop VNC via agent
qm guest exec 117 --timeout 30 -- bash -c \
  'su - kali -c "vncserver :1 -geometry 1920x1080 -depth 24"'

# firewall
pvesh create /nodes/node1/qemu/117/firewall/rules \
  --action ACCEPT --proto tcp --dport 5901 \
  --source 10.100.0.60/32 --comment "Guac VM102 VNC"

# verify from Guac VM
qm guest exec 102 --timeout 30 -- bash -c \
  'for ip in 80 81 82 83; do nc -z -w2 10.100.0.$ip 5901 && echo "$ip OPEN" || echo "$ip closed"; done'
```

### Node2

```bash
# status
qm list | grep -i redteam

# start RedTeam7
qm start 201
qm status 201

# find RedTeam7 IP by MAC
qm guest exec 108 --timeout 60 -- bash -c \
  'nmap -sn 10.100.0.0/24 | grep -B1 -i BC:24:11:ED:72:57'

# firewall
pvesh create /nodes/node2/qemu/201/firewall/rules \
  --action ACCEPT --proto tcp --dport 5901 \
  --source 10.100.0.50/32 --comment "Guac VM108 VNC"

# verify from Guac VM
qm guest exec 108 --timeout 30 -- bash -c \
  'for ip in 84 85 86 87; do nc -z -w2 10.100.0.$ip 5901 && echo "$ip OPEN" || echo "$ip closed"; done'
```

### Guacamole DB

```bash
docker exec -it guacamole_mysql mysql -u guacuser -pguacpassword guacamole_db

SELECT connection_id, connection_name, protocol, parent_id
FROM guacamole_connection ORDER BY connection_id;

SELECT connection_id, parameter_name, parameter_value
FROM guacamole_connection_parameter
WHERE connection_id IN (7,8,9,10) ORDER BY connection_id, parameter_name;

SELECT entity_id, name, type FROM guacamole_entity ORDER BY entity_id;
```

## Appendix B: SQL reference

### Create a connection

```sql
INSERT INTO guacamole_connection (connection_name, protocol)
SELECT 'RedTeam7', 'vnc'
WHERE NOT EXISTS (
  SELECT 1 FROM guacamole_connection WHERE connection_name = 'RedTeam7'
);

SET @cid = (
  SELECT connection_id FROM guacamole_connection
  WHERE connection_name = 'RedTeam7' ORDER BY connection_id LIMIT 1
);

INSERT INTO guacamole_connection_parameter
  (connection_id, parameter_name, parameter_value)
VALUES
  (@cid, 'hostname', '10.100.0.87'),
  (@cid, 'port',     '5901'),
  (@cid, 'username', 'kali'),
  (@cid, 'password', 'R3dT3am!')
ON DUPLICATE KEY UPDATE parameter_value = VALUES(parameter_value);
```

### Grant READ to a user

```sql
INSERT IGNORE INTO guacamole_connection_permission
  (connection_id, entity_id, permission)
SELECT @cid, entity_id, 'READ'
FROM guacamole_entity
WHERE name = 'redteam' AND type = 'USER';
```

### Create a group and move connections

```sql
INSERT INTO guacamole_connection_group (connection_group_name, type)
SELECT 'RedTeam', 'ORGANIZATIONAL'
WHERE NOT EXISTS (
  SELECT 1 FROM guacamole_connection_group WHERE connection_group_name = 'RedTeam'
);

SET @gid = (
  SELECT connection_group_id FROM guacamole_connection_group
  WHERE connection_group_name = 'RedTeam' ORDER BY connection_group_id LIMIT 1
);

UPDATE guacamole_connection SET parent_id = @gid
WHERE connection_name IN ('RedTeam4','RedTeam5','RedTeam6','RedTeam7');

INSERT IGNORE INTO guacamole_connection_group_permission
  (connection_group_id, entity_id, permission)
SELECT @gid, entity_id, 'READ'
FROM guacamole_entity
WHERE name IN ('redteam','guacuser') AND type = 'USER';
```

## Appendix C: Reset the Kali console password

If you do not know the `kali` console password and cannot use the guest
agent:

1. Open the VM console in Proxmox and reboot it.
2. At the GRUB menu, press `e` on the default Kali entry.
3. Find the line starting with `linux` and append:

   ```text
   rw init=/bin/bash
   ```

4. Press `Ctrl-X` to boot.
5. At the root shell:

   ```bash
   passwd kali
   sync
   exec /sbin/init
   ```

6. Reboot normally.

This changes only the local console password, not the VNC password. Set
the VNC password separately with `vncpasswd` as described in section 5.2.
