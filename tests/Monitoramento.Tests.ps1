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
