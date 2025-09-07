#!/usr/bin/env bash
set -euo pipefail

# ===== 基本參數 =====
export COMFY_ROOT="${COMFY_ROOT:-/workspace/ComfyUI}"
export COMFY_PORT="${COMFY_PORT:-8188}"
export VENV_PATH="${VENV_PATH:-/venv}"
export PY_BIN="${PY_BIN:-python3.11}"
export CURL_RETRY="--retry 5 --retry-delay 2 --fail -L"
export WORKFLOW_URL="${WORKFLOW_URL:-https://raw.githubusercontent.com/DuskSleep/Face-changing-MINTS-node_ComfyUI_vast.ai_usage/main/%E6%8D%A2%E8%84%B8-MINTS.json}"

echo "[INFO] COMFY_ROOT=$COMFY_ROOT  VENV_PATH=$VENV_PATH  PORT=$COMFY_PORT"

# ===== 系統工具（避免沒 git/unzip/libGL）=====
if command -v apt-get >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y git curl unzip ca-certificates libgl1 libglib2.0-0
fi

# ===== 鎖 Python 3.11 =====
if ! command -v ${PY_BIN} >/dev/null 2>&1; then
  echo "[ERR] 找不到 ${PY_BIN}，請先安裝 Python 3.11"; exit 1
fi
PYV="$(${PY_BIN} -c 'import sys;print(".".join(map(str,sys.version_info[:2])))')"
[ "$PYV" = "3.11" ] || { echo "[ERR] 偵測到 Python ${PYV}，此堆疊僅支援 3.11"; exit 2; }

# ===== 目錄 =====
mkdir -p "$COMFY_ROOT" "$VENV_PATH" \
  "$COMFY_ROOT/models/checkpoints" \
  "$COMFY_ROOT/models/instantid" \
  "$COMFY_ROOT/models/controlnet" \
  "$COMFY_ROOT/models/upscale_models" \
  "$COMFY_ROOT/models/insightface/models" \
  "$COMFY_ROOT/user/default/workflows" \
  "$COMFY_ROOT/custom_nodes"

# ===== venv =====
if [ ! -f "$VENV_PATH/bin/activate" ]; then
  ${PY_BIN} -m venv "$VENV_PATH"
fi
source "$VENV_PATH/bin/activate"
python -m pip install -U pip wheel setuptools

# ===== ComfyUI 本體 =====
if [ ! -d "${COMFY_ROOT}/.git" ]; then
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_ROOT"
else
  git -C "$COMFY_ROOT" fetch --prune && git -C "$COMFY_ROOT" reset --hard origin/master
fi

# 避免檔案鎖，先停舊的 ComfyUI
pkill -f "${COMFY_ROOT}/main.py" || true
sleep 1

# ===== 依賴（涵蓋 LayerStyle / InstantID / FaceAnalysis）=====
python -m pip uninstall -y opencv-python || true
python -m pip install -U \
  "onnx>=1.16" "onnxruntime-gpu>=1.19,<1.22" \
  "insightface==0.7.3" "mediapipe>=0.10" \
  "opencv-contrib-python>=4.8,<4.11" \
  "blend-modes>=2.2.0" "psd-tools" "hydra-core==1.3.2" "docopt==0.6.2" \
  "tqdm" "requests"

# ===== 自訂節點（強制 git 安裝，不靠 Manager）=====
CUSTOM_DIR="${COMFY_ROOT}/custom_nodes"
mkdir -p "$CUSTOM_DIR"

clone_fresh () {
  local url="$1" dest="$2"
  echo "[INFO] 安裝 $url -> $dest"
  rm -rf "$dest"
  git clone --depth=1 "$url" "$dest"
  if [ -f "$dest/requirements.txt" ]; then
    python -m pip install -r "$dest/requirements.txt" || true
  fi
  if [ -f "$dest/install.py" ]; then
    python "$dest/install.py" || true
  fi
}

# 你需要的全部節點（含會生出你列的缺失節點）
clone_fresh "https://github.com/chflame163/ComfyUI_LayerStyle"             "${CUSTOM_DIR}/ComfyUI_LayerStyle"           # LayerMask:/LayerUtility:*
clone_fresh "https://github.com/chflame163/ComfyUI_LayerStyle_Advance"     "${CUSTOM_DIR}/ComfyUI_LayerStyle_Advance"   # 進階/加速節點
clone_fresh "https://github.com/cubiq/ComfyUI_InstantID"                   "${CUSTOM_DIR}/ComfyUI_InstantID"            # ApplyInstantID/ModelLoader/FaceAnalysis
clone_fresh "https://github.com/cubiq/ComfyUI_FaceAnalysis"                "${CUSTOM_DIR}/ComfyUI_FaceAnalysis"         # FaceBoundingBox/FaceAnalysisModels

# 你之前列的其它依賴節點
clone_fresh "https://github.com/melMass/comfy_mtb"                         "${CUSTOM_DIR}/comfy_mtb"                    # Note Plus 等
clone_fresh "https://github.com/evanspearman/ComfyMath"                    "${CUSTOM_DIR}/ComfyMath"                    # CM_Number*/CM_Int*
clone_fresh "https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes"      "${CUSTOM_DIR}/ComfyUI_Comfyroll_CustomNodes"# CR *
clone_fresh "https://github.com/jamesWalker55/comfyui-various"             "${CUSTOM_DIR}/comfyui-various"              # JW*

# ===== 模型放位 =====
cd "$COMFY_ROOT"

# 1) Checkpoint
[ -f "models/checkpoints/juggernautXL_v9Rdphoto2Lightning.safetensors" ] || \
curl ${CURL_RETRY} -o models/checkpoints/juggernautXL_v9Rdphoto2Lightning.safetensors \
  "https://huggingface.co/AiWise/Juggernaut-XL-V9-GE-RDPhoto2-Lightning_4S/resolve/main/juggernautXL_v9Rdphoto2Lightning.safetensors"

# 2) InstantID
mkdir -p models/instantid
[ -f "models/instantid/ip-adapter.bin" ] || \
curl ${CURL_RETRY} -o models/instantid/ip-adapter.bin \
  "https://huggingface.co/InstantX/InstantID/resolve/main/ip-adapter.bin"

# 3) ControlNet（InstantID）
[ -f "models/controlnet/diffusion_pytorch_model.safetensors" ] || \
curl ${CURL_RETRY} -o models/controlnet/diffusion_pytorch_model.safetensors \
  "https://huggingface.co/InstantX/InstantID/resolve/main/ControlNetModel/diffusion_pytorch_model.safetensors"

# 4) TTPlanet Tile (SDXL)
[ -f "models/controlnet/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors" ] || \
curl ${CURL_RETRY} -o models/controlnet/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors \
  "https://huggingface.co/TTPlanet/TTPLanet_SDXL_Controlnet_Tile_Realistic/resolve/main/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors"

# 5) Upscale（並建立 .pth 連結，讓舊 workflow 不改名也能跑）
[ -f "models/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors" ] || \
curl ${CURL_RETRY} -o models/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors \
  "https://huggingface.co/Phips/2xNomosUni_span_multijpg_ldl/resolve/main/2xNomosUni_span_multijpg_ldl.safetensors"
[ -f "models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" ] || \
ln -s "2xNomosUni_span_multijpg_ldl.safetensors" "models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" || true

# 6) InsightFace 模型（修復 antelopev2 位置）
pushd models/insightface/models >/dev/null
rm -rf antelopev2 antelopev2.zip || true
curl ${CURL_RETRY} -o antelopev2.zip "https://github.com/deepinsight/insightface/releases/download/v0.7/antelopev2.zip"
unzip -o antelopev2.zip && rm -f antelopev2.zip
popd >/dev/null

# 7) 匯入你的 Workflow
WF_NAME="$(basename "${WORKFLOW_URL}")"
curl ${CURL_RETRY} -o "${COMFY_ROOT}/user/default/workflows/${WF_NAME}" "${WORKFLOW_URL}"

# ===== 啟動 ComfyUI =====
nohup "$VENV_PATH/bin/python" "${COMFY_ROOT}/main.py" --listen 0.0.0.0 --port "${COMFY_PORT}" >/tmp/comfy.log 2>&1 &
echo "[OK] 所有節點與模型已安裝；ComfyUI 執行中（port ${COMFY_PORT}）。"
