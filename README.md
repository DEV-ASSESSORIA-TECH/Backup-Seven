# BackupSeven

O BackupSeven substitui o antigo processo de backup em arquivo batch por uma
aplicação pequena em PowerShell 7. Ele cria backups lógicos do banco do Seven,
compacta a pasta `C:\Seven Sistemas\Fiscal` e envia os arquivos `.7z` validados
por meio do rclone.

> A versão 0.1.0 está pronta para homologação. Antes do uso em produção, valide
> o dump, a restauração e os arquivos Fiscal no ambiente real do Seven.

## Princípios operacionais

- PowerShell 7 é obrigatório.
- 7-Zip, rclone e mysqldump são instalados separadamente.
- Executáveis de terceiros nunca são armazenados neste repositório ou no ZIP.
- Credenciais locais nunca são commitadas ou incluídas em uma versão.
- Cada backup só é concluído depois de criado, compactado, validado, enviado e
  validado remotamente.
- O envio usa `rclone copyto`; o BackupSeven nunca usa `rclone sync`.
- Somente um processo do BackupSeven pode executar por vez.

## Instalação

Extraia o pacote em:

```text
C:\TI\SCRIPTS\BackupSeven
```

O ZIP contém somente:

```text
Backup-Seven.ps1
Modules\
config.example.psd1
README.md
VERSION
```

Depois da extração:

1. Copie `config.example.psd1` para `config.psd1`.
2. Ajuste os caminhos dos três executáveis e o nome do banco.
3. Configure o remote S3 do rclone em um arquivo externo.
4. Crie o arquivo externo de opções do MySQL.
5. Restrinja os arquivos de credenciais com ACLs NTFS.
6. Execute manualmente cada modo antes de criar os agendamentos.

Exemplo mínimo do arquivo de opções do MySQL:

```ini
[client]
user=backup_user
password=alterar-no-servidor
host=127.0.0.1
```

Esse arquivo é indicado por `Database.DefaultsExtraFile`. A senha não deve ser
adicionada ao `config.psd1` nem a `Database.ExtraArguments`.

## Execução

```powershell
pwsh.exe -NoLogo -NoProfile -NonInteractive `
  -File "C:\TI\SCRIPTS\BackupSeven\Backup-Seven.ps1" `
  -Mode Database
```

Modos disponíveis:

- `Database`: reenviar pendências do banco e criar um novo backup do banco.
- `Fiscal`: reenviar pendências Fiscal e criar um novo backup da pasta.
- `Full`: executar os dois pipelines independentemente.

Use `-ConfigPath` somente quando o arquivo não estiver ao lado do script.

## Diretórios e retenção

O diretório configurado em `Paths.RuntimeRoot` é criado automaticamente:

- `Pending`: archives válidos que ainda não foram confirmados no S3;
- `Completed`: archives enviados e confirmados;
- `Work`: temporários da execução atual;
- `Logs`: um arquivo UTF-8 por execução.

Uma nova execução tenta reenviar as pendências dos tipos selecionados. A
retenção local remove somente archives em `Completed`. Os valores de retenção
devem ser de pelo menos um dia. O BackupSeven não aplica retenção remota.

## Exit codes

| Código | Significado |
| ---: | --- |
| 0 | Execução concluída. |
| 1 | Falha no dump, compactação, envio ou validação remota. |
| 2 | Argumento, configuração, dependência ou permissão inválida. |
| 3 | Outra execução já está ativa. |
| 4 | Backup concluído, mas limpeza ou retenção falhou. |

## Agendador de Tarefas

Crie tarefas separadas para `Database` e `Fiscal`. Configure:

- programa: caminho completo do `pwsh.exe` do PowerShell 7;
- argumentos: `-NoLogo -NoProfile -NonInteractive -File ... -Mode Database` ou
  `-Mode Fiscal`;
- opção "Executar independentemente de o usuário estar conectado";
- conta com acesso ao banco, pasta Fiscal, runtime e credenciais;
- política do Agendador para não iniciar outra instância da mesma tarefa.

O lock interno também impede sobreposição entre tarefas de modos diferentes.

## Desenvolvimento e distribuição

Execute os testes com Pester 5.7.1:

```powershell
Invoke-Pester -Path .\tests
```

Gere o pacote com:

```powershell
.\scripts\package.ps1
```

O resultado será `dist\BackupSeven-<VERSION>.zip`. O CI valida parsing,
PSScriptAnalyzer, testes e pacote. O workflow manual de release cria a tag
`v<VERSION>`, publica a GitHub Release e anexa o ZIP e seu SHA256.

No repositório fonte, `ARCHITECTURE.md` contém os contratos detalhados e
`CHANGELOG.md` registra o histórico de versões. Esses documentos não fazem parte
do pacote enxuto de produção.
