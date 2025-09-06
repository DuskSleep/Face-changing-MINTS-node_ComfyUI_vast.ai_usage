#!/usr/bin/env bash
set -euo pipefail

VENV_PATH=${VENV_PATH:-/venv}
COMFY_ROOT=${COMFY_ROOT:-/opt/ComfyUI}
SCRIPTS=${SCRIPTS:-/opt/scripts}

# 修 InsightFace/antelopev2 路徑 & 下載模型（若啟用）
if [[ "${AUTO_DOWNLOAD:-1}" == "1" ]]; then
  "${SCRIPTS}/get_models.sh" || echo "[WARN] get_models.sh 有部分檔案下載失敗，稍後可重試。"
fi

# 再次確保 Manager 弱安全等級（避免映像外覆蓋）
CONF="${COMFY_ROOT}/custom_nodes/ComfyUI-Manager/config.ini"
mkdir -p "$(dirname "$CONF")"
if ! grep -q '^security_level=weak' "$CONF" 2>/dev/null; then
  echo "security_level=weak" > "$CONF"
fi

# 啟動 ComfyUI
source "${VENV_PATH}/bin/activate"
cd "${COMFY_ROOT}"

echo "[INFO] 启动 ComfyUI on ${COMFY_HOST:-0.0.0.0}:${COMFY_PORT:-8188}"
exec python main.py --listen "${COMFY_HOST:-0.0.0.0}" --port "${COMFY_PORT:-8188}" --auto-launch=false
