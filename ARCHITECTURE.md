# Arquitetura DBBackup v2

## Núcleo compartilhado, instâncias e jobs

Uma **instância** é o contexto operacional: credenciais S3, destinatários age,
agenda, lock, Runtime e pastas Completed/Logs. Ela executa uma lista de
**jobs**; cada job é uma fonte com provedor próprio (MySQL, SQL Anywhere ou
Directory) e destino remoto próprio. Uma instância pode combinar qualquer
conjunto de jobs, inclusive só diretórios. `App\Backup.ps1` recebe uma
configuração e uma lista de jobs (`-Job a,b`) ou todos (`-All`); os jobs de uma
execução rodam em sequência sob o lock da instância.

A configuração schema 2 resolve caminhos relativos à sua pasta. O núcleo
controla lock, tentativas, processos, compactação/criptografia, publicação,
retenção, métricas, código de saída e a linha final `RESULTADO`. Os provedores
recebem o job (banco, credencial, origem), retornam resultados e conteúdos e
não fazem upload nem declaram sucesso remoto.

MySQL mantém sua estratégia de dump normal, `--force` e granular por objeto.
Uma falha pode produzir conteúdo aproveitável e continuar com resultado FAILED;
DEGRADED exige os dois papéis publicados e nunca conta como último sucesso.
Directory arquiva a pasta de origem no lugar (sem cópia para Work), sob
`content/` do pacote; não oferece snapshot consistente entre arquivos. SQLAnywhere chama somente dbbackup, com ASTART=NO, contra o servidor
existente: não executa dbvalid, dbeng ou dbsrv. Abertura, recuperação e validação
do banco ficam fora deste produto.

## Artefatos e publicação

Cada pacote contém manifesto schema 1, versão do produtor, ferramentas, resultado,
metadados e inventário de arquivos/tamanhos/SHA-256. O 7z é testado antes do age.
O servidor usa destinatários públicos, nunca identidades privadas. A criptografia
é promovida junto ao state.json de uma área de staging para Pending por rename
atômico. Runtime e Completed precisam estar no mesmo volume.

O registro mantém hash/tamanho do ciphertext e destino remoto originais. Reenvio
não renomeia, recriptografa ou redireciona um pacote antigo. Somente após copyto e
check o conjunto é movido atomicamente a Completed. O transporte CONFIRMED e o
resultado local SUCCESS/DEGRADED/FAILED são dimensões separadas. Pendências nunca
são removidas por idade. A retenção exclui pacotes concluídos com seus registros.

## Processos, capacidade e observabilidade

Um executor comum captura stderr e drena stdout de forma assíncrona; dumps são
transmitidos diretamente ao arquivo. Timeout encerra a árvore do processo. As
estimativas de espaço e a reserva são conferidas antes das etapas maiores, sem
reservar espaço contra outros processos ou prometer caber um banco que cresceu.
Cada execução tem um prazo total (`RunTimeoutSeconds`); o limite da tarefa
agendada deriva dele.

O monitoramento observa pacotes normais confirmados, preserva o último sucesso
em checkpoint privado antes da retenção e grava o contrato Alloy atomicamente.
`service` identifica a aplicação protegida; `backup_id`, o conjunto de dados.
Erros de métricas são registrados no log e, sem falha de job, resultam em código 4. Lock ocupado
não é tentativa e não regrava métricas. O prazo é ancorado no último sucesso,
sem avançar a cada falha. A pasta de métricas pertence ao Alloy.

## Setup, segurança e atualização

Setup é guiado: cria a instância, adiciona jobs, reaproveita credenciais já
presentes em Secrets e agrupa jobs com o mesmo horário numa tarefa. Aplica
ACLs (somente Secrets e Runtime privados) e reconcilia, na pasta compartilhada
`\DBBackup\` do Agendador, somente as tarefas com a identidade do caminho de
configuração da instância. Plan é somente leitura. Controles impedem
sobreposição de estado/Secrets e identidades de métricas entre instâncias sob a
mesma raiz. Credenciais nativas em texto ficam em diretórios/arquivos privados,
restritos a SYSTEM e Administradores; não entram nos argumentos dos processos.

Alterar código compartilhado afeta a próxima execução de todas as instâncias que
o usam. Atualize com os trabalhos parados e preserve o estado operacional.
A distribuição é uma lista explícita de fontes com checksum do ZIP; na raiz,
apenas lançadores e LEIA-ME. Configurações 1.x e a linha 0.x não são importadas
nem desativadas automaticamente. Recovery e testes de
restauração não integram runtime, setup, agendador ou workflow de release.
