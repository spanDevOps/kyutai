#!/bin/bash
# Kyutai STT - Production Deployment with Public Access
# Uses Cloudflare Tunnel for public API access

set -e

# Colors and logging functions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration
PROJECT_NAME="kyutai-stt"
BATCH_SIZE=${BATCH_SIZE:-80}
API_KEY=${API_KEY:-$(openssl rand -hex 16 2>/dev/null || echo "public_token")}
INTERNAL_PORT=8000  # FastAPI will run on this port internally

# Banner
cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                KYUTAI STT PRODUCTION DEPLOYER               ║
║                  Public API via Cloudflare                  ║
║                          v2.0                               ║
║                                                              ║
║  🌐 Direct public WebSocket API for production use          ║
╚══════════════════════════════════════════════════════════════╝
EOF

log_success "🚀 KYUTAI STT PRODUCTION DEPLOYER v2.0"
log_info "✅ Production-ready deployment with public API access"

# Check if we're in a container
if [ -f /.dockerenv ]; then
    log_info "✅ Detected container environment"
else
    log_warning "Not in container - this script is optimized for containers"
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
apt install -y -qq curl wget git build-essential pkg-config libssl-dev cmake

# Set up CUDA environment
log_info "Setting up CUDA environment..."
if [ -d "/usr/local/cuda" ]; then
    export CUDA_ROOT="/usr/local/cuda"
    export PATH="/usr/local/cuda/bin:$PATH"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"
    log_success "CUDA found at /usr/local/cuda"
elif [ -d "/opt/cuda" ]; then
    export CUDA_ROOT="/opt/cuda"
    export PATH="/opt/cuda/bin:$PATH"
    export LD_LIBRARY_PATH="/opt/cuda/lib64:$LD_LIBRARY_PATH"
    log_success "CUDA found at /opt/cuda"
fi

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

# Clean up any existing services
log_info "Cleaning up existing services..."
pkill -f moshi-server 2>/dev/null || true
pkill -f uvicorn 2>/dev/null || true
pkill -f cloudflared 2>/dev/null || true
sleep 3

# Install Python dependencies
log_info "Installing Python dependencies..."
pip3 install --no-cache-dir fastapi uvicorn[standard] websockets msgpack

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

if command -v nvcc &> /dev/null; then
    log_info "Compiling moshi-server with CUDA support..."
    cargo install --features cuda moshi-server
else
    log_warning "Compiling moshi-server without CUDA (CPU-only mode)..."
    cargo install moshi-server
fi
log_success "moshi-server installed"

# Install Cloudflare Tunnel
log_info "Installing Cloudflare Tunnel for public access..."
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i cloudflared-linux-amd64.deb || apt install -f -y
rm cloudflared-linux-amd64.deb
log_success "Cloudflare Tunnel installed"

# Create production API server
log_info "Creating production API server..."
cat > production_api.py << 'PYTHON_EOF'
#!/usr/bin/env python3
import asyncio
import json
import logging
import os
import time
import msgpack
import websockets
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Kyutai STT Production API", version="2.0.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])

MOSHI_SERVER_URL = "ws://localhost:8080/api/asr-streaming"
API_KEY = os.getenv("API_KEY", "public_token")
SAMPLE_RATE = 24000
CHUNK_SIZE = 1920

class LiveTranscriptionService:
    def __init__(self):
        self.active_connections = 0
    
    async def handle_live_transcription(self, client_websocket: WebSocket):
        self.active_connections += 1
        try:
            headers = {"kyutai-api-key": API_KEY}
            async with websockets.connect(MOSHI_SERVER_URL, additional_headers=headers) as moshi_ws:
                logger.info(f"Live session started. Active: {self.active_connections}")
                
                # Send connection confirmation
                await client_websocket.send_json({
                    "type": "connected", 
                    "message": "Kyutai STT ready", 
                    "sample_rate": SAMPLE_RATE, 
                    "chunk_size": CHUNK_SIZE
                })
                
                # Forward messages bidirectionally
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
    return {"service": "Kyutai STT Production API", "status": "ready", "active_connections": live_service.active_connections}

@app.get("/health")
async def health_check():
    try:
        headers = {"kyutai-api-key": API_KEY}
        async with websockets.connect(MOSHI_SERVER_URL, additional_headers=headers) as websocket:
            await websocket.close()
        return {"status": "healthy", "active_connections": live_service.active_connections}
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"Service unhealthy: {str(e)}")

@app.websocket("/ws/live")
async def websocket_live_transcription(websocket: WebSocket):
    await websocket.accept()
    logger.info("WebSocket connected")
    try:
        await live_service.handle_live_transcription(websocket)
    except WebSocketDisconnect:
        logger.info("WebSocket disconnected")
    except Exception as e:
        logger.error(f"WebSocket error: {str(e)}")

if __name__ == "__main__":
    uvicorn.run("production_api:app", host="0.0.0.0", port=INTERNAL_PORT)
PYTHON_EOF

# Create startup script
log_info "Creating startup script..."
cat > start_production.sh << 'BASH_EOF'
#!/bin/bash
set -e
export PATH="$HOME/.cargo/bin:$PATH"

# Set up CUDA environment
if [ -d "/usr/local/cuda" ]; then
    export CUDA_ROOT="/usr/local/cuda"
    export PATH="/usr/local/cuda/bin:$PATH"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"
elif [ -d "/opt/cuda" ]; then
    export CUDA_ROOT="/opt/cuda"
    export PATH="/opt/cuda/bin:$PATH"
    export LD_LIBRARY_PATH="/opt/cuda/lib64:$LD_LIBRARY_PATH"
fi

echo "🚀 Starting Kyutai STT Production Services..."
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

echo "🌐 Starting Production API server..."
export API_KEY="API_KEY_PLACEHOLDER"
python3 production_api.py &
API_PID=$!

echo "⏳ Waiting for API server to be ready..."
sleep 10

echo "🔗 Starting Cloudflare Tunnel for public access..."
# Create a quick tunnel (no account needed for testing)
cloudflared tunnel --url http://localhost:INTERNAL_PORT_PLACEHOLDER &
TUNNEL_PID=$!

echo "⏳ Waiting for tunnel to establish..."
sleep 15

# Get tunnel URL from cloudflared logs
TUNNEL_URL=$(ps aux | grep cloudflared | grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' | head -1)

if [ -n "$TUNNEL_URL" ]; then
    echo ""
    echo "🎉 PRODUCTION DEPLOYMENT COMPLETED!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🌐 PUBLIC API ENDPOINT:"
    echo "   WebSocket: ${TUNNEL_URL/https:/wss:}/ws/live"
    echo "   Health: $TUNNEL_URL/health"
    echo "   Status: $TUNNEL_URL/"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔑 API Key: API_KEY_PLACEHOLDER"
    echo "📊 Batch Size: BATCH_SIZE_PLACEHOLDER"
    echo "📊 GPU Memory: GPU_MEMORY_PLACEHOLDERMb"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "✅ Ready for production use!"
    echo ""
    echo "🖥️  YOUR TEAM CAN USE:"
    echo "   const ws = new WebSocket('${TUNNEL_URL/https:/wss:}/ws/live');"
    echo ""
    echo "🖥️  OR FROM PYTHON:"
    echo "   python stt_from_mic_rust_server.py --url ${TUNNEL_URL/https:/ws:} --api-key API_KEY_PLACEHOLDER"
    echo ""
    echo "🛠️  Management:"
    echo "   • Stop: pkill -f moshi-server && pkill -f uvicorn && pkill -f cloudflared"
    echo "   • Restart: ./start_production.sh"
else
    echo "❌ Failed to establish Cloudflare tunnel"
    echo "   Check cloudflared logs: ps aux | grep cloudflared"
fi

# Keep services running
echo "🔄 Monitoring services..."
wait $MOSHI_PID $API_PID $TUNNEL_PID
BASH_EOF

# Update startup script with actual values
sed -i "s|PROJECT_DIR_PLACEHOLDER|${PROJECT_DIR}|g" start_production.sh
sed -i "s/API_KEY_PLACEHOLDER/${API_KEY}/g" start_production.sh
sed -i "s/BATCH_SIZE_PLACEHOLDER/${BATCH_SIZE}/g" start_production.sh
sed -i "s/GPU_MEMORY_PLACEHOLDER/${GPU_MEMORY}/g" start_production.sh
sed -i "s/INTERNAL_PORT_PLACEHOLDER/${INTERNAL_PORT}/g" start_production.sh

chmod +x start_production.sh

# Create logs directory
mkdir -p logs

log_success "🎉 Production deployment setup completed!"
log_info "Starting production services..."

# Start services
./start_production.sh
