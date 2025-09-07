#!/usr/bin/env bash
# install-mints-extras.sh — 等 ComfyUI -> 降 Manager 安全等級 -> 安裝缺失節點 -> 下載模型 -> 修復 antelopev2
set -euo pipefail
COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
VENV="${VENV:-/venv}"
MAX_WAIT="${MAX_WAIT:-420}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) COMFY_PORT="$2"; shift 2;;
    --dir)  COMFY_DIR="$2"; shift 2;;
    --venv) VENV="$2"; shift 2;;
    --max-wait) MAX_WAIT="$2"; shift 2;;
    *) shift;;
  esac
done

log(){ printf "\n\033[1;36m[extras]\033[0m %s\n" "$*"; }
warn(){ printf "\n\033[1;33m[extras]\033[0m %s\n" "$*"; }

wait_for_comfy(){
  log "等待 ComfyUI 於 127.0.0.1:${COMFY_PORT}（最長 ${MAX_WAIT}s）..."
  local t=0
  while [[ $t -lt $MAX_WAIT ]]; do
    curl -fsS "http://127.0.0.1:${COMFY_PORT}/" >/dev/null 2>&1 && { log "ComfyUI HTTP 正常"; return 0; }
    command -v ss >/dev/null 2>&1 && ss -ltn | grep -q ":${COMFY_PORT} " && { log "埠已開放"; return 0; }
    sleep 3; t=$((t+3))
  done
  warn "逾時，繼續執行（ComfyUI 可能仍在啟動）。"
}

choose_pip(){
  if [[ -x "${VENV}/bin/pip" ]]; then echo "${VENV}/bin/pip"; return; fi
  if [[ -x "${COMFY_DIR}/venv/bin/pip" ]]; then echo "${COMFY_DIR}/venv/bin/pip"; return; fi
  command -v pip3 >/dev/null 2>&1 && { echo pip3; return; }
  echo "python3 -m pip"
}

clone_or_update(){ # repo url, target dir
  local repo="$1" dir="$2"
  if [[ -d "$dir/.git" ]]; then git -C "$dir" pull --ff-only || true
  else git clone --depth=1 "$repo" "$dir"
  fi
}

dl(){ # url, outfile
  local url="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  if [[ -f "$out" ]]; then log "已存在：$out（跳過）"; return 0; fi
  if command -v aria2c >/dev/null 2>&1; then
    aria2c -x16 -s16 -k1M -o "$(basename "$out")" -d "$(dirname "$out")" "$url" && return 0
  fi
  command -v curl >/dev/null 2>&1 && curl -fL --retry 3 --retry-delay 2 -o "$out" "$url" && return 0
  command -v wget >/dev/null 2>&1 && wget -qO "$out" "$url" && return 0
  warn "下載失敗：$url"
}

unzip_to(){ # zipfile, destdir
  local zip="$1" dest="$2"
  mkdir -p "$dest"
  if command -v unzip >/dev/null 2>&1; then
    unzip -o "$zip" -d "$dest" >/dev/null 2>&1 || true
  else
    python3 - "$zip" "$dest" <<'PY'
import sys, zipfile, os
zip_path, dest = sys.argv[1], sys.argv[2]
os.makedirs(dest, exist_ok=True)
with zipfile.ZipFile(zip_path) as z:
    z.extractall(dest)
PY
  fi
}

# 1) 等待 ComfyUI
wait_for_comfy

# 2) 降 Manager 安全等級（允許 GitHub 安裝）
for cfg in \
  "${COMFY_DIR}/custom_nodes/ComfyUI-Manager/config.ini" \
  "${COMFY_DIR}/user/default/ComfyUI-Manager/config.ini"
do
  mkdir -p "$(dirname "$cfg")"; touch "$cfg"
  if ! grep -q "\[Environment\]" "$cfg"; then
    printf "[Environment]\nsecurity_level = weak\n" > "$cfg"
  else
    sed -i 's/^security_level *= *.*/security_level = weak/' "$cfg" || true
    grep -q '^security_level' "$cfg" || printf "security_level = weak\n" >> "$cfg"
  fi
done

# 3) 依賴（盡量溫和，不動 apt）
PIP="$(choose_pip)"
$PIP install -q --disable-pip-version-check \
  "mediapipe==0.10.14" "insightface>=0.7,<0.8" "onnxruntime-gpu>=1.16,<2" \
  "transformers>=4.39,<5" || warn "部分依賴安裝失敗，可稍後重試"

# 4) 補齊缺失節點
mkdir -p "${COMFY_DIR}/custom_nodes"
# 你原本列的四包
clone_or_update https://github.com/melMass/comfy_mtb                                       "${COMFY_DIR}/custom_nodes/comfy_mtb"                      # Note Plus (mtb)
clone_or_update https://github.com/evanspearman/ComfyMath                                   "${COMFY_DIR}/custom_nodes/ComfyMath"                     # CM_Number*
clone_or_update https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes                     "${COMFY_DIR}/custom_nodes/ComfyUI_Comfyroll_CustomNodes" # CR Upscale / Prompt Text
clone_or_update https://github.com/jamesWalker55/comfyui-various                            "${COMFY_DIR}/custom_nodes/comfyui-various"               # JWImageResize / JWInteger
# 其他缺的
clone_or_update https://github.com/chflame163/ComfyUI_LayerStyle                            "${COMFY_DIR}/custom_nodes/ComfyUI_LayerStyle"            # LayerMask/LayerUtility/PersonMaskUltra V2
clone_or_update https://github.com/chflame163/ComfyUI_LayerStyle_Advance                    "${COMFY_DIR}/custom_nodes/ComfyUI_LayerStyle_Advance"
clone_or_update https://github.com/cubiq/ComfyUI_InstantID                                  "${COMFY_DIR}/custom_nodes/ComfyUI_InstantID"             # ApplyInstantID/InstantIDModelLoader/InstantIDFaceAnalysis
clone_or_update https://github.com/cubiq/ComfyUI_FaceAnalysis                               "${COMFY_DIR}/custom_nodes/ComfyUI_FaceAnalysis"          # FaceBoundingBox/FaceAnalysisModels
clone_or_update https://github.com/pythongosssss/ComfyUI-Custom-Scripts                     "${COMFY_DIR}/custom_nodes/ComfyUI-Custom-Scripts"        # ConstrainImage|pysssss
clone_or_update https://github.com/rgthree/rgthree-comfy                                    "${COMFY_DIR}/custom_nodes/rgthree-comfy"                 # Image Comparer
clone_or_update https://github.com/yolain/ComfyUI-Easy-Use                                  "${COMFY_DIR}/custom_nodes/ComfyUI-Easy-Use"              # easy imageColorMatch

# 5) 下載 / 放置模型
log "下載模型..."
mkdir -p "${COMFY_DIR}/models/checkpoints" \
         "${COMFY_DIR}/models/instantid" \
         "${COMFY_DIR}/models/controlnet" \
         "${COMFY_DIR}/models/upscale_models" \
         "${COMFY_DIR}/models/insightface/models"

# SDXL checkpoint
dl "https://huggingface.co/AiWise/Juggernaut-XL-V9-GE-RDPhoto2-Lightning_4S/resolve/main/juggernautXL_v9Rdphoto2Lightning.safetensors" \
   "${COMFY_DIR}/models/checkpoints/juggernautXL_v9Rdphoto2Lightning.safetensors"

# InstantID
dl "https://huggingface.co/InstantX/InstantID/resolve/main/ip-adapter.bin" \
   "${COMFY_DIR}/models/instantid/ip-adapter.bin"
dl "https://huggingface.co/InstantX/InstantID/resolve/main/ControlNetModel/diffusion_pytorch_model.safetensors" \
   "${COMFY_DIR}/models/controlnet/diffusion_pytorch_model.safetensors"

# TTPlanet ControlNet Tile (SDXL)
dl "https://huggingface.co/TTPlanet/TTPLanet_SDXL_Controlnet_Tile_Realistic/resolve/main/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors" \
   "${COMFY_DIR}/models/controlnet/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors"

# Upscaler：2xNomosUni_span_multijpg_ldl（僅有 .safetensors）
dl "https://huggingface.co/Phips/2xNomosUni_span_multijpg_ldl/resolve/main/2xNomosUni_span_multijpg_ldl.safetensors" \
   "${COMFY_DIR}/models/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors"
# 舊 workflow 若寫成 .pth，建相容連結
if [[ ! -f "${COMFY_DIR}/models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" ]]; then
  ln -s "2xNomosUni_span_multijpg_ldl.safetensors" "${COMFY_DIR}/models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" 2>/dev/null || true
fi

# 6) 修復 insightface v0.7 / antelopev2
log "修復 antelopev2 到正確路徑 ..."
INSIGHT_DIR="${COMFY_DIR}/models/insightface/models"
mkdir -p "$INSIGHT_DIR"
rm -rf "${INSIGHT_DIR}/antelopev2.zip" "${INSIGHT_DIR}/antelopev2" || true
TMPD="$(mktemp -d)"
ZIP="$TMPD/antelopev2.zip"
dl "https://github.com/deepinsight/insightface/releases/download/v0.7/antelopev2.zip" "$ZIP"
unzip_to "$ZIP" "$TMPD/unzip"
if [[ -d "$TMPD/unzip/antelopev2" ]]; then
  mv "$TMPD/unzip/antelopev2" "${INSIGHT_DIR}/antelopev2"
else
  mkdir -p "${INSIGHT_DIR}/antelopev2"
  cp -r "$TMPD/unzip"/* "${INSIGHT_DIR}/antelopev2"/ || true
fi
rm -rf "$TMPD"

# 7) 摘要
log "完成。模型檢查："
for p in \
  "models/checkpoints/juggernautXL_v9Rdphoto2Lightning.safetensors" \
  "models/instantid/ip-adapter.bin" \
  "models/controlnet/diffusion_pytorch_model.safetensors" \
  "models/controlnet/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors" \
  "models/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors" \
  "models/insightface/models/antelopev2"; do
  [[ -e "${COMFY_DIR}/${p}" ]] && echo "OK  ${p}" || echo "MISS ${p}"
done

echo
echo "📌 ComfyUI → Manager → Reload Custom Nodes（或重啟 ComfyUI）即可套用新節點。"
