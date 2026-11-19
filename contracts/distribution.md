# Distribuição DBBackup

`VERSION` define o nome `DBBackup-X.Y.Z.zip`. `scripts/package.files.json` é a
lista explícita de origens/destinos; adicionar um módulo exige atualizar essa
lista. O ZIP tem, na raiz, apenas o lançador `DBBackup.bat` (menu e
atualização) e o `LEIA-ME.txt`, gerado a partir de `scripts/LEIA-ME.template.txt` com a versão e
os links do repositório, do runbook e do changelog da tag `vX.Y.Z`. Scripts,
módulos, modelos (`config.example.psd1`, `ambiente.example.psd1`) e `VERSION`
ficam em `App\`. A pasta `configuracoes/` do repositório (configurações
versionadas dos servidores) não entra no pacote, nas releases nem no CHANGELOG. README, RUNBOOK,
ARCHITECTURE, CHANGELOG e contratos não são distribuídos. O arquivo irmão
`.zip.sha256` verifica o ZIP completo.

Os nomes dos arquivos da release (`DBBackup-X.Y.Z.zip` e
`DBBackup-X.Y.Z.zip.sha256`, tag `vX.Y.Z`) são contrato do `App\Update.ps1`:
ele lê `releases/latest` da API do GitHub, procura esses dois arquivos, confere
o checksum e só aceita um pacote com `App\`, `.bat` e `LEIA-ME.txt` na raiz,
incluindo `DBBackup.bat` (a partir da 2.2; o updater da 2.1 exigia `Setup.bat`,
por isso a passagem 2.1 → 2.2 é manual).

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
