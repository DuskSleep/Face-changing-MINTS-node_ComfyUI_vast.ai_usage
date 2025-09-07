#!/usr/bin/env bash
# install-from-workflow.sh
# 依「换脸-MINTS.json」工作流比對缺失 → 放寬 Manager → 安裝指定節點 → 安裝 5 模型 → 修 insightface v0.7/antelopev2
# 僅做你紀錄列出的內容；全程在 /workspace/ComfyUI（可用 --dir 覆蓋）；不動 apt。
set -euo pipefail

# ===== 參數 =====
COMFY_DIR="/workspace/ComfyUI"
VENV="/venv"
COMFY_PORT="8188"
BASE=""                 # 自訂 API base，例如 https://xxx.cloudflare…
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
    --base)      BASE="$2"; shift 2;; # 例：--base https://your-cf-domain.example
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

cyan(){ printf "\033[1;36m%s\033[0m" "$1"; }
log(){ printf "\n%s %s\n" "$(cyan "[mints]")" "$*"; }
warn(){ printf "\n\033[1;33m[mints WARN]\033[0m %s\n" "$*"; }

PIP="$VENV/bin/pip"; [[ -x "$PIP" ]] || PIP="python3 -m pip"
[[ -d "$COMFY_DIR" ]] || { echo "COMFY_DIR not found: $COMFY_DIR"; exit 1; }

# Python 版本提示（僅警告，不變更）
PYV="$(python3 -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "unknown")"
if [[ "$PYV" != "3.11" ]]; then
  warn "建議 Python 3.11，當前 $PYV（繼續執行，但可能遇到相容性問題）"
fi

# ===== 準備 API base =====
if [[ -z "$BASE" ]]; then
  BASE="http://127.0.0.1:${COMFY_PORT}"
fi

# ===== 等待 ComfyUI /object_info 就緒（或跳過）=====
if [[ "$SKIP_WAIT" = "0" ]]; then
  log "等待 ComfyUI ${BASE}/object_info（最多 ${MAX_WAIT}s）..."
  t=0
  until curl -fsS "${BASE}/object_info" >/dev/null 2>&1; do
    sleep 3; t=$((t+3))
    if [[ $t -ge $MAX_WAIT ]]; then
      warn "逾時，繼續執行。你也可用 --skip-wait 或 --base 換檢查位址。"
      break
    fi
  done
else
  log "跳過等待 ComfyUI。"
fi

# ===== Manager 安全等級改 weak（兩個位置都寫）=====
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

# ===== 下載工作流（離線解析，不開 web）=====
TMPD="$(mktemp -d)"; WF="$TMPD/workflow.json"
log "抓取工作流：$WORKFLOW_URL"
curl -fL --retry 3 --retry-delay 2 -o "$WF" "$WORKFLOW_URL"

# ===== 取得可用節點 & 解析工作流節點 → 計算缺失（修正：不再用 tail，直接取命令輸出）=====
log "比對工作流所需節點 vs 當前可用節點 ..."
MISS_JSON="$(
python3 - <<PY
import json, os, sys, urllib.request
base = os.environ.get("BASE_INNER")
wf_path = os.environ.get("WF_INNER")
avail=set()
# 1) /object_info（若失敗也允許繼續）
try:
    with urllib.request.urlopen(base + "/object_info", timeout=5) as r:
        data=json.load(r)
        if isinstance(data, dict):
            avail=set(k for k in data.keys() if isinstance(k,str))
except Exception:
    pass
# 2) 解析工作流（class_type/type）
need=set()
with open(wf_path,"r",encoding="utf-8") as f:
    wf=json.load(f)
nodes = wf.get("nodes") or []
for n in nodes:
    ct = n.get("class_type") or n.get("type")
    if isinstance(ct,str): need.add(ct)
missing = sorted(need - avail)
print(json.dumps({"need":sorted(need), "avail_count":len(avail), "missing":missing}, ensure_ascii=False))
PY
)"
echo "$MISS_JSON"

# 轉成陣列
readarray -t MISSING < <(python3 - <<'PY' "$MISS_JSON"
import json,sys
data=json.loads(sys.argv[1])
for x in data.get("missing",[]): print(x)
PY
"$MISS_JSON"
)

# ===== 安裝你紀錄指定的四個節點（依缺失觸發，並保險補齊一次）=====
clone_or_update(){ # repo url, target dir
  local repo="$1" dir="$2"
  if [[ -d "$dir/.git" ]]; then git -C "$dir" pull --ff-only || true
  else git clone --depth=1 "$repo" "$dir"
  fi
}

log "安裝/更新缺失節點（僅限：mtb / ComfyMath / Comfyroll / various）..."
mkdir -p "$COMFY_DIR/custom_nodes"

# 依缺失名稱判斷需哪個 repo
for m in "${MISSING[@]}"; do
  case "$m" in
    Note*|*mtb* )
      clone_or_update "https://github.com/melMass/comfy_mtb" "$COMFY_DIR/custom_nodes/comfy_mtb";;
    CM_* )
      clone_or_update "https://github.com/evanspearman/ComfyMath" "$COMFY_DIR/custom_nodes/ComfyMath";;
    "CR Upscale Image"|"CR Prompt Text" )
      clone_or_update "https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes" "$COMFY_DIR/custom_nodes/ComfyUI_Comfyroll_CustomNodes";;
    JW* )
      clone_or_update "https://github.com/jamesWalker55/comfyui-various" "$COMFY_DIR/custom_nodes/comfyui-various";;
  esac
done

# 保險：若四個資料夾有缺就補
[[ -d "$COMFY_DIR/custom_nodes/comfy_mtb" ]] || clone_or_update "https://github.com/melMass/comfy_mtb" "$COMFY_DIR/custom_nodes/comfy_mtb"
[[ -d "$COMFY_DIR/custom_nodes/ComfyMath" ]] || clone_or_update "https://github.com/evanspearman/ComfyMath" "$COMFY_DIR/custom_nodes/ComfyMath"
[[ -d "$COMFY_DIR/custom_nodes/ComfyUI_Comfyroll_CustomNodes" ]] || clone_or_update "https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes" "$COMFY_DIR/custom_nodes/ComfyUI_Comfyroll_CustomNodes"
[[ -d "$COMFY_DIR/custom_nodes/comfyui-various" ]] || clone_or_update "https://github.com/jamesWalker55/comfyui-various" "$COMFY_DIR/custom_nodes/comfyui-various"

# ===== 安裝必要 Python 依賴（僅你紀錄會用到的）=====
log "安裝必要依賴（不動 apt）..."
$PIP install -q --disable-pip-version-check \
  "mediapipe==0.10.14" \
  "opencv-python-headless==4.10.*" "scikit-image" "pymatting" "guided-filter" \
  || warn "部分依賴安裝失敗，可稍後重試"

# ===== 下載模型（完全照你的紀錄與路徑）=====
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

# 4) Upscaler（僅 .safetensors）
dl "https://huggingface.co/Phips/2xNomosUni_span_multijpg_ldl/resolve/main/2xNomosUni_span_multijpg_ldl.safetensors" \
   "$COMFY_DIR/models/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors"
[[ -e "$COMFY_DIR/models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" ]] || \
ln -s "2xNomosUni_span_multijpg_ldl.safetensors" "$COMFY_DIR/models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" 2>/dev/null || true

# ===== 修復 insightface v0.7 / antelopev2 =====
log "修復 insightface/antelopev2 ..."
INS="$COMFY_DIR/models/insightface/models"
mkdir -p "$INS"; rm -rf "$INS/antelopev2" "$INS/antelopev2.zip" || true
TMPA="$(mktemp -d)"; ZIP="$TMPA/antelopev2.zip"
curl -fL -o "$ZIP" "https://github.com/deepinsight/insightface/releases/download/v0.7/antelopev2.zip"
if command -v unzip >/dev/null 2>&1; then
  unzip -o "$ZIP" -d "$TMPA/unzip" >/dev/null 2>&1 || true
else
  python3 - "$ZIP" "$TMPA/unzip" <<'PY'
import sys,zipfile,os; z=sys.argv[1];d=sys.argv[2];os.makedirs(d,exist_ok=True); zipfile.ZipFile(z).extractall(d)
PY
fi
if [[ -d "$TMPA/unzip/antelopev2" ]]; then
  mv "$TMPA/unzip/antelopev2" "$INS/antelopev2"
else
  mkdir -p "$INS/antelopev2"; cp -r "$TMPA/unzip"/* "$INS/antelopev2"/ || true
fi
rm -rf "$TMPA"

# ===== 收尾：再次列出缺失（新節點可能需在 UI 內 Reload 才會顯示）=====
log "安裝完成。重新比對（如仍有少量 missing，請在 UI 做一次：Manager → Reload Custom Nodes）..."
python3 - <<PY
import json, os, urllib.request, time
base=os.environ["BASE_INNER"]
wf_path=os.environ["WF_INNER"]
time.sleep(1)
need=set()
with open(wf_path,"r",encoding="utf-8") as f:
    wf=json.load(f)
for n in wf.get("nodes",[]): 
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
echo "📌 模型與 antelopev2 已放置完成；如工作流仍報缺，Reload Custom Nodes 後再跑一次推理即可。"

# ===== 傳遞變數給 Python 子程序 =====
#（放在最後避免污染上面邏輯）
