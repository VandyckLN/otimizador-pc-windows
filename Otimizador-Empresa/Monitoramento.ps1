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

# ---------------------------------------------------------------------------
# Coleta, payload, config, estado e envio
# ---------------------------------------------------------------------------

# Escreve no log do script principal, se a funcao Log existir (nunca define Log aqui)
function Registrar-Monitoramento {
    param([string]$Mensagem, [string]$Cor = 'Gray')
    if (Get-Command Log -ErrorAction SilentlyContinue) {
        try { Log $Mensagem $Cor } catch { }
    }
}

function Get-PesoGravidade {
    param([string]$Gravidade)
    switch ($Gravidade) {
        'erro'  { return 2 }
        'aviso' { return 1 }
        default { return 0 }
    }
}

function Formatar-DataIso {
    param($Data)
    if ($null -eq $Data -or "$Data" -eq '') { return $null }
    return ([datetime]$Data).ToString('yyyy-MM-ddTHH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture)
}

function Coletar-Alertas {
    param([object[]]$Achados, [object[]]$Itens)

    $saida = New-Object System.Collections.ArrayList

    foreach ($a in @($Achados)) {
        if ($null -eq $a -or [string]::IsNullOrWhiteSpace([string]$a.Codigo)) { continue }
        $grav = [string]$a.Gravidade
        [void]$saida.Add([pscustomobject]@{
            Codigo       = [string]$a.Codigo
            Categoria    = [string]$a.Categoria
            Problema     = [string]$a.Problema
            Evidencia    = [string]$a.Evidencia
            Solucao      = [string]$a.Solucao
            Gravidade    = $grav
            Destino      = (Get-Destino ([string]$a.Codigo) $grav)
            UltimoEvento = $a.UltimoEvento
        })
    }

    # Itens com problema: um alerta por Codigo
    $grupos = [ordered]@{}
    foreach ($i in @($Itens)) {
        if ($null -eq $i -or [string]::IsNullOrWhiteSpace([string]$i.Codigo)) { continue }
        if ([string]$i.Status -eq 'ok') { continue }
        $cod = [string]$i.Codigo
        if (-not $grupos.Contains($cod)) { $grupos[$cod] = New-Object System.Collections.ArrayList }
        [void]$grupos[$cod].Add($i)
    }
    foreach ($cod in $grupos.Keys) {
        $lista = @($grupos[$cod])
        $pior = $lista[0]
        foreach ($i in $lista) {
            if ((Get-PesoGravidade ([string]$i.Status)) -gt (Get-PesoGravidade ([string]$pior.Status))) { $pior = $i }
        }
        $evid = ($lista | ForEach-Object { "{0}: {1}" -f $_.Nome, $_.Valor }) -join '; '
        $grav = [string]$pior.Status
        [void]$saida.Add([pscustomobject]@{
            Codigo       = $cod
            Categoria    = [string]$pior.Secao
            Problema     = [string]$pior.Nome
            Evidencia    = $evid
            Solucao      = [string]$pior.Solucao
            Gravidade    = $grav
            Destino      = (Get-Destino $cod $grav)
            UltimoEvento = $null
        })
    }

    return $saida.ToArray()
}

function Novo-Payload {
    param([hashtable]$Computador, [object[]]$Alertas, [object[]]$Itens, [string]$Token,
          [string]$VersaoScript, [datetime]$Agora)

    $listaAlertas = New-Object System.Collections.ArrayList
    foreach ($a in @($Alertas)) {
        if ($null -eq $a) { continue }
        [void]$listaAlertas.Add([ordered]@{
            codigo       = [string]$a.Codigo
            categoria    = [string]$a.Categoria
            problema     = [string]$a.Problema
            evidencia    = [string]$a.Evidencia
            solucao      = [string]$a.Solucao
            gravidade    = [string]$a.Gravidade
            destino      = [string]$a.Destino
            situacao     = [string]$a.Situacao
            ultimoEvento = (Formatar-DataIso $a.UltimoEvento)
        })
    }

    $listaItens = New-Object System.Collections.ArrayList
    foreach ($i in @($Itens)) {
        if ($null -eq $i) { continue }
        [void]$listaItens.Add([ordered]@{
            secao  = [string]$i.Secao
            nome   = [string]$i.Nome
            valor  = [string]$i.Valor
            status = [string]$i.Status
        })
    }

    if ($null -eq $Computador) { $Computador = @{} }
    $payload = [ordered]@{
        versaoEsquema = 1
        versaoScript  = $VersaoScript
        enviadoEm     = (Formatar-DataIso $Agora)
        token         = $Token
        computador    = [ordered]@{
            nome       = [string]$Computador['nome']
            usuario    = [string]$Computador['usuario']
            fabricante = [string]$Computador['fabricante']
            modelo     = [string]$Computador['modelo']
            numeroSerie = [string]$Computador['numeroSerie']
            windows    = [string]$Computador['windows']
            ultimoBoot = (Formatar-DataIso $Computador['ultimoBoot'])
        }
        alertas       = $listaAlertas.ToArray()
        itens         = $listaItens.ToArray()
    }
    return ($payload | ConvertTo-Json -Depth 6)
}

function Ler-Config {
    param([string]$Caminho)

    if (-not (Test-Path -LiteralPath $Caminho)) {
        Registrar-Monitoramento 'Monitoramento: config.json nao encontrado' 'Yellow'
        return $null
    }
    $obj = $null
    try {
        $texto = (Get-Content -LiteralPath $Caminho -Raw -Encoding UTF8)
        if ($null -ne $texto) { $texto = $texto.TrimStart([char]0xFEFF) }
        if ([string]::IsNullOrWhiteSpace($texto)) {
            Registrar-Monitoramento 'Monitoramento: config.json esta vazio' 'Yellow'
            return $null
        }
        $obj = $texto | ConvertFrom-Json
    }
    catch {
        Registrar-Monitoramento 'Monitoramento: config.json invalido (JSON malformado)' 'Yellow'
        return $null
    }
    if ($null -eq $obj) {
        Registrar-Monitoramento 'Monitoramento: config.json invalido' 'Yellow'
        return $null
    }
    $url = [string]$obj.urlFluxo
    $token = [string]$obj.token
    if ([string]::IsNullOrWhiteSpace($url) -or [string]::IsNullOrWhiteSpace($token)) {
        Registrar-Monitoramento 'Monitoramento: config.json sem urlFluxo ou token' 'Yellow'
        return $null
    }
    if (-not $url.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        Registrar-Monitoramento 'Monitoramento: urlFluxo precisa comecar com https://' 'Yellow'
        return $null
    }
    return @{ urlFluxo = $url; token = $token }
}

function Proteger-Config {
    param([string]$Caminho)
    try {
        # SIDs (Administradores e SYSTEM) porque os nomes mudam conforme o idioma do Windows
        & icacls $Caminho /inheritance:r /grant:r "*S-1-5-32-544:F" "*S-1-5-18:F" 2>&1 | Out-Null
    }
    catch {
        Registrar-Monitoramento 'Monitoramento: nao foi possivel restringir as permissoes do config.json' 'Yellow'
    }
}

function ConvertTo-DataHora {
    param($Valor)
    if ($null -eq $Valor -or "$Valor" -eq '') { return $null }
    if ($Valor -is [datetime]) { return $Valor }
    return [datetime]::Parse([string]$Valor, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
}

function Ler-Estado {
    param([string]$Caminho)

    $estado = @{}
    if (-not (Test-Path -LiteralPath $Caminho)) { return $estado }
    try {
        $texto = (Get-Content -LiteralPath $Caminho -Raw -Encoding UTF8)
        if ($null -ne $texto) { $texto = $texto.TrimStart([char]0xFEFF) }
        if ([string]::IsNullOrWhiteSpace($texto)) { return $estado }
        $obj = $texto | ConvertFrom-Json
        if ($null -eq $obj) { return $estado }
        foreach ($p in $obj.PSObject.Properties) {
            $e = $p.Value
            $estado[$p.Name] = @{
                Destino      = [string]$e.Destino
                Gravidade    = [string]$e.Gravidade
                Categoria    = [string]$e.Categoria
                Problema     = [string]$e.Problema
                PrimeiraVez  = (ConvertTo-DataHora $e.PrimeiraVez)
                UltimoEvento = (ConvertTo-DataHora $e.UltimoEvento)
                Resolvido    = [bool]$e.Resolvido
            }
        }
        return $estado
    }
    catch {
        Registrar-Monitoramento 'Monitoramento: estado anterior ilegivel, recomecando do zero' 'Yellow'
        return @{}
    }
}

function Salvar-Estado {
    param([hashtable]$Estado, [string]$Caminho)

    $saida = [ordered]@{}
    foreach ($chave in $Estado.Keys) {
        $e = $Estado[$chave]
        $saida[$chave] = [ordered]@{
            Destino      = $e.Destino
            Gravidade    = $e.Gravidade
            Categoria    = $e.Categoria
            Problema     = $e.Problema
            PrimeiraVez  = $(if ($null -ne $e.PrimeiraVez) { ([datetime]$e.PrimeiraVez).ToString('o') } else { $null })
            UltimoEvento = $(if ($null -ne $e.UltimoEvento) { ([datetime]$e.UltimoEvento).ToString('o') } else { $null })
            Resolvido    = [bool]$e.Resolvido
        }
    }
    $pasta = Split-Path -Parent $Caminho
    if ($pasta -and -not (Test-Path -LiteralPath $pasta)) {
        New-Item -ItemType Directory -Path $pasta -Force | Out-Null
    }
    $json = $saida | ConvertTo-Json -Depth 5
    if ($saida.Count -eq 0) { $json = '{}' }
    [IO.File]::WriteAllText($Caminho, $json, (New-Object Text.UTF8Encoding($false)))
}

function Enviar-Payload {
    param([string]$Url, [string]$Json)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
        $r = Invoke-WebRequest -UseBasicParsing -Uri $Url -Method Post -ContentType 'application/json; charset=utf-8' `
                -Body $bytes -TimeoutSec 15 -ErrorAction Stop
        $codigo = [int]$r.StatusCode
        if ($codigo -ge 200 -and $codigo -lt 300) { return $true }
        Registrar-Monitoramento ("Monitoramento: envio recusado (HTTP {0})" -f $codigo) 'Yellow'
        return $false
    }
    catch {
        $msg = [string]$_.Exception.Message
        try {
            if ($Url) { $msg = $msg.Replace($Url, '[url]') }
            $msg = [regex]::Replace($msg, 'https?://\S+', '[url]')
        } catch { $msg = 'erro de rede' }
        Registrar-Monitoramento ("Monitoramento: falha no envio - {0}" -f $msg) 'Yellow'
        return $false
    }
}

function Invoke-Monitoramento {
    param([object[]]$Achados, [object[]]$Itens, [hashtable]$Computador, [string]$PastaBase, [string]$VersaoScript)

    try {
        $caminhoConfig = Join-Path $PastaBase 'config.json'
        if (-not (Test-Path -LiteralPath $caminhoConfig)) {
            Registrar-Monitoramento 'Monitoramento não configurado (config.json ausente) - nada enviado' 'Yellow'
            return
        }
        Proteger-Config $caminhoConfig
        $config = Ler-Config $caminhoConfig
        if ($null -eq $config) {
            Registrar-Monitoramento 'Monitoramento: configuracao invalida - nada enviado' 'Yellow'
            return
        }

        $agora = Get-Date
        $caminhoEstado = Join-Path (Join-Path $PastaBase 'estado') 'alertas.json'
        $estado = Ler-Estado $caminhoEstado
        $atuais = @(Coletar-Alertas -Achados $Achados -Itens $Itens)
        $cmp = Comparar-Alertas -Atuais $atuais -Estado $estado -Agora $agora
        $alertas = @($cmp.Alertas)

        $contagem = @{}
        foreach ($a in $alertas) { $contagem[[string]$a.Situacao] = 1 + [int]$contagem[[string]$a.Situacao] }
        $resumo = foreach ($s in 'novo', 'persiste', 'nova-ocorrencia', 'resolvido') { "{0}={1}" -f $s, [int]$contagem[$s] }
        Registrar-Monitoramento ("Monitoramento: alertas - " + ($resumo -join ', ')) 'Cyan'

        $json = Novo-Payload -Computador $Computador -Alertas $alertas -Itens $Itens -Token $config.token -VersaoScript $VersaoScript -Agora $agora
        if (Enviar-Payload -Url $config.urlFluxo -Json $json) {
            Salvar-Estado $cmp.Estado $caminhoEstado
            Registrar-Monitoramento 'Monitoramento: enviado ao Teams' 'Green'
        }
        else {
            Registrar-Monitoramento 'Monitoramento: envio nao concluido - sera tentado de novo na proxima execucao' 'Yellow'
        }
    }
    catch {
        Registrar-Monitoramento 'Monitoramento: erro inesperado - nada enviado' 'Yellow'
    }
}
