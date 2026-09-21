#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Script quản lý & khởi chạy Ollama (Native - Không dùng Docker)
# ---------------------------------------------------------------------------

readonly OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
readonly PID_FILE="${HOME}/.ollama/ollama.pid"

readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_installed() {
  if ! command -v ollama &>/dev/null; then
    log_error "Ollama chưa được cài đặt trên hệ thống!"
    echo "-> Cài đặt trên macOS:  brew install ollama (hoặc tải tại https://ollama.com)"
    echo "-> Cài đặt trên Linux:  curl -fsSL https://ollama.com/install.sh | sh"
    exit 1
  fi
}

is_running() {
  curl -sf "http://${OLLAMA_HOST}/api/version" &>/dev/null
}

list_models() {
  echo "--- Danh sách models hiện có trong Ollama ---"
  ollama list || true
  echo ""
}

start_ollama() {
  check_installed

  if is_running; then
    local version
    version=$(curl -s "http://${OLLAMA_HOST}/api/version" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 || echo "active")
    log_success "Ollama đang chạy tại http://${OLLAMA_HOST} (version: ${version})"
    echo ""
    list_models
    return 0
  fi

  log_info "Đang khởi động Ollama service tại http://${OLLAMA_HOST}..."
  mkdir -p "${HOME}/.ollama"

  # Khởi chạy ollama serve ở background
  nohup ollama serve > "${HOME}/.ollama/ollama.log" 2>&1 &
  echo $! > "$PID_FILE"

  # Chờ Ollama sẵn sàng
  local retries=15
  while ! is_running && [[ $retries -gt 0 ]]; do
    sleep 1
    retries=$((retries - 1))
  done

  if is_running; then
    log_success "Ollama đã khởi động thành công tại http://${OLLAMA_HOST}!"
    log_info "Log file: ${HOME}/.ollama/ollama.log"
    echo ""
    list_models
  else
    log_error "Không thể khởi động Ollama. Vui lòng kiểm tra log: cat ${HOME}/.ollama/ollama.log"
    exit 1
  fi
}

stop_ollama() {
  if ! is_running; then
    log_warn "Ollama hiện không chạy."
    rm -f "$PID_FILE"
    return 0
  fi

  log_info "Đang dừng dịch vụ Ollama..."
  if [[ -f "$PID_FILE" ]]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  pkill -f "ollama serve" 2>/dev/null || true
  pkill -x "ollama" 2>/dev/null || true
  sleep 1

  if is_running; then
    log_warn "Ollama có thể đang chạy dưới dạng background service của hệ thống (systemd hoặc macOS App)."
  else
    log_success "Đã dừng Ollama."
  fi
}

status_ollama() {
  check_installed
  if is_running; then
    local version
    version=$(curl -s "http://${OLLAMA_HOST}/api/version" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 || echo "active")
    log_success "Ollama ĐANG CHẠY tại http://${OLLAMA_HOST} (version: ${version})"
    echo ""
    list_models
  else
    log_warn "Ollama ĐANG DỪNG (không hoạt động trên cổng ${OLLAMA_HOST})."
  fi
}

pull_model() {
  check_installed
  local model="${1:-}"
  if [[ -z "$model" ]]; then
    log_error "Vui lòng chỉ định tên model. Ví dụ: ./run-ollama.sh pull qwen2.5:7b"
    exit 1
  fi
  log_info "Đang tải model '$model'..."
  ollama pull "$model"
  log_success "Tải model '$model' hoàn tất!"
}

case "${1:-start}" in
  start|up)
    start_ollama
    ;;
  stop|down)
    stop_ollama
    ;;
  restart)
    stop_ollama
    start_ollama
    ;;
  status)
    status_ollama
    ;;
  list)
    check_installed
    list_models
    ;;
  pull)
    shift
    pull_model "$@"
    ;;
  logs)
    if [[ -f "${HOME}/.ollama/ollama.log" ]]; then
      tail -f "${HOME}/.ollama/ollama.log"
    else
      log_warn "Chưa tìm thấy log file tại ${HOME}/.ollama/ollama.log"
    fi
    ;;
  help|-h|--help)
    echo "Sử dụng: $0 {start|stop|restart|status|list|logs|pull <model>}"
    exit 0
    ;;
  *)
    echo "Sử dụng: $0 {start|stop|restart|status|list|logs|pull <model>}"
    exit 1
    ;;
esac
