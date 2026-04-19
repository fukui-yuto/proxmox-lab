#!/bin/bash
# Vault 認証セットアップスクリプト
# 初期化・アンシール後に実行して userpass 認証を有効化する
# 実行場所: Raspberry Pi

set -euo pipefail

NAMESPACE="vault"
ADMIN_USER="admin"
ADMIN_PASS="Vault12345"

echo "=== Vault 状態確認 ==="
SEALED=$(kubectl exec -n "${NAMESPACE}" vault-0 -- vault status -format=json 2>/dev/null | grep -o '"sealed":[^,}]*' | grep -o 'true\|false')
if [ "${SEALED}" = "true" ]; then
  echo "ERROR: Vault is sealed. Unseal first."
  exit 1
fi

# Root Token の入力
echo ""
read -rsp "Root Token を入力してください (hvs.で始まる文字列): " ROOT_TOKEN
echo ""

# Root Token の検証
if ! kubectl exec -n "${NAMESPACE}" vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault auth list" &>/dev/null; then
  echo "ERROR: Root Token が無効です"
  exit 1
fi

echo "=== userpass 認証メソッドを有効化 ==="
kubectl exec -n "${NAMESPACE}" vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault auth enable userpass 2>&1" || echo "(既に有効化済み)"

echo "=== admin ポリシーを作成 ==="
kubectl exec -n "${NAMESPACE}" vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault policy write admin-policy - <<'EOF'
path \"*\" {
  capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\", \"sudo\"]
}
EOF"

echo "=== admin ユーザーを作成 ==="
kubectl exec -n "${NAMESPACE}" vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault write auth/userpass/users/${ADMIN_USER} password=${ADMIN_PASS} policies=admin-policy"

echo "=== 動作確認: userpass ログイン ==="
if kubectl exec -n "${NAMESPACE}" vault-0 -- sh -c "vault login -method=userpass username=${ADMIN_USER} password=${ADMIN_PASS}" &>/dev/null; then
  echo "OK: userpass ログイン成功"
else
  echo "ERROR: userpass ログイン失敗"
  exit 1
fi

echo "=== OIDC 認証メソッドを有効化 (Keycloak SSO) ==="
kubectl exec -n "${NAMESPACE}" vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault auth enable oidc 2>&1" || echo "(既に有効化済み)"

kubectl exec -n "${NAMESPACE}" vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault write auth/oidc/config \
  oidc_discovery_url=\"http://keycloak.homelab.local/realms/homelab\" \
  oidc_client_id=\"vault\" \
  oidc_client_secret=\"vault-keycloak-secret-2026\" \
  default_role=\"keycloak\""

kubectl exec -n "${NAMESPACE}" vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault write auth/oidc/role/keycloak \
  bound_audiences=\"vault\" \
  allowed_redirect_uris=\"http://vault.homelab.local/ui/vault/auth/oidc/oidc/callback\" \
  allowed_redirect_uris=\"http://vault.homelab.local/oidc/callback\" \
  user_claim=\"preferred_username\" \
  groups_claim=\"groups\" \
  policies=\"admin-policy\" \
  oidc_scopes=\"openid,profile,email,groups\""

echo "  → OIDC 認証設定完了 (Keycloak homelab realm)"

echo "=== Root Token を無効化 ==="
kubectl exec -n "${NAMESPACE}" vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault token revoke ${ROOT_TOKEN}"
echo "Root Token を無効化しました (今後は admin/${ADMIN_PASS} または OIDC でログイン)"

echo ""
echo "=================================================================="
echo "  セットアップ完了"
echo "  URL:      http://vault.homelab.local"
echo ""
echo "  [userpass 認証]"
echo "  Method:   Username"
echo "  Username: ${ADMIN_USER}"
echo "  Password: ${ADMIN_PASS}"
echo ""
echo "  [OIDC 認証 (Keycloak SSO)]"
echo "  Method:   OIDC"
echo "  → Sign In をクリックで Keycloak にリダイレクト"
echo "=================================================================="
