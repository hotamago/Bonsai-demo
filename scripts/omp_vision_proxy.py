#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
omp_vision_proxy — reverse proxy nhỏ đặt TRƯỚC llama-server để sửa lỗi
omp (và mọi client dùng OpenAI "Responses API") không gửi được ảnh.

VẤN ĐỀ:
  omp đính ảnh (@file) bằng cách gọi tool `read`, rồi trả ẢNH trong *output của
  tool* (function_call_output chứa input_image). llama.cpp /v1/responses chỉ cho
  phép TEXT trong output của tool -> trả 400 "Output of tool call should be 'Input text'".
  (Endpoint /v1/chat/completions thì chấp nhận ảnh ở tool, nên lỗi chỉ xảy ra với
  Responses API mà omp tự chọn khi dò server llama.cpp.)

CÁCH SỬA (chỉ sửa REQUEST, không đụng response):
  Với mỗi request POST .../v1/responses, duyệt mảng `input`. Gặp item
  function_call_output mà `output` là mảng có phần tử ảnh -> thay `output` bằng
  text thuần, và chèn NGAY SAU một message role=user mang ảnh đó (dạng input_image
  mà Responses API chấp nhận). Nhờ vậy model vẫn "nhìn" được ảnh, server hết 400.

Mọi path/method khác (/, /v1/models, /v1/chat/completions, /health, static, SSE
streaming…) được chuyển tiếp nguyên trạng.

ENV:
  BONSAI_PROXY_HOST     (mặc định 0.0.0.0)  — địa chỉ proxy lắng nghe
  BONSAI_PROXY_PORT     (mặc định 8080)     — cổng proxy (cổng omp sẽ gọi)
  BONSAI_UPSTREAM_HOST  (mặc định 127.0.0.1)
  BONSAI_UPSTREAM_PORT  (mặc định 8081)     — cổng llama-server thật
"""
import os, sys, json, http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROXY_HOST = os.environ.get("BONSAI_PROXY_HOST", "0.0.0.0")
PROXY_PORT = int(os.environ.get("BONSAI_PROXY_PORT", "8080"))
UP_HOST = os.environ.get("BONSAI_UPSTREAM_HOST", "127.0.0.1")
UP_PORT = int(os.environ.get("BONSAI_UPSTREAM_PORT", "8081"))

HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
              "te", "trailers", "transfer-encoding", "upgrade"}
IMG_TYPES = {"input_image", "output_image", "image_url", "image"}


def _img_url(part):
    """Trích URL ảnh từ nhiều biến thể shape khác nhau."""
    u = part.get("image_url", part.get("url"))
    if isinstance(u, dict):
        u = u.get("url")
    return u


def rewrite_responses_body(body: bytes):
    """Trả (body_mới, số_ảnh_đã_dời). Không đổi gì -> trả (body, 0)."""
    try:
        data = json.loads(body)
    except Exception:
        return body, 0
    inp = data.get("input")
    if not isinstance(inp, list):
        return body, 0

    new_input, moved = [], 0
    for item in inp:
        new_input.append(item)
        if not (isinstance(item, dict) and item.get("type") == "function_call_output"):
            continue
        out = item.get("output")
        if not isinstance(out, list):
            continue
        images = [p for p in out if isinstance(p, dict) and p.get("type") in IMG_TYPES]
        if not images:
            continue
        texts = [p.get("text", "") for p in out if isinstance(p, dict) and p.get("type") in ("input_text", "text", "output_text")]
        note = " ".join(t for t in texts if t).strip() or "[tool đã trả ảnh; xem message kế tiếp]"
        item["output"] = note  # output chỉ còn text -> server chấp nhận
        content = [{"type": "input_text",
                    "text": f"[Ảnh do tool trả về (call_id={item.get('call_id', '')})]"}]
        for img in images:
            url = _img_url(img)
            if not url:
                continue
            content.append({"type": "input_image", "image_url": url,
                            "detail": img.get("detail", "auto")})
            moved += 1
        # chèn message user mang ảnh ngay sau output của tool
        new_input.append({"role": "user", "content": content})

    if moved == 0:
        return body, 0
    data["input"] = new_input
    return json.dumps(data, ensure_ascii=False).encode("utf-8"), moved


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "omp-vision-proxy/1.0"

    def log_message(self, fmt, *args):
        pass  # im lặng; chỉ in khi thực sự rewrite (xem _relay)

    def _relay(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""

        # chỉ can thiệp đúng request Responses API có ảnh trong tool output
        path = self.path
        if method == "POST" and path.rstrip("/").endswith("/v1/responses") and body:
            new_body, moved = rewrite_responses_body(body)
            if moved:
                body = new_body
                sys.stderr.write(f"[proxy] /v1/responses: đã dời {moved} ảnh khỏi tool-output -> user message\n")
                sys.stderr.flush()

        # dựng header gửi lên upstream
        up_headers = {}
        for k, v in self.headers.items():
            if k.lower() in HOP_BY_HOP or k.lower() == "content-length":
                continue
            up_headers[k] = v
        up_headers["Host"] = f"{UP_HOST}:{UP_PORT}"
        if body:
            up_headers["Content-Length"] = str(len(body))

        try:
            conn = http.client.HTTPConnection(UP_HOST, UP_PORT, timeout=1800)
            conn.request(method, path, body=body if body else None, headers=up_headers)
            resp = conn.getresponse()
        except Exception as e:
            self.send_response(502)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            msg = f"omp-vision-proxy: không kết nối được upstream {UP_HOST}:{UP_PORT}: {e}".encode("utf-8")
            self.send_header("Content-Length", str(len(msg)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(msg)
            return

        # trả status + header (bỏ hop-by-hop & content-length), stream body về client
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() in HOP_BY_HOP or k.lower() == "content-length":
                continue
            self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            while True:
                # read1, not read: on a chunked (SSE) body read(n) blocks until n bytes
                # have arrived, which holds back streamed tokens and llama-server's
                # 30 s ":" heartbeats during a long prefill (idle-timeout proxies such
                # as Cloudflare then close the request).
                chunk = resp.read1(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            conn.close()

    # map mọi method thường dùng
    def do_GET(self):     self._relay("GET")
    def do_POST(self):    self._relay("POST")
    def do_PUT(self):     self._relay("PUT")
    def do_DELETE(self):  self._relay("DELETE")
    def do_PATCH(self):   self._relay("PATCH")
    def do_OPTIONS(self): self._relay("OPTIONS")
    def do_HEAD(self):    self._relay("HEAD")


def main():
    srv = ThreadingHTTPServer((PROXY_HOST, PROXY_PORT), Handler)
    sys.stderr.write(
        f"[proxy] omp-vision-proxy đang chạy: nghe {PROXY_HOST}:{PROXY_PORT}  ->  upstream {UP_HOST}:{UP_PORT}\n"
        f"[proxy] Trỏ omp vào http://<host>:{PROXY_PORT} như bình thường. Ctrl+C để dừng.\n")
    sys.stderr.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
