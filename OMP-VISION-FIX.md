# Fix: omp gửi ảnh cho Bonsai 27B (sửa ở phía server)

## Triệu chứng
Dùng `omp` với ảnh (`@anh.png`) báo lỗi:
```
400 Output of tool call should be 'Input text'
```

## Nguyên nhân
`omp` nói chuyện với llama-server qua **OpenAI Responses API** (`POST /v1/responses`).
Khi đính ảnh, omp gọi tool `read` để nạp ảnh rồi trả **ảnh trong *output của tool***
(`function_call_output` chứa `input_image`). llama.cpp `/v1/responses` **chỉ cho phép
text trong output của tool** nên từ chối.

- Bản thân model **nhìn ảnh tốt** (lõi Qwen-VL + `mmproj`).
- `/v1/chat/completions` chấp nhận ảnh ở tool, nhưng omp lại tự chọn `/v1/responses`.

## Cách sửa (một chỗ ở server, mọi omp hưởng lợi)
Đặt một reverse proxy nhỏ trước llama-server. Proxy bắt request `/v1/responses`,
**dời ảnh từ output-tool sang một message `user`** (dạng Responses API chấp nhận) rồi
mới forward. Mọi path khác (web UI, `/v1/models`, `/v1/chat/completions`, `/health`,
streaming SSE) đi qua nguyên trạng.

```
omp / web UI / API  ->  proxy 0.0.0.0:8080  ->  llama-server 127.0.0.1:8081
```

Không phải chỉnh gì ở từng omp: chúng vẫn trỏ cổng 8080 như cũ.

## Chạy
Dừng server 8080 hiện tại, rồi dùng **wrapper** thay cho `start_llama_server.ps1`
(giữ nguyên các env `BONSAI_*` bạn vẫn dùng):

```powershell
$env:BONSAI_CTX   = 128000
$env:BONSAI_MODEL = "27B"
$env:BONSAI_KV4   = 1
$env:BONSAI_HOST  = "0.0.0.0"          # không còn cần thiết: proxy tự expose 0.0.0.0:8080
$env:BONSAI_GGUF  = "models\Ternary-Bonsai-2-27B-Uncensored-Heretic-GGUF\Ternary-Bonsai-2-27B-Uncensored-Heretic-PQ2_0.gguf"
$env:BONSAI_MMPROJ= "models\Ternary-Bonsai-2-27B-Uncensored-Heretic-GGUF\mmproj-BF16.gguf"

.\scripts\start_omp_vision.ps1 -np 1
```

Wrapper sẽ chuyển tiếp mọi cờ CLI (như `-np 1`, `--temperature 0.7`) sang `llama-server`.
Nó sẽ chạy llama-server ở `127.0.0.1:8081`, đợi `/health`, rồi mở proxy ở

Khi proxy sửa một request ảnh, nó in:
```
[proxy] /v1/responses: đã dời N ảnh khỏi tool-output -> user message
```

## Tùy chọn (env)
| Env | Mặc định | Ý nghĩa |
|---|---|---|
| `BONSAI_PUBLIC_PORT`   | 8080 | cổng công khai cho omp (proxy) |
| `BONSAI_INTERNAL_PORT` | 8081 | cổng nội bộ llama-server |
| `BONSAI_PROXY_BIND`    | 0.0.0.0 | địa chỉ proxy lắng nghe |
| `BONSAI_IMAGE_MAX_TOKENS` | (xem VISION.md) | OCR chữ nhỏ nên đặt `0` hoặc `2048+` |

## File liên quan
- `scripts/omp_vision_proxy.py` — proxy (chỉ dùng thư viện chuẩn Python).
- `scripts/start_omp_vision.ps1` — wrapper khởi động cả cụm.
- `scripts/start_llama_server.ps1` — đã thêm hỗ trợ `BONSAI_PORT` (mặc định 8080, tương thích ngược).

## Ghi chú
- Nếu không muốn proxy: có thể sửa riêng từng omp bằng config overlay
  (`providers: { llama.cpp: { modelOverrides: { bonsai2-27b: { api: openai-completions } } } }`)
  để omp dùng `/v1/chat/completions`. Nhưng phải làm cho **mỗi** omp → kém tiện hơn fix server.
- Chỉ REQUEST bị sửa; response giữ nguyên nên streaming/định dạng không đổi.
