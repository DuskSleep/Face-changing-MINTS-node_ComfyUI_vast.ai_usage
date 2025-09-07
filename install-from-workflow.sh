#!/usr/bin/env bash
# install-from-workflow.sh
# 1) 更新 ComfyUI/ComfyUI-Manager → 安全等級 weak
# 2) 讀取工作流，觸發 Manager API 自動安裝缺失節點（/api/manager/queue/install → /api/manager/queue/start → /api/manager/reboot）
# 3) 對未覆蓋到的節點做 git fallback 安裝（僅限你的紀錄清單）
# 4) 安裝 5 個模型 + 修 insightface v0.7/antelopev2
set -euo pipefail

# ---------- args ----------
COMFY_DIR="/workspace/ComfyUI"
VENV="/venv"
COMFY_PORT="8188"
BASE=""   # e.g. https://your-cf-domain
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
    --base)      BASE="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

cyan(){ printf "\033[1;36m%s\033[0m" "$1"; }
log(){ printf "\n%s %s\n" "$(cyan "[mints]")" "$*"; }
warn(){ printf "\n\033[1;33m[mints WARN]\033[0m %s\n" "$*"; }

PIP="$VENV/bin/pip"; [[ -x "$PIP" ]] || PIP="python3 -m pip"
[[ -d "$COMFY_DIR" ]] || { echo "COMFY_DIR not found: $COMFY_DIR"; exit 1; }
[[ -n "${BASE}" ]] || BASE="http://127.0.0.1:${COMFY_PORT}"

# ---------- update ComfyUI & Manager ----------
log "更新 ComfyUI/Manager（git pull，如無 Manager 則安裝）..."
git -C "$COMFY_DIR" pull --rebase --autostash >/dev/null 2>&1 || true
mkdir -p "$COMFY_DIR/custom_nodes"
if [[ ! -d "$COMFY_DIR/custom_nodes/ComfyUI-Manager/.git" ]]; then
  git -C "$COMFY_DIR/custom_nodes" clone --depth=1 https://github.com/Comfy-Org/ComfyUI-Manager.git >/dev/null 2>&1 || \
  git -C "$COMFY_DIR/custom_nodes" clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager.git >/dev/null 2>&1 || true
else
  git -C "$COMFY_DIR/custom_nodes/ComfyUI-Manager" pull --ff-only >/dev/null 2>&1 || true
fi

# ---------- security_level = weak ----------
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

# ---------- wait /object_info (or skip) ----------
if [[ "$SKIP_WAIT" = "0" ]]; then
  log "等待 ${BASE}/object_info（最多 ${MAX_WAIT}s）..."
  t=0; until curl -fsS "${BASE}/object_info" >/dev/null 2>&1; do
    sleep 3; t=$((t+3)); [[ $t -ge $MAX_WAIT ]] && { warn "逾時，繼續"; break; }
  done
else
  log "跳過等待 ComfyUI。"
fi

# ---------- fetch workflow ----------
TMPD="$(mktemp -d)"; WF="$TMPD/workflow.json"
log "下載工作流：$WORKFLOW_URL"
curl -fL --retry 3 --retry-delay 2 -o "$WF" "$WORKFLOW_URL"

# ---------- compute missing vs. object_info ----------
log "比對工作流所需節點 vs 當前可用節點 ..."
MISS_JSON="$(
python3 - "$BASE" "$WF" <<'PY'
import json, sys, urllib.request
base, wf = sys.argv[1], sys.argv[2]
avail=set()
try:
  with urllib.request.urlopen(base + "/object_info", timeout=5) as r:
    d=json.load(r)
    if isinstance(d,dict): avail=set(k for k in d.keys() if isinstance(k,str))
except Exception: pass
need=set()
with open(wf,'r',encoding='utf-8') as f:
  w=json.load(f)
for n in w.get("nodes",[]) or []:
  ct=n.get("class_type") or n.get("type")
  if isinstance(ct,str): need.add(ct)
print(json.dumps({"need":sorted(need),"missing":sorted(need-avail),"avail_count":len(avail)}, ensure_ascii=False))
PY
)"
echo "$MISS_JSON"
readarray -t MISSING < <(python3 - "$MISS_JSON" <<'PY'
import json,sys; d=json.loads(sys.argv[1]); [print(x) for x in d.get("missing",[])]
PY
)

# ---------- map node -> repo（你紀錄的全集） ----------
declare -A MAP
MAP["mtb"]="https://github.com/melMass/comfy_mtb"
MAP["Note Plus (mtb)"]="https://github.com/melMass/comfy_mtb"
MAP["CM_"]="https://github.com/evanspearman/ComfyMath"
MAP["CR"]="https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes"
MAP["JW"]="https://github.com/jamesWalker55/comfyui-various"
MAP["LayerStyle"]="https://github.com/chflame163/ComfyUI_LayerStyle"
MAP["LayerStyleAdv"]="https://github.com/chflame163/ComfyUI_LayerStyle_Advance"
MAP["InstantID"]="https://github.com/cubiq/ComfyUI_InstantID"
MAP["FaceAnalysis"]="https://github.com/cubiq/ComfyUI_FaceAnalysis"
MAP["pysssss"]="https://github.com/pythongosssss/ComfyUI-Custom-Scripts"
MAP["rgthree"]="https://github.com/rgthree/rgthree-comfy"
MAP["EasyUse"]="https://github.com/yolain/ComfyUI-Easy-Use"

need_repos=()
for n in "${MISSING[@]}"; do
  case "$n" in
    Note*|*mtb*)            need_repos+=("${MAP["mtb"]}") ;;
    CM_* )                  need_repos+=("${MAP["CM_"]}") ;;
    "CR Upscale Image"|"CR Prompt Text") need_repos+=("${MAP["CR"]}") ;;
    JW* )                   need_repos+=("${MAP["JW"]}") ;;
    "LayerMask: "*|"LayerUtility: "*) need_repos+=("${MAP["LayerStyle"]}" "${MAP["LayerStyleAdv"]}") ;;
    ApplyInstantID|InstantIDModelLoader|InstantIDFaceAnalysis) need_repos+=("${MAP["InstantID"]}") ;;
    FaceBoundingBox|FaceAnalysisModels) need_repos+=("${MAP["FaceAnalysis"]}") ;;
    "ConstrainImage|pysssss") need_repos+=("${MAP["pysssss"]}") ;;
    "Image Comparer (rgthree)") need_repos+=("${MAP["rgthree"]}") ;;
    "easy imageColorMatch") need_repos+=("${MAP["EasyUse"]}") ;;
  esac
done
# 去重
uniq_repos=($(printf "%s\n" "${need_repos[@]}" | awk '!x[$0]++'))

# ---------- try Manager API to install missing ----------
mgr_install(){
  local repo="$1"
  local id="$(basename "$repo")"
  curl -fsS -X POST "${BASE}/api/manager/queue/install" \
    -H 'Content-Type: application/json' \
    --data-raw "{\"id\":\"${id}\",\"version\":\"nightly\",\"selected_version\":\"nightly\",\"skip_post_install\":false,\"ui_id\":\"\",\"mode\":\"remote\",\"repository\":\"${repo}\",\"channel\":\"https://raw.githubusercontent.com/Comfy-Org/ComfyUI-Manager/main/\"}" >/dev/null
}

if [[ ${#uniq_repos[@]} -gt 0 ]]; then
  log "透過 Manager 佇列安裝缺失節點（若 API 不可用會自動 fallback）..."
  ok_cnt=0; fail_cnt=0
  for r in "${uniq_repos[@]}"; do
    if mgr_install "$r"; then ok_cnt=$((ok_cnt+1)); else fail_cnt=$((fail_cnt+1)); fi
  done
  # 啟動佇列（開始安裝）
  curl -fsS "${BASE}/api/manager/queue/start" >/dev/null || true
  # 重啟以載入新節點（官方提供 /api/manager/reboot）
  curl -fsS "${BASE}/api/manager/reboot" >/dev/null || true
  log "Manager 佇列提交完成（成功:${ok_cnt} 失敗:${fail_cnt}）。如 API 不通，將改用 git fallback。"
else
  log "工作流未檢出需 Manager 安裝的節點。"
fi

# ---------- fallback：git 安裝（僅限你的紀錄清單） ----------
clone_or_update(){ local repo="$1" dir="$2"; if [[ -d "$dir/.git" ]]; then git -C "$dir" pull --ff-only >/dev/null 2>&1 || true; else git clone --depth=1 "$repo" "$dir" >/dev/null 2>&1 || true; fi; }
log "git fallback（如 Manager 未成功安裝時保險補齊）..."
mkdir -p "$COMFY_DIR/custom_nodes"
[[ -d "$COMFY_DIR/custom_nodes/comfy_mtb" ]] || clone_or_update "${MAP["mtb"]}"            "$COMFY_DIR/custom_nodes/comfy_mtb"
[[ -d "$COMFY_DIR/custom_nodes/ComfyMath" ]] || clone_or_update "${MAP["CM_"]}"            "$COMFY_DIR/custom_nodes/ComfyMath"
[[ -d "$COMFY_DIR/custom_nodes/ComfyUI_Comfyroll_CustomNodes" ]] || clone_or_update "${MAP["CR"]}" "$COMFY_DIR/custom_nodes/ComfyUI_Comfyroll_CustomNodes"
[[ -d "$COMFY_DIR/custom_nodes/comfyui-various" ]] || clone_or_update "${MAP["JW"]}"        "$COMFY_DIR/custom_nodes/comfyui-various"
[[ -d "$COMFY_DIR/custom_nodes/ComfyUI_LayerStyle" ]] || clone_or_update "${MAP["LayerStyle"]}" "$COMFY_DIR/custom_nodes/ComfyUI_LayerStyle"
[[ -d "$COMFY_DIR/custom_nodes/ComfyUI_LayerStyle_Advance" ]] || clone_or_update "${MAP["LayerStyleAdv"]}" "$COMFY_DIR/custom_nodes/ComfyUI_LayerStyle_Advance"
[[ -d "$COMFY_DIR/custom_nodes/ComfyUI_InstantID" ]] || clone_or_update "${MAP["InstantID"]}" "$COMFY_DIR/custom_nodes/ComfyUI_InstantID"
[[ -d "$COMFY_DIR/custom_nodes/ComfyUI_FaceAnalysis" ]] || clone_or_update "${MAP["FaceAnalysis"]}" "$COMFY_DIR/custom_nodes/ComfyUI_FaceAnalysis"
[[ -d "$COMFY_DIR/custom_nodes/ComfyUI-Custom-Scripts" ]] || clone_or_update "${MAP["pysssss"]}" "$COMFY_DIR/custom_nodes/ComfyUI-Custom-Scripts"
[[ -d "$COMFY_DIR/custom_nodes/rgthree-comfy" ]] || clone_or_update "${MAP["rgthree"]}"     "$COMFY_DIR/custom_nodes/rgthree-comfy"
[[ -d "$COMFY_DIR/custom_nodes/ComfyUI-Easy-Use" ]] || clone_or_update "${MAP["EasyUse"]}"  "$COMFY_DIR/custom_nodes/ComfyUI-Easy-Use"

# ---------- minimal deps（你的紀錄需要 mediapipe 等） ----------
log "安裝必要 Python 依賴（不動 apt）..."
$PIP install -q --disable-pip-version-check mediapipe==0.10.14 opencv-python-headless==4.10.* scikit-image pymatting guided-filter || true

# ---------- models ----------
log "下載/放置模型 ..."
mkdir -p "$COMFY_DIR/models/checkpoints" "$COMFY_DIR/models/instantid" "$COMFY_DIR/models/controlnet" "$COMFY_DIR/models/upscale_models" "$COMFY_DIR/models/insightface/models"
dl(){ local url="$1" out="$2"; mkdir -p "$(dirname "$out")"; [[ -f "$out" ]] && { echo "已存在：$out"; return; }; (command -v aria2c >/dev/null && aria2c -x16 -s16 -k1M -o "$(basename "$out")" -d "$(dirname "$out")" "$url") || curl -fL --retry 3 --retry-delay 2 -o "$out" "$url"; }
dl "https://huggingface.co/AiWise/Juggernaut-XL-V9-GE-RDPhoto2-Lightning_4S/resolve/main/juggernautXL_v9Rdphoto2Lightning.safetensors" "$COMFY_DIR/models/checkpoints/juggernautXL_v9Rdphoto2Lightning.safetensors"
dl "https://huggingface.co/InstantX/InstantID/resolve/main/ip-adapter.bin" "$COMFY_DIR/models/instantid/ip-adapter.bin"
dl "https://huggingface.co/InstantX/InstantID/resolve/main/ControlNetModel/diffusion_pytorch_model.safetensors" "$COMFY_DIR/models/controlnet/diffusion_pytorch_model.safetensors"
dl "https://huggingface.co/TTPlanet/TTPLanet_SDXL_Controlnet_Tile_Realistic/resolve/main/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors" "$COMFY_DIR/models/controlnet/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors"
dl "https://huggingface.co/Phips/2xNomosUni_span_multijpg_ldl/resolve/main/2xNomosUni_span_multijpg_ldl.safetensors" "$COMFY_DIR/models/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors"
[[ -e "$COMFY_DIR/models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" ]] || ln -s "2xNomosUni_span_multijpg_ldl.safetensors" "$COMFY_DIR/models/upscale_models/2xNomosUni_span_multijpg_ldl.pth" 2>/dev/null || true

# ---------- fix insightface v0.7 / antelopev2 ----------
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

# ---------- final check ----------
log "重新比對（若仍有缺，請 UI：Manager → Reload Custom Nodes 後再試一次推理）..."
python3 - "$BASE" "$WF" <<'PY'
import json, sys, urllib.request, time
base, wf = sys.argv[1], sys.argv[2]
for _ in range(40):
  try:
    with urllib.request.urlopen(base + "/object_info", timeout=3) as r:
      _=r.read(); break
  except Exception: time.sleep(1)
need=set()
with open(wf,'r',encoding='utf-8') as f:
  w=json.load(f)
for n in w.get("nodes",[]) or []:
  ct=n.get("class_type") or n.get("type")
  if isinstance(ct,str): need.add(ct)
avail=set()
try:
  with urllib.request.urlopen(base + "/object_info", timeout=5) as r:
    d=json.load(r)
    if isinstance(d,dict): avail=set(k for k in d.keys() if isinstance(k,str))
except Exception: pass
print(json.dumps({"missing_after_install": sorted(need - avail)}, ensure_ascii=False))
PY

echo
echo "✅ 完成：已觸發 Manager 安裝 + 模型就位 + antelopev2 修復。"
