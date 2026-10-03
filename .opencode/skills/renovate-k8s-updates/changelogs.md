# Changelog sources

Cached locations for upstream changelogs/release notes, so future Renovate runs
don't have to rediscover them. One row per app. Keep `source` pointing at the
specific releases or changelog page, and `notes` for quirks (e.g. groups releases,
no release notes, publishes only tags).

| app | chart / image | source | notes |
|---|---|---|---|
| cert-manager | jetstack/cert-manager | https://github.com/cert-manager/cert-manager/releases | Patch releases sometimes ship with empty GitHub release notes; check the compare link on the tag. |
| grafana | grafana-community/grafana | https://github.com/grafana-community/helm-charts/releases | Community fork; tags are `grafana-<version>`. Changelog is the release page for the `grafana-*` tag. |
| cilium | cilium/cilium | https://github.com/cilium/cilium/releases | Release body carries a "Summary of Changes" (bugfixes/minor) — read it directly; the chart version tracks the Cilium version. |
| prometheus | prometheus-community/helm-charts (chart `prometheus`) | https://github.com/prometheus-community/helm-charts/releases | Tags are `prometheus-<version>`; body lists bundled image bumps (alertmanager, node-exporter, kube-state-metrics, pushgateway). |
| prometheus-operator-crds | prometheus-community/helm-charts (chart `prometheus-operator-crds`) | https://github.com/prometheus-community/helm-charts/releases | Tags are `prometheus-operator-crds-<version>`; each bump bundles a `prometheus-operator/prometheus-operator` release (see its own releases). Patch bumps usually only change the CRD version annotation, no schema. |
| tailscale-operator | tailscale/tailscale | https://tailscale.com/changelog | GitHub release body is empty and just links here; find the "Tailscale Kubernetes Operator vX" subsection (operator notes only, separate from client notes). |
| nginx (bitnami) | oci://registry-1.docker.io/bitnamicharts/nginx | OCI chart — no reliable GitHub release notes | `bitnami/charts` CHANGELOG.md is stale/truncated. Diff the charts instead: `helm pull` both versions, untar, and `diff` `Chart.yaml`/`values.yaml`. |
