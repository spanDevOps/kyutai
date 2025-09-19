#!/bin/bash
# Kyutai STT - Minimal Container Deployment
# Just runs moshi-server - clients connect with stt_from_mic_rust_server.py

set -e

# Configuration
PROJECT_NAME="kyutai-stt"
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
║                 KYUTAI STT MINIMAL DEPLOYER                 ║
║                   Just moshi-server + SSH                   ║
║                          v1.1                               ║
║                                                              ║
║  🎤 Use stt_from_mic_rust_server.py from your local machine ║
╚══════════════════════════════════════════════════════════════╝
EOF

log_success "🚀 KYUTAI STT MINIMAL DEPLOYER v1.1"
log_info "✅ Latest version with CUDA fixes and simplified deployment"
log_info "Starting minimal deployment..."

# Check if we're in a container
if [ -f /.dockerenv ]; then
    log_info "✅ Detected container environment"
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
apt install -y -qq curl wget git build-essential pkg-config libssl-dev cmake openssh-server

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
else
    log_warning "CUDA toolkit not found in standard locations, trying to install..."
    # Try to install CUDA toolkit
    wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/x86_64/cuda-keyring_1.0-1_all.deb
    dpkg -i cuda-keyring_1.0-1_all.deb 2>/dev/null || true
    apt update -qq
    apt install -y -qq cuda-toolkit-12-4 || apt install -y -qq cuda-toolkit-11-8 || log_warning "Could not install CUDA toolkit"
    
    if [ -d "/usr/local/cuda" ]; then
        export CUDA_ROOT="/usr/local/cuda"
        export PATH="/usr/local/cuda/bin:$PATH"
        export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"
    fi
fi

# Verify nvcc is available
if command -v nvcc &> /dev/null; then
    CUDA_VERSION=$(nvcc --version | grep "release" | sed 's/.*release \([0-9]\+\.[0-9]\+\).*/\1/')
    log_success "nvcc found - CUDA version: $CUDA_VERSION"
else
    log_error "nvcc still not found - moshi-server compilation will fail"
    log_info "Trying alternative: compile without CUDA features"
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
sleep 3

# Python dependencies not needed - script runs on user's local machine

# Setup project directory
PROJECT_DIR="/workspace/$PROJECT_NAME"
log_info "Setting up project directory: $PROJECT_DIR"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# Download Kyutai configs only
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

# Set CUDA environment for Rust compilation
if command -v nvcc &> /dev/null; then
    log_info "Compiling moshi-server with CUDA support..."
    cargo install --features cuda moshi-server
else
    log_warning "Compiling moshi-server without CUDA (CPU-only mode)..."
    cargo install moshi-server
fi
log_success "moshi-server installed"

# Setup SSH for remote access
log_info "Setting up SSH access..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# Generate SSH key if not exists
if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ""
fi

# Configure SSH
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
echo "root:kyutai123" | chpasswd

# Start SSH service
service ssh start

# Create startup script
log_info "Creating startup script..."
cat > start_moshi.sh << 'BASH_EOF'
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

echo "🚀 Starting Kyutai STT moshi-server..."
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

# Get container IP
CONTAINER_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

echo ""
echo "🎉 MOSHI-SERVER READY!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🌐 moshi-server endpoint: ws://${CONTAINER_IP}:8080/api/asr-streaming"
echo "🔑 API Key: API_KEY_PLACEHOLDER"
echo "📊 Batch Size: BATCH_SIZE_PLACEHOLDER"
echo "📊 GPU Memory: GPU_MEMORY_PLACEHOLDERMb"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✅ Ready for live transcription!"
echo ""
echo "🖥️  FROM YOUR LOCAL MACHINE:"
echo "1. Download the script:"
echo "   curl -O https://raw.githubusercontent.com/kyutai-labs/delayed-streams-modeling/main/scripts/stt_from_mic_rust_server.py"
echo ""
echo "2. Install dependencies:"
echo "   pip install msgpack numpy sounddevice websockets"
echo ""
echo "3. Run live transcription:"
echo "   python stt_from_mic_rust_server.py --url ws://${CONTAINER_IP}:8080 --api-key API_KEY_PLACEHOLDER"
echo ""
echo "🛠️  Management:"
echo "   • View logs: tail -f /workspace/kyutai-stt/logs/*.log"
echo "   • Stop: pkill -f moshi-server"
echo "   • Restart: ./start_moshi.sh"

# Keep moshi-server running
wait $MOSHI_PID
BASH_EOF

# Update startup script with actual values
sed -i "s|PROJECT_DIR_PLACEHOLDER|${PROJECT_DIR}|g" start_moshi.sh
sed -i "s/API_KEY_PLACEHOLDER/${API_KEY}/g" start_moshi.sh
sed -i "s/BATCH_SIZE_PLACEHOLDER/${BATCH_SIZE}/g" start_moshi.sh
sed -i "s/GPU_MEMORY_PLACEHOLDER/${GPU_MEMORY}/g" start_moshi.sh

chmod +x start_moshi.sh

# Create logs directory
mkdir -p logs

log_success "🎉 Minimal deployment setup completed!"
log_info "Starting moshi-server..."

# Start moshi-server
./start_moshi.sh
