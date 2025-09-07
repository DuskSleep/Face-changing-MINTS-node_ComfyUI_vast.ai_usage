#!/usr/bin/env bash
set -euo pipefail

# === 基本參數 ===
export COMFY_ROOT="${COMFY_ROOT:-/workspace/ComfyUI}"
export COMFY_PORT="${COMFY_PORT:-8188}"
export VENV_PATH="${VENV_PATH:-/venv}"
export PY_BIN="${PY_BIN:-python3.11}"
export CURL="curl -sS -H Content-Type:application/json"
export RETRY="--retry 4 --retry-delay 2 --fail -L"

echo "[INFO] COMFY_ROOT=$COMFY_ROOT  PORT=$COMFY_PORT  VENV=$VENV_PATH"

# === 準備 venv / 版本鎖到 py311 ===
if ! command -v ${PY_BIN} >/dev/null 2>&1; then echo "[ERR] 缺少 ${PY_BIN}"; exit 1; fi
V="$(${PY_BIN} -c 'import sys;print(".".join(map(str,sys.version_info[:2])))')"
[ "$V" = "3.11" ] || { echo "[ERR] 只支援 Python 3.11，目前 $V"; exit 2; }
[ -f "$VENV_PATH/bin/activate" ] || ${PY_BIN} -m venv "$VENV_PATH"
source "$VENV_PATH/bin/activate"
python -m pip -q install -U pip wheel setuptools

# === 取得/更新 ComfyUI 與 Manager（僅確保存在） ===
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

# === Manager 安全等級 weak（才能執行 Try fix）===
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

# === 先補最常見依賴（避免 LayerStyle import failed）===
python -m pip -q uninstall -y opencv-python || true
python -m pip -q install -U blend-modes psd-tools "opencv-contrib-python>=4.8,<4.11"

# === 啟 ComfyUI（讓 Manager API 可用）===
if ! $CURL http://127.0.0.1:${COMFY_PORT}/ >/dev/null 2>&1; then
  nohup "$VENV_PATH/bin/python" "$COMFY_ROOT/main.py" --listen 0.0.0.0 --port "$COMFY_PORT" >/tmp/comfy.log 2>&1 &
  for i in {1..60}; do sleep 1; $CURL http://127.0.0.1:${COMFY_PORT}/ >/dev/null 2>&1 && break || true; done
fi

API_BASE="http://127.0.0.1:${COMFY_PORT}"

# === 小工具：盡最大可能呼叫 Try fix（不同 Manager 版本端點略有差異）===
try_fix() {
  local title="$1"
  echo "[FIX] $title"
  # 常見端點1：/customnode/fix  (payload by title/name/id 擇一)
  $CURL -X POST "${API_BASE}/customnode/fix" -d "{\"title\":\"${title}\"}" | grep -qi '"ok":true' && return 0
  $CURL -X POST "${API_BASE}/customnode/fix" -d "{\"name\":\"${title}\"}"  | grep -qi '"ok":true' && return 0
  $CURL -X POST "${API_BASE}/customnode/fix" -d "{\"id\":\"${title}\"}"    | grep -qi '"ok":true' && return 0
  # 常見端點2：/manager/api/customnode/fix
  $CURL -X POST "${API_BASE}/manager/api/customnode/fix" -d "{\"title\":\"${title}\"}" | grep -qi '"ok":true' && return 0
  # 常見端點3：/customnode/repair
  $CURL -X POST "${API_BASE}/customnode/repair" -d "{\"title\":\"${title}\"}" | grep -qi '"ok":true' && return 0
  echo "[WARN] API Try fix 未回傳 ok，改用 requirements.txt 嘗試修復：${title}"
  # 後備：若該節點資料夾有 requirements 就安裝它
  local d="${COMFY_ROOT}/custom_nodes/${title}"
  [ -f "$d/requirements.txt" ] && python -m pip -q install -r "$d/requirements.txt" || true
}

# === 對四個關鍵節點執行 Try fix ===
try_fix "ComfyUI_LayerStyle"
try_fix "ComfyUI_LayerStyle_Advance"
try_fix "ComfyUI_InstantID"
try_fix "ComfyUI_FaceAnalysis"

# === 重新啟動，讓修復生效 ===
pkill -f "${COMFY_ROOT}/main.py" || true
sleep 1
nohup "$VENV_PATH/bin/python" "$COMFY_ROOT/main.py" --listen 0.0.0.0 --port "$COMFY_PORT" >/tmp/comfy.log 2>&1 &
echo "[OK] Try fix 已執行；ComfyUI 重啟於 ${COMFY_PORT}"
