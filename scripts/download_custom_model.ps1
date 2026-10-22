# Download any custom GGUF model from Hugging Face into models\<repo-name>\
# and display ready-to-use launch commands.
#
# Usage:
#   .\scripts\download_custom_model.ps1 <hf_url_or_repo_id> [options]
#
# Examples:
#   .\scripts\download_custom_model.ps1 https://huggingface.co/OS-Software/Ternary-Bonsai-2-27B-Uncensored-Heretic-GGUF
#   .\scripts\download_custom_model.ps1 OS-Software/Ternary-Bonsai-2-27B-Uncensored-Heretic-GGUF -Quant PTQ1_0
#   .\scripts\download_custom_model.ps1 OS-Software/Ternary-Bonsai-2-27B-Uncensored-Heretic-GGUF -All
param(
    [Parameter(Position=0, Mandatory=$false)]
    [string]$Target,

    [string]$Quant = "",
    [switch]$All,
    [string]$Dest = "",
    [string]$Token = "",
    [string[]]$Patterns = @()
)

$ErrorActionPreference = "Stop"

if (-not $Target) {
    Write-Host "[ERR] Thieu URL hoac Repo ID cua Hugging Face." -ForegroundColor Red
    Write-Host "Vi du: .\scripts\download_custom_model.ps1 https://huggingface.co/OS-Software/Ternary-Bonsai-2-27B-Uncensored-Heretic-GGUF" -ForegroundColor Yellow
    exit 1
}

$DemoDir = Split-Path $PSScriptRoot -Parent
Set-Location $DemoDir

# Find python
$Py = $null
$candidates = @(
    (Join-Path $DemoDir ".venv\Scripts\python.exe"),
    (Join-Path $DemoDir ".venv\bin\python"),
    "python",
    "python3"
)
foreach ($c in $candidates) {
    try {
        $out = & $c -c "import huggingface_hub; print('ok')" 2>$null
        if ($out -match "ok") { $Py = $c; break }
    } catch {}
}

if (-not $Py) {
    Write-Host "[ERR] Khong tim thay Python hoac thu vien 'huggingface_hub'." -ForegroundColor Red
    Write-Host "      Hay chay: pip install -U huggingface_hub" -ForegroundColor Yellow
    exit 1
}

# Normalize URL to owner/repo
$RepoId = $Target -replace '^https?://([^/@]+@)?(www\.)?huggingface\.co/', ''
$RepoId = $RepoId -replace '/(tree|blob)/.*$', ''
$RepoId = $RepoId.Trim('/')

if ($RepoId -notmatch '^[^/]+/[^/]+$') {
    Write-Host "[ERR] Repo ID khong hop le: '$Target'" -ForegroundColor Red
    exit 1
}

$RepoName = Split-Path $RepoId -Leaf
if (-not $Dest) {
    $Dest = Join-Path "models" $RepoName
}
if (-not (Test-Path $Dest)) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
}

$TokenVal = if ($Token) { $Token } elseif ($env:BONSAI_TOKEN) { $env:BONSAI_TOKEN } elseif ($env:HF_TOKEN) { $env:HF_TOKEN } else { "" }
if (-not $TokenVal -and (Test-Path (Join-Path $DemoDir ".bonsai_token"))) {
    $TokenVal = (Get-Content (Join-Path $DemoDir ".bonsai_token") -Raw).Trim()
}

Write-Host "==> Kiem tra repo: $RepoId" -ForegroundColor Cyan

$AllowPatterns = ""
if ($Patterns.Count -gt 0) {
    $AllowPatterns = $Patterns -join ","
} elseif ($All) {
    $AllowPatterns = "*.gguf"
} elseif ($Quant) {
    $AllowPatterns = "*$Quant*.gguf,*mmproj*.gguf"
} else {
    $checkScript = @"
import os, sys
from huggingface_hub import HfApi
repo = '$RepoId'
tok = '$TokenVal' or None
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
    if has_mmproj and patterns[0] != '*.gguf':
        patterns.append('*mmproj*.gguf')
    print(','.join(patterns))
except Exception:
    print('*PQ2_0*.gguf,*mmproj*.gguf')
"@
    $AllowPatterns = & $Py -c $checkScript
}

Write-Host "==> Bat dau tai cac file khop pattern: [$AllowPatterns]" -ForegroundColor Cyan
Write-Host "    Repo:    $RepoId"
Write-Host "    Thu muc: $Dest"
Write-Host ""

$dlScript = @"
import sys
from huggingface_hub import snapshot_download
allow = [p.strip() for p in '$AllowPatterns'.split(',') if p.strip()]
token = '$TokenVal' or None
try:
    snapshot_download(repo_id='$RepoId', local_dir=r'$Dest', allow_patterns=allow, token=token)
except Exception as e:
    print(f'[ERR] Loi khi tai: {e}', file=sys.stderr)
    sys.exit(1)
"@
& $Py -c $dlScript

Write-Host "[OK] Tai hoan tat!" -ForegroundColor Green
Write-Host ""
Write-Host "Cac file GGUF trong '$Dest':"

$ggufs = Get-ChildItem -Path $Dest -Filter *.gguf -File -ErrorAction SilentlyContinue
if (-not $ggufs) {
    Write-Host "  (Chua co file .gguf nao)"
    exit 0
}

$modelFile = $null
$mmprojFile = $null
foreach ($f in $ggufs) {
    $mb = [math]::Round($f.Length / 1MB, 1)
    Write-Host "  - $($f.Name) ($mb MB)"
    if ($f.Name -match "mmproj") {
        if (-not $mmprojFile) { $mmprojFile = $f }
    } else {
        if (-not $modelFile -or $f.Name -match "pq2_0") {
            $modelFile = $f
        }
    }
}

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "HUONG DAN KHOI CHAY MODEL:" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

$relModel = Resolve-Path -Relative $modelFile.FullName
$relMmproj = if ($mmprojFile) { Resolve-Path -Relative $mmprojFile.FullName } else { $null }

Write-Host "`n[1] Windows PowerShell (Dung script khoi chay):" -ForegroundColor Yellow
if ($relMmproj) {
    Write-Host "  `$env:BONSAI_GGUF=`"$relModel`"; `$env:BONSAI_MMPROJ=`"$relMmproj`"; .\scripts\start_llama_server.ps1"
} else {
    Write-Host "  `$env:BONSAI_GGUF=`"$relModel`"; .\scripts\start_llama_server.ps1"
}

Write-Host "`n[2] Windows PowerShell (Lenh truc tiep llama-server.exe):" -ForegroundColor Yellow
$direct = ".\bin\cuda\llama-server.exe -m `"$relModel`""
if ($relMmproj) { $direct += " --mmproj `"$relMmproj`"" }
$direct += " -ngl 99 -fa on -c 32768 --jinja --webui-config-file scripts\webui-config.json --host 127.0.0.1 --port 8080"
Write-Host "  $direct"

Write-Host "`n[3] Linux / macOS / Git Bash:" -ForegroundColor Yellow
$posixModel = $relModel -replace '\\', '/'
$posixMmproj = if ($relMmproj) { $relMmproj -replace '\\', '/' } else { $null }
if ($posixMmproj) {
    Write-Host "  BONSAI_GGUF=`"$posixModel`" BONSAI_MMPROJ=`"$posixMmproj`" ./scripts/start_llama_server.sh"
} else {
    Write-Host "  BONSAI_GGUF=`"$posixModel`" ./scripts/start_llama_server.sh"
}
Write-Host "======================================================================" -ForegroundColor Cyan
