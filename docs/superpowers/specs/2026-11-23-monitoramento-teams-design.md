# Entrega 1 — Monitoramento diário com alertas no Teams e Planner

Data: 2026-11-23 · Status: rascunho para aprovação

## Intenção e o porquê

Hoje o Otimizador Empresarial só gera um relatório HTML local por máquina. O suporte
só fica sabendo de um problema quando o usuário abre chamado, ou quando o técnico
roda a ferramenta na máquina. O objetivo é **atender chamados mais rápido e
descobrir problemas antes do usuário ligar**, entrando no fluxo que a equipe já usa
no Microsoft 365: **Teams → Planner → Outlook**.

Esta é a primeira de quatro entregas acordadas, nesta ordem:

1. **Resumo JSON + envio para um fluxo do Teams + alertas no Teams/Planner** ← este documento
2. "Abrir chamado" pelo menu (técnico ou usuário envia a análise na hora)
3. Painel das máquinas (lista do SharePoint alimentada pelo mesmo fluxo)
4. Instalação e atualização automática do script nas máquinas sem domínio

A entrega 1 é a base das outras três: o formato JSON e o canal de envio definidos
aqui são reaproveitados por elas.

## Contexto do ambiente de teste

- Cerca de 50 estações Windows 10/11.
- **Sem domínio** (grupo de trabalho) e **sem pasta de rede**. Não há GPO.
- Comunicação da equipe: Teams; tarefas no Planner; e-mail no Outlook (Microsoft 365).
- Postura DevSecOps: minimizar segredos nas máquinas e o estrago caso um vaze.

## Objetivos

- Cada estação roda **diariamente** um diagnóstico (sem limpeza) e envia um resumo
  JSON por HTTPS para um fluxo do Power Automate (app Workflows do Teams).
- O fluxo:
  - posta um card no canal de suporte do Teams para problemas relevantes;
  - cria tarefa no Planner só para problemas críticos que pioram sozinhos;
  - avisa no canal quando um problema crítico some (resolvido).
- **Não gerar ruído:** a mesma máquina com o mesmo problema gera uma única tarefa;
  nos dias seguintes, o problema chega como "persiste", não como novo.
- Se o envio falhar (sem internet), o resumo fica numa fila local e é reenviado na
  próxima execução.
- O modo interativo e o relatório HTML continuam funcionando como hoje.

## Não-objetivos (ficam para as próximas entregas)

- Painel/lista consolidada das máquinas (entrega 3). Os dados de aviso já vão no
  JSON, mas o fluxo da entrega 1 não precisa gravá-los em lugar nenhum.
- Botão "Abrir chamado" no menu (entrega 2).
- Distribuição automática do script e da configuração nas 50 máquinas (entrega 4).
  Na entrega 1 a instalação no ambiente de teste é manual, guiada por documentação.
- Aplicar correções automaticamente. O modo automático continua sem corrigir nada.
- Envio de e-mail direto pelo script.

## Anti-objetivos (falharia mesmo "funcionando")

- Planner ou canal inundados: se a equipe parar de olhar porque tem alerta demais,
  a entrega falhou.
- Segredo com poder de escrita no tenant M365 guardado nas máquinas (Graph, conta
  de e-mail, conta de serviço). Rejeitado explicitamente.
- Dados pessoais desnecessários no payload: nada de conteúdo de arquivos, histórico
  de navegação ou lista de documentos. O nome do usuário logado pode ir, porque já
  está no relatório e o técnico precisa dele.
- O script travar ou demorar visivelmente para o usuário por causa do envio.
- O envio ou a fila quebrarem o modo interativo ou o relatório HTML.

## Restrições

- PowerShell 5.1 puro, sem módulos ou executáveis de terceiros (premissa de
  auditabilidade do projeto).
- Roda como SYSTEM via tarefa agendada (`schtasks`), sem domínio.
- HTTPS com TLS 1.2+ (no PS 5.1, forçar `[Net.ServicePointManager]::SecurityProtocol`).
- O fluxo do Power Automate fica **fora do repositório**. O repositório entrega o
  contrato (esquema JSON), um payload de exemplo e o passo a passo para montar o
  fluxo.
- É preciso confirmar se o licenciamento M365 do cliente de teste cobre o gatilho
  "When a Teams webhook request is received". O M365 padrão costuma cobrir, mas
  isso precisa ser validado antes do teste.

## Abordagens consideradas

| | Abordagem | Prós | Contras | Decisão |
|---|---|---|---|---|
| **A** | PC envia JSON por HTTPS → fluxo do Workflows (Teams/Power Automate) → card no Teams + tarefa no Planner | Usa o que o cliente já tem; o segredo na máquina só permite *enviar dados para este fluxo*; funciona fora da rede | URL do fluxo é segredo (precisa de rotação e de token extra); parte da lógica fica fora do repo; depende de licença | **Escolhida** pelo usuário |
| B | Script chama Microsoft Graph com app do Entra ID e cria a tarefa direto | Toda a lógica no código | Segredo com escrita no tenant em 50 máquinas sem domínio: estrago grande se vazar | Descartada |
| C | Script envia e-mail via SMTP/Outlook | Simples | Senha de caixa postal em cada PC; autenticação básica em SMTP sendo descontinuada; não gera tarefa nem painel | Descartada |

## O que foi decidido

### 1. Execução diária

- Novo parâmetro do script: `-Monitorar`. Roda **só** `Diagnostico` + `Analisar-Problemas`,
  gera o HTML e o JSON e envia. Não limpa, não otimiza, não pergunta nada.
- A limpeza semanal (`-Automatico`) continua existindo. Quando `-Automatico` roda,
  ele também envia o JSON (o diagnóstico já é feito).
- Documentar duas tarefas agendadas: diária (`-Monitorar`, horário comercial, por
  exemplo 10h, para pegar a máquina ligada) e semanal (`-Automatico`, sexta 18h,
  como hoje).

### 2. Código fixo por problema

Cada achado (`Achado`) e cada item de diagnóstico que gere alerta ganha um **código
estável** (ex.: `disco-smart`, `disco-erros`, `bsod`, `whea`, `antivirus-desativado`,
`antivirus-desatualizado`, `firewall-desativado`, `disco-espaco-critico`,
`desligamento-inesperado`, `impressora-spooler`...). Para problemas por dispositivo,
o código inclui um sufixo estável (ex.: `disco-smart:<número de série ou nome>`).
O código, e não o texto, é o que identifica "o mesmo problema" entre execuções.

### 3. Classificação: o que vira tarefa, o que vira card

Combinado com o usuário:

| Destino | Quais |
|---|---|
| **Tarefa no Planner** (+ card) | `erro` de **hardware e segurança**, que pioram sozinhos: disco com SMART ruim ou erros de leitura/gravação, telas azuis, erros WHEA, antivírus ausente/desativado/desatualizado, firewall desativado, disco do sistema abaixo de ~10% livre |
| **Só card no Teams** | demais `erro` (impressora, áudio, rede, câmera, serviços parados...), que o usuário costuma perceber e reportar |
| **Só no JSON** (painel na entrega 3) | `aviso` e `info` |

**Espaço em disco:** a tarefa é criada abaixo de **10% livres** no disco do sistema.
Esse limite fica no mapa de classificação e é independente da cor do relatório HTML,
que continua mostrando `erro` só abaixo de 5%. *(decisão minha, para não mudar o
relatório atual)*

A classificação de cada código fica num **mapa único no script** (código →
`tarefa` / `card` / `nenhum`), para ser fácil de revisar e ajustar.

### 4. Controle de duplicidade no PC (decisão minha)

- O script guarda em `estado\alertas.json` os códigos já reportados, o destino com
  que foram reportados, quando foram vistos pela primeira vez e, para alertas
  baseados em eventos, a data do evento mais recente.
- **O estado só avança depois de um envio confirmado** (HTTP 2xx). Se o envio
  falhar, a próxima execução compara de novo com o último estado confirmado, e
  nenhum `novo` se perde por falta de internet. *(decisão minha)*
- **Subir de destino conta como `novo`.** Exemplo: um código reportado como `nenhum`
  (aviso) que passa a `tarefa` (erro) é tratado como `novo` e cria a tarefa.
  *(decisão minha)*
- **Alertas baseados em eventos** (telas azuis, WHEA, erros de disco, desligamentos
  inesperados):
  - se aparecer um evento mais recente que o registrado no estado, o alerta sai como
    `nova-ocorrencia`. O fluxo posta um card "voltou a acontecer" e **não** cria
    outra tarefa;
  - o alerta é `resolvido` depois de **7 dias sem evento novo**, e não quando a
    janela de 30 dias do diagnóstico expira. *(decisão minha)*
- **Um alerta por máquina e por tipo:** firewall desligado em qualquer perfil gera
  um único alerta `firewall-desativado` (a evidência lista os perfis); o mesmo vale
  para o antivírus. *(decisão minha)*
- Em cada execução, cada alerta sai marcado como:
  - `novo`: apareceu agora → o fluxo posta card e, se for `tarefa`, cria a tarefa;
  - `persiste`: já tinha sido reportado → o fluxo não faz nada (ou só atualiza a
    tarefa, se for simples de implementar no fluxo);
  - `resolvido`: estava no estado e sumiu → o fluxo posta "resolvido" no canal.
- Motivo: mantém o fluxo do Power Automate burro e a lógica testável no repositório.
- Limitação aceita: se alguém apagar a tarefa no Planner e o problema continuar, ela
  não é recriada enquanto o código não sumir e voltar.

### 5. Contrato JSON (versão 1)

O payload leva:
- `versaoEsquema`, `versaoScript`, `enviadoEm` (ISO 8601);
- identificação: computador, usuário logado, fabricante/modelo, número de série,
  versão do Windows, último boot;
- `token` (ver segurança);
- `alertas`: lista com código, categoria, problema, evidência, solução, gravidade,
  destino (`tarefa`/`card`/`nenhum`) e situação
  (`novo`/`persiste`/`nova-ocorrencia`/`resolvido`);
- `itens`: os itens do diagnóstico (seção, nome, valor, status), para a entrega 3.

O esquema fica documentado em `docs/` com um payload de exemplo.

### 6. Envio e fila

- Como cada payload é uma foto completa da máquina, a fila guarda **só o último
  payload não enviado** (`fila\pendente.json`). Ele é substituído a cada execução e
  removido após um 2xx. Assim, uma semana offline gera um único envio atualizado,
  sem inundar o canal, e sem perder `novo` (ver item 4). *(decisão minha)*
- Timeout curto (cerca de 15 s) por envio; uma falha nunca interrompe o restante do script.
- Tudo é registrado no log existente (`logs\`), **sem** gravar a URL nem o token.

### 7. Configuração e segurança

- Arquivo `config.json` ao lado do script, **fora do git** (entra no `.gitignore`),
  com `urlFluxo` e `token`. Junto vai um `config.exemplo.json` versionado.
- O script ajusta as permissões do `config.json` (ACL) para só Administradores e
  SYSTEM lerem.
- O `token` é um valor aleatório compartilhado; o fluxo rejeita payloads sem o token
  correto. Isso é defesa em profundidade, caso a URL vaze por print, log ou chat.
- Rotação: trocar o token no fluxo e no `config.json`. Documentar o passo.
- Sem `config.json`, o script funciona como hoje (não envia nada) e avisa no log.

### 8. Fluxo no Power Automate (documentado, não versionado como código)

O passo a passo em `docs/` cobre:
- criar o fluxo pelo app Workflows do Teams com o gatilho de webhook;
- validar o `token` e o `versaoEsquema`. **Atenção:** o gatilho de webhook do Teams
  responde 202 na hora, antes de qualquer validação, então o script **não fica
  sabendo** se o payload foi rejeitado. Por isso, quando o token ou o esquema
  estiverem errados, o fluxo posta um card "payload rejeitado" (com o nome do
  computador, nunca o token) no canal. É assim que um token errado ou uma rotação
  feita só de um lado aparece. Na entrega 3, o painel também vai mostrar "último
  envio recebido" por máquina. *(decisão minha)*
- para cada alerta `novo` com destino `card` ou `tarefa`: postar um Adaptive Card no
  canal (computador, usuário, problema, evidência, o que fazer);
- para `tarefa` + `novo`: criar tarefa no plano/bucket de suporte, com título
  `[PC] problema`;
- para `resolvido` com destino `card` ou `tarefa`: postar no canal que o problema
  foi resolvido;
- modelo do Adaptive Card em JSON versionado no repositório.

Também vai um script de teste (`Testar-Envio`) que manda um payload de exemplo para
validar o fluxo sem depender de uma máquina com problema. Como o gatilho sempre
responde 202, o teste só é confirmado vendo o card chegar no canal, e o guia diz isso
explicitamente.

## Deixado para quem for construir

- Nomes exatos dos códigos e o mapeamento completo dos ~30 achados e itens.
- Layout do Adaptive Card.
- Estrutura interna das funções no script (manter o estilo atual: funções em
  português, um único `.ps1`).
- Se `persiste` atualiza a tarefa no fluxo ou é simplesmente ignorado.
- Horário exato sugerido para a tarefa diária.
- Como testar a lógica de estado e fila (ex.: Pester rodando localmente, ou
  funções puras testáveis sem Windows).
