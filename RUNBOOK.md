# DBBackup — runbook v2.0.0

## Conceitos

- **Instância**: contexto operacional — credenciais S3 (`rclone.conf`),
  destinatários age, agenda, lock e pastas. Uma pasta em `Instances\<instância>`.
- **Job**: uma fonte de backup com provedor (MySQL, SQL Anywhere ou Diretório) e
  destino S3 próprios. Uma instância pode ter qualquer combinação de jobs,
  inclusive só pastas.
- **Tarefa**: agendamento que executa um ou mais jobs da instância, em sequência.

## Dependências e instalação

Windows e PowerShell 7.2+ (instalador MSI; o da Microsoft Store fica em caminho
que a tarefa SYSTEM pode não executar). 7-Zip, age e rclone instalados
separadamente. MySQL precisa de mysql/mysqldump 5.x compatíveis com a origem.
SQL Anywhere precisa somente de dbbackup 17 e suas bibliotecas; `dbping.exe` na
mesma pasta é usado pelo teste de conexão do setup, se existir. O DBBackup não
instala dependências.

1. Confira o SHA-256 do ZIP contra o `.zip.sha256`.
2. Extraia, por exemplo, em `C:\TI\Scripts\DBBackup`.
3. Execute `Setup.bat` (pede elevação).

```text
DBBackup\
  Setup.bat, Aplicar-Configuracao.bat, Diagnosticar.bat, Executar-Backup.bat
  LEIA-ME.txt                         versão instalada e links
  App\                                scripts, módulos, modelo, VERSION
  Instances\<instância>\
    config.psd1                        editável (ACL herdada da pasta)
    Secrets\                          restrita a SYSTEM e Administradores
    Runtime\                          restrita (trabalho temporário, pendências)
  Completed\<instância>\<job>\        pacotes criptografados locais
  Logs\<instância>\                    um log por execução
```

Os `.bat` usam `%ProgramFiles%\PowerShell\7\pwsh.exe` ou, se não existir, o
`pwsh.exe` do PATH. `Executar-Backup.bat` e `Diagnosticar.bat` pedem o caminho
do `config.psd1` (aceitam o caminho colado com aspas).

## Setup guiado

O `Setup.bat` pergunta e valida cada resposta na hora:

1. **Nome da instância** (ex.: `assessoria`). Se já existir uma configuração 2.0,
   o setup oferece adicionar jobs ou apenas reaplicar. Uma configuração 1.x é
   guardada como `config.v1.psd1` e uma nova é criada.
2. **Executáveis** 7z, age e rclone (com sugestão do que estiver instalado). Os
   do banco são pedidos ao adicionar o primeiro job daquele provedor.
3. **Credenciais S3** (`Secrets\rclone.conf`) e **destinatários age**
   (`Secrets\recipients.txt`). Se já existirem, o setup pergunta se mantém; um
   arquivo recusado é guardado como `<nome>.old`.
4. **Jobs**, pelo menu `1 = MySQL, 2 = SQL Anywhere, 3 = Diretório`:
   - banco: credencial já existente em `Secrets` (`*.cnf` para MySQL,
     `*.options` para SQL Anywhere) é oferecida para reaproveitamento; senão o
     setup pede host/porta (ou servidor local), usuário e senha e grava
     `Secrets\<job>.cnf`/`.options`;
   - diretório: pasta de origem (caminho completo, fora da instância);
   - identificador do job (pasta no S3 e no Completed), bucket e prefixo
     (Enter mantém a sugestão; `/` usa a raiz do bucket) e horário diário.
   Ao concluir sem nenhum job de diretório, o setup pergunta se deseja
   adicionar backup de pasta.
5. **Agenda**: jobs com o mesmo horário entram na mesma tarefa (`diario-HHmm`)
   e rodam em sequência.
6. **Teste opcional, somente leitura**: login em cada banco, existência de cada
   pasta e listagem de cada destino S3. Nada é gravado no bucket.
7. **Diagnóstico local**, plano das tarefas (confirmar com `SIM`) e resumo com
   os jobs, destinos e o comando do primeiro backup.

Para reaproveitar credenciais de uma instalação anterior, copie os arquivos para
`Instances\<instância>\Secrets\` antes de rodar o setup. Se algo falhar depois
de salvar as credenciais, o setup indica o `Aplicar-Configuracao.bat` com o
caminho do `config.psd1`; nada precisa ser digitado de novo.

## Permissões

Somente `Secrets` e `Runtime` são restritas a SYSTEM e Administradores:
`Secrets` tem senhas e chaves em texto; `Runtime` tem dumps sem criptografia
durante a execução e pacotes pendentes. A pasta da instância e o `config.psd1`
herdam a permissão da instalação e podem ser editados sem elevação; o setup
restaura essa herança em instâncias criadas pela 1.x. `Completed` (pacotes
criptografados) e `Logs` (sem senhas) são pastas de operação, com a permissão
herdada. Uma execução nunca altera permissões de pastas existentes; o Apply
recusa um `Runtime` existente com conteúdo e permissões de terceiros.

## Configuração (`config.psd1`, schema 2)

```powershell
@{
    SchemaVersion = 2
    InstanceName = 'assessoria'
    Tools = @{ SevenZip = '...\7z.exe'; Age = '...\age.exe'; Rclone = '...\rclone.exe'
               MySql = '...\mysql.exe'; MySqlDump = '...\mysqldump.exe'; DbBackup = '...\dbbackup.exe' }
    Jobs = @(
        @{ Id = 'seven'; Provider = 'MySQL'; Database = 'a_estoque'; CredentialFile = 'Secrets/seven.cnf'
           ExtraArguments = @('--skip-events'); RemoteRoot = 's3:assessoriatech-backups-seven-prod/ASSESSORIA' }
        @{ Id = 'dominio'; Provider = 'SQLAnywhere'; Database = 'contabil'; CredentialFile = 'Secrets/dominio.options'
           RemoteRoot = 's3:<bucket-dominio>/ASSESSORIA' }
        @{ Id = 'documentos'; Provider = 'Directory'; SourcePath = 'D:\Documentos'; RemoteRoot = 's3:<bucket>/ASSESSORIA' }
    )
    Schedule = @{ Tasks = @(
        @{ Name = 'diario-1900'; Jobs = @('seven','dominio'); At = '19:00'; Frequency = 'Daily' }
        @{ Name = 'semanal-docs'; Jobs = @('documentos'); At = '03:00'; Frequency = 'Weekly'; Days = @('Saturday') }
    ) }
    # Storage, Encryption, Archive, Retention, Execution, Monitoring: ver App\Templates\config.example.psd1
}
```

Depois de editar, rode `Aplicar-Configuracao.bat`. Ids de job são únicos na
instância (sem diferenciar maiúsculas; `logs` é reservado). `Paths` é opcional:
o padrão é `Runtime` na instância e `Completed`/`Logs` na raiz da instalação,
uma subpasta por instância.

MySQL usa `[client]` com host, port, user e password no `.cnf`. O padrão
`--skip-events` significa que eventos MySQL não entram no dump. O setup não cria
usuários nem concede privilégios nos bancos.

SQL Anywhere usa uma linha no `.options`:

```text
-c "UID='usuario';PWD='senha';HOST='servidor:2638';DBN='banco'"
```

UID, PWD e DBN são obrigatórios; DBN deve ser igual ao `Database` do job. Use
HOST (host:porta) para servidor em rede ou SERVER (ou ENG) para servidor local;
um dos dois é obrigatório. CHARSET é opcional. DSN, parâmetros de startup e
flags de truncagem/rotação não são aceitos. São esperados ao menos um .db
(principal e dbspaces) e um .log não vazios. Em falha do dbbackup, a saída vai
para o log sem a senha.

## Destino S3 e nomes

`RemoteRoot` (`remote:bucket/prefixo`) é definido por job. O job grava em
`<RemoteRoot>/<job>/` e o log de cada execução vai para `<RemoteRoot>/Logs/` de
cada destino usado na execução:

```text
<bucket>/<prefixo>/<job>/aaaa/mm/dd/2026-11-18_19-00-05_<instância>_<job>.7z.age
<bucket>/<prefixo>/Logs/aaaa/mm/dd/2026-11-18_19-00-02_<instância>.log
```

Data e hora são locais. O fallback degradado do MySQL gera `_GERAL` e
`_GRANULAR` no fim do nome. Um nome repetido recebe `-2`, `-3`... O ID da
execução continua no `state.json` e no manifesto. Destinos de jobs não podem ser
iguais nem aninhados (maiúsculas e minúsculas diferenciam), na mesma instância
ou entre instâncias do servidor.

O envio usa `rclone copyto` e `rclone lsjson --hash` da pasta datada para
conferir tamanho e MD5 do objeto, sem reler o arquivo local nem baixar o objeto;
sem MD5 no destino, o log registra `remote verification: size-only`. Não há sync
nem remoção remota. O `rclone.conf` gerado inclui `no_check_bucket = true`. Uma
instância tem um `rclone.conf`; jobs em buckets diferentes usam a mesma
credencial. Configure a expiração remota com regras de ciclo de vida do bucket.

### Política IAM mínima

Um usuário IAM por cliente/servidor, com esta política (troque `<bucket>` e
`<prefixo>` pelo bucket e prefixo do `RemoteRoot` dos jobs):

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "BucketLocation",
            "Effect": "Allow",
            "Action": ["s3:GetBucketLocation"],
            "Resource": "arn:aws:s3:::<bucket>"
        },
        {
            "Sid": "ListOnlyPrefix",
            "Effect": "Allow",
            "Action": ["s3:ListBucket"],
            "Resource": "arn:aws:s3:::<bucket>",
            "Condition": { "StringLike": { "s3:prefix": ["<prefixo>", "<prefixo>/*"] } }
        },
        {
            "Sid": "MultipartBucketAccess",
            "Effect": "Allow",
            "Action": ["s3:ListBucketMultipartUploads"],
            "Resource": "arn:aws:s3:::<bucket>"
        },
        {
            "Sid": "ObjectAccess",
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:AbortMultipartUpload",
                "s3:ListMultipartUploadParts"
            ],
            "Resource": "arn:aws:s3:::<bucket>/<prefixo>/*"
        }
    ]
}
```

| Permissão | Uso no DBBackup |
| --- | --- |
| `s3:PutObject` | Enviar pacotes e logs, inclusive em partes (multipart). |
| `s3:ListBucket` (só no prefixo) | Conferir o objeto enviado na pasta datada e testar o acesso no setup. Sem ela, a AWS responde "acesso negado" em vez de "não existe". |
| `s3:GetObject` | Ler o MD5 de objetos enviados em partes; baixar na restauração. |
| `s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts`, `s3:ListBucketMultipartUploads` | Cancelar ou retomar uploads grandes interrompidos. |
| `s3:GetBucketLocation` | Descobrir a região do bucket. |

Não conceda `s3:DeleteObject` nem `s3:CreateBucket`: o DBBackup nunca apaga nem
cria nada no bucket, e sem essas permissões um servidor comprometido não apaga
os backups.

Jobs da mesma instância em **buckets diferentes** (ex.: MySQL do Seven e SQL
Anywhere do Domínio) usam o mesmo `rclone.conf`; liste os buckets nos `Resource`
e crie um bloco `ListBucket` por bucket, cada um com o prefixo usado nele:

```json
{ "Sid": "ListSeven", "Effect": "Allow", "Action": ["s3:ListBucket"],
  "Resource": "arn:aws:s3:::<bucket-seven>",
  "Condition": { "StringLike": { "s3:prefix": ["<prefixo>", "<prefixo>/*"] } } },
{ "Sid": "ListDominio", "Effect": "Allow", "Action": ["s3:ListBucket"],
  "Resource": "arn:aws:s3:::<bucket-dominio>",
  "Condition": { "StringLike": { "s3:prefix": ["<prefixo>", "<prefixo>/*"] } } }
```

e no `ObjectAccess` use `"Resource": ["arn:aws:s3:::<bucket-seven>/<prefixo>/*",
"arn:aws:s3:::<bucket-dominio>/<prefixo>/*"]`.



`Secrets\recipients.txt` contém um destinatário age público por linha
(comentários com `#`). Identidades privadas ficam no cofre ou no processo
externo de recuperação. Alterar destinatários afeta só pacotes novos.

## Limites e monitoramento

```powershell
Execution = @{ ToolTimeoutSeconds = 21600; RunTimeoutSeconds = 39600; ReserveBytes = 1073741824; EstimatedDatabaseBytes = 0 }
```

Cada processo externo tem timeout próprio (padrão 6 horas) e a execução inteira
tem prazo (`RunTimeoutSeconds`, padrão 11 horas): ferramentas são encurtadas ao
tempo restante e nenhum job começa depois dele. A tarefa agendada recebe esse
prazo arredondado para horas mais uma hora; reaplique após alterá-lo. Pastas são
arquivadas no lugar (sem cópia para Work); um arquivo alterado durante a
execução pode diferir do hash do manifesto. Com `EstimatedDatabaseBytes = 0`, a
estimativa de espaço vem do último payload do job (+25%) ou, no MySQL, do
tamanho em information_schema (+25%); o SQL Anywhere na primeira execução só
verifica a reserva.

```powershell
Monitoring = @{
    Enabled = $true
    Service = 'erp'
    TextfileDirectory = 'C:\ProgramData\GrafanaLabs\Alloy\textfile\backup'
    BackupIds = @{ seven='assessoria-seven'; documentos='assessoria-documentos' }
    Criticality = @{ seven='alta'; documentos='baixa' }
}
```

`Service` é o sistema protegido, não MySQL/SQLAnywhere ou DBBackup. BackupIds são
estáveis por conjunto; o padrão é `<instância>-<job>` em minúsculas.
Evite reutilizar a identidade para outros dados. O setup verifica colisões entre
instâncias da mesma raiz. ExpectedIntervalHours pode substituir o intervalo da
agenda por trabalho. Alloy cria sua pasta; DBBackup nunca a cria. SYSTEM escreve
nela; outra conta precisa das permissões do Alloy Backup Writers.

Arquivos `<service>__<backup_id>.prom` seguem o contrato genérico Grafana. Último
sucesso considera somente FULL normal confirmado, no ponto de recuperação
original. Pacotes degradados não avançam sucesso. O checkpoint privado em
Runtime/Monitoring conserva esse histórico após retenção ou falta da pasta Alloy.
Falha ao observar ou gravar métricas vai para o log e resulta em código 4 quando
nenhum trabalho falhou. Não apague checkpoints durante atualização.

## Diagnosticar, planejar e aplicar

```powershell
.\Diagnosticar.bat
.\Aplicar-Configuracao.bat
& pwsh -File .\App\Setup.ps1 -ConfigPath .\Instances\assessoria\config.psd1 -Plan
```

Diagnose é local: configuração, ACL de Secrets e Runtime, arquivos, ferramentas,
espaço e remotes declarados. Não conecta aos bancos e não grava. Plan também não
cria diretórios, altera ACL ou aplica tarefas.

As tarefas rodam como SYSTEM na pasta `\DBBackup\` do Agendador, com o nome
`<instância>-<tarefa>`, e executam `App\Backup.ps1 -Job <job1>,<job2>`. Cada
instância só altera as próprias tarefas (marca de dono na descrição); uma
tarefa de outra configuração com o mesmo nome causa conflito. Há agenda diária,
semanal e mensal (DaysOfMonth 1..31 ou Last). Sem `Schedule`, a agenda é
ignorada; `Tasks` vazio remove somente as tarefas próprias. Tarefas da mesma
instância em horários sobrepostos disputam o lock (código 3); agrupe os jobs na
mesma tarefa.

## Execução e interpretação

```powershell
& pwsh -File .\App\Backup.ps1 -ConfigPath .\Instances\assessoria\config.psd1 -All
& pwsh -File .\App\Backup.ps1 -ConfigPath .\Instances\assessoria\config.psd1 -Job seven,documentos
```

A falha de um job não impede os demais. O log da execução fica em
`Logs\<instância>\<data_hora>.log` e **termina sempre com uma linha
`RESULTADO`**, por exemplo:

```text
RESULTADO: SUCESSO (exit 0)
RESULTADO: FALHA (exit 1) - jobs com falha: dominio
RESULTADO: ATENCAO (exit 4) - etapas auxiliares com falha: envio do log
```

| Código | Significado |
| --- | --- |
| 0 | Jobs, reenvios e manutenção concluídos. |
| 1 | Falha de job, publicação, criptografia ou verificação. |
| 2 | Configuração, dependência ou inicialização inválida. |
| 3 | Lock ocupado (outra execução da instância); não gera log nem métrica. |
| 4 | Backups publicados, mas uma etapa auxiliar falhou: retenção, limpeza de execução interrompida, envio do log ou métricas. |
| 5 | Fallback MySQL publicado como degradado. |

Precedência: 1 > 5 > 4 > 0. No Agendador, "Resultado da Última Execução" mostra
o mesmo código; atualize a tela (F5) para ver o estado atual.

Dumps e .7z ficam sem criptografia em `Runtime\Work` durante a execução; o
payload é apagado assim que o .7z é testado. Após uma interrupção, a execução
seguinte remove sobras de Work/Staging e registra o que removeu. Pending guarda
pacotes criptografados ainda não enviados; são reenviados com os mesmos bytes e
destino. Nunca limpe Pending para liberar espaço. `Completed` é sujeito à
retenção local por idade (`Retention.CompletedDays`); com
`KeepLocalPayload = $false`, a cópia local é apagada logo após o envio. Nem a
conferência remota nem o teste 7z comprovam recuperação do banco; recovery é
externo ao projeto.

## Atualização e migração

Entre versões 2.x: pare as execuções, confira o checksum, substitua `App\` e os
`.bat`, e preserve `Instances`, `Completed` e `Logs`. Rode
`Aplicar-Configuracao.bat` para cada instância se o CHANGELOG pedir.

Da 1.x para a 2.0: os arquivos de configuração mudaram (schema 2). Extraia a 2.0
numa pasta nova, copie os arquivos de `Secrets` da instância antiga para
`Instances\<instância>\Secrets\` e rode o `Setup.bat`: ele oferece reaproveitar
`rclone.conf`, `recipients.txt` e as credenciais de banco. Remova as tarefas da
1.x no Agendador depois de conferir a 2.0. Pacotes e logs antigos não são
migrados; mantenha-os pelo tempo necessário.

## Build e release

`./scripts/verify.ps1` executa parsing, PSScriptAnalyzer e Pester com ferramentas
simuladas. `./scripts/package.ps1` gera o ZIP (lançadores, `LEIA-ME.txt` e `App`)
e o SHA-256 em `dist`. O workflow manual Release só roda a partir da `main`,
repete os checks, recusa versões já publicadas e vincula a release ao commit
verificado. Os testes não acessam bancos ou S3 reais.
