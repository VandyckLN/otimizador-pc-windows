# Otimizador Empresarial

Ferramenta de manutenção e diagnóstico para estações de trabalho Windows 10/11, feita em PowerShell, com menu em português, **backup automático de tudo que altera** e opção de desfazer. Pensada para suporte de TI e manutenção preventiva.

Os arquivos ficam na pasta [`Otimizador-Empresa/`](Otimizador-Empresa).

### Tela inicial

O menu já abre mostrando o estado da máquina:

```
   Estação ............ PC-FINANCEIRO-03
   Ligado desde ....... 16/11/2026 09:52  (há 0 dia(s) e 1 h)
   Último desligamento  15/11/2026 23:44 - desligado por EMPRESA\maria (StartMenuExperienceHost.exe)
   Memória RAM ........ ████████████░░░░░░░░ 59%  (9,33 GB de 15,89 GB em uso, 6,56 GB livre)
```

Último desligamento inesperado (queda de energia/travamento) aparece em vermelho; RAM muda de cor conforme o uso.

### Funcionalidades

1. **Diagnóstico + relatório HTML** — gera um relatório por máquina (`NOMEDOPC_data.html`) com status ✔ / ⚠ / ✖, pronto para anexar em chamado:
   - Identificação: nome, domínio, usuário, fabricante/modelo, número de série, versão do Windows, último boot, último desligamento (quem, quando, normal ou inesperado), Inicialização Rápida
   - Hardware: CPU, uso de RAM, pentes de memória (dual channel), saúde e desgaste dos discos (SMART), espaço livre, saúde da bateria
   - Segurança: antivírus (ativo/atualizado), firewall, BitLocker
   - Atualizações: última instalada, reinicialização pendente, dispositivos com problema
   - Rede: IP, gateway, DNS, acesso à internet
   - Desempenho: programas na inicialização, plano de energia, volume de temporários, maiores consumidores de memória
   - Inclui a análise de problemas abaixo
2. **Análise de problemas (causas prováveis)** — observa a máquina por 5 segundos e lê o histórico do Windows (sem testes de estresse) para apontar **o problema, a evidência e o que fazer**:
   - **Lentidão:** sem reiniciar há dias, atualizações pendentes, RAM esgotada (e quais programas consomem), CPU sobrecarregada (com explicação dos processos conhecidos: antivírus, Windows Update, indexação...), processador limitando velocidade (superaquecimento), disco sobrecarregado/HD mecânico/pouco espaço, inicialização lenta com os itens que mais atrasam, plano de energia em economia, bateria
   - **Travamentos:** telas azuis com o código traduzido para a causa provável, desligamentos inesperados, erros de hardware (WHEA), erros de disco, programas que travam com frequência
   - **Câmera e microfone:** não detectado, desativado, bloqueado na privacidade ou por política (GPO/Intune), ou em uso por outro programa
   - **Áudio, rede e impressão:** serviço de áudio parado, sem IP (DHCP), DNS falhando, Wi-Fi fraco, cabo limitado a 100 Mbps, spooler parado, fila travada, impressora offline/sem papel
   - **Qualquer dispositivo com erro**, com o significado do código
   - Ao final, oferece as **correções automáticas** possíveis (reiniciar dispositivo, liberar câmera, iniciar serviço, destravar fila, renovar IP...). **Nada é aplicado sem o técnico escolher** — e no modo automático nunca é aplicado.
3. **Limpeza (todos os usuários)** — temporários, cache do Windows Update, Otimização de Entrega, relatórios de erro, logs antigos, miniaturas, cache dos navegadores (Chrome, Edge, Brave, Firefox — **sem** apagar histórico, senhas, cookies ou logins). Lixeira e DISM só com confirmação.
4. **Otimização para trabalho** — plano Alto desempenho em desktops (notebooks mantêm o Equilibrado), remove sugestões/propagandas e instalação silenciosa de apps patrocinados, remove o atraso artificial de inicialização, TRIM/desfragmentação. Animações e apps em segundo plano são opcionais.
5. **Programas na inicialização** — lista por usuário com orientação do que manter (antivírus, VPN, agentes de gestão).
6. **Rede** — testa gateway, DNS e HTTPS; limpa cache DNS; reset de Winsock/TCP-IP com aviso para não usar em acesso remoto.
7. **Reparo do Windows** — DISM RestoreHealth, SFC e verificação online do disco.
8. **Atualizações do Windows e drivers** — usa o servidor configurado na empresa (WSUS/Intune/Windows Update), lista e instala com confirmação.
9. **Manutenção completa** — limpeza + otimização + relatório com análise.
10. **Desfazer** — restaura registro e plano de energia originais.

### Como usar

- **Interativo:** clique duas vezes em `Otimizador-Empresa\INICIAR_EMPRESA.bat` (pede permissão de administrador).
- **Automático (sem perguntas):** `Otimizador-Empresa\MANUTENCAO_AUTOMATICA.bat` — faz limpeza segura + relatório. Não esvazia lixeira, não roda DISM, não altera configurações e pula navegadores abertos.

Salvar relatórios numa pasta de rede:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\OtimizadorEmpresa.ps1 -Automatico -PastaRelatorio "\\servidor\ti\relatorios"
```

Agendar toda sexta-feira às 18h (rodar como administrador):

```bat
schtasks /Create /TN "Manutencao Otimizador" /SC WEEKLY /D FRI /ST 18:00 /RU SYSTEM /RL HIGHEST /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\TI\Otimizador-Empresa\OtimizadorEmpresa.ps1 -Automatico -PastaRelatorio \\servidor\ti\relatorios"
```

---

## Monitoramento (Teams/Planner)

Uma vez por dia, cada PC pode enviar um aviso para um fluxo do Power Automate, que posta cards no canal de suporte do Teams e cria tarefas no Planner.

**O que é enviado:** nome do computador, usuário, fabricante/modelo, número de série, versão do Windows, último boot, os alertas encontrados (problema, evidência e o que fazer) e o resumo do diagnóstico. **Não é enviado:** arquivos pessoais, senhas, histórico de navegação nem conteúdo de documentos.

**Como configurar:**

1. Abra um Prompt de Comando **como administrador** e, **nele**, crie a pasta, copie os arquivos e restrinja o acesso a Administradores e SYSTEM:

   ```bat
   mkdir C:\TI
   xcopy /E /I "<origem>\Otimizador-Empresa" C:\TI\Otimizador-Empresa
   icacls C:\TI /setowner *S-1-5-32-544 /T
   icacls C:\TI /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F
   ```

   Crie a pasta pelo prompt elevado: quem cria uma pasta em `C:\` vira o dono dela, e o dono pode mudar as permissões depois. O `/setowner` corrige isso se a pasta já existia.

   A tarefa agendada roda esses scripts como SYSTEM: se um usuário comum puder alterá-los, ele executa código como SYSTEM, lê o token do `config.json` ou planta um `estado\` falso. (No PowerShell, coloque cada `*S-...F` entre aspas simples.)
2. Monte o fluxo seguindo o [guia do fluxo](docs/monitoramento/fluxo-power-automate.md).
3. Na pasta `Otimizador-Empresa`, copie `config.exemplo.json` para `config.json` e preencha `urlFluxo` e `token`. O `config.json` fica fora do git. Na primeira execução, o script restringe o `config.json` a Administradores e SYSTEM; depois disso, para trocar o token, edite o arquivo num editor aberto **como administrador**.
4. Teste com `Otimizador-Empresa\Testar-Envio.ps1` (como administrador) e confira se o card chegou no canal. **Atenção:** cada execução do teste cria uma tarefa real no Planner; apague-a depois.
5. Faça um **piloto com 3 a 5 PCs** antes de agendar nos 50: no primeiro dia, cada PC envia todos os problemas que já existem como `novo`, o que gera muitos cards e tarefas de uma vez.

Sem `config.json`, o script funciona como antes e só registra um aviso no log.

Agendar o monitoramento diário às 10h (rodar como administrador), além da tarefa semanal de manutenção acima:

```bat
schtasks /Create /TN "Monitoramento Otimizador" /SC DAILY /ST 10:00 /RU SYSTEM /RL HIGHEST /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\TI\Otimizador-Empresa\OtimizadorEmpresa.ps1 -Monitorar"
```

Com `-Monitorar`, o script espera um tempo aleatório de 0 a 15 minutos antes de rodar (para os PCs não chamarem o fluxo todos ao mesmo tempo) e registra a espera no log. Para rodar na hora, num teste manual ou diagnóstico, acrescente `-SemAtraso`.

**Limitações conhecidas:**

- Relatórios e logs da execução diária se acumulam em `relatorios\` e `logs\`. Ainda não há limpeza automática.
- Como a tarefa roda como SYSTEM, as verificações de privacidade de câmera e microfone (que leem `HKCU`) leem as configurações do SYSTEM, e não as do usuário logado.
- Problemas sem evento (espaço em disco, antivírus, RAM...) só são dados como resolvidos depois de 7 dias seguidos sem aparecer.

---

## Segurança

- Exige administrador e cria **ponto de restauração** antes de alterar o sistema
- Todo valor de registro alterado é salvo em `backup\registro.json` antes da mudança — a opção **Desfazer** restaura tudo
- Temporários com menos de 1 dia não são apagados; arquivos em uso são ignorados
- Nada de arquivos pessoais (Documentos, Downloads, Área de Trabalho), programas ou dados de navegação é apagado
- Tudo é registrado em `logs\`
- Código aberto em PowerShell puro, sem executáveis nem downloads de terceiros — fácil de auditar

## Requisitos

- Windows 10 ou 11
- PowerShell 5.1 (já vem no Windows)
- Conta com permissão de administrador

## Próximos passos (ideias)

- Painel central com os relatórios de todas as máquinas
- Inventário de softwares instalados e licenças
- Remoção padronizada de bloatware de fábrica
- Versão para servidores Windows
