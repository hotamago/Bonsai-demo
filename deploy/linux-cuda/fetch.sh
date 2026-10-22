#!/bin/sh
# Fetch everything the Linux CUDA deployment needs, each pinned and sha256-checked.
#
#   ./fetch.sh binaries   PrismML llama.cpp release + libgomp1 .deb -> deploy/linux-cuda/build/
#   ./fetch.sh model      GGUF + mmproj from Hugging Face   -> $MODELS_DIR (from .env)
#   ./fetch.sh images     base images through a proxy into the local docker daemon
#                         (only for hosts whose dockerd cannot reach the registries)
#   ./fetch.sh all        binaries + model
#
# Proxy: curl honours ALL_PROXY / HTTPS_PROXY, e.g.
#   ALL_PROXY=socks5h://127.0.0.1:40000 ./fetch.sh all
# `images` uses crane (go-containerregistry) with the same proxy, then `docker load`,
# so the docker daemon itself needs no proxy and no restart.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"

LLAMA_RELEASE="prism-b10787-73bfe6c"
LLAMA_ASSET="llama-${LLAMA_RELEASE}-bin-linux-cuda-13.3-x64.tar.gz"
LLAMA_SHA256="e2d492f50d70f3e01b4b3ae68f670ae6825870d97206fb1bcb5b4376640c0e0c"
# libgomp1 for the CUDA runtime image (Ubuntu 24.04 noble-updates; sha256 from its Packages index)
LIBGOMP1_DEB="libgomp1_14.2.0-4ubuntu2~24.04.1_amd64.deb"
LIBGOMP1_SHA256="e8a95ec58125b4933597f30ff56c2ae10edf90f287262e366d4b6edea3019144"

HF_REPO="OS-Software/Ternary-Bonsai-2-27B-Uncensored-Heretic-GGUF"
HF_REVISION="5ab50fd49410941a8d4f97912303b1c7d458ffa2"
# file sha256 (= Hugging Face LFS oid at HF_REVISION)
MODEL_FILES="
Ternary-Bonsai-2-27B-Uncensored-Heretic-PQ2_0.gguf c0959544f1422c569d07ccef8911dc0d016034bc1285d91010a6630fdf4c4dda
mmproj-Q8_0.gguf 6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903
"

CRANE_VERSION="v0.22.1"
CRANE_SHA256="0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0"
IMAGES="nvidia/cuda:13.3.1-runtime-ubuntu24.04 python:3.13.17-slim-trixie"

say() { printf '==> %s\n' "$*"; }
die() { printf '[ERR] %s\n' "$*" >&2; exit 1; }

check_sha() { # file sha
    echo "$2  $1" | sha256sum -c --status - || die "sha256 mismatch: $1"
}

download() { # url dest sha
    if [ -f "$2" ] && echo "$3  $2" | sha256sum -c --status - 2>/dev/null; then
        say "ok (already present): $(basename "$2")"
        return
    fi
    say "downloading $(basename "$2")"
    if [ -t 2 ]; then _pg=--progress-bar; else _pg=-sS; fi
    curl -L --fail --retry 5 --retry-delay 5 -C - "$_pg" -o "$2.part" "$1"
    check_sha "$2.part" "$3"
    mv "$2.part" "$2"
}

env_value() { # NAME -> value from .env, if set there
    [ -f "$HERE/.env" ] || return 0
    sed -n "s/^$1=//p" "$HERE/.env" | tail -n 1 | sed 's/^"\(.*\)"$/\1/'
}

fetch_binaries() {
    mkdir -p "$HERE/build"
    download "https://github.com/PrismML-Eng/llama.cpp/releases/download/$LLAMA_RELEASE/$LLAMA_ASSET" \
        "$HERE/build/$LLAMA_ASSET" "$LLAMA_SHA256"
    download "http://archive.ubuntu.com/ubuntu/pool/main/g/gcc-14/$LIBGOMP1_DEB" \
        "$HERE/build/$LIBGOMP1_DEB" "$LIBGOMP1_SHA256"
}

fetch_model() {
    _dir="${MODELS_DIR:-$(env_value MODELS_DIR)}"
    _dir="${_dir:-../../models}"
    case "$_dir" in /*) ;; *) _dir="$HERE/$_dir" ;; esac   # relative to this folder, like compose
    _sub="$(basename "$HF_REPO")"
    mkdir -p "$_dir/$_sub"
    echo "$MODEL_FILES" | while read -r _f _sha; do
        [ -n "$_f" ] || continue
        download "https://huggingface.co/$HF_REPO/resolve/$HF_REVISION/$_f" "$_dir/$_sub/$_f" "$_sha"
    done
    say "model files in $_dir/$_sub"
}

fetch_images() {
    command -v docker >/dev/null || die "docker not found"
    _proxy="${HTTPS_PROXY:-${ALL_PROXY:-}}"
    # Go's proxy support takes socks5:// (it resolves names on the proxy side anyway).
    _proxy="$(printf '%s' "$_proxy" | sed 's#^socks5h://#socks5://#')"
    _crane="$(command -v crane || true)"
    if [ -z "$_crane" ]; then
        _crane="$HERE/build/crane"
        if [ ! -x "$_crane" ]; then
            mkdir -p "$HERE/build"
            say "downloading crane $CRANE_VERSION"
            curl -L --fail -sS -o "$HERE/build/crane.tar.gz" \
                "https://github.com/google/go-containerregistry/releases/download/$CRANE_VERSION/go-containerregistry_Linux_x86_64.tar.gz"
            check_sha "$HERE/build/crane.tar.gz" "$CRANE_SHA256"
            tar -xzf "$HERE/build/crane.tar.gz" -C "$HERE/build" crane
            rm -f "$HERE/build/crane.tar.gz"
        fi
    fi
    for _img in $IMAGES; do
        if docker image inspect "$_img" >/dev/null 2>&1; then
            say "ok (already loaded): $_img"
            continue
        fi
        say "pulling $_img via crane"
        _tar="$HERE/build/image.tar"
        HTTPS_PROXY="$_proxy" "$_crane" pull --platform linux/amd64 "$_img" "$_tar"
        docker load -i "$_tar"
        rm -f "$_tar"
    done
}

case "${1:-}" in
    binaries) fetch_binaries ;;
    model)    fetch_model ;;
    images)   fetch_images ;;
    all)      fetch_binaries; fetch_model ;;
    *) sed -n '2,14p' "$0"; exit 2 ;;
esac
