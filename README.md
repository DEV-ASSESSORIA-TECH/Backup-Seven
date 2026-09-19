# BackupSeven

O BackupSeven substitui o processo legado em arquivo batch por uma aplicação
pequena em PowerShell 7. Ele cria o dump lógico do banco do Seven, compacta o
dump e a pasta Fiscal com 7-Zip, envia os artefatos e o log final para o S3 por
meio do rclone e mantém retenção local por idade.

## O que a aplicação faz

- Executa `mysql.exe` e `mysqldump.exe` sem colocar a senha na linha de comando.
- Valida exit code e conteúdo não vazio do dump e gera um manifesto JSON.
- Se o dump normal falhar, preserva um dump com `--force` e tenta cada tabela e
  view separadamente.
- Cria e testa archives `.7z` antes do envio.
- Executa os modos independentes `Database`, `Fiscal` e `Full`.
- Envia cada arquivo com `rclone copyto` e confirma com `rclone check`.
- Reenvia archives pendentes antes de criar um backup novo do mesmo tipo.
- Registra um log UTF-8 por execução e também o envia ao S3.
- Nunca executa `rclone sync` nem remove objetos remotos.
- Impede duas execuções simultâneas por meio de um lock local.

PowerShell 7, 7-Zip, rclone, mysql e mysqldump são dependências externas. Nenhum desses
executáveis é incluído no pacote.

## Conteúdo do pacote

O ZIP de produção contém somente:

```text
BackupSeven-0.2.1.zip
├── Backup-Seven.ps1
├── config.psd1
├── Modules\
├── Secrets\
│   ├── mysql-backup.cnf
│   └── rclone.conf
├── README.md
└── VERSION
```

`config.psd1`, `Secrets\mysql-backup.cnf` e `Secrets\rclone.conf` são modelos
distribuídos já com os nomes usados em produção. Eles precisam ser revisados e
ter seus marcadores substituídos antes do uso. Os modelos versionados não contêm
credenciais reais.

## 1. Pré-requisitos

Instale ou confirme:

- PowerShell 7;
- 7-Zip;
- rclone;
- `mysql.exe` e `mysqldump.exe` compatíveis com o servidor MySQL do Seven;
- bucket S3 `assessoriatech-backups-seven-prod` já criado;
- conta Windows para executar a tarefa agendada sem usuário conectado.

Caminhos esperados inicialmente:

```text
C:\Program Files\PowerShell\7\pwsh.exe
C:\Program Files\7-Zip\7z.exe
C:\Program Files\MySQL\MySQL Server 5.5\bin\mysqldump.exe
C:\Program Files\MySQL\MySQL Server 5.5\bin\mysql.exe
C:\Program Files\rclone\rclone.exe
```

Ajuste `config.psd1` se algum executável estiver em outro local.

## 2. Instalação inicial

Extraia o ZIP em:

```text
C:\TI\Scripts\BackupSeven
```

Depois da extração, a instalação terá inicialmente:

```text
C:\TI\Scripts\BackupSeven\
├── Backup-Seven.ps1
├── config.psd1
├── Modules\
├── Secrets\
│   ├── mysql-backup.cnf
│   └── rclone.conf
├── README.md
└── VERSION
```

O script criará `Runtime`, `Completed` e `Logs` na primeira execução.

## 3. Configuração principal

Abra `config.psd1` e revise todas as seções. A configuração fornecida parte dos
dados conhecidos da instalação atual:

```powershell
@{
    InstanceName = 'MULTI-COPIAS'

    Tools = @{
        MySqlDump = 'C:\Program Files\MySQL\MySQL Server 5.5\bin\mysqldump.exe'
        MySql     = 'C:\Program Files\MySQL\MySQL Server 5.5\bin\mysql.exe'
        SevenZip   = 'C:\Program Files\7-Zip\7z.exe'
        Rclone     = 'C:\Program Files\rclone\rclone.exe'
    }

    Database = @{
        Name              = 'a_estoque'
        DefaultsExtraFile = 'C:\TI\Scripts\BackupSeven\Secrets\mysql-backup.cnf'
        ExtraArguments    = @(
            '--skip-events'
        )
    }

    Fiscal = @{
        SourcePath = 'C:\Seven Sistemas\Fiscal'
    }

    Storage = @{
        ConfigPath = 'C:\TI\Scripts\BackupSeven\Secrets\rclone.conf'
        RemoteRoot = 's3:assessoriatech-backups-seven-prod'
    }

    Archive = @{
        CompressionLevel = 5
        CpuLimitPercent  = 50
    }

    Paths = @{
        RuntimeRoot = 'C:\TI\Scripts\BackupSeven\Runtime'
        CompletedRoot = 'C:\TI\Scripts\BackupSeven\Completed'
        LogRoot     = 'C:\TI\Scripts\BackupSeven\Logs'
    }

    Retention = @{
        CompletedDays = 7
        LogDays       = 30
    }
}
```

O nome `s3` em `RemoteRoot` deve ser exatamente o nome escolhido para o remote
do rclone.

## 4. Credencial do banco

O arquivo `mysql-backup.cnf` não é gerado pelo MySQL. O pacote fornece apenas a
estrutura, e o administrador deve preenchê-la manualmente:

```ini
[client]
host=192.168.1.14
port=3306
user=backup_seven
password=SUBSTITUIR_POR_SENHA_REAL
```

Use preferencialmente uma conta exclusiva para backup, não `root`. Ela precisa
conseguir ler as tabelas e incluir views, triggers, routines e events usados
pelo banco. As permissões devem ser confirmadas no MySQL 5.5 do ambiente.

Na configuração fornecida, `--skip-events` evita que a ausência da permissão
`EVENT` interrompa o dump. Isso significa que os eventos agendados do MySQL não
estarão no arquivo de backup. Remova essa opção somente se a conta receber a
permissão necessária e um teste real confirmar o dump com os eventos.

O arquivo contém a senha em texto legível. Restrinja suas permissões NTFS à
conta da tarefa agendada e aos administradores autorizados. Não coloque a senha
em `config.psd1`, `Database.ExtraArguments`, scripts ou argumentos da tarefa.

O BackupSeven passa o arquivo ao mysql e ao mysqldump por
`--defaults-extra-file`, rejeita senhas e `--force` nos argumentos adicionais e
não registra o conteúdo do arquivo de credenciais no log.

## 5. Configuração do rclone e S3

O pacote já fornece `Secrets\rclone.conf` com a seção `s3`, a região
`sa-east-1` e marcadores para as credenciais. Substitua:

```ini
access_key_id = REPLACE_WITH_AWS_ACCESS_KEY_ID
secret_access_key = REPLACE_WITH_AWS_SECRET_ACCESS_KEY
```

Se preferir recriar ou editar o arquivo pelo próprio rclone, execute:

```powershell
& 'C:\Program Files\rclone\rclone.exe' config `
  --config 'C:\TI\Scripts\BackupSeven\Secrets\rclone.conf'
```

No assistente do rclone:

1. Crie um novo remote.
2. Use o nome `s3` ou altere `Storage.RemoteRoot` para o nome escolhido.
3. Selecione o tipo Amazon S3 e o provedor AWS.
4. Informe a Access Key, Secret Key e região da credencial de backup.
5. Mantenha o acesso privado e conclua a configuração.

A credencial AWS deve ter somente as permissões necessárias para gravar e
consultar objetos no bucket/prefixo do BackupSeven. Proteja `rclone.conf` com as
mesmas ACLs NTFS aplicadas ao arquivo do MySQL.

Teste o acesso antes de executar o backup:

```powershell
& 'C:\Program Files\rclone\rclone.exe' lsf `
  's3:assessoriatech-backups-seven-prod' `
  --config 'C:\TI\Scripts\BackupSeven\Secrets\rclone.conf' `
  --max-depth 1
```

Se o `rclone.conf` estiver criptografado, a conta agendada também precisará
receber a senha de descriptografia de maneira não interativa. Para a instalação
inicial mais simples, mantenha o arquivo protegido por ACL NTFS e valide o
acesso usando exatamente a conta da tarefa.

## 6. Teste manual

Abra o PowerShell 7 como a conta que executará o agendamento e teste primeiro o
banco:

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' `
  -NoLogo -NoProfile -NonInteractive `
  -File 'C:\TI\Scripts\BackupSeven\Backup-Seven.ps1' `
  -Mode Database
```

Depois teste o Fiscal:

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' `
  -NoLogo -NoProfile -NonInteractive `
  -File 'C:\TI\Scripts\BackupSeven\Backup-Seven.ps1' `
  -Mode Fiscal
```

Por fim, `-Mode Full` pode ser usado para uma execução manual completa. Cada
tipo é tratado de forma independente; no modo `Full`, uma falha no banco não
impede a tentativa do Fiscal, mas o resultado geral será uma falha.

Após os testes, confirme:

- exit code `0`;
- archive presente em `Completed\Database` ou `Completed\Fiscal`;
- nenhum archive em `Runtime\Pending`;
- arquivo legível em `Logs`;
- archive e log presentes no S3;
- abertura do `.7z` e restauração do dump em ambiente controlado.

## 7. Organização local e remota

Localmente:

```text
C:\TI\Scripts\BackupSeven\
├── Completed\
│   ├── Database\
│   │   └── BackupSeven_2026-09-01_143000Z_MULTI-COPIAS_Database_a1b2c3d4.7z
│   └── Fiscal\
├── Runtime\
│   ├── Pending\
│   ├── Work\
│   └── BackupSeven.lock
└── Logs\
    └── BackupSevenLog_2026-09-01_220000Z_MULTI-COPIAS_Fiscal_e5f6a7b8.log
```

No S3:

```text
assessoriatech-backups-seven-prod/
└── MULTI-COPIAS/
    ├── Database/2026/09/01/
    │   └── BackupSeven_2026-09-01_143000Z_MULTI-COPIAS_Database_a1b2c3d4.7z
    ├── Fiscal/2026/09/01/
    │   └── BackupSeven_2026-09-01_220000Z_MULTI-COPIAS_Fiscal_e5f6a7b8.7z
    └── Logs/2026/09/01/
        └── BackupSevenLog_2026-09-01_220000Z_MULTI-COPIAS_Fiscal_e5f6a7b8.log
```

Datas e horários presentes nos nomes são UTC. As linhas internas dos logs usam
a hora local vigente do servidor no formato `yyyy-MM-dd HH:mm:ss`, por exemplo:

```text
2026-09-04 13:44:45 [INFO] [e5f6a7b8...] [Fiscal/Upload] mensagem
```

### Recuperação degradada do banco

Todo archive de banco contém `manifest.json`. No fluxo normal, seu status é
`SUCCESS` e o archive também contém o dump geral. Se esse dump falhar, o
BackupSeven executa um novo dump com `--force` e tenta todas as tabelas e views
individualmente. O resultado completo do fallback produz:

```text
Completed\Database\
├── BackupSeven_<...>_Database_<run>_DEGRADED.7z
└── BackupSeven_<...>_Database_<run>_GRANULAR_DEGRADED.7z
```

O primeiro contém o SQL geral recuperável. O segundo contém
`Granular\<banco>\<objeto>.sql`; objetos que falharam recebem
`<objeto>_FAILED.txt` com nome, tipo, erro e timestamp. Os dois archives contêm
o mesmo manifesto `DEGRADED`, com os resultados e exit codes. Eles continuam
sendo armazenados no prefixo diário normal do banco no S3.

Um fallback completo e publicado retorna exit code `5`. Se apenas parte puder
ser criada ou publicada, o material válido é preservado, mas a execução retorna
`1`. Archives cujo upload não foi confirmado permanecem em `Runtime\Pending`.

## 8. Compactação e uso de processador

`CompressionLevel = 5` corresponde ao nível normal do 7-Zip. Ele altera o
equilíbrio entre tempo, memória e tamanho do archive, não a integridade do
conteúdo. O BackupSeven ainda executa `7z test` e só prossegue se o archive for
válido.

`CpuLimitPercent = 50` converte o percentual em aproximadamente metade dos
processadores lógicos e passa esse número ao 7-Zip. O mínimo é uma thread. Esse
controle limita o paralelismo da compactação, mas não é uma cota rígida do
Windows e não limita o mysqldump nem o rclone. Por isso, confirme o consumo real
no servidor durante a homologação.

## 9. Retenção e novas tentativas

- `CompletedDays` remove por idade somente archives já confirmados no S3.
- `LogDays` remove logs locais por idade.
- A idade vem do timestamp UTC controlado no nome do arquivo.
- Archives em `Pending` nunca são removidos automaticamente.
- `Work` é temporário e removido ao final da execução.
- O log atual nunca é removido pela própria execução.
- O BackupSeven não remove arquivos do S3; configure retenção remota por uma
  Lifecycle Rule no bucket, se necessário.

Uma nova execução tenta reenviar archives pendentes dos tipos selecionados. Se
o envio do log falhar, a execução retorna erro e preserva o log local, mas não
mantém uma fila separada para reenvio de logs antigos.

## 10. Agendador de Tarefas

No ambiente atual, crie duas tarefas independentes em modo `Full`: uma às
12:00 e outra às 19:00.

Configuração recomendada para cada ação:

```text
Programa:
C:\Program Files\PowerShell\7\pwsh.exe

Argumentos Full:
-NoLogo -NoProfile -NonInteractive -File "C:\TI\Scripts\BackupSeven\Backup-Seven.ps1" -Mode Full

Iniciar em:
C:\TI\Scripts\BackupSeven
```

Como alternativa, use execuções separadas por modo:

```
Argumentos Database:
-NoLogo -NoProfile -NonInteractive -File "C:\TI\Scripts\BackupSeven\Backup-Seven.ps1" -Mode Database

Argumentos Fiscal:
-NoLogo -NoProfile -NonInteractive -File "C:\TI\Scripts\BackupSeven\Backup-Seven.ps1" -Mode Fiscal

```

Nas opções da tarefa:

- selecione “Executar independentemente de o usuário estar conectado”;
- use uma conta com acesso ao MySQL, Fiscal, Runtime, Logs e Secrets;
- habilite execução com privilégios adequados ao ambiente;
- configure para não iniciar uma segunda instância da mesma tarefa;
- registre no Agendador o código de retorno da execução.

O lock interno também impede sobreposição entre tarefas de modos diferentes.

Para cadastrar as duas tarefas `Full` como `SYSTEM`, execute o exemplo abaixo
em um PowerShell elevado. Antes, confirme que `SYSTEM` possui acesso aos
diretórios e arquivos de credenciais usados pelo BackupSeven.

```powershell
$TaskPath = "\ASSESSORIA SCRIPTS\"
$ScriptPath = "C:\TI\Scripts\BackupSeven\Backup-Seven.ps1"
$WorkingDir = "C:\TI\Scripts\BackupSeven"
$Pwsh = "C:\Program Files\PowerShell\7\pwsh.exe"

# Cria a pasta no Agendador de Tarefas, caso ainda não exista
$Scheduler = New-Object -ComObject "Schedule.Service"
$Scheduler.Connect()
$RootFolder = $Scheduler.GetFolder("\")

try {
    $RootFolder.GetFolder("\ASSESSORIA SCRIPTS") | Out-Null
}
catch {
    $RootFolder.CreateFolder("ASSESSORIA SCRIPTS") | Out-Null
}

# Ação executada pelas duas tarefas
$Action = New-ScheduledTaskAction `
    -Execute $Pwsh `
    -Argument "-NoLogo -NoProfile -NonInteractive -File `"$ScriptPath`" -Mode Full" `
    -WorkingDirectory $WorkingDir

# Configurações
$Settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew

# Executar como SYSTEM, com privilégios elevados
$Principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

# 12:00
$Trigger1200 = New-ScheduledTaskTrigger `
    -Daily `
    -At "12:00"

Register-ScheduledTask `
    -TaskName "BackupSeven - Full - 12h00" `
    -TaskPath $TaskPath `
    -Action $Action `
    -Trigger $Trigger1200 `
    -Settings $Settings `
    -Principal $Principal `
    -Description "Backup completo do Seven - Database + Fiscal - 12:00" `
    -Force

# 19:00
$Trigger1900 = New-ScheduledTaskTrigger `
    -Daily `
    -At "19:00"

Register-ScheduledTask `
    -TaskName "BackupSeven - Full - 19h00" `
    -TaskPath $TaskPath `
    -Action $Action `
    -Trigger $Trigger1900 `
    -Settings $Settings `
    -Principal $Principal `
    -Description "Backup completo do Seven - Database + Fiscal - 19:00" `
    -Force
```

## 11. Exit codes e diagnóstico

| Código | Significado |
| ---: | --- |
| 0 | Backup, upload, validação, limpeza e retenção concluídos. |
| 1 | Falha no dump, compactação, upload de backup/log ou validação remota. |
| 2 | Configuração, dependência, caminho ou permissão inválida. |
| 3 | Outra execução do BackupSeven já está ativa. |
| 4 | Backups concluídos, mas limpeza ou retenção falhou. |
| 5 | Os dois archives de recuperação degradada do banco foram publicados; requer atenção operacional. |

Ao investigar uma falha:

1. Abra o log mais recente em `C:\TI\Scripts\BackupSeven\Logs`.
2. Identifique a etapa entre colchetes, como `Database/Dump` ou `Log/Upload`.
3. Confirme os caminhos e as permissões executando como a conta agendada.
4. Teste separadamente mysqldump, 7-Zip e rclone quando a etapa indicar uma
   dependência externa.
5. Não apague arquivos de `Pending` antes de entender a falha.

## 12. Atualização de versão

O pacote contém modelos chamados `config.psd1`, `mysql-backup.cnf` e
`rclone.conf`. Em uma atualização, não extraia o ZIP por cima da instalação sem
preservar:

```text
config.psd1
Secrets\mysql-backup.cnf
Secrets\rclone.conf
Runtime\
Logs\
Completed\
```

Ao adotar esta versão, adicione `Tools.MySql` e `Paths.CompletedRoot` ao arquivo
de configuração existente. A aplicação não move automaticamente os archives
antigos de `Runtime\Completed`; faça essa migração manualmente antes de remover
a pasta antiga.

Compare o novo modelo com a configuração existente e substitua somente scripts,
módulos, README e VERSION. Credenciais reais nunca devem ser copiadas de volta
para o repositório.

## Desenvolvimento e distribuição

No repositório, os modelos continuam com nomes explícitos para evitar que sejam
confundidos com credenciais reais:

```text
src\config.example.psd1
src\Secrets\mysql-backup.example.cnf
src\Secrets\rclone.example.conf
```

Execute os testes com Pester 5.7.1:

```powershell
Invoke-Pester -Path .\tests
```

Gere o pacote com:

```powershell
.\scripts\package.ps1
```

O resultado é `dist\BackupSeven-<VERSION>.zip` acompanhado de
`BackupSeven-<VERSION>.zip.sha256`. O CI valida parsing, PSScriptAnalyzer,
testes, pacote e checksum. `ARCHITECTURE.md` e `CHANGELOG.md` permanecem apenas
no repositório.
