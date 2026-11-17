# Distribuição DBBackup

`VERSION` define o nome `DBBackup-X.Y.Z.zip`. `scripts/package.files.json` é a
lista explícita de origens/destinos; adicionar um módulo exige atualizar essa
lista. O ZIP inclui `PACKAGE-MANIFEST.json` com versão e SHA-256 de cada arquivo.
O arquivo irmão `.zip.sha256` verifica o ZIP completo.

O empacotador confere os arquivos copiados, as entradas do ZIP e seu conteúdo
antes de substituir o pacote anterior. Arquivos operacionais e executáveis de
terceiros não são distribuídos. Os modelos mantêm nomes `.example.psd1`; uma
instalação começa sem instâncias configuradas e sem credenciais.

CI executa parsing, análise estática, Pester e empacotamento. O workflow manual
de release repete os checks, exige uma seção do CHANGELOG para VERSION e recusa
tag/release existentes. Publica o ZIP e checksum vinculados ao commit verificado.
Implementar esse workflow não o dispara, não cria tag e não instala o produto.
Recuperação é externa e não é executada nem certificada pelo workflow.
