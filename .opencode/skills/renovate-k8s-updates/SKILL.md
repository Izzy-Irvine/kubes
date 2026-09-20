---
name: renovate-k8s-updates
description: Handle weekly Renovate dependency PRs for the clowder cluster. Inventories every update, checks upstream changelogs for breaking or risky changes, classifies risk, applies any needed compatibility fixes, deploys them, merges the Renovate PR, and monitors the Flux rollout to completion or rollback. Use when there is an open PR labelled `renovate`, or when the user asks to patch/upgrade the cluster from Renovate.
---

# Renovate K8s Updates

Process Renovate upgrades for the `clowder` cluster safely. Renovate opens PRs on
Friday evenings (Pacific/Auckland); you handle them by reviewing, fixing, merging,
and monitoring.

The goal is to keep the cluster current while never losing user-facing data and
avoiding long outages. Brief downtime for stateless things is fine.

## When to use

- An open GitHub PR labelled `renovate` exists (check with `gh pr list`).
- The user asks to "do the Renovate updates" / "patch the cluster".

## Preconditions

Verify all of these before touching anything. Stop and report if any fail.

1. `main` is up to date and clean:
   - `git status --short --branch` (must be on `main`, no uncommitted changes)
   - `git pull --ff-only origin main`
2. Tools reachable: `gh auth status`, `kubectl config current-context`,
   `flux version --client`. If any CLI tool is missing, get it from the repo's
   `shell.nix` via `nix-shell` (it provides `talosctl`, `kubectl`, `sops`, `age`,
   `kubernetes-helm`, `talhelper`, `fluxcd`, etc.). Run commands inside
   `nix-shell` when a tool is not on PATH.
3. Cluster reachable and Flux healthy:
   - `flux get kustomizations -A` — every Kustomization `Ready=True`.
   - `flux get helmreleases -A` — every HelmRelease `Ready=True`.
4. **Capture a baseline of what is already failing.** The cluster is not always fully
   healthy before you start, and you must be able to tell your changes apart from
   pre-existing breakage. Record the current state *before* touching anything:
   - `flux get kustomizations -A` / `flux get helmreleases -A` — note any not `Ready`.
   - `kubectl get pods -A --field-selector=status.phase!=Running` — note non-Running.
   - `kubectl get deployments,statefulsets -A` — note anything not fully available.
   - `kubectl get pvc -A` — note anything not `Bound`.
   Keep this baseline and compare against it in steps 8 and 9. Anything already
   broken is **not** caused by your change; do not try to fix unrelated pre-existing
   failures as part of this workflow unless the user asks. If Flux itself is broadly
   unhealthy, stop and report rather than layering upgrades on top.
5. SOPS key available for any secret edits: `echo $SOPS_AGE_KEY_FILE` and the file
   exists (see the repo `AGENTS.md`). Never edit encrypted files with a plain editor.

## Workflow

### 1. Find the PR(s)

```sh
gh pr list --state open --label renovate --json number,title,headRefName,createdAt,url
```

Renovate groups updates by `renovate.json` (`helm charts`, `container images`), so
there may be more than one PR. Process them one at a time, smallest blast radius
first. Read the PR body for the change table and any embedded release notes:

```sh
gh pr view <n> --json number,title,body,headRefName,url
gh pr diff <n>
```

### 2. Inventory the updates

Build a table of every package changed across the PR:

| Package | Change | Update type | Files | Stateful? |
|---|---|---|---|---|
| cert-manager | v1.21.1 → v1.21.2 | patch | clusters/clowder/ingress/cert-manager.yaml | TLS certs |
| grafana | 13.2.3 → 13.2.4 | patch | clusters/clowder/monitoring/grafana.yaml | monitoring (expendable) |

Classify the update type as patch / minor / major / digest by diffing the version
numbers yourself. Note which workloads actually use each package
(`flux get helmreleases -A`, `kubectl get deploy,sts -A`).

### 3. Research changelogs

For each package, find the authoritative release notes / changelog and read the
entries for the range being upgraded. Sources, in order:

1. Release notes embedded in the Renovate PR body.
2. The upstream repo's GitHub Releases and `compare` links (`gh release view`,
   `gh api repos/<owner>/<repo>/releases`).
3. The project's `CHANGELOG.md`, upgrade notes, or migration guides.
4. Upstream issues/PRs for anything that looks breaking.

Look specifically for: major version bumps, removed/renamed config keys, CRD or API
version changes, changed default values, database/state migrations, and changes to
how state or storage is handled.

**Cache every changelog location you find in `changelogs.md`** (same directory as
this skill). Add a row so future runs do not need to search again:

```
| app | chart/image | source | notes |
```

Only add entries you have actually resolved and verified. Update the `notes` when a
source changes or an app starts publishing elsewhere.

### 4. Classify risk

Use the changelog findings plus the workload inventory.

The only thing that is truly unacceptable is **data loss in the key areas listed
below**. Small amounts of downtime are acceptable everywhere else, including
user-facing services — do not escalate purely because a workload will restart or be
briefly unavailable.

**EXTREME — always stop and ask the user first. Do not proceed autonomously:**

- Anything that could lose **Longhorn** volumes or the PVCs of **user-facing
  services or game servers**. Examples of data that must not be lost:
  `beans/lobby`, `chungus-amoug-us-minecraft-datadir`, `palworld-data-2`,
  `odin-2/redis`, `omada-data`, `global-game-jam-2025` PVCs, or any new
  user-facing PVC. Treat anything storage-adjacent the same way.
- Changes to Longhorn, StorageClasses, StatefulSet storage, or PVC/PV handling.
- Anything with a documented risk of data migration or volume format change.

Monitoring-stack data is explicitly **not** sensitive: Grafana, Prometheus, Loki,
and Alertmanager PVCs may be lost. Do not block on those.

**HIGH — stop and ask the user first:**

- Major version bumps, or breaking config/CRD/API/schema changes.
- `cert-manager` (public TLS), `cilium` (networking/CNI), `tailscale`,
  `omada` (migration-sensitive), `prometheus-operator-crds`.
- Anything where the changelog is unclear about breaking behavior.

**LOW / MEDIUM — proceed autonomously:**

- Patch and minor bumps with no breaking changes.
- Stateless workloads. Small amounts of downtime are acceptable.

When in doubt, escalate to the user. A pause is cheap; lost data is not.

### 5. Prepare fixes

Most upgrades need no code change and you can go straight to step 6. If the upgrade
requires a manifest change (new value, removed key, image/config adjustment), make it
following repo conventions:

- Edit files under `bases/<app>/` or `clusters/clowder/<app>/`. Never edit
  `clusters/clowder/flux-system/gotk-*.yaml` (Flux-generated).
- Secrets: edit with `sops <file>` only.
- Do not `kubectl apply` anything. Git is the source of truth.
- Commit message prefix is the project area, e.g.
  `Cert-manager: set webhook cert duration` (see repo `AGENTS.md`).

**Prefer landing fixes on `main` separately from the version bump** — smaller,
easier-to-roll-back changes. Push the fix commit(s) to `main`, let them deploy, and
monitor (step 6) before merging the Renovate PR.

Only commit the fix onto the `renovate/*` branch when the fix and the bump must land
at exactly the same time (e.g. a config key that only exists in the new version and
breaks the old one). In that case, note why in the PR.

### 6. Push and monitor fixes on main

```sh
git push origin main
```

Pushing to `main` fires the GitHub webhook, which reconciles Flux within seconds.
**Do not run `flux reconcile`** — the webhook and the 5–10m poll handle it. Wait for
the natural reconcile, then verify:

```sh
flux get kustomizations -A
flux get helmreleases -A
kubectl get pods -A --field-selector=status.phase!=Running
kubectl rollout status deploy/<name> -n <ns> --timeout=300s
```

Repeat the polls until every Kustomization/HelmRelease is `Ready` and workloads are
healthy, or a bounded wait (roughly 10–15 minutes) elapses. If a fix cannot be made
to converge, revert it (step 9) before proceeding.

### 7. Merge the Renovate PR

Once fixes are deployed and healthy:

```sh
gh pr merge <n> --merge
```

Use a merge commit (the repo history uses merge commits). Do not delete the branch —
`deleteBranchOnMerge` is off and Renovate may want it.

Note: the webhook only watches the `main` GitRepository, so a push to the
`renovate/*` branch does not deploy. Only the merge to `main` triggers a rollout.

### 8. Monitor the rollout

After merging, wait for the webhook-driven reconcile and verify the new versions
actually rolled out. Success criteria:

- `flux get kustomizations -A` and `flux get helmreleases -A` all `Ready=True` with
  the expected new revision.
- No pods stuck in `CrashLoopBackOff`, `ImagePullBackOff`, `Pending`, or not `Ready`.
- `kubectl rollout status` succeeds for affected Deployments/StatefulSets.
- All PVCs still `Bound` (`kubectl get pvc -A`), especially user-facing ones.
- If `cert-manager` changed: Certificates still `Ready` and public endpoints serve;
  check `kubectl get certificates -A` and `kubectl get challenges -A`.
- If Gateway/Cilium/Tailscale changed: check HTTPRoutes/Gateways and connectivity.

Poll on a bounded loop (about 10–15 minutes), giving Flux time between checks. Do not
use `flux reconcile`; wait for the webhook or the 5–10m poll.

**Compare everything against the baseline from precondition 4.** A workload that was
already broken before you started is not a regression — don't chase it or roll back
for it. Only act on failures that are new relative to the baseline.

### 9. Failure and rollback

If something fails, first check it against the baseline from precondition 4. If it was
already failing before your change, it is not yours to fix here — note it and move on.
For genuinely new failures:

1. Identify the failing commit — the Renovate merge commit, or a fix commit on
   `main`.
2. Try a forward fix only if it is small, clearly safe, and not storage-related.
   Commit, push to `main`, and re-monitor.
3. Otherwise roll back:
   ```sh
   git revert <commit>          # add -m 1 if reverting a merge commit
   git push origin main
   ```
   Then wait for the webhook reconcile and confirm health.
4. Never force-push. Never `kubectl apply`/`helm rollback` to paper over it.
5. Renovate PRs are "immortal": a reverted/closed upgrade will reappear later, which
   is fine — it means the next attempt starts clean.

If the failure risks data loss, stop immediately, do not attempt risky fixes, and ask
the user.

### 10. Report

Summarize back to the user:

- Which PR(s) were processed and what each package went from → to.
- The risk call for each update, and why anything escalated.
- Fix commits made (and whether they landed on `main` or the PR branch).
- Merge result and PR link.
- Rollout outcome: Kustomizations/HelmReleases ready, workloads healthy, PVCs bound.
- Any rollback performed and its result.
- Any new `changelogs.md` entries added.
- Any pre-existing failures from the baseline that remain (and are therefore not to
  be blamed on these updates).

## Hard rules

- Never risk losing Longhorn or user-facing/game-server PVC data. If an upgrade
  might, stop and ask.
- Never edit `clusters/clowder/flux-system/gotk-*.yaml` or any `*.sops.*` file by hand.
  Secrets go through `sops`.
- Never `kubectl apply` / `kubectl delete` / `helm upgrade` by hand. Change files and
  commit; Flux deploys.
- Do not run `flux reconcile` after a push; the webhook already triggers reconcile.
- Never force-push, never rewrite `main` history.
- Escalate high/extreme risk to the user instead of guessing.

## Reference

- Repo: `Izzy-Irvine/kubes`, cluster `clowder`, Flux reconciles `clusters/clowder`.
- Renovate config: `renovate.json` (grouping, disabled packages, Friday schedule).
- Existing risky/special cases already held by Renovate: Longhorn, cilium
  minor/major, omada minor/major, Flux bootstrap manifests, `ghcr.io/tomay0/odincards`.
- Changelog cache: `changelogs.md` in this directory.
- Repo conventions and commands: root `AGENTS.md`.
