# Proxmox VM Memory Usage Analysis and Optimization

## Scope

Read-only inspection of Proxmox nodes `node1` and `node2` on 2026-10-22.

## Executive Summary

- There is no host-level memory exhaustion, OOM kill, or memory pressure.
- The reported "100%" is mostly per-VM reporting and ballooning behavior, not the host running out of RAM.
- Auto-ballooning is effectively disabled on all VMs because no `balloon` minimum is configured.
- Most guest agents are not running, especially on Windows VMs.
- Most Windows VMs do not report balloon free-memory statistics.
- KSM is active via `ksmtuned` and has already deduplicated approximately 26 GB per node.
- Node1 is close to the default auto-balloon threshold: about 149 GiB used of 188 GiB (~79%).

## Current Host State

| Node | RAM Used | Available | PSI Memory | OOM Events |
|---|---:|---:|---:|---|
| node1 | 149 GiB / 188 GiB (~79%) | 38 GiB | 0.00 | none |
| node2 | 131 GiB / 188 GiB (~70%) | 56 GiB | 0.00 | none |

### KSM

Both nodes have `ksmtuned` enabled and running.

| Node | KSM run | Pages Shared | Approx. Saved |
|---|---:|---:|---:|
| node1 | 0 | 1,723,953 | ~26.6 GB |
| node2 | 0 | 1,693,525 | ~25.8 GB |

`KSM run=0` means KSM is idle because there is no current memory pressure. `ksmtuned` will enable it when needed. Existing shared pages remain deduplicated.

## Why VMs Show 100%

### 1. Proxmox reports committed/touched memory, not guest free memory

For Windows, Proxmox often reports the VM's cgroup RSS. Windows normally fills its assigned RAM with cache and standby memory, so the VM appears near 100% even when Task Manager shows lower "in use" memory.

### 2. Auto-ballooning is disabled on every VM

All VM configurations have no `balloon:` value.

Proxmox auto-ballooning explicitly skips VMs without a configured balloon minimum:

```text
next if !$d->{balloon_min}; # skip if balloon value not set in config
```

The balloon device exists, but the target stays at maximum, so the VM never releases RAM.

### 3. Guest agents are missing on most VMs

`qm agent <vmid> ping` fails for almost all VMs, including nearly all Windows VMs. Without the agent, Proxmox cannot read guest free memory and falls back to host RSS.

### 4. Most Windows VMs lack working balloon statistics

`qm monitor <vmid> info balloon` returns only `actual` and `max_mem` for most Windows guests, not `free_mem` and `total_mem`. This means the VirtIO balloon driver is not reporting or reclaiming memory.

### 5. Some VMs are genuinely near full

Examples:

- VM 110 `RedTeam6`: ~3.84 GB used of 4 GB, ~277 MB free, and has swapped.
- Wazuh VMs: only ~116-264 MB free.
- Windows VMs: 90-100% of assigned RAM touched.

## Samples

| VM | OS | Assigned | Host/Reported Usage | Guest Free | Agent | Balloon Free Stats |
|---|---|---:|---:|---:|---|---|
| 108 Node2Guacamole | Linux | 8 GB | 2.61 GB | 5.45 GB | yes | yes |
| 110 RedTeam6 | Linux | 4 GB | 3.84 GB | 277 MB | no | yes |
| 136 WinSvr-VISCOM-DC | Windows | 6096 MB | 5.75 GB | unknown | no | no |
| 139 Win1-Nolcom | Windows | 4 GB | 4.04 GB | unknown | no | no |
| 170 RedTeam0 | Linux | 4 GB | 1.76 GB | 2.35 GB | no | yes |
| 124 WinSvr-NCRCOM-DC | Windows | 6096 MB | 5.04 GB | unknown | no | no |

## Root Causes

1. No `balloon` minimum configured, so Proxmox auto-ballooning skips every VM.
2. Guest agents are not running on most VMs.
3. Most Windows VMs lack working VirtIO balloon statistics.
4. Proxmox reports cgroup RSS or `total_mem - free_mem`, which includes guest cache.
5. Node1 is tightly overcommitted: about 170 GB assigned on a 188 GB host.
6. KSM is idle because host usage is below the pressure threshold.

## Optimization Plan

### Phase 1 - Pilot ballooning

Start with one Windows VM and one Linux VM.

```bash
qm set <vmid> --balloon 3072
```

Verify:

```bash
qm monitor <vmid>
# inside monitor:
info balloon
```

Check that the target changes and the guest remains responsive.

### Phase 2 - Install guest agents and balloon drivers

Linux:

```bash
apt-get install qemu-guest-agent
systemctl enable --now qemu-guest-agent
```

Windows:

- Mount the VirtIO ISO.
- Install `virtio-win-guest-tools.exe`.
- Ensure the VirtIO Balloon Driver is installed.
- Ensure the `QEMU Guest Agent` service is running.
- Reboot.
https://fedorapeople.org/groups/virt/virtio-win/direct-downloads
Verify:

```bash
qm agent <vmid> ping
printf 'info balloon\n' | qm monitor <vmid>
```

Expected: `free_mem` and `total_mem` appear.

### Phase 3 - Roll out balloon minimums

Suggested starting values:

| VM Type | Assigned | Balloon Minimum |
|---|---:|---:|
| 4 GB Windows 11 lab VM | 4096 | 3072 |
| 6 GB Windows DC/file server | 6096 | 4096 |
| 4 GB Linux RedTeam/Kali | 4096 | 2048 |
| 4 GB Wazuh | 4096 | 3584-4096 |
| 8 GB Guacamole/template | 8192 | 3072 |
| 4 GB pfSense | 4096 | 2048 |
| 24-32 GB Sec-Onion (when running) | 24576-32768 | 8192-12288 |

Do not set minimums too low. A 4 GB Windows VM with a 1 GB minimum will thrash.

### Phase 4 - Reduce assigned RAM where excessive

Requires shutdown/reboot:

- Guacamole VM 108: 8 GB assigned, only ~1.3 GB used in guest. Consider 4 GB.
- Underused Linux templates/RedTeam VMs: consider reducing 4 GB to 3 GB.
- Wazuh VMs are genuinely tight; add RAM or tune indexer heap/retention.

### Phase 5 - Capacity and KSM

- Node1 has about 170 GB assigned on a 188 GB host. Add RAM or move VMs if all workloads need maximum memory simultaneously.
- Leave `ksmtuned` enabled.
- Optional: lower the auto-balloon host target from 80% to 75%:

```bash
pvesh set /nodes/<node>/config --ballooning-target 75
```

## Verification Commands

```bash
free -h
cat /proc/pressure/memory
cat /sys/kernel/mm/ksm/run
grep -E 'pages_sharing|pages_shared' /sys/kernel/mm/ksm/*

pvesh get /nodes/<node>/qemu/<vmid>/status/current --output-format json
qm monitor <vmid>
# info balloon
```

## Risks

- Balloon minimums that are too low can cause guest swapping and poor performance.
- Installing agents/drivers requires guest reboots.
- Reducing assigned RAM requires VM downtime.
- Windows may still show high memory usage because of cache and standby memory.
- KSM has CPU and security tradeoffs, but it is already configured and running via `ksmtuned`.

## Recommended First Action

Pilot `--balloon` on one Windows VM and one Linux VM, install the guest agent/balloon driver on those two, and monitor for 24 hours before rolling out to all VMs.

## Open Questions

1. Are VMs actually slow, or is this only the Proxmox 100% display?
2. Which VMs are critical and must retain full memory?
3. Can Windows VMs be rebooted to install the guest agent and balloon driver?
4. Can underused VMs be restarted to reduce assigned RAM?
