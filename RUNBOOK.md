# BackupSeven - Runbook

Procedimentos de operação no servidor. Instalação padrão em
`C:\TI\Scripts\BackupSeven`. Como o sistema funciona está no `README.md` do
repositório.

| Arquivo | Para quê |
| --- | --- |
| `Setup.bat` | Instalação e revisão: pergunta os dados, grava `config.psd1` e `Secrets` e aplica. |
| `Aplicar-Configuracao.bat` | Aplica o `config.psd1` como está (agendamentos, permissões, testes). Não pergunta dados. |
| `config.psd1` | Toda a configuração, inclusive os agendamentos (`Schedule`). |
| `Secrets\` | Credenciais do MySQL e do S3. Acesso só para SYSTEM e Administradores. |
| `Logs\` | Um log por execução. |

Os dois `.bat` pedem elevação (UAC) e rodam o PowerShell 7 com
`-ExecutionPolicy Bypass`. Não é preciso abrir terminal.

## 1. Instalação nova

Pré-requisitos no servidor: PowerShell 7, 7-Zip, rclone, `mysql.exe` e
`mysqldump.exe` compatíveis com o MySQL do Seven, e a credencial do S3. Para o
monitoramento, o Grafana Alloy (perfil servidor) instalado pelo `alloyctl`.

1. Extraia o ZIP em `C:\TI\Scripts\BackupSeven`.
2. Dê dois cliques em **`Setup.bat`** e responda. Enter mantém o valor entre
   colchetes.
   - **Instância**: prefixo no S3 (`<bucket>/<instância>/...`) e nos nomes dos
     arquivos.
   - **Agendamentos**: padrão Full diário às 12:00 e 19:00. Para mudar, veja a
     seção 3.
3. Confira o plano das tarefas agendadas e confirme.
4. Aceite o **backup de teste** no final e confira o exit code `0`.

Resultado esperado:

```text
[ OK ] MySQL: conectado ao banco ...
[ OK ] S3: ... acessivel                 (ou [AVISO] sem s3:ListBucket, normal)
[ OK ] Alloy: gravacao em ...            (ou [AVISO] pasta ainda nao existe)
[ OK ] Criada: \BackupSeven\Full Daily 12h00
[ OK ] Criada: \BackupSeven\Full Daily 19h00
```

## 2. Atualização de versão

O ZIP traz `config.psd1` e `Secrets\` como modelos. **Não extraia por cima.**

1. Extraia o ZIP novo em uma pasta temporária, por exemplo
   `C:\TI\Temp\BackupSeven-<versão>`.
2. Copie tudo, exceto a configuração e as credenciais:

   ```bat
   robocopy C:\TI\Temp\BackupSeven-<versão> C:\TI\Scripts\BackupSeven /E /XF config.psd1 /XD Secrets
   ```

3. Rode **`Setup.bat`** e responda só com Enter: ele mantém os valores e
   credenciais, inclui o que a versão nova precisar e aplica.
4. Apague a pasta temporária.

Se a versão anterior for a 0.4.x, o setup inclui a seção `Schedule` com as
12:00 e 19:00, cria as tarefas em `\BackupSeven\` e mostra as tarefas antigas
(`\ASSESSORIA SCRIPTS\BackupSeven - Full - ...`) para remoção. Confirme.

## 3. Alterar os agendamentos

1. Abra `config.psd1` e edite a seção `Schedule`.
2. Rode **`Aplicar-Configuracao.bat`**.
3. Confira o plano (`+ criar`, `~ alterar`, `- remover`) e confirme.

Cada item é um horário ou uma hashtable:

```powershell
Schedule = @{
    Tasks = @(
        '12:00'                     # Full, diario
        '19:00'
        @{ Mode = 'Database'; Frequency = 'Weekly'; Days = @('Saturday'); At = '03:00' }
        @{ Mode = 'Fiscal'; Frequency = 'Monthly'; DaysOfMonth = @(1, 'Last'); At = '22:00' }
        @{ At = '08:00'; Enabled = $false }        # registrada, desativada
    )
}
```

| Chave | Valores | Padrão |
| --- | --- | --- |
| `At` | `HH:mm`, 24 h, hora local do servidor | obrigatório |
| `Mode` | `Full`, `Database`, `Fiscal` | `Full` |
| `Frequency` | `Daily`, `Weekly`, `Monthly` | `Daily` |
| `Days` | `Weekly`: `Monday` ... `Sunday` | - |
| `DaysOfMonth` | `Monthly`: `1` a `31` ou `'Last'` | - |
| `Name` | nome da tarefa no Agendador | `<Mode> <Frequency> <HHhMM>` |
| `Enabled` | `$true` / `$false` | `$true` |

- As tarefas ficam na pasta **`\BackupSeven\`** do Agendador, visível só para
  administradores. Rodam como SYSTEM.
- A configuração é a fonte da verdade: tarefa editada à mão no Agendador
  volta ao que está no `config.psd1` quando a configuração muda. Tarefa que
  sai da configuração é removida (com aviso e confirmação).
- Duas tarefas no mesmo horário geram aviso: só uma roda, a outra termina com
  exit code `3`.
- O alerta de atraso do backup acompanha os horários sozinho: não há intervalo
  para configurar.

## 4. Trocar credenciais

- **Senha do MySQL ou chave do S3**: rode `Setup.bat` e responda `n` em
  "Credencial ... já preenchida. Manter?".
- Teste sem mudar nada: `Aplicar-Configuracao.bat`.

## 4.1. Criticidade dos backups

Em `config.psd1`, `Monitoring.Criticality` define, por tipo, se o backup é
`alta` (padrão) ou `baixa`. Com `baixa`, os alertas do backup descem um nível
(crítico vira warning, warning vira info). Vale na próxima execução, sem
aplicar nada:

```powershell
Monitoring = @{
    ...
    Criticality = @{ Database = 'alta'; Fiscal = 'baixa' }
}
```

## 5. Conferir se está funcionando

1. **Último log**: `Logs\`, o arquivo mais recente. Deve terminar com
   `Execution completed successfully.`
2. **Agendador de Tarefas** → pasta `BackupSeven` → coluna "Resultado da
   última execução": `0x0`.
3. **S3**: `<bucket>/<instância>/Database|Fiscal/<ano>/<mês>/<dia>/`.
4. **Grafana** (Explore, Prometheus):

   ```promql
   {job="integrations/backup", service="seven", __name__=~"backup_last_attempt_success|backup_last_success_timestamp_seconds"}
   ```

## 6. Exit codes

| Código | Significado | O que fazer |
| ---: | --- | --- |
| 0 | Sucesso | - |
| 1 | Falha no dump, compactação, envio ou validação | Ver a etapa no log (`[Database/Upload]`, etc.). Archive não enviado fica em `Runtime\Pending` e é reenviado na próxima execução. |
| 2 | Configuração, dependência ou permissão inválida | Rodar `Aplicar-Configuracao.bat`: os testes apontam o item. |
| 3 | Outra execução em andamento | Normal se coincidir com outra tarefa; ver avisos de horário. |
| 4 | Backups ok, limpeza ou retenção falhou | Ver `Retention/*` no log. |
| 5 | Banco publicado como `DEGRADED` | Dump normal falhou; ver o `manifest.json` e os `_FAILED.txt` do archive `GRANULAR_DEGRADED`. |

## 7. Problemas comuns

| Sintoma | Causa | Solução |
| --- | --- | --- |
| `... is not digitally signed` | Arquivos de ZIP baixado | Use os `.bat` (já usam Bypass e desbloqueiam os arquivos). |
| `[AVISO] S3: ... sem permissao de listar` | Conta do S3 sem `s3:ListBucket` | Normal; o backup não lista o bucket. |
| `[AVISO] Alloy: ... ainda nao existe` | Alloy sem a leitura de backups | `alloyctl` → **[1] Reaplicar**. O estado passa a ser gravado sem novo setup. |
| Log com `[WARN] [.../Monitoring]` | Pasta do Alloy ausente ou sem permissão | Mesmo item acima. Não afeta o backup. |
| Tarefa não aparece | Pasta `\BackupSeven\` só aparece para administradores | Abrir o Agendador como administrador. |
| Arquivos acumulando em `Runtime\Pending` | Envio ao S3 falhando | Ver `[*/Upload]` no log; nunca apagar `Pending` antes de entender. |

## 8. Restaurar um backup

Faça em um ambiente de teste sempre que possível.

1. Baixe o archive (local em `Completed\` ou do S3):

   ```bat
   "C:\Program Files\rclone\rclone.exe" copy "s3:<bucket>/<instancia>/Database/2026/11/14/<arquivo>.7z" C:\TI\Restore --config C:\TI\Scripts\BackupSeven\Secrets\rclone.conf
   ```

2. Extraia:

   ```bat
   "C:\Program Files\7-Zip\7z.exe" x C:\TI\Restore\<arquivo>.7z -oC:\TI\Restore\<arquivo>
   ```

3. Confira o `manifest.json` (`status`, arquivos e erros).
4. Importe o dump:

   ```bat
   "C:\Program Files\MySQL\MySQL Server 5.5\bin\mysql.exe" -h <servidor> -u <usuario_com_escrita> -p < C:\TI\Restore\<arquivo>\<arquivo>.sql
   ```

   **Atenção:** o dump é gerado com `--databases` e contém
   `CREATE DATABASE` e `USE` com o **nome original do banco**. Importado no
   servidor de produção, ele grava por cima do banco em uso. Para restaurar com
   outro nome, troque o nome nessas duas linhas do início do `.sql` antes de
   importar, ou importe em um servidor de teste. Use uma conta com permissão
   de escrita: a conta de backup normalmente só lê. O dump não inclui eventos
   agendados do MySQL (`--skip-events`).

O archive Fiscal contém a pasta `Fiscal` compactada; extraia e copie para o
destino desejado.
