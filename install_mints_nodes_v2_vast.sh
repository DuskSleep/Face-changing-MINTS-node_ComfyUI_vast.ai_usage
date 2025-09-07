#!/usr/bin/env bash
# install_mints_nodes_v2_vast.sh — Vast.ai 版：預設 COMFY_ROOT=/workspace/comfyui
# 針對「换脸-MINTS」工作流：補齊 custom_nodes + 依賴 + 模型 + InsightFace v0.7/antelopev2 位置修復
# 需求：Python 3.11（必要）、git/curl/wget/unzip/jq
set -euo pipefail

#======================= 路徑偵測 =======================#
choose_root() {
  local arg="${1:-}"
  if [ -n "$arg" ]; then echo "$arg"; return; fi
  for p in /workspace/comfyui /workspace/ComfyUI "$PWD/comfyui" "$PWD/ComfyUI"; do
    [ -d "$p" ] && { echo "$p"; return; }
  done
  # 找不到就建立預設
  mkdir -p /workspace/comfyui
  echo "/workspace/comfyui"
}
COMFY_ROOT="$(choose_root "${1:-${COMFY_ROOT:-}}")"
echo ">> COMFY_ROOT = $COMFY_ROOT"

#======================= Python/工具 =====================#
# 選擇 python3.11：優先使用已存在的 venv，其次 /venv，再來系統 python3.11
if [ -x "$COMFY_ROOT/venv/bin/python" ]; then PY_BIN="$COMFY_ROOT/venv/bin/python"
elif [ -x "/venv/bin/python3.11" ]; then PY_BIN="/venv/bin/python3.11"
else PY_BIN="${PY_BIN:-python3.11}"; fi

need_tools=(git curl wget unzip jq)
if [ "$(id -u)" = "0" ] && command -v apt-get >/dev/null 2>&1; then
  missing=()
  for t in "${need_tools[@]}"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
  if [ "${#missing[@]}" -gt 0 ]; then
    apt-get update && apt-get install -y "${missing[@]}"
  fi
fi

if ! command -v "$PY_BIN" >/dev/null 2>&1; then
  if [ "$(id -u)" = "0" ] && command -v apt-get >/dev/null 2>&1; then
    add-apt-repository -y ppa:deadsnakes/ppa || true
    apt-get update && apt-get install -y python3.11 python3.11-venv python3.11-distutils
  else
    echo "[錯誤] 找不到 Python 3.11，請先安裝或在環境變數 PY_BIN 指向 python3.11"; exit 1;
  fi
fi

# 版本確認
"$PY_BIN" - <<'PY' | grep -q '^3\.11\.' || { echo "[錯誤] 需要 Python 3.11"; exit 1; }
import sys; print(".".join(map(str, sys.version_info[:3])))
PY

#======================= 變數/URL =======================#
WF_URL="${WF_URL:-https://raw.githubusercontent.com/DuskSleep/Face-changing-MINTS-node_ComfyUI_vast.ai_usage/main/%E6%8D%A2%E8%84%B8-MINTS.json}"

URL_JUGGER="https://huggingface.co/AiWise/Juggernaut-XL-V9-GE-RDPhoto2-Lightning_4S/resolve/main/juggernautXL_v9Rdphoto2Lightning.safetensors"
URL_IPA="https://huggingface.co/InstantX/InstantID/resolve/main/ip-adapter.bin"
URL_INST_CN="https://huggingface.co/InstantX/InstantID/resolve/main/ControlNetModel/diffusion_pytorch_model.safetensors"
URL_TT_TILE="https://huggingface.co/TTPlanet/TTPLanet_SDXL_Controlnet_Tile_Realistic/resolve/main/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors"
URL_NOMOS="https://huggingface.co/Phips/2xNomosUni_span_multijpg_ldl/resolve/main/2xNomosUni_span_multijpg_ldl.safetensors"
URL_ANTELOPE="https://github.com/deepinsight/insightface/releases/download/v0.7/antelopev2.zip"

declare -A REPOS=(
  [comfy_mtb]=https://github.com/melMass/comfy_mtb
  [ComfyMath]=https://github.com/evanspearman/ComfyMath
  [ComfyUI_Comfyroll_CustomNodes]=https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes
  [comfyui-various]=https://github.com/jamesWalker55/comfyui-various
  [ComfyUI_LayerStyle]=https://github.com/chflame163/ComfyUI_LayerStyle
  [ComfyUI_LayerStyle_Advance]=https://github.com/chflame163/ComfyUI_LayerStyle_Advance
  [ComfyUI_InstantID]=https://github.com/cubiq/ComfyUI_InstantID
  [ComfyUI_FaceAnalysis]=https://github.com/cubiq/ComfyUI_FaceAnalysis
  [rgthree-comfy]=https://github.com/rgthree/rgthree-comfy
  [ComfyUI-Custom-Scripts]=https://github.com/pythongosssss/ComfyUI-Custom-Scripts
  [ComfyUI-Easy-Use]=https://github.com/yolain/ComfyUI-Easy-Use
)

#======================= 佈局/資料夾 ====================#
mkdir -p "$COMFY_ROOT"
cd "$COMFY_ROOT"

mkdir -p custom_nodes \
         models/{checkpoints,controlnet,instantid,upscale_models,insightface/models} \
         user/default/ComfyUI-Manager \
         workflows

# 下載工作流（掃描用）
if [ ! -f workflows/mints.json ]; then
  curl -L "$WF_URL" -o workflows/mints.json || echo "[警告] 無法下載工作流（不影響安裝基本套件）"
fi

#======================= 需要的節點（掃描 + 必裝） ======#
MUST_HAVE=(comfy_mtb ComfyMath ComfyUI_Comfyroll_CustomNodes comfyui-various ComfyUI_LayerStyle ComfyUI_LayerStyle_Advance ComfyUI_InstantID ComfyUI_FaceAnalysis rgthree-comfy ComfyUI-Custom-Scripts ComfyUI-Easy-Use)
declare -A NEED; for k in "${MUST_HAVE[@]}"; do NEED[$k]=1; done
UNKNOWN=()

if [ -f workflows/mints.json ] && command -v jq >/dev/null 2>&1; then
  mapfile -t CLASSES < <(jq -r '.nodes[].class_type' workflows/mints.json | sort -u)
  for c in "${CLASSES[@]}"; do
    case "$c" in
      "Note Plus (mtb)") NEED[comfy_mtb]=1 ;;
      CM_*) NEED[ComfyMath]=1 ;;
      "CR "*|CR*) NEED[ComfyUI_Comfyroll_CustomNodes]=1 ;;
      LayerMask:*|LayerUtility:*) NEED[ComfyUI_LayerStyle]=1 ;;
      ApplyInstantID|InstantIDModelLoader) NEED[ComfyUI_InstantID]=1 ;;
      InstantIDFaceAnalysis|FaceBoundingBox|FaceAnalysisModels) NEED[ComfyUI_FaceAnalysis]=1 ;;
      JW*|JWImageResizeByLongerSide|JWInteger) NEED[comfyui-various]=1 ;;
      "Image Comparer (rgthree)") NEED[rgthree-comfy]=1 ;;
      ConstrainImage*|"ConstrainImage|pysssss") NEED[ComfyUI-Custom-Scripts]=1 ;;
      easy\ *) NEED[ComfyUI-Easy-Use]=1 ;;
      *) UNKNOWN+=("$c");;
    esac
  done
fi

clone_or_update() {
  local name="$1" url="$2" dst="custom_nodes/$1"
  if [ -d "$dst/.git" ]; then git -C "$dst" pull --ff-only || echo "[警告] 更新 $name 失敗"
  elif [ -d "$dst" ]; then echo "[警告] $dst 已存在（非 git），略過"
  else git clone --depth 1 "$url" "$dst" || echo "[警告] 下載 $name 失敗"; fi
}
for name in "${!NEED[@]}"; do clone_or_update "$name" "${REPOS[$name]}"; done

# 安裝各節點 requirements
"$PY_BIN" -m pip -q install -U pip
install_reqs(){ local d="$1"; [ -f "$d/requirements.txt" ] && "$PY_BIN" -m pip -q install -r "$d/requirements.txt" || true; }
for d in custom_nodes/*; do [ -d "$d" ] && install_reqs "$d"; done

# 底層依賴（包含 InsightFace 0.7 / mediapipe）
"$PY_BIN" -m pip -q install "insightface==0.7" "onnxruntime>=1.17" mediapipe opencv-python Pillow numpy || true

#======================= Manager 安規（weak） ============#
CFG_NEW="user/default/ComfyUI-Manager/config.ini"
CFG_OLD="custom_nodes/ComfyUI-Manager/config.ini"
[ -f "$CFG_NEW" ] || printf "[security]\nsecurity_level = weak\n" >"$CFG_NEW"
sed -i -E 's/^\s*security_level\s*=.*/security_level = weak/i' "$CFG_NEW" 2>/dev/null || true
[ -f "$CFG_OLD" ] && sed -i -E 's/^\s*security_level\s*=.*/security_level = weak/i' "$CFG_OLD" 2>/dev/null || true

#======================= 模型下載/放置 ===================#
fetch(){ local url="$1" dst="$2"; [ -f "$dst" ] && return 0; mkdir -p "$(dirname "$dst")"; wget -q -O "$dst" "$url" || curl -L "$url" -o "$dst"; }
fetch "$URL_JUGGER"   "models/checkpoints/juggernautXL_v9Rdphoto2Lightning.safetensors"
fetch "$URL_IPA"      "models/instantid/ip-adapter.bin"
fetch "$URL_INST_CN"  "models/controlnet/diffusion_pytorch_model.safetensors"
fetch "$URL_TT_TILE"  "models/controlnet/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors"
fetch "$URL_NOMOS"    "models/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors"

# 舊流程若找 .pth，做相容
ln -sfn "2xNomosUni_span_multijpg_ldl.safetensors" "models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" 2>/dev/null || cp -n "models/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors" "models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" || true

#======================= InsightFace v0.7/antelopev2 =====#
TMP_ZIP="$(mktemp -u)/antelopev2.zip"; mkdir -p "$(dirname "$TMP_ZIP")"
curl -L "$URL_ANTELOPE" -o "$TMP_ZIP" || echo "[警告] 下載 antelopev2.zip 失敗"
rm -rf models/insightface/models/antelopev2
unzip -o "$TMP_ZIP" -d models/insightface/models/ >/dev/null 2>&1 || echo "[警告] 解壓 antelopev2.zip 失敗"
# 壓縮包偶爾多一層資料夾，壓平
if [ -d models/insightface/models/antelopev2/antelopev2 ]; then
  mv models/insightface/models/antelopev2/antelopev2/* models/insightface/models/antelopev2/ || true
  rmdir models/insightface/models/antelopev2/antelopev2 || true
fi

#======================= 完成 ============================#
echo
echo "✅ 安裝完成（根目錄：$COMFY_ROOT）。請重啟 ComfyUI，然後載入 workflows/mints.json。"
if [ "${#UNKNOWN[@]}" -gt 0 ]; then
  echo "⚠️  以下節點在工作流中無對應固定來源（可能是新包/別名）。若仍報紅，請把名稱貼給我："
  printf ' - %s\n' "${UNKNOWN[@]}"
fi
