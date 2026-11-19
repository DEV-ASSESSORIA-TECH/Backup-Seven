# Configurações versionadas

Configurações dos servidores, guardadas aqui para histórico e para reinstalar
rápido. **Esta pasta não entra no pacote, nas releases nem no CHANGELOG.** Os
commits vão direto na `main`.

```
configuracoes/
  <servidor>/                 nome do computador em minúsculas (ex.: srv-contabil-ass)
    ambiente.psd1             ferramentas e padrões do servidor
    <instancia>/config.psd1   jobs, agenda e monitoramento de cada instância
```

## Nunca coloque segredos aqui

O repositório é **público**. Só entram `ambiente.psd1` e `config.psd1`, que
guardam apenas *caminhos* para os Secrets. Não entram `rclone.conf`,
`recipients.txt`, `*.cnf`, `*.options` nem chaves age. O `.gitignore` bloqueia
`Secrets/`, e o menu recusa exportar ou gravar um arquivo com cara de segredo
(`PWD=`, `secret_access_key`, `AGE-SECRET-KEY-`).

## Exportar (servidor → repositório)

1. No servidor, abra `DBBackup.bat`, escolha **9** e depois **2**.
2. Os arquivos vão para `<instalação>\Configuracoes-Exportadas\<servidor>\`.
3. Copie a pasta `<servidor>` para `configuracoes/` e faça o commit na `main`.

## Puxar (repositório → servidor)

1. Abra `DBBackup.bat`, escolha **9** e depois **1**.
2. O menu lê `configuracoes/<servidor>/` da `main` pela API pública do GitHub
   e mostra a diferença de cada arquivo.
3. Depois de confirmar, ele grava os arquivos. A cópia anterior fica como
   `<arquivo>.anterior`.
4. O menu valida tudo. Se algo estiver inválido, volta tudo como estava.
5. Por último, ele oferece aplicar as instâncias alteradas.

Uma instância que ainda não existe no servidor recebe só o `config.psd1`.
Crie os Secrets dela pela opção **1** do menu, usando o mesmo nome.
