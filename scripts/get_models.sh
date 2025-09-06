#!/usr/bin/env bash
set -euo pipefail

COMFY_ROOT=${COMFY_ROOT:-/opt/ComfyUI}
MODELS="${COMFY_ROOT}/models"

require_ok() {
  local path="$1"
  if [[ ! -s "$path" ]]; then
    echo "[ERROR] 缺少檔案：$path"
    exit 1
  fi
}

dl() {
  local url="$1"
  local out="$2"
  if [[ -s "$out" ]]; then
    echo "[SKIP] 已存在：$(basename "$out")"
    return 0
  fi
  echo "[DL] $url"
  curl -L --fail --retry 5 --retry-delay 3 "$url" -o "$out"
}

mkdir -p \
  "${MODELS}/checkpoints" \
  "${MODELS}/controlnet" \
  "${MODELS}/instantid" \
  "${MODELS}/insightface/models" \
  "${MODELS}/upscale_models"

# 1) InsightFace antelopev2 放正確路徑（避免錯位）
# 清掉錯置於 models/insightface 根目錄的殘留
find "${MODELS}/insightface" -maxdepth 1 -type f -name 'antelopev2.zip' -delete || true
if [[ -d "${MODELS}/insightface/antelopev2" ]]; then
  rm -rf "${MODELS}/insightface/antelopev2"
fi

# 下載 antelopev2.zip 並解壓到 models/insightface/models/antelopev2
ANT_DIR="${MODELS}/insightface/models/antelopev2"
if [[ ! -d "$ANT_DIR" || -z "$(ls -A "$ANT_DIR" 2>/dev/null || true)" ]]; then
  mkdir -p "$ANT_DIR"
  TMP_ZIP="/tmp/antelopev2.zip"
  # 主要來源（GitHub releases v0.7），若取用失敗，使用 SourceForge 鏡像
  set +e
  curl -L --fail --retry 5 --retry-delay 3 \
    "https://github.com/deepinsight/insightface/releases/download/v0.7/antelopev2.zip" -o "$TMP_ZIP"
  if [[ $? -ne 0 ]]; then
    echo "[WARN] GitHub 下載失敗，改用 SourceForge 鏡像"
    curl -L --fail --retry 5 --retry-delay 3 \
      "https://downloads.sourceforge.net/project/insightface.mirror/v0.7/antelopev2.zip" -o "$TMP_ZIP"
  fi
  set -e
  unzip -o "$TMP_ZIP" -d "${MODELS}/insightface/models/"
  rm -f "$TMP_ZIP"
fi

# 2) InstantID 主模型與 ControlNet
dl "https://huggingface.co/InstantX/InstantID/resolve/main/ip-adapter.bin" \
   "${MODELS}/instantid/ip-adapter.bin"

dl "https://huggingface.co/InstantX/InstantID/resolve/main/ControlNetModel/diffusion_pytorch_model.safetensors" \
   "${MODELS}/controlnet/diffusion_pytorch_model.safetensors"

# 3) TTPlanet Tile ControlNet (SDXL)
dl "https://huggingface.co/TTPlanet/TTPLanet_SDXL_Controlnet_Tile_Realistic/resolve/main/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors" \
   "${MODELS}/controlnet/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors"

# 4) Juggernaut-XL Lightning 模型
dl "https://huggingface.co/AiWise/Juggernaut-XL-V9-GE-RDPhoto2-Lightning_4S/resolve/main/juggernautXL_v9Rdphoto2Lightning.safetensors" \
   "${MODELS}/checkpoints/juggernautXL_v9Rdphoto2Lightning.safetensors"

# 5) 2xNomosUni 升尺度（實際檔名為 .safetensors，建立 .pth 連結）
dl "https://huggingface.co/Phips/2xNomosUni_span_multijpg_ldl/resolve/main/2xNomosUni_span_multijpg_ldl.safetensors" \
   "${MODELS}/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors"

# 相容舊工作流：建立 .pth 軟連結
cd "${MODELS}/upscale_models"
if [[ ! -e "2xNomosUni_span_multijpg_ldl.pth" ]]; then
  ln -s "2xNomosUni_span_multijpg_ldl.safetensors" "2xNomosUni_span_multijpg_ldl.pth"
fi

# 基本檢查
require_ok "${MODELS}/instantid/ip-adapter.bin"
require_ok "${MODELS}/controlnet/diffusion_pytorch_model.safetensors"
require_ok "${MODELS}/insightface/models/antelopev2/glintr100.onnx"

echo "[OK] 模型檔案準備完成。"
