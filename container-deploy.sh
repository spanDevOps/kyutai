#!/bin/bash
# Kyutai STT - Container Deployment (PyTorch/CUDA containers)
# Optimized for Vast.ai PyTorch containers - no Docker installation needed

set -e

# Configuration
PROJECT_NAME="kyutai-stt"
API_PORT=${API_PORT:-8000}
BATCH_SIZE=${BATCH_SIZE:-80}
API_KEY=${API_KEY:-$(openssl rand -hex 16 2>/dev/null || echo "public_token")}

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
║                 KYUTAI STT CONTAINER DEPLOYER               ║
║                   For PyTorch/CUDA Containers               ║
║                                                              ║
║  🎤 Live WebSocket transcription only                        ║
╚══════════════════════════════════════════════════════════════╝
EOF

log_info "Starting container deployment for testing..."

# Check if we're in a container
if [ -f /.dockerenv ]; then
    log_info "✅ Detected container environment - using container-optimized deployment"
    CONTAINER_MODE=true
else
    log_warning "Not in container - this script is optimized for containers"
    CONTAINER_MODE=false
fi

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

# Install system dependencies
log_info "Installing system dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt update -qq
apt install -y -qq curl wget git build-essential pkg-config libssl-dev cmake python3-pip

# Install Rust
if ! command -v cargo &> /dev/null; then
    log_info "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
    source ~/.cargo/env
    export PATH="$HOME/.cargo/bin:$PATH"
    log_success "Rust installed"
else
    log_success "Rust already available"
    source ~/.cargo/env 2>/dev/null || true
    export PATH="$HOME/.cargo/bin:$PATH"
fi

# Clean up any existing services first
log_info "Cleaning up existing services..."
pkill -f moshi-server 2>/dev/null || true
pkill -f live_api_server 2>/dev/null || true
sleep 3

# Install Python dependencies
log_info "Installing Python dependencies..."
pip3 install --no-cache-dir fastapi uvicorn[standard] websockets>=11.0 msgpack soundfile numpy

# Setup project directory
PROJECT_DIR="/workspace/$PROJECT_NAME"
log_info "Setting up project directory: $PROJECT_DIR"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# Download Kyutai configs
log_info "Downloading Kyutai configuration files..."
if git clone --depth 1 https://github.com/kyutai-labs/delayed-streams-modeling.git temp_kyutai; then
    cp -r temp_kyutai/configs ./
    rm -rf temp_kyutai
    log_success "Configuration files downloaded"
else
    log_error "Failed to download configuration files"
    exit 1
fi

# Update configuration
log_info "Updating configuration..."
sed -i "s/batch_size = 64/batch_size = ${BATCH_SIZE}/" configs/config-stt-en_fr-hf.toml
sed -i "s/public_token/${API_KEY}/" configs/config-stt-en_fr-hf.toml

# Install moshi-server
log_info "Installing moshi-server (this may take 5-10 minutes)..."
source ~/.cargo/env
export PATH="$HOME/.cargo/bin:$PATH"
cargo install --features cuda moshi-server
log_success "moshi-server installed"

# Create API server
log_info "Creating live API server..."
cat > live_api_server.py << 'PYTHON_EOF'
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
            async with websockets.connect(MOSHI_SERVER_URL, extra_headers=headers) as moshi_ws:
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
                if message["type"] == "websocket.receive" and "text" in message:
                    try:
                        audio_chunk = json.loads(message["text"])
                        if audio_chunk.get("type") == "Audio" and "pcm" in audio_chunk:
                            # Forward the exact format from browser to moshi-server
                            msg_bytes = msgpack.packb(audio_chunk, use_bin_type=True, use_single_float=True)
                            await moshi_ws.send(msg_bytes)
                    except json.JSONDecodeError:
                        logger.error("Invalid JSON received from client")
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
        async with websockets.connect(MOSHI_SERVER_URL, extra_headers=headers) as websocket:
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
    return '''<!DOCTYPE html><html><head><title>Kyutai STT Demo</title><style>body{font-family:Arial,sans-serif;margin:40px}.container{max-width:800px;margin:0 auto}.status{padding:10px;margin:10px 0;border-radius:5px}.connected{background-color:#d4edda;color:#155724}.disconnected{background-color:#f8d7da;color:#721c24}.transcription{background-color:#f8f9fa;padding:20px;margin:20px 0;border-radius:5px;min-height:100px}button{padding:10px 20px;margin:10px;font-size:16px}.start{background-color:#28a745;color:white;border:none;border-radius:5px}.stop{background-color:#dc3545;color:white;border:none;border-radius:5px}</style></head><body><div class="container"><h1>🎤 Kyutai STT Live Demo</h1><div id="status" class="status disconnected">Disconnected</div><button id="startBtn" class="start" onclick="startTranscription()">Start</button><button id="stopBtn" class="stop" onclick="stopTranscription()" disabled>Stop</button><h3>Live Transcription:</h3><div id="transcription" class="transcription">Click Start to begin...</div></div><script>let ws=null,audioContext=null;async function startTranscription(){try{const protocol=window.location.protocol==="https:"?"wss:":"ws:";ws=new WebSocket(`${protocol}//${window.location.host}/ws/live`);ws.onopen=()=>{document.getElementById("status").textContent="Connected";document.getElementById("status").className="status connected";document.getElementById("transcription").innerHTML="Listening..."};ws.onmessage=event=>{const data=JSON.parse(event.data);if(data.type==="word"){document.getElementById("transcription").innerHTML+=data.text+" "}};const stream=await navigator.mediaDevices.getUserMedia({audio:true});audioContext=new AudioContext({sampleRate:24000});const source=audioContext.createMediaStreamSource(stream);const gainNode=audioContext.createGain();gainNode.gain.value=10000;const processor=audioContext.createScriptProcessor(2048,1,1);processor.onaudioprocess=event=>{if(ws&&ws.readyState===WebSocket.OPEN){const inputBuffer=event.inputBuffer.getChannelData(0);const audioData=new Float32Array(1920);for(let i=0;i<1920&&i<inputBuffer.length;i++){audioData[i]=inputBuffer[i]}const chunk={type:"Audio",pcm:Array.from(audioData)};ws.send(JSON.stringify(chunk))}};source.connect(gainNode);gainNode.connect(processor);processor.connect(audioContext.destination);document.getElementById("startBtn").disabled=true;document.getElementById("stopBtn").disabled=false}catch(error){alert("Error: "+error.message)}}function stopTranscription(){if(ws){ws.close();ws=null}if(audioContext){audioContext.close();audioContext=null}document.getElementById("status").textContent="Disconnected";document.getElementById("status").className="status disconnected";document.getElementById("startBtn").disabled=false;document.getElementById("stopBtn").disabled=true}</script></body></html>'''

if __name__ == "__main__":
    uvicorn.run("live_api_server:app", host="0.0.0.0", port=8000, log_level="info")
PYTHON_EOF

# Create startup script
log_info "Creating startup script..."
cat > start_services.sh << 'BASH_EOF'
#!/bin/bash
set -e
export PATH="$HOME/.cargo/bin:$PATH"

echo "🚀 Starting Kyutai STT services..."
echo "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null || echo 'Not available')"
echo "Batch Size: BATCH_SIZE_PLACEHOLDER"

cd PROJECT_DIR_PLACEHOLDER

echo "🎯 Starting moshi-server..."
$HOME/.cargo/bin/moshi-server worker --config configs/config-stt-en_fr-hf.toml &
MOSHI_PID=$!

echo "⏳ Waiting for moshi-server to be ready..."
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

echo "🌐 Starting Live Transcription API server..."
export API_KEY="API_KEY_PLACEHOLDER"
python3 live_api_server.py &
API_PID=$!

# Wait for API server
sleep 10

# Get container IP
CONTAINER_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

echo ""
echo "🎉 DEPLOYMENT COMPLETED!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🌐 Live Transcription API:"
echo "   • WebSocket: ws://${CONTAINER_IP}:8000/ws/live"
echo "   • Demo Page: http://${CONTAINER_IP}:8000/demo"
echo "   • Health: http://${CONTAINER_IP}:8000/health"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔑 API Key: API_KEY_PLACEHOLDER"
echo "📊 Batch Size: BATCH_SIZE_PLACEHOLDER"
echo "📊 GPU Memory: GPU_MEMORY_PLACEHOLDERMb"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✅ Ready for live transcription testing!"
echo "Share the WebSocket URL with your colleagues:"
echo "ws://${CONTAINER_IP}:8000/ws/live"
echo ""
echo "🛠️  Management commands:"
echo "   • View logs: tail -f /workspace/kyutai-stt/logs/*.log"
echo "   • Stop services: pkill -f moshi-server && pkill -f live_api_server"
echo "   • Restart: ./start_services.sh"

# Keep services running
wait
BASH_EOF

# Update startup script with actual values
sed -i "s|PROJECT_DIR_PLACEHOLDER|${PROJECT_DIR}|g" start_services.sh
sed -i "s/API_KEY_PLACEHOLDER/${API_KEY}/g" start_services.sh
sed -i "s/BATCH_SIZE_PLACEHOLDER/${BATCH_SIZE}/g" start_services.sh
sed -i "s/GPU_MEMORY_PLACEHOLDER/${GPU_MEMORY}/g" start_services.sh

chmod +x start_services.sh

# Create logs directory
mkdir -p logs

log_success "🎉 Container deployment setup completed!"
log_info "Starting services..."

# Start services
./start_services.sh
