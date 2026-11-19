# DBBackup

Backup criptografado de bancos MySQL 5, SQL Anywhere 17 e pastas em Windows,
enviado para S3 com rclone.

Cada **instância** reúne credenciais S3, destinatários age, agenda e pastas
operacionais, e executa uma lista de **jobs**. Cada job é uma fonte (um banco ou
uma pasta) com destino próprio no S3. Uma instância pode ter, por exemplo, um
MySQL, um SQL Anywhere e uma pasta, ou só pastas.

Fluxo de cada job: produz os arquivos, cria e testa um `.7z`, criptografa com age
e envia o `.7z.age` com rclone, conferindo tamanho e MD5 no destino. Pacotes
pendentes são reenviados sem mudar conteúdo ou destino.

- MySQL: dump lógico e fallback geral/granular explicitamente degradado.
- SQL Anywhere: cópia nativa completa do banco e log e, opcionalmente, incremental
  acumulado do log de transações em vários horários do dia (restauração = completo
  + último incremental).
- Pastas: arquivadas no lugar, sem cópia intermediária.
- Setup guiado com menu de jobs, reaproveitamento de credenciais e teste de conexão.
- Agendamento na pasta `\DBBackup\` do Agendador (`<instância>-<tarefa>`), com
  um ou vários horários por tarefa.
- Um único lançador, `DBBackup.bat`, com menu: setup, editar, aplicar,
  diagnosticar, executar, últimos resultados, ambiente, atualizar e configurações
  versionadas.
- `ambiente.psd1`: ferramentas e padrões do servidor definidos uma vez para todas
  as instâncias.
- Atualização pela última release do GitHub, preservando ambiente,
  configurações, credenciais, pacotes e logs.
- Configurações dos servidores versionadas em [`configuracoes/`](configuracoes/README.md)
  (sem segredos), puxadas pelo menu.
- Nomes legíveis: `2026-11-18_19-00-05_<instância>_<job>.7z.age`.
- Cada log termina com `RESULTADO: ...` explicando o que aconteceu.
- Métricas no contrato genérico de backups do Grafana Alloy.

**Recovery é um processo externo.** O DBBackup não restaura bancos e não precisa
de chave age privada. Sucesso de backup indica produção, verificação do pacote e
publicação confirmada; não certifica restauração.

## Instalação

Requer Windows, PowerShell 7.2+ (instalador MSI), 7-Zip, age e rclone; para MySQL,
`mysql.exe`/`mysqldump.exe`; para SQL Anywhere, a pasta de ferramentas 17
(`dbbackup.exe` e `dbping.exe`).

1. Confira o SHA-256 do `DBBackup-X.Y.Z.zip` com o `.zip.sha256`.
2. Extraia numa pasta, por exemplo `C:\TI\Scripts\DBBackup`.
3. Execute `DBBackup.bat`, escolha **1** e siga as perguntas.

O pacote contém apenas o `DBBackup.bat`, o `LEIA-ME.txt` e a pasta `App`. O
`ambiente.psd1` e as pastas `Instances`, `Completed` e `Logs` são criados ao lado
deles. Para atualizar, use a opção 8 do menu (veja o
[runbook](RUNBOOK.md#atualização-e-migração); da 2.1 para a 2.2 a atualização é manual).

## Documentação e desenvolvimento

- [Runbook](RUNBOOK.md): instalação, setup, credenciais, IAM, operação e migração.
- [Arquitetura](ARCHITECTURE.md): instâncias, jobs, núcleo e provedores.
- [Contratos](contracts/v2.md): configuração, resultado, artefatos e métricas.
- [Distribuição](contracts/distribution.md): conteúdo do pacote e release.
- [Mudanças](CHANGELOG.md).

```powershell
.\scripts\verify.ps1
.\scripts\package.ps1
```

A verificação usa Pester 5.7.1 e PSScriptAnalyzer 1.25.0. Os testes usam
ferramentas simuladas e mocks de ACL/agendador; não acessam bancos ou buckets
reais. O workflow de release é manual e só roda a partir da `main`.
