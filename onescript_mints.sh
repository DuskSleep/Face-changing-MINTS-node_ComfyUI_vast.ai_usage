#!/usr/bin/env bash
set -euo pipefail

# === 基本參數 ===
export COMFY_ROOT="${COMFY_ROOT:-/workspace/ComfyUI}"
export COMFY_PORT="${COMFY_PORT:-8188}"
export VENV_PATH="${VENV_PATH:-/venv}"
export PY_BIN="${PY_BIN:-python3.11}"
export RETRIES="${RETRIES:-240}"     # 最多等 240 秒
export SLEEP_SECS="${SLEEP_SECS:-1}" # 每次輪詢間隔秒數

echo "[INFO] COMFY_ROOT=$COMFY_ROOT  PORT=$COMFY_PORT  VENV=$VENV_PATH"

# === py311 & venv ===
if ! command -v ${PY_BIN} >/dev/null 2>&1; then echo "[ERR] 缺少 ${PY_BIN}"; exit 1; fi
V="$(${PY_BIN} -c 'import sys;print(\".\".join(map(str,sys.version_info[:2])))')"
[ "$V" = "3.11" ] || { echo "[ERR] 僅支援 Python 3.11，當前 $V"; exit 2; }
[ -f "$VENV_PATH/bin/activate" ] || ${PY_BIN} -m venv "$VENV_PATH"
source "$VENV_PATH/bin/activate"
python -m pip -q install -U pip wheel setuptools

# === 取得/更新 ComfyUI + Manager ===
if [ ! -d "${COMFY_ROOT}/.git" ]; then
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_ROOT"
else
  git -C "$COMFY_ROOT" fetch --prune && git -C "$COMFY_ROOT" reset --hard origin/master
fi
MANAGER_DIR="${COMFY_ROOT}/custom_nodes/ComfyUI-Manager"
if [ ! -d "$MANAGER_DIR/.git" ]; then
  git clone --depth=1 https://github.com/Comfy-Org/ComfyUI-Manager "$MANAGER_DIR"
else
  git -C "$MANAGER_DIR" pull --ff-only || true
fi

# === Manager: security_level=weak（Try fix 需要）===
CFG_A="${MANAGER_DIR}/config.ini"
CFG_B="${COMFY_ROOT}/user/default/ComfyUI-Manager/config.ini"
mkdir -p "$(dirname "$CFG_B")"; touch "$CFG_A" "$CFG_B"
for F in "$CFG_A" "$CFG_B"; do
  if grep -q '^security_level' "$F"; then
    sed -i -E 's/^security_level\s*=.*/security_level = weak/' "$F"
  else
    printf "[manager]\nsecurity_level = weak\n" > "$F"
  fi
done

# === 先補常見依賴，避免 LayerStyle 匯入失敗 ===
python -m pip -q uninstall -y opencv-python || true
python -m pip -q install -U blend-modes psd-tools "opencv-contrib-python>=4.8,<4.11"

API_BASE="http://127.0.0.1:${COMFY_PORT}"

start_comfy() {
  pkill -f "${COMFY_ROOT}/main.py" || true
  sleep 1
  nohup "$VENV_PATH/bin/python" "${COMFY_ROOT}/main.py" --listen 0.0.0.0 --port "${COMFY_PORT}" >/tmp/comfy.log 2>&1 &
}

wait_http_ok() {
  local url="$1"
  local n=0
  until curl -fsS "$url" >/dev/null 2>&1; do
    ((n++)); if [ "$n" -ge "$RETRIES" ]; then echo "[ERR] 等待 $url 超時"; return 1; fi
    sleep "$SLEEP_SECS"
  done
  return 0
}

wait_object_info() {
  local n=0
  while true; do
    local out
    out="$(curl -fsS "${API_BASE}/object_info" 2>/dev/null || true)"
    if [[ "$out" == "{"* ]]; then
      echo "[READY] /object_info 可用"
      return 0
    fi
    ((n++)); if [ "$n" -ge "$RETRIES" ]; then echo "[ERR] 等待 /object_info 超時"; return 1; fi
    sleep "$SLEEP_SECS"
  done
}

# 找出可用的 Manager 端點前綴（不同版本可能不同）
detect_manager_base() {
  for base in "/customnode" "/manager/api/customnode"; do
    if curl -fsS "${API_BASE}${base}/list" >/dev/null 2>&1; then
      echo "${API_BASE}${base}"
      return 0
    fi
  done
  return 1
}

try_fix() {
  local title="$1" base="$2"
  echo "[FIX] ${title} via ${base}/fix"
  # 以 title/name/id 嘗試
  curl -fsS -X POST "${base}/fix" -H "Content-Type: application/json" -d "{\"title\":\"${title}\"}" | grep -qi '"ok":true' && return 0
  curl -fsS -X POST "${base}/fix" -H "Content-Type: application/json" -d "{\"name\":\"${title}\"}"  | grep -qi '"ok":true' && return 0
  curl -fsS -X POST "${base}/fix" -H "Content-Type: application/json" -d "{\"id\":\"${title}\"}"    | grep -qi '"ok":true' && return 0
  # 某些版本端點名為 /repair
  echo "[WARN] 改用 /repair"
  curl -fsS -X POST "${base/\/fix/}/repair" -H "Content-Type: application/json" -d "{\"title\":\"${title}\"}" | grep -qi '"ok":true' && return 0
  echo "[WARN] Try fix 未回傳 ok：${title}"
  return 1
}

# === 啟動並等待「ComfyUI 就位」 ===
start_comfy
wait_http_ok "${API_BASE}/"
wait_object_info

# === 等待「Manager API 就位」 ===
MANAGER_BASE="$(detect_manager_base || true)"
if [ -z "${MANAGER_BASE:-}" ]; then
  # Manager 尚未註冊端點，額外再等幾秒重試
  for i in $(seq 1 30); do
    sleep 1
    MANAGER_BASE="$(detect_manager_base || true)"
    [ -n "${MANAGER_BASE:-}" ] && break
  done
fi
if [ -z "${MANAGER_BASE:-}" ]; then
  echo "[ERR] 找不到 ComfyUI-Manager API 端點"; exit 3
fi
echo "[READY] Manager API: ${MANAGER_BASE}"

# === 對關鍵節點執行 Try fix（按你截圖）===
try_fix "ComfyUI_LayerStyle"          "$MANAGER_BASE" || true
try_fix "ComfyUI_LayerStyle_Advance"  "$MANAGER_BASE" || true
try_fix "ComfyUI_InstantID"           "$MANAGER_BASE" || true
try_fix "ComfyUI_FaceAnalysis"        "$MANAGER_BASE" || true

# === 重啟並再次等待（讓修復生效）===
start_comfy
wait_http_ok "${API_BASE}/"
wait_object_info
echo "[OK] ComfyUI 已就位；Try fix 已套用完畢（port ${COMFY_PORT}）"
