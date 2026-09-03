# BackupSeven

O BackupSeven substitui o antigo processo de backup em arquivo batch por uma
aplicação pequena em PowerShell 7. Ele cria backups lógicos do banco do Seven,
compacta a pasta `C:\Seven Sistemas\Fiscal` e envia os arquivos `.7z` validados
por meio do rclone.

> Situação: a versão 0.1.0 está em desenvolvimento. O pipeline completo e seus
> testes já estão disponíveis; empacotamento e automações de CI/release ainda
> não foram concluídos.

## Princípios operacionais

- PowerShell 7 é obrigatório.
- 7-Zip, rclone e mysqldump são instalados separadamente.
- Executáveis de terceiros nunca são armazenados neste repositório ou no ZIP de
  distribuição.
- Credenciais locais nunca são commitadas ou incluídas em uma versão.
- Cada backup só é concluído depois de criado, compactado, validado, enviado e
  validado remotamente.
- O envio remoto usa operações de cópia de arquivo. O BackupSeven nunca usa
  `rclone sync`.
- Somente um processo do BackupSeven pode executar por vez.

## Instalação prevista

O pacote de produção deve ser extraído em:

```text
C:\TI\SCRIPTS\BackupSeven
```

Copie `config.example.psd1` para `config.psd1` e ajuste-o para o servidor. Crie
o arquivo de opções do MySQL e a configuração do rclone referenciados nessa
configuração local. Restrinja ambos os arquivos de credenciais com ACLs NTFS
aos administradores e à conta usada pelo Agendador de Tarefas.

Os contratos dos componentes e os diretórios de execução estão documentados em
[`ARCHITECTURE.md`](ARCHITECTURE.md). O histórico de versões é mantido em
[`CHANGELOG.md`](CHANGELOG.md).

## Comandos previstos

```powershell
pwsh.exe -NoLogo -NoProfile -NonInteractive -File .\Backup-Seven.ps1 -Mode Database
pwsh.exe -NoLogo -NoProfile -NonInteractive -File .\Backup-Seven.ps1 -Mode Fiscal
pwsh.exe -NoLogo -NoProfile -NonInteractive -File .\Backup-Seven.ps1 -Mode Full
```

O script principal só será documentado como pronto para produção depois que o
pipeline completo e seus testes automatizados estiverem disponíveis.

## Validação durante o desenvolvimento

Todos os arquivos PowerShell devem ser interpretados sem erros no PowerShell 7.
O CI também executará PSScriptAnalyzer, Pester e o script de empacotamento de
produção quando essas etapas forem implementadas.
