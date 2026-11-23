<#
 Testar-Envio.ps1 - envia um payload de exemplo ao fluxo do Teams para conferir a configuracao.
 Troca o token pelo do config.json e o nome do computador por TESTE-<nome>.
 Nunca mostra a URL nem o token.
 ATENCAO: cada execucao cria uma tarefa REAL no Planner (o exemplo tem um alerta 'novo' com destino 'tarefa').
 Apague a tarefa "[TESTE-<nome>] ..." depois de conferir.
#>
param(
    [string]$Config  = (Join-Path $PSScriptRoot 'config.json'),
    [string]$Payload = (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'docs') (Join-Path 'monitoramento' 'exemplo-payload.json'))
)

$ErrorActionPreference = 'Stop'

function Log($msg, $cor) {
    if ($cor) { Write-Host $msg -ForegroundColor $cor } else { Write-Host $msg }
}

. (Join-Path $PSScriptRoot 'Monitoramento.ps1')

# Restringe o config.json a Administradores e SYSTEM (avisa se o icacls falhar)
if (Test-Path -LiteralPath $Config) { Proteger-Config $Config }

$cfg = Ler-Config $Config
if (-not $cfg) {
    Write-Host "Config invalida ou ausente: veja o log." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $Payload)) {
    Write-Host "Payload de exemplo nao encontrado." -ForegroundColor Red
    exit 1
}

$obj = Get-Content -LiteralPath $Payload -Raw -Encoding UTF8 | ConvertFrom-Json
$obj.token = $cfg.token
$obj.computador.nome = "TESTE-$env:COMPUTERNAME"
$json = $obj | ConvertTo-Json -Depth 10

if (Enviar-Payload $cfg.urlFluxo $json) {
    Write-Host "Enviado (HTTP 2xx). Confira se o card chegou no canal - o fluxo sempre responde 202, mesmo se rejeitar." -ForegroundColor Green
    Write-Host "Atencao: este teste cria uma tarefa real no Planner. Apague-a depois de conferir." -ForegroundColor Yellow
} else {
    Write-Host "Falha no envio: veja o log." -ForegroundColor Red
    exit 1
}
