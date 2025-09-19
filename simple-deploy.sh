#!/bin/bash
# Kyutai STT - Simple Vast.ai Deployment (Testing Only)
# No autoscaling, no complex features - just basic live transcription

set -e

# Configuration
PROJECT_NAME="kyutai-stt"
API_PORT=${API_PORT:-8000}
BATCH_SIZE=${BATCH_SIZE:-80}
API_KEY=${API_KEY:-$(openssl rand -hex 16)}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Banner
cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                 KYUTAI STT SIMPLE DEPLOYER                  ║
║                   Testing on Vast.ai                        ║
║                                                              ║
║  🎤 Live WebSocket transcription only                        ║
╚══════════════════════════════════════════════════════════════╝
EOF

log_info "Starting simple deployment for testing..."

# Check if we're in a container
if [ -f /.dockerenv ]; then
    log_info "🐳 Detected container environment - switching to container-optimized deployment"
    curl -sSL https://raw.githubusercontent.com/spanDevOps/kyutai/main/container-deploy.sh | bash
    exit $?
fi

# Validate environment (for VM deployment)
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root. Use: sudo bash"
    exit 1
fi

# Pre-install curl for connectivity check
apt update -qq
apt install -y -qq curl openssl

# Check internet connectivity
if ! curl -s --connect-timeout 5 google.com &> /dev/null; then
    log_error "No internet connection detected. Please check your network."
    exit 1
fi
log_success "Internet connectivity verified"

# Check GPU
if command -v nvidia-smi &> /dev/null; then
    GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits | head -1)
    GPU_MEMORY=$(echo $GPU_INFO | cut -d',' -f2 | tr -d ' ')
    log_success "GPU detected: $GPU_INFO"
    
    if [ "$GPU_MEMORY" -lt 16000 ]; then
        BATCH_SIZE=32
        log_warning "GPU has <16GB VRAM, reducing batch size to $BATCH_SIZE"
    fi
else
    log_error "No NVIDIA GPU detected. This deployment requires a GPU."
    exit 1
fi

# Handle containerd conflicts first  
log_info "Resolving package conflicts..."
export DEBIAN_FRONTEND=noninteractive
apt-get remove -y containerd containerd.io 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# Install dependencies
log_info "Installing system dependencies..."
if [ "${SKIP_UPGRADE:-}" != "1" ]; then
    apt upgrade -y -qq
else
    log_info "Skipping system upgrade (SKIP_UPGRADE=1)"
fi
apt install -y -qq wget git docker.io

# Install Docker Compose v2
if ! command -v docker-compose &> /dev/null; then
    log_info "Installing Docker Compose v2..."
    DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)
    curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    log_success "Docker Compose v2 installed"
else
    log_success "Docker Compose already installed"
fi

# Install NVIDIA Container Toolkit
log_info "Installing NVIDIA Container Toolkit..."
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt update -qq && apt install -y -qq nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# Setup project
PROJECT_DIR="/opt/$PROJECT_NAME"
log_info "Setting up project directory: $PROJECT_DIR"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# Create simple docker-compose.yml
log_info "Creating Docker configuration..."
cat > docker-compose.yml << EOF
version: '3.8'

services:
  kyutai-stt:
    build: .
    container_name: ${PROJECT_NAME}-server
    restart: unless-stopped
    
    ports:
      - "${API_PORT}:8000"
    
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,utility
      - API_KEY=${API_KEY}
      - BATCH_SIZE=${BATCH_SIZE}
    
    volumes:
      - model_cache:/root/.cache/huggingface
      - ./logs:/app/logs
    
    runtime: nvidia

volumes:
  model_cache:
    driver: local
EOF

# Create simple Dockerfile
cat > Dockerfile << EOF
FROM nvidia/cuda:12.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV RUST_VERSION=1.75.0
ENV RUSTUP_HOME=/opt/rust
ENV CARGO_HOME=/opt/rust
ENV PATH=/opt/rust/bin:\$PATH

# Install dependencies
RUN apt-get update && apt-get install -y \\
    curl wget git build-essential pkg-config libssl-dev \\
    python3 python3-pip python3-dev cmake \\
    && rm -rf /var/lib/apt/lists/*

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \\
    sh -s -- -y --default-toolchain \$RUST_VERSION --profile minimal
RUN chmod -R a+w /opt/rust

# Install Python dependencies
RUN pip3 install --no-cache-dir \\
    fastapi uvicorn[standard] websockets msgpack \\
    soundfile numpy

WORKDIR /app

# Copy configs (downloaded by build script)
COPY configs/ ./configs/

# Create live_api_server.py inline
RUN cat > live_api_server.py << 'PYTHON_EOF'
#!/usr/bin/env python3
import asyncio
import websockets
import msgpack
import numpy as np
import json
import time
import logging
import os
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.responses import HTMLResponse
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Kyutai STT Live API", version="2.0.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])

MOSHI_SERVER_URL = "ws://localhost:8080/api/asr-streaming"
API_KEY = os.getenv("API_KEY", "public_token")
SAMPLE_RATE = 24000
CHUNK_SIZE = 1920

class LiveTranscriptionService:
    def __init__(self):
        self.active_connections = 0
    
    async def handle_live_transcription(self, client_websocket: WebSocket):
        connection_start = time.time()
        self.active_connections += 1
        try:
            headers = {"kyutai-api-key": API_KEY}
            async with websockets.connect(MOSHI_SERVER_URL, additional_headers=headers) as moshi_ws:
                logger.info(f"Live session started. Active: {self.active_connections}")
                client_to_moshi = asyncio.create_task(self._forward_audio_to_moshi(client_websocket, moshi_ws))
                moshi_to_client = asyncio.create_task(self._forward_transcription_to_client(moshi_ws, client_websocket))
                done, pending = await asyncio.wait([client_to_moshi, moshi_to_client], return_when=asyncio.FIRST_COMPLETED)
                for task in pending:
                    task.cancel()
        except Exception as e:
            logger.error(f"Live transcription error: {str(e)}")
            try:
                await client_websocket.send_json({"type": "error", "message": str(e)})
            except:
                pass
        finally:
            self.active_connections -= 1
            logger.info(f"Session ended. Active: {self.active_connections}")
    
    async def _forward_audio_to_moshi(self, client_ws: WebSocket, moshi_ws):
        try:
            while True:
                message = await client_ws.receive()
                if message["type"] == "websocket.receive" and "bytes" in message:
                    audio_data = np.frombuffer(message["bytes"], dtype=np.float32)
                    if len(audio_data) == CHUNK_SIZE:
                        moshi_message = {"type": "Audio", "pcm": [float(x) for x in audio_data]}
                        msg_bytes = msgpack.packb(moshi_message, use_bin_type=True, use_single_float=True)
                        await moshi_ws.send(msg_bytes)
        except WebSocketDisconnect:
            pass
        except Exception as e:
            logger.error(f"Error forwarding audio: {e}")
    
    async def _forward_transcription_to_client(self, moshi_ws, client_ws: WebSocket):
        try:
            async for message in moshi_ws:
                try:
                    data = msgpack.unpackb(message, raw=False)
                    if data.get("type") == "Word" and "text" in data:
                        word = data["text"].strip()
                        if word:
                            await client_ws.send_json({"type": "word", "text": word, "timestamp": time.time()})
                except Exception as e:
                    logger.error(f"Error processing message: {e}")
        except Exception as e:
            logger.error(f"Error forwarding transcription: {e}")

live_service = LiveTranscriptionService()

@app.get("/")
async def root():
    return {"service": "Kyutai STT Live API", "websocket_endpoint": "/ws/live", "active_connections": live_service.active_connections}

@app.get("/health")
async def health_check():
    try:
        headers = {"kyutai-api-key": API_KEY}
        async with websockets.connect(MOSHI_SERVER_URL, additional_headers=headers) as websocket:
            await websocket.close()
        return {"status": "healthy", "active_connections": live_service.active_connections}
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"Service unhealthy: {str(e)}")

@app.get("/metrics")
async def get_metrics():
    return {"active_connections": live_service.active_connections, "sample_rate": SAMPLE_RATE, "chunk_size": CHUNK_SIZE}

@app.websocket("/ws/live")
async def websocket_live_transcription(websocket: WebSocket):
    await websocket.accept()
    logger.info("WebSocket connected")
    try:
        await websocket.send_json({"type": "connected", "message": "Live transcription ready", "sample_rate": SAMPLE_RATE, "chunk_size": CHUNK_SIZE})
        await live_service.handle_live_transcription(websocket)
    except WebSocketDisconnect:
        logger.info("WebSocket disconnected")
    except Exception as e:
        logger.error(f"WebSocket error: {str(e)}")

@app.get("/demo", response_class=HTMLResponse)
async def demo_page():
    return '''<!DOCTYPE html><html><head><title>Kyutai STT Demo</title><style>body{font-family:Arial,sans-serif;margin:40px}.container{max-width:800px;margin:0 auto}.status{padding:10px;margin:10px 0;border-radius:5px}.connected{background-color:#d4edda;color:#155724}.disconnected{background-color:#f8d7da;color:#721c24}.transcription{background-color:#f8f9fa;padding:20px;margin:20px 0;border-radius:5px;min-height:100px}button{padding:10px 20px;margin:10px;font-size:16px}.start{background-color:#28a745;color:white;border:none;border-radius:5px}.stop{background-color:#dc3545;color:white;border:none;border-radius:5px}</style></head><body><div class="container"><h1>🎤 Kyutai STT Live Demo</h1><div id="status" class="status disconnected">Disconnected</div><button id="startBtn" class="start" onclick="startTranscription()">Start</button><button id="stopBtn" class="stop" onclick="stopTranscription()" disabled>Stop</button><h3>Live Transcription:</h3><div id="transcription" class="transcription">Click Start to begin...</div></div><script>let ws=null,audioContext=null;async function startTranscription(){try{const protocol=window.location.protocol==="https:"?"wss:":"ws:";ws=new WebSocket(`${protocol}//${window.location.host}/ws/live`);ws.onopen=()=>{document.getElementById("status").textContent="Connected";document.getElementById("status").className="status connected";document.getElementById("transcription").innerHTML="Listening..."};ws.onmessage=event=>{const data=JSON.parse(event.data);if(data.type==="word"){document.getElementById("transcription").innerHTML+=data.text+" "}};const stream=await navigator.mediaDevices.getUserMedia({audio:{sampleRate:24000,channelCount:1}});audioContext=new AudioContext({sampleRate:24000});const source=audioContext.createMediaStreamSource(stream);const processor=audioContext.createScriptProcessor(1920,1,1);processor.onaudioprocess=event=>{if(ws&&ws.readyState===WebSocket.OPEN){const inputBuffer=event.inputBuffer.getChannelData(0);ws.send(new Float32Array(inputBuffer).buffer)}};source.connect(processor);processor.connect(audioContext.destination);document.getElementById("startBtn").disabled=true;document.getElementById("stopBtn").disabled=false}catch(error){alert("Error: "+error.message)}}function stopTranscription(){if(ws){ws.close();ws=null}if(audioContext){audioContext.close();audioContext=null}document.getElementById("status").textContent="Disconnected";document.getElementById("status").className="status disconnected";document.getElementById("startBtn").disabled=false;document.getElementById("stopBtn").disabled=true}</script></body></html>'''

if __name__ == "__main__":
    uvicorn.run("live_api_server:app", host="0.0.0.0", port=8000, log_level="info")
PYTHON_EOF

# Create docker-entrypoint.sh inline
RUN cat > docker-entrypoint.sh << 'BASH_EOF'
#!/bin/bash
set -e
echo "🚀 Kyutai STT Starting..."
echo "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null || echo 'Not available')"
echo "Batch Size: ${BATCH_SIZE:-80}"

if command -v nvidia-smi &> /dev/null; then
    echo "⏳ Waiting for GPU..."
    for i in {1..30}; do
        if nvidia-smi &> /dev/null; then
            echo "✅ GPU ready!"
            break
        fi
        sleep 2
    done
fi

echo "🎯 Starting moshi-server..."
/opt/rust/bin/moshi-server worker --config configs/config-stt-en_fr-hf.toml &

echo "⏳ Waiting for moshi-server..."
for i in {1..120}; do
    if ps aux | grep -q "[m]oshi-server worker"; then
        echo "✅ moshi-server ready!"
        break
    fi
    if [ $i -eq 120 ]; then
        echo "❌ moshi-server failed to start"
        exit 1
    fi
    sleep 2
done

echo "🌐 Starting API server..."
exec python3 live_api_server.py
BASH_EOF

RUN chmod +x docker-entrypoint.sh

# Install moshi-server
RUN /opt/rust/bin/cargo install --features cuda moshi-server

# Update batch size
ARG BATCH_SIZE=80
RUN sed -i "s/batch_size = 64/batch_size = \${BATCH_SIZE}/" configs/config-stt-en_fr-hf.toml

# Create directories
RUN mkdir -p /app/logs

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \\
    CMD curl -f http://localhost:8000/health || exit 1

ENTRYPOINT ["./docker-entrypoint.sh"]
EOF

# Download configs from official Kyutai repository
log_info "Downloading configuration files..."
if git clone --depth 1 https://github.com/kyutai-labs/delayed-streams-modeling.git temp_kyutai; then
    cp -r temp_kyutai/configs ./
    rm -rf temp_kyutai
    log_success "Configuration files downloaded"
else
    log_error "Failed to download configuration files"
    exit 1
fi

# Check available disk space
AVAILABLE_SPACE=$(df . | awk 'NR==2 {print $4}')
REQUIRED_SPACE=15000000  # 15GB in KB
if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
    log_error "Insufficient disk space. Required: 15GB, Available: $((AVAILABLE_SPACE/1000000))GB"
    log_error "Docker build requires significant space for Rust compilation and model cache"
    exit 1
fi
log_success "Disk space check passed: $((AVAILABLE_SPACE/1000000))GB available"

# Note: live_api_server.py and docker-entrypoint.sh are created above in the Dockerfile
# They will be generated during the Docker build process

# Update configuration
sed -i "s/batch_size = 64/batch_size = ${BATCH_SIZE}/" configs/config-stt-en_fr-hf.toml
sed -i "s/public_token/${API_KEY}/" configs/config-stt-en_fr-hf.toml

# Build and start
log_info "Building Docker image (this may take 10-15 minutes)..."
docker-compose build --build-arg BATCH_SIZE=${BATCH_SIZE}

log_info "Starting services..."
docker-compose up -d

# Wait for services with better feedback
log_info "Waiting for services to start (this may take 5-10 minutes for first run)..."
log_info "Model download and container startup in progress..."

# Check if container is running first
for i in {1..60}; do
    if docker-compose ps | grep -q "Up"; then
        log_success "Container is running!"
        break
    fi
    if [ $i -eq 60 ]; then
        log_error "Container failed to start"
        docker-compose logs
        exit 1
    fi
    sleep 5
done

# Health check
log_info "Checking service health..."
for i in {1..30}; do
    if curl -sf http://localhost:${API_PORT}/health &> /dev/null; then
        log_success "Service is healthy!"
        break
    fi
    if [ $i -eq 30 ]; then
        log_error "Health check failed"
        docker-compose logs
        exit 1
    fi
    sleep 10
done

# Get public IP
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

# Summary
log_success "🎉 SIMPLE DEPLOYMENT COMPLETED!"
echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    DEPLOYMENT SUMMARY                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo
log_info "🌐 Live Transcription API:"
echo "   • WebSocket: ws://${PUBLIC_IP}:${API_PORT}/ws/live"
echo "   • Demo Page: http://${PUBLIC_IP}:${API_PORT}/demo"
echo "   • Health: http://${PUBLIC_IP}:${API_PORT}/health"
echo
log_info "🔑 Configuration:"
echo "   • API Key: ${API_KEY}"
echo "   • Batch Size: ${BATCH_SIZE}"
echo "   • GPU Memory: ${GPU_MEMORY}MB"
echo
log_info "🛠️ Management:"
echo "   • Logs: docker-compose logs -f"
echo "   • Restart: docker-compose restart"
echo "   • Stop: docker-compose down"
echo
log_success "✅ Ready for live transcription testing!"
echo "Share the WebSocket URL with your colleagues:"
echo "ws://${PUBLIC_IP}:${API_PORT}/ws/live"
