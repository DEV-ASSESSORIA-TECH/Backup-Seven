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
- SQL Anywhere: cópia nativa completa do banco e log, sem renomear/truncar o log.
- Pastas: arquivadas no lugar, sem cópia intermediária.
- Setup guiado com menu de jobs, reaproveitamento de credenciais e teste de conexão.
- Agendamento na pasta `\DBBackup\` do Agendador (`<instância>-<tarefa>`), com
  um ou vários horários por tarefa.
- `Editar-Configuracao.bat` edita, valida e aplica o `config.psd1` como Administrador.
- `Atualizar.bat` atualiza para a última release do GitHub, preservando
  configurações, credenciais, pacotes e logs.
- Nomes legíveis: `2026-11-18_19-00-05_<instância>_<job>.7z.age`.
- Cada log termina com `RESULTADO: ...` explicando o que aconteceu.
- Métricas no contrato genérico de backups do Grafana Alloy.

**Recovery é um processo externo.** O DBBackup não restaura bancos e não precisa
de chave age privada. Sucesso de backup indica produção, verificação do pacote e
publicação confirmada; não certifica restauração.

## Instalação

Requer Windows, PowerShell 7.2+ (instalador MSI), 7-Zip, age e rclone; para MySQL,
`mysql.exe`/`mysqldump.exe`; para SQL Anywhere, `dbbackup.exe` 17.

1. Confira o SHA-256 do `DBBackup-X.Y.Z.zip` com o `.zip.sha256`.
2. Extraia numa pasta, por exemplo `C:\TI\Scripts\DBBackup`.
3. Execute `Setup.bat` e siga as perguntas.

O pacote contém apenas os lançadores `.bat`, o `LEIA-ME.txt` e a pasta `App`.
As pastas `Instances`, `Completed` e `Logs` são criadas ao lado deles. Para
atualizar, rode `Atualizar.bat` (veja o [runbook](RUNBOOK.md#atualização-e-migração)).

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
