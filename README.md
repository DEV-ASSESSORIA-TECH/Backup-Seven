# DBBackup

Backup de bancos MySQL 5 e SQL Anywhere 17 em Windows, com scripts PowerShell
compartilhados e instâncias operacionais isoladas. Diretórios adicionais podem
ser protegidos como trabalhos independentes.

O fluxo produz os arquivos, cria e testa um `.7z`, criptografa com age e envia
`.7z.age` ao S3 pelo rclone, conferindo o objeto antes de concluir a publicação.
Os pacotes pendentes são reenviados sem mudar seu conteúdo ou destino.

- MySQL: dump lógico e fallback geral/granular explicitamente degradado.
- SQL Anywhere: cópia nativa completa do banco e log, sem renomear/truncar o log.
- Uma configuração, Secrets, Runtime, Completed, Logs e lock por instância.
- Setup e agendamento comuns em `\DBBackup\<instância>\`.
- Métricas no contrato genérico de backups do Grafana Alloy.
- Timeouts dos processos externos, encerramento da árvore e checks de espaço.

**Recovery é um processo externo.** O DBBackup não inicia motores de bancos de
restauração/validação, não importa dumps e não precisa de chave age privada.
Sucesso de backup indica produção, verificações dos arquivos/pacote e publicação
confirmada; não certifica restauração. Nenhuma recuperação real foi executada
como parte desta entrega.

## Instalação

Requer Windows, PowerShell 7.2 ou superior, 7-Zip, age e rclone. MySQL precisa
mysql/mysqldump compatíveis com a origem 5.x. SQL Anywhere precisa dbbackup 17 e
suas dependências nativas. Executáveis externos não acompanham o ZIP.

Extraia `DBBackup-1.0.0.zip` em uma pasta nova. Em PowerShell elevado:

```powershell
.\Setup.ps1 -Provider MySQL -InstanceName MySQL
.\Setup.ps1 -Provider SQLAnywhere -InstanceName SQLAnywhere
```

O setup cria instâncias a partir de modelos e solicita os valores locais. Nada
é configurado na produção ao extrair o pacote. A linha 0.x é incompatível e sua
migração é manual; não sobrescreva a instalação existente.

## Documentação e desenvolvimento

- [Runbook](RUNBOOK.md): instalação, credenciais, tarefas, operação e migração.
- [Arquitetura](ARCHITECTURE.md): fronteiras do núcleo e dos provedores.
- [Contratos](contracts/v1.md): configuração, resultado, artefatos e métricas.
- [Distribuição](contracts/distribution.md): conteúdo e regras de release.

```powershell
.\scripts\verify.ps1
.\scripts\package.ps1
```

A verificação usa Pester 5.7.1 e PSScriptAnalyzer 1.25.0. Os testes usam motores
simulados e mocks de ACL/agendador; não acessam bancos ou buckets reais. Há teste
real de encerramento de processos simulados e checks do pacote extraído. O
workflow de release é manual; sua implementação não publica a versão por si só.
