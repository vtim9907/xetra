#!/usr/bin/env bash
# 日常更新腳本：在 production 機器的 repo checkout 裡執行。
# 做四件事：用目前的程式碼建 image → 推到 Harbor → 滾動更新 k8s → 等待完成。
# 資料（Postgres PVC、/app/data、/app/keys）完全不受影響。
#
# 用法：
#   export HARBOR_IMAGE=harbor.example.com/library/artex   # 只需設定一次（可寫進 ~/.bashrc）
#   ./k8s/update.sh
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

: "${HARBOR_IMAGE:?請先設定 HARBOR_IMAGE，例如 export HARBOR_IMAGE=harbor.example.com/library/artex}"
NS="${ARTEX_NAMESPACE:-artex}"
TAG="$(git rev-parse --short HEAD)"

echo "[*] building $HARBOR_IMAGE:$TAG ..."
docker build --build-arg ARTEX_VERSION="$TAG" -t "$HARBOR_IMAGE:$TAG" .

echo "[*] pushing to Harbor ..."
docker push "$HARBOR_IMAGE:$TAG"

echo "[*] rolling out on k8s (namespace: $NS) ..."
kubectl -n "$NS" set image deployment/artex artex="$HARBOR_IMAGE:$TAG"
kubectl -n "$NS" rollout status deployment/artex --timeout=300s

echo "[+] 部署完成：$HARBOR_IMAGE:$TAG"
echo "    回滾：kubectl -n $NS rollout undo deployment/artex"
