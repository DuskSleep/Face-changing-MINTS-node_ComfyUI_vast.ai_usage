#!/usr/bin/env bash
# install-mints.sh — vast.ai Jupyter 終端機一鍵安裝（可放到 GitHub Raw/Gist 後用 curl 一鍵執行）
# 功能：
# - 等待 ComfyUI 服務就緒（或達到最長等待時間後繼續）
# - 降低 ComfyUI-Manager 安全等級為 weak
# - 安裝缺失節點（GitHub）：comfy_mtb / ComfyMath / Comfyroll / comfyui-various
# - 放置指定模型（XL checkpoint / InstantID / ControlNet / Upscaler）
# - 修復 insightface v0.7 的 antelopev2 到正確路徑
# - 安裝 mediapipe==0.10.14（於偵測到的 pip/venv 中）
# - 為 2xNomos… 建立 .pth -> .safetensors 相容連結（避免舊工作流找不到）
#
# 參數：
#   --port <n>         ComfyUI 監聽埠，預設 8188
#   --dir <path>       ComfyUI 根目錄，預設 /opt/ComfyUI
#   --venv <path>      Python 虛擬環境路徑，預設 /venv （若不存在會自動 fallback 到系統 pip）
#   --max-wait <sec>   等待 ComfyUI 的最長秒數（預設 420 = 7 分鐘）
#   --skip-wait        不等待 ComfyUI，直接安裝
#   --no-mediapipe     不安裝 mediapipe（若你不需要）
#
# 用法：
#   bash <(curl -fsSL https://RAW_URL/install-mints.sh) --port 8188
set -euo pipefail

# ----------- defaults -----------
COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
VENV="${VENV:-/venv}"
MAX_WAIT="${MAX_WAIT:-420}"
SKIP_WAIT="0"
INSTALL_MEDIAPIPE="1"

# ----------- args -----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)       COMFY_PORT="$2"; shift 2;;
    --dir)        COMFY_DIR="$2"; shift 2;;
    --venv)       VENV="$2"; shift 2;;
    --max-wait)   MAX_WAIT="$2"; shift 2;;
    --skip-wait)  SKIP_WAIT="1"; shift 1;;
    --no-mediapipe) INSTALL_MEDIAPIPE="0"; shift 1;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "未知參數：$1"; exit 1;;
  esac
done

log(){ printf "\n\033[1;36m[install-mints]\033[0m %s\n" "$*"; }
warn(){ printf "\n\033[1;33m[install-mints WARN]\033[0m %s\n" "$*"; }
err(){ printf "\n\033[1;31m[install-mints ERROR]\033[0m %s\n" "$*"; }

# ----------- helpers -----------
choose_pip(){
  # 優先用 VENV，再找可能的 pip3 / python3 -m pip
  if [[ -x "${VENV}/bin/pip" ]]; then
    echo "${VENV}/bin/pip"
    return 0
  fi
  if [[ -x "${COMFY_DIR}/venv/bin/pip" ]]; then
    echo "${COMFY_DIR}/venv/bin/pip"
    return 0
  fi
  if command -v pip3 >/dev/null 2>&1; then
    echo "pip3"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    echo "python3 -m pip"
    return 0
  fi
  echo ""
  return 1
}

download(){
  # download <url> <outfile>
  local url="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  if [[ -f "$out" ]]; then
    log "已存在：$out （跳過下載）"
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 -o "$out" "$url" && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url" && return 0
  fi
  err "無法下載：$url"
  return 1
}

unzip_to(){
  # unzip_to <zipfile> <destdir>
  local zip="$1" dest="$2"
  mkdir -p "$dest"
  if command -v unzip >/dev/null 2>&1; then
    unzip -o "$zip" -d "$dest" >/dev/null 2>&1 || true
  else
    # 用 Python 解壓（避免系統無 unzip）
    python3 - "$zip" "$dest" <<'PY'
import sys, zipfile, os
zip_path, dest = sys.argv[1], sys.argv[2]
os.makedirs(dest, exist_ok=True)
with zipfile.ZipFile(zip_path) as z:
    z.extractall(dest)
print("解壓完成:", zip_path, "->", dest)
PY
  fi
}

wait_for_comfy(){
  if [[ "$SKIP_WAIT" = "1" ]]; then
    log "跳過等待 ComfyUI。"
    return 0
  fi
  log "等待 ComfyUI 啟動在 127.0.0.1:${COMFY_PORT}（最長 ${MAX_WAIT}s）..."
  local t=0
  while [[ $t -lt $MAX_WAIT ]]; do
    # 優先測試 HTTP
    if command -v curl >/dev/null 2>&1; then
      if curl -fsS "http://127.0.0.1:${COMFY_PORT}/" >/dev/null 2>&1; then
        log "ComfyUI HTTP 回應正常。"
        return 0
      fi
    fi
    # 退而求其次檢查埠
    if command -v ss >/dev/null 2>&1; then
      if ss -ltn | grep -q ":${COMFY_PORT} "; then
        log "埠 ${COMFY_PORT} 已開放。"
        return 0
      fi
    fi
    sleep 3
    t=$((t+3))
  done
  warn "等待逾時，仍繼續進行安裝（可能 ComfyUI 尚未完全就緒）。"
}

# ----------- start -----------
log "設定：COMFY_DIR=${COMFY_DIR} COMFY_PORT=${COMFY_PORT} VENV=${VENV} MAX_WAIT=${MAX_WAIT}"
wait_for_comfy

log "偵測 pip ..."
PIP="$(choose_pip || true)"
if [[ -z "$PIP" ]]; then
  warn "找不到 pip，將嘗試使用 'python3 -m pip'"
  PIP="python3 -m pip"
fi
log "使用 pip：$PIP"

# ----------- 安裝 mediapipe（可關閉） -----------
if [[ "$INSTALL_MEDIAPIPE" = "1" ]]; then
  log "安裝 mediapipe==0.10.14（若已安裝會略過）..."
  $PIP install -q --disable-pip-version-check "mediapipe==0.10.14" || warn "mediapipe 安裝可能失敗，稍後可手動重試。"
else
  log "依指示略過 mediapipe 安裝。"
fi

# ----------- 降低 Manager 安全等級 -----------
log "設定 ComfyUI-Manager security_level=weak ..."
CFG1="${COMFY_DIR}/custom_nodes/ComfyUI-Manager/config.ini"
CFG2="${COMFY_DIR}/user/default/ComfyUI-Manager/config.ini"
mkdir -p "$(dirname "$CFG1")" "$(dirname "$CFG2")"
touch "$CFG1" "$CFG2"
for cfg in "$CFG1" "$CFG2"; do
  if ! grep -q "\[Environment\]" "$cfg"; then
    printf "[Environment]\nsecurity_level = weak\n" > "$cfg"
  else
    sed -i 's/^security_level *= *.*/security_level = weak/' "$cfg" || true
    grep -q '^security_level' "$cfg" || printf "security_level = weak\n" >> "$cfg"
  fi
done

# ----------- 安裝缺失節點 -----------
log "安裝/更新 Custom Nodes ..."
mkdir -p "${COMFY_DIR}/custom_nodes"
clone_or_update () {
  local repo="$1"; local dir="$2"
  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" pull --ff-only || true
  else
    git clone --depth=1 "$repo" "$dir"
  fi
}
clone_or_update "https://github.com/melMass/comfy_mtb"                                 "${COMFY_DIR}/custom_nodes/comfy_mtb"                      # Note Plus (mtb)
clone_or_update "https://github.com/evanspearman/ComfyMath"                             "${COMFY_DIR}/custom_nodes/ComfyMath"                     # CM_Number*
clone_or_update "https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes"               "${COMFY_DIR}/custom_nodes/ComfyUI_Comfyroll_CustomNodes" # CR Upscale / Prompt Text
clone_or_update "https://github.com/jamesWalker55/comfyui-various"                      "${COMFY_DIR}/custom_nodes/comfyui-various"               # JWImageResize / JWInteger

# ----------- 模型放置 -----------
log "下載/放置模型 ..."
mkdir -p "${COMFY_DIR}/models/checkpoints" \
         "${COMFY_DIR}/models/instantid" \
         "${COMFY_DIR}/models/controlnet" \
         "${COMFY_DIR}/models/upscale_models" \
         "${COMFY_DIR}/models/insightface/models"

download "https://huggingface.co/AiWise/Juggernaut-XL-V9-GE-RDPhoto2-Lightning_4S/resolve/main/juggernautXL_v9Rdphoto2Lightning.safetensors" \
         "${COMFY_DIR}/models/checkpoints/juggernautXL_v9Rdphoto2Lightning.safetensors"

download "https://huggingface.co/InstantX/InstantID/resolve/main/ip-adapter.bin" \
         "${COMFY_DIR}/models/instantid/ip-adapter.bin"

download "https://huggingface.co/InstantX/InstantID/resolve/main/ControlNetModel/diffusion_pytorch_model.safetensors" \
         "${COMFY_DIR}/models/controlnet/diffusion_pytorch_model.safetensors"

download "https://huggingface.co/TTPlanet/TTPLanet_SDXL_Controlnet_Tile_Realistic/resolve/main/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors" \
         "${COMFY_DIR}/models/controlnet/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors"

download "https://huggingface.co/Phips/2xNomosUni_span_multijpg_ldl/resolve/main/2xNomosUni_span_multijpg_ldl.safetensors" \
         "${COMFY_DIR}/models/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors"

# 建立相容連結（舊 workflow 若寫 .pth 仍能讀到）
if [[ ! -f "${COMFY_DIR}/models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" ]]; then
  ln -s "2xNomosUni_span_multijpg_ldl.safetensors" "${COMFY_DIR}/models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" 2>/dev/null || true
fi

# ----------- 修復 insightface / antelopev2 -----------
log "修復 insightface v0.7 的 antelopev2 位置 ..."
INSIGHT_DIR="${COMFY_DIR}/models/insightface/models"
mkdir -p "$INSIGHT_DIR"
rm -rf "${INSIGHT_DIR}/antelopev2.zip" "${INSIGHT_DIR}/antelopev2" || true
TMPD="$(mktemp -d)"
ZIP="$TMPD/antelopev2.zip"
download "https://github.com/deepinsight/insightface/releases/download/v0.7/antelopev2.zip" "$ZIP"
unzip_to "$ZIP" "$TMPD/unzip"
if [[ -d "$TMPD/unzip/antelopev2" ]]; then
  mv "$TMPD/unzip/antelopev2" "${INSIGHT_DIR}/antelopev2"
else
  mkdir -p "${INSIGHT_DIR}/antelopev2"
  cp -r "$TMPD/unzip"/* "${INSIGHT_DIR}/antelopev2"/ || true
fi
rm -rf "$TMPD"

# ----------- 完成摘要 -----------
log "完成。總結："
python3 - <<'PY' 2>/dev/null || true
import os, sys, json, glob, platform, subprocess
def which(cmd):
    from shutil import which as w
    return w(cmd) or ""
print("Python :", platform.python_version())
try:
    import torch
    print("Torch  :", torch.__version__, "CUDA", torch.version.cuda)
except Exception as e:
    print("Torch  :", "未檢出（這不影響本腳本任務）")
print("Models :")
base = os.environ.get("COMFY_DIR", "/opt/ComfyUI")
for p in [
  "models/checkpoints/juggernautXL_v9Rdphoto2Lightning.safetensors",
  "models/instantid/ip-adapter.bin",
  "models/controlnet/diffusion_pytorch_model.safetensors",
  "models/controlnet/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors",
  "models/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors",
]:
    print(" -", p, "OK" if os.path.exists(os.path.join(base, p)) else "MISSING")
PY

echo
echo "📌 若要立即套用新節點，請於 ComfyUI 內：ComfyUI-Manager → Reload Custom Nodes（或重啟 ComfyUI）"
echo "📌 若你使用了舊工作流引用 .pth，已為 2xNomos… 建立相容連結。"
