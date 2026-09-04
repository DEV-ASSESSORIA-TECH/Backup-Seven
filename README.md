# BackupSeven

O BackupSeven substitui o processo legado em arquivo batch por uma aplicação
pequena em PowerShell 7. Ele cria o dump lógico do banco do Seven, compacta o
dump e a pasta Fiscal com 7-Zip, envia os artefatos e o log final para o S3 por
meio do rclone e mantém retenção local por idade.

> A versão 0.2.0 deve ser homologada com um backup e uma restauração reais antes
> de entrar no agendamento de produção.

## O que a aplicação faz

- Executa o mysqldump sem colocar a senha na linha de comando.
- Valida exit code e conteúdo não vazio do dump.
- Cria e testa archives `.7z` antes do envio.
- Executa os modos independentes `Database`, `Fiscal` e `Full`.
- Envia cada arquivo com `rclone copyto` e confirma com `rclone check`.
- Reenvia archives pendentes antes de criar um backup novo do mesmo tipo.
- Registra um log UTF-8 por execução e também o envia ao S3.
- Nunca executa `rclone sync` nem remove objetos remotos.
- Impede duas execuções simultâneas por meio de um lock local.

PowerShell 7, 7-Zip, rclone e mysqldump são dependências externas. Nenhum desses
executáveis é incluído no pacote.

## Conteúdo do pacote

O ZIP de produção contém somente:

```text
BackupSeven-0.2.0.zip
├── Backup-Seven.ps1
├── config.psd1
├── Modules\
├── Secrets\
│   └── mysql-backup.cnf
├── README.md
└── VERSION
```

`config.psd1` e `Secrets\mysql-backup.cnf` são modelos distribuídos já com os
nomes usados em produção. Eles ainda precisam ser revisados e preenchidos. O
`rclone.conf` não é distribuído porque é criado pelo próprio rclone e contém a
credencial AWS.

## 1. Pré-requisitos

Instale ou confirme:

- PowerShell 7;
- 7-Zip;
- rclone;
- mysqldump compatível com o servidor MySQL do Seven;
- bucket S3 `assessoriatech-backups-seven-prod` já criado;
- conta Windows para executar a tarefa agendada sem usuário conectado.

Caminhos esperados inicialmente:

```text
C:\Program Files\PowerShell\7\pwsh.exe
C:\Program Files\7-Zip\7z.exe
C:\Program Files\MySQL\MySQL Server 5.5\bin\mysqldump.exe
C:\TI\TOOLS\rclone\rclone.exe
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
│   └── mysql-backup.cnf
├── README.md
└── VERSION
```

O script criará `Runtime` e `Logs` na primeira execução.

## 3. Configuração principal

Abra `config.psd1` e revise todas as seções. A configuração fornecida parte dos
dados conhecidos da instalação atual:

```powershell
@{
    InstanceName = 'MULTI-COPIAS'

    Tools = @{
        MySqlDump = 'C:\Program Files\MySQL\MySQL Server 5.5\bin\mysqldump.exe'
        SevenZip   = 'C:\Program Files\7-Zip\7z.exe'
        Rclone     = 'C:\TI\TOOLS\rclone\rclone.exe'
    }

    Database = @{
        Name              = 'a_estoque'
        DefaultsExtraFile = 'C:\TI\Scripts\BackupSeven\Secrets\mysql-backup.cnf'
        ExtraArguments    = @()
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
    }

    Paths = @{
        RuntimeRoot = 'C:\TI\Scripts\BackupSeven\Runtime'
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

O arquivo contém a senha em texto legível. Restrinja suas permissões NTFS à
conta da tarefa agendada e aos administradores autorizados. Não coloque a senha
em `config.psd1`, `Database.ExtraArguments`, scripts ou argumentos da tarefa.

O BackupSeven passa o arquivo ao mysqldump por `--defaults-extra-file`, rejeita
senhas nos argumentos adicionais e não registra seu conteúdo no log.

## 5. Configuração do rclone e S3

Crie o arquivo no caminho que o BackupSeven utilizará:

```powershell
& 'C:\TI\TOOLS\rclone\rclone.exe' config `
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
& 'C:\TI\TOOLS\rclone\rclone.exe' lsf `
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
- archive presente em `Runtime\Completed`;
- nenhum archive em `Runtime\Pending`;
- arquivo legível em `Logs`;
- archive e log presentes no S3;
- abertura do `.7z` e restauração do dump em ambiente controlado.

## 7. Organização local e remota

Localmente:

```text
C:\TI\Scripts\BackupSeven\
├── Runtime\
│   ├── Pending\
│   ├── Completed\
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
o offset local do servidor.

## 8. Retenção e novas tentativas

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

## 9. Agendador de Tarefas

Crie duas tarefas independentes: uma para `Database`, duas vezes ao dia, e uma
para `Fiscal`, uma vez ao dia.

Configuração recomendada para cada ação:

```text
Programa:
C:\Program Files\PowerShell\7\pwsh.exe

Argumentos Database:
-NoLogo -NoProfile -NonInteractive -File "C:\TI\Scripts\BackupSeven\Backup-Seven.ps1" -Mode Database

Argumentos Fiscal:
-NoLogo -NoProfile -NonInteractive -File "C:\TI\Scripts\BackupSeven\Backup-Seven.ps1" -Mode Fiscal

Iniciar em:
C:\TI\Scripts\BackupSeven
```

Nas opções da tarefa:

- selecione “Executar independentemente de o usuário estar conectado”;
- use uma conta com acesso ao MySQL, Fiscal, Runtime, Logs e Secrets;
- habilite execução com privilégios adequados ao ambiente;
- configure para não iniciar uma segunda instância da mesma tarefa;
- registre no Agendador o código de retorno da execução.

O lock interno também impede sobreposição entre tarefas de modos diferentes.

## 10. Exit codes e diagnóstico

| Código | Significado |
| ---: | --- |
| 0 | Backup, upload, validação, limpeza e retenção concluídos. |
| 1 | Falha no dump, compactação, upload de backup/log ou validação remota. |
| 2 | Configuração, dependência, caminho ou permissão inválida. |
| 3 | Outra execução do BackupSeven já está ativa. |
| 4 | Backups concluídos, mas limpeza ou retenção falhou. |

Ao investigar uma falha:

1. Abra o log mais recente em `C:\TI\Scripts\BackupSeven\Logs`.
2. Identifique a etapa entre colchetes, como `Database/Dump` ou `Log/Upload`.
3. Confirme os caminhos e as permissões executando como a conta agendada.
4. Teste separadamente mysqldump, 7-Zip e rclone quando a etapa indicar uma
   dependência externa.
5. Não apague arquivos de `Pending` antes de entender a falha.

## 11. Atualização de versão

O pacote contém modelos chamados `config.psd1` e `mysql-backup.cnf`. Em uma
atualização, não extraia o ZIP por cima da instalação sem preservar:

```text
config.psd1
Secrets\mysql-backup.cnf
Secrets\rclone.conf
Runtime\
Logs\
```

Compare o novo modelo com a configuração existente e substitua somente scripts,
módulos, README e VERSION. Credenciais reais nunca devem ser copiadas de volta
para o repositório.

## Desenvolvimento e distribuição

No repositório, os modelos continuam com nomes explícitos para evitar que sejam
confundidos com credenciais reais:

```text
src\config.example.psd1
src\Secrets\mysql-backup.example.cnf
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
