#!/usr/bin/env bash
set -euo pipefail

# =============================
# ComfyUI / vast.ai 簡化自動化腳本
# - 需要 Python 3.11 的既有 ComfyUI 環境
# - 降低 Manager 安全等級 -> 更新 -> 安裝常缺節點 -> 放置模型 -> 等待 8188
# - 註解皆中文，盡量不侵入你的既有啟動方式
# =============================

# ---- 可調參數（用環境變數覆蓋） ----
: "${PORT:=8188}"                                            # ComfyUI 服務埠
: "${COMFY_ROOT:=}"                                          # ComfyUI 根目錄（留空會自動猜）
: "${WORKFLOW_URL:=}"                                        # 你的工作流 JSON（供後續人工 Missing/Fix 用）
: "${GIT_PARALLEL:=1}"                                       # 是否並行 git clone（1=開）
: "${TRY_RESTART:=1}"                                        # 降安全等級後嘗試重啟（0=不動）
: "${PYTHON_BIN:=python3}"                                   # 指定 python 可執行檔（預設 python3）

# ---- 需安裝的 Custom Nodes（常見缺失清單）----
declare -a NODE_REPOS=(
  "https://github.com/melMass/comfy_mtb"                                 # Note Plus (mtb)
  "https://github.com/evanspearman/ComfyMath"                            # CM_Number* 系列
  "https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes"              # CR Upscale Image / CR Prompt Text
  "https://github.com/jamesWalker55/comfyui-various"                     # JWImageResizeByLongerSide / JWInteger
)

# ---- 需下載的模型與安裝位置 ----
# 目錄全部以 $COMFY_ROOT/models/* 為基準
declare -A MODEL_MAP=(
  # checkpoint
  ["checkpoints/juggernautXL_v9Rdphoto2Lightning.safetensors"]="https://huggingface.co/AiWise/Juggernaut-XL-V9-GE-RDPhoto2-Lightning_4S/resolve/main/juggernautXL_v9Rdphoto2Lightning.safetensors"
  # InstantID
  ["instantid/ip-adapter.bin"]="https://huggingface.co/InstantX/InstantID/resolve/main/ip-adapter.bin"
  ["controlnet/diffusion_pytorch_model.safetensors"]="https://huggingface.co/InstantX/InstantID/resolve/main/ControlNetModel/diffusion_pytorch_model.safetensors"
  # Tile ControlNet
  ["controlnet/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors"]="https://huggingface.co/TTPlanet/TTPLanet_SDXL_Controlnet_Tile_Realistic/resolve/main/TTPLANET_Controlnet_Tile_realistic_v2_fp16.safetensors"
  # Upscaler（只有 safetensors，稍後建立 .pth 同名連結）
  ["upscale_models/2xNomosUni_span_multijpg_ldl.safetensors"]="https://huggingface.co/Phips/2xNomosUni_span_multijpg_ldl/resolve/main/2xNomosUni_span_multijpg_ldl.safetensors"
)

# InsightFace antelopev2（官方 v0.7）
ANTELOPE_URL="https://github.com/deepinsight/insightface/releases/download/v0.7/antelopev2.zip"
# 若官方受限可替代來源（保留為備援，不強制）：
ALT_ANTELOPE_URL="https://sourceforge.net/projects/insightface.mirror/files/v0.7/antelopev2.zip/download"

# ========== 工具函式 ==========
log() { echo -e "\e[1;32m[INFO]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[WARN]\e[0m $*"; }
err() { echo -e "\e[1;31m[ERR ]\e[0m $*" >&2; }
die() { err "$@"; exit 1; }

need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "缺少指令：$1"; }

wait_http(){
  local url="$1" timeout="${2:-180}" i=0
  log "等待服務可用：$url（最多 ${timeout}s）"
  until curl -fsS -m 2 "$url" >/dev/null 2>&1; do
    ((i++)); if (( i>=timeout )); then return 1; fi
    sleep 1
  done
}

git_pull_or_clone(){
  local repo="$1" dest="$2"
  if [[ -d "$dest/.git" ]]; then
    log "更新節點：$dest"
    git -C "$dest" fetch --all -q || true
    git -C "$dest" reset --hard origin/HEAD -q || git -C "$dest" pull --rebase -q || true
  else
    log "安裝節點：$repo -> $dest"
    git clone --depth=1 "$repo" "$dest" -q
  fi
}

download_to(){
  local url="$1" dst="$2"
  local dst_dir; dst_dir="$(dirname "$dst")"
  mkdir -p "$dst_dir"
  log "下載：$url -> $dst"
  # 使用 curl，重試 3 次
  curl -fL --retry 3 --retry-all-errors --connect-timeout 10 -o "$dst.part" "$url" || return 1
  mv -f "$dst.part" "$dst"
}

# ========== 前置檢查 ==========
need_cmd git
need_cmd curl
need_cmd "$PYTHON_BIN"

# Python 版本提醒（不硬性終止，僅提醒）
if ! "$PYTHON_BIN" -c 'import sys; import re; v=sys.version_info; import sys; sys.exit(0 if (v.major,v.minor)==(3,11) else 1)' 2>/dev/null; then
  warn "偵測到 Python 版本非 3.11。你的環境需為 3.11，否則部分節點可能無法編譯/運作。"
fi

# 嘗試推斷 COMFY_ROOT
if [[ -z "${COMFY_ROOT}" ]]; then
  for p in "/opt/ComfyUI" "$HOME/ComfyUI" "/workspace/ComfyUI"; do
    [[ -d "$p" ]] && COMFY_ROOT="$p" && break
  done
fi
[[ -z "${COMFY_ROOT}" || ! -d "${COMFY_ROOT}" ]] && die "找不到 ComfyUI 根目錄，請以環境變數 COMFY_ROOT 指定（例如 COMFY_ROOT=/opt/ComfyUI）。"
log "使用 COMFY_ROOT：$COMFY_ROOT"

CUSTOM_NODES="$COMFY_ROOT/custom_nodes"
USER_DIR="$COMFY_ROOT/user"
MANAGER_DIR="$CUSTOM_NODES/ComfyUI-Manager"

mkdir -p "$CUSTOM_NODES" "$USER_DIR"

# 允許 git 在容器掛載路徑操作
git config --global --add safe.directory "$COMFY_ROOT" || true
git config --global --add safe.directory "$MANAGER_DIR" || true

# ========== 降低 Manager 安全等級（weak） ==========
# 新版路徑：$USER_DIR/default/ComfyUI-Manager/config.ini
# 舊版路徑：$MANAGER_DIR/config.ini
set_security_level(){
  local ini="$1"
  if [[ -f "$ini" ]]; then
    sed -i 's/^security_level *= *.*/security_level = weak/g' "$ini" || true
  else
    mkdir -p "$(dirname "$ini")"
    cat > "$ini" <<EOF
# 自動生成的 ComfyUI-Manager 設定
security_level = weak
EOF
  fi
  log "已設定 security_level=weak -> $ini"
}

set_security_level "$USER_DIR/default/ComfyUI-Manager/config.ini"
set_security_level "$MANAGER_DIR/config.ini"

# ========== 更新 ComfyUI 與 Manager ==========
if [[ -d "$COMFY_ROOT/.git" ]]; then
  log "更新 ComfyUI 本體"
  git -C "$COMFY_ROOT" fetch --all -q || true
  git -C "$COMFY_ROOT" pull --rebase -q || true
else
  warn "此 ComfyUI 非 git 管理，略過更新。"
fi

if [[ -d "$MANAGER_DIR" ]]; then
  log "更新 ComfyUI-Manager"
  git -C "$MANAGER_DIR" fetch --all -q || true
  git -C "$MANAGER_DIR" pull --rebase -q || true
else
  log "安裝 ComfyUI-Manager"
  git clone --depth=1 https://github.com/Comfy-Org/ComfyUI-Manager "$MANAGER_DIR" -q || \
  git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager "$MANAGER_DIR" -q || true
fi

# ========== 安裝常缺 Custom Nodes（簡化：直接 git clone） ==========
mkdir -p "$CUSTOM_NODES"
if [[ "${GIT_PARALLEL}" == "1" ]]; then
  for repo in "${NODE_REPOS[@]}"; do
    (
      name="$(basename "$repo")"
      git_pull_or_clone "$repo" "$CUSTOM_NODES/$name"
    ) &
  done
  wait || true
else
  for repo in "${NODE_REPOS[@]}"; do
    name="$(basename "$repo")"
    git_pull_or_clone "$repo" "$CUSTOM_NODES/$name"
  done
fi

# ========== 下載模型到指定位置 ==========
for relpath in "${!MODEL_MAP[@]}"; do
  url="${MODEL_MAP[$relpath]}"
  dst="$COMFY_ROOT/models/$relpath"
  download_to "$url" "$dst" || warn "下載失敗：$url"
done

# 為舊工作流相容：建立 .pth 同名連結（若引用 pth）
PTH_LINK="$COMFY_ROOT/models/upscale_models/2xNomosUni_span_multijpg_ldl.pth"
if [[ -f "$COMFY_ROOT/models/upscale_models/2xNomosUni_span_multijpg_ldl.safetensors" && ! -e "$PTH_LINK" ]]; then
  ln -s "2xNomosUni_span_multijpg_ldl.safetensors" "$PTH_LINK" || true
  log "已建立相容連結：upscale_models/2xNomosUni_span_multijpg_ldl.pth -> .safetensors"
fi

# ========== InsightFace antelopev2（修正到正確目錄） ==========
INSIGHT_DIR="$COMFY_ROOT/models/insightface/models/antelopev2"
mkdir -p "$INSIGHT_DIR"
tmpzip="$(mktemp -u)/antelopev2.zip"; mkdir -p "$(dirname "$tmpzip")"
if download_to "$ANTELOPE_URL" "$tmpzip" || download_to "$ALT_ANTELOPE_URL" "$tmpzip"; then
  log "解壓 antelopev2 到 $INSIGHT_DIR"
  unzip -oq "$tmpzip" -d "$COMFY_ROOT/models/insightface/models/" || warn "解壓失敗，請手動確認 zip。"
  # 有些壓縮包會解到 antelopev2/ 或直接是 .onnx，統一整理
  if compgen -G "$INSIGHT_DIR/*.onnx" >/dev/null; then
    :
  else
    # 若解壓到其他子層資料夾，搬運所有 .onnx
    find "$COMFY_ROOT/models/insightface/models" -maxdepth 2 -type f -name "*.onnx" -exec mv -f {} "$INSIGHT_DIR"/ \; || true
  fi
  rm -f "$tmpzip"
else
  warn "下載 antelopev2 失敗，請稍後再試或手動放置到 $INSIGHT_DIR"
fi

# ========== 嘗試重啟（使 security_level 生效），並等待 8188 ==========
maybe_restart(){
  # 嘗試以較安全的方式重啟；若你的環境有 run_nvidia.sh，就用它；否則不硬殺現有進程。
  if [[ "$TRY_RESTART" != "1" ]]; then
    warn "未自動重啟（TRY_RESTART=0），若要套用 security_level=weak 請自行重啟 ComfyUI。"
    return 0
  fi

  if pgrep -f "ComfyUI/.*/main.py" >/dev/null 2>&1 || pgrep -f "python.*ComfyUI.*main.py" >/dev/null 2>&1; then
    warn "偵測到 ComfyUI 正在執行。將嘗試柔性重啟。"
    # 嘗試透過 pkill -INT 給終止訊號（避免硬殺）
    pkill -INT -f "ComfyUI/.*/main.py" 2>/dev/null || pkill -INT -f "python.*ComfyUI.*main.py" 2>/dev/null || true
    sleep 3
  fi

  if [[ -x "$COMFY_ROOT/run_nvidia.sh" ]]; then
    log "以 run_nvidia.sh 後台啟動 ComfyUI"
    (cd "$COMFY_ROOT" && nohup ./run_nvidia.sh --port "$PORT" >/dev/null 2>&1 &)
  elif [[ -f "$COMFY_ROOT/main.py" ]]; then
    log "以 $PYTHON_BIN 啟動 ComfyUI（背景）"
    (cd "$COMFY_ROOT" && nohup "$PYTHON_BIN" main.py --listen 0.0.0.0 --port "$PORT" >/dev/null 2>&1 &)
  else
    warn "找不到啟動腳本與 main.py，略過自動啟動；請以你的原啟動方式重啟。"
  fi
}

maybe_restart

if ! wait_http "http://127.0.0.1:${PORT}/" 180; then
  warn "等待 8188 逾時，請確認 ComfyUI 是否已啟動無誤。"
else
  log "ComfyUI 已可連線：http://127.0.0.1:${PORT}/"
fi

# 顯示補充資訊
if [[ -n "${WORKFLOW_URL}" ]]; then
  log "你的工作流（供後續在 UI 內 Missing/Try Fix 使用）：$WORKFLOW_URL"
fi

log "完成。建議步驟：打開 UI -> Manager ->（若仍缺）Missing / Try Fix，再次載入你的工作流驗證。"
