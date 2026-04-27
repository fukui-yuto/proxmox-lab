#!/bin/bash
# Jenkins ジョブを Cookiecutter テンプレートから生成するスクリプト
# 使い方: bash k8s/jenkins/create-job.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/cookiecutter-job-template"
JOBS_DIR="$SCRIPT_DIR/jobs"
VALUES_FILE="$SCRIPT_DIR/values.yaml"

# パラメータ入力
read -rp "ジョブ名 (英小文字・数字・ハイフン): " JOB_NAME
if [[ ! "$JOB_NAME" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]; then
    echo "エラー: ジョブ名は英小文字・数字・ハイフンのみ使用可能です" >&2
    exit 1
fi
if [ -d "$JOBS_DIR/$JOB_NAME" ]; then
    echo "エラー: ジョブ '$JOB_NAME' は既に存在します" >&2
    exit 1
fi

read -rp "説明 [テストジョブ]: " DESCRIPTION
DESCRIPTION="${DESCRIPTION:-テストジョブ}"

echo "言語を選択:"
echo "  1) python"
echo "  2) go"
echo "  3) node"
echo "  4) shell"
read -rp "番号 [1]: " LANG_CHOICE
case "${LANG_CHOICE:-1}" in
    1) LANGUAGE="python" ;;
    2) LANGUAGE="go" ;;
    3) LANGUAGE="node" ;;
    4) LANGUAGE="shell" ;;
    *) echo "エラー: 無効な選択です" >&2; exit 1 ;;
esac

read -rp "追加パッケージ (スペース区切り、不要なら空Enter): " PACKAGES

# 確認
echo ""
echo "=== 生成内容 ==="
echo "  ジョブ名:   $JOB_NAME"
echo "  説明:       $DESCRIPTION"
echo "  言語:       $LANGUAGE"
echo "  パッケージ: ${PACKAGES:-なし}"
echo "================"
read -rp "作成しますか？ (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
    echo "キャンセルしました"
    exit 0
fi

# Cookiecutter 実行
cookiecutter --no-input \
    -o "$JOBS_DIR" \
    "$TEMPLATE_DIR" \
    job_name="$JOB_NAME" \
    description="$DESCRIPTION" \
    language="$LANGUAGE" \
    packages="$PACKAGES"

echo "ファイル生成完了:"
ls -la "$JOBS_DIR/$JOB_NAME/"

# values.yaml にジョブ定義を追加
python "$TEMPLATE_DIR/register_job.py" "$JOB_NAME" "$DESCRIPTION" "$VALUES_FILE"

echo ""
echo "完了! 以下を実行してください:"
echo "  git add k8s/jenkins/jobs/$JOB_NAME/ k8s/jenkins/values.yaml"
echo "  git commit -m \"feat: add $JOB_NAME job ($LANGUAGE)\""
echo "  git push"
