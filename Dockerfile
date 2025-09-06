# syntax=docker/dockerfile:1.7
# comfyui-mints:py311-cu121
FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    VENV_PATH=/venv \
    COMFY_ROOT=/opt/ComfyUI \
    SCRIPTS=/opt/scripts \
    COMFY_PORT=8188 \
    COMFY_HOST=0.0.0.0 \
    AUTO_DOWNLOAD=1 \
    ACCEPT_3P_LICENSES=1 \
    PATH=/venv/bin:$PATH

# 系統相依
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 python3.11-venv python3-pip git git-lfs curl wget unzip ca-certificates \
    libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 ffmpeg && \
    rm -rf /var/lib/apt/lists/* && \
    git lfs install

# venv（Python 3.11）
RUN python3.11 -m venv ${VENV_PATH} && \
    ${VENV_PATH}/bin/pip install --upgrade pip setuptools wheel

# 取得 ComfyUI 本體
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git ${COMFY_ROOT}

# 安裝 PyTorch CUDA 12.1 + 其他必需套件
RUN ${VENV_PATH}/bin/pip install --no-cache-dir \
      torch==2.3.1+cu121 torchvision==0.18.1+cu121 torchaudio==2.3.1+cu121 \
      -f https://download.pytorch.org/whl/cu121 && \
    ${VENV_PATH}/bin/pip install --no-cache-dir -r ${COMFY_ROOT}/requirements.txt && \
    ${VENV_PATH}/bin/pip install --no-cache-dir \
      xformers==0.0.27.post2 \
      mediapipe==0.10.14 \
      insightface==0.7.3 \
      onnxruntime-gpu==1.18.0 \
      opencv-python-headless \
      fastapi uvicorn

# 安裝 ComfyUI-Manager 與常用自訂節點
RUN mkdir -p ${COMFY_ROOT}/custom_nodes && \
    cd ${COMFY_ROOT}/custom_nodes && \
    git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager.git && \
    git clone --depth=1 https://github.com/cubiq/ComfyUI_InstantID.git && \
    git clone --depth=1 https://github.com/melMass/comfy_mtb.git && \
    git clone --depth=1 https://github.com/evanspearman/ComfyMath.git && \
    git clone --depth=1 https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git && \
    git clone --depth=1 https://github.com/jamesWalker55/comfyui-various.git

# Manager 設為弱安全級別
RUN mkdir -p ${COMFY_ROOT}/custom_nodes/ComfyUI-Manager && \
    printf 'security_level=weak\n' > ${COMFY_ROOT}/custom_nodes/ComfyUI-Manager/config.ini

# 預建模型目錄
RUN mkdir -p \
    ${COMFY_ROOT}/models/checkpoints \
    ${COMFY_ROOT}/models/controlnet \
    ${COMFY_ROOT}/models/instantid \
    ${COMFY_ROOT}/models/insightface/models \
    ${COMFY_ROOT}/models/upscale_models

# 內建預設 entrypoint（若 repo 有 scripts/ 會覆蓋）
RUN mkdir -p ${SCRIPTS} && \
    printf '#!/usr/bin/env bash\nset -euo pipefail\nexport PATH="${VENV_PATH}/bin:$PATH"\ncd "${COMFY_ROOT}"\n# 這裡可依 AUTO_DOWNLOAD=1 加入自動抓模型的邏輯\nexec python main.py --listen --port ${COMFY_PORT}\n' > ${SCRIPTS}/entrypoint.sh && \
    chmod +x ${SCRIPTS}/entrypoint.sh

# 可選：若 repo 有 scripts/，就覆蓋進容器（沒有也不會失敗）
RUN --mount=type=bind,source=scripts,target=/tmp/scripts,ro,optional \
    if [ -d /tmp/scripts ]; then \
      cp -a /tmp/scripts/. ${SCRIPTS}/ && chmod +x ${SCRIPTS}/*.sh || true; \
    fi

# 可選：若 repo 有 LICENSE-THIRDPARTY.txt，帶入（沒有也不會失敗）
RUN --mount=type=bind,source=LICENSE-THIRDPARTY.txt,target=/tmp/LTP.txt,ro,optional \
    mkdir -p /licenses && \
    { [ -f /tmp/LTP.txt ] && cp /tmp/LTP.txt /licenses/LICENSE-THIRDPARTY.txt || true; }

EXPOSE 8188
ENTRYPOINT ["/opt/scripts/entrypoint.sh"]
