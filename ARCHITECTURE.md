# Arquitetura do BackupSeven

## Escopo

O BackupSeven é uma aplicação PowerShell 7 para um único servidor, instalada em
`C:\TI\SCRIPTS\BackupSeven`. Ela produz dois tipos independentes de backup:

- `Database`: dump lógico criado pelo mysqldump e compactado pelo 7-Zip.
- `Fiscal`: archive da pasta `C:\Seven Sistemas\Fiscal` criado pelo 7-Zip.

O modo `Full` solicita os dois tipos. A falha de um tipo não impede a tentativa
do outro, mas o resultado geral da execução será uma falha.

A aplicação não instala dependências, não administra retenção remota, não cria
tarefas agendadas do Windows e não inclui executáveis de terceiros.

## Componentes

| Componente | Contrato |
| --- | --- |
| `Backup-Seven.ps1` | Validar entrada e configuração, adquirir o bloqueio de execução, coordenar os pipelines solicitados, aplicar retenção e definir o exit code do processo. |
| `Logging.psm1` | Gravar eventos UTF-8 de uma linha com data, severidade, ID da execução, modo e etapa. Chamadores nunca devem fornecer segredos como mensagens de log. |
| `Archive.psm1` | Criar um `.7z` único, rejeitar qualquer exit code não zero do 7-Zip, verificar se a saída não está vazia e executar `7z test`. |
| `Database.psm1` | Executar mysqldump no diretório de trabalho e retornar somente um dump bem-sucedido e não vazio. |
| `Fiscal.psm1` | Validar a origem Fiscal e produzir um archive validado por meio de `Archive.psm1`. |
| `Storage.psm1` | Enviar um archive ou log com `rclone copyto` e validá-lo com `rclone check --one-way`. |

Os módulos expõem somente as funções necessárias ao script principal. Falhas
operacionais esperadas são lançadas como erros terminantes e tratadas no limite
de cada pipeline.

## Estado durante a execução

O diretório configurado em `Paths.RuntimeRoot` contém:

```text
Runtime\
├── Pending\<Database|Fiscal>\yyyy\MM\
├── Completed\<Database|Fiscal>\yyyy\MM\
└── Work\<run-id>\
```

Os logs ficam fora de `Runtime`, diretamente no diretório configurado:

```text
Logs\
└── BackupSevenLog_<yyyy-MM-dd>_<HHmmssZ>_<InstanceName>_<Database|Fiscal|Full>_<run-id>.log
```

Não é necessário banco de estado ou manifesto:

- um arquivo em `Work` é temporário e deve ser limpo após a execução;
- um arquivo em `Pending` é válido localmente, mas não foi confirmado no remoto;
- um arquivo em `Completed` foi enviado e confirmado remotamente;
- somente arquivos em `Completed` participam da retenção local por idade.

Os valores de retenção são inteiros de pelo menos um dia. O timestamp usado para
avaliar a idade de archives e logs vem do nome controlado do arquivo, não de
`LastWriteTime`.

Uma nova execução tenta reenviar arquivos pendentes dos tipos solicitados antes
de criar novos artefatos. Uma falha nessa nova tentativa não impede a criação de
outro backup local.

## Contrato dos artefatos

Os nomes usam UTC e são únicos:

```text
BackupSeven_<yyyy-MM-dd>_<HHmmssZ>_<InstanceName>_<Database|Fiscal>_<run-id>.7z
```

Os objetos remotos usam o mesmo nome em:

```text
<RemoteRoot>/<InstanceName>/<Database|Fiscal>/yyyy/MM/dd/<archive>
<RemoteRoot>/<InstanceName>/Logs/yyyy/MM/dd/<log>
```

Um archive passa de `Pending` para `Completed` somente depois de um
`rclone copyto` e de um `rclone check --one-way` limitado ao arquivo. O
BackupSeven não executa `rclone sync` nem remove objetos remotos. O log final é
publicado pelo mesmo contrato de `copyto` e `check` quando o armazenamento já
foi validado naquela execução.

O `rclone check` compara tamanho e o melhor hash comum informado pelos backends.
Se o provedor S3 não oferecer hash compatível, essa limitação deve ser validada
durante a homologação; baixar novamente todo o objeto não faz parte da versão
inicial.

## Configuração e credenciais

O `config.psd1` pertence à instalação local e nunca é distribuído. O repositório
e o pacote contêm apenas `config.example.psd1`.

As credenciais do banco ficam em um arquivo externo de opções do MySQL indicado
por `Database.DefaultsExtraFile`. As credenciais S3 ficam na configuração
externa do rclone indicada por `Storage.ConfigPath`. Ambos os arquivos exigem
ACLs NTFS restritas.

## Logs e exit codes

Os registros de log têm o seguinte formato:

```text
2026-09-03T10:30:00.000-04:00 [INFO] [run-id] [Database/Dump] mensagem
```

O arquivo local fica diretamente em `Paths.LogRoot`, sem hierarquia de datas.
O timestamp do nome é UTC; as linhas mantêm o offset local para facilitar a
auditoria no servidor.

Os exit codes são intencionalmente poucos e estáveis:

| Código | Significado |
| ---: | --- |
| 0 | Todo o trabalho solicitado, novas tentativas pendentes e retenção tiveram sucesso. |
| 1 | Falha no dump, compactação, envio de backup/log ou validação remota. |
| 2 | Chamada, configuração, dependência, diretório ou permissão inválida. |
| 3 | Outra execução do BackupSeven detém o bloqueio. |
| 4 | Os backups tiveram sucesso, mas a limpeza ou retenção falhou. |

## Contrato de agendamento

O Agendador de Tarefas executa o PowerShell 7 com `-NoProfile -NonInteractive`
e a opção "Executar independentemente de o usuário estar conectado". As tarefas
regulares selecionam explicitamente `Database` ou `Fiscal`; `Full` é destinado
a uma execução completa solicitada por um operador. A conta do agendador deve
ter acesso a todos os caminhos locais e arquivos de credenciais configurados.

## Distribuição

`scripts/package.ps1` monta o ZIP por uma lista fechada de arquivos, reabre o
resultado para validar seu conteúdo e gera o arquivo SHA-256 correspondente.
Configuração local, credenciais, runtime, testes, workflows, `ARCHITECTURE.md` e
`CHANGELOG.md` não entram no pacote.

O CI executa parsing, PSScriptAnalyzer, Pester e empacotamento. O release é
manual, usa `VERSION` como fonte de verdade, recusa uma versão cuja tag ou
release já exista e publica o ZIP acompanhado de SHA256.
