# Funcoes usadas pelos outros scripts. Nao precisa rodar este arquivo direto.

$ErrorActionPreference = "Continue"

$Ambientes = [ordered]@{
    "dev" = "dev"
    "hml" = "homologacao"
    "prd" = "producao"
}

function Passo([string]$texto) {
    Write-Host ""
    Write-Host "==> $texto" -ForegroundColor Cyan
}

function Ok([string]$texto) {
    Write-Host "    OK: $texto" -ForegroundColor Green
}

function Aviso([string]$texto) {
    Write-Host "    AVISO: $texto" -ForegroundColor Yellow
}

function Falha([string]$texto) {
    Write-Host "    ERRO: $texto" -ForegroundColor Red
    exit 1
}

# Pasta para os arquivos JSON temporarios (fica fora do git)
$PastaTmp = Join-Path $PSScriptRoot ".tmp"
New-Item -ItemType Directory -Force $PastaTmp | Out-Null

# Salva um objeto como JSON e devolve o caminho no formato que o AWS CLI entende (file://...)
function SalvarJson([string]$nome, $objeto) {
    $caminho = Join-Path $PastaTmp $nome
    ($objeto | ConvertTo-Json -Depth 10 -Compress) | Set-Content -Encoding ascii $caminho
    return "file://$caminho"
}

function ObterConta {
    $conta = aws sts get-caller-identity --query Account --output text
    if ($LASTEXITCODE -ne 0 -or -not $conta) { Falha "AWS CLI sem acesso. Rode 'aws sts get-caller-identity' para conferir." }
    return $conta.Trim()
}

function ObterRepoGitHub {
    $repo = gh repo view --json nameWithOwner -q .nameWithOwner
    if ($LASTEXITCODE -ne 0 -or -not $repo) { Falha "Nao achei o repositorio no GitHub. Rode o script dentro da pasta do repositorio e confira 'gh auth status'." }
    return $repo.Trim()
}
