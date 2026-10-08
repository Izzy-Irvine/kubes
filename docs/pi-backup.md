# WARNING! This is AI generated slop


# Raspberry Pi backup server

The Raspberry Pi (hostname `raspberrypi`, tailnet `raspberrypi.tail797fc.ts.net`,
`100.89.252.121`) is the off-cluster backup target. It currently serves the
Longhorn backup store over NFS; ZFS replication will be added later (see the
stub at the end).

Everything in this document is set up manually on the Pi. The only part that
lives in Git is the cluster side, which is described in
[Cluster side](#cluster-side).

## Architecture

Longhorn mounts its NFS backup target **from its own pods** (the
`longhorn-manager`, instance-manager and recovery-backend pods), not from the
host. Those pods are on the cluster pod network and cannot route to the
tailnet, so the cluster reaches the Pi through a Tailscale **egress proxy**:

```
longhorn-system pod ─▶ ClusterIP service ─▶ Tailscale egress proxy
   (tag:longhorn-egress) ──WireGuard──▶ raspberrypi:2049 (NFSv4.2, tailscale0 only)
```

The egress proxy, the backing Service and a `NetworkPolicy` live in
`clusters/clowder/tailscale/egress.yaml`. The Longhorn backup target is set in
`clusters/clowder/longhorn/resources.yaml`.

## Security model

There is no per-client authentication in NFS (only source-host allowlists or
Kerberos). "Authenticated" here is provided by **Tailscale device identity**,
backed by the following layers so that only the Longhorn backup path can reach
the share:

1. **Dedicated Tailscale tag.** The egress proxy is tagged
   `tag:longhorn-egress`, distinct from the other operator proxies
   (`tag:k8s`). The tailnet policy lets only `tag:longhorn-egress` reach the Pi
   on 2049; members may reach it only on `tcp:22` (SSH). Other cluster devices
   (ingress proxies, exit/subnet-router) cannot reach it at all.
2. **Kubernetes `NetworkPolicy`.** The proxy pods accept connections only from
   the `longhorn-system` namespace and from the operator pod. Other cluster
   workloads — including the exit node and ingress proxies that share the
   `tailscale` namespace — are dropped by Cilium even though they can resolve
   the Service.
3. **Pi firewall.** `nfsd`/`rpcbind`/`mountd` are not bound to a specific
   interface, so nftables drops the NFS/RPC ports (`2049`, `111`, `32767`) on
   anything other than `tailscale0`. `rpcbind`, `mountd` and `nfs-server` all
   wait for that rule before they start.
4. **NFS export.** The export uses `root_squash` and exposes only the backup
   directory. The tailnet policy — not `root_squash` — is what stops other
   devices from connecting.
5. **Mount guard.** `nfs-server` only starts when the encrypted dataset is
   mounted, and is bound to it (`BindsTo`) so it stops if the dataset is ever
   unmounted. The plaintext directory underneath the mountpoint can never be
   exported.
6. **Encryption at rest.** The dataset is ZFS-encrypted (AES-256-GCM) with a
   passphrase that is not stored on the Pi, and **swap is disabled** so the
   passphrase and plaintext cannot be paged to the unencrypted SD card.

Tailscale also encrypts the transport (WireGuard) and mutually authenticates
both ends.

## Prerequisites

- Raspberry Pi running Raspberry Pi OS / Debian, on the tailnet.
- A **wired ethernet** connection on the backup VLAN (Wi-Fi is disabled — it is
  far too slow for NFS; see step 0).
- Root (sudo) access.
- Tailscale admin console access (for the policy).

---

## 0. Base OS: disable swap and Wi-Fi

The Pi is not in a physically safe place, so nothing sensitive may land on the
unencrypted SD card — including swap. Raspberry Pi OS enables a 512 MiB
`dphys-swapfile` swap by default; turn it off:

```bash
sudo dphys-swapfile swapoff
sudo systemctl disable --now dphys-swapfile
sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=0/' /etc/dphys-swapfile
sudo swapoff -a
```

Verify `/proc/swaps` shows no entry. (The Pi has RAM to spare; if memory ever
becomes tight, use encrypted `zram` rather than disk swap.)

### Wi-Fi off; wired only

The Pi must be on **wired ethernet**, and Wi-Fi should be disabled. Over Wi-Fi
the link ran at ~100 ms RTT and backups crawled at 1–7 MB/s; on the wire it is
~1–2 ms and ~40 MB/s. Disabling the radio also saves power.

Plug the ethernet into a port that serves DHCP, then bring it up and confirm it
got an address and the default route:

```bash
sudo nmcli device connect eth0
ip -br addr show eth0
ip route
```

Then turn Wi-Fi off for good:

```bash
sudo nmcli connection modify snoo_blue_canoe connection.autoconnect no
sudo nmcli radio wifi off
grep -q '^dtoverlay=disable-wifi' /boot/firmware/config.txt \
  || echo 'dtoverlay=disable-wifi' | sudo tee -a /boot/firmware/config.txt
```

`nmcli radio wifi off` takes effect immediately; `dtoverlay=disable-wifi`
disables the radio in hardware and takes effect on the next reboot. (Add
`dtoverlay=disable-bt` too if you also want Bluetooth off.)

---

## 1. Tag the Pi and the egress proxy

The Pi is tagged `tag:backup-pi` and the egress proxy is tagged
`tag:longhorn-egress`. This is what makes the identity-based policy possible;
the steps below document how it was done (the Pi is already tagged — 1c is kept
for re-provisioning).

### 1a. Tailnet policy

This tailnet uses the newer **`grants`** syntax. Open the policy file
(admin console → **Access controls**) and:

1. Ensure `tagOwners` contains the two new tags (you may have already added
   them).
2. Replace the catch-all grant `{ "src": ["*"], "dst": ["*"], "ip": ["*"] }`
   with the scoped grants below. Grants are allow-only, so the broad catch-all
   must go for the Pi restriction to take effect.
3. Add `tag:backup-pi` to the `ssh` destination — otherwise Tailscale SSH to the
   Pi stops working once it is tagged (a tagged device is no longer
   `autogroup:self`).

```jsonc
{
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s": ["tag:k8s-operator"],
    "tag:backup-pi": ["autogroup:admin"],
    "tag:longhorn-egress": ["tag:k8s-operator"]
  },

  "grants": [
    // Members keep access to cluster services and their own devices.
    { "src": ["autogroup:member"], "dst": ["tag:k8s", "tag:k8s-operator", "autogroup:self"], "ip": ["*"] },
    // ...the approved subnet route and the internet through an exit node.
    { "src": ["autogroup:member"], "dst": ["192.168.100.0/24"], "ip": ["*"] },
    { "src": ["autogroup:member"], "dst": ["autogroup:internet"], "ip": ["*"] },
    // ...and only SSH/ICMP to the Pi — never its NFS.
    { "src": ["autogroup:member"], "dst": ["tag:backup-pi"], "ip": ["tcp:22", "icmp:*"] },

    // Operator <-> its tag:k8s proxies.
    { "src": ["tag:k8s-operator"], "dst": ["tag:k8s"], "ip": ["*"] },
    { "src": ["tag:k8s"], "dst": ["tag:k8s"], "ip": ["*"] },

    // Only the egress proxy may reach the Pi: NFS for backups, and the two
    // exporter ports the cluster scrapes.
    { "src": ["tag:longhorn-egress"], "dst": ["tag:backup-pi"], "ip": ["tcp:2049", "tcp:9100", "tcp:9633"] },

    // Kubernetes API access through the operator (unchanged).
    {
      "src": ["autogroup:admin"],
      "dst": ["tag:k8s-operator"],
      "app": {
        "tailscale.com/cap/kubernetes": [{ "impersonate": { "groups": ["system:masters"] } }]
      }
    }
  ],

  "ssh": [
    {
      "action": "check",
      "src": ["autogroup:member"],
      "dst": ["autogroup:self"],
      "users": ["autogroup:nonroot", "root"]
    },
    // Tagged devices are not "self", so the Pi needs its own rule.
    {
      "action": "check",
      "src": ["autogroup:member"],
      "dst": ["tag:backup-pi"],
      "users": ["autogroup:nonroot", "root"]
    }
  ],

  "autoApprovers": {
    "exitNode": ["tag:k8s"],
    "routes": { "192.168.100.0/24": ["tag:k8s"] }
  }
}
```

> Members are deliberately limited to cluster services (`tag:k8s`), their own
> devices, the `192.168.100.0/24` subnet, exit-node internet, and SSH/ICMP to
> the Pi. They **cannot** reach the Pi's NFS — 2049 is reserved for
> `tag:longhorn-egress`.

### 1b. Let the operator assign `tag:longhorn-egress`

The operator mints devices for a `ProxyGroup` using `spec.tags`, but only for
tags owned by its own tag, `tag:k8s-operator`. The `tagOwners` entry above
(`"tag:longhorn-egress": ["tag:k8s-operator"]`) is therefore normally all that
is required — no OAuth client change — because the operator's OAuth client
already carries `tag:k8s-operator` and `tag:k8s` is owned the same way.

If the `ProxyGroup` still fails to join after the policy is saved, add
`tag:longhorn-egress` to the operator's OAuth client (Admin console →
**Settings → Trust credentials / OAuth clients**).

> Until the operator can assign the tag, the `ProxyGroup` will not come up and
> backups will fail.

### 1c. Apply the tag to the Pi

```bash
sudo tailscale up --advertise-tags=tag:backup-pi
```

This re-authenticates the device and converts it from user-owned to tag-owned.
Verify:

```bash
tailscale status --json | jq -r '.Self.Tags'
# -> ["tag:backup-pi"]
```

---

## 2. Storage — encrypted ZFS dataset

The share is a ZFS dataset in the same pool as the (already encrypted)
`general-storage-backup` dataset. Native ZFS encryption is a per-dataset
property set **at creation time**; the pool itself is not encrypted. Create it
with your own passphrase (it prompts twice):

```bash
sudo zfs create \
  -o encryption=on \
  -o keyformat=passphrase \
  -o keylocation=prompt \
  -o compression=lz4 \
  -o mountpoint=/srv/longhorn-backup \
  pool2025/longhorn-backup
```

`keylocation=prompt` means the dataset is **locked after every reboot** and must
be unlocked by hand — see [Reboot and unlock](#reboot-and-unlock).

Give the squashed root (see `root_squash` below) write access:

```bash
sudo chown nobody:nogroup /srv/longhorn-backup
sudo chmod 750 /srv/longhorn-backup
```

---

## 3. NFS server (NFSv4.2 only)

Longhorn's egress proxy forwards a single TCP port, so the server must speak
NFSv4.2 (NFSv3's rpcbind/mountd dynamic ports cannot be proxied).

```bash
sudo apt update
sudo apt install -y nfs-kernel-server
```

Configure NFSv4.2 only (no UDP, no NFSv3) and pin the mountd port so the
firewall can name it. nfs-utils 2.6 reads `nfs.conf`; the Debian
`nfs-mountd.service` ignores `/etc/default/nfs-kernel-server`, so the port must
go here:

```bash
sudo tee /etc/nfs.conf.d/longhorn.conf >/dev/null <<'EOF'
[nfsd]
vers3=n
vers4=y
vers4.2=y
udp=n

[mountd]
port=32767
EOF
```

Export only the backup directory, only to the tailnet (the original file is kept
as `/etc/exports.orig`):

```bash
sudo cp -a /etc/exports /etc/exports.orig   # once
sudo tee /etc/exports >/dev/null <<'EOF'
/srv/longhorn-backup 100.64.0.0/10(rw,sync,no_subtree_check,root_squash)
EOF
```

> `root_squash` maps the client's root to `nobody`; the directory ownership from
> step 2 makes that writable while preventing arbitrary UIDs from becoming root
> on the Pi. Do **not** add `no_root_squash`.

`rpcbind` and `rpc.mountd` must stay running (`nfs-server.service` requires
mountd, and mountd hangs without rpcbind) — NFSv3 itself is disabled in the
kernel, and both are firewalled to `tailscale0` in step 4. The v3-only helpers
`rpc-statd`/`rpc-statd-notify` are masked:

```bash
sudo systemctl enable --now rpcbind.socket
sudo systemctl mask --now rpc-statd.service rpc-statd-notify.service
# Enable but do NOT start yet: the mount guard in step 5 must be installed
# first, so nfs-server never exports the plaintext fallback directory.
sudo systemctl enable nfs-server
```

`nfs-server` is started at the end of step 5 (after the mount guard is in
place). Step 7 confirms only NFSv4 is served.

---

## 4. Firewall: NFS only on `tailscale0`

`nfsd`/`rpcbind`/`mountd` listen on all interfaces, so firewall them. This is a
self-contained nft table applied by a dedicated unit — the stock
`/etc/nftables.conf` is **not** used, because it does `flush ruleset` and would
interfere with the rules Tailscale installs at runtime. Loopback and
`tailscale0` are allowed; the NFS/RPC ports are dropped everywhere else.

```bash
sudo tee /etc/nftables.d/nfs-tailscale-only.nft >/dev/null <<'EOF'
table inet nfs_lockdown {
  chain input {
    type filter hook input priority filter - 5; policy accept;
    iifname "tailscale0" accept
    iifname "lo" accept
    tcp dport { 2049, 111, 32765, 32766, 32767 } drop
    udp dport { 2049, 111, 32765, 32766, 32767 } drop
  }
}
EOF
sudo tee /etc/systemd/system/nfs-tailscale-only.service >/dev/null <<'EOF'
[Unit]
Description=Restrict NFS/RPC ports to the tailscale0 interface
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/sbin/nft delete table inet nfs_lockdown
ExecStart=/usr/sbin/nft -f /etc/nftables.d/nfs-tailscale-only.nft

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now nfs-tailscale-only.service
```

`rpcbind` and `nfs-mountd` must also wait for the firewall, so port 111/32767
cannot briefly listen on the LAN at boot before the rule loads:

```bash
sudo mkdir -p /etc/systemd/system/rpcbind.socket.d /etc/systemd/system/nfs-mountd.service.d
for d in rpcbind.socket.d nfs-mountd.service.d; do
  sudo tee /etc/systemd/system/$d/10-after-firewall.conf >/dev/null <<'EOF'
[Unit]
Requires=nfs-tailscale-only.service
After=nfs-tailscale-only.service
EOF
done
sudo systemctl daemon-reload
```

---

## 5. Mount guard and stop-on-unmount

When the encrypted dataset is locked, `/srv/longhorn-backup` reverts to a plain
(empty) directory on the unencrypted SD card, and NFS would happily export it.
This drop-in refuses to start unless the dataset is mounted, **binds** the
service to the ZFS mount so it stops if the dataset is ever unmounted, and makes
NFS wait for the firewall. Install it **before starting NFS**:

```bash
sudo tee /etc/systemd/system/nfs-server.service.d/10-require-longhorn-mount.conf >/dev/null <<'EOF'
[Unit]
RequiresMountsFor=/srv/longhorn-backup
BindsTo=srv-longhorn\x2dbackup.mount
After=srv-longhorn\x2dbackup.mount
Requires=nfs-tailscale-only.service
After=nfs-tailscale-only.service

[Service]
ExecStartPre=/usr/bin/bash -c 'mountpoint -q /srv/longhorn-backup || { echo "FATAL: /srv/longhorn-backup not mounted. Run: zfs load-key pool2025/longhorn-backup && zfs mount pool2025/longhorn-backup" >&2; exit 1; }'
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now nfs-server
sudo exportfs -ra

# Confirm only v4 is served
sudo cat /proc/fs/nfsd/versions   # -> -2 -3 +4 +4.1 +4.2
```

> `srv-longhorn\x2dbackup.mount` is the escaping of the `/srv/longhorn-backup`
> mount unit name. `BindsTo` is what makes an unmount also stop NFS; plain
> `RequiresMountsFor` only orders startup.

## 6. Reboot and unlock

The passphrase is not stored on the Pi, so after every reboot the dataset is
locked and `nfs-server` will not have started. To bring backups back:

```bash
sudo zfs load-key pool2025/longhorn-backup
sudo zfs mount pool2025/longhorn-backup
sudo systemctl start nfs-server
```

Check: `sudo zfs get -H -o value keystatus pool2025/longhorn-backup` should say
`available`, and `systemctl is-active nfs-server` should say `active`.

## 7. Verify on the Pi

```bash
# NFS export is present and squashed
sudo exportfs -v

# Only v4 is served
sudo cat /proc/fs/nfsd/versions        # -> -2 -3 +4 +4.1 +4.2

# RPC/NFS ports are listening (bind wide; the firewall restricts them)
sudo rpcinfo -p localhost              # nfs 2049, mountd 32767, rpcbind 111

# The drop rule is installed and the units are up
sudo nft list table inet nfs_lockdown
systemctl is-active nfs-server nfs-tailscale-only
```

Expect `100.64.0.0/10` as the only client, `root_squash`, and mountd on
`32767`.

---

## Cluster side

Already in Git:

- `clusters/clowder/tailscale/egress.yaml` — `ProxyClass` + `ProxyGroup`
  (`replicas: 2`, `tags: [tag:longhorn-egress]`), the `pi-nfs` `ExternalName`
  Service pointing at `raspberrypi.tail797fc.ts.net:2049`, and the
  `NetworkPolicy` that lets only the `longhorn-system` namespace and the
  operator pod reach the proxies.
- `clusters/clowder/longhorn/resources.yaml` — backup target
  `nfs://pi-nfs.tailscale.svc.cluster.local:/srv/longhorn-backup` with
  `nfsOptions=nfsvers=4.2,actimeo=1,hard,timeo=300,retry=2` (hard mount, so a
  transient NFS failure stalls rather than risking a partial write), plus the
  daily `RecurringJob` (`daily-backup`, `0 16 * * *`, retain 7) and
  `allowRecurringJobWhileVolumeDetached: true`.

After Flux reconciles:

```bash
kubectl wait svc/pi-nfs -n tailscale --for=condition=TailscaleEgressSvcReady=true --timeout=5m
kubectl get proxygroup longhorn-egress -n tailscale -o yaml   # check status.devices
```

Mount + write test from a throwaway pod. It must be privileged (NFS mount needs
`CAP_SYS_ADMIN`) and it fails fast, so a reported success actually means the
mount and a write worked:

```bash
kubectl -n longhorn-system run nfs-probe --rm -i --restart=Never \
  --image=longhornio/longhorn-manager:v1.7.2 \
  --overrides='{"spec":{"containers":[{"name":"nfs-probe","image":"longhornio/longhorn-manager:v1.7.2","imagePullPolicy":"IfNotPresent","securityContext":{"privileged":true},"command":["sh","-c","set -e; mkdir -p /mnt/pi; mount -t nfs -o nfsvers=4.2,hard,timeo=300,retry=2 pi-nfs.tailscale.svc.cluster.local:/srv/longhorn-backup /mnt/pi; touch /mnt/pi/.probe && rm /mnt/pi/.probe; umount /mnt/pi; echo NFS_WRITE_OK"]}]}}'
```

A successful run prints `NFS_WRITE_OK`; any mount/write failure exits non-zero
instead of being swallowed.

Then confirm the Longhorn UI shows a healthy **Backup Target**, take a manual
backup, and check the file appears on the Pi under
`/srv/longhorn-backup/backupstore/`.

---

## Monitoring (node_exporter + SMART)

The Pi runs two exporters, both bound to the tailnet interface only, and the
cluster's Prometheus scrapes them through the same egress proxy used for NFS.

On the Pi:

- **`prometheus-node-exporter`** — `ARGS` in
  `/etc/default/prometheus-node-exporter` is
  `--web.listen-address=100.89.252.121:9100 --collector.processes
  --collector.interrupts --collector.tcpstat`. The stock Drop-in that depended
  on the dead `wg-quick@cult-flat` interface is replaced by one with
  `After=`/`Wants=tailscaled.service`.
- **`smartmontools`** — `/etc/smartd.conf` monitors the disk explicitly
  (`/dev/sda -d sat -a -n standby -m root -M exec …`); the packaged
  `DEVICESCAN -d removable` never matched the USB-attached WD Red and smartd
  exited with "No devices to monitor".
- **`smartctl_exporter`** (v0.14.0, linux-arm64) — installed to
  `/usr/local/bin/smartctl_exporter` with a systemd unit running
  `--smartctl.device=/dev/sda;sat --smartctl.powermode-check=never
  --web.listen-address=100.89.252.121:9633 --smartctl.interval=5m`. The `sat`
  device type is required (the USB bridge fails auto-detect), and the power-mode
  check is disabled because the bridge misreports STANDBY, which otherwise makes
  smartctl bail with `exit(2)` and the exporter emit no per-device metrics.

```bash
systemctl is-active prometheus-node-exporter smartmontools smartctl_exporter
sudo ss -lntp | grep -E '9100|9633'
curl -s 100.89.252.121:9100/metrics | head
curl -s 100.89.252.121:9633/metrics | grep smartctl_device_smart_status
```

On the cluster (in Git):

- `clusters/clowder/tailscale/egress.yaml` — a `pi-metrics` egress `Service`
  (ports 9100 + 9633) sharing the `longhorn-egress` proxy; the `NetworkPolicy`
  also admits the Prometheus server pod.
- `clusters/clowder/monitoring/prometheus.yaml` — `extraScrapeConfigs` static
  jobs `raspberrypi-node` / `raspberrypi-smart`, plus
  `serverFiles.alerting_rules.yml` (`SmartDeviceUnhealthy`,
  `SmartTemperatureHigh`, `SmartMediaErrors`, `SmartctlExitStatusUnhealthy`, and
  exporter-`up` down alerts). Alertmanager still uses its null receiver, so these
  evaluate and display in the UIs but do not notify anywhere yet.

Verify:

```bash
kubectl -n tailscale get svc pi-metrics   # TailscaleEgressSvcReady=True
# in Prometheus/Grafana:
#   up{job=~"raspberrypi-.*"} == 1
```

The disk is polled every 5m with the power-mode check disabled, so it is spun up
on each poll (a WD Red is designed to be always-on).

---

## Troubleshooting

- **`ProxyGroup` never becomes ready** — the operator's OAuth client probably
  does not own `tag:longhorn-egress`. Fix step 1b.
- **`TailscaleEgressSvcReady` stays false** — check the operator logs:
  `kubectl -n tailscale logs deploy/operator`.
- **Mount succeeds but times out** — verify the Pi firewall allows 2049 on
  `tailscale0`, the export includes `100.64.0.0/10`, and the ACL grants
  `tag:longhorn-egress` → `tag:backup-pi:2049`.
- **Longhorn reports NFS mount errors** — ensure the target URL includes
  `nfsvers=4.2` (Longhorn's default options must be replaced in full, which the
  current URL does).
- **Backups succeed from your laptop but not the cluster** — the cluster path is
  the egress proxy, not plain tailnet access; a laptop reaching the Pi proves
  nothing about the pod path.
- **Backups run at MB/s** — the Pi is probably on Wi-Fi. Confirm it is wired and
  the radio is off (step 0): wired is ~1–2 ms RTT and tens of MB/s, Wi-Fi was
  ~100 ms and 1–7 MB/s.

## ZFS backup (TODO)

The Pi will also receive ZFS replication from the `zfs` namespace. Not set up
yet — the existing `clusters/clowder/zfs/*` jobs still target
`izzy@192.168.50.4`. When that work happens, document here:

- the ZFS pool/dataset that will receive the stream,
- the receive user and `authorized_keys`,
- how the cluster reaches the Pi for the SSH-based `zfs send` (it will need its
  own egress path, e.g. a second egress Service on port 22).
