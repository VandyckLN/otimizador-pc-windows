# Monitoramento.ps1 - funcoes de monitoramento diario (envio ao Teams via Power Automate).
# Este arquivo so define funcoes e variaveis; nada e executado ao carregar (dot-source).
# Compativel com PowerShell 5.1.

# Codigo-base -> gravidade -> destino (tarefa | card | nenhum)
$Script:MapaDestino = @{
    'disco-smart'  = @{ erro = 'tarefa' }
    'disco-erros'  = @{ erro = 'tarefa' }
    'bsod'         = @{ erro = 'tarefa' }
    'whea'         = @{ erro = 'tarefa'; aviso = 'nenhum' }
    'antivirus'    = @{ erro = 'tarefa'; aviso = 'tarefa' }
    'firewall'     = @{ erro = 'tarefa' }
    'disco-espaco' = @{ erro = 'tarefa'; aviso = 'tarefa' }
}

# Dias sem evento novo para considerar um alerta baseado em evento como resolvido
$Script:DiasParaResolver = 7

function Get-Destino {
    param([string]$Codigo, [string]$Gravidade)
    $base = ($Codigo -split ':', 2)[0]
    if ($Script:MapaDestino.ContainsKey($base) -and $Script:MapaDestino[$base].ContainsKey($Gravidade)) {
        return [string]$Script:MapaDestino[$base][$Gravidade]
    }
    if ($Gravidade -eq 'erro') { return 'card' }
    return 'nenhum'
}

function Get-PesoDestino {
    param([string]$Destino)
    switch ($Destino) {
        'tarefa' { return 2 }
        'card'   { return 1 }
        default  { return 0 }
    }
}

function Comparar-Alertas {
    param([object[]]$Atuais, [hashtable]$Estado, [datetime]$Agora)

    $saida = New-Object System.Collections.ArrayList
    $novoEstado = @{}
    if ($null -eq $Estado) { $Estado = @{} }

    # Copia profunda do estado de entrada (nunca altera o original)
    foreach ($chave in $Estado.Keys) {
        $e = $Estado[$chave]
        $novoEstado[$chave] = @{
            Destino      = $e.Destino
            Gravidade    = $e.Gravidade
            Categoria    = $e.Categoria
            Problema     = $e.Problema
            PrimeiraVez  = $e.PrimeiraVez
            UltimoEvento = $e.UltimoEvento
            Resolvido    = [bool]$e.Resolvido
        }
    }

    $codigosAtuais = @{}
    foreach ($a in @($Atuais)) {
        if ($null -eq $a) { continue }
        $cod = [string]$a.Codigo
        $codigosAtuais[$cod] = $true
        $situacao = $null

        if (-not $novoEstado.ContainsKey($cod)) {
            $situacao = 'novo'
            $novoEstado[$cod] = @{
                Destino = $a.Destino; Gravidade = $a.Gravidade; Categoria = $a.Categoria
                Problema = $a.Problema; PrimeiraVez = $Agora; UltimoEvento = $a.UltimoEvento
                Resolvido = $false
            }
        }
        else {
            $e = $novoEstado[$cod]
            $subiu = (Get-PesoDestino $a.Destino) -gt (Get-PesoDestino $e.Destino)
            $temEvento = ($null -ne $a.UltimoEvento)
            $eventoNovo = $temEvento -and (($null -eq $e.UltimoEvento) -or ($a.UltimoEvento -gt $e.UltimoEvento))

            if ($temEvento -and $e.Resolvido) {
                if ($eventoNovo) {
                    $situacao = 'novo'
                    $e.Resolvido = $false
                    $e.PrimeiraVez = $Agora
                    $e.UltimoEvento = $a.UltimoEvento
                    if ($subiu) { $e.Destino = $a.Destino }
                    $e.Gravidade = $a.Gravidade; $e.Categoria = $a.Categoria; $e.Problema = $a.Problema
                }
                # senão: resolvido e sem evento novo -> não emite, mantém
            }
            elseif ($e.Resolvido) {
                # alerta sem evento que voltou depois de resolvido: tratado como novo
                $situacao = 'novo'
                $e.Resolvido = $false
                $e.PrimeiraVez = $Agora
                if ($subiu) { $e.Destino = $a.Destino }
            }
            elseif ($subiu) {
                $situacao = 'novo'
                $e.Destino = $a.Destino
                $e.Gravidade = $a.Gravidade
                if ($eventoNovo) { $e.UltimoEvento = $a.UltimoEvento }
            }
            elseif ($eventoNovo) {
                $situacao = 'nova-ocorrencia'
                $e.UltimoEvento = $a.UltimoEvento
            }
            elseif ($temEvento) {
                $ref = $e.PrimeiraVez
                if ($null -ne $e.UltimoEvento -and $e.UltimoEvento -gt $ref) { $ref = $e.UltimoEvento }
                if (($Agora - $ref).TotalDays -ge $Script:DiasParaResolver) {
                    $situacao = 'resolvido'
                    $e.Resolvido = $true
                }
                else { $situacao = 'persiste' }
            }
            else { $situacao = 'persiste' }
        }

        if ($null -ne $situacao) {
            $o = $a.PSObject.Copy()
            Add-Member -InputObject $o -NotePropertyName Situacao -NotePropertyValue $situacao -Force
            [void]$saida.Add($o)
        }
    }

    # Codigos no estado que sumiram dos atuais
    foreach ($cod in @($novoEstado.Keys)) {
        if ($codigosAtuais.ContainsKey($cod)) { continue }
        $e = $novoEstado[$cod]
        if (-not $e.Resolvido) {
            [void]$saida.Add([pscustomobject]@{
                Codigo = $cod; Categoria = $e.Categoria; Problema = $e.Problema
                Evidencia = ''; Solucao = ''; Gravidade = $e.Gravidade; Destino = $e.Destino
                UltimoEvento = $e.UltimoEvento; Situacao = 'resolvido'
            })
        }
        $novoEstado.Remove($cod)
    }

    return @{ Alertas = $saida.ToArray(); Estado = $novoEstado }
}
