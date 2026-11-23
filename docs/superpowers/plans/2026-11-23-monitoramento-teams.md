# Monitoramento diário com alertas no Teams/Planner — Plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cada estação roda o diagnóstico todo dia e envia um resumo JSON para um fluxo do Teams/Power Automate. O fluxo posta um card no canal e cria tarefa no Planner para os problemas críticos, sem duplicar.

**Architecture:** A lógica nova fica em `Otimizador-Empresa/Monitoramento.ps1`, que é carregado pelo script principal com dot-source. Esse arquivo tem funções puras (classificação, comparação com o estado, montagem do payload) e funções de I/O isoladas (config, estado, envio), e é testável com Pester sem Windows. O `OtimizadorEmpresa.ps1` ganha o modo `-Monitorar`, códigos estáveis nos achados e itens e a chamada de `Invoke-Monitoramento`. O fluxo do Power Automate não é código do repositório: entra como documentação, modelo de card e script de teste.

**Tech Stack:** Windows PowerShell 5.1 (produção); Pester 5 para os testes (rodam em PS 5.1 ou pwsh 7); Power Automate (app Workflows do Teams) com Adaptive Card.

**Spec:** `docs/superpowers/specs/2026-11-23-monitoramento-teams-design.md`

## Global Constraints

- PowerShell 5.1 puro, sem módulos nem executáveis de terceiros em produção (Pester só nos testes). Nada de sintaxe exclusiva do PS 7: sem `? :`, `??`, `ConvertFrom-Json -AsHashtable`, `-Parallel`.
- Funções e mensagens em português, no estilo do script atual.
- HTTPS com TLS 1.2: `[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12`.
- Timeout de envio: 15 s. Uma falha no envio nunca interrompe o restante do script.
- URL do fluxo e token **nunca** aparecem em log, console, relatório ou card.
- `config.json` e `estado\` ficam fora do git.
- Sem `config.json`, o script se comporta exatamente como hoje, mais uma linha de aviso no log.
- Versão do esquema do payload: `1`. Versão do script: `1.2` (o menu mostra `v1.2`).
- Destinos: `tarefa`, `card`, `nenhum`. Situações: `novo`, `persiste`, `nova-ocorrencia`, `resolvido`.
- Alerta baseado em evento é considerado resolvido após **7 dias** sem evento novo.
- Limite de tarefa para espaço em disco: abaixo de **10%** livres no disco do sistema.

**Desvio consciente da spec (simplificação, mesmo comportamento):** a spec previa um `fila\pendente.json`. Como o estado só avança depois de um 2xx e cada execução monta o payload a partir do último estado confirmado, a execução seguinte já gera o envio atualizado. O arquivo de fila seria redundante, então **não há arquivo de fila**. Uma semana offline continua resultando em um único envio, sem perder nenhum `novo`.

## Contrato JSON v1 (fixo — Tasks 2 e 4 dependem dele)

```json
{
  "versaoEsquema": 1,
  "versaoScript": "1.2",
  "enviadoEm": "2026-11-23T10:00:00-03:00",
  "token": "<token do config.json>",
  "computador": {
    "nome": "PC-FINANCEIRO-03", "usuario": "PC-FINANCEIRO-03\\maria",
    "fabricante": "Dell Inc.", "modelo": "OptiPlex 3080", "numeroSerie": "ABC123",
    "windows": "Microsoft Windows 11 Pro (build 22631)", "ultimoBoot": "2026-11-22T08:01:00-03:00"
  },
  "alertas": [
    { "codigo": "bsod", "categoria": "Travamentos", "problema": "Telas azuis (o Windows travou e reiniciou)",
      "evidencia": "2 nos últimos 30 dias. ...", "solucao": "Atualizar drivers ...", "gravidade": "erro",
      "destino": "tarefa", "situacao": "novo", "ultimoEvento": "2026-11-21T14:10:00-03:00" }
  ],
  "itens": [ { "secao": "Hardware", "nome": "Memória RAM", "valor": "...", "status": "ok" } ]
}
```

- `ultimoEvento` é `null` quando o alerta não é baseado em evento.
- `alertas` traz **todos** os alertas, inclusive `persiste` e `destino: nenhum`. Quem filtra é o fluxo. Os itens com `resolvido` trazem os dados guardados no estado.
- Datas em ISO 8601 com offset: `(Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')`.

## Review Focus

1. **`config.json` ausente, vazio ou com JSON inválido:** não envia, registra um aviso no log, gera o relatório normalmente e o script termina com código 0. *(teste na Task 2)*
2. **Máquina offline por vários dias:** nenhum `novo` se perde. Quando o envio volta a funcionar, o problema chega como `novo`, e não como `persiste`. *(teste na Task 2)*
3. **Primeira execução encontra uma tela azul de 20 dias atrás:** sai como `novo`, depois `persiste`, e só fica `resolvido` 7 dias após a primeira vez que foi visto. Não alterna entre aberto e resolvido dia sim, dia não. *(teste na Task 1)*
4. **Acentos em pt-BR** (`Câmera`, `Áudio`, `não`) chegam corretos ao Teams: o corpo é enviado como bytes UTF-8, e não como string em codificação ANSI. *(teste na Task 2)*
5. **Firewall desligado em 2 perfis ou 2 antivírus com problema:** gera um único alerta por tipo, com a evidência listando todos. *(teste na Task 2)*

---

### Task 1: Classificação e comparação com o estado (funções puras)

**Files:**
- Create: `Otimizador-Empresa/Monitoramento.ps1`
- Test: `tests/Monitoramento.Tests.ps1`

**Interfaces:**
- Produces:
  - `$Script:MapaDestino` — hashtable código-base → hashtable gravidade→destino:
    - `disco-smart` @{erro='tarefa'}
    - `disco-erros` @{erro='tarefa'}
    - `bsod` @{erro='tarefa'}
    - `whea` @{erro='tarefa'; aviso='nenhum'}
    - `antivirus` @{erro='tarefa'; aviso='tarefa'}
    - `firewall` @{erro='tarefa'}
    - `disco-espaco` @{erro='tarefa'; aviso='tarefa'}
  - `Get-Destino([string]$Codigo, [string]$Gravidade) -> string` — usa o código-base (parte antes de `:`). Se não houver regra no mapa, aplica o padrão `erro`→`card`, `aviso`/`info`→`nenhum`.
  - `Comparar-Alertas([object[]]$Atuais, [hashtable]$Estado, [datetime]$Agora) -> @{ Alertas = object[]; Estado = hashtable }`. Cada atual é um pscustomobject com `Codigo, Categoria, Problema, Evidencia, Solucao, Gravidade, Destino, UltimoEvento ([datetime] ou $null)`. A saída `Alertas` são os mesmos objetos mais `Situacao`. A saída `Estado` é **um novo** hashtable (não altera o de entrada), com chave = código e valor = `@{ Destino; Gravidade; Categoria; Problema; PrimeiraVez; UltimoEvento; Resolvido }`.

Regras de `Comparar-Alertas`, com ordem de destino `nenhum` < `card` < `tarefa`. O estado guarda o **maior** destino já visto:

| Caso | Situação emitida | Estado |
|---|---|---|
| atual sem estado | `novo` | cria (PrimeiraVez=Agora) |
| atual com estado, destino subiu | `novo` | atualiza o destino |
| evento, estado resolvido, `UltimoEvento` mais novo | `novo` | Resolvido=$false, PrimeiraVez=Agora |
| evento, estado resolvido, sem evento novo | *(não emite)* | mantém |
| evento, não resolvido, `UltimoEvento` mais novo | `nova-ocorrencia` | atualiza UltimoEvento |
| evento, não resolvido, `Agora - max(UltimoEvento, PrimeiraVez) >= 7d` | `resolvido` | Resolvido=$true |
| demais casos com estado | `persiste` | mantém |
| código no estado, ausente nos atuais, não resolvido | `resolvido` (objeto montado a partir do estado) | remove |
| código no estado, ausente nos atuais, resolvido | *(não emite)* | remove |

- [ ] **Step 1: Escrever os testes que falham**, com `BeforeAll { . "$PSScriptRoot/../Otimizador-Empresa/Monitoramento.ps1" }` e um helper `Novo-Alerta` nos testes:
  - `Get-Destino 'disco-smart:WD123' 'erro'` → `tarefa`; `'whea','aviso'` → `nenhum`; `'impressora-spooler','erro'` → `card`; `'ram-esgotada','aviso'` → `nenhum`; `'antivirus','aviso'` → `tarefa`
  - estado vazio + 1 alerta → `Situacao -eq 'novo'` e o estado tem a chave
  - mesma entrada rodada 2x, encadeando o estado → a 2ª dá `persiste`
  - `whea` aviso/`nenhum` no estado → agora erro/`tarefa` → `novo` e o estado fica com `Destino -eq 'tarefa'`
  - destino que desce (tarefa → nenhum) → `persiste` e o estado continua `tarefa`
  - código no estado e ausente nos atuais → `resolvido`, chave removida, com `Problema` vindo do estado
  - **Review Focus 3:** `bsod` com UltimoEvento = Agora-20d e estado vazio → `novo`; Agora+1d → `persiste`; Agora+7d → `resolvido`; Agora+8d (mesmo evento) → nenhum alerta `bsod` emitido; evento novo em Agora+9d → `novo`
  - `bsod` não resolvido + UltimoEvento mais novo → `nova-ocorrencia`
  - o estado de entrada não é alterado (comparar com uma cópia em JSON)

- [ ] **Step 2: Rodar e ver falhar**
  Run: `pwsh -NoProfile -c "Invoke-Pester ./tests -Output Detailed"` (no Windows: `powershell -NoProfile -c "Invoke-Pester .\tests -Output Detailed"`)
  Expected: FAIL, `Get-Destino` não reconhecido

- [ ] **Step 3: Implementar `$Script:MapaDestino`, `Get-Destino` e `Comparar-Alertas` em `Monitoramento.ps1`**
  O arquivo não pode executar nada quando é carregado com dot-source: só define funções e variáveis.

- [ ] **Step 4: Rodar e ver passar** — mesmo comando. Expected: todos PASS.

- [ ] **Step 5: Commit** — `git add Otimizador-Empresa/Monitoramento.ps1 tests/Monitoramento.Tests.ps1 && git commit -m "Monitoramento: classificação de alertas e comparação com estado"`

---

### Task 2: Coleta de alertas, payload, config, estado e envio

**Files:**
- Modify: `Otimizador-Empresa/Monitoramento.ps1`
- Create: `Otimizador-Empresa/config.exemplo.json` (`{"urlFluxo": "https://...", "token": "troque-por-um-valor-aleatorio"}`)
- Modify: `.gitignore` (adicionar `Otimizador-Empresa/config.json` e `Otimizador-Empresa/estado/`)
- Test: `tests/Monitoramento.Tests.ps1`

**Interfaces:**
- Consumes: `Get-Destino`, `Comparar-Alertas` (Task 1). Usa `Log($msg, $cor)` se existir; nos testes, definir um stub `function Log { param($m,$c) $Script:LogCapturado += "$m`n" }`.
- Produces:
  - `Coletar-Alertas([object[]]$Achados, [object[]]$Itens) -> object[]` — pega os achados com `Codigo` e os itens com `Codigo` e `Status -ne 'ok'`, e converte para o formato de alerta da Task 1 (calculando `Destino` com `Get-Destino`). Itens com o mesmo `Codigo` viram um único alerta: a evidência junta os `Nome: Valor` com `; ` e a gravidade é a pior delas. Ignora achados e itens sem `Codigo`.
  - `Novo-Payload([hashtable]$Computador, [object[]]$Alertas, [object[]]$Itens, [string]$Token, [string]$VersaoScript, [datetime]$Agora) -> string` — JSON no contrato v1, gerado com `ConvertTo-Json -Depth 6`. `alertas` e `itens` são sempre arrays, mesmo com 0 ou 1 elemento.
  - `Ler-Config([string]$Caminho) -> hashtable|$null` — retorna `$null` se o arquivo não existir, se o JSON for inválido, se faltar `urlFluxo`/`token` ou se `urlFluxo` não começar com `https://`. Registra no log o motivo, sem mostrar valores.
  - `Proteger-Config([string]$Caminho)` — `icacls $Caminho /inheritance:r /grant:r "*S-1-5-32-544:F" "*S-1-5-18:F"`. Usa SIDs, e não nomes, porque o Windows em pt-BR chama o grupo de "Administradores".
  - `Ler-Estado([string]$Caminho) -> hashtable` / `Salvar-Estado([hashtable]$Estado, [string]$Caminho)` — JSON em UTF-8. Um arquivo ausente ou corrompido vira `@{}`. As datas fazem ida e volta como `[datetime]`. Em PS 5.1, converter `PSCustomObject` para hashtable manualmente.
  - `Enviar-Payload([string]$Url, [string]$Json) -> bool` — `Invoke-WebRequest -UseBasicParsing -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($Json)) -TimeoutSec 15`, com TLS 1.2. Retorna `$true` só com status 2xx. Exceção vira `$false` e uma linha de log com a mensagem do erro, **sem** a URL.
  - `Invoke-Monitoramento([object[]]$Achados, [object[]]$Itens, [hashtable]$Computador, [string]$PastaBase, [string]$VersaoScript) -> void` — orquestra: lê `config.json` (se faltar, registra "Monitoramento não configurado (config.json ausente) - nada enviado" e retorna), chama `Proteger-Config`, `Ler-Estado` em `estado\alertas.json`, `Coletar-Alertas`, `Comparar-Alertas` e `Novo-Payload`, e envia com `Enviar-Payload`. Só chama `Salvar-Estado` se o envio retornar `$true`. Registra no log a quantidade de alertas por situação.

- [ ] **Step 1: Escrever os testes que falham:**
  - `Coletar-Alertas`: 2 itens `firewall` (Domain e Public, ambos erro) + 1 item ok → 1 alerta, com a evidência contendo "Domain" e "Public" *(Review Focus 5)*; um item `antivirus` aviso + um erro → 1 alerta `erro`/`tarefa`; achado sem `Codigo` → ignorado
  - `Novo-Payload` com 1 alerta → `($json | ConvertFrom-Json).alertas` é array com Count 1; `versaoEsquema -eq 1`; `ultimoEvento` é `$null` para alerta que não é de evento
  - `Ler-Config`: arquivo inexistente → `$null`; `{lixo` → `$null`; `urlFluxo` `http://` → `$null`; válido → hashtable. Em nenhum caso o log capturado contém o token *(Review Focus 1)*
  - `Ler-Estado`/`Salvar-Estado`: ida e volta preserva `PrimeiraVez` como `[datetime]`; arquivo corrompido → `@{}`
  - `Enviar-Payload` com `Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 202 } }` → `$true`; com um mock que lança exceção → `$false` e o log não contém a URL; verificar via `Should -Invoke Invoke-WebRequest -ParameterFilter { $Body -is [byte[]] }` e que os bytes decodificados em UTF-8 contêm `Câmera` *(Review Focus 4)*
  - `Invoke-Monitoramento` com `Mock Enviar-Payload { $false }` em duas execuções seguidas → `estado\alertas.json` não existe e a 2ª execução ainda gera `novo`. Depois, com `Mock Enviar-Payload { $true }`, o estado é gravado *(Review Focus 2)*. Usar `$TestDrive` como `PastaBase`, mock de `Proteger-Config` e um `config.json` válido gravado no `$TestDrive`
  - `Invoke-Monitoramento` sem `config.json` → não lança exceção e `Enviar-Payload` não é chamado

- [ ] **Step 2: Rodar e ver falhar** — `pwsh -NoProfile -c "Invoke-Pester ./tests -Output Detailed"`. Expected: FAIL nas funções novas.

- [ ] **Step 3: Implementar as funções acima, criar `config.exemplo.json` e atualizar o `.gitignore`.**

- [ ] **Step 4: Rodar e ver passar** — mesmo comando. Expected: todos PASS (incluindo a Task 1).

- [ ] **Step 5: Commit** — `git commit -m "Monitoramento: payload, config protegido, estado e envio ao fluxo"`

---

### Task 3: Integração no script principal

**Files:**
- Modify: `Otimizador-Empresa/OtimizadorEmpresa.ps1` (param `:13-16`, autoelevação `:19-26`, `Item` `:148`, `Diagnostico` `:154-283`, `Achado` `:337`, `Analisar-Problemas` `:367-675`, bloco automático `:1027-1032`, cabeçalho do menu `:1041`)

**Interfaces:**
- Consumes: `Invoke-Monitoramento` (Task 2).
- Produces: o modo `-Monitorar`; o parâmetro opcional nomeado `-Codigo` em `Item` e em `Achado`; `-UltimoEvento` em `Achado`; `$Script:VersaoScript = '1.2'`.

- [ ] **Step 1: Parâmetros e carga**
  - adicionar `[switch]$Monitorar` ao `param`
  - repassar `-Monitorar` na autoelevação
  - depois de definir `$Base`: `. (Join-Path $Base 'Monitoramento.ps1')`
  - `if ($Monitorar) { $Automatico = $true }` logo após o `param`, para reaproveitar todo o comportamento sem perguntas (Pergunta/Pausa/Log)
  - `$Script:VersaoScript = '1.2'`, e o menu passa a mostrar `v$Script:VersaoScript`

- [ ] **Step 2: Assinaturas**
  - `Item($secao, $nome, $valor, $status = 'ok', $Codigo = $null)` grava `Codigo` no objeto
  - `Achado(..., $descCorrecao = $null, $Codigo = $null, $UltimoEvento = $null)` grava `Codigo` e `UltimoEvento`
  - todas as chamadas novas usam parâmetros **nomeados** (`-Codigo 'x'`), para não quebrar as chamadas posicionais existentes

- [ ] **Step 3: Códigos.** Adicionar `-Codigo` a todos os 32 `Achado` de `Analisar-Problemas`, em kebab-case derivado do problema, por exemplo:
  - fixos pela spec: `sem-reiniciar`, `reinicio-pendente`, `ram-esgotada`, `disco-espaco`, `disco-erros`, `disco-smart:<FriendlyName>`, `bsod`, `desligamento-inesperado`, `whea`, `programas-travando`, `camera-desativada:<Name>`, `audio-servico:<svc>`, `rede-sem-ip:<InterfaceAlias>`, `impressora-spooler`, `impressora-fila`, `impressora:<Name>`
  - os demais ficam a critério de quem implementa, desde que sejam estáveis entre execuções (sem números, percentuais ou datas no código)
  - `-UltimoEvento ($lista | Measure-Object TimeCreated -Maximum).Maximum` em `bsod`, `desligamento-inesperado`, `whea` e `disco-erros`
  - nos itens do `Diagnostico`: `-Codigo 'antivirus'` nos 2 `Item` de antivírus e `-Codigo 'firewall'` no `Item` de firewall

- [ ] **Step 4: Identificação e chamada.** Criar `Get-IdentificacaoPC -> hashtable` no script principal com as chaves do contrato (`nome, usuario, fabricante, modelo, numeroSerie, windows, ultimoBoot`), via CIM `Win32_ComputerSystem`, `Win32_BIOS` e `Win32_OperatingSystem`.
  O bloco automático passa a ser:
  - `-Monitorar`: `Diagnostico` (que já chama `Analisar-Problemas` e gera o HTML) e depois `Invoke-Monitoramento -Achados $Script:Achados -Itens $Script:Relatorio -Computador (Get-IdentificacaoPC) -PastaBase $Base -VersaoScript $Script:VersaoScript`
  - `-Automatico` sem `-Monitorar`: `ManutencaoCompleta` e depois o mesmo `Invoke-Monitoramento`
  - o `Invoke-Monitoramento` fica dentro de `try { } catch { Log "Falha no monitoramento: $($_.Exception.Message)" 'Red' }`

- [ ] **Step 5: Verificação estática** — sem Windows aqui, checar a sintaxe e o comportamento ao carregar:
  Run: `pwsh -NoProfile -c "\$e=\$null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ./Otimizador-Empresa/OtimizadorEmpresa.ps1), [ref]\$null, [ref]\$e) | Out-Null; \$e.Count"`
  Expected: `0`
  Run: `grep -c "Achado '" Otimizador-Empresa/OtimizadorEmpresa.ps1` e `grep -c "\-Codigo '" Otimizador-Empresa/OtimizadorEmpresa.ps1`
  Expected: o segundo número ≥ 32 + 3 (todos os achados e itens de segurança têm código)
  Run: `pwsh -NoProfile -c "Invoke-Pester ./tests"` — Expected: tudo PASS

- [ ] **Step 6: Teste manual em Windows (obrigatório antes do merge; anotar o resultado no PR)**
  - sem `config.json`: `powershell -ExecutionPolicy Bypass -File .\OtimizadorEmpresa.ps1 -Monitorar` gera o HTML, e o log mostra "Monitoramento não configurado"
  - com `config.json` apontando para o fluxo de teste: o card chega no canal, e `estado\alertas.json` é criado com ACL restrita (`icacls config.json` mostra só Administradores e SYSTEM)
  - menu interativo: as opções 1 e 2 continuam funcionando como antes

- [ ] **Step 7: Commit** — `git commit -m "Modo -Monitorar com códigos estáveis e envio ao fluxo do Teams"`

---

### Task 4: Documentação do fluxo, card e Testar-Envio

Pode rodar **em paralelo** com as Tasks 1–3: depende só do contrato JSON v1 acima.

**Files:**
- Create: `docs/monitoramento/exemplo-payload.json` — contrato v1 com 4 alertas, um por situação (`novo` com destino `tarefa`, `persiste`, `nova-ocorrencia` de `bsod`, `resolvido`), com acentos
- Create: `docs/monitoramento/card-teams.json` — Adaptive Card 1.4 com `${computador.nome}`, `${computador.usuario}`, `${problema}`, `${evidencia}`, `${solucao}`; cabeçalho com cor por situação (`novo` → attention, `nova-ocorrencia` → warning, `resolvido` → good)
- Create: `docs/monitoramento/fluxo-power-automate.md`
- Create: `Otimizador-Empresa/Testar-Envio.ps1`
- Modify: `README.md`

**Interfaces:**
- Consumes: o contrato JSON v1 e `Ler-Config` / `Enviar-Payload` de `Monitoramento.ps1` (Task 2) no `Testar-Envio.ps1`.

- [ ] **Step 1: `fluxo-power-automate.md`**, um passo a passo para quem nunca montou um fluxo:
  1. verificar a licença: o gatilho "When a Teams webhook request is received" precisa estar disponível
  2. criar o fluxo pelo app Workflows do Teams e copiar a URL para o `config.json`
  3. *Parse JSON* com um esquema gerado a partir de `exemplo-payload.json`
  4. condição `token` igual ao valor guardado numa variável do fluxo e `versaoEsquema` igual a 1; se falhar, postar o card "payload rejeitado" com `computador.nome` (**nunca** o token) e encerrar
  5. *Apply to each* em `alertas`:
     - `situacao` em (`novo`, `nova-ocorrencia`) e `destino` diferente de `nenhum` → postar o card
     - `situacao = novo` e `destino = tarefa` → criar tarefa no Planner com o título `[<computador.nome>] <problema>` e a evidência e a solução na descrição
     - `situacao = resolvido` e `destino` diferente de `nenhum` → postar o card "resolvido"
  6. aviso explícito: o gatilho responde 202 antes de validar, então o teste só é confirmado vendo o card no canal
  7. rotação do token: gerar um valor novo com `[guid]::NewGuid()`, atualizar a variável do fluxo e depois o `config.json` de cada máquina. Enquanto não terminar, aparecem cards "payload rejeitado", e isso é o esperado

- [ ] **Step 2: `Testar-Envio.ps1`** — `param([string]$Config = "$PSScriptRoot\config.json", [string]$Payload = "$PSScriptRoot\..\docs\monitoramento\exemplo-payload.json")`. Faz dot-source de `Monitoramento.ps1`, troca o `token` do exemplo pelo do config e o `computador.nome` por `TESTE-$env:COMPUTERNAME`, e envia com `Enviar-Payload`. Imprime "Enviado (HTTP 2xx). Confira se o card chegou no canal - o fluxo sempre responde 202, mesmo se rejeitar." ou "Falha no envio: veja o log". Define um `Log` simples antes do dot-source.
  Verificação: `pwsh -NoProfile -c "[System.Management.Automation.Language.Parser]::ParseFile('Otimizador-Empresa/Testar-Envio.ps1',[ref]\$null,[ref]\$e)|Out-Null; \$e.Count"` → `0`; `Get-Content docs/monitoramento/*.json | ConvertFrom-Json` sem erro.

- [ ] **Step 3: README** — nova seção "Monitoramento (Teams/Planner)" com:
  - o que é enviado e o que não é
  - como configurar (`config.exemplo.json` → `config.json`)
  - um link para o guia do fluxo
  - as duas tarefas agendadas:

    ```bat
    schtasks /Create /TN "Monitoramento Otimizador" /SC DAILY /ST 10:00 /RU SYSTEM /RL HIGHEST /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\TI\Otimizador-Empresa\OtimizadorEmpresa.ps1 -Monitorar"
    ```

    mais a tarefa semanal existente
  - remover o "Alertas por e-mail/Teams" da lista "Próximos passos"

- [ ] **Step 4: Commit** — `git commit -m "Docs do fluxo Teams/Planner, card e script de teste de envio"`
