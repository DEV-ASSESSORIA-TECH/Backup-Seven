# Implementação DBBackup v1.0.0

Branch: `release/1.0.0`. Configuração, entradas e artefatos incompatíveis com 0.x.

| Etapa | Commit / entrega |
| --- | --- |
| 1 | `7908558` — contratos e escopo v1. |
| 2 | `0c59447` — núcleo por instância. |
| 3 | `cbfec41` — provedores MySQL e diretórios. |
| 4 | `332ef6d` — 7z + age obrigatório e estado dos artefatos. |
| 5 | `3b442b2` — backup completo SQL Anywhere 17. |
| 6 | `fecd24e` — setup, secrets e agendamento comuns. |
| 7 | Excluída pelo usuário: recovery preparation. |
| 8 | `3ee7d0f` — métricas, timeouts, checks de espaço e nenhum motor local adicional. |
| 9 | `17ea6eb` — pacote genérico, manifest/checksum e workflow manual. |
| 10 | Documentação final de operação, migração e fronteira do recovery. |
| 11 | VERSION/changelog 1.0.0, verificação final e pacote local. |

## Decisão de recovery

Por solicitação do usuário, restauração e validação do banco são um processo
externo ao projeto. Não há Restore.ps1, tarefas de recovery, VM provisionada,
identidade age privada ou banco de ensaio iniciado pelo runtime/CI. A validação
local com dbvalid/dbeng introduzida inicialmente na etapa 5 foi removida na etapa
8 para impedir uma segunda instância no servidor de produção. Essa limitação é
explícita no manifesto e no runbook; sucesso de backup não certifica restauração.

## Verificações

Até a etapa 6: 60 testes, parsing e análise estática aprovados. Na etapa 8: 71
testes aprovados, incluindo timeout com filho nativo simulado, persistência de
métricas, deadlines, indisponibilidade do Alloy e falta de espaço. Etapa 9: cinco
testes adicionais de checksum, conteúdo permitido, integridade do manifest,
launchers e importação do pacote extraído. A verificação final da etapa 11 reúne
a suíte completa e recompila o pacote com VERSION=1.0.0.

Bancos e S3 são simulados; ACL e aplicação de tarefas são mockados. Não foram
feitas conexões à produção, mudanças em tarefas instaladas ou recuperação real.
Compatibilidade operacional dos binários nativos no ambiente final não é
certificada pelos testes simulados. Publicação remota/tag e instalação são ações
separadas; o workflow manual está preparado, mas não é disparado pela implementação.
