# Dockerfile  — comfyui-mints:py311-cu121
FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    VENV_PATH=/venv \
    COMFY_ROOT=/opt/ComfyUI \
    SCRIPTS=/opt/scripts \
    COMFY_PORT=8188 \
    COMFY_HOST=0.0.0.0 \
    # 首次啟動是否自動下載模型（可在 vast.ai 環境變數覆寫）
    AUTO_DOWNLOAD=1 \
    # 遵守第三方模型授權
    ACCEPT_3P_LICENSES=1

# 依賴
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 python3.11-venv python3-pip git git-lfs curl wget unzip ca-certificates \
    libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 ffmpeg && \
    rm -rf /var/lib/apt/lists/* && \
    git lfs install

# venv（明確使用 Python 3.11）
RUN python3.11 -m venv ${VENV_PATH} && \
    ${VENV_PATH}/bin/pip install --upgrade pip setuptools wheel

# 取得 ComfyUI 本體
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git ${COMFY_ROOT}

# 安裝 PyTorch CUDA 12.1 + 其他必需套件（與 py311 相容）
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

# 安裝 ComfyUI-Manager 與自訂節點
RUN mkdir -p ${COMFY_ROOT}/custom_nodes && \
    cd ${COMFY_ROOT}/custom_nodes && \
    git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager.git && \
    git clone --depth=1 https://github.com/cubiq/ComfyUI_InstantID.git && \
    git clone --depth=1 https://github.com/melMass/comfy_mtb.git && \
    git clone --depth=1 https://github.com/evanspearman/ComfyMath.git && \
    git clone --depth=1 https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git && \
    git clone --depth=1 https://github.com/jamesWalker55/comfyui-various.git

# 降低 Manager 安全等級（weak）
RUN mkdir -p ${COMFY_ROOT}/custom_nodes/ComfyUI-Manager && \
    touch ${COMFY_ROOT}/custom_nodes/ComfyUI-Manager/config.ini && \
    sed -i 's/^security_level=.*$/security_level=weak/g' ${COMFY_ROOT}/custom_nodes/ComfyUI-Manager/config.ini || \
    echo "security_level=weak" >> ${COMFY_ROOT}/custom_nodes/ComfyUI-Manager/config.ini

# 預建目錄
RUN mkdir -p \
    ${COMFY_ROOT}/models/checkpoints \
    ${COMFY_ROOT}/models/controlnet \
    ${COMFY_ROOT}/models/instantid \
    ${COMFY_ROOT}/models/insightface/models \
    ${COMFY_ROOT}/models/upscale_models

# 放置腳本與授權提示
RUN mkdir -p ${SCRIPTS}
COPY scripts/ ${SCRIPTS}/
RUN chmod +x ${SCRIPTS}/*.sh
COPY LICENSE-THIRDPARTY.txt /licenses/LICENSE-THIRDPARTY.txt

EXPOSE 8188

# 入口：啟動時自動下載缺檔並啟動 ComfyUI
ENTRYPOINT ["/opt/scripts/entrypoint.sh"]
