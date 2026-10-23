# Bonsai 2 27B on a Linux NVIDIA server (Docker Compose)

Runs `llama-server` from the pinned PrismML llama.cpp release (`prism-b10787-73bfe6c`,
prebuilt Linux CUDA 13.3 binaries; PQ2_0 needs the fork) behind the
[omp vision proxy](../../OMP-VISION-FIX.md), as a service that restarts by itself.

```
client --(SSH tunnel / local tunnel daemon)--> 127.0.0.1:8080  proxy  (python:3.13.17-slim-trixie)
                                                     |
                                                     v
                                              llama:8081  llama-server  (bonsai-llama image, GPU)
```

- Only the proxy is published, and only on the host's loopback (`BONSAI_BIND`).
- The model stays on the host (`MODELS_DIR`, mounted read-only); the image holds binaries only.
- The container runs the demo's own `scripts/start_llama_server.sh`, so flags match a
  workstation launch with the same `BONSAI_*` settings (sampling, `--jinja`, mmproj, KV4, alias).
- The image build needs no network: `fetch.sh` downloads every input first, pinned and
  sha256-checked, through a proxy if needed.

## Requirements

- x86_64 Linux, NVIDIA driver with CUDA >= 13.3 (`nvidia-smi`), Docker with Compose v2 and
  the NVIDIA Container Toolkit.
- About 8 GB disk for the model, 3.1 GB for the image. 12 GB of VRAM runs the 27B with a
  128k context (see measurements below).

## Install

```bash
git clone https://github.com/hotamago/Bonsai-demo && cd Bonsai-demo/deploy/linux-cuda
cp .env.example .env && chmod 600 .env
sed -i "s/^LLAMA_API_KEY=.*/LLAMA_API_KEY=$(openssl rand -hex 32)/" .env   # then review .env

./fetch.sh all            # llama.cpp release + libgomp1 .deb -> build/, model -> MODELS_DIR
./fetch.sh images         # only if dockerd cannot pull from Docker Hub itself (see below)
docker compose build
docker compose up -d
docker compose ps         # llama and proxy "healthy" after ~10-60 s, autoheal running
```

Behind a restricted network, prefix the fetches with a proxy, e.g.
`ALL_PROXY=socks5h://127.0.0.1:40000 ./fetch.sh all`. `fetch.sh images` pulls the base
images with [crane](https://github.com/google/go-containerregistry) through the same proxy
and `docker load`s them, so the docker daemon needs no proxy and no restart.

Update: `git pull`, then `docker compose build && docker compose up -d`.
Stop: `docker compose down` (in this folder; it only touches the `bonsai` project).

## Settings (`.env`)

| Variable | Default | Meaning |
|---|---|---|
| `LLAMA_API_KEY` | empty | Required as `Authorization: Bearer <key>` on every API route (also `/v1/models`, `/props`, `/slots`); only `/health` and the static web UI page answer without it. Empty = no auth. |
| `MODELS_DIR` | `../../models` | Host folder mounted at `/models`. |
| `BONSAI_GGUF_FILE`, `BONSAI_MMPROJ_FILE` | Heretic PQ2_0 + mmproj Q8_0 | Paths relative to `MODELS_DIR`. |
| `BONSAI_ALIAS` | `bonsai2-27b` | Model id in `/v1/models`. |
| `BONSAI_CTX` | `128000` | Context length (`0` = RAM-tiered auto). |
| `BONSAI_KV4` | `1` | q4_0 KV cache. |
| `BONSAI_IMAGE_MAX_TOKENS` | `0` | Vision tokens per image, `0` = uncapped. |
| `BONSAI_MMPROJ_CPU` | `0` | `1` keeps the projector in RAM (frees ~0.6-0.9 GB VRAM). |
| `BONSAI_EXTRA_ARGS` | `-np 1 --ctx-checkpoints 4` | Extra llama-server flags. |
| `BONSAI_BIND`, `BONSAI_PUBLIC_PORT` | `127.0.0.1`, `8080` | Where the proxy is published. |

Other `BONSAI_*` variables from [environment_variables.md](../../environment_variables.md)
can be added to the `llama` service's `environment:` block.

## Use it from another machine

The port is bound to the server's loopback. Forward it over SSH:

```bash
ssh -N -L 8080:127.0.0.1:8080 <user>@<server>
```

Then point clients at `http://127.0.0.1:8080` exactly as with a local server: OpenAI base
URL `http://127.0.0.1:8080/v1`, model `bonsai2-27b`, API key = `LLAMA_API_KEY`. The web UI
is at `http://127.0.0.1:8080` (enter the key in its settings). omp's `/v1/responses` image
calls go through the proxy fix.

If you publish the port through a tunnel daemon on the host (it reaches `127.0.0.1:8080`),
keep `LLAMA_API_KEY` set. Streaming requests stay alive through idle-timeout proxies:
llama-server sends an SSE `:` comment every 30 s during prefill and the proxy forwards it
at once. A **non-streaming** request sends nothing until it is finished, so a long cold
prompt can exceed a 100 s idle limit (Cloudflare answers 524); use `stream: true` there.

## Checks

```bash
KEY=$(sed -n 's/^LLAMA_API_KEY=//p' .env)
curl -s 127.0.0.1:8080/health
curl -s 127.0.0.1:8080/v1/models -H "Authorization: Bearer $KEY"
curl -s 127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"bonsai2-27b","messages":[{"role":"user","content":"Say hi"}],"max_tokens":64}'
docker compose logs --tail 50 llama
```

## Measured (RTX 3080 12 GB, i9-11900K, driver 615.71)

Model `Ternary-Bonsai-2-27B-Uncensored-Heretic-PQ2_0.gguf` + `mmproj-Q8_0.gguf`, `-c 128000`,
q4_0 KV, projector on the GPU, `-np 1`. Cold prompts (`cache_prompt: false`), 256 generated
tokens, streamed (the 58k and 116k rows straight to llama-server, the others through the proxy).

| | |
|---|---|
| VRAM after load (128k ctx) | 10.3 GB of 12 GB |
| VRAM after a 116k-token prompt / a 1920x1080 image (uncapped) | 10.4 / 10.5 GB |
| Start-up (model in page cache) | ~3 s to healthy |

| Prompt tokens | Prefill tok/s | Time to first token | Generation tok/s |
|---:|---:|---:|---:|
| 1,016 | 1,206 | 1.0 s | 68.5 |
| 2,354 | 1,268 | 2.0 s | 66.8 |
| 34,859 | 1,062 | 33.0 s | 45.8 |
| 58,031 | 972 | 59.9 s | 37.8 |
| 115,922 | 745 | 156.2 s | 25.8 |

A 1920x1080 image is ~2,000 prompt tokens and took 2.8 s to prefill.
