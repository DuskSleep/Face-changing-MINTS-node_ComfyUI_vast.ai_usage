#!/usr/bin/env bash
set -euo pipefail

# === 可調參數（預設到 /workspace）===
export COMFY_ROOT="${COMFY_ROOT:-/workspace/ComfyUI}"
export COMFY_PORT="${COMFY_PORT:-8188}"
export VENV_PATH="${VENV_PATH:-/venv}"
export PY_BIN="${PY_BIN:-python3.11}"
export CURL_RETRY="--retry 5 --retry-delay 2 --fail -L"
export WORKFLOW_URL="${WORKFLOW_URL:-https://raw.githubusercontent.com/DuskSleep/Face-changing-MINTS-node_ComfyUI_vast.ai_usage/main/%E6%8D%A2%E8%84%B8-MINTS.json}"

# === Python 版本嚴格鎖 3.11 ===
if ! command -v ${PY_BIN} >/dev/null 2>&1; then
  echo "[ERR] 找不到 ${PY_BIN}，請先安裝 Python 3.11"; exit 1
fi
PYV="$(${PY_BIN} -c 'import sys;print(".".join(map(str,sys.version_info[:2])))')"
if [ "$PYV" != "3.11" ]; then
  echo "[ERR] 偵測到 Python ${PYV}，此堆疊僅支援 3.11"; exit 2
fi

# === 路徑就緒 ===
mkdir -p "$COMFY_ROOT" "$VENV_PATH" \
         "$COMFY_ROOT/models/checkpoints" \
         "$COMFY_ROOT/models/instantid" \
         "$COMFY_ROOT/models/controlnet" \
         "$COMFY_ROOT/models/upscale_models" \
         "$COMFY_ROOT/models/insightface/models" \
         "$COMFY_ROOT/user/default/workflows" \
         "$COMFY_ROOT/custom_nodes"

# === venv 就緒 ===
if [ ! -f "$VENV_PATH/bin/activate" ]; then
  ${PY_BIN} -m venv "$VENV_PATH"
fi
source "$VENV_PATH/bin/activate"
python -m pip install -U pip wheel setuptools

# === 安裝/更新 ComfyUI 與 Manager ===
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

# === 降低安全等級到 weak（允許 GitHub 安裝）===
CONFIG_A="${MANAGER_DIR}/config.ini"
CONFIG_B="${COMFY_ROOT}/user/default/ComfyUI-Manager/config.ini"
mkdir -p "$(dirname "$CONFIG_B")"
touch "$CONFIG_A" "$CONFIG_B"
for CFG in "$CONFIG_A" "$CONFIG_B"; do
  if grep -q '^security_level' "$CFG"; then
    sed -i -E 's/^security_level\s*=.*/security_level = weak/' "$CFG"
  else
    printf "[manager]\nsecurity_level = weak\n" > "$CFG"
  fi
done

# === 依賴（InstantID / InsightFace / Mediapipe / LayerStyle Advance）===
# onnxruntime-gpu 1.19+ 針對 CUDA 12.x；使用 contrib 版 OpenCV 以含 ximgproc
python -m pip uninstall -y opencv-python || true
python -m pip install -U \
  "onnx>=1.16" "onnxruntime-gpu>=1.19" \
  "insightface==0.7.3" "mediapipe>=0.10" \
  "tqdm" "requests" \
  "blend-modes>=2.2.0" "psd-tools" "hydra-core==1.3.2" "docopt==0.6.2" \
  "opencv-contrib-python>=4.8,<4.11"

# === 先啟一次 ComfyUI 讓 Manager API 可用（若已啟動則略過）===
if ! curl -s "http://127.0.0.1:${COMFY_PORT}/" >/dev/null 2>&1; then
  nohup "$VENV_PATH/bin/python" "${COMFY_ROOT}/main.py" --listen 0.0.0.0 --port "${COMFY_PORT}" >/tmp/comfy.log 2>&1 &
  for i in {1..60}; do
    sleep 1
    curl -s "http://127.0.0.1:${COMFY_PORT}/" >/dev/null 2>&1 && break || true
  done
fi

# === 缺失節點清單（先 Manager API，失敗就 git clone）===
declare -A REPOS=(
  ["comfy_mtb"]="https://github.com/melMass/comfy_mtb"                            # Note Plus (mtb)
  ["ComfyMath"]="https://github.com/evanspearman/ComfyMath"                        # CM_Number* / CM_Int*
  ["ComfyUI_Comfyroll_CustomNodes"]="https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes"  # CR *
  ["comfyui-various"]="https://github.com/jamesWalker55/comfyui-various"           # JW*
  ["ComfyUI_LayerStyle_Advance"]="https://github.com/chflame163/ComfyUI_LayerStyle_Advance"   # LayerStyle Advance
)
CUSTOM_DIR="${COMFY_ROOT}/custom_nodes"

install_repo_manager() {
  local url="$1"
  curl -sS -X POST "http://127.0.0.1:${COMFY_PORT}/api/customnode/install" \
    -H "Content-Type: application/json" \
    -d "{\"files\":[\"${url}\"],\"install_type\":\"git-clone\",\"reference\":\"${url}\",\"title\":\"auto\",\"id\":\"auto\"}" \
    | grep -qi '"ok":true'
}

for name in "${!REPOS[@]}"; do
  dest="${CUSTOM_DIR}/${name}"
  if [ ! -d "$dest" ]; then
    echo "[info] 嘗試用 Manager API 安裝 $name …"
    if ! install_repo_manager "${REPOS[$name]}"; then
      echo "[warn] Manager API 失敗，改用手動 git 安裝 $name"
      git clone --depth=1 "${REPOS[$name]}" "$dest"
      if [ -f "$dest/requirements.txt" ]; then
        python -m pip install -r "$dest/requirements.txt" || true
      fi
      if [ -f "$dest/install.py" ]; then
        python "$dest/install.py" || true
      fi
    fi
  else
    git -C "$dest" pull --ff-only || true
  fi
done

# === 模型下載與放置 ===
cd "$COMFY_ROOT"

# 1) Checkpoint
if [ ! -f "models/checkpoints/juggernautXL_v9Rdphoto2Lightning.safetensors" ]; then
  curl ${CURL_RETRY} -o models/checkpoints/juggernautXL_v9Rdphoto2Lightning.safetensors \
    "https://huggingface.co/AiWise/Juggernaut-XL-V9-GE-RDPhoto2-Lightning_4S/resolve/main/juggernautXL_v9Rdphoto2Lightning.safetensors"
fi

# 2) InstantID
mkdir -p models/instantid
if [ ! -f "models/instantid/ip-adapter.bin" ]; then
  curl ${CURL_RETRY} -o models/instantid/ip-adapter.bin \
    "https://huggingface.co/InstantX/InstantID/resolve/main/ip-adapter.bin"
fi

# 3) ControlNet / InstantID 控制網
if [ ! -f "models/controlnet/diffusion_pytorch_model.safetensors" ]; then
  curl ${CURL_RETRY} -o models/controlnet/diffusion_pytorch_model.safetensors \
    "https://huggingface.co/InstantX/InstantID/resolve/main/ControlNetModel/diffusion_pytorch_model.safetensors"
fi

# 4) TTPlanet Tile (SDXL)
if [ ! -f "models/controlnet/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors" ]; then
  curl ${CURL_RETRY} -o models/controlnet/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors \
    "https://huggingface.co/TTPlanet/TTPLanet_SDXL_Controlnet_Tile_Realistic/resolve/main/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors"
fi

# 5) Upscale model：safetensors + 同名 .pth 連結
if [ ! -f "models/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors" ]; then
  curl ${CURL_RETRY} -o models/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors \
    "https://huggingface.co/Phips/2xNomosUni_span_multijpg_ldl/resolve/main/2xNomosUni_span_multijpg_ldl.safetensors"
fi
if [ ! -f "models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" ]; then
  ln -s "2xNomosUni_span_multijpg_ldl.safetensors" "models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" || true
fi

# 6) InsightFace 模型（修復 antelopev2 放置位置）
pushd models/insightface/models >/dev/null
rm -rf antelopev2 antelopev2.zip || true
curl ${CURL_RETRY} -o antelopev2.zip \
  "https://github.com/deepinsight/insightface/releases/download/v0.7/antelopev2.zip"
unzip -o antelopev2.zip && rm -f antelopev2.zip
popd >/dev/null

# 7) 匯入你的工作流（放到 workflows 夾）
WF_NAME="$(basename "${WORKFLOW_URL}")"
curl ${CURL_RETRY} -o "${COMFY_ROOT}/user/default/workflows/${WF_NAME}" "${WORKFLOW_URL}"

# === 收尾：重啟 ComfyUI 以掃描新節點/模型 ===
pkill -f "${COMFY_ROOT}/main.py" || true
sleep 1
nohup "$VENV_PATH/bin/python" "${COMFY_ROOT}/main.py" --listen 0.0.0.0 --port "${COMFY_PORT}" >/tmp/comfy.log 2>&1 &
echo "[OK] 安裝完成；ComfyUI 執行中（port ${COMFY_PORT}）。"
