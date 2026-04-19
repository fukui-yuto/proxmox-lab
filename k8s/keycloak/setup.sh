#!/bin/bash
# Keycloak 初期セットアップスクリプト
# 実行場所: Raspberry Pi (ansible 実行環境)
# 前提: install.sh 実行後、Harbor が起動済みであること

set -euo pipefail

NAMESPACE="keycloak"
KCADM="/opt/keycloak/bin/kcadm.sh"
ADMIN_PASS="Keycloak12345"
HARBOR_PASS="Harbor12345"

echo "=== STEP 1: CoreDNS カスタム設定 ==="
kubectl apply -f ../coredns-custom.yaml
kubectl rollout restart deployment/coredns -n kube-system
kubectl rollout status deployment/coredns -n kube-system --timeout=60s

echo "=== Keycloak Pod 起動待ち (最大 5 分) ==="
kubectl wait --for=condition=ready pod \
  -l app=keycloak \
  -n "${NAMESPACE}" \
  --timeout=300s

POD=$(kubectl get pod -n "${NAMESPACE}" -l app=keycloak -o jsonpath='{.items[0].metadata.name}')
echo "  Pod: ${POD}"

echo "=== STEP 2: kcadm ログイン ==="
kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  ${KCADM} config credentials \
  --server http://localhost:8080 --realm master \
  --user admin --password "${ADMIN_PASS}"

echo "=== STEP 3: homelab realm 作成 ==="
kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  ${KCADM} create realms \
  -s realm=homelab -s enabled=true -s displayName="Homelab"

echo "=== STEP 3b: groups client scope 作成 ==="
GROUPS_SCOPE_ID=$(kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  ${KCADM} create client-scopes -r homelab \
  -s name=groups -s protocol=openid-connect \
  -s 'attributes={"include.in.token.scope":"true","display.on.consent.screen":"false"}' \
  -i)
echo "  → groups scope ID: ${GROUPS_SCOPE_ID}"

echo "=== STEP 4: OIDC クライアント作成 ==="
kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  ${KCADM} create clients -r homelab \
  -s clientId=argocd -s enabled=true -s protocol=openid-connect \
  -s publicClient=false -s secret=argocd-keycloak-secret-2026 \
  -s 'redirectUris=["http://argocd.homelab.local/auth/callback"]' \
  -s 'webOrigins=["http://argocd.homelab.local"]' \
  -s standardFlowEnabled=true

kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  ${KCADM} create clients -r homelab \
  -s clientId=grafana -s enabled=true -s protocol=openid-connect \
  -s publicClient=false -s secret=grafana-keycloak-secret-2026 \
  -s 'redirectUris=["http://grafana.homelab.local/login/generic_oauth"]' \
  -s 'webOrigins=["http://grafana.homelab.local"]' \
  -s standardFlowEnabled=true

kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  ${KCADM} create clients -r homelab \
  -s clientId=harbor -s enabled=true -s protocol=openid-connect \
  -s publicClient=false -s secret=harbor-keycloak-secret-2026 \
  -s 'redirectUris=["http://harbor.homelab.local/c/oidc/callback"]' \
  -s 'webOrigins=["http://harbor.homelab.local"]' \
  -s standardFlowEnabled=true

kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  ${KCADM} create clients -r homelab \
  -s clientId=vault -s enabled=true -s protocol=openid-connect \
  -s publicClient=false -s secret=vault-keycloak-secret-2026 \
  -s 'redirectUris=["http://vault.homelab.local/ui/vault/auth/oidc/oidc/callback","http://vault.homelab.local/oidc/callback"]' \
  -s 'webOrigins=["http://vault.homelab.local"]' \
  -s standardFlowEnabled=true

kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  ${KCADM} create clients -r homelab \
  -s clientId=minio -s enabled=true -s protocol=openid-connect \
  -s publicClient=false -s secret=minio-keycloak-secret-2026 \
  -s 'redirectUris=["http://minio.homelab.local/oauth_callback"]' \
  -s 'webOrigins=["http://minio.homelab.local"]' \
  -s standardFlowEnabled=true

kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  ${KCADM} create clients -r homelab \
  -s clientId=kibana -s enabled=true -s protocol=openid-connect \
  -s publicClient=false -s secret=kibana-keycloak-secret-2026 \
  -s 'redirectUris=["http://kibana.homelab.local/oauth2/callback"]' \
  -s 'webOrigins=["http://kibana.homelab.local"]' \
  -s standardFlowEnabled=true

echo "=== STEP 5: グループ・管理ユーザー作成 ==="
kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  ${KCADM} create groups -r homelab -s name=homelab-admins

kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  ${KCADM} create users -r homelab \
  -s username=admin -s enabled=true -s email=admin@homelab.local -s emailVerified=true

kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  ${KCADM} set-password -r homelab \
  --username admin --new-password "${ADMIN_PASS}"

echo "=== STEP 6: groups mapper 追加 (全クライアント) ==="
for CLIENT in argocd grafana harbor vault minio kibana; do
  CLIENT_UUID=$(kubectl exec -n "${NAMESPACE}" "${POD}" -- /bin/sh -c \
    "${KCADM} get clients -r homelab -q clientId=${CLIENT} --fields id \
    | grep '\"id\"' | sed 's/.*\"id\" : \"\([^\"]*\)\".*/\1/'")

  kubectl exec -n "${NAMESPACE}" "${POD}" -- /bin/sh -c \
    "${KCADM} create clients/${CLIENT_UUID}/protocol-mappers/models -r homelab \
    -s name=groups -s protocol=openid-connect \
    -s protocolMapper=oidc-group-membership-mapper \
    -s 'config={\"full.path\":\"false\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"claim.name\":\"groups\",\"userinfo.token.claim\":\"true\"}'"

  # audience mapper 追加 (aud クレームに clientId を含める)
  kubectl exec -n "${NAMESPACE}" "${POD}" -- /bin/sh -c \
    "${KCADM} create clients/${CLIENT_UUID}/protocol-mappers/models -r homelab \
    -s name=audience-mapper -s protocol=openid-connect \
    -s protocolMapper=oidc-audience-mapper \
    -s 'config={\"included.client.audience\":\"${CLIENT}\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\"}'"

  echo "  → ${CLIENT} (${CLIENT_UUID}) mapper 追加完了"

  # groups client scope をデフォルトスコープに割り当て
  kubectl exec -n "${NAMESPACE}" "${POD}" -- \
    ${KCADM} update clients/${CLIENT_UUID}/default-client-scopes/${GROUPS_SCOPE_ID} -r homelab
done

echo "=== STEP 7: MinIO policy mapper 追加 ==="
MINIO_UUID=$(kubectl exec -n "${NAMESPACE}" "${POD}" -- /bin/sh -c \
  "${KCADM} get clients -r homelab -q clientId=minio --fields id \
  | grep '\"id\"' | sed 's/.*\"id\" : \"\([^\"]*\)\".*/\1/'")

kubectl exec -n "${NAMESPACE}" "${POD}" -- /bin/sh -c \
  "${KCADM} create clients/${MINIO_UUID}/protocol-mappers/models -r homelab \
  -s name=minio-policy -s protocol=openid-connect \
  -s protocolMapper=oidc-hardcoded-claim-mapper \
  -s 'config={\"claim.name\":\"policy\",\"claim.value\":\"consoleAdmin\",\"jsonType.label\":\"String\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"userinfo.token.claim\":\"true\"}'"
echo "  → MinIO policy mapper (consoleAdmin) 追加完了"

echo "=== STEP 8: Harbor OIDC 設定 ==="
HARBOR_POD=$(kubectl get pod -n harbor -l component=core -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n harbor "${HARBOR_POD}" -- curl -s -X PUT \
  -u "admin:${HARBOR_PASS}" http://localhost:8080/api/v2.0/configurations \
  -H 'Content-Type: application/json' \
  -d '{
    "auth_mode":"oidc_auth",
    "oidc_name":"Keycloak",
    "oidc_endpoint":"http://keycloak.homelab.local/realms/homelab",
    "oidc_client_id":"harbor",
    "oidc_client_secret":"harbor-keycloak-secret-2026",
    "oidc_scope":"openid,profile,email,groups",
    "oidc_verify_cert":false,
    "oidc_auto_onboard":true,
    "oidc_user_claim":"sub",
    "oidc_groups_claim":"groups",
    "oidc_admin_group":"homelab-admins"
  }'

echo "=== STEP 9: Vault OIDC 設定 ==="
VAULT_NAMESPACE="vault"
VAULT_SEALED=$(kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- vault status -format=json 2>/dev/null | grep -o '"sealed":[^,}]*' | grep -o 'true\|false')
if [ "${VAULT_SEALED}" = "false" ]; then
  # Vault が unsealed の場合のみ OIDC を設定
  # admin userpass でログインしてトークンを取得
  VAULT_TOKEN=$(kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- \
    vault login -method=userpass -format=json username=admin password=Vault12345 2>/dev/null \
    | grep -o '"client_token":"[^"]*"' | sed 's/"client_token":"//;s/"//')

  if [ -n "${VAULT_TOKEN}" ]; then
    kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- sh -c \
      "VAULT_TOKEN=${VAULT_TOKEN} vault auth enable oidc 2>&1" || echo "  (既に有効化済み)"

    kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- sh -c \
      "VAULT_TOKEN=${VAULT_TOKEN} vault write auth/oidc/config \
        oidc_discovery_url=\"http://keycloak.homelab.local/realms/homelab\" \
        oidc_client_id=\"vault\" \
        oidc_client_secret=\"vault-keycloak-secret-2026\" \
        default_role=\"keycloak\""

    kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- sh -c \
      "VAULT_TOKEN=${VAULT_TOKEN} vault write auth/oidc/role/keycloak \
        bound_audiences=\"vault\" \
        allowed_redirect_uris=\"http://vault.homelab.local/ui/vault/auth/oidc/oidc/callback\" \
        allowed_redirect_uris=\"http://vault.homelab.local/oidc/callback\" \
        user_claim=\"preferred_username\" \
        groups_claim=\"groups\" \
        policies=\"admin-policy\" \
        oidc_scopes=\"openid,profile,email,groups\""
    echo "  → Vault OIDC 設定完了"
  else
    echo "  WARN: Vault ログインに失敗 — OIDC 設定をスキップ (setup-auth.sh 実行後に再試行してください)"
  fi
else
  echo "  WARN: Vault is sealed — OIDC 設定をスキップ"
fi

echo ""
echo "=== セットアップ完了 ==="
echo "ArgoCD SSO:  http://argocd.homelab.local → Log in via Keycloak"
echo "Grafana SSO: http://grafana.homelab.local → Sign in with Keycloak"
echo "Harbor SSO:  http://harbor.homelab.local  → Login via OIDC Provider"
echo "Vault SSO:   http://vault.homelab.local   → Method: OIDC → Sign In"
echo "MinIO SSO:   http://minio.homelab.local   → Login with SSO"
echo "Kibana SSO:  http://kibana.homelab.local   → 自動認証 (oauth2-proxy)"
