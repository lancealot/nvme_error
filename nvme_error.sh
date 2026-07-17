#!/bin/bash
# =============================================================================
# NVMe AER Error Monitor
# =============================================================================
#
# Description:
#   Live, colorized monitor for PCIe Advanced Error Reporting (AER) on NVMe
#   controllers.  Polls each controller's AER capability registers, decodes
#   the correctable and uncorrectable status bits into human-readable error
#   names, and tracks per-device event totals along with a rolling log of
#   recent error events.
#
# Operation:
#   - Discovers NVMe controllers by scanning PCI class 0x0108 in sysfs
#   - Maps controllers to nvmeX names and reads serial/model from sysfs
#   - Reads the AER correctable (+0x10) and uncorrectable (+0x04) status
#     registers via setpci, decodes the latched bits, then clears them by
#     writing the observed value back (write-1-to-clear), so each poll
#     reports only new events
#   - Renders on the terminal's alternate screen (like htop/less), leaving
#     your scrollback history intact, and prints a session summary on exit
#
# Semantics:
#   AER status registers are latching bitmasks, not counters: a set bit
#   means that error type occurred at least once since the register was
#   last cleared.  Counts shown are "error events observed" (one per bit
#   per poll), so sustained bursts within one interval are undercounted.
#
# Output columns:
#   - S:           health dot (green ok, yellow correctable errors seen,
#                  red uncorrectable errors seen, dim no AER capability)
#   - DEVICE:      NVMe controller name (e.g. nvme0)
#   - PCI ADDR:    PCI address of the controller
#   - SERIAL:      drive serial number (from sysfs)
#   - MODEL:       drive model (from sysfs)
#   - LINK:        current PCIe link (yellow ! if below the drive's max)
#   - NEW:         error events in the last poll interval
#   - CORR/UNC:    correctable / uncorrectable events since start
#   - LAST ERROR:  time and decoded type(s) of the most recent error
#
# Dependencies:
#   - bash >= 4.2
#   - setpci (pciutils)
#   - Linux sysfs (/sys/bus/pci, /sys/class/nvme)
# =============================================================================

VERSION="2.0.0"

# sysfs root (overridable for testing)
SYS="${NVME_ERROR_SYS:-/sys}"

# =============================================================================
# AER status bit definitions (PCIe spec, AER extended capability)
# =============================================================================

# Correctable Error Status register, offset +0x10
CORR_DEF=(
    "0:RxErr"        # Receiver Error
    "6:BadTLP"       # Bad TLP
    "7:BadDLLP"      # Bad DLLP
    "8:Rollover"     # REPLAY_NUM Rollover
    "12:Timeout"     # Replay Timer Timeout
    "13:AdvNF"       # Advisory Non-Fatal Error
    "14:IntErr"      # Corrected Internal Error
    "15:HdrOF"       # Header Log Overflow
)

# Uncorrectable Error Status register, offset +0x04
UNC_DEF=(
    "4:DLP"          # Data Link Protocol Error
    "5:SDES"         # Surprise Down Error
    "12:PoisonTLP"   # Poisoned TLP
    "13:FCP"         # Flow Control Protocol Error
    "14:CmpltTO"     # Completion Timeout
    "15:CmpltAbrt"   # Completer Abort
    "16:UnxCmplt"    # Unexpected Completion
    "17:RxOF"        # Receiver Overflow
    "18:MalfTLP"     # Malformed TLP
    "19:ECRC"        # ECRC Error
    "20:UnsupReq"    # Unsupported Request
    "21:ACSViol"     # ACS Violation
    "22:UncIntErr"   # Uncorrectable Internal Error
    "23:MCBlkTLP"    # MC Blocked TLP
    "24:AtomicBlk"   # AtomicOp Egress Blocked
    "25:TLPPfxBlk"   # TLP Prefix Blocked
    "26:PoisonEgr"   # Poisoned TLP Egress Blocked
)

# =============================================================================
# CLI handling
# =============================================================================

die() {
    printf '%s: %s\n' "${0##*/}" "$*" >&2
    exit 1
}

show_help() {
    cat << EOF
Usage: ${0##*/} [OPTIONS]

Monitor NVMe device errors using PCIe Advanced Error Reporting (AER).

Options:
    -d          Print one status snapshot and exit
    -j          Print one snapshot as JSON and exit
    -i SECONDS  Refresh interval for live mode (default: 2)
    -l FILE     Append every error event to FILE with full timestamps
    -n          Passive mode: do not clear AER status registers after
                reading (counts then reflect latched status, not deltas)
    -h          Show this help and exit

Interactive keys (live mode):
    q  quit and print a session summary
    r  reset session counters and the recent-event list

Without options the script runs a full-screen live view, updating every
2 seconds.  It draws on the terminal's alternate screen, so your
scrollback history is preserved and restored when you quit.

Notes:
    * Requires root (setpci needs raw PCI config space access).
    * AER status registers are latching bitmasks: counts are error events
      observed per poll, so bursts within one interval count once.
    * Colors honor NO_COLOR and are disabled when output is not a TTY.
EOF
    exit 0
}

SINGLE_RUN=false
JSON_OUTPUT=false
NO_RESET=false
INTERVAL=2
LOG_FILE=""

while getopts ":dji:l:nh" opt; do
    case $opt in
        d)  SINGLE_RUN=true ;;
        j)  JSON_OUTPUT=true ;;
        i)  INTERVAL=$OPTARG ;;
        l)  LOG_FILE=$OPTARG ;;
        n)  NO_RESET=true ;;
        h)  show_help ;;
        :)  die "option -$OPTARG requires an argument (use -h for help)" ;;
        *)  die "invalid option: -$OPTARG (use -h for help)" ;;
    esac
done
shift $((OPTIND - 1))
[[ $# -gt 0 ]] && die "unexpected argument: $1 (use -h for help)"

# =============================================================================
# Environment checks
# =============================================================================

(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )) \
    || die "bash 4.2 or newer is required"

[[ $INTERVAL =~ ^[0-9]*\.?[0-9]+$ && -n ${INTERVAL//[.0]/} ]] \
    || die "invalid interval '$INTERVAL' (need a number > 0)"

command -v setpci > /dev/null 2>&1 \
    || die "setpci not found (install the pciutils package)"

[[ -d $SYS/bus/pci/devices ]] \
    || die "PCI sysfs tree not found at $SYS/bus/pci"

(( EUID == 0 )) \
    || die "must be run as root (setpci needs PCI config space access)"

if [[ -n $LOG_FILE ]]; then
    : >> "$LOG_FILE" 2> /dev/null || die "cannot write to log file '$LOG_FILE'"
fi

# =============================================================================
# Terminal setup
# =============================================================================

IS_TTY=false
[[ -t 1 ]] && IS_TTY=true

USE_COLOR=false
if [[ $IS_TTY == true && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
    USE_COLOR=true
fi

if [[ $USE_COLOR == true ]]; then
    C_RESET=$(tput sgr0 2> /dev/null)
    C_BOLD=$(tput bold 2> /dev/null)
    C_DIM=$(tput dim 2> /dev/null)
    C_RED=$(tput setaf 1 2> /dev/null)
    C_GREEN=$(tput setaf 2 2> /dev/null)
    C_YELLOW=$(tput setaf 3 2> /dev/null)
    C_CYAN=$(tput setaf 6 2> /dev/null)
else
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN=""
fi

# Unicode glyphs with ASCII fallback
case ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} in
    *[Uu][Tt][Ff]8* | *[Uu][Tt][Ff]-8*)
        GLYPH_DOT="●" GLYPH_RULE="─" GLYPH_SEP="·" ;;
    *)
        GLYPH_DOT="*" GLYPH_RULE="-" GLYPH_SEP="|" ;;
esac

# Alternate-screen management: keeps the user's scrollback intact.  On
# terminals without smcup/rmcup (e.g. the Linux console) fall back to a
# plain visible-screen clear, which still never touches scrollback.
IN_ALT_SCREEN=false
HAS_ALT_SCREEN=false

enter_screen() {
    local alt
    alt=$(tput smcup 2> /dev/null)
    if [[ -n $alt ]]; then
        printf '%s' "$alt"
        HAS_ALT_SCREEN=true
    else
        printf '\e[2J\e[H'
    fi
    tput civis 2> /dev/null   # hide cursor
    printf '\e[?7l'           # disable line wrap so long rows clip cleanly
    IN_ALT_SCREEN=true
}

leave_screen() {
    [[ $IN_ALT_SCREEN == true ]] || return 0
    printf '\e[?7h'
    tput cnorm 2> /dev/null
    [[ $HAS_ALT_SCREEN == true ]] && tput rmcup 2> /dev/null
    [[ -t 0 ]] && stty echo 2> /dev/null
    IN_ALT_SCREEN=false
}

MONITOR_RAN=false

on_exit() {
    leave_screen
    [[ $MONITOR_RAN == true ]] && print_summary
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# =============================================================================
# Device discovery and static info (all from sysfs)
# =============================================================================

declare -A NVME_OF SERIAL_OF MODEL_OF FW_OF
PCI_DEVS=()
DISPLAY_ORDER=()

sysval() {
    local v=""
    [[ -r $1 ]] && IFS=$' \t\n' read -r v < "$1" 2> /dev/null
    printf '%s' "$v"
}

sysline() {
    # like sysval but keeps internal whitespace (for model strings)
    local v=""
    [[ -r $1 ]] && read -r v < "$1" 2> /dev/null
    printf '%s' "$v"
}

discover_devices() {
    local class_file class addr ctrl link name
    PCI_DEVS=()
    NVME_OF=() SERIAL_OF=() MODEL_OF=() FW_OF=()

    # every PCI function with class 0x0108xx (non-volatile memory controller)
    for class_file in "$SYS"/bus/pci/devices/*/class; do
        [[ -r $class_file ]] || continue
        read -r class < "$class_file"
        [[ $class == 0x0108* ]] || continue
        addr=${class_file%/class}
        PCI_DEVS+=("${addr##*/}")
    done

    # map nvme controller names and identity onto PCI addresses
    for ctrl in "$SYS"/class/nvme/nvme*; do
        [[ -e $ctrl ]] || continue
        link=$(readlink -f "$ctrl/device" 2> /dev/null) || continue
        addr=${link##*/}
        [[ -e $SYS/bus/pci/devices/$addr ]] || continue
        name=${ctrl##*/}
        NVME_OF[$addr]=$name
        SERIAL_OF[$addr]=$(sysval "$ctrl/serial")
        MODEL_OF[$addr]=$(sysline "$ctrl/model")
        FW_OF[$addr]=$(sysval "$ctrl/firmware_rev")
    done

    # display order: by nvme number, then unbound controllers by PCI address
    local entry lines=()
    DISPLAY_ORDER=()
    for addr in "${PCI_DEVS[@]}"; do
        name=${NVME_OF[$addr]:-}
        if [[ $name =~ ^nvme([0-9]+)$ ]]; then
            lines+=("$(printf '0%08d' "${BASH_REMATCH[1]}") $addr")
        else
            lines+=("1$addr $addr")
        fi
    done
    if (( ${#lines[@]} > 0 )); then
        while read -r _ entry; do
            [[ -n $entry ]] && DISPLAY_ORDER+=("$entry")
        done < <(printf '%s\n' "${lines[@]}" | sort)
    fi
}

# Current/max PCIe link, with degradation check.
# Sets: LINK_TEXT LINK_DEGRADED LINK_SPEED LINK_WIDTH LINK_MAX_SPEED LINK_MAX_WIDTH
speed_x10() {
    local n=${1%% *}
    if [[ $n == *.* ]]; then printf '%s' "${n/./}"; else printf '%s0' "$n"; fi
}

gen_of_speed() {
    case ${1%% *} in
        2.5)       printf 'Gen1' ;;
        5 | 5.0)   printf 'Gen2' ;;
        8 | 8.0)   printf 'Gen3' ;;
        16 | 16.0) printf 'Gen4' ;;
        32 | 32.0) printf 'Gen5' ;;
        64 | 64.0) printf 'Gen6' ;;
        *)         printf '%s' "${1%% *}GT" ;;
    esac
}

read_link() {
    local p="$SYS/bus/pci/devices/$1"
    LINK_SPEED=$(sysval "$p/current_link_speed")
    LINK_WIDTH=$(sysval "$p/current_link_width")
    LINK_MAX_SPEED=$(sysval "$p/max_link_speed")
    LINK_MAX_WIDTH=$(sysval "$p/max_link_width")
    LINK_DEGRADED=false
    LINK_TEXT="?"

    [[ $LINK_SPEED =~ ^[0-9] ]] || return 0
    LINK_TEXT="$(gen_of_speed "$LINK_SPEED") x$LINK_WIDTH"
    if [[ $LINK_MAX_SPEED =~ ^[0-9] && $LINK_MAX_WIDTH =~ ^[0-9]+$ ]]; then
        if (( $(speed_x10 "$LINK_SPEED") < $(speed_x10 "$LINK_MAX_SPEED") \
              || LINK_WIDTH < LINK_MAX_WIDTH )); then
            LINK_DEGRADED=true
        fi
    fi
}

# =============================================================================
# AER polling
# =============================================================================

declare -A CUM_CORR CUM_UNC NEW_CORR NEW_UNC LAST_ERR AER_OK CORR_RAW UNC_RAW
EVENTS=()
EVENT_KEEP=8
TOTAL_CORR=0
TOTAL_UNC=0

read_aer() {
    # read_aer <pci-addr> <hex-offset> -> lowercase 8-digit hex on stdout
    local v
    v=$(setpci -s "$1" "ECAP_AER+$2.l" 2> /dev/null) || return 1
    [[ $v =~ ^[0-9a-fA-F]{1,8}$ ]] || return 1
    printf '%08x' "$((16#$v))"
}

# decode_status <hexval> corr|unc  -> sets DEC_NAMES (array) and DEC_COUNT
decode_status() {
    local val=$((16#$1)) def bit
    local -a defs
    if [[ $2 == corr ]]; then defs=("${CORR_DEF[@]}"); else defs=("${UNC_DEF[@]}"); fi
    DEC_NAMES=()
    for def in "${defs[@]}"; do
        bit=${def%%:*}
        (( val & (1 << bit) )) && DEC_NAMES+=("${def#*:}")
    done
    DEC_COUNT=${#DEC_NAMES[@]}
}

record_event() {
    # record_event <hh:mm:ss> <addr> <corr|uncorr> <names> <rawhex>
    local iso
    EVENTS+=("$1|${NVME_OF[$2]:-$2}|$3|$4|$5")
    (( ${#EVENTS[@]} > EVENT_KEEP )) && EVENTS=("${EVENTS[@]: -EVENT_KEEP}")
    if [[ -n $LOG_FILE ]]; then
        printf -v iso '%(%FT%T%z)T' -1
        printf '%s %s %s %s status=0x%s types="%s"\n' \
            "$iso" "${NVME_OF[$2]:-N/A}" "$2" "$3" "$5" "$4" >> "$LOG_FILE"
    fi
}

poll_device() {
    # poll_device <pci-addr> <hh:mm:ss>
    local addr=$1 ts=$2 corr unc names
    NEW_CORR[$addr]=0
    NEW_UNC[$addr]=0
    CORR_RAW[$addr]=""
    UNC_RAW[$addr]=""

    if ! corr=$(read_aer "$addr" 10); then
        AER_OK[$addr]=false
        return
    fi
    AER_OK[$addr]=true
    CORR_RAW[$addr]=$corr
    unc=$(read_aer "$addr" 04) || unc=""
    UNC_RAW[$addr]=$unc

    if [[ -n ${corr//0/} ]]; then
        decode_status "$corr" corr
        if (( DEC_COUNT > 0 )); then
            names=${DEC_NAMES[*]}
            NEW_CORR[$addr]=$DEC_COUNT
            CUM_CORR[$addr]=$(( ${CUM_CORR[$addr]:-0} + DEC_COUNT ))
            TOTAL_CORR=$(( TOTAL_CORR + DEC_COUNT ))
            LAST_ERR[$addr]="$ts $names"
            record_event "$ts" "$addr" "corr" "$names" "$corr"
        fi
        # write-1-to-clear exactly the bits we observed
        [[ $NO_RESET == false ]] && setpci -s "$addr" "ECAP_AER+10.l=$corr" > /dev/null 2>&1
    fi

    if [[ -n $unc && -n ${unc//0/} ]]; then
        decode_status "$unc" unc
        if (( DEC_COUNT > 0 )); then
            names=${DEC_NAMES[*]}
            NEW_UNC[$addr]=$DEC_COUNT
            CUM_UNC[$addr]=$(( ${CUM_UNC[$addr]:-0} + DEC_COUNT ))
            TOTAL_UNC=$(( TOTAL_UNC + DEC_COUNT ))
            LAST_ERR[$addr]="$ts ${names}"
            record_event "$ts" "$addr" "uncorr" "$names" "$unc"
        fi
        [[ $NO_RESET == false ]] && setpci -s "$addr" "ECAP_AER+04.l=$unc" > /dev/null 2>&1
    fi
}

poll_all() {
    local now addr
    printf -v now '%(%H:%M:%S)T' -1
    for addr in "${DISPLAY_ORDER[@]}"; do
        poll_device "$addr" "$now"
    done
}

reset_counters() {
    CUM_CORR=() CUM_UNC=() LAST_ERR=()
    EVENTS=()
    TOTAL_CORR=0
    TOTAL_UNC=0
    printf -v FLASH_MSG 'counters reset at %(%H:%M:%S)T' -1
}

# =============================================================================
# Rendering
# =============================================================================

# Column widths (PCI width adapts: short form unless a non-zero domain exists)
W_DEV=8 W_SER=16 W_MOD=21 W_LNK=10 W_NEW=4 W_CORR=7 W_UNC=6 W_LAST=30
PCI_W=8
FLASH_MSG=""

pci_display() {
    # strip the leading "0000:" domain for readability when it is the default
    if (( PCI_W == 8 )); then printf '%s' "${1#0000:}"; else printf '%s' "$1"; fi
}

set_pci_width() {
    local addr
    PCI_W=8
    for addr in "${PCI_DEVS[@]}"; do
        [[ $addr == 0000:* ]] || { PCI_W=12; break; }
    done
    TABLE_W=$(( 2 + W_DEV + PCI_W + W_SER + W_MOD + W_LNK + W_NEW + W_CORR + W_UNC + W_LAST + 9 ))
}

fmt_duration() {
    printf '%02d:%02d:%02d' $(( $1 / 3600 )) $(( ($1 % 3600) / 60 )) $(( $1 % 60 ))
}

rule() {
    # rule <width> -> horizontal line
    local s
    printf -v s '%*s' "$1" ''
    printf '%s' "${s// /$GLYPH_RULE}"
}

# total table width; recomputed by set_pci_width when the PCI column widens
TABLE_W=$(( 2 + W_DEV + PCI_W + W_SER + W_MOD + W_LNK + W_NEW + W_CORR + W_UNC + W_LAST + 9 ))

# compose_table -> appends the header + one row per device to BUF
compose_table() {
    local addr name serial model dot row nc nu new_n
    local c_dev c_pci c_ser c_mod c_lnk c_new c_corr c_unc c_last

    printf -v row '%-*s %-*s %-*s %-*s %-*s %*s %*s %*s %s' \
        "$W_DEV" "DEVICE" "$PCI_W" "PCI ADDR" "$W_SER" "SERIAL" \
        "$W_MOD" "MODEL" "$W_LNK" "LINK" "$W_NEW" "NEW" \
        "$W_CORR" "CORR" "$W_UNC" "UNC" "LAST ERROR"
    BUF+="  ${C_BOLD}${row}${C_RESET}${EOL}"$'\n'
    BUF+="${C_DIM}$(rule "$TABLE_W")${C_RESET}${EOL}"$'\n'

    for addr in "${DISPLAY_ORDER[@]}"; do
        name=${NVME_OF[$addr]:-}
        serial=${SERIAL_OF[$addr]:-}
        model=${MODEL_OF[$addr]:-}
        read_link "$addr"
        nc=${CUM_CORR[$addr]:-0}
        nu=${CUM_UNC[$addr]:-0}
        new_n=$(( ${NEW_CORR[$addr]:-0} + ${NEW_UNC[$addr]:-0} ))

        # health dot
        if [[ ${AER_OK[$addr]:-true} == false ]]; then
            dot="${C_DIM}${GLYPH_DOT}${C_RESET}"
        elif (( nu > 0 )); then
            dot="${C_RED}${GLYPH_DOT}${C_RESET}"
        elif (( nc > 0 )); then
            dot="${C_YELLOW}${GLYPH_DOT}${C_RESET}"
        else
            dot="${C_GREEN}${GLYPH_DOT}${C_RESET}"
        fi

        printf -v c_dev '%-*.*s' "$W_DEV" "$W_DEV" "${name:--}"
        printf -v c_pci '%-*.*s' "$PCI_W" "$PCI_W" "$(pci_display "$addr")"
        printf -v c_ser '%-*.*s' "$W_SER" "$W_SER" "${serial:--}"
        if [[ -z $name ]]; then
            printf -v c_mod '%-*.*s' "$W_MOD" "$W_MOD" "(no nvme driver)"
            c_mod="${C_YELLOW}${c_mod}${C_RESET}"
        else
            printf -v c_mod '%-*.*s' "$W_MOD" "$W_MOD" "${model:--}"
        fi

        printf -v c_lnk '%-*.*s' "$W_LNK" "$W_LNK" \
            "${LINK_TEXT}$([[ $LINK_DEGRADED == true ]] && printf '!')"
        [[ $LINK_DEGRADED == true ]] && c_lnk="${C_YELLOW}${c_lnk}${C_RESET}"

        if [[ ${AER_OK[$addr]:-true} == false ]]; then
            printf -v c_new '%*s' "$W_NEW" "-"
            printf -v c_corr '%*s' "$W_CORR" "n/a"
            printf -v c_unc '%*s' "$W_UNC" "-"
            c_new="${C_DIM}${c_new}${C_RESET}"
            c_corr="${C_DIM}${c_corr}${C_RESET}"
            c_unc="${C_DIM}${c_unc}${C_RESET}"
            printf -v c_last '%.*s' "$W_LAST" "no AER capability"
            c_last="${C_DIM}${c_last}${C_RESET}"
        else
            if (( new_n > 0 )); then
                printf -v c_new '%*s' "$W_NEW" "+$new_n"
                c_new="${C_BOLD}${C_RED}${c_new}${C_RESET}"
            else
                printf -v c_new '%*s' "$W_NEW" "-"
                c_new="${C_DIM}${c_new}${C_RESET}"
            fi
            printf -v c_corr '%*s' "$W_CORR" "$nc"
            if (( nc > 0 )); then c_corr="${C_YELLOW}${c_corr}${C_RESET}"
            else c_corr="${C_DIM}${c_corr}${C_RESET}"; fi
            printf -v c_unc '%*s' "$W_UNC" "$nu"
            if (( nu > 0 )); then c_unc="${C_BOLD}${C_RED}${c_unc}${C_RESET}"
            else c_unc="${C_DIM}${c_unc}${C_RESET}"; fi
            if [[ -n ${LAST_ERR[$addr]:-} ]]; then
                printf -v c_last '%.*s' "$W_LAST" "${LAST_ERR[$addr]}"
            else
                printf -v c_last '%s' "${C_DIM}-${C_RESET}"
            fi
        fi

        BUF+="${dot} ${c_dev} ${c_pci} ${c_ser} ${c_mod} ${c_lnk} ${c_new} ${c_corr} ${c_unc} ${c_last}${EOL}"$'\n'
    done
}

compose_totals() {
    local n_dev=${#DISPLAY_ORDER[@]} n_err=0 addr t_corr t_unc
    for addr in "${DISPLAY_ORDER[@]}"; do
        (( ${CUM_CORR[$addr]:-0} + ${CUM_UNC[$addr]:-0} > 0 )) && (( n_err++ ))
    done
    if (( TOTAL_CORR > 0 )); then t_corr="${C_YELLOW}${TOTAL_CORR}${C_RESET}"
    else t_corr="${C_GREEN}0${C_RESET}"; fi
    if (( TOTAL_UNC > 0 )); then t_unc="${C_BOLD}${C_RED}${TOTAL_UNC}${C_RESET}"
    else t_unc="${C_GREEN}0${C_RESET}"; fi
    BUF+="  ${C_DIM}devices:${C_RESET} ${n_dev}"
    BUF+="  ${C_DIM}with errors:${C_RESET} ${n_err}"
    BUF+="  ${C_DIM}events:${C_RESET} ${t_corr} ${C_DIM}corr${C_RESET} / ${t_unc} ${C_DIM}uncorr${C_RESET}"
    [[ $NO_RESET == true ]] && BUF+="  ${C_YELLOW}[passive: registers not cleared]${C_RESET}"
    BUF+="${EOL}"$'\n'
}

compose_events() {
    local ev i ts dev kind names raw label
    BUF+="${C_DIM}$(rule 2) recent events $(rule $(( TABLE_W - 17 )))${C_RESET}${EOL}"$'\n'
    if (( ${#EVENTS[@]} == 0 )); then
        BUF+="  ${C_DIM}(none this session)${C_RESET}${EOL}"$'\n'
        return
    fi
    for (( i = ${#EVENTS[@]} - 1; i >= 0; i-- )); do
        ev=${EVENTS[$i]}
        IFS='|' read -r ts dev kind names raw <<< "$ev"
        if [[ $kind == uncorr ]]; then
            label="${C_BOLD}${C_RED}uncorrectable${C_RESET}"
        else
            label="${C_YELLOW}correctable${C_RESET}"
        fi
        BUF+="  ${C_DIM}${ts}${C_RESET}  ${C_BOLD}${dev}${C_RESET}  ${label}: ${names} ${C_DIM}(status 0x${raw})${C_RESET}${EOL}"$'\n'
    done
}

compose_frame() {
    # compose_frame live|single
    local mode=$1 now up
    printf -v now '%(%F %T)T' -1
    BUF=""
    BUF+="${C_BOLD}${C_CYAN}NVMe AER Monitor${C_RESET}"
    BUF+="${C_DIM} ${GLYPH_SEP} ${HOSTNAME:-localhost} ${GLYPH_SEP} updated ${now}"
    if [[ $mode == live ]]; then
        up=$(fmt_duration "$SECONDS")
        BUF+=" ${GLYPH_SEP} every ${INTERVAL}s ${GLYPH_SEP} up ${up}"
    fi
    BUF+="${C_RESET}${EOL}"$'\n'
    compose_totals
    BUF+="${EOL}"$'\n'
    compose_table
    BUF+="${EOL}"$'\n'
    compose_events
    if [[ $mode == live ]]; then
        BUF+="${EOL}"$'\n'
        BUF+="${C_DIM} q quit ${GLYPH_SEP} r reset counters"
        BUF+="${FLASH_MSG:+ ${GLYPH_SEP} }${FLASH_MSG}"
        BUF+=" ${GLYPH_SEP} corr/unc = AER events since start${C_RESET}${EOL}"
    fi
    FLASH_MSG=""
}

print_summary() {
    local addr name dur ev ts dev kind names raw shown=false
    printf -v dur '%s' "$(fmt_duration "$SECONDS")"
    printf '\n%sNVMe AER Monitor%s %s session summary (%s, ended %s)\n' \
        "$C_BOLD" "$C_RESET" "$GLYPH_SEP" "$dur" "$(printf '%(%F %T)T' -1)"
    printf '  events observed: %s correctable, %s uncorrectable\n' \
        "$TOTAL_CORR" "$TOTAL_UNC"
    for addr in "${DISPLAY_ORDER[@]}"; do
        (( ${CUM_CORR[$addr]:-0} + ${CUM_UNC[$addr]:-0} > 0 )) || continue
        shown=true
        name=${NVME_OF[$addr]:-$addr}
        printf '  %-8s %-16s %5s corr / %s unc   last: %s\n' \
            "$name" "${SERIAL_OF[$addr]:--}" "${CUM_CORR[$addr]:-0}" \
            "${CUM_UNC[$addr]:-0}" "${LAST_ERR[$addr]:--}"
    done
    [[ $shown == false ]] && printf '  no AER errors observed\n'
    if (( ${#EVENTS[@]} > 0 )); then
        printf '  recent events:\n'
        for ev in "${EVENTS[@]}"; do
            IFS='|' read -r ts dev kind names raw <<< "$ev"
            printf '    %s  %-8s %-13s %s (status 0x%s)\n' \
                "$ts" "$dev" "$kind" "$names" "$raw"
        done
    fi
    [[ -n $LOG_FILE ]] && printf '  full event log: %s\n' "$LOG_FILE"
    printf '\n'
}

# =============================================================================
# JSON output
# =============================================================================

json_escape() {
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

json_names() {
    local out="" n
    for n in "${DEC_NAMES[@]}"; do out+="\"$n\", "; done
    printf '[%s]' "${out%, }"
}

display_json() {
    local addr first=true corr unc corr_names corr_count unc_names unc_count
    printf '{\n'
    printf '  "version": "%s",\n' "$VERSION"
    printf '  "timestamp": "%s",\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf '  "host": "%s",\n' "$(json_escape "${HOSTNAME:-localhost}")"
    printf '  "reset_after_read": %s,\n' "$([[ $NO_RESET == true ]] && printf 'false' || printf 'true')"
    printf '  "devices": [\n'
    for addr in "${DISPLAY_ORDER[@]}"; do
        [[ $first == true ]] && first=false || printf ',\n'
        corr=${CORR_RAW[$addr]:-}
        unc=${UNC_RAW[$addr]:-}
        if [[ -n $corr ]]; then decode_status "$corr" corr; else DEC_NAMES=(); fi
        corr_names=$(json_names); corr_count=${#DEC_NAMES[@]}
        if [[ -n $unc ]]; then decode_status "$unc" unc; else DEC_NAMES=(); fi
        unc_names=$(json_names); unc_count=${#DEC_NAMES[@]}
        read_link "$addr"
        printf '    {\n'
        printf '      "device": "%s",\n' "${NVME_OF[$addr]:-N/A}"
        printf '      "pci_address": "%s",\n' "$addr"
        printf '      "serial": "%s",\n' "$(json_escape "${SERIAL_OF[$addr]:-N/A}")"
        printf '      "model": "%s",\n' "$(json_escape "${MODEL_OF[$addr]:-N/A}")"
        printf '      "firmware": "%s",\n' "$(json_escape "${FW_OF[$addr]:-N/A}")"
        printf '      "link": {"speed": "%s", "width": "%s", "max_speed": "%s", "max_width": "%s", "degraded": %s},\n' \
            "$LINK_SPEED" "$LINK_WIDTH" "$LINK_MAX_SPEED" "$LINK_MAX_WIDTH" "$LINK_DEGRADED"
        printf '      "aer_supported": %s,\n' "${AER_OK[$addr]:-false}"
        printf '      "correctable": {"status_raw": "%s", "events": %s, "types": %s},\n' \
            "${corr:-}" "$corr_count" "$corr_names"
        printf '      "uncorrectable": {"status_raw": "%s", "events": %s, "types": %s},\n' \
            "${unc:-}" "$unc_count" "$unc_names"
        printf '      "current_error": "%s",\n' "${corr:-00000000}"
        printf '      "cumulative_errors": %s\n' "$(( ${CUM_CORR[$addr]:-0} + ${CUM_UNC[$addr]:-0} ))"
        printf '    }'
    done
    printf '\n  ]\n}\n'
}

# =============================================================================
# Main
# =============================================================================

discover_devices
set_pci_width
(( ${#PCI_DEVS[@]} > 0 )) || die "no NVMe PCI controllers (class 0x0108) found"

if [[ -n $LOG_FILE ]]; then
    printf '%s session start (interval=%ss, reset=%s)\n' \
        "$(printf '%(%FT%T%z)T' -1)" "$INTERVAL" \
        "$([[ $NO_RESET == true ]] && printf 'no' || printf 'yes')" >> "$LOG_FILE"
fi

if [[ $JSON_OUTPUT == true ]]; then
    poll_all
    display_json
    exit 0
fi

if [[ $SINGLE_RUN == true ]]; then
    poll_all
    EOL=""
    compose_frame single
    printf '%s' "$BUF"
    exit 0
fi

# --- continuous monitoring mode ---------------------------------------------
if [[ $IS_TTY == true ]]; then
    EOL=$'\e[K'   # clear to end of line after every row: no stale artifacts
    enter_screen
else
    EOL=""        # plain streaming frames when piped/redirected
fi

while true; do
    discover_devices
    set_pci_width
    poll_all
    compose_frame live
    MONITOR_RAN=true

    if [[ $IS_TTY == true ]]; then
        # repaint in place: cursor home, draw, clear whatever is left below
        printf '\e[H%s\e[J' "$BUF"
    else
        printf '%s\n' "$BUF"
    fi

    key=""
    if [[ -t 0 ]]; then
        IFS= read -rsn1 -t "$INTERVAL" key
    else
        sleep "$INTERVAL"
    fi
    case $key in
        q | Q) exit 0 ;;
        r | R) reset_counters ;;
    esac
done
