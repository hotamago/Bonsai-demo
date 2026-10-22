#!/bin/sh
# Container entrypoint: run the demo's launcher with the container's settings.
#
# Every BONSAI_* variable keeps its meaning from environment_variables.md.
# BONSAI_EXTRA_ARGS holds trailing llama-server flags (word-split, e.g.
# "-np 1 --ctx-checkpoints 4"); arguments given to the container come after it.
set -e

# An empty key must mean "no key", not "the empty string is the key".
[ -n "${LLAMA_API_KEY:-}" ] || unset LLAMA_API_KEY
if [ -z "${LLAMA_API_KEY:-}" ]; then
    echo "[entrypoint] WARNING: LLAMA_API_KEY is empty - the API is unauthenticated." >&2
fi

if [ -z "${BONSAI_GGUF:-}" ] || [ ! -f "$BONSAI_GGUF" ]; then
    echo "[entrypoint] BONSAI_GGUF='${BONSAI_GGUF:-}' is not a file inside the container." >&2
    echo "             Check MODELS_DIR / BONSAI_GGUF_FILE in .env (models are mounted at /models)." >&2
    exit 1
fi
if [ -n "${BONSAI_MMPROJ:-}" ] && [ ! -f "$BONSAI_MMPROJ" ]; then
    echo "[entrypoint] BONSAI_MMPROJ='$BONSAI_MMPROJ' is not a file; starting text-only." >&2
    unset BONSAI_MMPROJ
fi

# shellcheck disable=SC2086
exec /opt/bonsai/scripts/start_llama_server.sh ${BONSAI_EXTRA_ARGS:-} "$@"
