#!/usr/bin/env bash
# 安裝缺失節點 + 依賴（會先等待 ComfyUI 就緒）
set -euo pipefail
COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
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

# 1) 等待 ComfyUI
wait_for_comfy

# 2) 降低 Manager 安全等級（允許 GitHub 安裝）
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

# 3) 必要 Python 套件（Py3.11 友善）
PIP="$(choose_pip)"
$PIP install -q --disable-pip-version-check \
  "mediapipe==0.10.14" \
  "transformers>=4.39,<5" \
  "insightface>=0.7,<0.8" \
  "onnxruntime-gpu>=1.16,<2" || warn "部分依賴安裝失敗，可稍後重試"

# 4) 補齊缺失節點 Repos
mkdir -p "${COMFY_DIR}/custom_nodes"
# 已列舉過的四包（確保齊全）
clone_or_update https://github.com/melMass/comfy_mtb                                       "${COMFY_DIR}/custom_nodes/comfy_mtb"
clone_or_update https://github.com/evanspearman/ComfyMath                                   "${COMFY_DIR}/custom_nodes/ComfyMath"
clone_or_update https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes                     "${COMFY_DIR}/custom_nodes/ComfyUI_Comfyroll_CustomNodes"
clone_or_update https://github.com/jamesWalker55/comfyui-various                            "${COMFY_DIR}/custom_nodes/comfyui-various"
# 新增：LayerStyle（LayerMask/LayerUtility/PersonMaskUltra V2 等）
clone_or_update https://github.com/chflame163/ComfyUI_LayerStyle                            "${COMFY_DIR}/custom_nodes/ComfyUI_LayerStyle"
clone_or_update https://github.com/chflame163/ComfyUI_LayerStyle_Advance                    "${COMFY_DIR}/custom_nodes/ComfyUI_LayerStyle_Advance"
# 新增：InstantID（ApplyInstantID/ModelLoader/FaceAnalysis）
clone_or_update https://github.com/cubiq/ComfyUI_InstantID                                  "${COMFY_DIR}/custom_nodes/ComfyUI_InstantID"
# 新增：Face Analysis（FaceBoundingBox/FaceAnalysisModels）
clone_or_update https://github.com/cubiq/ComfyUI_FaceAnalysis                               "${COMFY_DIR}/custom_nodes/ComfyUI_FaceAnalysis"
# 新增：pysssss（ConstrainImage）
clone_or_update https://github.com/pythongosssss/ComfyUI-Custom-Scripts                     "${COMFY_DIR}/custom_nodes/ComfyUI-Custom-Scripts"
# 新增：rgthree（Image Comparer）
clone_or_update https://github.com/rgthree/rgthree-comfy                                    "${COMFY_DIR}/custom_nodes/rgthree-comfy"
# 新增：Easy-Use（easy imageColorMatch）
clone_or_update https://github.com/yolain/ComfyUI-Easy-Use                                  "${COMFY_DIR}/custom_nodes/ComfyUI-Easy-Use"

# 5) InstantID / FaceAnalysis 模型位置健檢（antelopev2）
INSIGHT_DIR="${COMFY_DIR}/models/insightface/models"
mkdir -p "$INSIGHT_DIR"
if [[ ! -d "${INSIGHT_DIR}/antelopev2" ]]; then
  log "缺 antelopev2，下載 insightface v0.7 資源..."
  TMPD="$(mktemp -d)"; ZIP="$TMPD/antelopev2.zip"
  curl -fL -o "$ZIP" https://github.com/deepinsight/insightface/releases/download/v0.7/antelopev2.zip
  mkdir -p "$TMPD/unzip" && (unzip -o "$ZIP" -d "$TMPD/unzip" >/dev/null 2>&1 || python3 - <<'PY'
import sys,zipfile,os; z=sys.argv[1];d=sys.argv[2];os.makedirs(d,exist_ok=True)
with zipfile.ZipFile(z) as zz: zz.extractall(d)
PY
  "$ZIP" "$TMPD/unzip")
  mv "$TMPD/unzip/antelopev2" "${INSIGHT_DIR}/antelopev2" || true
  rm -rf "$TMPD"
fi

# 6) 2xNomos… 相容連結（.pth -> .safetensors）
UP="${COMFY_DIR}/models/upscale_models"
[[ -d "$UP" ]] || mkdir -p "$UP"
if [[ -f "$UP/2xNomosUni_span_multijpg_ldl.safetensors" && ! -e "$UP/2xNomosUni_span_multijpg_ldl.pth" ]]; then
  ln -s "2xNomosUni_span_multijpg_ldl.safetensors" "$UP/2xNomosUni_span_multijpg_ldl.pth" || true
fi

echo
log "完成：請在 ComfyUI → Manager 點『Reload Custom Nodes』或重啟 ComfyUI。"
