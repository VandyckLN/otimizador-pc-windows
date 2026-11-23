# Fluxo do Teams/Planner (Power Automate)

Passo a passo para montar o fluxo que recebe o aviso diário de cada PC, posta um card no canal de suporte e cria tarefas no Planner. Não precisa ter montado um fluxo antes.

> Use o app **Workflows** do Teams. Os "Conectores do Office 365 / Incoming Webhook" estão sendo descontinuados e não devem ser usados.

## O que o fluxo recebe

Cada PC envia um JSON (versão 1 do contrato) com os dados do computador e a lista de alertas. Veja um exemplo completo em [`exemplo-payload.json`](exemplo-payload.json). O card de exemplo está em [`card-teams.json`](card-teams.json).

## 1. Verificar a licença

1. No Teams, abra o app **Workflows**.
2. Procure o modelo/gatilho **"When a Teams webhook request is received"** (Quando uma solicitação de webhook do Teams for recebida).
3. Se ele não aparecer, a licença do Microsoft 365 da conta não inclui esse gatilho. Fale com o administrador do tenant antes de continuar.

## 2. Criar o fluxo e copiar a URL

1. No app Workflows, crie um fluxo novo a partir do gatilho acima. Em **Quem pode disparar o fluxo**, escolha "Qualquer pessoa" (as máquinas não têm login).
2. Salve o fluxo. O gatilho passa a mostrar a **URL HTTP POST**. Copie essa URL.
3. Em cada PC, copie `config.exemplo.json` para `config.json` (na pasta `Otimizador-Empresa`) e cole a URL em `urlFluxo`.
4. Crie uma variável no fluxo (ação **Initialize variable**, tipo texto) com o nome `tokenEsperado` e o valor do token. Gere o token com `[guid]::NewGuid()` no PowerShell e use o mesmo valor em `token` no `config.json`.

A URL e o token são segredos: não coloque em chamado, e-mail ou card.

## 3. Parse JSON

1. Adicione a ação **Parse JSON** com o conteúdo do corpo do gatilho.
2. Não gere o esquema do exemplo. Abra [`esquema-parse-json.json`](esquema-parse-json.json), copie tudo e cole no campo **Esquema**. Ele já aceita `ultimoEvento` como texto ou vazio (`null`).
3. Não use "Gerar do exemplo" com `exemplo-payload.json`: o primeiro alerta tem `ultimoEvento` vazio, o gerador assume que o campo nunca é texto e o Parse JSON falha nos alertas de tela azul.
4. Deixe a ação com o nome `Parse_JSON` (o padrão): os cards usam esse nome.

## 4. Validar token e versão

1. Adicione uma **Condição** com duas regras (E):
   - `token` é igual a `tokenEsperado`
   - `versaoEsquema` é igual a `1`
2. Se for **falso**: use **Post card in a chat or channel**, cole no campo **Adaptive Card** o conteúdo de [`card-rejeitado.json`](card-rejeitado.json) (mostra só o nome do computador) e depois encerre o fluxo (**Terminate**). **Nunca** coloque o token no card.
3. Se for **verdadeiro**: continue no passo 5.

## 5. Tratar cada alerta

Adicione **Apply to each** sobre `alertas` e, dentro dele, três condições:

- **Postar o card:** `situacao` é `novo` ou `nova-ocorrencia` **e** `destino` é diferente de `nenhum`. Ação: **Post card in a chat or channel**, colando no campo **Adaptive Card** (dentro do Apply to each) o conteúdo de [`card-teams.json`](card-teams.json). O cartão usa expressões do Power Automate (`@{...}`), não o modelo `${...}` do Adaptive Cards, e elas assumem os nomes de ação `Apply_to_each` e `Parse_JSON`. Se você renomeou alguma ação, troque o nome nas expressões (por exemplo `items('Apply_to_each')` e `body('Parse_JSON')`).
- **Criar tarefa:** `situacao` é `novo` **e** `destino` é `tarefa`. Ação: **Create a task** (Planner), com título `[<computador.nome>] <problema>` e a evidência e a solução na descrição.
- **Resolvido:** `situacao` é `resolvido` **e** `destino` é diferente de `nenhum`. Ação: postar o card de "resolvido" (mesmo card, cabeçalho verde).

Alertas `persiste` não geram nada: o PC os envia todos os dias para o fluxo saber que continuam abertos.

## 6. Testar (leia isto)

> **Atenção:** o gatilho responde **202** antes de validar qualquer coisa. Por isso o PC sempre vê sucesso, mesmo se o token estiver errado. O teste só é confirmado **vendo o card chegar no canal**.

1. No PC, rode `Otimizador-Empresa\Testar-Envio.ps1`. Ele usa o nome `TESTE-<nome do PC>`.
2. Confira o canal. Se aparecer o card "payload rejeitado", o token do fluxo e o do `config.json` não coincidem. Se não aparecer nada, veja o histórico de execuções do fluxo.

## 7. Trocar o token (rotação)

1. Gere um valor novo: `[guid]::NewGuid()`.
2. Atualize a variável `tokenEsperado` no fluxo.
3. Atualize o `token` no `config.json` de cada máquina.

Enquanto nem todas as máquinas estiverem atualizadas, vão aparecer cards "payload rejeitado" daquelas que ficaram para trás. Isso é o esperado.
