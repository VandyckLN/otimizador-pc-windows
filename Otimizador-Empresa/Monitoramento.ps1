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

# Texto estavel (titulo da tarefa e solucao) dos alertas gerados a partir de itens
$Script:TextoAlertaItem = @{
    'antivirus' = @{
        Problema = 'Antivírus desativado, desatualizado ou ausente'
        Solucao  = 'Verificar o antivírus: ativar a proteção em tempo real e atualizar as definições. Se não houver antivírus, ativar o Microsoft Defender'
    }
    'firewall'  = @{
        Problema = 'Firewall do Windows desligado'
        Solucao  = 'Reativar o firewall em Segurança do Windows > Firewall e proteção de rede (todos os perfis)'
    }
}

# Dias de carencia antes de considerar um alerta resolvido:
#  - alerta baseado em evento: dias sem evento novo;
#  - alerta sem evento: dias seguidos ausente (evita reabrir problemas que vao e voltam).
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
            AusenteDesde = $e.AusenteDesde
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
                Resolvido = $false; AusenteDesde = $null
            }
        }
        else {
            $e = $novoEstado[$cod]
            # Voltou dentro da carencia: continua o mesmo problema (persiste, ou novo se o destino subiu)
            $e.AusenteDesde = $null
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
        $emitirResolvido = $false
        if ($null -ne $e.UltimoEvento -or $e.Resolvido) {
            # Baseado em evento (ou ja resolvido): regra de evento, resolve na hora
            $emitirResolvido = (-not $e.Resolvido)
        }
        else {
            # Sem evento: so resolve depois de DiasParaResolver dias seguidos ausente
            if ($null -eq $e.AusenteDesde) { $e.AusenteDesde = $Agora }
            if (($Agora - [datetime]$e.AusenteDesde).TotalDays -lt $Script:DiasParaResolver) { continue }
            $emitirResolvido = $true
        }
        if ($emitirResolvido) {
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

    # Agrupa achados e itens por Codigo (um alerta por Codigo)
    $grupos = [ordered]@{}
    foreach ($a in @($Achados)) {
        if ($null -eq $a -or [string]::IsNullOrWhiteSpace([string]$a.Codigo)) { continue }
        $cod = [string]$a.Codigo
        if (-not $grupos.Contains($cod)) { $grupos[$cod] = @{ Achados = (New-Object System.Collections.ArrayList); Itens = (New-Object System.Collections.ArrayList) } }
        [void]$grupos[$cod].Achados.Add($a)
    }
    foreach ($i in @($Itens)) {
        if ($null -eq $i -or [string]::IsNullOrWhiteSpace([string]$i.Codigo)) { continue }
        if ([string]$i.Status -eq 'ok') { continue }
        $cod = [string]$i.Codigo
        if (-not $grupos.Contains($cod)) { $grupos[$cod] = @{ Achados = (New-Object System.Collections.ArrayList); Itens = (New-Object System.Collections.ArrayList) } }
        [void]$grupos[$cod].Itens.Add($i)
    }

    $saida = New-Object System.Collections.ArrayList
    foreach ($cod in $grupos.Keys) {
        $g = $grupos[$cod]
        $achGrp = @($g.Achados)
        $itGrp = @($g.Itens)

        # Pior gravidade de todo o grupo
        $grav = ''
        $pesoMax = -1
        foreach ($x in $achGrp) { $pv = Get-PesoGravidade ([string]$x.Gravidade); if ($pv -gt $pesoMax) { $pesoMax = $pv; $grav = [string]$x.Gravidade } }
        foreach ($x in $itGrp) { $pv = Get-PesoGravidade ([string]$x.Status); if ($pv -gt $pesoMax) { $pesoMax = $pv; $grav = [string]$x.Status } }

        # Evidencia: achados primeiro, depois "Nome: Valor" dos itens
        $partes = @()
        foreach ($x in $achGrp) { if (-not [string]::IsNullOrWhiteSpace([string]$x.Evidencia)) { $partes += [string]$x.Evidencia } }
        foreach ($x in $itGrp) { $partes += ("{0}: {1}" -f $x.Nome, $x.Valor) }

        # Ultimo evento: o mais recente nao nulo
        $ultimo = $null
        foreach ($x in $achGrp) { if ($null -ne $x.UltimoEvento -and ($null -eq $ultimo -or $x.UltimoEvento -gt $ultimo)) { $ultimo = $x.UltimoEvento } }

        if ($achGrp.Count -gt 0) {
            $pior = $achGrp[0]
            foreach ($x in $achGrp) { if ((Get-PesoGravidade ([string]$x.Gravidade)) -gt (Get-PesoGravidade ([string]$pior.Gravidade))) { $pior = $x } }
            $categoria = [string]$pior.Categoria; $problema = [string]$pior.Problema; $solucao = [string]$pior.Solucao
        }
        else {
            $base = ($cod -split ':', 2)[0]
            $categoria = [string]$itGrp[0].Secao
            if ($Script:TextoAlertaItem.ContainsKey($base)) {
                $problema = [string]$Script:TextoAlertaItem[$base].Problema
                $solucao = [string]$Script:TextoAlertaItem[$base].Solucao
            }
            else { $problema = [string]$itGrp[0].Nome; $solucao = '' }
        }

        [void]$saida.Add([pscustomobject]@{
            Codigo       = $cod
            Categoria    = $categoria
            Problema     = $problema
            Evidencia    = ($partes -join '; ')
            Solucao      = $solucao
            Gravidade    = $grav
            Destino      = (Get-Destino $cod $grav)
            UltimoEvento = $ultimo
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
        $codigo = $LASTEXITCODE
        if ($null -ne $codigo -and $codigo -ne 0) {
            Registrar-Monitoramento ("Monitoramento: icacls falhou (codigo {0}) - as permissoes do config.json podem nao estar restritas" -f $codigo) 'Yellow'
        }
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
                AusenteDesde = (ConvertTo-DataHora $e.AusenteDesde)
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
            AusenteDesde = $(if ($null -ne $e.AusenteDesde) { ([datetime]$e.AusenteDesde).ToString('o') } else { $null })
        }
    }
    $pasta = Split-Path -Parent $Caminho
    if ($pasta -and -not (Test-Path -LiteralPath $pasta)) {
        New-Item -ItemType Directory -Path $pasta -Force | Out-Null
    }
    $json = $saida | ConvertTo-Json -Depth 5
    if ($saida.Count -eq 0) { $json = '{}' }

    # Gravacao atomica: escreve num .tmp e so entao troca pelo arquivo final
    $tmp = $Caminho + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    if ([IO.File]::Exists($Caminho)) {
        # [NullString]::Value (PS 3+): $null viraria '' ao passar para o parametro string do .NET
        [IO.File]::Replace($tmp, $Caminho, [NullString]::Value)
    }
    else {
        [IO.File]::Move($tmp, $Caminho)
    }
}

# Remove URLs (e, se informado, o token) de uma mensagem antes de ir para o log
function Ocultar-Segredos {
    param([string]$Mensagem, [string]$Token)
    $msg = [string]$Mensagem
    try {
        $msg = [regex]::Replace($msg, 'https?://\S+', '[url]')
        if (-not [string]::IsNullOrEmpty($Token)) { $msg = $msg.Replace($Token, '[token]') }
    } catch { $msg = 'detalhe omitido' }
    return $msg
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

    $config = $null
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
            try {
                Salvar-Estado $cmp.Estado $caminhoEstado
                Registrar-Monitoramento 'Monitoramento: enviado ao Teams' 'Green'
            }
            catch {
                Registrar-Monitoramento 'Monitoramento: enviado, mas o estado não foi gravado — a próxima execução pode repetir alertas' 'Yellow'
            }
        }
        else {
            Registrar-Monitoramento 'Monitoramento: envio nao concluido - sera tentado de novo na proxima execucao' 'Yellow'
        }
    }
    catch {
        $tok = $null
        if ($null -ne $config) { $tok = [string]$config.token }
        $detalhe = Ocultar-Segredos ([string]$_.Exception.Message) $tok
        Registrar-Monitoramento ("Monitoramento: erro inesperado - nada enviado ({0})" -f $detalhe) 'Yellow'
    }
}
