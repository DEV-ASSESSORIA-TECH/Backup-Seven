# Arquitetura DBBackup v1

## Núcleo compartilhado, estado por instância

`Backup.ps1` exige uma configuração e um trabalho (`-Job`) ou todos (`-All`).
A configuração schema 1 resolve caminhos relativos a sua própria pasta. O núcleo
controla lock, tentativas, processos, compactação/criptografia, publicação,
retenção, métricas e código de saída. Os provedores retornam resultados e
conteúdos; não fazem upload nem declaram sucesso remoto.

MySQL mantém sua estratégia de dump normal, `--force` e granular por objeto.
Uma falha pode produzir conteúdo aproveitável e continuar com resultado FAILED;
DEGRADED exige os dois papéis publicados e nunca conta como último sucesso.
Directory faz uma cópia de arquivos vivos; não oferece snapshot consistente entre
arquivos. SQLAnywhere chama somente dbbackup, com ASTART=NO, contra o servidor
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
Tarefas têm também limite total de 12 horas.

O monitoramento observa pacotes normais confirmados, preserva o último sucesso
em checkpoint privado antes da retenção e grava o contrato Alloy atomicamente.
`service` identifica a aplicação protegida; `backup_id`, o conjunto de dados.
Erros de métricas são avisos e não modificam o resultado do backup. Lock ocupado
não é tentativa e não regrava métricas. O prazo é ancorado no último sucesso,
sem avançar a cada falha. A pasta de métricas pertence ao Alloy.

## Setup, segurança e atualização

Setup aplica configurações/ACLs e reconcilia somente tarefas com a identidade do
caminho de configuração da instância. Plan é somente leitura. Controles impedem
sobreposição de estado/Secrets e identidades de métricas entre instâncias sob a
mesma raiz. Credenciais nativas em texto ficam em diretórios/arquivos privados,
restritos a SYSTEM e Administradores; não entram nos argumentos dos processos.

Alterar código compartilhado afeta a próxima execução de todas as instâncias que
o usam. Atualize com os trabalhos parados e preserve o estado operacional.
A distribuição é uma lista explícita de fontes e modelos, com manifest/checksum.
A linha 0.x não é importada ou desativada automaticamente. Recovery e testes de
restauração não integram runtime, setup, agendador ou workflow de release.
