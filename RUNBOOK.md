# DBBackup — runbook v2.1.0

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
mesma pasta, se existir, é usado pelo teste de conexão do setup e pela
estimativa de espaço da primeira execução. O DBBackup não
instala dependências.

1. Confira o SHA-256 do ZIP contra o `.zip.sha256`.
2. Extraia, por exemplo, em `C:\TI\Scripts\DBBackup`.
3. Execute `Setup.bat` (pede elevação).

```text
DBBackup\
  Setup.bat                           cria instância ou adiciona jobs
  Editar-Configuracao.bat             abre o config.psd1 como Administrador, valida e aplica
  Aplicar-Configuracao.bat            reaplica ACL, diagnóstico e tarefas
  Diagnosticar.bat                    verificações locais
  Executar-Backup.bat                 backup manual com andamento na tela
  Atualizar.bat                       atualiza para a última versão do GitHub
  LEIA-ME.txt                         versão instalada e links
  App\                                scripts, módulos, modelo, VERSION
  Instances\<instância>\
    config.psd1                        configuração (alterar com Editar-Configuracao.bat)
    Secrets\                          restrita a SYSTEM e Administradores
    Runtime\                          restrita (trabalho temporário, pendências)
  Completed\<instância>\<job>\        pacotes criptografados locais
  Logs\<instância>\                    um log por execução
  Versoes-Anteriores\                 cópia de App e .bat antes de cada atualização
```

Os `.bat` usam `%ProgramFiles%\PowerShell\7\pwsh.exe` ou, se não existir, o
`pwsh.exe` do PATH, e pedem elevação. Os que agem sobre uma instância listam as
instâncias de `Instances\`: com uma só, ela é escolhida direto; com várias,
digite o número (um caminho completo de `config.psd1` também é aceito).

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
     (Enter mantém a sugestão; `/` usa a raiz do bucket) e horários diários
     (um ou vários, ex.: `12:30,19:00`).
   Ao concluir sem nenhum job de diretório, o setup pergunta se deseja
   adicionar backup de pasta.
5. **Agenda**: jobs com os mesmos horários entram na mesma tarefa
   (`diario-1900`, `diario-1230-1900`) e rodam em sequência.
6. **Teste opcional, somente leitura**: login em cada banco, existência de cada
   pasta e listagem de cada destino S3. Nada é gravado no bucket.
7. **Diagnóstico local**, plano das tarefas (confirmar com `SIM`) e resumo com
   os jobs, destinos e o comando do primeiro backup. Tarefas de versões
   anteriores (pastas `\DBBackup\<instância>\` da 1.x e `\BackupSeven\` da
   0.x) são listadas com o script que executam, e removidas se você digitar
   `SIM`.

Para reaproveitar credenciais de uma instalação anterior, copie os arquivos para
`Instances\<instância>\Secrets\` antes de rodar o setup. Se algo falhar depois
de salvar as credenciais, o setup indica o `Aplicar-Configuracao.bat` com o
caminho do `config.psd1`; nada precisa ser digitado de novo.

## Permissões

Somente `Secrets` e `Runtime` são restritas a SYSTEM e Administradores:
`Secrets` tem senhas e chaves em texto; `Runtime` tem dumps sem criptografia
durante a execução e pacotes pendentes. A pasta da instância e o `config.psd1`
herdam a permissão da instalação (o setup restaura essa herança em instâncias
criadas pela 1.x). Na instalação típica a herança permite leitura a usuários e
escrita só a Administradores, e isso é intencional: a tarefa roda como SYSTEM os
executáveis indicados em `Tools`, então quem altera o `config.psd1` precisa ser
administrador. Por isso o Bloco de Notas aberto sem elevação só oferece "Salvar
como"; use **`Editar-Configuracao.bat`**.

`Completed` (pacotes criptografados) e `Logs` (sem senhas) são pastas de
operação, com a permissão herdada. Uma execução nunca altera permissões de
pastas existentes. O Apply torna privado o `Runtime` da instância (padrão
`Instances\<instância>\Runtime`) mesmo que tenha herdado permissões; um
`Runtime` configurado fora da instância precisa já ser privado ou estar vazio.

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
        @{ Name = 'diario-1230-1900'; Jobs = @('seven','dominio'); At = @('12:30','19:00'); Frequency = 'Daily' }
        @{ Name = 'semanal-docs'; Jobs = @('documentos'); At = '03:00'; Frequency = 'Weekly'; Days = @('Saturday') }
    ) }
    # Storage, Encryption, Archive, Retention, Execution, Monitoring: ver App\Templates\config.example.psd1
}
```

Para alterar, use **`Editar-Configuracao.bat`**: ele escolhe a instância, abre
o `config.psd1` no Bloco de Notas como Administrador, espera você salvar e
fechar, valida o arquivo e pergunta se aplica. Se o arquivo ficar inválido, ele
oferece abrir de novo ou voltar ao conteúdo anterior; enquanto estiver inválido,
os backups agendados terminam com código 2. Uma alteração feita de outro jeito
precisa de `Aplicar-Configuracao.bat` para chegar às tarefas.

`At` aceita um horário (`'19:00'`) ou vários (`@('12:30','19:00')`): a tarefa
ganha um disparo por horário e roda os mesmos jobs em cada um. Ids de job são
únicos na
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
tamanho em information_schema (+25%) ou, no SQL Anywhere, de
`dbping -d -pd FileSize,PageSize` (+25%), se o `dbping.exe` estiver ao lado do
`dbbackup.exe` e responder; sem estimativa, só a reserva é verificada.

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

`Executar-Backup.bat` escolhe a instância, mostra os jobs e pergunta quais
executar (Enter = todos). Cada linha do log aparece na janela enquanto o backup
roda (`Step 1/4` backup, `2/4` compactação, `3/4` criptografia, `4/4` envio), e
a janela termina com o resultado. Pela linha de comando:

```powershell
& pwsh -File .\App\Backup.ps1 -ConfigPath .\Instances\assessoria\config.psd1 -All
& pwsh -File .\App\Backup.ps1 -ConfigPath .\Instances\assessoria\config.psd1 -Job seven,documentos
```

As ferramentas externas rodam sem entrada (stdin fechado): uma ferramenta que
pediria senha ou confirmação falha na hora, em vez de esperar até o timeout.
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

### Atualizar (2.1 em diante): `Atualizar.bat`

1. Rode **`Atualizar.bat`** (pede elevação). Ele consulta a última release no
   GitHub e mostra a versão instalada e a disponível.
2. Confirme. Ele baixa o ZIP e o `.sha256`, confere o checksum e verifica que o
   pacote só tem `App\`, `.bat` e `LEIA-ME.txt`.
3. Se algum backup estiver em execução, ele para sem alterar nada (código 3);
   rode de novo depois.
4. Ele guarda a versão atual em `Versoes-Anteriores\<versão>_<data>\` (as três
   mais recentes são mantidas), substitui `App\` e os arquivos da raiz e, se algo
   falhar no meio, restaura a versão anterior sozinho.
5. Por fim, oferece reaplicar a configuração de cada instância com a versão
   nova (recomendado: as tarefas são conferidas e só mudam com `SIM`).

`Instances` (configurações, `Secrets`, `Runtime`), `Completed` e `Logs` nunca são
tocados. Para voltar a uma versão anterior, copie o conteúdo de
`Versoes-Anteriores\<versão>_<data>\` para a raiz da instalação.

Sem internet: baixe `DBBackup-X.Y.Z.zip` e `DBBackup-X.Y.Z.zip.sha256` da página
de releases, coloque os dois na mesma pasta e arraste o ZIP sobre o
`Atualizar.bat`. O checksum é conferido se o `.sha256` estiver ao lado.

### Atualizar manualmente (e da 2.0.0 para a 2.1.0)

A 2.0.0 não tem o `Atualizar.bat`; a primeira atualização é manual. Depois
disso, use o `Atualizar.bat`.

1. Confira se nenhum backup está em execução.
2. Confira o SHA-256 do ZIP e extraia numa pasta temporária, por exemplo
   `C:\TI\Temp\DBBackup-2.1.0`.
3. Copie para a instalação (o pacote não contém `Instances`, `Completed` nem
   `Logs`, então nada disso é sobrescrito):

   ```bat
   robocopy C:\TI\Temp\DBBackup-2.1.0\App C:\TI\Scripts\DBBackup\App /MIR
   robocopy C:\TI\Temp\DBBackup-2.1.0 C:\TI\Scripts\DBBackup *.bat LEIA-ME.txt
   ```

   O primeiro comando espelha `App\` (remove módulos que deixaram de existir); o
   segundo copia só os arquivos da raiz.
4. Rode `Aplicar-Configuracao.bat` para cada instância e apague a pasta
   temporária.

Da 1.x para a 2.0: os arquivos de configuração mudaram (schema 2). Extraia a 2.0
numa pasta nova, copie os arquivos de `Secrets` da instância antiga para
`Instances\<instância>\Secrets\` e rode o `Setup.bat`: ele oferece reaproveitar
`rclone.conf`, `recipients.txt` e as credenciais de banco. Remova as tarefas da
1.x depois de conferir a 2.0 (a partir da 2.1, o Apply lista essas tarefas e
oferece removê-las). Pacotes e logs antigos não são
migrados; mantenha-os pelo tempo necessário.

## Build e release

`./scripts/verify.ps1` executa parsing, PSScriptAnalyzer e Pester com ferramentas
simuladas. `./scripts/package.ps1` gera o ZIP (lançadores, `LEIA-ME.txt` e `App`)
e o SHA-256 em `dist`. O workflow manual Release só roda a partir da `main`,
repete os checks, recusa versões já publicadas e vincula a release ao commit
verificado. Os testes não acessam bancos ou S3 reais.
