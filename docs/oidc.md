# Workload identity OIDC issuer

The cluster's service-account tokens are publicly verifiable at
`https://oidc.izzy.kiwi`. AWS IAM and Entra workload identity can trust this
issuer. The endpoint serves only:

- `/.well-known/openid-configuration`
- `/openid/v1/jwks`

It is exposed by the `ingress/public` Gateway and served as static files from
`clusters/clowder/oidc/`.

## Issuer rollout (two phases)

Do not apply the final `[public, VIP]` issuer order directly from the current
all-VIP state. A token minted by an updated apiserver (public issuer) would be
rejected by an apiserver that still only accepts the VIP issuer.

### Phase 1: stage `[VIP, public]`

Temporarily set the order in `talos/clowder/talconfig.yaml`:

```yaml
service-account-issuer:
  - https://192.168.100.200:6443
  - https://oidc.izzy.kiwi
```

Then generate and apply one control plane at a time, waiting for readiness
between nodes:

```sh
cd talos/clowder
export TALOSCONFIG=$(pwd)/clusterconfig/talosconfig
talhelper genconfig -s talsecret.sops.yaml
talosctl -n 192.168.100.201 apply-config -f clusterconfig/clowder-algernon.yaml
# wait for the node and apiserver to be healthy
talosctl -n 192.168.100.202 apply-config -f clusterconfig/clowder-rusty.yaml
# wait
talosctl -n 192.168.100.203 apply-config -f clusterconfig/clowder-leo.yaml
```

New tokens still use the VIP issuer, and every apiserver accepts both.

### Phase 2: switch to `[public, VIP]`

Ensure the public endpoint is live:

```sh
curl -fsS https://oidc.izzy.kiwi/.well-known/openid-configuration | jq .
curl -fsS https://oidc.izzy.kiwi/openid/v1/jwks | jq .
```

Restore the committed order (`public` first), regenerate, and apply one node at
a time again. Old apiservers still accept both issuers, so there is no
mixed-version rejection.

Verify:

```sh
kubectl -n kube-system get pod kube-apiserver-algernon -o yaml | grep service-account-issuer
kubectl create token default -n default --audience=sts.amazonaws.com --duration=10m \
  | cut -d. -f2 | base64 -d | jq '{iss,aud,sub}'
```

`iss` must be `https://oidc.izzy.kiwi`.

## Retiring the VIP issuer

The VIP issuer remains accepted for a bounded migration window. To remove it:

1. Ensure every control plane is on `[public, VIP]` and issuing public-issuer
   tokens.
2. Wait until all old-issuer tokens have expired. Inventory and revoke legacy
   secret-based service-account tokens, which do not expire.
3. Set `[public]`, regenerate, and roll one node at a time.

## JWKS rotation / rebuild

If the service-account signing key changes (cluster rebuild or manual rotation):

1. Get the new JWKS: `kubectl get --raw /openid/v1/jwks | jq -S .`.
2. Replace the `jwks` value in `clusters/clowder/oidc/site.yaml` with that
   output and apply.
3. Run `scripts/check-oidc-jwks.sh`.

`scripts/check-oidc-jwks.sh` compares the live signing key, the deployed
ConfigMap, and the public endpoint, and validates the discovery document. Run it
after any control-plane change or cluster rebuild.

## Entra later (manual)

No Azure resources are deployed by this repo. When adding Entra workload
identity by hand:

1. Create a UAMI (for Key Vault/Storage) or app registration (for Graph).
2. Add a federated identity credential:
   - issuer: `https://oidc.izzy.kiwi`
   - subject: `system:serviceaccount:<namespace>:<serviceaccount>`
   - audience: `api://AzureADTokenExchange`
3. Grant the narrowest Azure RBAC on the target.
4. In the app, project a token with audience `api://AzureADTokenExchange` and
   set `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_FEDERATED_TOKEN_FILE`.
