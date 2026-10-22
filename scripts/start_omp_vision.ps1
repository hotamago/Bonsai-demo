# start_omp_vision.ps1
# Khởi động llama-server + omp-vision-proxy để omp (Responses API) gửi được ẢNH.
#
# Topology:
#   omp / web UI / API  ->  proxy 0.0.0.0:8080  ->  llama-server 127.0.0.1:8081
#
# Cách dùng: set các env BONSAI_* như bình thường rồi chạy script NÀY thay cho
# start_llama_server.ps1. Mọi omp cứ trỏ vào cổng 8080 như cũ — không cần sửa gì.
#
#   $env:BONSAI_MODEL="27B"; $env:BONSAI_CTX=128000; $env:BONSAI_KV4=1
#   $env:BONSAI_GGUF="models\...\...-PQ2_0.gguf"
#   $env:BONSAI_MMPROJ="models\...\mmproj-BF16.gguf"
#   .\scripts\start_omp_vision.ps1
#
# Tùy chọn:
#   BONSAI_PUBLIC_PORT   (mặc định 8080)  cổng công khai cho omp
#   BONSAI_INTERNAL_PORT (mặc định 8081)  cổng nội bộ của llama-server
#   BONSAI_PROXY_BIND    (mặc định 0.0.0.0) địa chỉ proxy lắng nghe

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$DemoDir   = Split-Path $ScriptDir -Parent
Set-Location $DemoDir

$PublicPort   = if ($env:BONSAI_PUBLIC_PORT)   { [int]$env:BONSAI_PUBLIC_PORT }   else { 8080 }
$InternalPort = if ($env:BONSAI_INTERNAL_PORT) { [int]$env:BONSAI_INTERNAL_PORT } else { 8081 }
$ProxyBind    = if ($env:BONSAI_PROXY_BIND)    { $env:BONSAI_PROXY_BIND }         else { "0.0.0.0" }

# chọn python (chỉ cần stdlib)
$Py = "python"
if (Test-Path (Join-Path $DemoDir ".venv\Scripts\python.exe")) {
    $Py = Join-Path $DemoDir ".venv\Scripts\python.exe"
}

# nếu đã có thứ gì chiếm cổng công khai -> báo và thoát
try {
    $null = Invoke-WebRequest -Uri "http://localhost:$PublicPort/health" -TimeoutSec 2
    Write-Host "[ERR] Cổng $PublicPort đã có service chạy. Dừng nó trước khi chạy wrapper này." -ForegroundColor Red
    exit 1
} catch {}

Write-Host "=== Bonsai + omp vision proxy ===" -ForegroundColor Cyan
Write-Host "  llama-server (nội bộ): 127.0.0.1:$InternalPort"
Write-Host "  proxy (công khai)    : ${ProxyBind}:$PublicPort   <- omp trỏ vào đây"
Write-Host ""

# llama-server chạy ở cổng nội bộ, chỉ bind localhost
$env:BONSAI_PORT = "$InternalPort"
$env:BONSAI_HOST = "127.0.0.1"

$serverProc = $null
try {
    # chạy start_llama_server.ps1 trong cửa sổ riêng (để xem log server), kế thừa toàn bộ env BONSAI_*
    # chuyển tiếp mọi tham số CLI (như -np 1, --temperature 0.7, v.v.)
    $forwardArgs = @()
    foreach ($a in $args) {
        if ($a -match '\s' -and -not ($a.StartsWith('"') -and $a.EndsWith('"'))) {
            $escaped = $a.Replace('"', '\"')
            $forwardArgs += """$escaped"""
        } else {
            $forwardArgs += $a
        }
    }
    $launchArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $ScriptDir "start_llama_server.ps1")) + $forwardArgs

    $serverProc = Start-Process -FilePath "powershell.exe" `
        -ArgumentList $launchArgs `
        -PassThru

    # chờ llama-server sẵn sàng
    Write-Host "[wrapper] Đang chờ llama-server tại 127.0.0.1:$InternalPort/health ..." -ForegroundColor Yellow
    $ready = $false
    for ($i = 0; $i -lt 600; $i++) {
        if ($serverProc.HasExited) {
            Write-Host "[ERR] llama-server đã thoát (exit $($serverProc.ExitCode)). Xem cửa sổ server để biết lỗi." -ForegroundColor Red
            exit 1
        }
        try {
            $h = Invoke-WebRequest -Uri "http://127.0.0.1:$InternalPort/health" -TimeoutSec 2
            if ($h.StatusCode -eq 200) { $ready = $true; break }
        } catch {}
        Start-Sleep -Seconds 2
    }
    if (-not $ready) {
        Write-Host "[ERR] Hết giờ chờ llama-server sẵn sàng." -ForegroundColor Red
        exit 1
    }
    Write-Host "[wrapper] llama-server đã sẵn sàng. Khởi động proxy..." -ForegroundColor Green
    Write-Host ""

    # proxy chạy foreground; Ctrl+C sẽ dừng cả cụm (finally bên dưới)
    $env:BONSAI_PROXY_HOST    = $ProxyBind
    $env:BONSAI_PROXY_PORT    = "$PublicPort"
    $env:BONSAI_UPSTREAM_HOST = "127.0.0.1"
    $env:BONSAI_UPSTREAM_PORT = "$InternalPort"
    & $Py (Join-Path $ScriptDir "omp_vision_proxy.py")
}
finally {
    if ($serverProc -and -not $serverProc.HasExited) {
        Write-Host ""
        Write-Host "[wrapper] Dừng llama-server (PID $($serverProc.Id)) ..." -ForegroundColor Yellow
        # kill cả cây tiến trình (powershell -> llama-server.exe)
        try { & taskkill /PID $serverProc.Id /T /F | Out-Null } catch {}
    }
}
