# Histórico de alterações

Todas as alterações relevantes do DBBackup são registradas neste arquivo. O
projeto usa as versões semânticas definidas em `VERSION` e as principais seções
do Keep a Changelog, sem exigir todas as seções em cada versão.

## [2.2.3] - 2026-11-19

### Corrigido

- Menu, opção 7 (Ambiente): a validação sempre falhava com "Cannot bind
  argument to parameter 'Path' because it is an empty string", mesmo com o
  `ambiente.psd1` correto, porque a pasta `Instances` não chegava à checagem das
  instâncias.

## [2.2.2] - 2026-11-19

### Corrigido

- Monitoramento: o label `site` voltou a ser o local do servidor
  (`Monitoring.Site` no `ambiente.psd1`, ex.: `assessoria`, perguntado pelo
  setup), como na 0.6. Antes era o nome da instância (`seven`, `dominio`). Sem
  `Site`, continua o nome da instância.

## [2.2.1] - 2026-11-19

### Corrigido

- Incremental do SQL Anywhere: a pasta do log de produção não era reconhecida
  quando o `dbping -pd LogName` responde em tabela traduzida
  (`Banco de dados   LogName   C:\...\contabil.log`). Com isso, os logs
  renomeados (`AAMMDDxx.LOG`) não eram limpos. A pasta passa a ser gravada na
  base no próximo backup completo.

## [2.2.0] - 2026-11-19

### Adicionado

- `DBBackup.bat`: lançador único com menu (nova instância, editar, aplicar,
  diagnosticar, executar backup, últimos resultados, ambiente, atualizar,
  configurações versionadas). Cada opção roda o script em um processo separado e
  volta ao menu. Arrastar um ZIP sobre ele atualiza sem internet.
- `ambiente.psd1` na raiz da instalação: ferramentas (`SqlAnywhere` é a pasta
  `...\Tools` ou `...\Bin64`), `Execution`, `Archive`, `Retention` e a pasta
  textfile do Alloy valem para todas as instâncias. Precedência: instância >
  ambiente > padrão interno. O primeiro setup cria o arquivo e as instâncias
  seguintes não perguntam caminhos. Uma instância 2.0/2.1 entrega suas
  ferramentas ao ambiente na primeira passagem pelo setup. A opção 7 do menu
  edita, valida e reaplica.
- Backup incremental acumulado do SQL Anywhere: job
  `Incremental = @{ Enabled = $true; KeepRenamedLogDays = 3 }` e tarefas com
  `Mode = 'Incremental'`. O completo usa `dbbackup -r` e vira a base; o
  incremental usa `dbbackup -t` (log desde a base), com o sufixo `_INCREMENTAL`,
  e vai para `<RemoteRoot>/<job>/incremental/`. Sem base, o incremental é
  promovido a completo. Os logs renomeados (`AAMMDDxx.log`) são apagados após o
  completo confirmado e `KeepRenamedLogDays`. O setup pergunta o incremental
  (padrão `09:00,12:00,15:00,18:00`) e o horário do completo.
- Monitoramento do incremental: `backup_id` `<id>-log`, `kind="log"`, com prazo
  pelos horários incrementais.
- Diagnóstico: avisa quando falta o ambiente, o `dbping.exe`, a base do
  incremental, a pasta do log de produção ou a tarefa incremental.
- Menu: puxar as configurações do servidor de `configuracoes/<servidor>/` (main
  do GitHub). Mostra a diferença, guarda `<arquivo>.anterior`, valida e desfaz
  tudo se algo ficar inválido, e oferece aplicar. Também exporta as
  configurações para commit. Secrets nunca entram.

### Alterado

- Retenção local: além de `CompletedDays` (7), os incrementais saem quando a
  base deles é mais antiga que o completo anterior. Um completo que falha não
  apaga nada novo.
- `config.psd1` não precisa mais de `Tools`, `Execution`, `Archive` e
  `Retention`; o modelo foi reescrito.

### Removido

- `Setup.bat`, `Editar-Configuracao.bat`, `Aplicar-Configuracao.bat`,
  `Diagnosticar.bat`, `Executar-Backup.bat` e `Atualizar.bat` (substituídos pelo
  menu). O updater da 2.1 não aceita o pacote 2.2, por isso a atualização
  2.1 → 2.2 é manual: veja o RUNBOOK.

## [2.1.0] - 2026-11-18

### Adicionado

- `Atualizar.bat`: consulta a última release no GitHub, pergunta, baixa o ZIP e
  o `.sha256`, confere o checksum e o conteúdo do pacote, recusa atualizar com
  backup em execução, guarda a versão atual em `Versoes-Anteriores\` (três
  mantidas), troca só `App\` e os arquivos da raiz, restaura sozinho se a troca
  falhar e oferece reaplicar as instâncias. Sem internet, aceita um ZIP
  arrastado sobre o `.bat`. `Instances`, `Completed` e `Logs` não são tocados.
- `Editar-Configuracao.bat`: abre o `config.psd1` como Administrador, valida ao
  fechar, oferece reabrir ou desfazer se ficar inválido e aplica.
- Vários horários por tarefa: `At = @('12:30','19:00')` gera um disparo por
  horário; o setup aceita `12:30,19:00` e agrupa jobs com os mesmos horários.
- `Executar-Backup.bat` mostra o andamento na janela (`Step 1/4` a `4/4`) e
  pergunta quais jobs executar.
- Apply lista tarefas da 0.x/1.x (`\BackupSeven\`, `\DBBackup\<instância>\`)
  com o script que executam e as remove com `SIM`.
- Setup pergunta se publica métricas para o Grafana Alloy (sugere Sim quando a
  pasta textfile do Alloy existe), o serviço e o `backup_id` de cada job
  (reaproveitar o da 0.6 mantém o histórico). O diagnóstico avisa quando o
  Alloy está instalado e a instância não publica métricas; antes, o modelo
  vinha com `Monitoring.Enabled = $false` e o setup não perguntava.
- Estimativa de espaço do SQL Anywhere na primeira execução via
  `dbping -pd FileSize,PageSize`, quando disponível.

### Alterado

- Os `.bat` listam as instâncias (uma é escolhida direto; várias, por número)
  em vez de pedir o caminho do `config.psd1`.
- O Apply torna privado o `Runtime` da instância mesmo com permissões herdadas,
  em vez de recusar.
- Mensagens de agenda indicam a tarefa, os jobs configurados e diferença de
  maiúsculas/minúsculas no nome do job.
- Ferramentas externas rodam com stdin fechado: um pedido de senha ou
  confirmação falha na hora em vez de esperar o timeout.

### Corrigido

- Documentação: o `config.psd1` herda a permissão da instalação e, na
  instalação típica, só Administradores alteram (a tarefa SYSTEM executa os
  caminhos de `Tools`). A 2.0.0 dizia que era editável sem elevação.

## [2.0.0] - 2026-11-18

### Alterado — incompatível com a 1.x

- Instância e job separados (configuração schema 2): a instância reúne
  credenciais S3, destinatários age, agenda e pastas; cada job tem provedor
  (MySQL, SQL Anywhere ou Diretório) e `RemoteRoot` próprios. Uma instância
  pode combinar qualquer conjunto de jobs, inclusive só pastas. A seção
  `Directories` e os campos `Provider`/`Database` da instância deixam de existir.
- Tarefas agendadas executam uma lista de jobs (`Schedule.Tasks[].Jobs`), em
  sequência; `Backup.ps1 -Job` aceita `a,b`.
- Nomes legíveis: `2026-11-18_19-00-05_<instância>_<job>[_GERAL|_GRANULAR].7z.age`,
  em horário local; logs `Logs\<instância>\2026-11-18_19-00-02.log`.
- `Completed` e `Logs` saem da instância e ficam na raiz da instalação
  (`Completed\<instância>\<job>\`, `Logs\<instância>\`), com a permissão
  herdada. Só `Secrets` e `Runtime` continuam restritas; a pasta da instância e
  o `config.psd1` voltam a ser editáveis.
- Pacote: na raiz só os `.bat` e `LEIA-ME.txt` (versão e links); scripts,
  módulos, modelo e `VERSION` em `App\`. README, RUNBOOK, ARCHITECTURE e
  contratos não fazem mais parte do pacote, nem o `PACKAGE-MANIFEST.json`.

### Adicionado

- Setup com menu de jobs (MySQL, SQL Anywhere, Diretório), pergunta explícita
  sobre backup de pasta, opção de instância só de diretório, adição de jobs a
  uma instância existente e agrupamento de jobs por horário numa tarefa.
- Setup encontra arquivos já presentes em `Secrets` (`rclone.conf`,
  `recipients.txt`, `*.cnf`, `*.options`), pergunta se mantém, garante a ACL e
  guarda o recusado como `.old`; configuração 1.x guardada como `config.v1.psd1`.
- Linha final `RESULTADO: ...` em todo log, com jobs e etapas que falharam.
- `Diagnosticar.bat` e `Executar-Backup.bat`.

## [1.1.0] - 2026-11-18

### Alterado — incompatível com a 1.0.0

- `Storage.RemoteRoot` passa a ser o destino completo da instância
  (`remote:bucket/prefixo`). O nome da instância não é mais acrescentado ao
  caminho remoto: `<RemoteRoot>/<trabalho>/aaaa/mm/dd/` e `<RemoteRoot>/Logs/`.
  Duas instâncias do mesmo servidor não podem usar o mesmo destino.
- Tarefas agendadas ficam direto em `\DBBackup\`, com o nome
  `<instância>-<tarefa>`; cada instância só altera as próprias tarefas.

### Corrigido

- Setup falhava com `0x8007007B` ao abrir a pasta de tarefas: o caminho era
  passado ao Agendador com barra final.

### Adicionado

- Setup guiado: valida executáveis na hora (com sugestão de instalação
  encontrada), nome do banco obrigatório, bucket e prefixo separados, horário
  da tarefa, host/porta conforme o provedor, endpoint só fora da AWS, teste
  opcional somente leitura de banco e S3, orientação quando algo falha após
  salvar as credenciais e resumo final.
- `no_check_bucket = true` no `rclone.conf` gerado.
- RUNBOOK com a política IAM mínima em JSON e o uso de cada permissão.

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
- Menos I/O: diretórios arquivados no lugar, sem cópia para Work; payload em
  claro apagado antes da criptografia; retenção sem recalcular hashes; uma só
  leitura do pacote para SHA-256/MD5 e conferência remota por `rclone lsjson`.
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
