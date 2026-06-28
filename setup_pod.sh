#!/usr/bin/env bash
# =============================================================================
# CartoonAutomation — Vast.ai Pod Setup Script
# Run this inside the Vast.ai pod after SSH-ing in.
# The script is IDEMPOTENT — safe to run multiple times on the same pod.
# =============================================================================
set -euo pipefail

WORKSPACE="/workspace"
LOG_FILE="$WORKSPACE/setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo " CartoonAutomation Pod Setup"
echo " $(date)"
echo "=============================================="

# ── 1. System dependencies ────────────────────────────────────────────────────
echo "[1/7] Installing system packages..."
apt-get update -qq
apt-get install -y -qq git ffmpeg wget curl unzip rsync htop nvtop 2>/dev/null || true

# ── 2. Python environment check ──────────────────────────────────────────────
echo "[2/7] Checking Python environment..."
python3 --version
pip3 install --upgrade pip -q

# ── 3. Install Python dependencies ───────────────────────────────────────────
echo "[3/7] Installing Python packages (this takes ~5 min)..."
pip3 install --no-cache-dir -q \
    fastapi>=0.111.0 \
    uvicorn>=0.30.0 \
    Pillow>=10.0.0 \
    "imageio[ffmpeg]>=2.34.0" \
    torch>=2.3.0 \
    diffusers>=0.32.0 \
    transformers>=4.44.0 \
    accelerate>=0.33.0 \
    sentencepiece \
    protobuf \
    bitsandbytes>=0.43.0
echo "  Python packages installed."

# ── 4. Install kohya_ss for LoRA training ────────────────────────────────────
echo "[4/7] Setting up kohya_ss LoRA trainer..."
if [ -d "$WORKSPACE/kohya_ss" ]; then
    echo "  kohya_ss already cloned — skipping."
else
    git clone --depth=1 https://github.com/kohya-ss/sd-scripts "$WORKSPACE/kohya_ss"
    cd "$WORKSPACE/kohya_ss"
    pip3 install --no-cache-dir -q -r requirements.txt
    pip3 install --no-cache-dir -q bitsandbytes
    cd "$WORKSPACE"
    echo "  kohya_ss installed."
fi

# ── 5. Copy server files (uploaded via rsync from local machine) ──────────────
echo "[5/7] Checking for server files..."
if [ ! -f "$WORKSPACE/hunyuan_server.py" ]; then
    echo "  WARNING: hunyuan_server.py not found in $WORKSPACE."
    echo "  Upload it from your local machine with:"
    echo "    rsync -avz knowledge_base/scripts/vastai/ <user>@<pod-ip>:/workspace/"
else
    echo "  hunyuan_server.py found."
fi

if [ ! -f "$WORKSPACE/wan22_server.py" ]; then
    echo "  WARNING: wan22_server.py not found in $WORKSPACE."
else
    echo "  wan22_server.py found."
fi

# ── 6. Pre-download model weights ─────────────────────────────────────────────
# When NONINTERACTIVE=1 (set by vast_session.ps1) skip prompts and defer
# model downloads to first request. Pass NONINTERACTIVE=0 to be prompted.
echo "[6/7] Model weight pre-download..."
NONINTERACTIVE="${NONINTERACTIVE:-0}"

if [ "$NONINTERACTIVE" = "1" ]; then
    echo "  Non-interactive mode: skipping pre-download."
    echo "  Models will download automatically on first video generation request (~10-20 min)."
else
    read -p "  Download HunyuanVideo-1.5 weights now? (~15 min) [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        python3 -c "
from diffusers import HunyuanVideoImageToVideoPipeline
import torch
print('Downloading HunyuanVideo-1.5 weights...')
HunyuanVideoImageToVideoPipeline.from_pretrained('tencent/HunyuanVideo-1.5', torch_dtype=torch.bfloat16)
print('Done.')
"
    fi

    read -p "  Download Wan2.2-14B weights now? (~20 min) [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        python3 -c "
from diffusers import WanImageToVideoPipeline
import torch
print('Downloading Wan2.2-14B weights...')
WanImageToVideoPipeline.from_pretrained('Wan-AI/Wan2.2-I2V-14B-480P', torch_dtype=torch.bfloat16)
print('Done.')
"
    fi
fi

# ── 7. Create startup helper scripts ─────────────────────────────────────────
echo "[7/7] Creating session startup scripts..."

cat > "$WORKSPACE/start_hunyuan.sh" << 'EOF'
#!/bin/bash
echo "Starting HunyuanVideo-1.5 server on port 8000..."
cd /workspace
nohup uvicorn hunyuan_server:app --host 0.0.0.0 --port 8000 --timeout-keep-alive 600 > /workspace/hunyuan.log 2>&1 &
echo "PID: $!"
echo "Waiting for server to load model (30-90 sec)..."
sleep 5
until curl -sf http://localhost:8000/health > /dev/null; do
    echo "  Still loading..."
    sleep 10
done
echo "HunyuanVideo server is READY at http://$(curl -s ifconfig.me):8000"
EOF
chmod +x "$WORKSPACE/start_hunyuan.sh"

cat > "$WORKSPACE/start_wan22.sh" << 'EOF'
#!/bin/bash
echo "Starting Wan2.2-14B server on port 8001..."
cd /workspace
nohup uvicorn wan22_server:app --host 0.0.0.0 --port 8001 --timeout-keep-alive 600 > /workspace/wan22.log 2>&1 &
echo "PID: $!"
sleep 5
until curl -sf http://localhost:8001/health > /dev/null; do
    echo "  Still loading..."
    sleep 10
done
echo "Wan2.2 server is READY at http://$(curl -s ifconfig.me):8001"
EOF
chmod +x "$WORKSPACE/start_wan22.sh"

cat > "$WORKSPACE/show_ip.sh" << 'EOF'
#!/bin/bash
PUBLIC_IP=$(curl -s ifconfig.me)
echo "================================================"
echo "  Pod Public IP: $PUBLIC_IP"
echo ""
echo "  HunyuanVideo: http://$PUBLIC_IP:8000/generate"
echo "  Wan2.2:        http://$PUBLIC_IP:8001/generate"
echo ""
echo "  Set in your .env on your local machine:"
echo "  HUNYUAN_API_URL=http://$PUBLIC_IP:8000/generate"
echo "  WAN22_API_URL=http://$PUBLIC_IP:8001/generate"
echo "================================================"
EOF
chmod +x "$WORKSPACE/show_ip.sh"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo " SETUP COMPLETE"
echo "=============================================="
echo ""
echo " Next steps:"
echo "   1. Upload server files if not already done:"
echo "      rsync -avz knowledge_base/scripts/vastai/ user@$(hostname -I | awk '{print $1}'):/workspace/"
echo ""
echo "   2. Start the video server:"
echo "      bash /workspace/start_hunyuan.sh"
echo "      # or: bash /workspace/start_wan22.sh"
echo ""
echo "   3. Get the URL to paste in .env:"
echo "      bash /workspace/show_ip.sh"
echo ""
echo "   4. For LoRA training, kohya_ss is at:"
echo "      $WORKSPACE/kohya_ss/flux_train_network.py"
echo ""
echo " Log file: $LOG_FILE"
