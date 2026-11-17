# DBBackup — runbook v1.0.0

## Dependências e instalação

Windows e PowerShell 7.2+; 7-Zip, age e rclone instalados separadamente. MySQL
precisa mysql/mysqldump 5.x compatíveis com a origem. SQL Anywhere precisa somente
dbbackup 17 e suas bibliotecas nativas; não é necessário instalar um motor de
restauração no servidor. O DBBackup não instala essas dependências.

1. Confira o SHA-256 do ZIP contra o `.zip.sha256` recebido por canal confiável.
2. Extraia em pasta nova, por exemplo `C:\TI\Scripts\DBBackup`.
3. Abra PowerShell elevado nessa pasta e execute o setup por instância:

```powershell
.\Setup.ps1 -Provider MySQL -InstanceName MySQL
.\Setup.ps1 -Provider SQLAnywhere -InstanceName SQLAnywhere
```

Também há `Setup.bat` e `Aplicar-Configuracao.bat`, que solicitam elevação e
perguntam a instância/configuração interativamente. Eles usam
`%ProgramFiles%\PowerShell\7\pwsh.exe` e, se não existir, o `pwsh.exe` do PATH.
Prefira o instalador MSI: o PowerShell da Microsoft Store fica em caminho
versionado que a tarefa (SYSTEM) pode não executar, e o setup avisa nesse caso. O ZIP não contém configurações
operacionais: apenas os modelos `Templates/<provedor>/config.example.psd1`.

```text
DBBackup/
  Backup.ps1, Setup.ps1, Diagnose.ps1
  Modules/, Templates/, VERSION
  Instances/
    MySQL/
      config.psd1, Secrets/, Runtime/, Completed/, Logs/
    SQLAnywhere/
      config.psd1, Secrets/, Runtime/, Completed/, Logs/
```

## Configuração e credenciais

O setup pergunta caminhos das ferramentas, banco e destino rclone. Cria somente
secrets ausentes; nunca substitui credenciais existentes. Para alterá-las, edite
os arquivos privados e reaplique a configuração. Todo arquivo de credenciais deve
ficar dentro de Secrets da própria instância. Os arquivos não são um cofre
criptografado: contêm opções nativas protegidas por ACL NTFS para SYSTEM e
Administradores. Não os inclua em relatórios ou no repositório.

MySQL usa `Secrets/mysql.cnf`, seção `[client]`, com host, port, user e password.
O padrão `--skip-events` significa que eventos MySQL não estão no dump; mudar
isso exige permissão correspondente e homologação externa. O setup não cria
usuários nem concede privilégios nos bancos.

SQL Anywhere usa `Secrets/sqlanywhere.options`, uma linha (substitua os valores):

```text
-c "UID='REPLACE_USER';PWD='REPLACE_PASSWORD';HOST='REPLACE_HOST:2638';DBN='REPLACE_DATABASE'"
```

UID, PWD, HOST e DBN são obrigatórios; DBN corresponde a Database.Name. SERVER e
CHARSET são opcionais. Para servidor local por memória compartilhada, SERVER
(ou ENG) pode substituir HOST; um dos dois é obrigatório. DSN, parâmetros de
startup e flags de truncagem/rotação não são aceitos nesse arquivo. Valores não
podem conter aspas duplas ou quebras de linha; aspas simples internas são
duplicadas. São esperados ao menos um .db (principal e dbspaces adicionais) e um
.log não vazios. A rotina não abre a cópia do banco. Em falha do dbbackup, a
saída da ferramenta vai para o log sem a senha.

S3 usa `Secrets/rclone.conf`; o destino tem forma `remote:bucket/prefix`.
O fluxo usa copyto e, em seguida, `rclone lsjson --hash` da pasta datada para
conferir tamanho e MD5 do objeto enviado (sem reler o arquivo local nem baixar o
objeto), sem sync ou remoção remota e sem exigir listagem do bucket inteiro. Configurar um remote não comprova acesso ao bucket. Mantenha
os remotes antigos enquanto houver pendências que os referenciem. O setup
pergunta o provedor S3 do rclone (AWS, Wasabi, Minio...) e um endpoint opcional.
`Storage.Destination` (padrão `s3`) é apenas o rótulo de destino nas métricas.
Configure a expiração remota com regras de ciclo de vida do bucket.

`Secrets/recipients.txt` contém um destinatário age público nativo por linha;
comentários iniciados por # são aceitos. O setup valida os destinatários antes
de gravar o arquivo e pede novamente (até três tentativas). Identidades privadas ficam no cofre ou
no processo externo de recuperação. Alterar destinatários afeta somente novos
pacotes; guarde as identidades necessárias aos antigos. O projeto não cria nem
usa chaves de ensaio/recuperação no servidor.

## Trabalhos, limites e monitoramento

Cada instância tem um trabalho `database`, sempre completo. Diretórios adicionais
são opcionais e independentes:

```powershell
Directories = @(@{ Id='documents'; SourcePath='D:\Documents' })
Execution = @{
    ToolTimeoutSeconds = 21600
    RunTimeoutSeconds = 39600
    ReserveBytes = 1073741824
    EstimatedDatabaseBytes = 0
}
```

Fontes não podem incluir a instância ou seus diretórios operacionais. Links são
rejeitados. Diretórios vivos não têm consistência de snapshot. A pasta é lida no
lugar (sem cópia para Work) e vai para `content/` dentro do pacote; um arquivo
alterado durante a execução pode diferir do hash do manifest. Depois que o 7z é
testado, o conteúdo em claro de Work é apagado antes da criptografia. A retenção
decide pelo state.json e pelo tamanho, sem recalcular o hash de cada pacote. Com
`EstimatedDatabaseBytes = 0`, a estimativa do banco vem do último payload
completo do trabalho (+25%); sem histórico, o MySQL consulta o tamanho em
information_schema (+25%). O SQL Anywhere não tem sonda: na primeira execução
só a reserva é verificada e o log registra um aviso; informe um valor para
evitar isso. Antes do 7z e do age, usa-se o
tamanho já conhecido, margem de 5%, 1 MiB e reserva. Não há reserva exclusiva de
disco; outros processos e crescimento dos dados podem consumir o espaço.

Cada processo externo tem timeout próprio (padrão 6 horas); expiração encerra sua
árvore. `RunTimeoutSeconds` (padrão 11 horas) é o prazo da execução inteira:
cada ferramenta é encurtada ao tempo restante e nenhum trabalho começa depois
dele, de modo que a falha é registrada nas métricas e Work é limpo. A tarefa
agendada recebe esse prazo arredondado para horas mais uma hora (12 horas no
padrão); reaplique a configuração depois de alterá-lo. Esses limites não tornam
um backup interrompido válido; a próxima execução tenta as pendências já
completas, não arquivos parciais de Work.

```powershell
Monitoring = @{
    Enabled = $true
    Service = 'erp'
    TextfileDirectory = 'C:\ProgramData\GrafanaLabs\Alloy\textfile\backup'
    BackupIds = @{ database='mysql-database'; documents='documents' }
    Criticality = @{ database='alta'; documents='baixa' }
}
```

Service é o sistema protegido, não MySQL/SQLAnywhere ou DBBackup. BackupIds são
estáveis por conjunto; o padrão omitido é `<instância>-<trabalho>` em minúsculas.
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

## Diagnosticar, planejar e aplicar agenda

```powershell
.\Diagnose.ps1 -ConfigPath .\Instances\MySQL\config.psd1
.\Setup.ps1 -ConfigPath .\Instances\MySQL\config.psd1 -Plan
.\Setup.ps1 -ConfigPath .\Instances\MySQL\config.psd1 -Apply
```

Use `-InstancesRoot` consistentemente se as configurações estiverem fora da raiz
padrão. Diagnose é local: configuração, ACL de secrets e das pastas de estado,
arquivos, ferramentas, espaço e remotes declarados. Não conecta ao banco, não testa recuperação e não grava.
Plan também não cria diretórios, altera ACL ou aplica tarefas.

```powershell
Schedule = @{ Tasks = @(
    @{ Name='database-daily'; Job='database'; At='19:00'; Frequency='Daily' }
    @{ Name='documents-weekly'; Job='documents'; At='03:00'; Frequency='Weekly'; Days=@('Saturday') }
) }
```

Há agenda diária, semanal e mensal (DaysOfMonth 1..31 ou Last). Cada tarefa usa
trabalho explícito e roda como SYSTEM em `\DBBackup\<instância>\`. Apply mostra o
plano e exige SIM. Tarefas de outra configuração causam conflito. Sem Schedule,
a agenda é ignorada; Tasks vazio remove somente as tarefas próprias. Tarefas da
mesma instância no mesmo horário disputam o lock; escolha horários distintos ou
execute `-All` manualmente. Antes de remover um trabalho, resolva suas pendências
e aposente seu arquivo .prom deliberadamente.

## Execução e interpretação

```powershell
.\Backup.ps1 -ConfigPath .\Instances\MySQL\config.psd1 -Job database
.\Backup.ps1 -ConfigPath .\Instances\SQLAnywhere\config.psd1 -All
```

Cada instância tem um lock; outras podem rodar simultaneamente. A falha de um
trabalho não impede os demais. O banco/log, dump e 7z ficam sem criptografia em
Work durante a execução, sob ACL privada. Em término normal, Work é limpo; após
uma interrupção, a execução seguinte da instância remove, sob o lock, as pastas
de execução de Work e de Staging deixadas para trás (inclusive o arquivo de
conexão temporário do SQL Anywhere) e registra o que removeu. Itens com outros
nomes não são tocados e geram código 4. Apagar não equivale a apagamento seguro.
Nunca limpe Pending automaticamente para liberar espaço; cada execução registra
quantos pacotes e bytes aguardam envio.

As pastas Runtime, Completed e Logs recebem ACL privada (SYSTEM e
Administradores) apenas quando o DBBackup as cria. Uma execução nunca altera as
permissões de uma pasta existente. O Apply só protege uma pasta existente vazia
e recusa uma pasta com conteúdo e permissões de terceiros; use pastas dedicadas.

Pending guarda o pacote criptografado e state.json; reenvia os mesmos bytes ao
destino registrado, mesmo que a configuração tenha mudado. Completed indica
transporte confirmado e é sujeito à retenção local por idade; o registro pode
continuar marcado DEGRADED/FAILED. Um pacote ou log ilegível é registrado e
ignorado, sem interromper a retenção dos demais (código 4). Com
`Retention.KeepLocalPayload = $false`, a cópia criptografada local é apagada
logo após o envio confirmado e Completed guarda só state.json (tamanho e hash). Logs operacionais são sanitizados e enviados
como texto separado. Retenção remota é responsabilidade do bucket.

A conferência remota compara tamanho e MD5 informado pelo destino (S3 guarda o
MD5 nos metadados do objeto); se o destino não informar MD5, fica só no tamanho
e o log registra `remote verification: size-only` como aviso. Nem esse check, nem o teste 7z, comprovam
recuperação do banco. SQL Anywhere não executa dbvalid/dbeng/dbsrv. Seu sucesso
significa saída nativa normal, arquivos esperados não vazios, pacote testado,
criptografia concluída e publicação confirmada. Recovery é externo ao projeto,
sem hook, tarefa automática, chave privada ou instância local de teste.

| Código | Significado |
| --- | --- |
| 0 | Trabalhos, reenvios e manutenção concluídos. |
| 1 | Falha operacional, publicação, criptografia ou verificação. |
| 2 | Configuração, dependência ou inicialização inválida. |
| 3 | Lock ocupado; não publica tentativa falha nas métricas. |
| 4 | Backups publicados, mas uma etapa auxiliar falhou: retenção, limpeza de execução interrompida, envio do log ou métricas. |
| 5 | Os dois pacotes do fallback MySQL foram publicados como degradados. |

Precedência: 1 > 5 > 4 > 0. A etapa auxiliar que falhou continua registrada no
log mesmo quando o código final é 5.

## Atualização e migração

Da linha 0.x para v1: instale em outra pasta, configure secrets/destinatários e
novas identidades. Os archives/configurações antigos não são importados. Preserve
pendências antigas e o histórico; a nova rotina não os envia nem os remove.
Desative tarefas antigas somente numa transição deliberada, quando a nova rotina
estiver conferida. O setup não modifica a instalação antiga ou suas tarefas.
Aposente métricas antigas somente ao aposentar o backup correspondente.

Entre versões v1: pare os trabalhos de todas as instâncias que compartilham o
código, confira o checksum do pacote e atualize os arquivos distribuídos. Preserve
Instances e quaisquer caminhos operacionais externos. Reaplique a configuração
se necessário. Não execute setup/backup enquanto substitui os módulos. Nenhuma
migração ou atualização da produção é efetuada pelo build ou release.

## Build e release

`./scripts/verify.ps1` executa parsing, PSScriptAnalyzer e Pester com ferramentas
simuladas. `./scripts/package.ps1` gera ZIP, manifest de arquivos e SHA-256 em
dist. O workflow manual Release só aceita disparo a partir da `main`, repete os
checks, recusa versões já publicadas e vincula a release ao commit verificado.
As actions dos workflows são fixadas por SHA de commit. Disparar o workflow é uma ação separada;
nenhuma publicação é realizada apenas por desenvolver esta branch.

Os testes entregues não acessam bancos/S3 reais e não certificam compatibilidade
nativa age/SAP/MySQL no ambiente do cliente. Restauração e validação de banco
seguem como processo externo independente; não são executadas no CI ou servidor
como parte do DBBackup.
