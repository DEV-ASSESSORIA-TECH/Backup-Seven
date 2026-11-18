# Distribuição DBBackup

`VERSION` define o nome `DBBackup-X.Y.Z.zip`. `scripts/package.files.json` é a
lista explícita de origens/destinos; adicionar um módulo exige atualizar essa
lista. O ZIP tem, na raiz, apenas os lançadores (`Setup.bat`,
`Aplicar-Configuracao.bat`, `Diagnosticar.bat`, `Executar-Backup.bat`) e o
`LEIA-ME.txt`, gerado a partir de `scripts/LEIA-ME.template.txt` com a versão e
os links do repositório, do runbook e do changelog da tag `vX.Y.Z`. Scripts,
módulos, modelo de configuração e `VERSION` ficam em `App\`. README, RUNBOOK,
ARCHITECTURE, CHANGELOG e contratos não são distribuídos. O arquivo irmão
`.zip.sha256` verifica o ZIP completo.

O empacotador confere os arquivos copiados, as entradas do ZIP e o conteúdo de
cada entrada antes de substituir o pacote anterior. Arquivos operacionais e
executáveis de terceiros não são distribuídos. O modelo mantém o nome
`.example.psd1`; uma instalação começa sem instâncias configuradas e sem
credenciais.

CI executa parsing, análise estática, Pester e empacotamento. O workflow manual
de release só roda a partir da `main`, repete os checks, exige uma seção do
CHANGELOG para VERSION e recusa tag/release existentes. Publica o ZIP e checksum
vinculados ao commit verificado. Implementar esse workflow não o dispara, não
cria tag e não instala o produto. Recuperação é externa e não é executada nem
certificada pelo workflow.
