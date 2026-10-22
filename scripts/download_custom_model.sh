#!/bin/sh
# Download any custom GGUF model from Hugging Face into models/<repo-name>/
# and display ready-to-use launch commands for Linux, macOS, and Windows.
#
# Usage:
#   ./scripts/download_custom_model.sh <hf_url_or_repo_id> [options] [patterns...]
#
# Examples:
#   # Tải bản mặc định (PQ2_0 + mmproj) từ URL Hugging Face:
#   ./scripts/download_custom_model.sh https://huggingface.co/OS-Software/Ternary-Bonsai-2-27B-Uncensored-Heretic-GGUF
#
#   # Tải bản siêu nhẹ PTQ1_0:
#   ./scripts/download_custom_model.sh OS-Software/Ternary-Bonsai-2-27B-Uncensored-Heretic-GGUF --quant PTQ1_0
#
#   # Tải toàn bộ file .gguf trong repo:
#   ./scripts/download_custom_model.sh OS-Software/Ternary-Bonsai-2-27B-Uncensored-Heretic-GGUF --all
#
#   # Tải vào thư mục chỉ định:
#   ./scripts/download_custom_model.sh https://huggingface.co/OS-Software/Ternary-Bonsai-2-27B-Uncensored-Heretic-GGUF --dest models/heretic
#
# Options:
#   --quant <Q>    Chỉ tải quant cụ thể (vd: PQ2_0, PTQ1_0, Q4_K_M...) và mmproj
#   --all          Tải toàn bộ file *.gguf trong repo
#   --dest <DIR>   Chỉ định thư mục lưu (mặc định: models/<tên-repo>)
#   --token <TOK>  Hugging Face token nếu repo yêu cầu xác thực
#   --help, -h     Hiện hướng dẫn sử dụng
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$DEMO_DIR"

if [ -t 1 ]; then
    CLR_GREEN="\033[32m"
    CLR_YELLOW="\033[33m"
    CLR_RED="\033[31m"
    CLR_CYAN="\033[36m"
    CLR_RESET="\033[0m"
else
    CLR_GREEN="" CLR_YELLOW="" CLR_RED="" CLR_CYAN="" CLR_RESET=""
fi

info()  { printf "${CLR_GREEN}[OK]${CLR_RESET}   %s\n" "$*"; }
warn()  { printf "${CLR_YELLOW}[WARN]${CLR_RESET} %s\n" "$*"; }
err()   { printf "${CLR_RED}[ERR]${CLR_RESET}  %s\n" "$*" >&2; }
step()  { printf "${CLR_CYAN}==>${CLR_RESET}  %s\n" "$*"; }

show_help() {
    cat <<EOF
Usage: $0 <hf_url_or_repo_id> [options] [patterns...]

Arguments:
  hf_url_or_repo_id   URL Hugging Face (vd: https://huggingface.co/owner/repo)
                      hoặc Repo ID dạng owner/repo.

Options:
  --quant <Q>         Tải quant cụ thể (vd: PQ2_0, PTQ1_0...) kèm mmproj nếu có.
  --all               Tải tất cả các file .gguf trong repo.
  --dest <DIR>        Đường dẫn thư mục lưu (mặc định: models/<repo_name>).
  --token <TOK>       Hugging Face token (hoặc đặt biến môi trường BONSAI_TOKEN/HF_TOKEN).
  -h, --help          Hiển thị trợ giúp này.

EOF
    exit 0
}

# ── Tìm Python ──
PY=""
if [ -x "$DEMO_DIR/.venv/bin/python" ]; then
    PY="$DEMO_DIR/.venv/bin/python"
elif [ -x "$DEMO_DIR/.venv/Scripts/python.exe" ]; then
    PY="$DEMO_DIR/.venv/Scripts/python.exe"
elif command -v python3 >/dev/null 2>&1; then
    PY="python3"
elif command -v python >/dev/null 2>&1; then
    PY="python"
fi

if [ -z "$PY" ] || ! "$PY" -c "import huggingface_hub" 2>/dev/null; then
    err "Không tìm thấy Python có cài đặt thư viện 'huggingface_hub'."
    echo "  Hãy chạy: pip install -U huggingface_hub"
    exit 1
fi

raw_input=""
quant_choice=""
download_all=0
dest=""
token="${BONSAI_TOKEN:-${HF_TOKEN:-}}"
custom_patterns=""

# Parse options
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        --quant)
            shift
            quant_choice="$1"
            ;;
        --all)
            download_all=1
            ;;
        --dest)
            shift
            dest="$1"
            ;;
        --token)
            shift
            token="$1"
            ;;
        *)
            if [ -z "$raw_input" ]; then
                raw_input="$1"
            else
                if [ -n "$custom_patterns" ]; then
                    custom_patterns="$custom_patterns,$1"
                else
                    custom_patterns="$1"
                fi
            fi
            ;;
    esac
    shift
done

if [ -z "$raw_input" ]; then
    err "Thiếu URL hoặc Repo ID của Hugging Face."
    echo "Ví dụ: $0 https://huggingface.co/OS-Software/Ternary-Bonsai-2-27B-Uncensored-Heretic-GGUF"
    echo "Chạy '$0 --help' để xem thêm tùy chọn."
    exit 1
fi

# ── Chuẩn hóa URL thành repo_id: owner/name ──
repo_id="$(echo "$raw_input" | sed -E 's#^https?://([^/@]+@)?(www\.)?huggingface\.co/##; s#/(tree|blob)/.*##; s#/+$##')"

case "$repo_id" in
    */*)
        ;;
    *)
        err "Repo ID không hợp lệ: '$raw_input' (cần có định dạng owner/repo hoặc URL Hugging Face)."
        exit 1
        ;;
esac

repo_name="$(basename "$repo_id")"
if [ -z "$dest" ]; then
    dest="models/$repo_name"
fi
mkdir -p "$dest"

# ── Xác định Token nếu cần ──
if [ -z "$token" ] && [ -f "$DEMO_DIR/.bonsai_token" ]; then
    token="$(tr -d '\r\n' < "$DEMO_DIR/.bonsai_token")"
fi

step "Kiểm tra model repo: $repo_id"

# ── Xác định danh sách patterns tải về ──
allow_patterns=""
if [ -n "$custom_patterns" ]; then
    allow_patterns="$custom_patterns"
elif [ "$download_all" = "1" ]; then
    allow_patterns="*.gguf"
elif [ -n "$quant_choice" ]; then
    allow_patterns="*${quant_choice}*.gguf,*mmproj*.gguf"
else
    # Mặc định thông minh cho Bonsai 2 / ternary GGUFs:
    # Ưu tiên PQ2_0 + mmproj, nếu không có thì PTQ1_0, hoặc toàn bộ *.gguf
    allow_patterns="$("$PY" -c "
import os, sys
from huggingface_hub import HfApi

repo = '$repo_id'
tok = '$token' or None
try:
    api = HfApi(token=tok)
    files = api.list_repo_files(repo_id=repo)
    ggufs = [f for f in files if f.endswith('.gguf')]
    has_pq2 = any('PQ2_0' in f for f in ggufs)
    has_ptq1 = any('PTQ1_0' in f for f in ggufs)
    has_mmproj = any('mmproj' in f for f in ggufs)

    patterns = []
    if has_pq2:
        patterns.append('*PQ2_0*.gguf')
    elif has_ptq1:
        patterns.append('*PTQ1_0*.gguf')
    else:
        patterns.append('*.gguf')

    if has_mmproj and not patterns[0] == '*.gguf':
        patterns.append('*mmproj*.gguf')

    print(','.join(patterns))
except Exception:
    # Nếu không truy vấn trước được (vd offline/token), mặc định tìm PQ2_0 + mmproj
    print('*PQ2_0*.gguf,*mmproj*.gguf')
")"
fi

step "Bắt đầu tải các file khớp pattern: [${allow_patterns}]"
echo "  Repo:      $repo_id"
echo "  Thư mục:   $dest"
echo ""

# ── Thực hiện tải qua snapshot_download ──
"$PY" -c "
import os, sys
from huggingface_hub import snapshot_download

repo = '$repo_id'
dest = '$dest'
patterns_raw = '$allow_patterns'
token = '$token' or None

allow = [p.strip() for p in patterns_raw.split(',') if p.strip()]

try:
    snapshot_download(
        repo_id=repo,
        local_dir=dest,
        allow_patterns=allow,
        token=token
    )
except Exception as e:
    print(f'\n[ERR] Lỗi khi tải repo: {e}', file=sys.stderr)
    sys.exit(1)
"

info "Tải hoàn tất!"
echo ""
echo "Các file GGUF hiện có trong '$dest':"

# ── Hiển thị danh sách file & tìm model/mmproj chính ──
"$PY" -c "
import os, sys, glob

dest = '$dest'
ggufs = sorted(glob.glob(os.path.join(dest, '*.gguf')))
if not ggufs:
    print('  (Chưa có file .gguf nào)')
    sys.exit(0)

models = []
mmprojs = []
for f in ggufs:
    sz_mb = os.path.getsize(f) / (1024 * 1024)
    name = os.path.basename(f)
    print(f'  - {name} ({sz_mb:.1f} MB)')
    if 'mmproj' in name.lower():
        mmprojs.append(f)
    else:
        models.append(f)

print('')
if not models:
    sys.exit(0)

primary_model = models[0]
for m in models:
    if 'pq2_0' in m.lower():
        primary_model = m
        break

primary_mmproj = mmprojs[0] if mmprojs else ''

rel_model = os.path.relpath(primary_model, start='.').replace(chr(92), '/')
rel_mmproj = os.path.relpath(primary_mmproj, start='.').replace(chr(92), '/') if primary_mmproj else ''

sep = chr(92)
win_model = rel_model.replace('/', sep)
win_mmproj = rel_mmproj.replace('/', sep) if rel_mmproj else ''

print('=' * 68)
print('HƯỚNG DẪN KHỞI CHẠY MODEL:')
print('=' * 68)
print('\n[1] Trên Linux / macOS / Git Bash:')
if rel_mmproj:
    print(f'  BONSAI_GGUF=\"{rel_model}\" BONSAI_MMPROJ=\"{rel_mmproj}\" ./scripts/start_llama_server.sh')
else:
    print(f'  BONSAI_GGUF=\"{rel_model}\" ./scripts/start_llama_server.sh')

print('\n[2] Trên Windows PowerShell (Dùng script start_llama_server.ps1):')
ps1_path = f'.{sep}scripts{sep}start_llama_server.ps1'
if win_mmproj:
    print(f'  \$env:BONSAI_GGUF=\"{win_model}\"; \$env:BONSAI_MMPROJ=\"{win_mmproj}\"; {ps1_path}')
else:
    print(f'  \$env:BONSAI_GGUF=\"{win_model}\"; {ps1_path}')

print('\n[3] Trên Windows PowerShell (Chạy trực tiếp binary CUDA):')
direct_cmd = f'.{sep}bin{sep}cuda{sep}llama-server.exe -m \"{win_model}\"'
if win_mmproj:
    direct_cmd += f' --mmproj \"{win_mmproj}\"'
direct_cmd += f' -ngl 99 -fa on -c 32768 --jinja --webui-config-file scripts{sep}webui-config.json --host 127.0.0.1 --port 8080'
print(f'  {direct_cmd}')
print('=' * 68)
"
