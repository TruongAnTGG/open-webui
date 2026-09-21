#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# All-in-One Launcher: Ollama + Open WebUI Portal (Native - Không dùng Docker)
# ---------------------------------------------------------------------------

export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VENV_DIR="${SCRIPT_DIR}/.venv"
readonly FRONTEND_BUILD_DIR="${SCRIPT_DIR}/build"

readonly PORT="${PORT:-8080}"
readonly HOST="${HOST:-0.0.0.0}"
readonly OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
readonly OLLAMA_BASE_URL="http://${OLLAMA_HOST}"

# File PID và Log
readonly OLLAMA_PID_FILE="${HOME}/.ollama/ollama.pid"
readonly OLLAMA_LOG_FILE="${HOME}/.ollama/ollama.log"

readonly WEBUI_LOG_DIR="${HOME}/.open-webui"
readonly WEBUI_LOG_FILE="${WEBUI_LOG_DIR}/open-webui.log"
readonly WEBUI_PID_FILE="${WEBUI_LOG_DIR}/open-webui.pid"

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

# ===========================================================================
# 1. Quản lý Ollama
# ===========================================================================

is_ollama_running() {
  curl -sf "http://${OLLAMA_HOST}/api/version" &>/dev/null
}

check_ollama_installed() {
  if ! command -v ollama &>/dev/null; then
    log_error "Ollama chưa được cài đặt trên hệ thống!"
    echo "-> Cài đặt trên macOS:  brew install ollama (hoặc tải tại https://ollama.com)"
    echo "-> Cài đặt trên Linux:  curl -fsSL https://ollama.com/install.sh | sh"
    exit 1
  fi
}

list_ollama_models() {
  echo "--- Danh sách models hiện có trong Ollama ---"
  ollama list 2>/dev/null || true
  echo ""
}

start_ollama() {
  check_ollama_installed

  if is_ollama_running; then
    local version
    version=$(curl -s "http://${OLLAMA_HOST}/api/version" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 || echo "active")
    log_success "Ollama đang chạy tại http://${OLLAMA_HOST} (version: ${version})"
    list_ollama_models
    return 0
  fi

  log_info "Đang khởi động Ollama service tại http://${OLLAMA_HOST}..."
  mkdir -p "${HOME}/.ollama"

  nohup ollama serve > "$OLLAMA_LOG_FILE" 2>&1 &
  echo $! > "$OLLAMA_PID_FILE"

  local retries=20
  while ! is_ollama_running && [[ $retries -gt 0 ]]; do
    sleep 1
    retries=$((retries - 1))
  done

  if is_ollama_running; then
    log_success "Ollama đã khởi động thành công tại http://${OLLAMA_HOST}!"
    list_ollama_models
  else
    log_error "Không thể khởi động Ollama. Kiểm tra log: cat $OLLAMA_LOG_FILE"
    exit 1
  fi
}

stop_ollama() {
  if ! is_ollama_running; then
    log_warn "Ollama hiện không chạy."
    rm -f "$OLLAMA_PID_FILE"
    return 0
  fi

  log_info "Đang dừng dịch vụ Ollama..."
  if [[ -f "$OLLAMA_PID_FILE" ]]; then
    kill "$(cat "$OLLAMA_PID_FILE")" 2>/dev/null || true
    rm -f "$OLLAMA_PID_FILE"
  fi
  pkill -f "ollama serve" 2>/dev/null || true
  pkill -x "ollama" 2>/dev/null || true
  sleep 1
  log_success "Đã dừng Ollama."
}

# ===========================================================================
# 2. Quản lý Open WebUI Portal
# ===========================================================================

is_webui_running() {
  curl -sf "http://127.0.0.1:${PORT}/health" &>/dev/null
}

find_python() {
  # 1. Ưu tiên Python 3.11 (tốt nhất cho Open WebUI)
  if command -v python3.11 &>/dev/null; then
    echo "python3.11"
    return 0
  fi

  # 2. Thử Python 3.12 hoặc 3.10
  for candidate in python3.12 python3.10; do
    if command -v "$candidate" &>/dev/null; then
      echo "$candidate"
      return 0
    fi
  done

  # 3. Tự động dùng uv để chuẩn bị Python 3.11 tương thích
  if ! command -v uv &>/dev/null; then
    log_info "Đang chuẩn bị công cụ quản lý Python uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 || true
    export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
  fi

  if command -v uv &>/dev/null; then
    local uv_py
    uv_py=$(uv python find 3.11 2>/dev/null || true)
    if [[ -z "$uv_py" ]]; then
      log_info "Đang tự động tải Python 3.11 tương thích cho Open WebUI..."
      uv python install 3.11 >/dev/null 2>&1 || true
      uv_py=$(uv python find 3.11 2>/dev/null || true)
    fi
    if [[ -n "$uv_py" ]]; then
      echo "$uv_py"
      return 0
    fi
  fi

  # 4. Kiểm tra python3 mặc định (< 3.14)
  if command -v python3 &>/dev/null; then
    local is_compat
    is_compat=$(python3 -c 'import sys; print(sys.version_info >= (3, 10) and sys.version_info < (3, 14))' 2>/dev/null || echo "False")
    if [[ "$is_compat" == "True" ]]; then
      echo "python3"
      return 0
    fi
  fi

  local cur_ver
  cur_ver=$(python3 --version 2>/dev/null || echo "Không xác định")
  log_error "Phiên bản Python hiện tại ($cur_ver) chưa được Open WebUI hỗ trợ (yêu cầu < 3.14, khuyên dùng 3.11)!"
  echo ""
  echo "Cách khắc phục nhanh nhất (không cần sudo):"
  echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"
  echo "  export PATH=\"\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH\""
  echo "  uv python install 3.11"
  echo ""
  exit 1
}

setup_venv() {
  # Dọn dẹp venv nếu phiên bản python cũ >= 3.14
  if [[ -f "${VENV_DIR}/bin/activate" ]]; then
    local venv_compat
    venv_compat=$("${VENV_DIR}/bin/python" -c 'import sys; print(sys.version_info >= (3, 10) and sys.version_info < (3, 14))' 2>/dev/null || echo "False")
    if [[ "$venv_compat" != "True" ]]; then
      log_warn "Thư mục .venv hiện tại dùng phiên bản Python không tương thích. Đang tạo lại..."
      rm -rf "$VENV_DIR"
    fi
  fi

  local py_bin
  py_bin=$(find_python)

  if [[ ! -f "${VENV_DIR}/bin/activate" ]]; then
    if [[ -d "$VENV_DIR" ]]; then
      rm -rf "$VENV_DIR"
    fi

    log_info "Đang tạo môi trường ảo Python (.venv) bằng $py_bin..."
    local created=false

    if command -v uv &>/dev/null; then
      if uv venv "$VENV_DIR" --seed --python "$py_bin" 2>/dev/null; then
        created=true
      fi
    fi

    if [[ "$created" == false ]]; then
      if ! "$py_bin" -m venv "$VENV_DIR"; then
        log_error "Tạo môi trường ảo .venv thất bại!"
        echo "Vui lòng chạy: sudo apt update && sudo apt install -y python3-venv python3-pip python3-dev build-essential"
        exit 1
      fi
    fi

    log_success "Đã tạo .venv thành công!"
  fi

  # shellcheck source=/dev/null
  source "${VENV_DIR}/bin/activate"
}

install_backend() {
  setup_venv
  log_info "Đang cài đặt các thư viện Python backend..."

  # 1. Cài trước PyTorch bản CPU siêu nhẹ (~150MB) để tránh PyPI tự tải Triton + CUDA nặng ~6GB
  if ! "${VENV_DIR}/bin/python" -c "import torch" &>/dev/null; then
    log_info "Cài đặt PyTorch CPU (tiết kiệm hơn 6GB ổ cứng, tránh lỗi Triton)..."
    if command -v uv &>/dev/null; then
      uv pip install --python "${VENV_DIR}/bin/python" --no-cache \
        'torch<=2.9.1' torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cpu || true
    fi
  fi

  # 2. Cài đặt các thư viện còn lại với --no-cache để không tốn ổ cứng
  log_info "Cài đặt các gói phụ thuộc Open WebUI..."
  if command -v uv &>/dev/null; then
    uv pip install --python "${VENV_DIR}/bin/python" --no-cache -r "${SCRIPT_DIR}/backend/requirements.txt"
  else
    if [[ -f "${VENV_DIR}/bin/pip" ]]; then
      "${VENV_DIR}/bin/pip" install --upgrade pip setuptools wheel
      "${VENV_DIR}/bin/pip" install --no-cache-dir -r "${SCRIPT_DIR}/backend/requirements.txt"
    else
      "${VENV_DIR}/bin/python" -m pip install --upgrade pip setuptools wheel
      "${VENV_DIR}/bin/python" -m pip install --no-cache-dir -r "${SCRIPT_DIR}/backend/requirements.txt"
    fi
  fi
  log_success "Cài đặt backend dependencies thành công!"
}

build_frontend() {
  if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
    log_error "Cần có Node.js để build frontend."
    echo "Cài Node.js: curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt install -y nodejs"
    exit 1
  fi

  log_info "Kiểm tra và build Frontend từ source code..."
  cd "$SCRIPT_DIR"

  if [[ ! -d "node_modules" ]]; then
    log_info "Đang cài đặt node_modules..."
    npm install
  fi

  log_info "Đang build static files (npm run build)..."
  npm run build
  log_success "Build Frontend hoàn tất tại: ${FRONTEND_BUILD_DIR}"
}

prepare_secret_key() {
  local key_file="${SCRIPT_DIR}/backend/.webui_secret_key"
  if [[ ! -f "$key_file" && -z "${WEBUI_SECRET_KEY:-}" ]]; then
    head -c 24 /dev/urandom | base64 > "$key_file"
  fi
  if [[ -f "$key_file" ]]; then
    export WEBUI_SECRET_KEY="$(cat "$key_file")"
  fi
}

start_openwebui() {
  if is_webui_running; then
    log_success "Open WebUI Portal đang chạy tại http://localhost:${PORT}"
    log_info "Log file: ${WEBUI_LOG_FILE}"
    return 0
  fi

  setup_venv

  if ! "${VENV_DIR}/bin/python" -c "import uvicorn, fastapi" &>/dev/null; then
    log_warn "Thư viện backend chưa được cài đặt đầy đủ. Đang tiến hành cài đặt..."
    install_backend
  fi

  if [[ ! -f "${FRONTEND_BUILD_DIR}/index.html" ]]; then
    log_warn "Chưa tìm thấy bản build frontend. Đang tiến hành build..."
    build_frontend
  fi

  prepare_secret_key

  export OLLAMA_BASE_URL
  export PORT
  export HOST

  log_info "Đang khởi động Open WebUI Portal trên cổng $PORT..."
  # Khởi chạy uvicorn ở background chế độ Production (không reload, 1 worker, tối ưu websocket)
  nohup "${VENV_DIR}/bin/python" -m uvicorn open_webui.main:app \
    --host "$HOST" \
    --port "$PORT" \
    --workers 1 \
    --ws-per-message-deflate "${UVICORN_WS_PER_MESSAGE_DEFLATE:-true}" \
    --forwarded-allow-ips "*" > "$WEBUI_LOG_FILE" 2>&1 &

  local pid=$!
  echo "$pid" > "$WEBUI_PID_FILE"

  log_info "Đang kiểm tra khởi động Open WebUI (PID: $pid)..."
  local retries=35
  while ! is_webui_running && [[ $retries -gt 0 ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      log_error "Khởi động Open WebUI thất bại! Log chi tiết:"
      echo "--------------------------------------------------------"
      tail -n 25 "$WEBUI_LOG_FILE" 2>/dev/null || true
      echo "--------------------------------------------------------"
      rm -f "$WEBUI_PID_FILE"
      exit 1
    fi
    sleep 1
    retries=$((retries - 1))
  done

  if is_webui_running; then
    log_success "Open WebUI Portal đã khởi động thành công!"
    log_info "-> Giao diện WebUI: http://localhost:${PORT}"
    log_info "-> Log file       : ${WEBUI_LOG_FILE}"
  else
    log_warn "Open WebUI đang khởi tạo chậm hơn bình thường. Theo dõi log: ./run.sh logs"
  fi
}

stop_openwebui() {
  local stopped=false
  if [[ -f "$WEBUI_PID_FILE" ]]; then
    local pid
    pid=$(cat "$WEBUI_PID_FILE" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log_info "Đang dừng Open WebUI (PID: $pid)..."
      kill "$pid" 2>/dev/null || true
      stopped=true
    fi
    rm -f "$WEBUI_PID_FILE"
  fi

  local pids
  pids=$(pgrep -f "open_webui.main:app" 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null || true
    stopped=true
  fi

  sleep 1
  if [[ "$stopped" == true ]]; then
    log_success "Đã dừng Open WebUI Portal."
  else
    log_warn "Open WebUI Portal hiện không chạy."
  fi
}

# ===========================================================================
# 3. Điều phối chung
# ===========================================================================

status_all() {
  echo "================================================="
  echo "  Trạng thái hệ thống (Ollama & Open WebUI)"
  echo "================================================="
  if is_ollama_running; then
    local ol_ver
    ol_ver=$(curl -s "http://${OLLAMA_HOST}/api/version" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 || echo "active")
    log_success "Ollama ĐANG CHẠY tại http://${OLLAMA_HOST} (version: ${ol_ver})"
    list_ollama_models
  else
    log_warn "Ollama ĐANG DỪNG."
  fi

  echo ""
  if is_webui_running; then
    local pid=""
    if [[ -f "$WEBUI_PID_FILE" ]]; then
      pid=$(cat "$WEBUI_PID_FILE" 2>/dev/null || true)
    fi
    log_success "Open WebUI ĐANG CHẠY tại http://localhost:${PORT}"
    if [[ -n "$pid" ]]; then
      echo "  -> PID         : $pid"
    fi
    echo "  -> Health check: http://localhost:${PORT}/health [200 OK]"
    echo "  -> Kết nối     : ${OLLAMA_BASE_URL}"
    echo "  -> Log file    : ${WEBUI_LOG_FILE}"
  else
    log_warn "Open WebUI ĐANG DỪNG (không hoạt động trên cổng ${PORT})."
    if [[ -f "$WEBUI_LOG_FILE" ]]; then
      echo "  -> Xem log gần nhất: tail -n 20 ${WEBUI_LOG_FILE}"
    fi
  fi
  echo "================================================="
}

show_logs() {
  local target="${1:-webui}"
  if [[ "$target" == "ollama" ]]; then
    if [[ -f "$OLLAMA_LOG_FILE" ]]; then
      log_info "Hiển thị log Ollama (Ctrl+C để thoát)..."
      tail -f "$OLLAMA_LOG_FILE"
    else
      log_warn "Chưa có file log Ollama tại $OLLAMA_LOG_FILE"
    fi
  else
    if [[ -f "$WEBUI_LOG_FILE" ]]; then
      log_info "Hiển thị log Open WebUI (Ctrl+C để thoát)..."
      tail -f "$WEBUI_LOG_FILE"
    else
      log_warn "Chưa có file log Open WebUI tại $WEBUI_LOG_FILE"
    fi
  fi
}

start_dev() {
  setup_venv

  if ! "${VENV_DIR}/bin/python" -c "import uvicorn, fastapi" &>/dev/null; then
    log_warn "Thư viện backend chưa được cài đặt trong .venv. Đang tiến hành cài đặt..."
    install_backend
  fi

  prepare_secret_key
  export OLLAMA_BASE_URL
  export PORT
  export HOST

  echo ""
  log_info "Chạy Open WebUI chế độ Development trực tiếp trên màn hình..."
  cd "${SCRIPT_DIR}/backend"
  exec "${VENV_DIR}/bin/python" -m uvicorn open_webui.main:app --host "$HOST" --port "$PORT" --reload --forwarded-allow-ips "*"
}

# ===========================================================================
# Main
# ===========================================================================

case "${1:-all}" in
  all|start|up|prod|production)
    echo "================================================="
    echo "  Khởi động Ollama & Open WebUI Portal (Production)"
    echo "================================================="
    start_ollama
    echo ""
    start_openwebui
    echo "================================================="
    echo "  Hoàn tất! Các lệnh quản trị tiện ích:"
    echo "  - Xem log WebUI      : ./run.sh logs"
    echo "  - Xem log Ollama     : ./run.sh logs ollama"
    echo "  - Kiểm tra trạng thái: ./run.sh status"
    echo "  - Dừng dịch vụ       : ./run.sh stop"
    echo "================================================="
    ;;
  status)
    status_all
    ;;
  logs)
    shift || true
    show_logs "${1:-webui}"
    ;;
  stop|down)
    stop_openwebui
    stop_ollama
    ;;
  restart)
    stop_openwebui
    stop_ollama
    sleep 1
    "$0" all
    ;;
  dev)
    start_ollama
    start_dev
    ;;
  build)
    build_frontend
    ;;
  install)
    setup_venv
    install_backend
    build_frontend
    ;;
  help|-h|--help)
    echo "Sử dụng: $0 [all|status|logs [ollama|webui]|stop|restart|dev|build|install]"
    echo "  $0 (hoặc $0 all) : Khởi động cả Ollama và Open WebUI Portal"
    echo "  $0 status        : Xem trạng thái chi tiết của cả 2 dịch vụ"
    echo "  $0 logs          : Xem log realtime của Open WebUI Portal"
    echo "  $0 logs ollama   : Xem log realtime của Ollama"
    echo "  $0 stop          : Dừng cả hai dịch vụ"
    echo "  $0 restart       : Khởi động lại toàn bộ"
    echo "  $0 dev           : Chạy trực tiếp trên terminal (xem log lỗi live)"
    echo "  $0 build         : Chỉ build lại frontend từ code mới (npm run build)"
    echo "  $0 install       : Cài đặt lại toàn bộ thư viện Python & Node"
    exit 0
    ;;
  *)
    echo "Lệnh không hợp lệ. Gõ '$0 help' để xem hướng dẫn."
    exit 1
    ;;
esac
