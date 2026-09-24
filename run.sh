#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Script triển khai trọn gói Open WebUI và Ollama bằng 2 Container Docker
# Hai container kết nối nội bộ qua Docker network: open-webui-net
# ---------------------------------------------------------------------------

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly NETWORK_NAME="open-webui-net"
readonly OLLAMA_CONTAINER="ollama"
readonly WEBUI_CONTAINER="open-webui"

readonly OLLAMA_IMAGE="ollama/ollama:latest"
readonly WEBUI_IMAGE="open-webui:local"

readonly WEBUI_PORT="${OPEN_WEBUI_PORT:-3000}"
readonly OLLAMA_PORT="${OLLAMA_PORT:-11434}"

# Màu sắc hiển thị (ghi vào stderr để không làm bẩn stdout)
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

check_docker() {
  if ! command -v docker &>/dev/null; then
    log_error "Docker chưa được cài đặt trên hệ thống!"
    echo "-> Vui lòng cài đặt Docker trước khi chạy script." >&2
    exit 1
  fi

  if ! docker info &>/dev/null; then
    log_error "Docker daemon chưa khởi động (hoặc người dùng chưa có quyền docker)!"
    echo "-> Khởi động Docker Desktop (trên macOS) hoặc: sudo systemctl start docker (trên Linux)" >&2
    exit 1
  fi
}

GPU_FLAGS=()
detect_gpu() {
  GPU_FLAGS=()
  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    log_info "Phát hiện NVIDIA GPU, kích hoạt hỗ trợ GPU cho Ollama (--gpus all)..."
    GPU_FLAGS=("--gpus" "all")
  else
    log_info "Chạy Ollama chế độ CPU (mặc định cho macOS hoặc máy không có GPU NVIDIA)..."
  fi
}

cleanup_native_processes() {
  # Dọn dẹp tiến trình native cũ nếu trước đó người dùng chạy bản không dùng Docker
  if pgrep -f "open_webui.main:app" &>/dev/null; then
    log_info "Dừng tiến trình Open WebUI native cũ đang chiếm cổng..."
    pkill -f "open_webui.main:app" 2>/dev/null || true
    sleep 1
  fi

  # Thử dừng Ollama systemd nếu đang chạy trên host
  if command -v systemctl &>/dev/null && systemctl is-active --quiet ollama 2>/dev/null; then
    log_info "Phát hiện Ollama đang chạy qua systemd trên host. Đang dừng để nhường cổng..."
    sudo systemctl stop ollama 2>/dev/null || true
    sleep 1
  fi
  pkill -f "ollama serve" 2>/dev/null || true
}

build_openwebui() {
  check_docker
  log_info "Dọn dẹp build cache cũ để đảm bảo đủ dung lượng ổ đĩa..."
  docker builder prune -f >/dev/null 2>&1 || true

  log_info "Bắt đầu build Docker image '$WEBUI_IMAGE' từ mã nguồn local..."
  log_info "(Sử dụng USE_SLIM=true để tối ưu dung lượng và build nhanh hơn)"

  if ! docker build --build-arg USE_SLIM=true -t "$WEBUI_IMAGE" "$SCRIPT_DIR"; then
    log_warn "Build local thất bại (thường do ổ cứng không đủ dung lượng build từ source)."
    read -rp "Anh có muốn chuyển sang dùng image chính thức prebuilt (ghcr.io/open-webui/open-webui:main) không? [Y/n]: " ans
    if [[ "${ans,,}" =~ ^(y|yes|)$ ]]; then
      log_info "Đang kéo image chính thức đã compile sẵn..."
      docker pull ghcr.io/open-webui/open-webui:main
      docker tag ghcr.io/open-webui/open-webui:main "$WEBUI_IMAGE"
      log_success "Đã chuẩn bị xong image Open WebUI!"
    else
      log_error "Hủy thao tác. Vui lòng giải phóng thêm ổ cứng và thử lại."
      exit 1
    fi
  else
    log_success "Build image '$WEBUI_IMAGE' thành công!"
  fi
}

start_all() {
  check_docker
  cleanup_native_processes

  # 1. Kiểm tra / Tạo Docker Network
  if ! docker network inspect "$NETWORK_NAME" &>/dev/null; then
    log_info "Đang tạo Docker Network chung: $NETWORK_NAME..."
    docker network create "$NETWORK_NAME" >/dev/null
  else
    log_info "Docker Network '$NETWORK_NAME' đã sẵn sàng."
  fi

  # 2. Khởi động Container 1: Ollama
  log_info "Khởi tạo container Ollama..."
  docker rm -f "$OLLAMA_CONTAINER" >/dev/null 2>&1 || true

  detect_gpu

  local host_ollama_port="$OLLAMA_PORT"
  # Kiểm tra xem cổng 11434 trên host có đang bị dịch vụ native khác chiếm không
  if curl -sf "http://127.0.0.1:${OLLAMA_PORT}/api/version" &>/dev/null; then
    log_warn "Cổng host ${OLLAMA_PORT} đang có dịch vụ Ollama native khác chiếm giữ."
    log_info "Tự động đổi cổng host sang 11435 để tránh xung đột (2 container trong Docker vẫn gọi nhau qua cổng 11434 bình thường)..."
    host_ollama_port=11435
  fi

  log_info "Đang chạy $OLLAMA_CONTAINER trên cổng host $host_ollama_port..."
  docker run -d \
    --name "$OLLAMA_CONTAINER" \
    --network "$NETWORK_NAME" \
    ${GPU_FLAGS[@]+"${GPU_FLAGS[@]}"} \
    -p "${host_ollama_port}:11434" \
    -v ollama:/root/.ollama \
    --restart unless-stopped \
    "$OLLAMA_IMAGE" >/dev/null

  # 3. Build image Open WebUI nếu chưa có
  if ! docker image inspect "$WEBUI_IMAGE" &>/dev/null; then
    build_openwebui
  fi

  # 4. Khởi động Container 2: Open WebUI
  log_info "Khởi tạo container Open WebUI..."
  docker rm -f "$WEBUI_CONTAINER" >/dev/null 2>&1 || true

  log_info "Đang chạy $WEBUI_CONTAINER kết nối nội bộ tới 'http://${OLLAMA_CONTAINER}:11434'..."
  docker run -d \
    --name "$WEBUI_CONTAINER" \
    --network "$NETWORK_NAME" \
    -p "${WEBUI_PORT}:8080" \
    -e "ENABLE_OLLAMA_API=true" \
    -e "OLLAMA_BASE_URL=http://${OLLAMA_CONTAINER}:11434" \
    -e "OLLAMA_BASE_URLS=http://${OLLAMA_CONTAINER}:11434" \
    -e "WEBUI_SECRET_KEY=" \
    -v open-webui:/app/backend/data \
    --add-host=host.docker.internal:host-gateway \
    --restart unless-stopped \
    "$WEBUI_IMAGE" >/dev/null

  # 5. Kiểm tra trạng thái sẵn sàng
  sleep 3
  echo ""
  log_success "================================================="
  log_success " Cả 2 Container đã khởi chạy thành công!"
  log_success " -> Open WebUI Portal : http://localhost:${WEBUI_PORT}"
  log_success " -> Ollama API        : http://localhost:${OLLAMA_PORT}"
  log_success " -> Kết nối mạng nội bộ: Open WebUI -> http://${OLLAMA_CONTAINER}:11434"
  log_success "================================================="
  echo ""
  echo "Các lệnh hữu ích:"
  echo "  ./run.sh status         : Xem trạng thái 2 container"
  echo "  ./run.sh logs           : Xem log của Open WebUI"
  echo "  ./run.sh logs ollama    : Xem log của Ollama"
  echo "  ./run.sh pull <model>   : Tải model AI (ví dụ: ./run.sh pull qwen2.5:7b)"
  echo "  ./run.sh stop           : Dừng 2 container"
  echo ""
}

stop_all() {
  check_docker
  log_info "Đang dừng 2 container $WEBUI_CONTAINER & $OLLAMA_CONTAINER..."
  docker stop "$WEBUI_CONTAINER" "$OLLAMA_CONTAINER" >/dev/null 2>&1 || true
  docker rm "$WEBUI_CONTAINER" "$OLLAMA_CONTAINER" >/dev/null 2>&1 || true
  log_success "Đã dừng và gỡ bỏ 2 container thành công."
}

status_all() {
  check_docker
  echo "================================================="
  echo "  Trạng thái Container (Docker Network: $NETWORK_NAME)"
  echo "================================================="
  docker ps -a --filter "name=^/${OLLAMA_CONTAINER}$" --filter "name=^/${WEBUI_CONTAINER}$"
  echo "================================================="
}

show_logs() {
  check_docker
  local target="${1:-$WEBUI_CONTAINER}"
  if [[ "$target" == "ollama" ]]; then
    target="$OLLAMA_CONTAINER"
  else
    target="$WEBUI_CONTAINER"
  fi
  log_info "Hiển thị log của container '$target' (Nhấn Ctrl+C để thoát)..."
  docker logs -f "$target"
}

pull_model() {
  check_docker
  local model="${1:-}"
  if [[ -z "$model" ]]; then
    log_error "Vui lòng chỉ định tên model. Ví dụ: ./run.sh pull qwen2.5:7b"
    exit 1
  fi
  log_info "Đang tải model '$model' vào Ollama container..."
  docker exec -it "$OLLAMA_CONTAINER" ollama pull "$model"
  log_success "Tải model '$model' thành công!"
}

# ===========================================================================
# Main Case
# ===========================================================================

case "${1:-start}" in
  start|all|up|prod)
    start_all
    ;;
  build)
    build_openwebui
    ;;
  status)
    status_all
    ;;
  logs)
    shift || true
    show_logs "${1:-webui}"
    ;;
  stop|down)
    stop_all
    ;;
  restart)
    stop_all
    start_all
    ;;
  pull)
    shift || true
    pull_model "${1:-}"
    ;;
  help|-h|--help)
    echo "Sử dụng: $0 [start|build|status|logs [ollama|webui]|pull <model>|stop|restart]"
    echo "  $0 (hoặc $0 start)    : Build code local & khởi chạy 2 container"
    echo "  $0 build              : Chỉ build lại image Open WebUI từ source code"
    echo "  $0 status             : Xem trạng thái 2 container Docker"
    echo "  $0 logs               : Xem log của Open WebUI container"
    echo "  $0 logs ollama        : Xem log của Ollama container"
    echo "  $0 pull <tên_model>   : Tải model AI vào Ollama (ví dụ: ./run.sh pull llama3.2)"
    echo "  $0 stop               : Dừng và gỡ cả 2 container"
    echo "  $0 restart            : Khởi động lại toàn bộ"
    exit 0
    ;;
  *)
    echo "Lệnh không hợp lệ. Gõ '$0 help' để xem hướng dẫn."
    exit 1
    ;;
esac
