# Histórico de alterações

Todas as alterações relevantes do DBBackup são registradas neste arquivo. O
projeto usa as versões semânticas definidas em `VERSION` e as principais seções
do Keep a Changelog, sem exigir todas as seções em cada versão.

## [1.0.0] - 2026-11-17

### Alterado — incompatível com a linha 0.x

- Produto DBBackup, com entradas genéricas e configuração schema 1.
- Código compartilhado e estado isolado por instância; removida a identidade
  fixa do Seven em scripts, setup, arquivos e tarefas agendadas.
- Modos legados substituídos por trabalhos explícitos e `-All`. Configurações,
  pendências e archives 0.x não são importados automaticamente.

### Adicionado

- Provedores MySQL 5 (dump normal e fallback geral/granular), SQL Anywhere 17
  (completo nativo de banco/log sem rotação/truncagem) e diretórios opcionais.
- Pipeline 7z testado + age obrigatório, destinatários públicos, manifest com
  hashes/versões, estado de transporte e promoção atômica de bundles.
- Reenvio preservando bytes/destino, retenção local e logs sanitizados.
- Setup e secrets compartilhados como mecanismo, arquivos privados por instância,
  diagnóstico local e reconciliação de tarefas com identidade de configuração.
- Métricas Grafana Alloy no contrato genérico v0.3.0, checkpoint de último
  sucesso, deadline por agenda e identificação de publicação degradada.
- Timeout por ferramenta com encerramento da árvore, streaming do dump e
  verificações de espaço/reserva antes das etapas maiores.
- Prazo total por execução (`Execution.RunTimeoutSeconds`), com limite da tarefa
  agendada derivado dele, e limpeza de Work/Staging de execuções interrompidas.
- Estimativa automática de espaço (histórico do trabalho ou sonda MySQL),
  `Retention.KeepLocalPayload`, `Storage.Destination` e resumo de pendências.
- Pacote DBBackup com lista explícita, manifest interno, SHA-256 e workflow
  manual de release que verifica o commit antes de publicar.

### Fronteira operacional

- Recovery preparation foi excluído por solicitação do usuário. Restauração,
  descriptografia de ensaio e validação de banco são processos externos.
- Não há motor local de recovery/validação iniciado pelo DBBackup; SQL Anywhere
  usa somente dbbackup, não dbvalid/dbeng/dbsrv.
- Sucesso não certifica restauração. Os testes de banco/S3/criptografia usam
  simuladores; nenhuma homologação em produção ou recuperação real é declarada.
- Build local não publica release/tag nem instala ou altera tarefas existentes.

## [0.6.0] - 2026-11-16

### Adicionado

- Monitoramento publica `backup_success_due_timestamp_seconds`: prazo do
  próximo sucesso, a primeira execução do `Schedule` que cobre o tipo depois
  do último sucesso. Não avança quando uma execução falha; sem sucesso
  conhecido, mantém o primeiro prazo publicado. Os alertas do Grafana passam a
  usar o prazo quando ele existe (preciso em qualquer agenda).
- `Monitoring.Criticality` por tipo (`alta`, padrão, ou `baixa`), publicada
  como `criticality` em `backup_info`; `baixa` desce um nível os alertas do
  backup. Valor inválido encerra com exit code `2`. O setup inclui a chave.

### Corrigido

- Pastas de ano e mês que ficavam vazias em `Runtime\Pending\<tipo>` depois
  do envio passam a ser removidas no fim de cada execução (`Cleanup/Pending`),
  inclusive as já acumuladas. Arquivos pendentes e a pasta do tipo nunca são
  removidos, e uma falha na limpeza só gera aviso.

## [0.5.0] - 2026-11-14

### Adicionado

- Seção `Schedule` no `config.psd1`: as tarefas agendadas passam a ser
  declaradas na configuração (horário; modo `Full`, `Database` ou `Fiscal`;
  frequência diária, semanal ou mensal; ativa ou não). Padrão: `Full` diário
  às 12:00 e 19:00.
- `Aplicar-Configuracao.bat` e `Setup-BackupSeven.ps1 -Apply`: aplicam o
  `config.psd1` sem perguntar dados e reconciliam as tarefas, com plano
  (criar, alterar, remover) e confirmação.
- `Setup.bat`: setup interativo com elevação e `-ExecutionPolicy Bypass`.
- Tarefas na pasta `\BackupSeven\` do Agendador, acessível só por SYSTEM e
  Administradores, registradas por XML (inclui o gatilho mensal).
- Módulo `Schedule.psm1`.
- `RUNBOOK.md` com os procedimentos de operação, incluído no pacote.

### Alterado

- O intervalo esperado do monitoramento é calculado a partir do `Schedule`;
  `Monitoring.ExpectedIntervalHours` passa a ser só uma substituição manual.
  O setup remove o valor fixo gravado pelas versões 0.4.x.
- Tarefas do BackupSeven fora de `\BackupSeven\` (como as de
  `\ASSESSORIA SCRIPTS\`) são listadas para remoção na primeira aplicação.
- `README.md` reescrito como referência e retirado do pacote.

## [0.4.1] - 2026-11-14

### Corrigido

- O teste do S3 no setup não exige mais a permissão `s3:ListBucket`, que o
  backup não usa: credencial aceita sem permissão de listar vira aviso;
  credencial inválida continua sendo erro.
- Tarefas agendadas executam o `Backup-Seven.ps1` com
  `-ExecutionPolicy Bypass`, para não serem recusadas pela política de execução
  com os arquivos não assinados do pacote.
- Pasta do Grafana Alloy ainda inexistente vira aviso no setup, com a
  orientação de rodar o `alloyctl`, em vez de erro.

### Alterado

- O setup pode ser executado sobre uma instalação existente e altera somente o
  necessário: `config.psd1` só é regravado (com cópia) quando algum valor muda,
  a ACL de `Secrets` só é reaplicada quando difere, e as tarefas existentes que
  executam o `Backup-Seven.ps1` têm apenas a ação ajustada, mantendo gatilhos e
  conta. As tarefas padrão só são oferecidas quando não há nenhuma.
- O setup remove a marca de arquivo baixado da internet dos arquivos da pasta.
- `Monitoring.BackupIds` é preservado ao regravar a configuração.

## [0.4.0] - 2026-11-13

### Adicionado

- Estado de cada backup em textfile para o Grafana Alloy (job
  `integrations/backup`), no contrato genérico de backups do repositório
  `grafana`: `seven__database.prom` e `seven__fiscal.prom` com último sucesso
  (ponto de recuperação e tamanho), última tentativa (resultado, duração e
  degradado), intervalo esperado e `backup_info`.
- Seção opcional `Monitoring` na configuração: ativação, pasta, identidade
  (`Service` e `BackupIds`) e `ExpectedIntervalHours` por tipo.
- Módulo `Monitoring.psm1`.
- `Setup-BackupSeven.ps1` no pacote: setup assistido que pergunta os dados,
  grava configuração e credenciais, restringe `Secrets`, testa MySQL, S3 e a
  pasta do Alloy e oferece criar as tarefas agendadas e um backup de teste.

### Alterado

- CI registra o repositório PSGallery quando a imagem do runner não o traz.
- Falha antes de iniciar os pipelines (exit code `2` após ler a configuração)
  é registrada como tentativa falha dos tipos solicitados quando o
  monitoramento está ativo. Falha ao gravar o estado só gera aviso no log e não
  altera o exit code.

## [0.3.0] - 2026-09-19

### Adicionado

- Manifesto JSON em todos os backups do banco.
- Recuperação degradada com dump geral `--force`, dump individual de tabelas e
  views, marcadores `_FAILED.txt` e exit code `5`.
- Configuração explícita de `mysql.exe` para enumeração dos objetos do banco.

### Alterado

- Archives confirmados agora ficam diretamente em `Completed\Database` e
  `Completed\Fiscal`, fora de `Runtime` e sem hierarquia local de ano e mês.
- A hierarquia diária do S3 e a fila `Runtime\Pending` permanecem inalteradas.

## [0.2.1] - 2026-09-08

### Adicionado

- Limite configurável e aproximado do paralelismo do 7-Zip por percentual de
  processadores lógicos, inicialmente em 50%.
- Modelo sanitizado de `rclone.conf` no repositório e no pacote de produção.

### Alterado

- Linhas de log agora usam a hora local no formato `yyyy-MM-dd HH:mm:ss` e não
  repetem o modo quando ele já faz parte da etapa.
- Configuração inicial ajustada para o caminho real do rclone e para
  `--skip-events`, necessário enquanto a conta do MySQL não possui permissão
  para exportar eventos agendados.
- Documentação operacional ampliada com os contratos de compactação, CPU,
  credenciais e a limitação explícita do backup de eventos.

## [0.2.0] - 2026-09-04

### Adicionado

- Modelo de `mysql-backup.cnf` no pacote, pronto para preenchimento manual.
- Tutorial completo de instalação, credenciais, validação, agendamento,
  diagnóstico e atualização no README.

### Alterado

- Archives agora usam data e hora UTC legíveis no nome e são organizados no S3
  por instância, tipo, ano, mês e dia.
- Logs ficam diretamente em `Paths.LogRoot`, usam nomenclatura equivalente à
  dos archives e têm retenção baseada no timestamp controlado do nome.
- O log final de cada execução é enviado e validado no S3 sob o prefixo `Logs`.
- O pacote entrega `config.psd1` e `Secrets\mysql-backup.cnf` com seus nomes de
  produção, mantendo os modelos explicitamente identificados no repositório.
- Caminho operacional padronizado como `C:\TI\Scripts\BackupSeven`.
- Configuração inicial alinhada ao mysqldump do MySQL 5.5 e ao banco `a_estoque`
  identificados no processo legado.

## [0.1.0] - 2026-09-03

### Corrigido

- Verificação de tag/release inexistente não deixa mais exit code `1` encerrar o workflow.
- O empacotamento agora gera e valida SHA-256 para uso no CI e na release.

### Adicionado

- Contratos de arquitetura e configuração externa.
- Logs UTF-8 com contexto de execução, modo e etapa.
- Criação e validação de archives com 7-Zip.
- Backups independentes nos modos `Database`, `Fiscal` e `Full`.
- Dump completo do banco com credenciais em arquivo externo do MySQL.
- Envio validado pelo rclone com fila local para novas tentativas.
- Retenção local restrita aos backups confirmados e bloqueio de concorrência.
- Testes automatizados dos módulos, fluxos de erro e pacote de produção.
- Pacote versionado por allowlist, sem configuração ou dependências externas.
- CI para parsing, análise estática, testes e empacotamento.
- Release manual com tag `v<VERSION>`, ZIP e SHA256.
