# Changelog sources

Cached locations for upstream changelogs/release notes, so future Renovate runs
don't have to rediscover them. One row per app. Keep `source` pointing at the
specific releases or changelog page, and `notes` for quirks (e.g. groups releases,
no release notes, publishes only tags).

| app | chart / image | source | notes |
|---|---|---|---|
| cert-manager | jetstack/cert-manager | https://github.com/cert-manager/cert-manager/releases | Patch releases sometimes ship with empty GitHub release notes; check the compare link on the tag. |
| grafana | grafana-community/grafana | https://github.com/grafana-community/helm-charts/releases | Community fork; tags are `grafana-<version>`. Changelog is the release page for the `grafana-*` tag. |
