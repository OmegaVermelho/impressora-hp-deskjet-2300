# Central de Comando — HP DeskJet 2300 Series

Utilitário de linha de comando em Bash para operação completa da impressora **HP DeskJet 2300 series** em Linux. Reúne, em um único menu interativo com banner colorido, rotinas de impressão, digitalização, cópia (xerox), gestão de fila, leitura de suprimentos e diagnóstico de conectividade USB.

O projeto integra **CUPS**, **HPLIP** e **SANE** e foi desenhado para reduzir o tempo de suporte: detecta automaticamente a fila, o endereço do scanner e a porta USB, além de oferecer reparos assistidos para os problemas mais comuns (dispositivo ocupado, fila inconsistente e impressora travada após uma impressão interrompida).

> Testado em Linux Mint/Ubuntu com HP DeskJet 2300 series via USB (`03f0:3654`), CUPS 2.4.7, HPLIP 3.23.12 e SANE 1.2.1.

## Recursos

- Menu interativo com banner colorido e status ao vivo (fila, scanner e USB).
- Impressão de PDF, imagens e texto com seleção de cópias, modo de cor, papel e intervalos de páginas.
- Digitalização em PDF, PNG, JPEG ou TIFF, com modos Colorido, Tons de cinza e Lineart e resoluções de 75 a 1200 dpi.
- Xerox: digitaliza e imprime na sequência, preservando o scan em caso de falha de impressão.
- Atalho para gerar um PDF colorido em 300 dpi diretamente na Área de Trabalho.
- Gestão de fila: listar, cancelar, pausar/retomar, aceitar/rejeitar jobs e definir impressora padrão.
- Diagnóstico e reparos: health check, recriação da fila com o backend USB padrão, quirk USB, reset lógico e liberação de dispositivo travado.
- Leitura de níveis de tinta via HPLIP, com orientação quando o canal de status não responde.
- Logs integrados do CUPS, `journalctl` e `dmesg`.
- Detecção automática após reenumeração USB (o número do dispositivo pode mudar).

## Requisitos

- Linux com CUPS e um usuário com permissão de impressão.
- Impressora HP DeskJet 2300 series conectada por USB.
- Pacotes:

```bash
sudo apt update
sudo apt install cups hplip sane-utils libsane-hpaio ghostscript poppler-utils python3
```

| Dependência | Uso |
| --- | --- |
| `cups` (`lp`, `lpstat`, `lpadmin`, `cupsenable`) | Fila e impressão |
| `hplip` (`hp-levels`, `hp-probe`) | Suprimentos e descoberta |
| `sane-utils` (`scanimage`) | Digitalização |
| `libsane-hpaio` | Backend `hpaio` da HP |
| `ghostscript` | Normalização/conversão de PDF |
| `poppler-utils` (`pdfinfo`) | Verificação de PDFs |
| `python3` | Leitura do status da porta USB |

## Instalação

```bash
git clone https://github.com/OmegaVermelho/impressora-hp-deskjet-2300.git
cd impressora-hp-deskjet-2300
chmod +x impressora-hp.sh
./impressora-hp.sh
```

## Uso

```bash
./impressora-hp.sh          # menu interativo
./impressora-hp.sh --test   # status completo e sai
./impressora-hp.sh --help   # ajuda
```

### Opções do menu

| Opção | Descrição |
| --- | --- |
| `1` | Status completo: fila, USB, estado da porta, scanner e tinta |
| `2` | Imprimir arquivo (PDF, imagem ou texto) |
| `3` | Imprimir página de teste |
| `4` | Digitalizar (PDF/PNG/JPEG/TIFF) |
| `5` | Xerox / copiar documento (digitalizar e imprimir) |
| `6` | Digitalizar rápido: PDF colorido 300 dpi na Área de Trabalho |
| `7` | Níveis de tinta / suprimentos |
| `8` | Gerenciar fila de impressão |
| `9` | Diagnóstico e reparos |
| `10` | Logs do sistema (CUPS, `journalctl`, `dmesg`) |
| `11` | Informações e versões |
| `12` | Ajuda |
| `0` | Sair |

### Exemplos de fluxo

- **Imprimir um documento**: opção `2` → informe o caminho do PDF → escolha cópias, cor e papel → acompanhe o job.
- **Digitalizar para PDF**: opção `4` → Colorido, 300 dpi, PDF → escolha a pasta (padrão: Área de Trabalho).
- **Xerox**: opção `5` → cópias, modo (preto e branco ou colorido), resolução e papel.
- **PDF rápido**: opção `6` → gera `Documento_AAAA-MM-DD_HHMMSS.pdf` na Área de Trabalho.

## Configuração

As constantes ficam no início de `impressora-hp.sh`:

| Variável | Padrão | Descrição |
| --- | --- | --- |
| `PRINTER_MODEL` | `HP DeskJet 2300 series` | Nome exibido |
| `USB_VID` / `USB_PID` | `03f0` / `3654` | Identificação USB |
| `QUEUE_PREFERRED` | `HP-DeskJet-2300-series` | Fila CUPS preferida |
| `SERIAL_DEFAULT` | serial da impressora | Fallback quando não detectado |
| `PPD_MODEL` | `drv:///hpcups.drv/hp-deskjet_2300_series.ppd` | Driver usado ao recriar a fila |
| `QUIRK_FILE` | `/usr/share/cups/usb/local-hp-deskjet-2300.quirks` | Quirk do backend USB |

Variáveis de ambiente aceitas:

- `SCANNER_DEVICE` — força o dispositivo SANE (ex.: `hpaio:/usb/DeskJet_2300_series?serial=...`).
- `NO_COLOR=1` — desativa cores.
- `FORCE_COLOR=1` — força cores mesmo fora de um terminal.

## Notas técnicas

- A fila usa o backend USB padrão do CUPS (`usb://...&interface=1`) em vez do backend `hp` do HPLIP. Essa escolha evita o erro `Did not find alt setting 1 for intf 0, config 1` observado em alguns ambientes.
- O reparo (opção `9` → `3`) pode criar o quirk `0x03f0 0x3654 unidir no-reattach` e reiniciar o CUPS.
- A digitalização é independente de tinta; a impressão exige cartuchos instalados e a impressora sem estado de erro.
- Após reenumeração USB, o número do dispositivo muda (`/dev/bus/usb/003/00X`); o script redescobre automaticamente via `lsusb`.

## Solução de problemas

| Sintoma | Causa provável | Ação |
| --- | --- | --- |
| `sane_start: Error during device I/O` | Impressora travada após impressão interrompida | Desligue da tomada por ~30 s e religue (opção `9` → `7`) |
| `Device busy` | Outro aplicativo usando o scanner | Feche-o; o script tenta novamente automaticamente |
| Impressão não conclui / job parado | Erro da impressora (`0x10`), cartucho ausente, papel ou tampa | Verifique cartuchos (preto e tricolor), papel e tampa; use a opção `1`/`9` |
| Níveis de tinta indisponíveis | Canal de status do HPLIP sem resposta | Confira fisicamente os cartuchos; reinstale-os se necessário |
| `Permission denied` no USB | Usuário sem acesso ao nó USB | Verifique regras udev/ACL e grupos; como alternativa, execute com `sudo` |
| Fila inconsistente | URI/PPD incorretos | Opção `9` → `2` (recriar/reparar fila) |
| Impressora não listada | USB desconectado ou fila ausente | Opção `9` → `1` (health check) e opção `10` (logs) |

Dica: o status `0x10` na porta USB indica erro reportado pela impressora. O script mostra essa informação nas opções `1` e `9`.

## Estrutura do projeto

```text
impressora-hp-deskjet-2300/
├── impressora-hp.sh   # utilitário principal
├── README.md          # este manual
└── LICENSE            # licença MIT
```

## Privacidade

O script pode conter o serial da impressora como valor de fallback (`SERIAL_DEFAULT`). Nenhuma credencial é armazenada pelo utilitário; a autenticação no GitHub é feita exclusivamente pelo `gh`.

## Licença

Distribuído sob a licença **MIT**. Consulte [LICENSE](LICENSE).

## Autor

**OmegaVermelho** — [github.com/OmegaVermelho](https://github.com/OmegaVermelho)

Contribuições são bem-vindas via issues e pull requests.
