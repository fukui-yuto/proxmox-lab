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

echo "=== STEP 5: グループ・管理ユーザー作成 ==="
kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  ${KCADM} create groups -r homelab -s name=homelab-admins

kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  ${KCADM} create users -r homelab \
  -s username=admin -s enabled=true -s email=admin@homelab.local

kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  ${KCADM} set-password -r homelab \
  --username admin --new-password "${ADMIN_PASS}"

echo "=== STEP 6: groups mapper 追加 (argocd / grafana / harbor) ==="
for CLIENT in argocd grafana harbor; do
  CLIENT_UUID=$(kubectl exec -n "${NAMESPACE}" "${POD}" -- /bin/sh -c \
    "${KCADM} get clients -r homelab -q clientId=${CLIENT} --fields id \
    | grep '\"id\"' | sed 's/.*\"id\" : \"\([^\"]*\)\".*/\1/'")

  kubectl exec -n "${NAMESPACE}" "${POD}" -- /bin/sh -c \
    "${KCADM} create clients/${CLIENT_UUID}/protocol-mappers/models -r homelab \
    -s name=groups -s protocol=openid-connect \
    -s protocolMapper=oidc-group-membership-mapper \
    -s 'config={\"full.path\":\"false\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"claim.name\":\"groups\",\"userinfo.token.claim\":\"true\"}'"

  echo "  → ${CLIENT} (${CLIENT_UUID}) mapper 追加完了"
done

echo "=== STEP 7: Harbor OIDC 設定 ==="
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
    "oidc_user_claim":"preferred_username",
    "oidc_groups_claim":"groups",
    "oidc_admin_group":"homelab-admins"
  }'

echo ""
echo "=== セットアップ完了 ==="
echo "ArgoCD SSO:  http://argocd.homelab.local → Log in via Keycloak"
echo "Grafana SSO: http://grafana.homelab.local → Sign in with Keycloak"
echo "Harbor SSO:  http://harbor.homelab.local  → Login via OIDC Provider"
