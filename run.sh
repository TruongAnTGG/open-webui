#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Script triển khai Open WebUI và Ollama bằng Docker
# ---------------------------------------------------------------------------

readonly NETWORK_NAME="open-webui-net"
readonly OLLAMA_CONTAINER="ollama"
readonly WEBUI_CONTAINER="open-webui"
readonly OLLAMA_IMAGE="ollama/ollama:latest"
readonly WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"

readonly WEBUI_PORT="${OPEN_WEBUI_PORT:-3000}"
readonly OLLAMA_PORT="${OLLAMA_PORT:-11434}"

# Màu sắc hiển thị
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_docker() {
  if ! command -v docker &>/dev/null; then
    log_error "Docker chưa được cài đặt. Vui lòng cài đặt Docker trước khi chạy!"
    exit 1
  fi

  if ! docker info &>/dev/null; then
    log_error "Docker daemon chưa chạy. Vui lòng khởi động Docker Desktop rồi thử lại!"
    exit 1
  fi
}

detect_gpu() {
  local gpu_flags=()
  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    log_info "Phát hiện NVIDIA GPU, kích hoạt hỗ trợ GPU (--gpus all)..."
    gpu_flags=("--gpus" "all")
  else
    log_info "Chạy chế độ CPU (mặc định cho macOS hoặc máy không có NVIDIA GPU)..."
  fi
  echo "${gpu_flags[@]}"
}

start_containers() {
  check_docker

  # 1. Tạo Docker network nếu chưa tồn tại
  if ! docker network inspect "$NETWORK_NAME" &>/dev/null; then
    log_info "Đang tạo Docker network: $NETWORK_NAME..."
    docker network create "$NETWORK_NAME"
  else
    log_info "Docker network '$NETWORK_NAME' đã sẵn sàng."
  fi

  # 2. Khởi động Ollama
  log_info "Kiểm tra container Ollama hiện có..."
  docker rm -f "$OLLAMA_CONTAINER" 2>/dev/null || true

  local gpu_args
  read -ra gpu_args <<< "$(detect_gpu)"

  log_info "Đang khởi động $OLLAMA_CONTAINER trên cổng $OLLAMA_PORT..."
  docker run -d \
    --name "$OLLAMA_CONTAINER" \
    --network "$NETWORK_NAME" \
    ${gpu_args[@]+"${gpu_args[@]}"} \
    -p "${OLLAMA_PORT}:11434" \
    -v ollama:/root/.ollama \
    --restart unless-stopped \
    "$OLLAMA_IMAGE"

  # 3. Khởi động Open WebUI
  log_info "Kiểm tra container Open WebUI hiện có..."
  docker rm -f "$WEBUI_CONTAINER" 2>/dev/null || true

  log_info "Đang khởi động $WEBUI_CONTAINER trên cổng $WEBUI_PORT..."
  docker run -d \
    --name "$WEBUI_CONTAINER" \
    --network "$NETWORK_NAME" \
    -p "${WEBUI_PORT}:8080" \
    -e "OLLAMA_BASE_URL=http://${OLLAMA_CONTAINER}:11434" \
    -e "WEBUI_SECRET_KEY=" \
    -v open-webui:/app/backend/data \
    --add-host=host.docker.internal:host-gateway \
    --restart unless-stopped \
    "$WEBUI_IMAGE"

  # 4. Thông báo hoàn thành
  sleep 2
  echo ""
  log_success "================================================="
  log_success " Deploy thành công tất cả các thành phần!"
  log_success " -> Open WebUI: http://localhost:${WEBUI_PORT}"
  log_success " -> Ollama API: http://localhost:${OLLAMA_PORT}"
  log_success "================================================="
  echo ""
  echo "Để tải một model (ví dụ llama3.2, qwen2.5, deepseek-r1):"
  echo "  ./run.sh pull llama3.2"
  echo "  (hoặc: docker exec -it ollama ollama run llama3.2)"
  echo ""
  echo "Xem trạng thái hoặc logs:"
  echo "  ./run.sh status"
  echo "  ./run.sh logs"
  echo ""
}

stop_containers() {
  check_docker
  log_info "Đang dừng các container..."
  docker stop "$WEBUI_CONTAINER" "$OLLAMA_CONTAINER" 2>/dev/null || true
  docker rm "$WEBUI_CONTAINER" "$OLLAMA_CONTAINER" 2>/dev/null || true
  log_success "Đã dừng và gỡ bỏ container $WEBUI_CONTAINER & $OLLAMA_CONTAINER."
}

show_status() {
  check_docker
  echo "--- Trạng thái Container ---"
  docker ps -a --filter "name=^/${OLLAMA_CONTAINER}$" --filter "name=^/${WEBUI_CONTAINER}$"
}

show_logs() {
  check_docker
  local target="${2:-$WEBUI_CONTAINER}"
  log_info "Hiển thị logs của container '$target' (Nhấn Ctrl+C để thoát)..."
  docker logs -f "$target"
}

pull_model() {
  check_docker
  local model="${2:-}"
  if [[ -z "$model" ]]; then
    log_error "Vui lòng chỉ định tên model. Ví dụ: ./run.sh pull llama3.2"
    exit 1
  fi
  log_info "Đang tải model '$model' vào Ollama..."
  docker exec -it "$OLLAMA_CONTAINER" ollama pull "$model"
  log_success "Tải model '$model' thành công!"
}

case "${1:-start}" in
  start|up)
    start_containers
    ;;
  stop|down)
    stop_containers
    ;;
  restart)
    stop_containers
    start_containers
    ;;
  status)
    show_status
    ;;
  logs)
    show_logs "$@"
    ;;
  pull)
    pull_model "$@"
    ;;
  help|-h|--help)
    echo "Sử dụng: $0 {start|stop|restart|status|logs [ollama|open-webui]|pull <model>}"
    exit 0
    ;;
  *)
    echo "Sử dụng: $0 {start|stop|restart|status|logs [ollama|open-webui]|pull <model>}"
    exit 1
    ;;
esac
