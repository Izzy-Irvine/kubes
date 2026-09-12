# Kubes

GitOps repo for a single Talos Kubernetes cluster (`clowder`). Flux reconciles
`clusters/clowder` from the `main` branch. A GitHub webhook (Receiver in
`clusters/clowder/flux-other/notification-webhook.yaml`) triggers reconciliation
within seconds of a push to `main`, with a 5-10m interval as fallback. Do not
`kubectl apply` manifests by hand — change files and commit.

There is no build, lint, or test suite. Verification is inspecting the cluster
with `kubectl` / `flux`.

## Layout

- `talos/` — Talos machine configs, generated with talhelper. `clusterconfig/*.yaml`
  and `talosconfig` are generated and gitignored. Setup/bootstrap steps live in
  `talos/readme.md`.
- `bases/<app>/` — shared kustomize base manifests.
- `clusters/clowder/<app>/` — per-app namespace. Each `kustomization.yaml` pulls in
  `../../../bases/<app>` and patches image tags, replicas, and hostnames. Add new
  apps as a new directory here.
- `Dockerfiles/` — Containerfiles for images used by manifests; built outside this repo.
- `scripts/` — helpers, e.g. `scripts/copy-off-pvc/run.sh` to pull PVC contents locally.

## Secrets (SOPS + age)

- Files matching `*.sops.yaml`, `*.k8s-sops.yaml`, or `*.sops.env` are age-encrypted.
  Edit with `sops <file>`, never by hand or with plain editors.
- Requires the age key: `export SOPS_AGE_KEY_FILE=~/age-key.txt` (recipients in
  `.sops.yaml`). Only `data`/`stringData` are encrypted in k8s secrets.
- Flux decrypts via the `sops-age` secret; keep the `decryption` block in
  `clusters/clowder/flux-system/gotk-sync.yaml`.
- Decrypted temp files (`.decrypted~*`) are gitignored — never commit plaintext secrets.

## Commands

- `nix-shell` — provides talosctl, kubectl, sops, age, helm, talhelper, flux, etc.
- Regenerate Talos config (from `talos/`): `talhelper genconfig -s talsecret.sops.yaml`,
  then `export TALOSCONFIG=$(pwd)/clusterconfig/talosconfig`.

## Cluster conventions

- Cilium is the CNI (kube-proxy disabled) and provides LB-IPAM/L2 announcements.
- Public traffic uses Gateway API, not ingress-nginx; certs via cert-manager DNS-01
  (Route 53). DNS for `izzy.kiwi` is in Route 53: wildcard `*.izzy.kiwi` CNAMEs to
  `home.izzy.kiwi`, which the `ddns` deployment keeps pointing at the home WAN IP.
  The router port-forwards to the cluster's Gateway LB (`192.168.100.210`).
- Adding a public hostname needs a Gateway listener + `Certificate` in
  `clusters/clowder/ingress/gateways.yaml` — an HTTPRoute alone won't serve it.
- `clusters/clowder/flux-system/gotk-*.yaml` is Flux-generated — do not edit.

## Commit messages

Prefix commit messages with the area of the project you're working on.

Examples:

- `Nginx: Set replicas 5 from 3`
- `Beans minecraft: updated to version 1.20 from 1.19`
