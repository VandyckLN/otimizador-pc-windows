# Fluxo do Teams/Planner (Power Automate)

Passo a passo para montar o fluxo que recebe o aviso diário de cada PC, posta um card no canal de suporte e cria tarefas no Planner. Não precisa ter montado um fluxo antes.

> Use o app **Workflows** do Teams. Os "Conectores do Office 365 / Incoming Webhook" estão sendo descontinuados e não devem ser usados.

## O que o fluxo recebe

Cada PC envia um JSON (versão 1 do contrato) com os dados do computador e a lista de alertas. Veja um exemplo completo em [`exemplo-payload.json`](exemplo-payload.json), gerado pela própria função `Novo-Payload` do script. Os cards estão em [`card-teams.json`](card-teams.json) e [`card-rejeitado.json`](card-rejeitado.json).

## Nomes das ações (importante)

As expressões deste guia e dos cards usam estes nomes internos de ação:

| Ação | Nome que a ação deve ter | Nome usado nas expressões |
|---|---|---|
| Parse JSON | `Parse JSON` | `Parse_JSON` |
| For each (sobre `alertas`) | `For each` | `For_each` |
| Compose do card do alerta | `Compose card` | `Compose_card` |
| Compose do card rejeitado | `Compose card rejeitado` | `Compose_card_rejeitado` |
| Create a task (Planner) | `Create a task` | `Create_a_task` |

O nome interno é o nome da ação com os espaços trocados por `_`. O designer novo chama o laço de **For each** (`For_each`); o designer antigo chamava de *Apply to each* (`Apply_to_each`), e o designer em português pode gerar outros nomes. **Renomeie as ações para os nomes da tabela** (menu `...` da ação > Renomear) ou, se preferir manter os nomes que o designer gerou, troque o nome em todas as expressões (`items('For_each')`, `body('Parse_JSON')`, `outputs('Compose_card')`...).

## 1. Verificar a licença

1. No Teams, abra o app **Workflows**.
2. Procure o modelo/gatilho **"When a Teams webhook request is received"** (Quando uma solicitação de webhook do Teams for recebida).
3. Se ele não aparecer, a licença do Microsoft 365 da conta não inclui esse gatilho. Fale com o administrador do tenant antes de continuar.

## 2. Criar o fluxo e copiar a URL

1. No app Workflows, crie um fluxo novo a partir do gatilho acima. Em **Quem pode disparar o fluxo**, escolha "Qualquer pessoa" (as máquinas não têm login).
2. Salve o fluxo. O gatilho passa a mostrar a **URL HTTP POST**. Copie essa URL.
3. Em cada PC, copie `config.exemplo.json` para `config.json` (na pasta `Otimizador-Empresa`) e cole a URL em `urlFluxo`.
4. Logo abaixo do gatilho, adicione **Initialize variable** (tipo *String*) com o nome `tokenEsperado` e o valor do token. Gere o token com `[guid]::NewGuid()` no PowerShell e use o mesmo valor em `token` no `config.json`.

A URL e o token são segredos: não coloque em chamado, e-mail ou card.

## 3. Validar token e versão (antes do Parse JSON)

A validação vem **antes** do Parse JSON e lê o corpo bruto do gatilho (`triggerBody()`). Assim, um payload com esquema diferente (por exemplo, um PC com script mais novo) ainda gera o card "payload rejeitado", em vez de só fazer o Parse JSON falhar sem aviso.

1. Adicione uma **Condição** (*Condition*) com duas linhas ligadas por **E** (*And*). Digite cada valor na aba **Expressão** (botão *fx*), não como texto:
   - `triggerBody()?['token']` **é igual a** `variables('tokenEsperado')`
   - `triggerBody()?['versaoEsquema']` **é igual a** `1`
2. O `1` da segunda linha **precisa ser digitado na aba Expressão**. O PC envia `versaoEsquema` como número, e a comparação do Power Automate diferencia tipos: `1` (número) não é igual a `"1"` (texto). Se o `1` for digitado como texto comum, todos os envios caem no card "payload rejeitado". Uma alternativa equivalente é uma linha só com `equals(triggerBody()?['versaoEsquema'], 1)` (na aba Expressão) **é igual a** `true` (também na aba Expressão).
3. No ramo **Se não** (*False*):
   1. Adicione **Compose**, renomeie para `Compose card rejeitado` e cole em **Inputs** o conteúdo de [`card-rejeitado.json`](card-rejeitado.json). Ele mostra só o nome do computador e a versão recebida. **Nunca** coloque o token no card.
   2. Adicione **Post card in a chat or channel** com os campos do [passo 5.2](#52-ramo-do-card) e, em **Adaptive Card**, a expressão `string(outputs('Compose_card_rejeitado'))`.
   3. Encerre o fluxo com **Terminate**.
4. O ramo **Se sim** (*True*) pode ficar vazio: o fluxo continua no passo 4.

## 4. Parse JSON

1. Depois da condição, adicione **Parse JSON**. Em **Content**, use a expressão `triggerBody()` (ou o conteúdo dinâmico *Body* do gatilho).
2. Não gere o esquema do exemplo. Abra [`esquema-parse-json.json`](esquema-parse-json.json), copie tudo e cole no campo **Schema**. Ele já aceita `ultimoEvento` e `ultimoBoot` como texto ou vazio (`null`).
3. Não use "Generate from sample" com `exemplo-payload.json`: alguns alertas têm `ultimoEvento` vazio, o gerador assume que o campo nunca é texto e o Parse JSON falha nos alertas de tela azul.
4. Deixe a ação com o nome `Parse JSON` (`Parse_JSON` nas expressões).

## 5. Tratar cada alerta

Adicione **For each** sobre a expressão `body('Parse_JSON')?['alertas']`. Dentro dele ficam **dois ramos independentes**: o do card e o da tarefa.

> **O card não pode bloquear a tarefa.** Se o post no Teams falhar (canal renomeado, limite do conector, card inválido), a tarefa no Planner precisa ser criada mesmo assim. Monte os dois ramos em **paralelo** (no `+` entre as ações, escolha **Add a parallel branch**). Se preferir deixá-los em sequência, abra **Settings > Run after** da condição "Criar tarefa?" e marque **is successful**, **has failed**, **is skipped** e **has timed out**. Sem isso, uma falha no card pula a criação da tarefa.

### 5.1 Por que o card passa por um Compose

O campo **Adaptive Card** do Teams recebe texto. Se o card for colado direto nele, cada `@{...}` insere o valor cru, sem escapar `\` e aspas. Valores reais quebram o JSON: o usuário `PC-FINANCEIRO-03\maria` (o `\m` é um escape inválido), uma solução com aspas (`usar "Reparo Rápido"`), uma impressora `\\srv\HP`.

Por isso o card é montado num **Compose** cuja entrada é um **objeto JSON**. Dentro de um objeto, cada valor com `@{...}` é calculado separadamente e o Power Automate faz o escape sozinho. O post recebe depois `string(outputs('Compose_card'))`, que converte o objeto pronto em texto JSON válido.

### 5.2 Ramo do card

1. Adicione uma **Condição** chamada "Postar card?" com uma linha, tudo na aba **Expressão**:
   `and(contains(createArray('novo','nova-ocorrencia','resolvido'), items('For_each')?['situacao']), not(equals(items('For_each')?['destino'], 'nenhum')))` **é igual a** `true`.
2. No ramo **Se sim**:
   1. Adicione **Compose**, renomeie para `Compose card` e cole em **Inputs** o conteúdo de [`card-teams.json`](card-teams.json). O card usa expressões do Power Automate (`@{...}`), não o modelo `${...}` do Adaptive Cards. O cabeçalho fica verde para `resolvido`, amarelo para `nova-ocorrencia` e vermelho para `novo`.
   2. Adicione **Post card in a chat or channel** e preencha:
      - **Post as:** `Flow bot`
      - **Post in:** `Channel`
      - **Team:** a equipe de suporte
      - **Channel:** o canal de suporte
      - **Adaptive Card:** na aba **Expressão**, `string(outputs('Compose_card'))`. Também funciona digitar `@{outputs('Compose_card')}` como texto, porque a interpolação converte o objeto em texto JSON da mesma forma. Não use `outputs('Compose_card')` sem `string()`: isso entrega um objeto, e o campo espera texto.

### 5.3 Ramo da tarefa (paralelo ao do card)

1. Adicione uma **Condição** chamada "Criar tarefa?" com duas linhas ligadas por **E**:
   - `items('For_each')?['situacao']` **é igual a** `novo`
   - `items('For_each')?['destino']` **é igual a** `tarefa`
2. No ramo **Se sim**, adicione **Create a task** (Planner) e preencha:
   - **Group Id:** o grupo do Microsoft 365 da equipe de suporte
   - **Plan Id:** o plano onde as tarefas vão cair
   - **Bucket Id:** o bucket (por exemplo, "Alertas automáticos")
   - **Title:** `[@{body('Parse_JSON')?['computador']?['nome']}] @{items('For_each')?['problema']}`
3. Em seguida, adicione **Update task details** (Planner) com **Task Id** = o *Id* retornado pelo Create a task (`outputs('Create_a_task')?['body/id']`) e, em **Description**, a evidência, a solução e o usuário (`items('For_each')?['evidencia']`, `items('For_each')?['solucao']`, `body('Parse_JSON')?['computador']?['usuario']`). Título e descrição do Planner são texto simples, então aqui o `@{...}` direto não tem problema de escape.

Alertas `persiste` não geram nada: o PC os envia todos os dias para o fluxo saber que continuam abertos. Alertas com `destino` `nenhum` também não geram nada.

### 5.4 Se o designer mostrar `@{...}` como texto

Em algumas telas do designer novo, os valores `@{...}` aparecem como texto puro, e não como "fichas" de conteúdo dinâmico. Isso não é erro por si só. Para conferir:

1. No menu `...` da ação **Compose**, abra **Peek code** (Exibir código). No designer novo, use a aba **Code view** da ação, se aparecer.
2. O certo é `"inputs": { "type": "AdaptiveCard", ... }`, um **objeto**, com valores como `"@{items('For_each')?['problema']}"`.
3. Está errado se `inputs` aparecer como **um texto único** (`"inputs": "{\n  \"type\": ...`) ou se os valores aparecerem como `@@{...}`. No primeiro caso, o escape manual volta a ser necessário e o card quebra. No segundo, o designer escapou o `@` e a expressão não é calculada. Para corrigir, desligue o **Novo designer** (chave no topo da tela), apague o conteúdo do Compose, cole o card de novo no designer clássico e confira outra vez com **Peek code**.

## 6. Testar (leia isto)

> **Atenção:** o gatilho responde **202** antes de validar qualquer coisa. Por isso o PC sempre vê sucesso, mesmo se o token estiver errado. O teste só é confirmado **vendo o card chegar no canal**.

> **Atenção:** cada execução do `Testar-Envio.ps1` cria uma **tarefa real no Planner** (o exemplo tem um alerta `novo` com destino `tarefa`). Apague a tarefa `[TESTE-...]` depois de conferir.

1. No PC, rode `Otimizador-Empresa\Testar-Envio.ps1` como administrador. Ele usa o nome `TESTE-<nome do PC>` e restringe as permissões do `config.json`.
2. Confira o canal. Devem chegar os cards de `novo`, `nova-ocorrencia` e `resolvido` do exemplo, e uma tarefa no Planner. Se aparecer o card "payload rejeitado", o token do fluxo e o do `config.json` não coincidem. Se não aparecer nada, veja o histórico de execuções do fluxo.
3. Para uma execução real sem esperar o atraso aleatório, rode `OtimizadorEmpresa.ps1 -Monitorar -SemAtraso`.

## 7. Implantar: comece com um piloto

No primeiro dia, cada PC envia **todos** os problemas que já existem como `novo`. Com 50 PCs de uma vez, o canal e o Planner enchem de cards e tarefas. Comece com um **piloto de 3 a 5 PCs**: trate ou feche o que chegar, ajuste o fluxo e só então agende nos demais.

A tarefa agendada com `-Monitorar` espera um tempo aleatório de 0 a 15 minutos antes de rodar, para não disparar o fluxo de todos os PCs no mesmo segundo.

## 8. Trocar o token (rotação)

1. Gere um valor novo: `[guid]::NewGuid()`.
2. Atualize a variável `tokenEsperado` no fluxo.
3. Atualize o `token` no `config.json` de cada máquina. Depois da primeira execução, o `config.json` só pode ser lido e alterado por Administradores e SYSTEM: abra o editor **como administrador** (por exemplo, Bloco de Notas > Executar como administrador) ou distribua o arquivo pela ferramenta de gestão (GPO/RMM).

Enquanto nem todas as máquinas estiverem atualizadas, vão aparecer cards "payload rejeitado" daquelas que ficaram para trás. Isso é o esperado.

## 9. Limitações conhecidas

- Um problema sem evento (espaço em disco, antivírus, RAM esgotada...) só é dado como `resolvido` depois de **7 dias seguidos** sem aparecer. Se voltar antes disso, continua o mesmo alerta (`persiste`) e não abre tarefa nova.
- Se alguém apagar a tarefa no Planner e o problema continuar, ela não é recriada: o PC envia `persiste`, não `novo`.
- Relatórios (`relatorios\`) e logs (`logs\`) acumulam a cada execução diária. Ainda não há limpeza automática desses arquivos.
- A tarefa roda como SYSTEM. As verificações de privacidade que leem `HKCU` (câmera e microfone bloqueados nas configurações de privacidade) leem as configurações do SYSTEM, e não as do usuário logado. Esses alertas podem não refletir o que o usuário vê.
