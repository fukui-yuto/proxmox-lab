#!/bin/bash
# Jenkins ジョブを削除するスクリプト
# 使い方: bash k8s/jenkins/delete-job.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/cookiecutter-job-template"
JOBS_DIR="$SCRIPT_DIR/jobs"
VALUES_FILE="$SCRIPT_DIR/values.yaml"

# 既存ジョブ一覧を表示
echo "=== 登録済みジョブ ==="
for dir in "$JOBS_DIR"/*/; do
    basename "$dir"
done
echo "======================"
echo ""

# 削除するジョブ名を入力
read -rp "削除するジョブ名: " JOB_NAME

if [ ! -d "$JOBS_DIR/$JOB_NAME" ]; then
    echo "エラー: ジョブ '$JOB_NAME' が見つかりません" >&2
    exit 1
fi

# 確認
read -rp "ジョブ '$JOB_NAME' を削除しますか？ (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
    echo "キャンセルしました"
    exit 0
fi

# ジョブディレクトリ削除
rm -rf "$JOBS_DIR/$JOB_NAME"
echo "削除: $JOBS_DIR/$JOB_NAME/"

# values.yaml からジョブ定義を削除
python "$TEMPLATE_DIR/unregister_job.py" "$JOB_NAME" "$VALUES_FILE"

echo ""
echo "完了! 以下を実行してください:"
echo "  git add -A k8s/jenkins/jobs/$JOB_NAME/ k8s/jenkins/values.yaml"
echo "  git commit -m \"feat: remove $JOB_NAME job\""
echo "  git push"
echo ""
echo "push 後、ArgoCD sync → JCasC リロードで Jenkins からも自動削除されます。"
