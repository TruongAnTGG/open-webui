#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Master Launcher (Native - Không dùng Docker)
# Điều phối chạy Ollama (run-ollama.sh) và Open WebUI (run-openwebui.sh)
# ---------------------------------------------------------------------------

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-all}" in
  ollama)
    shift
    exec "${SCRIPT_DIR}/run-ollama.sh" "$@"
    ;;
  openui|webui|open-webui)
    shift
    exec "${SCRIPT_DIR}/run-openwebui.sh" "$@"
    ;;
  all|start|up)
    echo "================================================="
    echo "  Khởi động Ollama & Open WebUI (Native)"
    echo "================================================="
    "${SCRIPT_DIR}/run-ollama.sh" start
    echo ""
    "${SCRIPT_DIR}/run-openwebui.sh" start
    echo "================================================="
    echo "  Tất cả dịch vụ đã chạy nền thành công!"
    echo "  - Xem log Open WebUI : ./run.sh logs"
    echo "  - Xem log Ollama     : ./run.sh logs ollama"
    echo "  - Kiểm tra trạng thái: ./run.sh status"
    echo "  - Dừng dịch vụ       : ./run.sh stop"
    echo "================================================="
    ;;
  status)
    echo "================================================="
    echo "  Kiểm tra trạng thái Ollama & Open WebUI"
    echo "================================================="
    "${SCRIPT_DIR}/run-ollama.sh" status
    echo ""
    "${SCRIPT_DIR}/run-openwebui.sh" status
    ;;
  logs)
    target="${2:-webui}"
    if [[ "$target" == "ollama" ]]; then
      exec "${SCRIPT_DIR}/run-ollama.sh" logs
    else
      exec "${SCRIPT_DIR}/run-openwebui.sh" logs
    fi
    ;;
  stop|down)
    "${SCRIPT_DIR}/run-openwebui.sh" stop
    "${SCRIPT_DIR}/run-ollama.sh" stop
    ;;
  help|-h|--help)
    echo "Sử dụng: $0 [all|status|logs [ollama|webui]|stop|ollama|webui]"
    echo "  $0 all     : Khởi động Ollama trước rồi khởi động Open WebUI"
    echo "  $0 status  : Kiểm tra trạng thái của cả Ollama và Open WebUI"
    echo "  $0 logs    : Xem log Open WebUI (hoặc: $0 logs ollama)"
    echo "  $0 stop    : Dừng cả hai dịch vụ"
    echo "  $0 ollama  : Chạy script điều khiển Ollama (./run-ollama.sh)"
    echo "  $0 webui   : Chạy script điều khiển Open WebUI (./run-openwebui.sh)"
    exit 0
    ;;
  *)
    echo "Sử dụng: $0 [all|status|logs|stop|ollama|webui]"
    echo "Hoặc chạy trực tiếp: ./run-ollama.sh hoặc ./run-openwebui.sh"
    exit 1
    ;;
esac
