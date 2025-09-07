#!/usr/bin/env bash
# install-from-workflow.sh
# 根據「换脸-MINTS.json」工作流做離線缺失節點比對，然後只安裝你紀錄列出的節點 & 模型。
# 位置固定在 /workspace/ComfyUI（可用 --dir 覆蓋），Python 僅提示需 3.11，不強改版本。
set -euo pipefail

# ===== 參數 =====
COMFY_DIR="/workspace/ComfyUI"
VENV="/venv"
COMFY_PORT="8188"
MAX_WAIT="480"
WORKFLOW_URL="https://raw.githubusercontent.com/DuskSleep/Face-changing-MINTS-node_ComfyUI_vast.ai_usage/main/%E6%8D%A2%E8%84%B8-MINTS.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) COMFY_DIR="$2"; shift 2;;
    --venv) VENV="$2"; shift 2;;
    --port) COMFY_PORT="$2"; shift 2;;
    --max-wait) MAX_WAIT="$2"; shift 2;;
    --workflow) WORKFLOW_URL="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

cyan(){ printf "\033[1;36m%s\033[0m" "$1"; }
log(){ printf "\n%s %s\n" "$(cyan "[mints]")" "$*"; }
warn(){ printf "\n\033[1;33m[mints WARN]\033[0m %s\n" "$*"; }

need(){
  command -v "$1" >/dev/null 2>&1 || { warn "missing '$1'"; return 1; }
}

PIP="$VENV/bin/pip"
[[ -x "$PIP" ]] || PIP="python3 -m pip"

# ===== 基本檢查 =====
[[ -d "$COMFY_DIR" ]] || { echo "COMFY_DIR not found: $COMFY_DIR"; exit 1; }
PYV="$(python3 -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "unknown")"
if [[ "$PYV" != "3.11" ]]; then
  warn "Python 要求 3.11，目前: $PYV（將繼續執行，但可能遇到兼容性問題）"
fi

# ===== 等待 ComfyUI API 就緒（/object_info）=====
log "等待 ComfyUI 127.0.0.1:${COMFY_PORT}（最多 ${MAX_WAIT}s）..."
t=0
until curl -fsS "http://127.0.0.1:${COMFY_PORT}/object_info" >/dev/null 2>&1; do
  sleep 3; t=$((t+3))
  if [[ $t -ge $MAX_WAIT ]]; then
    warn "逾時，仍繼續。"
    break
  fi
done

# ===== 降低 Manager 安全等級為 weak（兩處都寫）=====
log "設定 ComfyUI-Manager security_level=weak ..."
for cfg in \
  "$COMFY_DIR/custom_nodes/ComfyUI-Manager/config.ini" \
  "$COMFY_DIR/user/default/ComfyUI-Manager/config.ini"
do
  mkdir -p "$(dirname "$cfg")"; touch "$cfg"
  if ! grep -q "\[Environment\]" "$cfg"; then
    printf "[Environment]\nsecurity_level = weak\n" > "$cfg"
  else
    sed -i 's/^security_level *= *.*/security_level = weak/' "$cfg" || true
    grep -q '^security_level' "$cfg" || printf "security_level = weak\n" >> "$cfg"
  fi
done

# ===== 下載工作流（離線解析用，不走 Web UI）=====
TMPD="$(mktemp -d)"; WF="$TMPD/workflow.json"
log "抓取工作流：$WORKFLOW_URL"
curl -fL --retry 3 --retry-delay 2 -o "$WF" "$WORKFLOW_URL"

# ===== 取出「已安裝節點清單」與「工作流需要的節點」，計算缺失 =====
log "比對工作流所需節點 vs 當前可用節點 ..."
python3 - "$COMFY_PORT" "$WF" <<'PY'
import json, sys, urllib.request
port, wf_path = sys.argv[1], sys.argv[2]

# 1) 取得目前可用節點（/object_info）
avail = set()
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/object_info", timeout=5) as r:
        data = json.load(r)
        # 形態可能是 { "CheckpointLoaderSimple": {...}, "KSampler": {...}, ... }
        if isinstance(data, dict):
            avail = set(k for k in data.keys() if isinstance(k, str))
except Exception:
    pass

# 2) 解析工作流，抓 class_type / type
need = set()
with open(wf_path, 'r', encoding='utf-8') as f:
    wf = json.load(f)
nodes = wf.get("nodes") or []
for n in nodes:
    ct = n.get("class_type") or n.get("type")
    if isinstance(ct, str):
        need.add(ct)

missing = sorted(need - avail)
print(json.dumps({"need": sorted(need), "avail_count": len(avail), "missing": missing}, ensure_ascii=False))
PY
MISS_JSON="$(tail -n1)"

# 解析缺失字串為 bash 陣列
MISSING=()
if [[ "$MISS_JSON" =~ \"missing\":\ \[(.*)\] ]]; then
  # 粗略擷取，後續仍會判斷模式
  :
fi
# 直接交給 python 再列一遍乾淨清單
readarray -t MISSING < <(python3 - <<'PY' "$MISS_JSON"
import sys, json
data=json.loads(sys.argv[1])
for x in data.get("missing", []):
    print(x)
PY
"$MISS_JSON"
)

log "缺失節點：${#MISSING[@]} 個"
for m in "${MISSING[@]}"; do echo " - $m"; done

# ===== 依你的「紀錄」只安裝 4 個指定節點包（依缺失來決定是否裝）=====
install_repo(){
  local repo="$1" name="$2"
  local dest="$COMFY_DIR/custom_nodes/$name"
  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" pull --ff-only || true
  elif [[ -d "$dest" ]]; then
    # 目錄存在但不是 git，略過避免覆蓋
    :
  else
    git clone --depth=1 "$repo" "$dest"
  fi
}

needs_repo=false
for m in "${MISSING[@]}"; do
  case "$m" in
    Note*|*mtb* )               install_repo "https://github.com/melMass/comfy_mtb" "comfy_mtb"; needs_repo=true;;
    CM_* )                      install_repo "https://github.com/evanspearman/ComfyMath" "ComfyMath"; needs_repo=true;;
    "CR "* )                    install_repo "https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes" "ComfyUI_Comfyroll_CustomNodes"; needs_repo=true;;
    JW* )                       install_repo "https://github.com/jamesWalker55/comfyui-various" "comfyui-various"; needs_repo=true;;
    * ) :;;
  esac
done

# 若工作流沒有缺失（或缺失不屬於這四包），仍依「紀錄」檢查一下四包是否已存在；不存在就補裝
check_or_install(){
  local path="$1" repo="$2" name="$3"
  [[ -d "$path" ]] || install_repo "$repo" "$name"
}
check_or_install "$COMFY_DIR/custom_nodes/comfy_mtb"                       "https://github.com/melMass/comfy_mtb"                       "comfy_mtb"
check_or_install "$COMFY_DIR/custom_nodes/ComfyMath"                       "https://github.com/evanspearman/ComfyMath"                  "ComfyMath"
check_or_install "$COMFY_DIR/custom_nodes/ComfyUI_Comfyroll_CustomNodes"   "https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes"    "ComfyUI_Comfyroll_CustomNodes"
check_or_install "$COMFY_DIR/custom_nodes/comfyui-various"                 "https://github.com/jamesWalker55/comfyui-various"           "comfyui-various"

# ===== 安裝依賴（僅你紀錄需要的：mediapipe + 常見基礎）=====
log "安裝必要依賴（Py3.11 友善）..."
$PIP install -q --disable-pip-version-check \
  "mediapipe==0.10.14" \
  "opencv-python-headless==4.10.*" "scikit-image" "pymatting" "guided-filter" \
  || warn "部分依賴安裝失敗，可稍後重試"

# ===== 安裝模型（完全照你的紀錄與路徑）=====
log "下載/放置模型 ..."
mkdir -p "$COMFY_DIR/models/checkpoints" \
         "$COMFY_DIR/models/instantid" \
         "$COMFY_DIR/models/controlnet" \
         "$COMFY_DIR/models/upscale_models" \
         "$COMFY_DIR/models/insightface/models"

dl(){
  local url="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  [[ -f "$out" ]] && { echo "已存在：$out"; return 0; }
  if command -v aria2c >/dev/null 2>&1; then
    aria2c -x16 -s16 -k1M -o "$(basename "$out")" -d "$(dirname "$out")" "$url" || true
  fi
  [[ -f "$out" ]] || curl -fL --retry 3 --retry-delay 2 -o "$out" "$url"
}

# 1) checkpoints
dl "https://huggingface.co/AiWise/Juggernaut-XL-V9-GE-RDPhoto2-Lightning_4S/resolve/main/juggernautXL_v9Rdphoto2Lightning.safetensors" \
   "$COMFY_DIR/models/checkpoints/juggernautXL_v9Rdphoto2Lightning.safetensors"

# 2) InstantID
dl "https://huggingface.co/InstantX/InstantID/resolve/main/ip-adapter.bin" \
   "$COMFY_DIR/models/instantid/ip-adapter.bin"
dl "https://huggingface.co/InstantX/InstantID/resolve/main/ControlNetModel/diffusion_pytorch_model.safetensors" \
   "$COMFY_DIR/models/controlnet/diffusion_pytorch_model.safetensors"

# 3) TTPlanet tile SDXL
dl "https://huggingface.co/TTPlanet/TTPLanet_SDXL_Controlnet_Tile_Realistic/resolve/main/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors" \
   "$COMFY_DIR/models/controlnet/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors"

# 4) Upscaler（僅有 safetensors）
dl "https://huggingface.co/Phips/2xNomosUni_span_multijpg_ldl/resolve/main/2xNomosUni_span_multijpg_ldl.safetensors" \
   "$COMFY_DIR/models/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors"
[[ -e "$COMFY_DIR/models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" ]] || \
ln -s "2xNomosUni_span_multijpg_ldl.safetensors" "$COMFY_DIR/models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" 2>/dev/null || true

# ===== 修復 insightface v0.7 / antelopev2 到正確路徑 =====
log "修復 insightface/antelopev2 ..."
INS="$COMFY_DIR/models/insightface/models"
mkdir -p "$INS"; rm -rf "$INS/antelopev2" "$INS/antelopev2.zip" || true
TMPA="$(mktemp -d)"; ZIP="$TMPA/antelopev2.zip"
curl -fL -o "$ZIP" "https://github.com/deepinsight/insightface/releases/download/v0.7/antelopev2.zip"
if command -v unzip >/dev/null 2>&1; then
  unzip -o "$ZIP" -d "$TMPA/unzip" >/dev/null 2>&1 || true
else
  python3 - <<'PY'
import sys,zipfile,os; z=sys.argv[1];d=sys.argv[2];os.makedirs(d,exist_ok=True); zipfile.ZipFile(z).extractall(d)
PY
  "$ZIP" "$TMPA/unzip"
fi
if [[ -d "$TMPA/unzip/antelopev2" ]]; then
  mv "$TMPA/unzip/antelopev2" "$INS/antelopev2"
else
  mkdir -p "$INS/antelopev2"; cp -r "$TMPA/unzip"/* "$INS/antelopev2"/ || true
fi
rm -rf "$TMPA"

# ===== 收尾：再次列出缺失（此處僅比對名稱；如需 UI Reload，請手動 Reload or 重啟）=====
log "安裝完成。重新比對（名稱層級；新節點如未在本輪 API 出現，Reload 後即會出現）..."
python3 - "$COMFY_PORT" "$WF" <<'PY'
import json, sys, urllib.request, time
port, wf_path = sys.argv[1], sys.argv[2]
need=set()
with open(wf_path,'r',encoding='utf-8') as f:
    wf=json.load(f)
for n in wf.get("nodes",[]):
    ct=n.get("class_type") or n.get("type")
    if isinstance(ct,str): need.add(ct)
time.sleep(1)
avail=set()
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/object_info", timeout=5) as r:
        data=json.load(r)
        if isinstance(data,dict):
            avail=set(k for k in data.keys() if isinstance(k,str))
except Exception:
    pass
missing = sorted(need - avail)
print(json.dumps({"missing_after_install": missing}, ensure_ascii=False))
PY

echo
echo "📌 若仍顯示少量 missing，多半只需在 UI 做一次「Reload Custom Nodes」或重啟 ComfyUI 即會就緒。"
echo "📌 你紀錄要求的 5 個模型 & antelopev2 已就位；2xNomos… 也建立了 .pth 相容連結。"
