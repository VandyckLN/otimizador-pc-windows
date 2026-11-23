BeforeAll {
    . "$PSScriptRoot/../Otimizador-Empresa/Monitoramento.ps1"

    function Novo-Alerta {
        param([string]$Codigo = 'x', [string]$Gravidade = 'erro', [string]$Destino = 'card',
              $UltimoEvento = $null, [string]$Problema = 'Problema X')
        [pscustomobject]@{
            Codigo = $Codigo; Categoria = 'Cat'; Problema = $Problema; Evidencia = 'ev'; Solucao = 'sol'
            Gravidade = $Gravidade; Destino = $Destino; UltimoEvento = $UltimoEvento
        }
    }
    $Script:Agora = [datetime]'2026-11-23T10:00:00'
}

Describe 'Get-Destino' {
    It 'disco-smart erro -> tarefa (usa codigo-base)' { Get-Destino 'disco-smart:WD123' 'erro' | Should -Be 'tarefa' }
    It 'whea aviso -> nenhum'                          { Get-Destino 'whea' 'aviso' | Should -Be 'nenhum' }
    It 'sem regra erro -> card'                        { Get-Destino 'impressora-spooler' 'erro' | Should -Be 'card' }
    It 'sem regra aviso -> nenhum'                     { Get-Destino 'ram-esgotada' 'aviso' | Should -Be 'nenhum' }
    It 'sem regra info -> nenhum'                      { Get-Destino 'qualquer' 'info' | Should -Be 'nenhum' }
    It 'antivirus aviso -> tarefa'                     { Get-Destino 'antivirus' 'aviso' | Should -Be 'tarefa' }
    It 'regra existente sem a gravidade cai no padrao' { Get-Destino 'bsod' 'aviso' | Should -Be 'nenhum' }
}

Describe 'Comparar-Alertas' {
    It 'estado vazio + alerta -> novo e cria a chave' {
        $r = Comparar-Alertas -Atuais @(Novo-Alerta -Codigo 'a') -Estado @{} -Agora $Agora
        $r.Alertas[0].Situacao | Should -Be 'novo'
        $r.Estado.ContainsKey('a') | Should -BeTrue
        $r.Estado['a'].PrimeiraVez | Should -Be $Agora
        $r.Estado['a'].Resolvido | Should -BeFalse
    }

    It 'segunda execucao encadeada -> persiste' {
        $a = Novo-Alerta -Codigo 'a'
        $r1 = Comparar-Alertas -Atuais @($a) -Estado @{} -Agora $Agora
        $r2 = Comparar-Alertas -Atuais @($a) -Estado $r1.Estado -Agora $Agora.AddDays(1)
        $r2.Alertas[0].Situacao | Should -Be 'persiste'
    }

    It 'destino que sobe -> novo e atualiza o destino' {
        $r1 = Comparar-Alertas -Atuais @(Novo-Alerta -Codigo 'whea' -Gravidade 'aviso' -Destino 'nenhum') -Estado @{} -Agora $Agora
        $r2 = Comparar-Alertas -Atuais @(Novo-Alerta -Codigo 'whea' -Gravidade 'erro' -Destino 'tarefa') -Estado $r1.Estado -Agora $Agora.AddDays(1)
        $r2.Alertas[0].Situacao | Should -Be 'novo'
        $r2.Estado['whea'].Destino | Should -Be 'tarefa'
    }

    It 'destino que desce -> persiste e o estado guarda o maior' {
        $r1 = Comparar-Alertas -Atuais @(Novo-Alerta -Codigo 'w' -Destino 'tarefa') -Estado @{} -Agora $Agora
        $r2 = Comparar-Alertas -Atuais @(Novo-Alerta -Codigo 'w' -Destino 'nenhum') -Estado $r1.Estado -Agora $Agora.AddDays(1)
        $r2.Alertas[0].Situacao | Should -Be 'persiste'
        $r2.Estado['w'].Destino | Should -Be 'tarefa'
    }

    It 'codigo no estado e ausente nos atuais -> resolvido, remove a chave, dados do estado' {
        $r1 = Comparar-Alertas -Atuais @(Novo-Alerta -Codigo 'a' -Problema 'Meu problema') -Estado @{} -Agora $Agora
        $r2 = Comparar-Alertas -Atuais @() -Estado $r1.Estado -Agora $Agora.AddDays(1)
        $r2.Alertas.Count | Should -Be 1
        $r2.Alertas[0].Situacao | Should -Be 'resolvido'
        $r2.Alertas[0].Problema | Should -Be 'Meu problema'
        $r2.Alertas[0].Codigo | Should -Be 'a'
        $r2.Alertas[0].Evidencia | Should -Be ''
        $r2.Alertas[0].Solucao | Should -Be ''
        $r2.Estado.ContainsKey('a') | Should -BeFalse
    }

    It 'ausente e ja resolvido -> nao emite e remove' {
        $est = @{ 'b' = @{ Destino = 'tarefa'; Gravidade = 'erro'; Categoria = 'C'; Problema = 'P'
                           PrimeiraVez = $Agora.AddDays(-30); UltimoEvento = $Agora.AddDays(-20); Resolvido = $true } }
        $r = Comparar-Alertas -Atuais @() -Estado $est -Agora $Agora
        $r.Alertas.Count | Should -Be 0
        $r.Estado.ContainsKey('b') | Should -BeFalse
    }

    Context 'alerta baseado em evento (bsod)' {
        BeforeAll {
            $Script:Ev = $Script:Agora.AddDays(-20)
            $Script:Bsod = Novo-Alerta -Codigo 'bsod' -Destino 'tarefa' -UltimoEvento $Script:Ev
        }
        It 'ciclo completo: novo, persiste, resolvido, silencio, novo' {
            $r = Comparar-Alertas -Atuais @($Bsod) -Estado @{} -Agora $Agora
            $r.Alertas[0].Situacao | Should -Be 'novo'
            $est = $r.Estado

            $r = Comparar-Alertas -Atuais @($Bsod) -Estado $est -Agora $Agora.AddDays(1)
            $r.Alertas[0].Situacao | Should -Be 'persiste'
            $est = $r.Estado

            $r = Comparar-Alertas -Atuais @($Bsod) -Estado $est -Agora $Agora.AddDays(7)
            $r.Alertas[0].Situacao | Should -Be 'resolvido'
            $r.Estado['bsod'].Resolvido | Should -BeTrue
            $est = $r.Estado

            $r = Comparar-Alertas -Atuais @($Bsod) -Estado $est -Agora $Agora.AddDays(8)
            @($r.Alertas | Where-Object Codigo -eq 'bsod').Count | Should -Be 0
            $r.Estado['bsod'].Resolvido | Should -BeTrue
            $est = $r.Estado

            $novo = Novo-Alerta -Codigo 'bsod' -Destino 'tarefa' -UltimoEvento $Agora.AddDays(9)
            $r = Comparar-Alertas -Atuais @($novo) -Estado $est -Agora $Agora.AddDays(9)
            $r.Alertas[0].Situacao | Should -Be 'novo'
            $r.Estado['bsod'].Resolvido | Should -BeFalse
            $r.Estado['bsod'].PrimeiraVez | Should -Be $Agora.AddDays(9)
        }
        It 'nao resolvido + evento mais novo -> nova-ocorrencia' {
            $r1 = Comparar-Alertas -Atuais @($Bsod) -Estado @{} -Agora $Agora
            $novo = Novo-Alerta -Codigo 'bsod' -Destino 'tarefa' -UltimoEvento $Agora.AddDays(-1)
            $r2 = Comparar-Alertas -Atuais @($novo) -Estado $r1.Estado -Agora $Agora.AddDays(1)
            $r2.Alertas[0].Situacao | Should -Be 'nova-ocorrencia'
            $r2.Estado['bsod'].UltimoEvento | Should -Be $Agora.AddDays(-1)
        }
    }

    It 'nao altera o estado de entrada' {
        $est = @{ 'a' = @{ Destino = 'card'; Gravidade = 'erro'; Categoria = 'C'; Problema = 'P'
                           PrimeiraVez = $Agora.AddDays(-2); UltimoEvento = $null; Resolvido = $false } }
        $antes = $est | ConvertTo-Json -Depth 5
        $null = Comparar-Alertas -Atuais @(Novo-Alerta -Codigo 'a' -Destino 'tarefa') -Estado $est -Agora $Agora
        $null = Comparar-Alertas -Atuais @() -Estado $est -Agora $Agora
        ($est | ConvertTo-Json -Depth 5) | Should -Be $antes
    }
}

Describe 'Coletar-Alertas' {
    It 'itens com o mesmo codigo viram um unico alerta com evidencia agregada' {
        $itens = @(
            [pscustomobject]@{ Codigo = 'firewall'; Secao = 'Seguranca'; Nome = 'Firewall Domain'; Valor = 'Desligado'; Status = 'erro' },
            [pscustomobject]@{ Codigo = 'firewall'; Secao = 'Seguranca'; Nome = 'Firewall Public'; Valor = 'Desligado'; Status = 'erro' },
            [pscustomobject]@{ Codigo = 'outro'; Secao = 'Seguranca'; Nome = 'Tudo bem'; Valor = 'ok'; Status = 'ok' }
        )
        $r = @(Coletar-Alertas -Achados @() -Itens $itens)
        $r.Count | Should -Be 1
        $r[0].Codigo | Should -Be 'firewall'
        $r[0].Evidencia | Should -Match 'Domain'
        $r[0].Evidencia | Should -Match 'Public'
        $r[0].Destino | Should -Be 'tarefa'
    }
    It 'antivirus aviso + erro -> um alerta erro/tarefa' {
        $itens = @(
            [pscustomobject]@{ Codigo = 'antivirus'; Secao = 'Seguranca'; Nome = 'AV1'; Valor = 'Desatualizado'; Status = 'aviso' },
            [pscustomobject]@{ Codigo = 'antivirus'; Secao = 'Seguranca'; Nome = 'AV2'; Valor = 'Desligado'; Status = 'erro' }
        )
        $r = @(Coletar-Alertas -Achados @() -Itens $itens)
        $r.Count | Should -Be 1
        $r[0].Gravidade | Should -Be 'erro'
        $r[0].Destino | Should -Be 'tarefa'
    }
    It 'achados sem Codigo sao ignorados; com Codigo viram alerta' {
        $achados = @(
            [pscustomobject]@{ Categoria = 'C'; Problema = 'Sem codigo'; Evidencia = 'e'; Solucao = 's'; Gravidade = 'erro' },
            [pscustomobject]@{ Codigo = 'bsod'; Categoria = 'Travamentos'; Problema = 'Tela azul'; Evidencia = 'e'; Solucao = 's'; Gravidade = 'erro'; UltimoEvento = [datetime]'2026-11-21T14:10:00' }
        )
        $r = @(Coletar-Alertas -Achados $achados -Itens @())
        $r.Count | Should -Be 1
        $r[0].Codigo | Should -Be 'bsod'
        $r[0].Destino | Should -Be 'tarefa'
        $r[0].UltimoEvento | Should -Be ([datetime]'2026-11-21T14:10:00')
    }
    It 'itens sem Codigo sao ignorados' {
        $r = @(Coletar-Alertas -Achados @() -Itens @([pscustomobject]@{ Secao = 'S'; Nome = 'N'; Valor = 'V'; Status = 'erro' }))
        $r.Count | Should -Be 0
    }
}

Describe 'Novo-Payload' {
    BeforeAll {
        $Script:Comp = @{ nome = 'PC1'; usuario = 'PC1\maria'; fabricante = 'Dell'; modelo = 'X'; numeroSerie = 'S1'; windows = 'Win 11'; ultimoBoot = [datetime]'2026-11-22T08:01:00' }
    }
    It 'gera o contrato v1 com arrays e ultimoEvento nulo' {
        $al = [pscustomobject]@{ Codigo = 'firewall'; Categoria = 'Seguranca'; Problema = 'Firewall'; Evidencia = 'ev'; Solucao = 'sol'
                                 Gravidade = 'erro'; Destino = 'tarefa'; UltimoEvento = $null; Situacao = 'novo' }
        $json = Novo-Payload -Computador $Comp -Alertas @($al) -Itens @() -Token 'tok' -VersaoScript '1.2' -Agora $Agora
        $o = $json | ConvertFrom-Json
        $o.versaoEsquema | Should -Be 1
        $o.versaoScript | Should -Be '1.2'
        $o.token | Should -Be 'tok'
        @($o.alertas).Count | Should -Be 1
        $json | Should -Match '"alertas":\s*\['
        $json | Should -Match '"itens":\s*\['
        $o.alertas[0].ultimoEvento | Should -BeNullOrEmpty
        $json | Should -Match '"ultimoEvento":\s*null'
        $o.alertas[0].situacao | Should -Be 'novo'
        $o.computador.nome | Should -Be 'PC1'
        $json | Should -Not -Match '/Date\('
    }
    It 'formata datas como ISO com offset e aceita alerta resolvido sem evidencia' {
        $al = [pscustomobject]@{ Codigo = 'bsod'; Categoria = 'T'; Problema = 'P'; Evidencia = ''; Solucao = ''
                                 Gravidade = 'erro'; Destino = 'tarefa'; UltimoEvento = [datetime]'2026-11-21T14:10:00'; Situacao = 'resolvido' }
        $it = [pscustomobject]@{ Secao = 'Hardware'; Nome = 'Câmera'; Valor = 'ok'; Status = 'ok' }
        $json = Novo-Payload -Computador $Comp -Alertas @($al) -Itens @($it) -Token 't' -VersaoScript '1.2' -Agora $Agora
        $o = $json | ConvertFrom-Json
        $o.alertas[0].evidencia | Should -Be ''
        $json | Should -Match '"ultimoEvento":\s*"2026-11-21T14:10:00[+-]\d\d:\d\d"'
        $json | Should -Match '"enviadoEm":\s*"2026-11-23T10:00:00[+-]\d\d:\d\d"'
        @($o.itens).Count | Should -Be 1
        $o.itens[0].nome | Should -Be 'Câmera'
    }
}

Describe 'Ler-Config' {
    BeforeEach {
        $Script:LogCapturado = ''
        function Log { param($m, $c) $Script:LogCapturado += "$m`n" }
    }
    It 'arquivo inexistente -> null' {
        Ler-Config (Join-Path $TestDrive 'nao-existe.json') | Should -BeNullOrEmpty
    }
    It 'JSON invalido -> null sem vazar conteudo' {
        $p = Join-Path $TestDrive 'c1.json'; Set-Content $p '{lixo-SEGREDO' -Encoding UTF8
        Ler-Config $p | Should -BeNullOrEmpty
        $Script:LogCapturado | Should -Not -Match 'SEGREDO'
    }
    It 'urlFluxo http -> null e o log nao contem o token' {
        $p = Join-Path $TestDrive 'c2.json'
        Set-Content $p '{"urlFluxo":"http://x.com/a","token":"TOKEN-SECRETO"}' -Encoding UTF8
        Ler-Config $p | Should -BeNullOrEmpty
        $Script:LogCapturado | Should -Not -Match 'TOKEN-SECRETO'
        $Script:LogCapturado | Should -Not -Match 'x\.com'
    }
    It 'faltando token -> null' {
        $p = Join-Path $TestDrive 'c3.json'; Set-Content $p '{"urlFluxo":"https://x.com/a"}' -Encoding UTF8
        Ler-Config $p | Should -BeNullOrEmpty
    }
    It 'valido (com BOM) -> hashtable' {
        $p = Join-Path $TestDrive 'c4.json'
        [IO.File]::WriteAllText($p, '{"urlFluxo":"https://x.com/a","token":"TOKEN-SECRETO"}', (New-Object Text.UTF8Encoding($true)))
        $c = Ler-Config $p
        $c | Should -BeOfType [hashtable]
        $c.urlFluxo | Should -Be 'https://x.com/a'
        $c.token | Should -Be 'TOKEN-SECRETO'
        $Script:LogCapturado | Should -Not -Match 'TOKEN-SECRETO'
    }
}

Describe 'Ler-Estado / Salvar-Estado' {
    It 'ida e volta preserva datas como datetime' {
        $p = Join-Path $TestDrive 'est1.json'
        $est = @{ 'a' = @{ Destino = 'tarefa'; Gravidade = 'erro'; Categoria = 'C'; Problema = 'Câmera'
                           PrimeiraVez = [datetime]'2026-11-20T09:30:00'; UltimoEvento = $null; Resolvido = $false }
                  'b' = @{ Destino = 'card'; Gravidade = 'erro'; Categoria = 'C'; Problema = 'P'
                           PrimeiraVez = [datetime]'2026-11-01T09:30:00'; UltimoEvento = [datetime]'2026-11-02T10:00:00'; Resolvido = $true } }
        Salvar-Estado $est $p
        $r = Ler-Estado $p
        $r | Should -BeOfType [hashtable]
        $r['a'] | Should -BeOfType [hashtable]
        $r['a'].PrimeiraVez | Should -BeOfType [datetime]
        $r['a'].PrimeiraVez | Should -Be ([datetime]'2026-11-20T09:30:00')
        $r['a'].UltimoEvento | Should -BeNullOrEmpty
        $r['a'].Resolvido | Should -BeFalse
        $r['a'].Problema | Should -Be 'Câmera'
        $r['b'].UltimoEvento | Should -BeOfType [datetime]
        $r['b'].Resolvido | Should -BeTrue
    }
    It 'cria a pasta ao salvar' {
        $p = Join-Path (Join-Path $TestDrive 'sub') 'e.json'
        Salvar-Estado @{} $p
        Test-Path $p | Should -BeTrue
    }
    It 'arquivo corrompido ou ausente -> hashtable vazio' {
        $p = Join-Path $TestDrive 'est2.json'; Set-Content $p '{nao e json' -Encoding UTF8
        $r = Ler-Estado $p
        $r | Should -BeOfType [hashtable]
        $r.Count | Should -Be 0
        (Ler-Estado (Join-Path $TestDrive 'nada.json')).Count | Should -Be 0
    }
}

Describe 'Enviar-Payload' {
    BeforeEach {
        $Script:LogCapturado = ''
        function Log { param($m, $c) $Script:LogCapturado += "$m`n" }
    }
    It 'status 2xx -> true, corpo em bytes UTF-8' {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 202 } }
        Enviar-Payload 'https://exemplo.com/fluxo?sig=SEGREDO' '{"a":"Câmera"}' | Should -BeTrue
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Body -is [byte[]] -and [Text.Encoding]::UTF8.GetString($Body) -like '*Câmera*' -and $Method -eq 'Post'
        }
    }
    It 'status nao 2xx -> false' {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 500 } }
        Enviar-Payload 'https://exemplo.com/fluxo' '{}' | Should -BeFalse
    }
    It 'excecao -> false e o log nao contem a URL' {
        Mock Invoke-WebRequest { throw 'Falha ao chamar https://exemplo.com/fluxo?sig=SEGREDO timeout' }
        Enviar-Payload 'https://exemplo.com/fluxo?sig=SEGREDO' '{}' | Should -BeFalse
        $Script:LogCapturado | Should -Not -Match 'exemplo\.com'
        $Script:LogCapturado | Should -Not -Match 'SEGREDO'
        $Script:LogCapturado | Should -Match 'timeout'
    }
}

Describe 'Invoke-Monitoramento' {
    BeforeEach {
        $Script:LogCapturado = ''
        function Log { param($m, $c) $Script:LogCapturado += "$m`n" }
        $Script:Base = Join-Path $TestDrive ('base' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Script:Base | Out-Null
        $Script:Ach = @([pscustomobject]@{ Codigo = 'bsod'; Categoria = 'T'; Problema = 'Tela azul'; Evidencia = 'e'; Solucao = 's'
                                           Gravidade = 'erro'; UltimoEvento = (Get-Date).AddDays(-2) })
        $Script:Comp = @{ nome = 'PC1'; usuario = 'u'; fabricante = 'f'; modelo = 'm'; numeroSerie = 's'; windows = 'w'; ultimoBoot = (Get-Date) }
        Mock Proteger-Config { }
    }
    It 'sem config.json -> nao lanca, nao envia, loga aviso' {
        Mock Enviar-Payload { $true }
        { Invoke-Monitoramento $Ach @() $Comp $Base '1.2' } | Should -Not -Throw
        Should -Invoke Enviar-Payload -Times 0 -Exactly
        $Script:LogCapturado | Should -Match 'não configurado'
    }
    Context 'com config' {
        BeforeEach {
            Set-Content (Join-Path $Script:Base 'config.json') '{"urlFluxo":"https://x.com/a","token":"TOK"}' -Encoding UTF8
            $Script:Estado = Join-Path (Join-Path $Script:Base 'estado') 'alertas.json'
        }
        It 'envio falha -> nao grava estado e a 2a execucao ainda e novo' {
            Mock Enviar-Payload { $false }
            Invoke-Monitoramento $Ach @() $Comp $Base '1.2'
            Test-Path $Estado | Should -BeFalse
            Invoke-Monitoramento $Ach @() $Comp $Base '1.2'
            Test-Path $Estado | Should -BeFalse
            Should -Invoke Enviar-Payload -Times 2 -Exactly -ParameterFilter {
                ($Json | ConvertFrom-Json).alertas[0].situacao -eq 'novo'
            }
        }
        It 'envio ok -> grava estado e a proxima execucao vira persiste' {
            Mock Enviar-Payload { $true }
            Invoke-Monitoramento $Ach @() $Comp $Base '1.2'
            Test-Path $Estado | Should -BeTrue
            Invoke-Monitoramento $Ach @() $Comp $Base '1.2'
            Should -Invoke Enviar-Payload -Times 1 -Exactly -ParameterFilter {
                ($Json | ConvertFrom-Json).alertas[0].situacao -eq 'persiste'
            }
            $Script:LogCapturado | Should -Not -Match 'TOK'
            $Script:LogCapturado | Should -Not -Match 'x\.com'
        }
    }
}
