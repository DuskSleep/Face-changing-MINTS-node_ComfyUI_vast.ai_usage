#!/usr/bin/env bash
# install-from-workflow.sh (fixed)
# 依工作流比對缺失 → Manager 設 weak → 補 4 指定節點 → 裝 5 模型 → 修 insightface v0.7/antelopev2
set -euo pipefail

# ----- 參數 -----
COMFY_DIR="/workspace/ComfyUI"
VENV="/venv"
COMFY_PORT="8188"
BASE=""
WORKFLOW_URL="https://raw.githubusercontent.com/DuskSleep/Face-changing-MINTS-node_ComfyUI_vast.ai_usage/main/%E6%8D%A2%E8%84%B8-MINTS.json"
MAX_WAIT="480"
SKIP_WAIT="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)       COMFY_DIR="$2"; shift 2;;
    --venv)      VENV="$2"; shift 2;;
    --port)      COMFY_PORT="$2"; shift 2;;
    --workflow)  WORKFLOW_URL="$2"; shift 2;;
    --max-wait)  MAX_WAIT="$2"; shift 2;;
    --skip-wait) SKIP_WAIT="1"; shift 1;;
    --base)      BASE="$2"; shift 2;;   # 例：--base https://你的CF域名
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

cyan(){ printf "\033[1;36m%s\033[0m" "$1"; }
log(){ printf "\n%s %s\n" "$(cyan "[mints]")" "$*"; }
warn(){ printf "\n\033[1;33m[mints WARN]\033[0m %s\n" "$*"; }

PIP="$VENV/bin/pip"; [[ -x "$PIP" ]] || PIP="python3 -m pip"
[[ -d "$COMFY_DIR" ]] || { echo "COMFY_DIR not found: $COMFY_DIR"; exit 1; }

PYV="$(python3 -c 'import sys;print(f\"{sys.version_info.major}.{sys.version_info.minor}\")' 2>/dev/null || echo "unknown")"
[[ "$PYV" == "3.11" ]] || warn "建議 Python 3.11，當前 $PYV（仍繼續）"

[[ -n "$BASE" ]] || BASE="http://127.0.0.1:${COMFY_PORT}"

# ----- 等待（可 skip）-----
if [[ "$SKIP_WAIT" = "0" ]]; then
  log "等待 ${BASE}/object_info（最多 ${MAX_WAIT}s）..."
  t=0
  until curl -fsS "${BASE}/object_info" >/dev/null 2>&1; do
    sleep 3; t=$((t+3)); [[ $t -ge $MAX_WAIT ]] && { warn "逾時，繼續"; break; }
  done
else
  log "跳過等待 ComfyUI。"
fi

# ----- Manager 設 weak -----
log "設定 ComfyUI-Manager security_level=weak ..."
for cfg in "$COMFY_DIR/custom_nodes/ComfyUI-Manager/config.ini" \
           "$COMFY_DIR/user/default/ComfyUI-Manager/config.ini"; do
  mkdir -p "$(dirname "$cfg")"; touch "$cfg"
  if ! grep -q "\[Environment\]" "$cfg"; then
    printf "[Environment]\nsecurity_level = weak\n" > "$cfg"
  else
    sed -i 's/^security_level *= *.*/security_level = weak/' "$cfg" || true
    grep -q '^security_level' "$cfg" || printf "security_level = weak\n" >> "$cfg"
  fi
done

# ----- 抓工作流 -----
TMPD="$(mktemp -d)"; WF="$TMPD/workflow.json"
log "下載工作流：$WORKFLOW_URL"
curl -fL --retry 3 --retry-delay 2 -o "$WF" "$WORKFLOW_URL"

# ----- 比對缺失（使用命令引數；不吃環境變數）-----
log "比對工作流所需節點 vs 當前可用節點 ..."
MISS_JSON="$(
python3 - "$BASE" "$WF" <<'PY'
import json, sys, urllib.request
base, wf_path = sys.argv[1], sys.argv[2]
avail=set()
try:
    with urllib.request.urlopen(base + "/object_info", timeout=5) as r:
        data=json.load(r)
        if isinstance(data, dict): avail=set(k for k in data.keys() if isinstance(k,str))
except Exception:
    pass
need=set()
with open(wf_path,"r",encoding="utf-8") as f:
    wf=json.load(f)
for n in wf.get("nodes",[]) or []:
    ct = n.get("class_type") or n.get("type")
    if isinstance(ct,str): need.add(ct)
missing = sorted(need - avail)
print(json.dumps({"need":sorted(need), "avail_count":len(avail), "missing":missing}, ensure_ascii=False))
PY
)"
echo "$MISS_JSON"

readarray -t MISSING < <(python3 - "$MISS_JSON" <<'PY'
import json,sys
data=json.loads(sys.argv[1])
for x in data.get("missing",[]): print(x)
PY
)

# ----- 安裝 4 指定節點 -----
clone_or_update(){ local repo="$1" dir="$2"; if [[ -d "$dir/.git" ]]; then git -C "$dir" pull --ff-only || true; else git clone --depth=1 "$repo" "$dir"; fi; }
log "安裝/更新缺失節點 ..."
mkdir -p "$COMFY_DIR/custom_nodes"
for m in "${MISSING[@]}"; do
  case "$m" in
    Note*|*mtb*) clone_or_update "https://github.com/melMass/comfy_mtb"                         "$COMFY_DIR/custom_nodes/comfy_mtb" ;;
    CM_*)        clone_or_update "https://github.com/evanspearman/ComfyMath"                     "$COMFY_DIR/custom_nodes/ComfyMath" ;;
    "CR Upscale Image"|"CR Prompt Text")
                 clone_or_update "https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes"       "$COMFY_DIR/custom_nodes/ComfyUI_Comfyroll_CustomNodes" ;;
    JW*)         clone_or_update "https://github.com/jamesWalker55/comfyui-various"              "$COMFY_DIR/custom_nodes/comfyui-various" ;;
  esac
done
[[ -d "$COMFY_DIR/custom_nodes/comfy_mtb" ]] || clone_or_update "https://github.com/melMass/comfy_mtb"                         "$COMFY_DIR/custom_nodes/comfy_mtb"
[[ -d "$COMFY_DIR/custom_nodes/ComfyMath" ]] || clone_or_update "https://github.com/evanspearman/ComfyMath"                     "$COMFY_DIR/custom_nodes/ComfyMath"
[[ -d "$COMFY_DIR/custom_nodes/ComfyUI_Comfyroll_CustomNodes" ]] || clone_or_update "https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes" "$COMFY_DIR/custom_nodes/ComfyUI_Comfyroll_CustomNodes"
[[ -d "$COMFY_DIR/custom_nodes/comfyui-various" ]] || clone_or_update "https://github.com/jamesWalker55/comfyui-various"        "$COMFY_DIR/custom_nodes/comfyui-various"

# ----- 依賴（僅紀錄需要）-----
log "安裝必要依賴（不動 apt）..."
$PIP install -q --disable-pip-version-check mediapipe==0.10.14 opencv-python-headless==4.10.* scikit-image pymatting guided-filter || true

# ----- 下載模型（完全照紀錄）-----
log "下載/放置模型 ..."
mkdir -p "$COMFY_DIR/models/checkpoints" "$COMFY_DIR/models/instantid" "$COMFY_DIR/models/controlnet" "$COMFY_DIR/models/upscale_models" "$COMFY_DIR/models/insightface/models"
dl(){ local url="$1" out="$2"; mkdir -p "$(dirname "$out")"; [[ -f "$out" ]] && { echo "已存在：$out"; return; }; (command -v aria2c >/dev/null && aria2c -x16 -s16 -k1M -o "$(basename "$out")" -d "$(dirname "$out")" "$url") || curl -fL --retry 3 --retry-delay 2 -o "$out" "$url"; }
dl "https://huggingface.co/AiWise/Juggernaut-XL-V9-GE-RDPhoto2-Lightning_4S/resolve/main/juggernautXL_v9Rdphoto2Lightning.safetensors" "$COMFY_DIR/models/checkpoints/juggernautXL_v9Rdphoto2Lightning.safetensors"
dl "https://huggingface.co/InstantX/InstantID/resolve/main/ip-adapter.bin" "$COMFY_DIR/models/instantid/ip-adapter.bin"
dl "https://huggingface.co/InstantX/InstantID/resolve/main/ControlNetModel/diffusion_pytorch_model.safetensors" "$COMFY_DIR/models/controlnet/diffusion_pytorch_model.safetensors"
dl "https://huggingface.co/TTPlanet/TTPLanet_SDXL_Controlnet_Tile_Realistic/resolve/main/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors" "$COMFY_DIR/models/controlnet/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors"
dl "https://huggingface.co/Phips/2xNomosUni_span_multijpg_ldl/resolve/main/2xNomosUni_span_multijpg_ldl.safetensors" "$COMFY_DIR/models/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors"
[[ -e "$COMFY_DIR/models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" ]] || ln -s "2xNomosUni_span_multijpg_ldl.safetensors" "$COMFY_DIR/models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" 2>/dev/null || true

# ----- 修 insightface v0.7 / antelopev2 -----
log "修復 insightface/antelopev2 ..."
INS="$COMFY_DIR/models/insightface/models"
mkdir -p "$INS"; rm -rf "$INS/antelopev2" "$INS/antelopev2.zip" || true
TMPA="$(mktemp -d)"; ZIP="$TMPA/antelopev2.zip"
curl -fL -o "$ZIP" "https://github.com/deepinsight/insightface/releases/download/v0.7/antelopev2.zip"
if command -v unzip >/dev/null 2>&1; then unzip -o "$ZIP" -d "$TMPA/unzip" >/dev/null 2>&1 || true
else python3 - "$ZIP" "$TMPA/unzip" <<'PY'
import sys,zipfile,os; z=sys.argv[1];d=sys.argv[2];os.makedirs(d,exist_ok=True); zipfile.ZipFile(z).extractall(d)
PY
fi
if [[ -d "$TMPA/unzip/antelopev2" ]]; then
  mv "$TMPA/unzip/antelopev2" "$INS/antelopev2"
else
  mkdir -p "$INS/antelopev2"; cp -r "$TMPA/unzip"/* "$INS/antelopev2"/ || true
fi
rm -rf "$TMPA"

# ----- 收尾：再比一次 -----
log "安裝完成。重新比對（若仍有缺，請在 UI：Manager → Reload Custom Nodes）..."
python3 - "$BASE" "$WF" <<'PY'
import json, sys, urllib.request
base, wf_path = sys.argv[1], sys.argv[2]
need=set()
with open(wf_path,"r",encoding="utf-8") as f:
    wf=json.load(f)
for n in wf.get("nodes",[]) or []:
    ct=n.get("class_type") or n.get("type")
    if isinstance(ct,str): need.add(ct)
avail=set()
try:
    with urllib.request.urlopen(base + "/object_info", timeout=5) as r:
        data=json.load(r)
        if isinstance(data,dict): avail=set(k for k in data.keys() if isinstance(k,str))
except Exception:
    pass
print(json.dumps({"missing_after_install": sorted(need - avail)}, ensure_ascii=False))
PY

echo
echo "📌 模型與 antelopev2 已放置；2xNomos 也建了 .pth 相容連結。"
