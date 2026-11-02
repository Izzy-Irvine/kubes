#!/usr/bin/env sh
set -eu

issuer="https://oidc.izzy.kiwi"
cm="$(kubectl -n oidc get deployment oidc -o jsonpath='{.spec.template.spec.volumes[?(@.name=="site")].configMap.name}')"

live="$(kubectl get --raw /openid/v1/jwks | jq -S '.keys |= sort_by(.kid)')"
deployed="$(kubectl -n oidc get configmap "$cm" -o jsonpath='{.data.jwks}' | jq -S '.keys |= sort_by(.kid)')"
public="$(curl -fsS "$issuer/openid/v1/jwks" | jq -S '.keys |= sort_by(.kid)')"

[ "$live" = "$deployed" ] || { echo "JWKS mismatch: deployed $cm != live signing key" >&2; exit 1; }
[ "$live" = "$public" ] || { echo "JWKS mismatch: public endpoint != live signing key" >&2; exit 1; }

curl -fsS "$issuer/.well-known/openid-configuration" | jq -e --arg issuer "$issuer" \
  '.issuer == $issuer and .jwks_uri == ($issuer + "/openid/v1/jwks")' >/dev/null

echo "OIDC metadata and JWKS match at $issuer"
