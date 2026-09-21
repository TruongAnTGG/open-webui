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
export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"

readonly RED='\033[0;31m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

find_python() {
  # 1. Thử tìm Python 3.11 (khuyên dùng nhất bởi Open WebUI)
  if command -v python3.11 &>/dev/null; then
    echo "python3.11"
    return 0
  fi

  # 2. Thử tìm Python 3.12 hoặc 3.10
  for candidate in python3.12 python3.10; do
    if command -v "$candidate" &>/dev/null; then
      echo "$candidate"
      return 0
    fi
  done

  # 3. Nếu có uv, tự động tìm hoặc tải Python 3.11
  if command -v uv &>/dev/null; then
    local uv_py
    uv_py=$(uv python find 3.11 2>/dev/null || true)
    if [[ -z "$uv_py" ]]; then
      log_info "Đang dùng uv để tự động tải Python 3.11 tương thích..."
      uv python install 3.11 &>/dev/null || true
      uv_py=$(uv python find 3.11 2>/dev/null || true)
    fi
    if [[ -n "$uv_py" ]]; then
      echo "$uv_py"
      return 0
    fi
  fi

  # 4. Kiểm tra python3 mặc định của hệ thống xem có < 3.14 không
  if command -v python3 &>/dev/null; then
    local is_compat
    is_compat=$(python3 -c 'import sys; print(sys.version_info >= (3, 10) and sys.version_info < (3, 14))' 2>/dev/null || echo "False")
    if [[ "$is_compat" == "True" ]]; then
      echo "python3"
      return 0
    fi
  fi

  # Không có phiên bản tương thích
  local cur_ver
  cur_ver=$(python3 --version 2>/dev/null || echo "Không xác định")
  log_error "Phiên bản Python hiện tại trên máy là $cur_ver."
  echo ""
  echo "Các thư viện AI của Open WebUI (unstructured, torch, chromadb) chưa hỗ trợ Python >= 3.14!"
  echo "Yêu cầu: Python 3.11 (hoặc 3.12, 3.10)."
  echo ""
  echo "Cách khắc phục nhanh nhất trên server:"
  echo "  Cách 1 (Khuyên dùng - Nhanh nhất & không cần sudo):"
  echo "     curl -LsSf https://astral.sh/uv/install.sh | sh"
  echo "     source ~/.cargo/env 2>/dev/null || true"
  echo "     uv python install 3.11"
  echo ""
  echo "  Cách 2 (Cài Python 3.11 qua APT trên Ubuntu/Debian):"
  echo "     sudo add-apt-repository -y ppa:deadsnakes/ppa"
  echo "     sudo apt update"
  echo "     sudo apt install -y python3.11 python3.11-venv python3.11-dev"
  echo ""
  exit 1
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
  # Kiểm tra nếu .venv đã có nhưng dùng Python >= 3.14 không tương thích
  if [[ -f "${VENV_DIR}/bin/activate" ]]; then
    local venv_compat
    venv_compat=$("${VENV_DIR}/bin/python" -c 'import sys; print(sys.version_info >= (3, 10) and sys.version_info < (3, 14))' 2>/dev/null || echo "False")
    if [[ "$venv_compat" != "True" ]]; then
      local venv_ver
      venv_ver=$("${VENV_DIR}/bin/python" --version 2>/dev/null || echo "")
      log_warn "Thư mục .venv hiện tại dùng $venv_ver (không tương thích, cần < 3.14). Đang xoá để tạo lại..."
      rm -rf "$VENV_DIR"
    fi
  fi

  local py_bin
  py_bin=$(find_python)

  # Kiểm tra nếu thư mục .venv chưa tồn tại hoặc bị lỗi (thiếu file activate)
  if [[ ! -f "${VENV_DIR}/bin/activate" ]]; then
    if [[ -d "$VENV_DIR" ]]; then
      log_warn "Phát hiện thư mục .venv cũ bị lỗi. Đang dọn dẹp để tạo lại..."
      rm -rf "$VENV_DIR"
    fi

    log_info "Đang tạo môi trường ảo Python (.venv) bằng $py_bin..."
    local created=false

    if command -v uv &>/dev/null; then
      if uv venv "$VENV_DIR" --python "$py_bin" 2>/dev/null; then
        created=true
      fi
    fi

    if [[ "$created" == false ]]; then
      if ! "$py_bin" -m venv "$VENV_DIR"; then
        log_error "Tạo môi trường ảo .venv thất bại!"
        echo ""
        echo "-> Trên Ubuntu/Debian, vui lòng chạy lệnh sau rồi thử lại:"
        echo "   sudo apt update && sudo apt install -y python3-venv python3-pip python3-dev build-essential"
        echo ""
        exit 1
      fi
    fi

    if [[ ! -f "${VENV_DIR}/bin/activate" ]]; then
      log_error "Không tìm thấy file ${VENV_DIR}/bin/activate sau khi tạo .venv."
      exit 1
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
    uv pip install --python "${VENV_DIR}/bin/python" -r "${SCRIPT_DIR}/backend/requirements.txt" || \
      "${VENV_DIR}/bin/pip" install -r "${SCRIPT_DIR}/backend/requirements.txt"
  else
    "${VENV_DIR}/bin/pip" install --upgrade pip setuptools wheel
    "${VENV_DIR}/bin/pip" install -r "${SCRIPT_DIR}/backend/requirements.txt"
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

  # Kiểm tra xem uvicorn và fastapi đã cài trong .venv chưa
  if ! "${VENV_DIR}/bin/python" -c "import uvicorn, fastapi" &>/dev/null; then
    log_warn "Thư viện backend chưa được cài đặt trong .venv. Đang tiến hành cài đặt..."
    install_backend
  fi

  # Kiểm tra build frontend
  if [[ ! -f "${FRONTEND_BUILD_DIR}/index.html" ]]; then
    log_warn "Chưa tìm thấy bản build frontend tại ${FRONTEND_BUILD_DIR}."
    if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
      log_error "Node.js hoặc npm chưa được cài đặt trên server để tự động build frontend!"
      echo ""
      echo "Anh có 2 cách xử lý:"
      echo "  1. Cài Node.js trên server:"
      echo "     curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -"
      echo "     sudo apt install -y nodejs"
      echo "  2. Hoặc build frontend trên máy local (npm run build) rồi đưa thư mục 'build/' lên server."
      echo ""
      exit 1
    fi
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
    exec "${VENV_DIR}/bin/python" -m uvicorn open_webui.main:app --host "$HOST" --port "$PORT" --reload --forwarded-allow-ips "*"
  else
    exec "${VENV_DIR}/bin/python" -m uvicorn open_webui.main:app --host "$HOST" --port "$PORT" --forwarded-allow-ips "*"
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
  exec "${VENV_DIR}/bin/python" -m uvicorn open_webui.main:app --host "$HOST" --port "$PORT" --reload --forwarded-allow-ips "*"
}

status_openwebui() {
  local pids
  pids=$(pgrep -f "open_webui.main:app" 2>/dev/null || true)

  if curl -sf "http://127.0.0.1:${PORT}/health" &>/dev/null; then
    log_success "Open WebUI ĐANG CHẠY tại http://localhost:${PORT}"
    if [[ -n "$pids" ]]; then
      echo "  -> Process ID (PID): $pids"
    fi
    echo "  -> Health check: http://localhost:${PORT}/health [200 OK]"
    echo "  -> Kết nối Ollama: ${OLLAMA_BASE_URL}"
  elif [[ -n "$pids" ]]; then
    log_warn "Tiến trình Open WebUI đang chạy (PID: $pids) nhưng cổng $PORT chưa sẵn sàng phản hồi (đang khởi động)."
  else
    log_warn "Open WebUI ĐANG DỪNG (không hoạt động trên cổng ${PORT})."
  fi
}

stop_openwebui() {
  local pids
  pids=$(pgrep -f "open_webui.main:app" 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    log_info "Đang dừng Open WebUI (PID: $pids)..."
    kill $pids 2>/dev/null || true
    sleep 1
    log_success "Đã dừng Open WebUI."
  else
    log_warn "Open WebUI hiện không chạy."
  fi
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
  status)
    status_openwebui
    ;;
  stop|down)
    stop_openwebui
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
    echo "Sử dụng: $0 {start|status|stop|dev|build|install|reload}"
    echo "  start   : Tự chuẩn bị môi trường và chạy Open WebUI (mặc định cổng 8080)"
    echo "  status  : Kiểm tra xem Open WebUI có đang chạy hay không"
    echo "  stop    : Dừng dịch vụ Open WebUI"
    echo "  dev     : Chạy backend với --reload cho lập trình viên"
    echo "  build   : Chỉ build lại frontend từ code mới (npm run build)"
    echo "  install : Cài đặt lại thư viện Python (.venv) và Node.js (node_modules)"
    exit 0
    ;;
  *)
    echo "Sử dụng: $0 {start|status|stop|dev|build|install|reload}"
    exit 1
    ;;
esac
