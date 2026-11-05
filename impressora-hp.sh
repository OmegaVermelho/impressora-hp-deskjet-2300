#!/usr/bin/env bash
# ============================================================================
#  impressora-hp.sh - Central de Comando para HP DeskJet 2300 series
#  Menu interativo com banner colorido: impressao, digitalizacao e xerox.
#
#  Uso:
#    ./impressora-hp.sh            # abre o menu interativo
#    ./impressora-hp.sh --test     # mostra o status e sai
#    ./impressora-hp.sh --help     # ajuda
#
#  Dicas:
#   - Se a digitalizacao falhar com "Error during device I/O", a impressora
#     provavelmente travou apos uma impressao: desligue da tomada por ~30 s.
#   - Se a impressao travar, verifique cartuchos (preto e tricolor), papel,
#     tampa aberta e a luz de erro. O status USB mostra se ha erro (0x10).
# ============================================================================

set -o pipefail

# ------------------------------- configuracao -------------------------------
PRINTER_MODEL="HP DeskJet 2300 series"
USB_VID="03f0"
USB_PID="3654"
QUEUE_PREFERRED="HP-DeskJet-2300-series"
SERIAL_DEFAULT="BR26T3B1T7"
PPD_MODEL="drv:///hpcups.drv/hp-deskjet_2300_series.ppd"
QUIRK_FILE="/usr/share/cups/usb/local-hp-deskjet-2300.quirks"
TESTPAGE="/usr/share/cups/data/default-testpage.pdf"
# ---------------------------------------------------------------------------

# ----------------------------------- cores ----------------------------------
if [[ -n ${FORCE_COLOR:-} || ( -t 1 && -z ${NO_COLOR:-} ) ]]; then
    E=$'\033'
    RESET="${E}[0m"; BOLD="${E}[1m"; DIM="${E}[2m"
    RED="${E}[38;5;196m"; GREEN="${E}[38;5;46m"; YELLOW="${E}[38;5;226m"
    BLUE="${E}[38;5;39m"; MAGENTA="${E}[38;5;201m"; CYAN="${E}[38;5;51m"
    WHITE="${E}[38;5;231m"; ORANGE="${E}[38;5;208m"; GRAY="${E}[38;5;245m"
else
    E=""; RESET=""; BOLD=""; DIM=""
    RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""
    WHITE=""; ORANGE=""; GRAY=""
fi

# ---------------------------------- globais ---------------------------------
QUEUE=""; URI=""; SERIAL=""; NODE=""; USB_LINE=""; SYSFS=""; SPEED=""
SCANNER=""; JOB_ID=""; SCAN_ERR=""; PS_RAW=""; PS_PAPER=""; PS_SEL=""; PS_OK=""
HOSTNAME_S="${HOSTNAME:-$(hostname 2>/dev/null || echo localhost)}"

# --------------------------------- helpers ----------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

say()   { printf '%s\n' "$*"; }
info()  { printf '  %s[i]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()    { printf '  %s[OK]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()  { printf '  %s[!]%s %s\n' "$YELLOW" "$RESET" "$*"; }
err()   { printf '  %s[X]%s %s\n' "$RED" "$RESET" "$*"; }
title() { printf '\n%s== %s ==%s\n' "$BOLD$CYAN" "$*" "$RESET"; }
hr()    { printf '%s\n' "${GRAY}------------------------------------------------------------------------${RESET}"; }

ask() {
    local msg=$1 def=${2:-} ans
    if [[ -n $def ]]; then
        printf '  %s%s%s [%s]: ' "$WHITE" "$msg" "$RESET" "$def"
    else
        printf '  %s%s%s: ' "$WHITE" "$msg" "$RESET"
    fi
    IFS= read -r ans || ans=""
    [[ -z $ans ]] && ans=$def
    REPLY=$ans
}

ask_yesno() {
    local msg=$1 def=${2:-n} ans
    local hint="s/N"
    [[ $def == s* || $def == S* || $def == y* || $def == Y* ]] && hint="S/n"
    printf '  %s%s%s [%s]: ' "$WHITE" "$msg" "$RESET" "$hint"
    IFS= read -r ans || ans=""
    [[ -z $ans ]] && ans=$def
    [[ $ans =~ ^[sSyY] ]]
}

pause() { printf '\n'; IFS= read -r -p "  Pressione Enter para continuar..." _ || true; }

run_root() {
    if [[ $EUID -eq 0 ]]; then "$@"; return $?; fi
    if have sudo && sudo -n true 2>/dev/null; then sudo "$@"; return $?; fi
    "$@"
}

fix_owner() {
    local f=$1
    if [[ $EUID -eq 0 && -n $REAL_USER && $REAL_USER != root && -e $f ]]; then
        chown "$REAL_USER:$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")" "$f" 2>/dev/null || true
    fi
}

# ----------------------------- usuario e pastas -----------------------------
detect_real_user() {
    if [[ $EUID -eq 0 ]]; then
        if [[ -n ${SUDO_USER:-} ]]; then
            REAL_USER=$SUDO_USER
        else
            local cand
            cand=$(stat -c %U "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" 2>/dev/null)
            if [[ -n $cand && $cand != root ]]; then
                REAL_USER=$cand
            else
                cand=$(ls -1 /home 2>/dev/null | head -1)
                REAL_USER=${cand:-root}
            fi
        fi
    else
        REAL_USER=$(id -un)
    fi
    REAL_HOME=$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)
    [[ -z $REAL_HOME ]] && REAL_HOME=$HOME
}

desktop_dir() {
    local d=""
    if [[ -n $REAL_USER && $REAL_USER != root ]] && have runuser; then
        d=$(runuser -u "$REAL_USER" -- xdg-user-dir DESKTOP 2>/dev/null)
    fi
    [[ -z $d || ! -d $d ]] && d="$REAL_HOME/Desktop"
    [[ ! -d $d ]] && d="$REAL_HOME/Área de trabalho"
    [[ ! -d $d ]] && d="$REAL_HOME"
    printf '%s\n' "$d"
}

# ------------------------------- deteccao -----------------------------------
detect_queue() {
    local q=""
    q=$(lpstat -d 2>/dev/null | sed -n 's/^.*: //p')
    if [[ -z $q ]]; then
        q=$(lpstat -p 2>/dev/null | awk '/^printer/ {print $2; exit}')
    fi
    if [[ -n $QUEUE_PREFERRED ]] && lpstat -p "$QUEUE_PREFERRED" >/dev/null 2>&1; then
        q=$QUEUE_PREFERRED
    fi
    QUEUE=$q
}

detect_uri() {
    URI=""
    [[ -n $QUEUE ]] && URI=$(lpstat -v "$QUEUE" 2>/dev/null | sed -n 's/^.*: //p')
}

detect_serial() {
    SERIAL=""
    if [[ -n $URI && $URI =~ serial=([^&\ ]+) ]]; then
        SERIAL=${BASH_REMATCH[1]}
    fi
    [[ -z $SERIAL ]] && SERIAL=$SERIAL_DEFAULT
}

detect_node() {
    NODE=""; USB_LINE=""
    USB_LINE=$(lsusb -d "$USB_VID:$USB_PID" 2>/dev/null | head -1)
    if [[ -n $USB_LINE ]]; then
        local bus dev
        bus=$(sed -E 's/^Bus ([0-9]+) Device ([0-9]+).*/\1/' <<<"$USB_LINE")
        dev=$(sed -E 's/^Bus ([0-9]+) Device ([0-9]+).*/\2/' <<<"$USB_LINE")
        NODE=$(printf '/dev/bus/usb/%03d/%03d' "$((10#$bus))" "$((10#$dev))")
    fi
}

detect_sysfs() {
    SYSFS=""; SPEED=""
    [[ -z $NODE ]] && return
    local bus dev d
    bus=$((10#$(sed -E 's#/dev/bus/usb/([0-9]+)/.*#\1#' <<<"$NODE")))
    dev=$((10#$(sed -E 's#.*/([0-9]+)$#\1#' <<<"$NODE")))
    for d in /sys/bus/usb/devices/*/; do
        [[ -f $d/busnum && -f $d/devnum ]] || continue
        if [[ $(<"$d/busnum") == "$bus" && $(<"$d/devnum") == "$dev" ]]; then
            SYSFS=${d%/}
            break
        fi
    done
    [[ -n $SYSFS && -f $SYSFS/speed ]] && SPEED=$(<"$SYSFS/speed")
}

detect_scanner() {
    if [[ -n ${SCANNER_DEVICE:-} ]]; then SCANNER=$SCANNER_DEVICE; return; fi
    local slug=""
    if [[ -n $URI && $URI =~ usb://[^/]+/([^?]+) ]]; then
        slug=${BASH_REMATCH[1]//%20/_}
    fi
    [[ -z $slug ]] && slug="DeskJet_2300_series"
    SCANNER="hpaio:/usb/${slug}?serial=${SERIAL:-$SERIAL_DEFAULT}"
}

detect_all() {
    detect_queue
    detect_uri
    detect_serial
    detect_node
    detect_sysfs
    detect_scanner
}

usb_connected() { [[ -n $NODE && -e $NODE ]]; }

# --------------------------- status da porta USB ----------------------------
read_port_status() {
    PS_RAW=""; PS_PAPER=""; PS_SEL=""; PS_OK=""; PS_ERRMSG=""
    if ! have python3; then PS_ERRMSG="python3 ausente"; return 1; fi
    if ! usb_connected; then PS_ERRMSG="dispositivo USB nao encontrado"; return 1; fi
    local out rc
    out=$(timeout 10 python3 - "$NODE" 2>&1 <<'PY'
import ctypes, fcntl, os, sys
node = sys.argv[1]
class C(ctypes.Structure):
    _fields_ = [("rt", ctypes.c_uint8), ("rq", ctypes.c_uint8),
                ("v", ctypes.c_uint16), ("i", ctypes.c_uint16),
                ("l", ctypes.c_uint16), ("t", ctypes.c_uint32),
                ("d", ctypes.c_void_p)]
buf = ctypes.create_string_buffer(1)
c = C(); c.rt = 0xA1; c.rq = 1; c.v = 0; c.i = 1; c.l = 1; c.t = 3000
c.d = ctypes.cast(buf, ctypes.c_void_p)
fd = os.open(node, os.O_RDWR)
try:
    fcntl.ioctl(fd, 0xC0185500,
                bytearray(ctypes.string_at(ctypes.addressof(c), ctypes.sizeof(c))), True)
finally:
    os.close(fd)
x = buf.raw[0]
print("%d %d %d %d" % (x, 1 if x & 0x20 else 0, 1 if x & 0x10 else 0, 1 if x & 0x08 else 0))
PY
)
    rc=$?
    if [[ $rc -ne 0 || -z $out ]]; then
        PS_ERRMSG=${out:-"falha ao ler o status (dispositivo ocupado?)"}
        return 1
    fi
    read -r PS_RAW PS_PAPER PS_SEL PS_OK <<<"$out"
    return 0
}

# ----------------------------- banner e menu --------------------------------
gradient_text() {
    local text=$1
    local -a cols=(51 45 39 33 27 21 57 93 129 165 201 207 213)
    local n=${#cols[@]} len=${#text} i idx out=""
    for ((i=0; i<len; i++)); do
        idx=$(( i * n / (len > 0 ? len : 1) ))
        (( idx >= n )) && idx=$((n - 1))
        out+="${E}[38;5;${cols[$idx]}m${text:i:1}"
    done
    printf '%s%s\n' "$out" "$RESET"
}

print_banner() {
    [[ -t 1 ]] && clear 2>/dev/null
    detect_all
    local bar="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf '\n  %s%s┏%s┓%s\n' "$BOLD" "$CYAN" "$bar" "$RESET"
    printf '  '
    gradient_text "     H P   D E S K J E T   2 3 0 0   S E R I E S"
    printf '       %sCentral de Comando da Impressora%s\n' "$YELLOW" "$RESET"
    printf '  %s%s┗%s┛%s\n' "$BOLD" "$CYAN" "$bar" "$RESET"

    local qcol=$RED qtxt="nao configurada"
    if [[ -n $QUEUE ]] && lpstat -p "$QUEUE" >/dev/null 2>&1; then
        qcol=$GREEN; qtxt=$QUEUE
    fi
    local scol=$RED stxt="nao detectado"
    if [[ -n $SCANNER ]]; then
        scol=$GREEN; stxt=$SCANNER
    fi
    local ucol=$RED utxt="desconectada"
    if usb_connected; then
        ucol=$GREEN
        utxt=${USB_LINE%%:*}
    fi

    printf '  %s•%s Fila    : %s%s%s\n' "$qcol" "$RESET" "$WHITE" "$qtxt" "$RESET"
    printf '  %s•%s Scanner : %s%s%s\n' "$scol" "$RESET" "$WHITE" "$stxt" "$RESET"
    printf '  %s•%s USB     : %s%s%s\n' "$ucol" "$RESET" "$WHITE" "$utxt" "$RESET"
    printf '  %sUsuario: %s@%s   %s%s\n\n' "$DIM" "$REAL_USER" "$HOSTNAME_S" "$(date '+%d/%m/%Y %H:%M')" "$RESET"
}

print_menu() {
    hr
    printf '  %s1%s  Status completo (fila, USB, scanner, tinta)\n'  "$BOLD$CYAN" "$RESET"
    printf '  %s2%s  Imprimir arquivo (PDF, imagem, texto)\n'         "$BOLD$CYAN" "$RESET"
    printf '  %s3%s  Imprimir pagina de teste\n'                      "$BOLD$CYAN" "$RESET"
    printf '  %s4%s  Digitalizar (PDF/PNG/JPEG/TIFF)\n'               "$BOLD$CYAN" "$RESET"
    printf '  %s5%s  Xerox / copiar documento (digitalizar e imprimir)\n' "$BOLD$CYAN" "$RESET"
    printf '  %s6%s  Digitalizar rapido -> PDF na Area de Trabalho\n' "$BOLD$CYAN" "$RESET"
    printf '  %s7%s  Niveis de tinta / suprimentos\n'                 "$BOLD$CYAN" "$RESET"
    printf '  %s8%s  Gerenciar fila de impressao\n'                   "$BOLD$CYAN" "$RESET"
    printf '  %s9%s  Diagnostico e reparos\n'                         "$BOLD$CYAN" "$RESET"
    printf '  %s10%s Logs do sistema\n'                               "$BOLD$CYAN" "$RESET"
    printf '  %s11%s Informacoes e versoes\n'                         "$BOLD$CYAN" "$RESET"
    printf '  %s12%s Ajuda\n'                                         "$BOLD$CYAN" "$RESET"
    printf '  %s0%s  Sair\n'                                          "$BOLD$RED"  "$RESET"
    hr
}

# ------------------------------- formatacao ---------------------------------
fmt_bytes() {
    local b=${1:-0}
    if (( b >= 1048576 )); then printf '%.1f MB' "$(awk "BEGIN{print $b/1048576}")"
    elif (( b >= 1024 )); then printf '%.1f KB' "$(awk "BEGIN{print $b/1024}")"
    else printf '%d B' "$b"; fi
}

queue_state() {
    local out
    out=$(lpstat -p "$QUEUE" 2>/dev/null)
    if [[ $out == *"processando"* || $out == *"printing"* ]]; then
        echo "processando"
    elif [[ $out == *"desabilitada"* || $out == *"disabled"* ]]; then
        echo "desabilitada"
    elif [[ $out == *"inativa"* || $out == *"idle"* || $out == *"ociosa"* ]]; then
        echo "inativa (pronta)"
    else
        echo "desconhecido"
    fi
}

queue_accepting() {
    local out
    out=$(lpstat -a "$QUEUE" 2>/dev/null)
    if [[ $out == *"não"* || $out == *"not accepting"* || $out == *"rejeit"* ]]; then
        echo "nao"
    else
        echo "sim"
    fi
}

# -------------------------------- tinta -------------------------------------
ink_report() {
    if ! have hp-levels; then
        warn "hp-levels nao instalado (pacote hplip)."
        return 1
    fi
    local out rc
    out=$(timeout 45 hp-levels 2>&1); rc=$?
    if [[ $rc -ne 0 || $out == *"No device found"* ]]; then
        warn "Nao foi possivel ler os niveis de tinta."
        say  "  Possiveis causas: cartucho tricolor ausente/defeituoso ou canal"
        say  "  de status do HPLIP indisponivel. Verifique fisicamente os cartuchos."
        return 1
    fi
    printf '%s\n' "$out"
    return 0
}

# ------------------------------- impressao ----------------------------------
submit_job() {
    local out rc
    out=$("$@" 2>&1); rc=$?
    printf '%s\n' "$out"
    [[ $rc -ne 0 ]] && return 1
    JOB_ID=$(grep -oE '[[:alnum:]_.-]+-[0-9]+' <<<"$out" | tail -1)
    return 0
}

wait_job() {
    local id=$1 tmo=${2:-120} start now
    [[ -z $id ]] && return 0
    start=$(date +%s)
    while :; do
        if ! lpstat -o "$QUEUE" 2>/dev/null | awk '{print $1}' | grep -qx "$id"; then
            return 0
        fi
        now=$(date +%s)
        (( now - start >= tmo )) && return 2
        sleep 2
    done
}

print_precheck() {
    if read_port_status && [[ ${PS_OK:-1} == 0 ]]; then
        warn "A impressora reporta erro (status USB 0x$(printf '%02x' "$PS_RAW"))."
        say  "  Verifique: cartucho preto e tricolor, papel, tampa e a luz de erro."
        ask_yesno "Tentar imprimir mesmo assim?" n || return 1
    fi
    return 0
}

monitor_job() {
    local id=$1 tmo=${2:-120}
    [[ -z $id ]] && return 0
    info "Acompanhando job $id (ate ${tmo}s)..."
    if wait_job "$id" "$tmo"; then
        ok "Job concluido."
        return 0
    fi
    warn "O job ainda esta na fila apos ${tmo}s (a impressao pode ter travado)."
    say  "  Verifique o estado/erros (opcao 1) ou cancele a fila (opcao 8)."
    say  "  Se travou apos uma impressao, faca power cycle (opcao 9 > 7)."
    if ask_yesno "Cancelar este job agora?" s; then
        cancel "$id" >/dev/null 2>&1
        ok "Job cancelado."
    fi
    return 1
}

do_print_file() {
    detect_all
    title "Imprimir arquivo"
    [[ -z $QUEUE ]] && { err "Nenhuma fila de impressao configurada (opcao 9)."; return; }
    ask "Caminho do arquivo (PDF/imagem/texto)" ""
    local f=${REPLY/#\~/${REAL_HOME:-$HOME}}
    [[ -z $f ]] && { warn "Nada informado."; return; }
    f=${f%\"}; f=${f#\"}
    if [[ ! -f $f ]]; then err "Arquivo nao encontrado: $f"; return; fi

    ask "Copias" "1"
    local copies=$REPLY
    [[ $copies =~ ^[0-9]+$ ]] || { err "Numero de copias invalido."; return; }
    (( copies < 1 )) && copies=1

    say  "  Cor: 1) Colorida   2) Preto e branco"
    ask "Escolha" "1"
    local cmode="color"
    [[ $REPLY == 2 ]] && cmode="monochrome"

    say  "  Papel: 1) A4   2) Letter"
    ask "Escolha" "1"
    local media="A4"
    [[ $REPLY == 2 ]] && media="Letter"

    ask "Paginas (ex.: 1-2,3; vazio = todas)" ""
    local pages=$REPLY

    local args=(-d "$QUEUE" -n "$copies" -o "print-color-mode=$cmode" -o "media=$media")
    [[ -n $pages ]] && args+=(-P "$pages")

    say ""
    info "Fila: $QUEUE | copias: $copies | cor: $cmode | papel: $media"
    print_precheck || return

    if submit_job lp "${args[@]}" -- "$f"; then
        ok "Enviado."
        ask_yesno "Acompanhar a impressao?" s && monitor_job "$JOB_ID" 120
    else
        err "Falha ao enviar o job."
    fi
}

do_print_test() {
    detect_all
    title "Pagina de teste"
    [[ -z $QUEUE ]] && { err "Nenhuma fila configurada (opcao 9)."; return; }
    local f=$TESTPAGE
    [[ -f $f ]] || f="/usr/share/cups/data/default.pdf"
    [[ -f $f ]] || { err "Pagina de teste nao encontrada."; return; }

    say  "  Cor: 1) Colorida   2) Preto e branco"
    ask "Escolha" "1"
    local cmode="color"; [[ $REPLY == 2 ]] && cmode="monochrome"

    print_precheck || return
    if submit_job lp -d "$QUEUE" -o "media=A4" -o "print-color-mode=$cmode" -o "orientation-requested=3" -- "$f"; then
        ok "Pagina de teste enviada."
        ask_yesno "Acompanhar a impressao?" s && monitor_job "$JOB_ID" 120
    else
        err "Falha ao enviar a pagina de teste."
    fi
}

# ------------------------------ digitalizacao -------------------------------
scan_to_file() {
    # $1=arquivo $2=modo $3=resolucao $4=formato
    local path=$1 mode=$2 res=$3 fmt=$4 attempt rc
    SCAN_ERR=""
    local errf="$WORKDIR/scan.err"
    for attempt in 1 2 3; do
        timeout 240 scanimage --device-name "$SCANNER" --source Flatbed \
            --format="$fmt" --resolution="$res" --mode="$mode" > "$path" 2>"$errf"
        rc=$?
        if [[ $rc -eq 0 && -s $path ]] && (( $(stat -c%s "$path" 2>/dev/null || echo 0) > 1000 )); then
            return 0
        fi
        SCAN_ERR=$(tr '\n' ' ' <"$errf" 2>/dev/null)
        rm -f "$path" 2>/dev/null
        if [[ $SCAN_ERR == *"Device busy"* ]]; then
            warn "Dispositivo ocupado (tentativa $attempt/3). Aguardando..."
            sleep 6
        else
            sleep 4
        fi
    done
    return 1
}

scan_failure_hint() {
    err "Falha na digitalizacao${SCAN_ERR:+: $SCAN_ERR}"
    if [[ $SCAN_ERR == *"device I/O"* || $SCAN_ERR == *"sane_start"* ]]; then
        warn "A impressora parece travada apos uma impressao."
        say  "  Desligue da tomada por ~30 s, religue e tente novamente."
    elif [[ $SCAN_ERR == *"Device busy"* ]]; then
        warn "Dispositivo ocupado. Feche outros apps de digitalizacao/impressao."
    elif [[ $SCAN_ERR == *"permission"* || $SCAN_ERR == *"Permission"* ]]; then
        warn "Sem permissao para acessar o USB."
        say  "  Rode com sudo ou verifique as regras udev/grupos (lpadmin)."
    fi
}

do_scan() {
    detect_all
    title "Digitalizar"
    if ! usb_connected; then err "Impressora desconectada (USB)."; return; fi

    say  "  Modo: 1) Colorida   2) Tons de cinza   3) Lineart (texto)"
    ask "Escolha" "1"
    local mode="Color"
    case $REPLY in 2) mode="Gray";; 3) mode="Lineart";; esac

    say  "  Resolucao: 75  100  150  200  300  600  1200 dpi"
    ask "Resolucao" "300"
    local res=$REPLY
    [[ $res =~ ^(75|100|150|200|300|600|1200)$ ]] || { err "Resolucao invalida."; return; }

    say  "  Formato: 1) PDF   2) PNG   3) JPEG   4) TIFF"
    ask "Escolha" "1"
    local fmt="pdf"
    case $REPLY in 2) fmt="png";; 3) fmt="jpeg";; 4) fmt="tiff";; esac

    local dir; dir=$(desktop_dir)
    ask "Pasta de destino" "$dir"
    dir=${REPLY/#\~/${REAL_HOME:-$HOME}}
    [[ -d $dir ]] || { err "Pasta inexistente: $dir"; return; }

    ask "Nome do arquivo (sem extensao)" "Documento_$(date +%Y-%m-%d_%H%M%S)"
    local base=$REPLY
    base=$(sed -E 's#[/\\]#_#g; s/[[:space:]]+/_/g' <<<"$base")
    base=${base%.*}
    local out="$dir/${base}.${fmt}"

    if [[ -e $out ]] && ! ask_yesno "Arquivo ja existe. Sobrescrever?" n; then
        warn "Cancelado."; return
    fi

    if lpstat -o "$QUEUE" 2>/dev/null | grep -q .; then
        warn "Ha jobs na fila; o scanner pode ficar ocupado."
        ask_yesno "Continuar mesmo assim?" s || return
    fi

    info "Digitalizando ${res}dpi ${mode} -> ${out}"
    if scan_to_file "$out" "$mode" "$res" "$fmt"; then
        fix_owner "$out"
        ok "Salvo: $out ($(fmt_bytes "$(stat -c%s "$out")"))"
        if [[ $fmt == pdf ]] && have pdfinfo; then
            pdfinfo "$out" 2>/dev/null | grep -E 'Pages|Page size' | sed 's/^/  /'
        fi
        ask_yesno "Abrir o arquivo agora?" n && open_file "$out"
    else
        scan_failure_hint
    fi
}

do_quick_pdf() {
    detect_all
    title "Digitalizar rapido -> PDF na Area de Trabalho"
    if ! usb_connected; then err "Impressora desconectada (USB)."; return; fi
    local dir out
    dir=$(desktop_dir)
    out="$dir/Documento_$(date +%Y-%m-%d_%H%M%S).pdf"
    info "Colorida 300dpi -> $out"
    if scan_to_file "$out" "Color" "300" "pdf"; then
        fix_owner "$out"
        ok "Salvo: $out ($(fmt_bytes "$(stat -c%s "$out")"))"
        ask_yesno "Abrir o arquivo agora?" n && open_file "$out"
    else
        scan_failure_hint
    fi
}

do_xerox() {
    detect_all
    title "Xerox / copiar documento"
    if ! usb_connected; then err "Impressora desconectada (USB)."; return; fi
    [[ -z $QUEUE ]] && { err "Nenhuma fila configurada (opcao 9)."; return; }

    ask "Copias" "1"
    local copies=$REPLY
    [[ $copies =~ ^[0-9]+$ ]] || { err "Numero de copias invalido."; return; }
    (( copies < 1 )) && copies=1

    say  "  Impressao: 1) Preto e branco   2) Colorida"
    ask "Escolha" "1"
    local cmode="monochrome" smode="Gray"
    [[ $REPLY == 2 ]] && { cmode="color"; smode="Color"; }

    say  "  Resolucao do scan: 200  300  600 dpi"
    ask "Resolucao" "300"
    local res=$REPLY
    [[ $res =~ ^(200|300|600)$ ]] || { err "Resolucao invalida."; return; }

    say  "  Papel: 1) A4   2) Letter"
    ask "Escolha" "1"
    local media="A4"; [[ $REPLY == 2 ]] && media="Letter"

    local tmp="$WORKDIR/xerox-$$.pdf"
    info "Passo 1/2: digitalizando (${res}dpi ${smode})..."
    if ! scan_to_file "$tmp" "$smode" "$res" "pdf"; then
        scan_failure_hint
        return
    fi
    ok "Scan concluido ($(fmt_bytes "$(stat -c%s "$tmp")"))."
    print_precheck || { rm -f "$tmp"; return; }

    info "Passo 2/2: imprimindo $copies copia(s)..."
    if submit_job lp -d "$QUEUE" -n "$copies" -o "media=$media" -o "print-color-mode=$cmode" -- "$tmp"; then
        ok "Xerox enviada."
        if ask_yesno "Acompanhar a impressao?" s; then
            if ! monitor_job "$JOB_ID" 150; then
                local dir; dir=$(desktop_dir)
                local keep="$dir/Xerox_$(date +%Y-%m-%d_%H%M%S).pdf"
                cp -f "$tmp" "$keep" 2>/dev/null && fix_owner "$keep"
                warn "Impressao nao concluiu; o scan foi salvo em: $keep"
            fi
        fi
    else
        err "Falha ao imprimir a xerox."
        local dir; dir=$(desktop_dir)
        local keep="$dir/Xerox_$(date +%Y-%m-%d_%H%M%S).pdf"
        cp -f "$tmp" "$keep" 2>/dev/null && fix_owner "$keep"
        warn "O scan foi mantido em: $keep"
    fi
    rm -f "$tmp"
}

open_file() {
    local f=$1
    [[ -z ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]] && { info "Abra manualmente: $f"; return; }
    if [[ $EUID -eq 0 && $REAL_USER != root ]] && have runuser; then
        runuser -u "$REAL_USER" -- env DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" xdg-open "$f" >/dev/null 2>&1 &
    else
        xdg-open "$f" >/dev/null 2>&1 &
    fi
}

# -------------------------------- status ------------------------------------
do_status() {
    detect_all
    title "Status completo"

    if [[ -z $QUEUE ]]; then
        err "Nenhuma fila CUPS configurada."
    else
        ok "Fila: $QUEUE"
        say  "     Estado   : $(queue_state)"
        say  "     Aceitando: $(queue_accepting)"
        say  "     URI      : ${URI:-<desconhecida>}"
        local jobs
        jobs=$(lpstat -o "$QUEUE" 2>/dev/null)
        if [[ -n $jobs ]]; then
            warn "Jobs na fila:"
            printf '%s\n' "$jobs" | sed 's/^/       /'
        else
            say  "     Jobs     : nenhum"
        fi
    fi

    hr
    if usb_connected; then
        ok "USB: ${USB_LINE%%:*}"
        say  "     No do dispositivo: $NODE"
        [[ -n $SYSFS ]] && say "     Sysfs: $SYSFS"
        [[ -n $SPEED ]] && say "     Velocidade: ${SPEED} Mbps"
        if read_port_status; then
            local st="sem erro"
            [[ ${PS_OK:-1} == 0 ]] && st="ERRO reportado"
            say  "     Porta: 0x$(printf '%02x' "$PS_RAW") ($st)"
            say  "     Papel vazio: $([[ $PS_PAPER == 1 ]] && echo sim || echo nao) | Selecionada: $([[ $PS_SEL == 1 ]] && echo sim || echo nao)"
            if [[ ${PS_OK:-1} == 0 ]]; then
                warn "Estado de erro na impressora. Verifique cartuchos/papel/tampa."
            fi
        else
            warn "Nao foi possivel ler a porta USB: $PS_ERRMSG"
        fi
    else
        err "Impressora USB nao detectada (${USB_VID}:${USB_PID})."
    fi

    hr
    say  "Scanner (SANE): ${SCANNER:-<nao definido>}"
    say  "     Verificacao rapida:"
    if have scanimage; then
        if timeout 10 scanimage --device-name "$SCANNER" -A >/dev/null 2>"$WORKDIR/sane.err"; then
            say  "       dispositivo respondeu OK"
        else
            say  "       sem resposta agora ($(tr '\n' ' ' <"$WORKDIR/sane.err" 2>/dev/null))"
        fi
    else
        warn "scanimage nao instalado."
    fi

    hr
    say  "Tinta / suprimentos:"
    ink_report || true
}

# ------------------------------- fila ---------------------------------------
do_queue() {
    detect_all
    while :; do
        title "Gerenciar fila"
        [[ -z $QUEUE ]] && { err "Nenhuma fila configurada."; pause; return; }
        say  "Fila: $QUEUE | $(queue_state) | aceitando: $(queue_accepting)"
        hr
        printf '  1) Listar jobs\n'
        printf '  2) Detalhes da fila\n'
        printf '  3) Cancelar um job\n'
        printf '  4) Cancelar todos os jobs\n'
        printf '  5) Pausar impressora\n'
        printf '  6) Retomar impressora\n'
        printf '  7) Rejeitar novos jobs\n'
        printf '  8) Aceitar novos jobs\n'
        printf '  9) Definir como padrao\n'
        printf '  0) Voltar\n'
        hr
        ask "Escolha" "0"
        case $REPLY in
            1) local j; j=$(lpstat -o "$QUEUE" 2>/dev/null); [[ -n $j ]] && printf '%s\n' "$j" || say "  (nenhum job)"; pause ;;
            2) lpstat -l -p "$QUEUE" 2>/dev/null | sed 's/^/  /'; pause ;;
            3)
                ask "ID do job" ""
                [[ -n $REPLY ]] && { cancel "$REPLY" 2>&1 && ok "Cancelado: $REPLY" || err "Falha ao cancelar."; } || warn "Nada informado."
                pause ;;
            4) ask_yesno "Cancelar TODOS os jobs de $QUEUE?" n && { cancel -a "$QUEUE" 2>&1; ok "Solicitado."; }; pause ;;
            5) run_root cupsdisable "$QUEUE" 2>&1 && ok "Pausada."; pause ;;
            6) run_root cupsenable "$QUEUE" 2>&1 && ok "Retomada."; pause ;;
            7) run_root cupsreject "$QUEUE" 2>&1 && ok "Rejeitando novos jobs."; pause ;;
            8) run_root cupsaccept "$QUEUE" 2>&1 && ok "Aceitando novos jobs."; pause ;;
            9) run_root lpadmin -d "$QUEUE" 2>&1 && ok "Padrao definido."; pause ;;
            0) return ;;
            *) warn "Opcao invalida." ;;
        esac
    done
}

# ---------------------------- diagnostico -----------------------------------
do_repair() {
    detect_all
    while :; do
        title "Diagnostico e reparos"
        hr
        printf '  1) Verificacao completa (health check)\n'
        printf '  2) Criar/reparar fila (URI USB + PPD hpcups)\n'
        printf '  3) Recriar quirk USB e reiniciar CUPS\n'
        printf '  4) Reset USB logico (sem desligar)\n'
        printf '  5) Reiniciar CUPS\n'
        printf '  6) Cancelar jobs e liberar dispositivo\n'
        printf '  7) Como destravar (power cycle)\n'
        printf '  0) Voltar\n'
        hr
        ask "Escolha" "0"
        case $REPLY in
            1) health_check; pause ;;
            2) repair_queue; pause ;;
            3) repair_quirk; pause ;;
            4) usb_reset; pause ;;
            5) restart_cups; pause ;;
            6) free_device; pause ;;
            7) power_cycle_help; pause ;;
            0) return ;;
            *) warn "Opcao invalida." ;;
        esac
    done
}

health_check() {
    detect_all
    title "Health check"
    local fail=0
    if usb_connected; then ok "USB presente: ${USB_LINE%%:*}"; else err "USB ausente"; fail=1; fi

    if [[ -n $QUEUE ]] && lpstat -p "$QUEUE" >/dev/null 2>&1; then
        ok "Fila existe: $QUEUE"
        [[ $(queue_accepting) == sim ]] || { warn "Fila nao esta aceitando jobs"; fail=1; }
        [[ $(queue_state) == *desabilitada* ]] && { warn "Fila desabilitada"; fail=1; }
        [[ $URI == usb://* ]] && ok "URI usa backend USB padrao" || { warn "URI inesperada: $URI"; fail=1; }
    else
        err "Fila ausente ou invalida"; fail=1
    fi

    if read_port_status; then
        if [[ ${PS_OK:-1} == 1 ]]; then ok "Porta USB sem erro (0x$(printf '%02x' "$PS_RAW"))"; else warn "Porta USB em erro (0x$(printf '%02x' "$PS_RAW"))"; fi
    else
        warn "Porta USB nao respondeu: $PS_ERRMSG"
    fi

    if [[ -f $QUIRK_FILE ]]; then ok "Quirk presente: $QUIRK_FILE"; else warn "Quirk ausente (opcao 3)"; fi

    if have scanimage; then
        if timeout 10 scanimage --device-name "$SCANNER" -A >/dev/null 2>&1; then
            ok "Scanner respondeu"
        else
            warn "Scanner nao respondeu agora (pode estar ocupado/travado)"
        fi
    else
        warn "scanimage ausente"
    fi

    [[ $fail -eq 0 ]] && ok "Verificacao concluida." || warn "Ha pendencias acima."
}

repair_queue() {
    detect_all
    title "Criar/reparar fila"
    local q=${QUEUE:-$QUEUE_PREFERRED}
    ask "Nome da fila" "$q"
    q=$REPLY
    [[ -z $q ]] && { warn "Cancelado."; return; }

    ask "Serial da impressora" "${SERIAL:-$SERIAL_DEFAULT}"
    local sn=$REPLY
    local uri="usb://HP/DeskJet%202300%20series?serial=${sn}&interface=1"

    info "Fila: $q"
    info "URI : $uri"
    info "PPD : $PPD_MODEL"
    ask_yesno "Aplicar agora?" s || { warn "Cancelado."; return; }

    if lpstat -p "$q" >/dev/null 2>&1; then
        run_root lpadmin -p "$q" -v "$uri" 2>&1
    else
        run_root lpadmin -p "$q" -E -v "$uri" -m "$PPD_MODEL" 2>&1
    fi
    run_root cupsaccept "$q" 2>&1
    run_root cupsenable "$q" 2>&1
    if ask_yesno "Definir $q como padrao?" s; then
        run_root lpadmin -d "$q" 2>&1
    fi
    detect_all
    ok "Configuracao aplicada."
}

repair_quirk() {
    title "Quirk USB + reiniciar CUPS"
    say  "Arquivo: $QUIRK_FILE"
    say  "Conteudo: 0x${USB_VID} 0x${USB_PID} unidir no-reattach"
    ask_yesno "Criar/atualizar e reiniciar o CUPS?" s || return
    printf '0x%s 0x%s unidir no-reattach\n' "$USB_VID" "$USB_PID" | run_root tee "$QUIRK_FILE" >/dev/null
    if [[ -f $QUIRK_FILE ]]; then
        ok "Quirk gravado."
        restart_cups
    else
        err "Nao foi possivel gravar (rode com sudo)."
    fi
}

usb_reset() {
    title "Reset USB logico"
    detect_all
    usb_connected || { err "Dispositivo nao encontrado."; return; }
    say  "No: $NODE"
    ask_yesno "Enviar reset USB agora?" s || return
    if timeout 10 python3 - "$NODE" >/dev/null 2>&1 <<'PY'
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_WRONLY)
try:
    fcntl.ioctl(fd, 0x5514, 0)
finally:
    os.close(fd)
PY
    then
        ok "Reset enviado. Aguardando reenumeracao..."
        sleep 5
        detect_all
        usb_connected && ok "Dispositivo presente: ${USB_LINE%%:*}" || warn "Nao reapareceu; use power cycle (opcao 7)."
    else
        err "Falha no reset (tente com sudo)."
    fi
}

restart_cups() {
    title "Reiniciar CUPS"
    ask_yesno "Reiniciar o servico de impressao?" s || return
    if run_root systemctl restart cups 2>&1; then
        ok "CUPS reiniciado."
    else
        err "Falha ao reiniciar (tente: sudo systemctl restart cups)"
    fi
    sleep 2
    detect_all
}

free_device() {
    title "Cancelar jobs e liberar dispositivo"
    detect_all
    [[ -n $QUEUE ]] && cancel -a "$QUEUE" 2>/dev/null && ok "Jobs cancelados."
    usb_connected || { warn "Dispositivo USB ausente."; return; }
    say  "Processos com o dispositivo aberto:"
    local holders
    holders=$(run_root fuser "$NODE" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | sort -u)
    if [[ -z $holders ]]; then
        say  "  (nenhum)"
        return
    fi
    local pid comm
    for pid in $holders; do
        comm=$(ps -p "$pid" -o comm= 2>/dev/null)
        printf '  PID %-7s %s\n' "$pid" "${comm:-?}"
    done
    ask_yesno "Encerrar backends travados (usb/hp/scanimage)?" s || return
    for pid in $holders; do
        comm=$(ps -p "$pid" -o comm= 2>/dev/null)
        case $comm in
            usb|hp|scanimage)
                kill -KILL "$pid" 2>/dev/null && ok "Encerrado PID $pid ($comm)"
                ;;
            *)
                warn "Ignorando PID $pid ($comm)"
                ;;
        esac
    done
}

power_cycle_help() {
    title "Como destravar a impressora"
    say " 1) Cancele os jobs (opcao 8 ou 6)."
    say " 2) Desligue a impressora da TOMADA (nao apenas o botao)."
    say " 3) Aguarde ~30 segundos."
    say " 4) Religue e aguarde a luz estabilizar."
    say " 5) Rode a opcao 9 > 1 (health check) para confirmar."
    say ""
    say " Isso limpa o estado USB travado apos uma impressao interrompida"
    say " e costuma restaurar a digitalizacao imediatamente."
}

# -------------------------------- logs --------------------------------------
do_logs() {
    while :; do
        title "Logs do sistema"
        hr
        printf '  1) CUPS error_log (ultimas 80 linhas)\n'
        printf '  2) journalctl do CUPS (40 linhas)\n'
        printf '  3) dmesg USB recente\n'
        printf '  0) Voltar\n'
        hr
        ask "Escolha" "0"
        case $REPLY in
            1) run_root tail -n 80 /var/log/cups/error_log 2>&1 | sed 's/^/  /'; pause ;;
            2) journalctl -u cups -n 40 --no-pager 2>&1 | sed 's/^/  /'; pause ;;
            3) dmesg 2>/dev/null | grep -iE 'usb|03f0|deskjet' | tail -n 25 | sed 's/^/  /'; pause ;;
            0) return ;;
            *) warn "Opcao invalida." ;;
        esac
    done
}

# -------------------------------- info --------------------------------------
do_info() {
    detect_all
    title "Informacoes e versoes"
    say  "Modelo        : $PRINTER_MODEL"
    say  "Fila          : ${QUEUE:-<nenhuma>}"
    say  "URI           : ${URI:-<desconhecida>}"
    say  "Serial        : ${SERIAL:-<desconhecido>}"
    say  "Scanner SANE  : ${SCANNER:-<nao definido>}"
    say  "USB           : ${USB_LINE:-<ausente>}"
    say  "No USB        : ${NODE:-<ausente>}"
    [[ -n $SYSFS ]] && say "Sysfs         : $SYSFS"
    [[ -n $SPEED ]] && say "Velocidade    : ${SPEED} Mbps"
    if [[ -n $SYSFS && -e $SYSFS/authorized ]]; then
        say "Autorizado    : $(<"$SYSFS/authorized")"
    fi
    if [[ -n $SYSFS ]]; then
        local ifc drv found=0
        for ifc in "$SYSFS":*; do
            [[ -e $ifc/driver ]] || continue
            drv=$(readlink "$ifc/driver" 2>/dev/null)
            say "Driver ${ifc##*:}    : ${drv##*/}"
            found=1
        done
        [[ $found -eq 0 ]] && say "Driver        : (nenhum)"
    fi
    say  "Quirk         : $([[ -f $QUIRK_FILE ]] && echo presente || echo ausente)"
    hr
    if have dpkg-query; then
        say "CUPS          : $(dpkg-query -W -f='${Version}' cups 2>/dev/null || echo '?')"
    fi
    if have hp-probe; then
        local hv
        hv=$(timeout 12 hp-probe -b usb 2>/dev/null | grep -oE 'ver\. [0-9.]+' | head -1)
        say "HPLIP         : ${hv:-?}"
    fi
    if have scanimage; then
        say "SANE          : $(scanimage --version 2>/dev/null | head -1)"
    fi
    say "Kernel        : $(uname -r)"
}

# -------------------------------- ajuda -------------------------------------
do_help() {
    title "Ajuda rapida"
    say "1  Status completo .... fila, USB, estado da porta, scanner e tinta."
    say "2  Imprimir arquivo ... PDF, imagem ou texto; copias, cor, papel e paginas."
    say "3  Pagina de teste .... verifica o caminho de impressao."
    say "4  Digitalizar ........ PDF/PNG/JPEG/TIFF, cor/cinza/lineart e dpi."
    say "5  Xerox .............. digitaliza e imprime em seguida."
    say "6  PDF rapido ......... colorido 300dpi direto na Area de Trabalho."
    say "7  Tinta .............. niveis dos cartuchos (HPLIP)."
    say "8  Fila ............... listar/cancelar/pausar/retomar/definir padrao."
    say "9  Diagnostico ........ health check, reparar fila/quirk, reset USB."
    say "10 Logs ............... CUPS, journalctl e dmesg."
    say "11 Informacoes ........ versoes e identificacao do dispositivo."
    say ""
    say "Dicas:"
    say " - Scan funciona mesmo sem tinta; impressao exige cartuchos e sem erro."
    say " - Se o scan der 'device I/O', faca power cycle (opcao 9 > 7)."
    say " - Estado USB 0x10 indica erro reportado pela impressora."
    say ""
    say "Variaveis: SCANNER_DEVICE, NO_COLOR=1, FORCE_COLOR=1"
}

# -------------------------------- principal ---------------------------------
usage() {
    cat <<EOF
Uso: $(basename "$0") [--test|--help]

  (sem argumentos)  Abre o menu interativo.
  --test            Mostra o status completo e sai.
  --help            Mostra esta ajuda.
EOF
}

main() {
    detect_real_user
    WORKDIR="${TMPDIR:-/tmp}/impressora-hp-${REAL_USER}"
    mkdir -p "$WORKDIR" 2>/dev/null
    if [[ $EUID -eq 0 && $REAL_USER != root ]]; then
        chown "$REAL_USER" "$WORKDIR" 2>/dev/null || true
    fi

    case ${1:-} in
        --help|-h) usage; exit 0 ;;
        --test|-t) detect_all; do_status; exit 0 ;;
        "") : ;;
        *) usage; exit 1 ;;
    esac

    detect_all
    while :; do
        print_banner
        print_menu
        printf '  %sEscolha:%s ' "$BOLD" "$RESET"
        IFS= read -r opt || break
        case $opt in
            1)  do_status; pause ;;
            2)  do_print_file; pause ;;
            3)  do_print_test; pause ;;
            4)  do_scan; pause ;;
            5)  do_xerox; pause ;;
            6)  do_quick_pdf; pause ;;
            7)  if ink_report; then :; fi; pause ;;
            8)  do_queue ;;
            9)  do_repair ;;
            10) do_logs ;;
            11) do_info; pause ;;
            12) do_help; pause ;;
            0|q|Q) break ;;
            *)  warn "Opcao invalida."; sleep 1 ;;
        esac
    done
    [[ -t 1 ]] && clear 2>/dev/null
    printf '%s%sAte logo!%s\n' "$BOLD" "$CYAN" "$RESET"
}

main "$@"
