# Histórico de alterações

Todas as alterações relevantes do BackupSeven são registradas neste arquivo. O
projeto usa as versões semânticas definidas em `VERSION` e as principais seções
do Keep a Changelog, sem exigir todas as seções em cada versão.

## [Não publicado]

### Corrigido

- Verificação de tag/release inexistente não deixa mais exit code `1` encerrar o workflow.
- O empacotamento agora gera e valida SHA-256 para uso no CI e na release.

## [0.1.0] - Não publicado

### Adicionado

- Contratos de arquitetura e configuração externa.
- Logs UTF-8 com contexto de execução, modo e etapa.
- Criação e validação de archives com 7-Zip.
- Backups independentes nos modos `Database`, `Fiscal` e `Full`.
- Dump completo do banco com credenciais em arquivo externo do MySQL.
- Envio validado pelo rclone com fila local para novas tentativas.
- Retenção local restrita aos backups confirmados e bloqueio de concorrência.
- Testes automatizados dos módulos, fluxos de erro e pacote de produção.
- Pacote versionado por allowlist, sem configuração ou dependências externas.
- CI para parsing, análise estática, testes e empacotamento.
- Release manual com tag `v<VERSION>`, ZIP e SHA256.
