# Histórico de alterações

Todas as alterações relevantes do BackupSeven são registradas neste arquivo. O
projeto usa as versões semânticas definidas em `VERSION` e as principais seções
do Keep a Changelog, sem exigir todas as seções em cada versão.

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
