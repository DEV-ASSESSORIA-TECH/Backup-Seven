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
perguntam a instância/configuração interativamente. O ZIP não contém configurações
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
CHARSET são opcionais. DSN, parâmetros de startup e flags de truncagem/rotação
não são aceitos nesse arquivo. Valores não podem conter aspas duplas ou quebras
de linha; aspas simples internas são duplicadas. É esperado um .db principal e
pelo menos um .log não vazio. A rotina não abre a cópia do banco.

S3 usa `Secrets/rclone.conf`; o destino tem forma `remote:bucket/prefix`.
O fluxo usa copyto e check por arquivo, sem sync ou remoção remota e sem exigir
listagem do bucket. Configurar um remote não comprova acesso ao bucket. Mantenha
os remotes antigos enquanto houver pendências que os referenciem.

`Secrets/recipients.txt` contém um destinatário age público nativo por linha;
comentários iniciados por # são aceitos. Identidades privadas ficam no cofre ou
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
    ReserveBytes = 1073741824
    EstimatedDatabaseBytes = 0
}
```

Fontes não podem incluir a instância ou seus diretórios operacionais. Links são
rejeitados. Diretórios vivos não têm consistência de snapshot. Configure a
estimativa do banco conforme seu tamanho esperado: zero verifica só a reserva,
pois o produtor não consulta o tamanho remoto. Antes do 7z e do age, usa-se o
tamanho já conhecido, margem de 5%, 1 MiB e reserva. Não há reserva exclusiva de
disco; outros processos e crescimento dos dados podem consumir o espaço.

Cada processo externo tem timeout próprio (padrão 6 horas); expiração encerra sua
árvore. A tarefa agendada tem limite total independente de 12 horas. Esses
limites não tornam um backup interrompido válido; a próxima execução tenta as
pendências já completas, não arquivos parciais de Work.

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
Falha de métricas apenas avisa no log. Não apague checkpoints durante atualização.

## Diagnosticar, planejar e aplicar agenda

```powershell
.\Diagnose.ps1 -ConfigPath .\Instances\MySQL\config.psd1
.\Setup.ps1 -ConfigPath .\Instances\MySQL\config.psd1 -Plan
.\Setup.ps1 -ConfigPath .\Instances\MySQL\config.psd1 -Apply
```

Use `-InstancesRoot` consistentemente se as configurações estiverem fora da raiz
padrão. Diagnose é local: configuração, ACL, arquivos, ferramentas, espaço e
remotes declarados. Não conecta ao banco, não testa recuperação e não grava.
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
interrupção, inspecione Work/Staging com a instância parada. Apagar não equivale
a apagamento seguro. Nunca limpe Pending automaticamente para liberar espaço.

Pending guarda o pacote criptografado e state.json; reenvia os mesmos bytes ao
destino registrado, mesmo que a configuração tenha mudado. Completed indica
transporte confirmado e é sujeito à retenção local por idade; o registro pode
continuar marcado DEGRADED/FAILED. Logs operacionais são sanitizados e enviados
como texto separado. Retenção remota é responsabilidade do bucket.

`rclone check` compara tamanho e o melhor hash comum; sem hash compatível, a
conferência pode limitar-se ao tamanho. Nem esse check, nem o teste 7z, comprovam
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
| 4 | Backup concluído, mas limpeza/retenção falhou. |
| 5 | Os dois pacotes do fallback MySQL foram publicados como degradados. |

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
dist. O workflow manual Release repete os checks, recusa versões já publicadas e
vincula a release ao commit verificado. Disparar o workflow é uma ação separada;
nenhuma publicação é realizada apenas por desenvolver esta branch.

Os testes entregues não acessam bancos/S3 reais e não certificam compatibilidade
nativa age/SAP/MySQL no ambiente do cliente. Restauração e validação de banco
seguem como processo externo independente; não são executadas no CI ou servidor
como parte do DBBackup.
