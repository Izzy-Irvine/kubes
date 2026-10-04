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
   (`tag:k8s`). The tailnet ACL only lets `tag:longhorn-egress` reach the Pi on
   2049. No other cluster device (including the ingress proxies and the
   exit/subnet-router) can reach the Pi.
2. **Kubernetes `NetworkPolicy`.** The proxy pods accept connections only from
   the `longhorn-system` and `tailscale` namespaces. Other cluster workloads
   are dropped by Cilium even though they can resolve the Service name.
3. **Pi firewall.** `nfsd` is not bound to any specific interface (the kernel
   has no such knob), so nftables drops the NFS/RPC ports (`2049`, `111`, and
   the pinned `mountd` port `32767`) on anything other than `tailscale0`.
4. **NFS export.** The export is restricted to the tailnet CGNAT range, uses
   `root_squash`, and exposes only the backup directory.
5. **Mount guard.** `nfs-server` refuses to start unless the encrypted dataset
   is mounted, so a locked dataset can never be replaced by the plaintext
   directory underneath it.
6. **Encryption at rest.** The dataset is ZFS-encrypted (AES-256-GCM) with a
   passphrase that is not stored on the Pi.

Tailscale also encrypts the transport (WireGuard) and mutually authenticates
both ends.

> Because the tailnet currently uses the default allow-all policy, any *member*
> device (your laptop, phone) can also reach the Pi. That is out of scope for
> "nothing else **in the cluster**", but if you want to lock that down too, drop
> the broad `autogroup:member` rule in the ACL below and grant members only the
> ports they need.

## Prerequisites

- Raspberry Pi running Raspberry Pi OS / Debian, on the tailnet.
- Root (sudo) access.
- Tailscale admin console access (for the tag and ACL).

---

## 1. Tag the Pi and the egress proxy

The Pi is currently user-owned and untagged. Tagging it (and the egress proxy)
is what makes an identity-based ACL possible.

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
    // Members keep full access to tailnet devices and approved subnet routes.
    { "src": ["autogroup:member"], "dst": ["*"], "ip": ["*"] },
    // ...including the internet through an exit node.
    { "src": ["autogroup:member"], "dst": ["autogroup:internet"], "ip": ["*"] },

    // Operator <-> its tag:k8s proxies.
    { "src": ["tag:k8s-operator"], "dst": ["tag:k8s"], "ip": ["*"] },
    { "src": ["tag:k8s"], "dst": ["tag:k8s"], "ip": ["*"] },

    // Only the Longhorn egress proxy may reach the Pi, and only NFS.
    { "src": ["tag:longhorn-egress"], "dst": ["tag:backup-pi"], "ip": ["tcp:2049"] },

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

> Members still have `dst: ["*"]`, so your own devices can reach the Pi on any
> port. If you also want your personal devices blocked from the Pi's NFS, narrow
> the member grants to explicit destinations (`tag:k8s`, `tag:k8s-operator`,
> `autogroup:self`, `192.168.100.0/24`, `autogroup:internet`) plus
> `tag:backup-pi` on `tcp:22` only.

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
sudo systemctl enable --now nfs-server
sudo exportfs -ra
```

Confirm the kernel only serves v4:

```bash
sudo cat /proc/fs/nfsd/versions   # -> -2 -3 +4 +4.1 +4.2
```

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

---

## 5. Mount guard

When the encrypted dataset is locked, `/srv/longhorn-backup` reverts to a plain
(empty) directory on the unencrypted SD card, and NFS would happily export it.
This drop-in makes `nfs-server` refuse to start unless the real dataset is
mounted:

```bash
sudo tee /etc/systemd/system/nfs-server.service.d/10-require-longhorn-mount.conf >/dev/null <<'EOF'
[Service]
ExecStartPre=/usr/bin/bash -c 'mountpoint -q /srv/longhorn-backup || { echo "FATAL: /srv/longhorn-backup not mounted. Run: zfs load-key pool2025/longhorn-backup && zfs mount pool2025/longhorn-backup" >&2; exit 1; }'
EOF
sudo systemctl daemon-reload
```

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
  `NetworkPolicy` that lets only `longhorn-system` (and the operator) reach the
  proxies.
- `clusters/clowder/longhorn/resources.yaml` — backup target
  `nfs://pi-nfs.tailscale.svc.cluster.local:/srv/longhorn-backup` with
  `nfsOptions=nfsvers=4.2,...`, plus the weekly `RecurringJob`.

After Flux reconciles:

```bash
kubectl wait svc/pi-nfs -n tailscale --for=condition=TailscaleEgressSvcReady=true --timeout=5m
kubectl get proxygroup longhorn-egress -n tailscale -o yaml   # check status.devices
```

Mount test from a throwaway pod:

```bash
kubectl -n longhorn-system run nfs-probe --rm -it --restart=Never \
  --image=busybox --overrides='{"spec":{"containers":[{"name":"nfs-probe","image":"busybox","command":["sh","-c","mount -t nfs -o nfsvers=4.2 pi-nfs.tailscale.svc.cluster.local:/srv/longhorn-backup /mnt 2>&1 || true; ls -la /mnt; touch /mnt/.probe && echo OK"]}]}}'
```

Then confirm the Longhorn UI shows a healthy **Backup Target**, take a manual
backup, and check the file appears on the Pi under
`/srv/longhorn-backup/backupstore/`.

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

## ZFS backup (TODO)

The Pi will also receive ZFS replication from the `zfs` namespace. Not set up
yet — the existing `clusters/clowder/zfs/*` jobs still target
`izzy@192.168.50.4`. When that work happens, document here:

- the ZFS pool/dataset that will receive the stream,
- the receive user and `authorized_keys`,
- how the cluster reaches the Pi for the SSH-based `zfs send` (it will need its
  own egress path, e.g. a second egress Service on port 22).
