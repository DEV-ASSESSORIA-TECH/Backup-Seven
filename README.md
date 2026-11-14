# BackupSeven

Aplicação em PowerShell 7 que faz o backup do Seven em um servidor Windows: dump
lógico do banco MySQL e cópia da pasta Fiscal, compactados com 7-Zip, enviados
ao S3 pelo rclone e conferidos no destino. Substitui o processo legado em
arquivo batch.

Este documento descreve como o sistema funciona. Os procedimentos de operação
(instalar, atualizar, alterar agendamentos, restaurar) estão no
[`RUNBOOK.md`](RUNBOOK.md), que também acompanha o pacote. Os contratos internos
estão em [`ARCHITECTURE.md`](ARCHITECTURE.md).

## O que faz

- Executa `mysqldump` sem senha na linha de comando e valida exit code e
  conteúdo do dump; cada archive do banco leva um `manifest.json`.
- Se o dump normal falhar, publica um dump geral com `--force` e um dump por
  tabela e view (recuperação degradada, exit code `5`).
- Cria e testa (`7z test`) cada archive antes do envio.
- Envia com `rclone copyto` e confirma com `rclone check`; nunca executa
  `rclone sync` nem remove objetos remotos.
- Reenvia archives pendentes antes de criar um backup novo do mesmo tipo.
- Mantém retenção local por idade e um log por execução, também enviado ao S3.
- Impede execuções simultâneas por lock local.
- Gerencia as próprias tarefas agendadas a partir da configuração.
- Opcionalmente, publica o estado de cada backup para o Grafana Alloy.

PowerShell 7, 7-Zip, rclone, `mysql.exe` e `mysqldump.exe` são dependências
externas e não fazem parte do pacote.

## Modos

| Modo | Faz |
| --- | --- |
| `Database` | Dump do banco. |
| `Fiscal` | Archive da pasta Fiscal. |
| `Full` | Os dois. A falha de um não impede o outro; o resultado geral é falha. |

## Pacote

```text
BackupSeven-<versão>.zip
├── Backup-Seven.ps1            execução do backup (tarefas agendadas)
├── Setup-BackupSeven.ps1       setup e aplicação da configuração
├── Setup.bat                   setup interativo
├── Aplicar-Configuracao.bat    aplica config.psd1 (-Apply)
├── config.psd1                 modelo de configuração
├── Modules\
├── Secrets\                    modelos de credenciais (MySQL e rclone)
├── RUNBOOK.md
└── VERSION
```

`config.psd1` e `Secrets\` vêm como modelos com os nomes de produção e nunca
devem sobrescrever os de uma instalação existente.

## Configuração (`config.psd1`)

Lida a cada execução: mudanças valem na próxima, sem reinstalar. Só os
agendamentos precisam ser aplicados (`Aplicar-Configuracao.bat`).

| Seção | Chaves | Uso |
| --- | --- | --- |
| `InstanceName` | texto | Prefixo no S3 e nos nomes de archives e logs. |
| `Tools` | `MySqlDump`, `MySql`, `SevenZip`, `Rclone` | Executáveis externos. |
| `Database` | `Name`, `DefaultsExtraFile`, `ExtraArguments` | Banco, arquivo de opções do MySQL com a credencial e argumentos extras do mysqldump. |
| `Fiscal` | `SourcePath` | Pasta Fiscal. |
| `Storage` | `ConfigPath`, `RemoteRoot` | `rclone.conf` e destino `remote:bucket`. |
| `Archive` | `CompressionLevel`, `CpuLimitPercent` | Nível do 7-Zip (`-mx`) e percentual de processadores lógicos convertido em threads (`-mmt`, mínimo 1). Não é cota rígida de CPU. |
| `Paths` | `RuntimeRoot`, `CompletedRoot`, `LogRoot` | Pastas locais. |
| `Retention` | `CompletedDays`, `LogDays` | Retenção local por idade (mínimo 1 dia). |
| `Monitoring` | `Enabled`, `TextfileDirectory`, `Service`, `BackupIds`, `ExpectedIntervalHours` | Estado para o Grafana Alloy. Opcional. |
| `Schedule` | `Tasks` | Tarefas agendadas. Opcional. |

`Database.ExtraArguments` contém `--skip-events` porque a conta de backup não
tem a permissão `EVENT`: o dump não inclui eventos agendados do MySQL. Senhas e
`--force` não são aceitos nesse campo.

### Agendamentos (`Schedule`)

```powershell
Schedule = @{
    Tasks = @(
        '12:00'
        '19:00'
        @{ Mode = 'Database'; Frequency = 'Weekly'; Days = @('Saturday'); At = '03:00' }
    )
}
```

Cada item é um horário (`Full`, diário) ou uma hashtable com `At`, `Mode`
(`Full`, `Database`, `Fiscal`), `Frequency` (`Daily`, `Weekly`, `Monthly`),
`Days` (semanal, em inglês), `DaysOfMonth` (mensal, `1`-`31` ou `'Last'`),
`Name` e `Enabled`.

A configuração é a fonte da verdade. A aplicação (`Setup-BackupSeven.ps1
-Apply`):

- registra as tarefas na pasta `\BackupSeven\` do Agendador, com acesso só de
  SYSTEM e Administradores, executando como SYSTEM com
  `-ExecutionPolicy Bypass`;
- compara cada tarefa com a definição pela impressão digital gravada na
  descrição (`[cfg:...]`) e mostra um plano: criar, alterar, remover (tarefas
  da pasta que saíram da configuração e tarefas do BackupSeven fora da pasta,
  de versões anteriores);
- só altera depois de confirmação;
- avisa sobre tarefas no mesmo horário, que disputam o lock (exit code `3`).

O monitoramento deriva daí o intervalo esperado entre backups (maior intervalo
entre execuções que cobrem cada tipo; `Full` cobre os dois), salvo
`Monitoring.ExpectedIntervalHours` explícito.

## Credenciais e permissões

- **MySQL**: `Secrets\mysql-backup.cnf`, passado por `--defaults-extra-file`.
  Conta dedicada, só leitura.
- **S3**: `Secrets\rclone.conf`. A conta precisa gravar e consultar objetos; não
  precisa listar o bucket (`s3:ListBucket`).
- `Secrets\` fica restrita a SYSTEM e Administradores. Nenhuma credencial vai
  para `config.psd1`, argumentos de tarefa ou log.

## Artefatos

Nomes em UTC, únicos por execução:

```text
BackupSeven_<aaaa-mm-dd>_<HHmmss>Z_<Instância>_<Database|Fiscal>_<run>.7z
BackupSeven_<...>_Database_<run>_DEGRADED.7z
BackupSeven_<...>_Database_<run>_GRANULAR_DEGRADED.7z
BackupSevenLog_<aaaa-mm-dd>_<HHmmss>Z_<Instância>_<Modo>_<run>.log
```

Local:

```text
<raiz>\
├── Completed\Database|Fiscal\   confirmados no S3; participam da retenção
├── Runtime\
│   ├── Pending\                 válidos localmente, ainda não confirmados
│   ├── Work\<run>\              temporário da execução
│   └── BackupSeven.lock
└── Logs\
```

S3:

```text
<bucket>/<Instância>/<Database|Fiscal|Logs>/<aaaa>/<mm>/<dd>/<arquivo>
```

Um archive passa de `Pending` para `Completed` só depois de `copyto` e
`check`. `Pending` nunca é apagado pela retenção. Retenção remota, se desejada,
é uma Lifecycle Rule do bucket. As linhas dos logs usam a hora local do
servidor.

### Recuperação degradada

Se o dump normal falhar, o BackupSeven gera:

- `_DEGRADED.7z`: dump geral com `--force`;
- `_GRANULAR_DEGRADED.7z`: um `.sql` por tabela e view, e `<objeto>_FAILED.txt`
  para os que falharam.

Os dois levam o mesmo `manifest.json` com status `DEGRADED`, resultados e exit
codes. Publicados os dois, a execução termina com `5`; se só parte for
publicada, termina com `1`.

## Monitoramento

Com `Monitoring.Enabled = $true`, ao fim de cada pipeline o BackupSeven grava
`<Service>__<BackupId>.prom` (padrão `seven__database.prom` e
`seven__fiscal.prom`) em `TextfileDirectory`. O Grafana Alloy lê a pasta e
publica no job `integrations/backup`, no contrato genérico de backups
(`contracts/prometheus/backup.yml`, repositório `grafana`).

| Métrica | Valor |
| --- | --- |
| `backup_last_success_timestamp_seconds` | Ponto de recuperação (UTC do nome) do archive normal mais recente em `Completed`; `0` se nunca houve. |
| `backup_last_success_size_bytes` | Tamanho desse archive. |
| `backup_last_attempt_timestamp_seconds` | Fim da tentativa. |
| `backup_last_attempt_success` | `1` só com o archive confirmado no S3 no fluxo normal. |
| `backup_last_attempt_degraded` | `1` quando o banco foi publicado como `DEGRADED`. |
| `backup_last_attempt_duration_seconds` | Duração do pipeline. |
| `backup_expected_interval_seconds` | Derivado do `Schedule` ou de `ExpectedIntervalHours`. |
| `backup_collection_*` | Momento da gravação e se o estado pôde ser lido. |
| `backup_info` | `kind`, `producer`, `producer_version` e `site` (`InstanceName` em minúsculas). |

- O último sucesso também é lido do arquivo anterior, para não voltar a `0`
  quando a retenção local remove archives antigos.
- Exit code `2` com a configuração já lida grava tentativa falha; exit code `3`
  não grava.
- Falha ao gravar (pasta ausente, permissão) gera `WARN` no log e nunca altera
  o exit code.
- A pasta é criada pelo Alloy (perfil servidor). SYSTEM grava nela; outra conta
  precisa estar no grupo local `Alloy Backup Writers`.

## Exit codes

| Código | Significado |
| ---: | --- |
| 0 | Trabalho solicitado, reenvios pendentes e retenção concluídos. |
| 1 | Falha no dump, compactação, envio de backup ou log, ou validação remota. |
| 2 | Chamada, configuração, dependência, pasta ou permissão inválida. |
| 3 | Outra execução detém o lock. |
| 4 | Backups concluídos, mas limpeza ou retenção falhou. |
| 5 | Fallback completo do banco publicado como `DEGRADED`. |

## Desenvolvimento e distribuição

Modelos no repositório, com nomes que não se confundem com credenciais reais:

```text
src\config.example.psd1
src\Secrets\mysql-backup.example.cnf
src\Secrets\rclone.example.conf
```

```powershell
Invoke-Pester -Path .\tests      # Pester 5.7.1
.\scripts\package.ps1            # dist\BackupSeven-<VERSION>.zip + .sha256
```

O pacote é montado por lista fechada de arquivos e validado após a criação. O
CI executa parsing, PSScriptAnalyzer, Pester e empacotamento; o release é manual
e usa `VERSION`, com entrada obrigatória no `CHANGELOG.md`. `README.md`,
`ARCHITECTURE.md` e `CHANGELOG.md` ficam só no repositório.
