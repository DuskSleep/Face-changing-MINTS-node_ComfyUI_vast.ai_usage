#!/usr/bin/env bash
# install-mints-extras.sh — 一鍵補齊 MINTS/InstantID 需要的節點+模型（含 LayerStyle 模型整包與 antelopev2），可重複執行。
# 流程：等待 ComfyUI → 降 Manager 安全等級 → 安裝缺失節點 → 安裝相依套件 → 放置模型（含 LayerStyle 全包）→ 修復 antelopev2 → 摘要。
set -euo pipefail

# ===== 預設參數（可用環境變數或 CLI 覆蓋）=====
COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
VENV="${VENV:-/venv}"
MAX_WAIT="${MAX_WAIT:-420}"
SKIP_WAIT="${SKIP_WAIT:-0}"

# ===== 參數處理 =====
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)      COMFY_PORT="$2"; shift 2;;
    --dir)       COMFY_DIR="$2"; shift 2;;
    --venv)      VENV="$2"; shift 2;;
    --max-wait)  MAX_WAIT="$2"; shift 2;;
    --skip-wait) SKIP_WAIT="1"; shift 1;;
    *) shift;;
  esac
done

# ===== Log =====
boldcyan(){ printf "\033[1;36m%s\033[0m" "$1"; }
log(){ printf "\n%s %s\n" "$(boldcyan "[mints-extras]")" "$*"; }
warn(){ printf "\n\033[1;33m[mints-extras WARN]\033[0m %s\n" "$*"; }

# ===== Helpers =====
wait_for_comfy(){
  [[ "$SKIP_WAIT" = "1" ]] && { log "跳過等待 ComfyUI。"; return 0; }
  log "等待 ComfyUI 在 127.0.0.1:${COMFY_PORT}（最長 ${MAX_WAIT}s）..."
  local t=0
  while [[ $t -lt $MAX_WAIT ]]; do
    if command -v curl >/dev/null 2>&1 && curl -fsS "http://127.0.0.1:${COMFY_PORT}/" >/dev/null 2>&1; then
      log "ComfyUI HTTP 正常。"; return 0
    fi
    if command -v ss >/dev/null 2>&1 && ss -ltn | grep -q ":${COMFY_PORT} "; then
      log "發現埠 ${COMFY_PORT} 已開放。"; return 0
    fi
    sleep 3; t=$((t+3))
  done
  warn "等待逾時（可能 ComfyUI 尚在啟動），繼續進行安裝。"
}

choose_pip(){
  if [[ -x "${VENV}/bin/pip" ]]; then echo "${VENV}/bin/pip"; return 0; fi
  if [[ -x "${COMFY_DIR}/venv/bin/pip" ]]; then echo "${COMFY_DIR}/venv/bin/pip"; return 0; fi
  command -v pip3 >/dev/null 2>&1 && { echo pip3; return 0; }
  command -v python3 >/dev/null 2>&1 && { echo "python3 -m pip"; return 0; }
  echo ""; return 1
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
  return 1
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

# ===== Start =====
log "設定：COMFY_DIR=${COMFY_DIR}  VENV=${VENV}  COMFY_PORT=${COMFY_PORT}  MAX_WAIT=${MAX_WAIT}"
wait_for_comfy

# 降 Manager 安全等級（兩處都寫）
log "設定 ComfyUI-Manager security_level=weak ..."
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

# 安裝相依套件（盡量不動 apt）
PIP="$(choose_pip || true)"; [[ -z "$PIP" ]] && { PIP="python3 -m pip"; warn "找不到 venv pip，改用：$PIP"; }
log "使用 pip：$PIP"
$PIP install -q --disable-pip-version-check \
  "mediapipe==0.10.14" \
  "insightface>=0.7,<0.8" \
  "onnxruntime-gpu>=1.16,<2" \
  "transformers>=4.39,<5" \
  "huggingface_hub>=0.24,<1" \
  "opencv-python-headless==4.10.*" "pymatting" "guided-filter" "scikit-image" \
  || warn "部分依賴安裝失敗，可稍後重試"

# 安裝/更新所有需要的 Custom Nodes
log "安裝/更新 Custom Nodes ..."
mkdir -p "${COMFY_DIR}/custom_nodes"
# 你原列的四包
clone_or_update https://github.com/melMass/comfy_mtb                                       "${COMFY_DIR}/custom_nodes/comfy_mtb"                      # Note Plus (mtb)
clone_or_update https://github.com/evanspearman/ComfyMath                                   "${COMFY_DIR}/custom_nodes/ComfyMath"                     # CM_Number*
clone_or_update https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes                     "${COMFY_DIR}/custom_nodes/ComfyUI_Comfyroll_CustomNodes" # CR Upscale / Prompt Text
clone_or_update https://github.com/jamesWalker55/comfyui-various                            "${COMFY_DIR}/custom_nodes/comfyui-various"               # JWImageResize / JWInteger
# LayerStyle（LayerMask/LayerUtility/PersonMaskUltra V2 等）
clone_or_update https://github.com/chflame163/ComfyUI_LayerStyle                            "${COMFY_DIR}/custom_nodes/ComfyUI_LayerStyle"
clone_or_update https://github.com/chflame163/ComfyUI_LayerStyle_Advance                    "${COMFY_DIR}/custom_nodes/ComfyUI_LayerStyle_Advance"
# InstantID / FaceAnalysis
clone_or_update https://github.com/cubiq/ComfyUI_InstantID                                  "${COMFY_DIR}/custom_nodes/ComfyUI_InstantID"
clone_or_update https://github.com/cubiq/ComfyUI_FaceAnalysis                               "${COMFY_DIR}/custom_nodes/ComfyUI_FaceAnalysis"
# 其它
clone_or_update https://github.com/pythongosssss/ComfyUI-Custom-Scripts                     "${COMFY_DIR}/custom_nodes/ComfyUI-Custom-Scripts"        # ConstrainImage|pysssss
clone_or_update https://github.com/rgthree/rgthree-comfy                                    "${COMFY_DIR}/custom_nodes/rgthree-comfy"                 # Image Comparer
clone_or_update https://github.com/yolain/ComfyUI-Easy-Use                                  "${COMFY_DIR}/custom_nodes/ComfyUI-Easy-Use"              # easy imageColorMatch

# 放置模型（你指定的）
log "下載/放置模型 ..."
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
# 舊工作流若寫成 .pth，建相容連結
if [[ -f "${COMFY_DIR}/models/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors" && ! -e "${COMFY_DIR}/models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" ]]; then
  ( cd "${COMFY_DIR}/models/upscale_models" && ln -s "2xNomosUni_span_multijpg_ldl.safetensors" "2xNomosUni_span_multijpg_ldl.pth" ) || true
fi

# 修復 insightface v0.7 / antelopev2
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

# 同步 LayerStyle 模型整包（作者倉打包好的 models 目錄）
log "同步 LayerStyle 模型整包到 ${COMFY_DIR}/models ..."
python3 - <<'PY' || true
import os, shutil
from huggingface_hub import snapshot_download
repo="chflame163/ComfyUI_LayerStyle"
path=snapshot_download(repo, repo_type="model", local_files_only=False)
src=os.path.join(path,"ComfyUI","models")
dst=os.path.join(os.environ.get("COMFY_DIR","/workspace/ComfyUI"),"models")
if os.path.isdir(src):
    for root, _, files in os.walk(src):
        rel=os.path.relpath(root, src)
        os.makedirs(os.path.join(dst, rel), exist_ok=True)
        for f in files:
            sp=os.path.join(root,f)
            dp=os.path.join(dst, rel, f)
            if not os.path.exists(dp):
                shutil.copy2(sp, dp)
print("LayerStyle models synced ->", dst)
PY

# ===== 摘要 =====
log "完成。模型檢查："
for p in \
  "models/checkpoints/juggernautXL_v9Rdphoto2Lightning.safetensors" \
  "models/instantid/ip-adapter.bin" \
  "models/controlnet/diffusion_pytorch_model.safetensors" \
  "models/controlnet/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors" \
  "models/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors" \
  "models/insightface/models/antelopev2" \
  "models/mediapipe" "models/vitmatte"
do
  [[ -e "${COMFY_DIR}/${p}" ]] && echo "OK  ${p}" || echo "MISS ${p}"
done

echo
echo "📌 在 ComfyUI：Manager → Reload Custom Nodes（或重啟）以載入新節點。"
echo "📌 若你用舊 workflow 引用 .pth，已建立對應連結。"
