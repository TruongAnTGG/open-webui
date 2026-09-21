#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Script khởi chạy Open WebUI Native (Không dùng Docker, từ mã nguồn hiện tại)
# ---------------------------------------------------------------------------

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VENV_DIR="${SCRIPT_DIR}/.venv"
readonly FRONTEND_BUILD_DIR="${SCRIPT_DIR}/build"

readonly PORT="${PORT:-8080}"
readonly HOST="${HOST:-0.0.0.0}"
readonly OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}"

# Màu sắc hiển thị
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

find_python() {
  if command -v python3.11 &>/dev/null; then
    echo "python3.11"
  elif command -v python3.12 &>/dev/null; then
    echo "python3.12"
  elif command -v python3.10 &>/dev/null; then
    echo "python3.10"
  elif command -v python3 &>/dev/null; then
    echo "python3"
  else
    log_error "Không tìm thấy Python 3 trên hệ thống! Vui lòng cài đặt Python 3.11."
    exit 1
  fi
}

check_node() {
  if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
    log_error "Node.js và npm chưa được cài đặt. Cần có Node.js để build frontend."
    echo "-> Cài đặt trên macOS: brew install node"
    echo "-> Cài đặt trên Linux: sudo apt install -y nodejs npm (hoặc dùng nvm)"
    exit 1
  fi
}

setup_venv() {
  local py_bin
  py_bin=$(find_python)

  if [[ ! -d "$VENV_DIR" ]]; then
    log_info "Đang tạo môi trường ảo Python (.venv) bằng $py_bin..."
    if command -v uv &>/dev/null; then
      uv venv "$VENV_DIR" --python "$py_bin"
    else
      "$py_bin" -m venv "$VENV_DIR"
    fi
    log_success "Đã tạo .venv thành công!"
  fi

  # Kích hoạt venv
  # shellcheck source=/dev/null
  source "${VENV_DIR}/bin/activate"
}

install_backend() {
  setup_venv
  log_info "Đang cài đặt các thư viện Python backend..."
  if command -v uv &>/dev/null; then
    uv pip install -r "${SCRIPT_DIR}/backend/requirements.txt"
  else
    pip install --upgrade pip
    pip install -r "${SCRIPT_DIR}/backend/requirements.txt"
  fi
  log_success "Cài đặt backend dependencies thành công!"
}

build_frontend() {
  check_node
  log_info "Kiểm tra và build Frontend từ source code..."
  cd "$SCRIPT_DIR"

  if [[ ! -d "node_modules" ]]; then
    log_info "Đang cài đặt node_modules..."
    npm install
  fi

  log_info "Đang build static files (npm run build)..."
  npm run build
  log_success "Build Frontend hoàn tất! Thư mục build: ${FRONTEND_BUILD_DIR}"
}

prepare_secret_key() {
  local key_file="${SCRIPT_DIR}/backend/.webui_secret_key"
  if [[ ! -f "$key_file" && -z "${WEBUI_SECRET_KEY:-}" ]]; then
    log_info "Tạo WEBUI_SECRET_KEY..."
    head -c 24 /dev/urandom | base64 > "$key_file"
  fi
  if [[ -f "$key_file" ]]; then
    export WEBUI_SECRET_KEY="$(cat "$key_file")"
  fi
}

start_openwebui() {
  local reload_flag="${1:-false}"

  setup_venv

  # Kiểm tra xem uvicorn và fastapi đã cài chưa
  if ! python -c "import uvicorn, fastapi" &>/dev/null; then
    log_warn "Thư viện backend chưa được cài đặt đầy đủ. Đang tiến hành cài đặt..."
    install_backend
  fi

  # Kiểm tra build frontend
  if [[ ! -f "${FRONTEND_BUILD_DIR}/index.html" ]]; then
    log_warn "Chưa tìm thấy bản build frontend. Đang tiến hành build..."
    build_frontend
  fi

  prepare_secret_key

  export OLLAMA_BASE_URL
  export PORT
  export HOST

  echo ""
  log_success "================================================="
  log_success " Khởi chạy Open WebUI (Native):"
  log_success " -> URL: http://localhost:${PORT}"
  log_success " -> Kết nối Ollama: ${OLLAMA_BASE_URL}"
  log_success "================================================="
  echo ""

  cd "${SCRIPT_DIR}/backend"
  if [[ "$reload_flag" == "true" ]]; then
    log_info "Chạy ở chế độ reload (tự động cập nhật khi đổi code backend)..."
    exec python -m uvicorn open_webui.main:app --host "$HOST" --port "$PORT" --reload --forwarded-allow-ips "*"
  else
    exec python -m uvicorn open_webui.main:app --host "$HOST" --port "$PORT" --forwarded-allow-ips "*"
  fi
}

start_dev() {
  check_node
  setup_venv
  prepare_secret_key

  export OLLAMA_BASE_URL
  export PORT="${PORT:-8080}"
  export HOST="${HOST:-0.0.0.0}"

  echo ""
  log_info "Chế độ Development (Backend tại :$PORT, Frontend tại :5173)"
  log_info "1. Backend đang chạy reload..."
  log_info "2. Ở một terminal khác, anh có thể gõ: npm run dev để xem giao diện dev"
  echo ""

  cd "${SCRIPT_DIR}/backend"
  exec python -m uvicorn open_webui.main:app --host "$HOST" --port "$PORT" --reload --forwarded-allow-ips "*"
}

case "${1:-start}" in
  start|up)
    start_openwebui false
    ;;
  dev)
    start_dev
    ;;
  reload)
    start_openwebui true
    ;;
  build)
    build_frontend
    ;;
  install)
    log_info "Cài đặt toàn bộ dependencies (Frontend + Backend)..."
    check_node
    cd "$SCRIPT_DIR"
    npm install
    install_backend
    log_success "Cài đặt tất cả dependencies hoàn tất!"
    ;;
  help|-h|--help)
    echo "Sử dụng: $0 {start|dev|build|install|reload}"
    echo "  start   : Tự chuẩn bị môi trường và chạy Open WebUI (mặc định cổng 8080)"
    echo "  dev     : Chạy backend với --reload cho lập trình viên"
    echo "  build   : Chỉ build lại frontend từ code mới (npm run build)"
    echo "  install : Cài đặt lại thư viện Python (.venv) và Node.js (node_modules)"
    exit 0
    ;;
  *)
    echo "Sử dụng: $0 {start|dev|build|install|reload}"
    exit 1
    ;;
esac
