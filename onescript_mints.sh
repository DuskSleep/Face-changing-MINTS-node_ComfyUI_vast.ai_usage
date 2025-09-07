#!/usr/bin/env bash
set -euo pipefail

# ===== 基本參數 =====
export COMFY_ROOT="${COMFY_ROOT:-/workspace/ComfyUI}"
export COMFY_PORT="${COMFY_PORT:-8188}"
export VENV_PATH="${VENV_PATH:-/venv}"
export PY_BIN="${PY_BIN:-python3.11}"
export WORKFLOW_URL="${WORKFLOW_URL:-https://raw.githubusercontent.com/DuskSleep/Face-changing-MINTS-node_ComfyUI_vast.ai_usage/main/%E6%8D%A2%E8%84%B8-MINTS.json}"
export RETRIES="${RETRIES:-240}"     # 最多等待 240 秒
export SLEEP_SECS="${SLEEP_SECS:-1}" # 每次輪詢間隔

echo "[INFO] COMFY_ROOT=$COMFY_ROOT  PORT=$COMFY_PORT  VENV=$VENV_PATH"
mkdir -p "$COMFY_ROOT/user/default/workflows" "$COMFY_ROOT/models/checkpoints" \
         "$COMFY_ROOT/models/instantid" "$COMFY_ROOT/models/controlnet" \
         "$COMFY_ROOT/models/upscale_models" "$COMFY_ROOT/models/insightface/models" \
         "$COMFY_ROOT/custom_nodes"

# ===== 嚴格鎖 Python 3.11 + venv =====
if ! command -v ${PY_BIN} >/dev/null 2>&1; then echo "[ERR] 缺少 ${PY_BIN}"; exit 1; fi
V="$(${PY_BIN} -c 'import sys;print(".".join(map(str,sys.version_info[:2])))')"
[ "$V" = "3.11" ] || { echo "[ERR] 只支援 Python 3.11，目前 $V"; exit 2; }
[ -f "$VENV_PATH/bin/activate" ] || ${PY_BIN} -m venv "$VENV_PATH"
source "$VENV_PATH/bin/activate"
python -m pip -q install -U pip wheel setuptools

# ===== 取得/更新 ComfyUI + Manager =====
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

# ===== Manager 安全等級 weak（Try fix/安裝 GitHub 需要）=====
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

# ===== 下載工作流到 ComfyUI =====
WF_NAME="$(basename "${WORKFLOW_URL}")"
curl -fsSL "${WORKFLOW_URL}" -o "${COMFY_ROOT}/user/default/workflows/${WF_NAME}"
echo "[OK] Workflow saved to user/default/workflows/${WF_NAME}"

# ===== 依賴（避免 LayerStyle / InstantID 匯入失敗）=====
python -m pip -q uninstall -y opencv-python || true
python -m pip -q install -U \
  blend-modes psd-tools "opencv-contrib-python>=4.8,<4.11" \
  "onnx>=1.16" "onnxruntime-gpu>=1.19,<1.22" \
  "insightface==0.7.3" "mediapipe>=0.10" tqdm requests

# ===== 公用函式 =====
API_BASE="http://127.0.0.1:${COMFY_PORT}"

start_comfy() {
  pkill -f "${COMFY_ROOT}/main.py" || true
  sleep 1
  nohup "$VENV_PATH/bin/python" "${COMFY_ROOT}/main.py" --listen 0.0.0.0 --port "${COMFY_PORT}" >/tmp/comfy.log 2>&1 &
}

wait_http_ok() {
  local url="$1" n=0
  until curl -fsS "$url" >/dev/null 2>&1; do
    ((n++)); if [ "$n" -ge "$RETRIES" ]; then echo "[ERR] 等待 $url 超時"; return 1; fi
    sleep "$SLEEP_SECS"
  done
}

wait_object_info() {
  local n=0 out=""
  while true; do
    out="$(curl -fsS "${API_BASE}/object_info" 2>/dev/null || true)"
    [[ "$out" == "{"* ]] && { echo "[READY] /object_info"; return 0; }
    ((n++)); if [ "$n" -ge "$RETRIES" ]; then echo "[ERR] /object_info 超時"; return 1; fi
    sleep "$SLEEP_SECS"
  done
}

detect_manager_base() {
  for base in "/manager/api/customnode" "/customnode" "/api/customnode"; do
    curl -fsS "${API_BASE}${base}/list" >/dev/null 2>&1 && { echo "${API_BASE}${base}"; return 0; }
  done
  return 1
}

manager_install_repo() {
  local base="$1" url="$2"
  # Manager 安裝（git-clone）
  curl -fsS -X POST "${base}/install" -H "Content-Type: application/json" \
    -d "{\"files\":[\"${url}\"],\"install_type\":\"git-clone\",\"reference\":\"${url}\",\"title\":\"auto\",\"id\":\"auto\"}" \
    | grep -qi '"ok":true'
}

git_clone_fallback() {
  local url="$1" dest="$2"
  rm -rf "$dest"
  git clone --depth=1 "$url" "$dest"
  [ -f "$dest/requirements.txt" ] && python -m pip -q install -r "$dest/requirements.txt" || true
  [ -f "$dest/install.py" ] && python "$dest/install.py" || true
}

try_fix() {
  local base="$1" title="$2"
  echo "[FIX] ${title}"
  curl -fsS -X POST "${base}/fix" -H "Content-Type: application/json" -d "{\"title\":\"${title}\"}" | grep -qi '"ok":true' && return 0
  curl -fsS -X POST "${base}/repair" -H "Content-Type: application/json" -d "{\"title\":\"${title}\"}" | grep -qi '"ok":true' && return 0
  return 1
}

# ===== 先啟 ComfyUI 並等待 API 就位 =====
start_comfy
wait_http_ok "${API_BASE}/"
wait_object_info
MANAGER_BASE="$(detect_manager_base || true)"
if [ -z "${MANAGER_BASE:-}" ]; then
  # 再多等幾秒讓 Manager 載入
  for _ in $(seq 1 30); do sleep 1; MANAGER_BASE="$(detect_manager_base || true)"; [ -n "${MANAGER_BASE:-}" ] && break; done
fi
[ -n "${MANAGER_BASE:-}" ] || { echo "[ERR] 找不到 ComfyUI-Manager API"; exit 3; }
echo "[READY] Manager API = ${MANAGER_BASE}"

# ===== 依你紀錄安裝缺失節點（Manager→失敗才 git）=====
declare -A REPOS=(
  ["comfy_mtb"]="https://github.com/melMass/comfy_mtb"
  ["ComfyMath"]="https://github.com/evanspearman/ComfyMath"
  ["ComfyUI_Comfyroll_CustomNodes"]="https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes"
  ["comfyui-various"]="https://github.com/jamesWalker55/comfyui-various"
  ["ComfyUI_LayerStyle"]="https://github.com/chflame163/ComfyUI_LayerStyle"
  ["ComfyUI_LayerStyle_Advance"]="https://github.com/chflame163/ComfyUI_LayerStyle_Advance"
  ["ComfyUI_InstantID"]="https://github.com/cubiq/ComfyUI_InstantID"
  ["ComfyUI_FaceAnalysis"]="https://github.com/cubiq/ComfyUI_FaceAnalysis"
)
for name in "${!REPOS[@]}"; do
  dest="${COMFY_ROOT}/custom_nodes/${name}"
  if [ ! -d "$dest" ]; then
    echo "[INFO] 安裝 ${name}"
    if ! manager_install_repo "${MANAGER_BASE}" "${REPOS[$name]}"; then
      echo "[WARN] Manager 安裝失敗，改用 git：${name}"
      git_clone_fallback "${REPOS[$name]}" "$de
