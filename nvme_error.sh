#!/bin/bash
# =============================================================================
# NVMe AER Error Monitor
# =============================================================================
#
# Description:
#   Live, colorized monitor for PCIe Advanced Error Reporting (AER) on NVMe
#   controllers.  Polls the AER capability registers at BOTH ends of each
#   drive's PCIe link -- the drive itself and its parent (host) port -- and
#   decodes correctable and uncorrectable status bits into human-readable
#   error names with directional attribution:
#
#     DOWN (v) errors latched in the drive's registers: the drive's receiver
#              detected corruption, so host->drive traffic is suspect.
#     UP   (^) errors latched in the parent port's registers: the host side
#              detected corruption, so drive->host traffic is suspect.
#
#   (Replay-type errors -- Timeout, Rollover -- latch on the *transmitting*
#   end and therefore implicate the opposite direction.)
#
# Views:
#   - Main table: one row per controller with paired down/up counters,
#     link state, temperature, and last decoded error; 'p' adds a dim
#     sub-row per drive showing the parent port's own state.
#   - Detail screen ('d', or a digit key): per-type x per-end error matrix,
#     link/ASPM/MPS/MRRS configuration, AER masks, uncorrectable header-log
#     decode, drive health, and that drive's event history.
#   - Read soak ('t' inside detail): a safe, READ-ONLY background load
#     generator (parallel dd readers with O_DIRECT) to raise link duty
#     cycle while you watch for errors.  It never writes to the drive.
#
# Link state:
#   The LINK column compares the trained link against what is achievable:
#   a yellow '!' marks a link running below its effective maximum (drive
#   max, port max, and the port's configured Target Link Speed), while a
#   dim '*' marks a link that is capped by configuration or port
#   capability and running exactly at that cap -- expected, not an alarm.
#
# Semantics:
#   AER status registers are latching bitmasks, not counters: a set bit
#   means that error type occurred at least once since the register was
#   last cleared.  Counts shown are "error events observed" (one per bit
#   per poll), so sustained bursts within one interval are undercounted.
#   By default observed bits are cleared (write-1-to-clear) at both ends
#   after each read; with -n nothing is written and new events are
#   detected as 0->1 transitions against the previous poll instead.
#
# Temperature source:
#   Kernel NVMe hwmon interface (kernel >= 5.5, CONFIG_NVME_HWMON), no
#   external tools; falls back to 'nvme smart-log' when hwmon is absent.
#
# Dependencies:
#   - bash >= 4.2
#   - setpci (pciutils)
#   - Linux sysfs (/sys/bus/pci, /sys/class/nvme)
#   - nvme-cli (optional: temperature fallback, SMART block in detail view)
# =============================================================================

VERSION="3.0.0"

# sysfs and /dev roots (overridable for testing)
SYS="${NVME_ERROR_SYS:-/sys}"
DEV="${NVME_ERROR_DEV:-/dev}"

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

Monitor NVMe device errors using PCIe Advanced Error Reporting (AER),
at both ends of each drive's link (drive end and host-port end).

Options:
    -d          Print one status snapshot and exit
    -j          Print one snapshot as JSON and exit
    -i SECONDS  Refresh interval for live mode (default: 2)
    -l FILE     Append every error event to FILE with full timestamps
    -n          Passive mode: read AER status without clearing it (new
                events are then detected as 0->1 register transitions)
    -h          Show this help and exit

Interactive keys (live mode):
    q       quit and print a session summary
    r       reset session counters and the recent-event list
    p       toggle host-port sub-rows in the main table
    d, 0-9  open the drive detail screen (digit jumps to that nvme number)
    n / N   next / previous drive (detail screen)
    c       clear this drive's counters (detail screen)
    t       start/stop a READ-ONLY soak on this drive (detail screen)
    Esc, b  back to the main table

Read soak ('t'):
    Spawns parallel 'dd' readers (O_DIRECT, bs=1M) against the drive's
    namespace block device to raise link duty cycle while you watch for
    errors.  It only ever READS -- no data is modified -- but it will add
    I/O load and latency on that drive while running.

Arrows: v = error latched at the drive end (host->drive traffic suspect),
        ^ = error latched at the host port (drive->host traffic suspect).

Notes:
    * Requires root (setpci needs PCI config space access).
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
    C_BLUE=$(tput setaf 4 2> /dev/null)
    C_MAG=$(tput setaf 5 2> /dev/null)
    C_CYAN=$(tput setaf 6 2> /dev/null)
else
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW=""
    C_BLUE="" C_MAG="" C_CYAN=""
fi

# Unicode glyphs with ASCII fallback
case ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} in
    *[Uu][Tt][Ff]8* | *[Uu][Tt][Ff]-8*)
        GLYPH_DOT="●" GLYPH_RULE="─" GLYPH_SEP="·" GLYPH_SUB="└"
        A_DN="↓" A_UP="↑" ;;
    *)
        GLYPH_DOT="*" GLYPH_RULE="-" GLYPH_SEP="|" GLYPH_SUB="\\"
        A_DN="v" A_UP="^" ;;
esac

# colored arrow shorthands (down = drive end, up = host-port end)
ADN="${C_CYAN}${A_DN}${C_RESET}"
AUP="${C_MAG}${A_UP}${C_RESET}"

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
    stop_soak quiet
    leave_screen
    [[ $MONITOR_RAN == true ]] && print_summary
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# =============================================================================
# Device discovery and static info (all from sysfs)
# =============================================================================

declare -A NVME_OF SERIAL_OF MODEL_OF FW_OF PORT_OF
declare -A TEMP_FILE_OF TEMP_WARN_OF TEMP_CRIT_OF HWMON_DIR_OF
PCI_DEVS=()
DISPLAY_ORDER=()
PORT_LIST=()

HAVE_NVME_CLI=false
command -v nvme > /dev/null 2>&1 && HAVE_NVME_CLI=true

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
    local class_file class addr ctrl link name real par pb
    local hw hname hdir devlink taddr tail v
    local -A addr_of_name=() port_seen=()
    PCI_DEVS=()
    PORT_LIST=()
    NVME_OF=() SERIAL_OF=() MODEL_OF=() FW_OF=() PORT_OF=()
    TEMP_FILE_OF=() TEMP_WARN_OF=() TEMP_CRIT_OF=() HWMON_DIR_OF=()

    # every PCI function with class 0x0108xx (non-volatile memory controller)
    for class_file in "$SYS"/bus/pci/devices/*/class; do
        [[ -r $class_file ]] || continue
        read -r class < "$class_file"
        [[ $class == 0x0108* ]] || continue
        addr=${class_file%/class}
        addr=${addr##*/}
        PCI_DEVS+=("$addr")

        # parent (host) port: the directory above the device in the PCI tree.
        # A domain root (pci0000:c0) parent means no port -- e.g. an RCiEP.
        real=$(readlink -f "$SYS/bus/pci/devices/$addr" 2> /dev/null)
        par=${real%/*}
        pb=${par##*/}
        if [[ $pb =~ ^[0-9a-fA-F]{4,}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
            PORT_OF[$addr]=$pb
            if [[ -z ${port_seen[$pb]:-} ]]; then
                port_seen[$pb]=1
                PORT_LIST+=("$pb")
            fi
        else
            PORT_OF[$addr]=""
        fi
    done

    # map nvme controller names and identity onto PCI addresses
    for ctrl in "$SYS"/class/nvme/nvme*; do
        [[ -e $ctrl ]] || continue
        link=$(readlink -f "$ctrl/device" 2> /dev/null) || continue
        addr=${link##*/}
        [[ -e $SYS/bus/pci/devices/$addr ]] || continue
        name=${ctrl##*/}
        NVME_OF[$addr]=$name
        addr_of_name[$name]=$addr
        SERIAL_OF[$addr]=$(sysval "$ctrl/serial")
        MODEL_OF[$addr]=$(sysline "$ctrl/model")
        FW_OF[$addr]=$(sysval "$ctrl/firmware_rev")
    done

    # locate the kernel's NVMe hwmon sensors (kernel >= 5.5).  Depending on
    # kernel version the hwmon device's parent is either the PCI device or
    # the nvme class device, so accept both.
    for hw in "$SYS"/class/hwmon/*/name; do
        [[ -r $hw ]] || continue
        read -r hname < "$hw"
        [[ $hname == nvme ]] || continue
        hdir=${hw%/name}
        devlink=$(readlink -f "$hdir/device" 2> /dev/null) || continue
        taddr=""
        if [[ $devlink =~ /nvme/(nvme[0-9]+)$ ]]; then
            taddr=${addr_of_name[${BASH_REMATCH[1]}]:-}
        else
            tail=${devlink##*/}
            [[ -n ${NVME_OF[$tail]:-} ]] && taddr=$tail
        fi
        [[ -n $taddr && -r $hdir/temp1_input ]] || continue
        TEMP_FILE_OF[$taddr]="$hdir/temp1_input"
        HWMON_DIR_OF[$taddr]=$hdir
        v=$(sysval "$hdir/temp1_max")
        [[ $v =~ ^[0-9]+$ ]] && TEMP_WARN_OF[$taddr]=$(( (v + 500) / 1000 ))
        v=$(sysval "$hdir/temp1_crit")
        [[ $v =~ ^[0-9]+$ ]] && TEMP_CRIT_OF[$taddr]=$(( (v + 500) / 1000 ))
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

# =============================================================================
# Register access helpers
# =============================================================================

pci_read() {
    # pci_read <pci-addr> <setpci-expr>  -> hex value on stdout (lowercase)
    local v
    v=$(setpci -s "$1" "$2" 2> /dev/null) || return 1
    [[ $v =~ ^[0-9a-fA-F]{1,8}$ ]] || return 1
    printf '%s' "${v,,}"
}

read_aer() {
    # read_aer <pci-addr> <hex-offset> -> lowercase 8-digit hex on stdout
    local v
    v=$(pci_read "$1" "ECAP_AER+$2.l") || return 1
    printf '%08x' "$((16#$v))"
}

# get_temp <pci-addr> -> sets TEMP_C ("" if unknown), TEMP_WARN, TEMP_CRIT.
get_temp() {
    local addr=$1 f=${TEMP_FILE_OF[$addr]:-} t name
    TEMP_C=""
    TEMP_WARN=${TEMP_WARN_OF[$addr]:-70}
    TEMP_CRIT=${TEMP_CRIT_OF[$addr]:-80}
    if [[ -n $f ]]; then
        t=$(sysval "$f")
        [[ $t =~ ^-?[0-9]+$ ]] && TEMP_C=$(( (t + 500) / 1000 ))
        return 0
    fi
    name=${NVME_OF[$addr]:-}
    [[ -n $name && $HAVE_NVME_CLI == true && -e $DEV/$name ]] || return 0
    t=$(nvme smart-log "$DEV/$name" -o json 2> /dev/null)
    [[ $t =~ \"temperature\"[[:space:]]*:[[:space:]]*([0-9]+) ]] \
        && TEMP_C=$(( BASH_REMATCH[1] - 273 ))
    return 0
}

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

target_speed_x10() {
    # target_speed_x10 <port-addr>: the port's configured Target Link Speed
    # (Link Control 2, CAP_EXP+0x30, bits 3:0), or "" if unavailable/zero
    local v code
    v=$(pci_read "$1" "CAP_EXP+30.w") || return 0
    code=$(( 16#$v & 0xf ))
    case $code in
        1) printf '25' ;;  2) printf '50' ;;  3) printf '80' ;;
        4) printf '160' ;; 5) printf '320' ;; 6) printf '640' ;;
    esac
    return 0
}

# read_link <pci-addr>: sets LINK_TEXT LINK_DEGRADED LINK_CAPPED LINK_SPEED
# LINK_WIDTH LINK_MAX_SPEED LINK_MAX_WIDTH LINK_TARGET_X10.
# Degraded = trained below the effective max (min of drive max, port max,
# port target speed).  Capped = at the effective max, but that max is below
# the drive's own capability -- deliberate configuration, not an alarm.
read_link() {
    local p="$SYS/bus/pci/devices/$1" port=${PORT_OF[$1]:-}
    local cur_x10 eff_x10 drv_x10 pmax pmax_x10 eff_w pmaxw
    LINK_SPEED=$(sysval "$p/current_link_speed")
    LINK_WIDTH=$(sysval "$p/current_link_width")
    LINK_MAX_SPEED=$(sysval "$p/max_link_speed")
    LINK_MAX_WIDTH=$(sysval "$p/max_link_width")
    LINK_DEGRADED=false
    LINK_CAPPED=false
    LINK_TARGET_X10=""
    LINK_TEXT="?"

    [[ $LINK_SPEED =~ ^[0-9] ]] || return 0
    LINK_TEXT="$(gen_of_speed "$LINK_SPEED") x$LINK_WIDTH"
    [[ $LINK_MAX_SPEED =~ ^[0-9] && $LINK_MAX_WIDTH =~ ^[0-9]+$ ]] || return 0

    cur_x10=$(speed_x10 "$LINK_SPEED")
    drv_x10=$(speed_x10 "$LINK_MAX_SPEED")
    eff_x10=$drv_x10
    eff_w=$LINK_MAX_WIDTH

    if [[ -n $port ]]; then
        pmax=$(sysval "$SYS/bus/pci/devices/$port/max_link_speed")
        if [[ $pmax =~ ^[0-9] ]]; then
            pmax_x10=$(speed_x10 "$pmax")
            (( pmax_x10 < eff_x10 )) && eff_x10=$pmax_x10
        fi
        pmaxw=$(sysval "$SYS/bus/pci/devices/$port/max_link_width")
        [[ $pmaxw =~ ^[0-9]+$ ]] && (( pmaxw < eff_w )) && eff_w=$pmaxw
        LINK_TARGET_X10=$(target_speed_x10 "$port")
        [[ -n $LINK_TARGET_X10 ]] && (( LINK_TARGET_X10 < eff_x10 )) \
            && eff_x10=$LINK_TARGET_X10
    fi

    if (( cur_x10 < eff_x10 || LINK_WIDTH < eff_w )); then
        LINK_DEGRADED=true
    elif (( eff_x10 < drv_x10 )); then
        LINK_CAPPED=true
    fi
}

# =============================================================================
# Decoding
# =============================================================================

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

# decode_tlp_hdr <dw0> <dw1> <dw2> <dw3> -> one-line description
decode_tlp_hdr() {
    local dw0=$((16#$1)) dw1=$((16#$2)) fmt type key name req
    fmt=$(( (dw0 >> 29) & 0x7 ))
    type=$(( (dw0 >> 24) & 0x1f ))
    key=$(printf '%d_%02d' "$fmt" "$type")
    case $key in
        0_00 | 1_00) name="MRd" ;;
        2_00 | 3_00) name="MWr" ;;
        0_02)        name="IORd" ;;
        2_02)        name="IOWr" ;;
        0_04)        name="CfgRd0" ;;
        2_04)        name="CfgWr0" ;;
        0_05)        name="CfgRd1" ;;
        2_05)        name="CfgWr1" ;;
        0_10)        name="Cpl" ;;
        2_10)        name="CplD" ;;
        1_1[6-9] | 1_2? | 3_1[6-9] | 3_2?) name="Msg" ;;
        *)           name="fmt${fmt}/type${type}" ;;
    esac
    req=$(( (dw1 >> 16) & 0xffff ))
    printf '%s from %02x:%02x.%x' "$name" \
        $(( (req >> 8) & 0xff )) $(( (req >> 3) & 0x1f )) $(( req & 0x7 ))
    if [[ $name == MRd || $name == MWr ]]; then
        printf ' addr 0x%s' "${3}"
    fi
}

# =============================================================================
# AER polling (both link ends, edge-detected)
# =============================================================================

# drive-end state keyed by drive addr; port-end state keyed by PORT addr
# (dual-function drives share one port, and therefore one set of counters)
declare -A CUM_CORR CUM_UNC NEW_CORR NEW_UNC LAST_ERR AER_OK CORR_RAW UNC_RAW
declare -A P_CUM_CORR P_CUM_UNC P_NEW_CORR P_NEW_UNC P_LAST P_AER_OK P_CORR_RAW P_UNC_RAW
declare -A PREV_REG TYPECNT HDR_LOG HDR_TIME FIRST_SEEN
EVENTS=()
EVENT_KEEP=8
TOT_DC=0 TOT_DU=0 TOT_PC=0 TOT_PU=0

record_event() {
    # record_event <hh:mm:ss> <display-name> <end d|p> <corr|uncorr> <names> <rawhex> <addr>
    local iso arrow=$A_DN
    [[ $3 == p ]] && arrow=$A_UP
    EVENTS+=("$1|$2|$3|$4|$5|$6|$7")
    (( ${#EVENTS[@]} > 200 )) && EVENTS=("${EVENTS[@]: -200}")
    if [[ -n $LOG_FILE ]]; then
        printf -v iso '%(%FT%T%z)T' -1
        printf '%s %s %s %s%s status=0x%s types="%s"\n' \
            "$iso" "$2" "$7" "$arrow" "$4" "$6" "$5" >> "$LOG_FILE"
    fi
}

poll_end() {
    # poll_end <reg-addr> <end d|p> <offset> <corr|unc> <ts> <display-name>
    # Reads one status register, edge-detects new bits, updates counters.
    # Returns 1 if the register could not be read.
    local addr=$1 end=$2 off=$3 kind=$4 ts=$5 dname=$6
    local cur prev new newhex n key

    cur=$(read_aer "$addr" "$off") || return 1
    prev=${PREV_REG[$addr|$end$kind]:-0}
    new=$(( 16#$cur & ~prev ))

    if [[ $NO_RESET == false ]]; then
        # write-1-to-clear exactly the bits we observed
        [[ -n ${cur//0/} ]] && setpci -s "$addr" "ECAP_AER+$off.l=$cur" > /dev/null 2>&1
        PREV_REG[$addr|$end$kind]=0
    else
        PREV_REG[$addr|$end$kind]=$((16#$cur))
    fi

    # expose raw values for JSON / single-run
    if [[ $end == d ]]; then
        [[ $kind == corr ]] && CORR_RAW[$addr]=$cur || UNC_RAW[$addr]=$cur
    else
        [[ $kind == corr ]] && P_CORR_RAW[$addr]=$cur || P_UNC_RAW[$addr]=$cur
    fi

    (( new == 0 )) && return 0
    printf -v newhex '%08x' "$new"
    decode_status "$newhex" "$kind"
    (( DEC_COUNT > 0 )) || return 0

    local names=${DEC_NAMES[*]} kindword=corr
    [[ $kind == unc ]] && kindword=uncorr
    for n in "${DEC_NAMES[@]}"; do
        key="$end|$addr|$n"
        TYPECNT[$key]=$(( ${TYPECNT[$key]:-0} + 1 ))
    done

    if [[ $end == d ]]; then
        if [[ $kind == corr ]]; then
            NEW_CORR[$addr]=$(( ${NEW_CORR[$addr]:-0} + DEC_COUNT ))
            CUM_CORR[$addr]=$(( ${CUM_CORR[$addr]:-0} + DEC_COUNT ))
            TOT_DC=$(( TOT_DC + DEC_COUNT ))
        else
            NEW_UNC[$addr]=$(( ${NEW_UNC[$addr]:-0} + DEC_COUNT ))
            CUM_UNC[$addr]=$(( ${CUM_UNC[$addr]:-0} + DEC_COUNT ))
            TOT_DU=$(( TOT_DU + DEC_COUNT ))
        fi
        LAST_ERR[$addr]="$ts $A_DN$names"
    else
        if [[ $kind == corr ]]; then
            P_NEW_CORR[$addr]=$(( ${P_NEW_CORR[$addr]:-0} + DEC_COUNT ))
            P_CUM_CORR[$addr]=$(( ${P_CUM_CORR[$addr]:-0} + DEC_COUNT ))
            TOT_PC=$(( TOT_PC + DEC_COUNT ))
        else
            P_NEW_UNC[$addr]=$(( ${P_NEW_UNC[$addr]:-0} + DEC_COUNT ))
            P_CUM_UNC[$addr]=$(( ${P_CUM_UNC[$addr]:-0} + DEC_COUNT ))
            TOT_PU=$(( TOT_PU + DEC_COUNT ))
        fi
        P_LAST[$addr]="$ts $A_UP$names"
    fi

    # on an uncorrectable error, capture the AER header log (the failing
    # TLP's header) from the end that latched it
    if [[ $kind == unc ]]; then
        local d0 d1 d2 d3
        d0=$(read_aer "$addr" 1c) && d1=$(read_aer "$addr" 20) \
            && d2=$(read_aer "$addr" 24) && d3=$(read_aer "$addr" 28) && {
            HDR_LOG[$addr|$end]="$d0 $d1 $d2 $d3"
            HDR_TIME[$addr|$end]=$ts
        }
    fi

    record_event "$ts" "$dname" "$end" "$kindword" "$names" "$newhex" "$addr"
    return 0
}

poll_device() {
    # poll_device <drive-addr> <hh:mm:ss>
    local addr=$1 ts=$2 name=${NVME_OF[$1]:-$1}
    NEW_CORR[$addr]=0
    NEW_UNC[$addr]=0
    CORR_RAW[$addr]=""
    UNC_RAW[$addr]=""
    if ! poll_end "$addr" d 10 corr "$ts" "$name"; then
        AER_OK[$addr]=false
        return
    fi
    AER_OK[$addr]=true
    poll_end "$addr" d 04 unc "$ts" "$name"
}

poll_port() {
    # poll_port <port-addr> <hh:mm:ss> <display-name>
    local addr=$1 ts=$2 dname=$3
    P_NEW_CORR[$addr]=0
    P_NEW_UNC[$addr]=0
    P_CORR_RAW[$addr]=""
    P_UNC_RAW[$addr]=""
    if ! poll_end "$addr" p 10 corr "$ts" "$dname"; then
        P_AER_OK[$addr]=false
        return
    fi
    P_AER_OK[$addr]=true
    poll_end "$addr" p 04 unc "$ts" "$dname"
}

port_display_name() {
    # attribute a port's events to the drive(s) behind it
    local port=$1 addr names=""
    for addr in "${DISPLAY_ORDER[@]}"; do
        [[ ${PORT_OF[$addr]:-} == "$port" ]] || continue
        names+="${names:+,}${NVME_OF[$addr]:-$addr}"
    done
    printf '%s' "${names:-$port}"
}

poll_all() {
    local now addr port
    printf -v now '%(%H:%M:%S)T' -1
    for addr in "${DISPLAY_ORDER[@]}"; do
        poll_device "$addr" "$now"
    done
    for port in "${PORT_LIST[@]}"; do
        poll_port "$port" "$now" "$(port_display_name "$port")"
    done
}

reset_counters() {
    CUM_CORR=() CUM_UNC=() LAST_ERR=()
    P_CUM_CORR=() P_CUM_UNC=() P_LAST=()
    TYPECNT=() HDR_LOG=() HDR_TIME=()
    EVENTS=()
    TOT_DC=0 TOT_DU=0 TOT_PC=0 TOT_PU=0
    printf -v FLASH_MSG 'counters reset at %(%H:%M:%S)T' -1
}

clear_device_counters() {
    # clear_device_counters <drive-addr>: this drive + its port, both ends
    local addr=$1 port=${PORT_OF[$1]:-} key
    TOT_DC=$(( TOT_DC - ${CUM_CORR[$addr]:-0} ))
    TOT_DU=$(( TOT_DU - ${CUM_UNC[$addr]:-0} ))
    CUM_CORR[$addr]=0; CUM_UNC[$addr]=0
    unset "LAST_ERR[$addr]"
    if [[ -n $port ]]; then
        TOT_PC=$(( TOT_PC - ${P_CUM_CORR[$port]:-0} ))
        TOT_PU=$(( TOT_PU - ${P_CUM_UNC[$port]:-0} ))
        P_CUM_CORR[$port]=0; P_CUM_UNC[$port]=0
        unset "P_LAST[$port]"
    fi
    for key in "${!TYPECNT[@]}"; do
        [[ $key == "d|$addr|"* || ( -n $port && $key == "p|$port|"* ) ]] \
            && unset "TYPECNT[$key]"
    done
    printf -v FLASH_MSG '%s counters cleared' "${NVME_OF[$addr]:-$addr}"
}

# =============================================================================
# Read soak (READ-ONLY load generator)
# =============================================================================

SOAK_ADDR=""
SOAK_PIDS=()
SOAK_DIR=""
SOAK_T0=0
SOAK_READERS=4
SOAK_CHUNK_MB=256

soak_reader() {
    # soak_reader <blockdev> <start-mb> <span-mb>
    local bdev=$1 start=$2 span=$3 off=$2 count
    (( span < 1 )) && span=1
    count=$SOAK_CHUNK_MB
    (( count > span )) && count=$span
    while [[ -e $SOAK_DIR/run ]]; do
        if [[ -e $SOAK_DIR/nodirect ]]; then
            dd if="$bdev" of=/dev/null bs=1M iflag=skip_bytes \
                skip=$(( off * 1048576 )) count="$count" 2> /dev/null \
                || { sleep 0.5; continue; }
        else
            dd if="$bdev" of=/dev/null bs=1M iflag=direct,skip_bytes \
                skip=$(( off * 1048576 )) count="$count" 2> /dev/null \
                || { touch "$SOAK_DIR/nodirect"; continue; }
        fi
        echo >> "$SOAK_DIR/progress"
        off=$(( start + ( (off - start + count) % span ) ))
    done
}

start_soak() {
    # start_soak <drive-addr>
    local addr=$1 name=${NVME_OF[$1]:-} ns bdev size_mb i
    if [[ -z $name ]]; then
        FLASH_MSG="soak: no nvme driver bound to this device"
        return
    fi
    ns=$(cd "$SYS/class/nvme/$name" 2> /dev/null && printf '%s\n' "$name"n* | head -1)
    bdev="$DEV/$ns"
    if [[ -z $ns || $ns == "${name}n*" || ! -r $bdev ]]; then
        FLASH_MSG="soak: no readable namespace block device for $name"
        return
    fi
    size_mb=$(sysval "$SYS/class/nvme/$name/$ns/size")
    [[ $size_mb =~ ^[0-9]+$ ]] && size_mb=$(( size_mb / 2048 )) || size_mb=0
    if (( size_mb < 1 )); then
        FLASH_MSG="soak: cannot determine size of $bdev"
        return
    fi
    SOAK_DIR=$(mktemp -d /tmp/nvme_error_soak.XXXXXX) || {
        FLASH_MSG="soak: mktemp failed"
        return
    }
    touch "$SOAK_DIR/run" "$SOAK_DIR/progress"
    SOAK_ADDR=$addr
    SOAK_T0=$SECONDS
    SOAK_PIDS=()
    local span=$(( size_mb / SOAK_READERS ))
    for (( i = 0; i < SOAK_READERS; i++ )); do
        soak_reader "$bdev" $(( i * span )) "$span" &
        SOAK_PIDS+=($!)
    done
    FLASH_MSG="read soak started on $name ($bdev, ${SOAK_READERS} readers)"
}

stop_soak() {
    # stop_soak [quiet]
    local pid chunks mb dur
    [[ -n $SOAK_ADDR ]] || return 0
    rm -f "$SOAK_DIR/run" 2> /dev/null
    for pid in "${SOAK_PIDS[@]}"; do
        kill "$pid" 2> /dev/null
        pkill -P "$pid" 2> /dev/null
    done
    wait "${SOAK_PIDS[@]}" 2> /dev/null
    if [[ ${1:-} != quiet ]]; then
        chunks=$(wc -l < "$SOAK_DIR/progress" 2> /dev/null || echo 0)
        mb=$(( chunks * SOAK_CHUNK_MB ))
        dur=$(( SECONDS - SOAK_T0 ))
        printf -v FLASH_MSG 'soak stopped: read %s GB in %s' \
            "$(( mb / 1024 ))" "$(fmt_duration "$dur")"
    fi
    rm -rf "$SOAK_DIR" 2> /dev/null
    SOAK_ADDR=""
    SOAK_PIDS=()
    SOAK_DIR=""
}

soak_status() {
    # sets SOAK_LINE ("" when no soak active)
    SOAK_LINE=""
    [[ -n $SOAK_ADDR ]] || return 0
    local chunks mb dur rate10
    chunks=$(wc -l < "$SOAK_DIR/progress" 2> /dev/null || echo 0)
    mb=$(( chunks * SOAK_CHUNK_MB ))
    dur=$(( SECONDS - SOAK_T0 ))
    (( dur < 1 )) && dur=1
    rate10=$(( mb * 10 / dur / 1024 ))
    SOAK_LINE="  ${C_BOLD}${C_BLUE}SOAK${C_RESET} ${NVME_OF[$SOAK_ADDR]:-$SOAK_ADDR}"
    SOAK_LINE+=" ${C_DIM}${GLYPH_SEP}${C_RESET} ${SOAK_READERS} readers (read-only)"
    SOAK_LINE+=" ${C_DIM}${GLYPH_SEP}${C_RESET} $(fmt_duration "$dur")"
    SOAK_LINE+=" ${C_DIM}${GLYPH_SEP}${C_RESET} ${C_BOLD}$(( rate10 / 10 )).$(( rate10 % 10 )) GB/s${C_RESET}"
    SOAK_LINE+=" ${C_DIM}${GLYPH_SEP} t to stop${C_RESET}"
}

# =============================================================================
# Rendering
# =============================================================================

# Column widths (PCI width adapts: short form unless a non-zero domain exists)
W_DEV=8 W_SER=16 W_MOD=22 W_LNK=10 W_TMP=4 W_NEW=4
W_DC=5 W_DU=4 W_PC=5 W_PU=4
PCI_W=8
FLASH_MSG=""
SHOW_PORTS=false

pci_display() {
    if (( PCI_W == 8 )); then printf '%s' "${1#0000:}"; else printf '%s' "$1"; fi
}

set_pci_width() {
    local addr
    PCI_W=8
    for addr in "${PCI_DEVS[@]}"; do
        [[ $addr == 0000:* ]] || { PCI_W=12; break; }
    done
    TABLE_W=$(( 2 + W_DEV + PCI_W + W_SER + W_MOD + W_LNK + W_TMP + W_NEW \
                + W_DC + W_DU + W_PC + W_PU + 36 ))
}

fmt_duration() {
    printf '%02d:%02d:%02d' $(( $1 / 3600 )) $(( ($1 % 3600) / 60 )) $(( $1 % 60 ))
}

rule() {
    local s
    printf -v s '%*s' "$1" ''
    printf '%s' "${s// /$GLYPH_RULE}"
}

TABLE_W=120

cnt_cell() {
    # cnt_cell <value> <width> <color-if-positive>  -> colored right-aligned cell
    local s
    printf -v s '%*s' "$2" "$1"
    if [[ $1 == "-" ]]; then
        printf '%s' "${C_DIM}${s}${C_RESET}"
    elif (( $1 > 0 )); then
        printf '%s' "${3}${s}${C_RESET}"
    else
        printf '%s' "${C_DIM}${s}${C_RESET}"
    fi
}

last_err_cell() {
    # last_err_cell <"ts ARROWnames"|""> -> colorized LAST ERROR text
    local v=$1 ts rest arrow
    if [[ -z $v ]]; then
        printf '%s' "${C_DIM}-${C_RESET}"
        return
    fi
    ts=${v%% *}
    rest=${v#* }
    arrow=${rest:0:1}
    if [[ $arrow == "$A_UP" ]]; then
        printf '%s' "$ts ${C_MAG}${arrow}${C_RESET}${rest:1}"
    else
        printf '%s' "$ts ${C_CYAN}${arrow}${C_RESET}${rest:1}"
    fi
}

compose_table() {
    local addr port name serial model dot row nc nu pc pu new_n
    local c_dev c_pci c_ser c_mod c_lnk c_tmp c_new suffix

    printf -v row '%-*s %-*s %-*s %-*s %-*s %*s %*s  %*s %*s  %*s %*s  %s' \
        "$W_DEV" "DEVICE" "$PCI_W" "PCI ADDR" "$W_SER" "SERIAL" \
        "$W_MOD" "MODEL" "$W_LNK" "LINK" "$W_TMP" "TEMP" "$W_NEW" "NEW" \
        "$W_DC" "${A_DN}CORR" "$W_DU" "${A_DN}UNC" \
        "$W_PC" "${A_UP}CORR" "$W_PU" "${A_UP}UNC" "LAST ERROR"
    BUF+="  ${C_BOLD}${row}${C_RESET}${EOL}"$'\n'
    BUF+="${C_DIM}$(rule "$TABLE_W")${C_RESET}${EOL}"$'\n'

    for addr in "${DISPLAY_ORDER[@]}"; do
        port=${PORT_OF[$addr]:-}
        name=${NVME_OF[$addr]:-}
        serial=${SERIAL_OF[$addr]:-}
        model=${MODEL_OF[$addr]:-}
        read_link "$addr"
        nc=${CUM_CORR[$addr]:-0}
        nu=${CUM_UNC[$addr]:-0}
        if [[ -n $port ]]; then
            pc=${P_CUM_CORR[$port]:-0}
            pu=${P_CUM_UNC[$port]:-0}
        else
            pc="-" pu="-"
        fi
        new_n=$(( ${NEW_CORR[$addr]:-0} + ${NEW_UNC[$addr]:-0} ))
        [[ -n $port ]] && new_n=$(( new_n + ${P_NEW_CORR[$port]:-0} + ${P_NEW_UNC[$port]:-0} ))

        local pu_n=0 pc_n=0
        [[ $pu =~ ^[0-9]+$ ]] && pu_n=$pu
        [[ $pc =~ ^[0-9]+$ ]] && pc_n=$pc
        if [[ ${AER_OK[$addr]:-true} == false && $pc$pu == "--" ]]; then
            dot="${C_DIM}${GLYPH_DOT}${C_RESET}"
        elif (( nu > 0 || pu_n > 0 )); then
            dot="${C_RED}${GLYPH_DOT}${C_RESET}"
        elif (( nc > 0 || pc_n > 0 )); then
            dot="${C_YELLOW}${GLYPH_DOT}${C_RESET}"
        elif [[ ${AER_OK[$addr]:-true} == false ]]; then
            dot="${C_DIM}${GLYPH_DOT}${C_RESET}"
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

        suffix=""
        [[ $LINK_DEGRADED == true ]] && suffix="!"
        [[ $LINK_CAPPED == true ]] && suffix="*"
        printf -v c_lnk '%-*.*s' "$W_LNK" "$W_LNK" "${LINK_TEXT}${suffix}"
        if [[ $LINK_DEGRADED == true ]]; then
            c_lnk="${C_YELLOW}${c_lnk}${C_RESET}"
        elif [[ $LINK_CAPPED == true ]]; then
            # re-pad without the '*', then splice it back in dimmed
            printf -v c_lnk '%-*.*s' "$W_LNK" "$W_LNK" "$LINK_TEXT"
            c_lnk="${c_lnk:0:${#LINK_TEXT}}${C_DIM}*${C_RESET}${c_lnk:$(( ${#LINK_TEXT} + 1 ))}"
        fi

        get_temp "$addr"
        if [[ -n $TEMP_C ]]; then
            printf -v c_tmp '%*s' "$W_TMP" "$TEMP_C"
            if (( TEMP_C >= TEMP_CRIT )); then
                c_tmp="${C_BOLD}${C_RED}${c_tmp}${C_RESET}"
            elif (( TEMP_C >= TEMP_WARN )); then
                c_tmp="${C_YELLOW}${c_tmp}${C_RESET}"
            fi
        else
            printf -v c_tmp '%*s' "$W_TMP" "-"
            c_tmp="${C_DIM}${c_tmp}${C_RESET}"
        fi

        if [[ ${AER_OK[$addr]:-true} == false ]]; then
            printf -v c_new '%*s' "$W_NEW" "-"
            c_new="${C_DIM}${c_new}${C_RESET}"
            BUF+="${dot} ${c_dev} ${c_pci} ${c_ser} ${c_mod} ${c_lnk} ${c_tmp} ${c_new}  "
            BUF+="$(cnt_cell "-" "$W_DC" "") $(cnt_cell "-" "$W_DU" "")  "
            BUF+="$(cnt_cell "$pc" "$W_PC" "$C_YELLOW") $(cnt_cell "$pu" "$W_PU" "$C_BOLD$C_RED")  "
            BUF+="${C_DIM}no AER capability${C_RESET}${EOL}"$'\n'
        else
            if (( new_n > 0 )); then
                printf -v c_new '%*s' "$W_NEW" "+$new_n"
                c_new="${C_BOLD}${C_RED}${c_new}${C_RESET}"
            else
                printf -v c_new '%*s' "$W_NEW" "-"
                c_new="${C_DIM}${c_new}${C_RESET}"
            fi
            BUF+="${dot} ${c_dev} ${c_pci} ${c_ser} ${c_mod} ${c_lnk} ${c_tmp} ${c_new}  "
            BUF+="$(cnt_cell "$nc" "$W_DC" "$C_YELLOW") $(cnt_cell "$nu" "$W_DU" "$C_BOLD$C_RED")  "
            BUF+="$(cnt_cell "$pc" "$W_PC" "$C_YELLOW") $(cnt_cell "$pu" "$W_PU" "$C_BOLD$C_RED")  "
            local le=${LAST_ERR[$addr]:-} ple=""
            [[ -n $port ]] && ple=${P_LAST[$port]:-}
            if [[ -n $ple && ( -z $le || ! ${ple%% *} < ${le%% *} ) ]]; then
                le=$ple
            fi
            BUF+="$(last_err_cell "$le")${EOL}"$'\n'
        fi

        if [[ $SHOW_PORTS == true && -n $port ]]; then
            local plead pstat pad_n
            printf -v plead '  %s %s  root port' "$GLYPH_SUB" "$(pci_display "$port")"
            # pad by character count (printf pads by bytes, which breaks on
            # the multibyte sub-row glyph in UTF-8 locales)
            pad_n=$(( 2 + W_DEV + PCI_W + W_SER + W_MOD + 4 - ${#plead} ))
            (( pad_n > 0 )) && printf -v plead '%s%*s' "$plead" "$pad_n" ''
            if [[ ${P_AER_OK[$port]:-true} == false ]]; then
                pstat="${C_DIM}no AER capability${C_RESET}"
            else
                pstat="$(cnt_cell "-" "$W_DC" "") $(cnt_cell "-" "$W_DU" "")  "
                pstat+="$(cnt_cell "${P_CUM_CORR[$port]:-0}" "$W_PC" "$C_YELLOW") "
                pstat+="$(cnt_cell "${P_CUM_UNC[$port]:-0}" "$W_PU" "$C_BOLD$C_RED")  "
                pstat+="$(last_err_cell "${P_LAST[$port]:-}")"
            fi
            BUF+="${C_DIM}${plead}${C_RESET}"
            BUF+="$(printf '%*s' $(( W_LNK + W_TMP + W_NEW + 4 )) '')"
            BUF+="${pstat}${EOL}"$'\n'
        fi
    done
}

compose_totals() {
    local n_dev=${#DISPLAY_ORDER[@]} n_err=0 addr port
    for addr in "${DISPLAY_ORDER[@]}"; do
        port=${PORT_OF[$addr]:-}
        (( ${CUM_CORR[$addr]:-0} + ${CUM_UNC[$addr]:-0} > 0 )) && { (( n_err++ )); continue; }
        [[ -n $port ]] && (( ${P_CUM_CORR[$port]:-0} + ${P_CUM_UNC[$port]:-0} > 0 )) && (( n_err++ ))
    done
    local tc tu
    tc="$(color_count $TOT_DC "$C_YELLOW")${ADN} $(color_count $TOT_PC "$C_YELLOW")${AUP}"
    tu="$(color_count $TOT_DU "$C_BOLD$C_RED")${ADN} $(color_count $TOT_PU "$C_BOLD$C_RED")${AUP}"
    BUF+="  ${C_DIM}devices:${C_RESET} ${n_dev}"
    BUF+="  ${C_DIM}with errors:${C_RESET} ${n_err}"
    BUF+="  ${C_DIM}events:${C_RESET} ${tc} ${C_DIM}corr${C_RESET} / ${tu} ${C_DIM}unc${C_RESET}"
    [[ $NO_RESET == true ]] && BUF+="  ${C_YELLOW}[passive: registers not cleared]${C_RESET}"
    BUF+="${EOL}"$'\n'
    soak_status
    [[ -n $SOAK_LINE ]] && BUF+="${SOAK_LINE}${EOL}"$'\n'
}

color_count() {
    if (( $1 > 0 )); then printf '%s' "$2$1$C_RESET"; else printf '%s' "${C_GREEN}0${C_RESET}"; fi
}

compose_events() {
    # compose_events [filter-device-name] [max]
    local filter=${1:-} max=${2:-$EVENT_KEEP} ev i shown=0
    local ts dev end kind names raw addr label arrow
    BUF+="${C_DIM}$(rule 2) recent events $(rule $(( TABLE_W - 17 )))${C_RESET}${EOL}"$'\n'
    for (( i = ${#EVENTS[@]} - 1; i >= 0 && shown < max; i-- )); do
        ev=${EVENTS[$i]}
        IFS='|' read -r ts dev end kind names raw addr <<< "$ev"
        [[ -n $filter && $dev != *"$filter"* ]] && continue
        (( shown++ ))
        if [[ $end == p ]]; then
            arrow="${C_MAG}${A_UP} port $(pci_display "$addr")${C_RESET}"
        else
            arrow="${C_CYAN}${A_DN} drive${C_RESET}"
        fi
        if [[ $kind == uncorr ]]; then
            label="${C_BOLD}${C_RED}uncorrectable${C_RESET}"
        else
            label="${C_YELLOW}correctable${C_RESET}"
        fi
        BUF+="  ${C_DIM}${ts}${C_RESET}  ${C_BOLD}${dev}${C_RESET}  ${arrow}  ${label}: ${names} ${C_DIM}(status 0x${raw})${C_RESET}${EOL}"$'\n'
    done
    if (( shown == 0 )); then
        BUF+="  ${C_DIM}(none this session)${C_RESET}${EOL}"$'\n'
    fi
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
        BUF+="${C_DIM} q quit ${GLYPH_SEP} r reset ${GLYPH_SEP} p ports ${GLYPH_SEP} d/0-9 detail"
        BUF+=" ${GLYPH_SEP} ${C_RESET}${ADN}${C_DIM} at drive ${GLYPH_SEP} ${C_RESET}${AUP}${C_DIM} at host port ${GLYPH_SEP} * capped"
        BUF+="${FLASH_MSG:+ ${GLYPH_SEP} ${C_RESET}${C_BOLD}${FLASH_MSG}${C_DIM}}"
        BUF+="${C_RESET}${EOL}"$'\n'
    fi
    FLASH_MSG=""
}

# =============================================================================
# Detail screen
# =============================================================================

detail_kv() {
    # detail_kv <label> <value...> -> "label value" with dim label
    printf '%s' "${C_DIM}$1${C_RESET} $2"
}

smart_field() {
    # smart_field <json> <key> -> value or "-"
    if [[ $1 =~ \"$2\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "-"
    fi
}

compose_detail() {
    local addr=$1 port=${PORT_OF[$1]:-} name=${NVME_OF[$1]:-$1}
    local now up line def n dc pc v
    printf -v now '%(%F %T)T' -1
    up=$(fmt_duration "$SECONDS")
    BUF=""

    # --- header ---------------------------------------------------------
    BUF+="${C_BOLD}${C_CYAN}${name}${C_RESET}"
    BUF+=" ${C_DIM}${GLYPH_SEP}${C_RESET} ${SERIAL_OF[$addr]:--}"
    BUF+=" ${C_DIM}${GLYPH_SEP}${C_RESET} ${MODEL_OF[$addr]:--}"
    BUF+=" ${C_DIM}${GLYPH_SEP} fw${C_RESET} ${FW_OF[$addr]:--}"
    BUF+="${C_DIM} ${GLYPH_SEP} updated ${now} ${GLYPH_SEP} up ${up}${C_RESET}${EOL}"$'\n'
    soak_status
    [[ -n $SOAK_LINE ]] && BUF+="${SOAK_LINE}${EOL}"$'\n'
    BUF+="${EOL}"$'\n'

    # --- link -----------------------------------------------------------
    read_link "$addr"
    BUF+="${C_BOLD}${C_BLUE}LINK${C_RESET}${EOL}"$'\n'
    local state=""
    [[ $LINK_DEGRADED == true ]] && state=" ${C_YELLOW}DEGRADED${C_RESET}"
    [[ $LINK_CAPPED == true ]] && state=" ${C_DIM}(capped)${C_RESET}"
    line="  $(detail_kv "drive" "$(pci_display "$addr")")  ${LINK_TEXT}${state}"
    line+="  $(detail_kv "max" "$(gen_of_speed "$LINK_MAX_SPEED") x${LINK_MAX_WIDTH}")"
    if [[ -n $LINK_TARGET_X10 ]]; then
        case $LINK_TARGET_X10 in
            25) v="Gen1" ;; 50) v="Gen2" ;; 80) v="Gen3" ;;
            160) v="Gen4" ;; 320) v="Gen5" ;; 640) v="Gen6" ;; *) v="?" ;;
        esac
        line+="  $(detail_kv "port target" "$v")"
    fi
    BUF+="${line}${EOL}"$'\n'
    if [[ -n $port ]]; then
        line="  $(detail_kv "port " "$(pci_display "$port")")"
        line+="  $(gen_of_speed "$(sysval "$SYS/bus/pci/devices/$port/current_link_speed")") x$(sysval "$SYS/bus/pci/devices/$port/current_link_width")"
        line+="  $(detail_kv "max" "$(gen_of_speed "$(sysval "$SYS/bus/pci/devices/$port/max_link_speed")") x$(sysval "$SYS/bus/pci/devices/$port/max_link_width")")"
        BUF+="${line}${EOL}"$'\n'
    else
        BUF+="  ${C_DIM}no parent port visible (root-complex integrated endpoint?)${C_RESET}${EOL}"$'\n'
    fi

    # ASPM / MPS / MRRS / AER masks
    local lnkctl devctl mask aspm mps mrrs masked
    lnkctl=$(pci_read "$addr" "CAP_EXP+10.w") || lnkctl=""
    devctl=$(pci_read "$addr" "CAP_EXP+8.w") || devctl=""
    if [[ -n $lnkctl ]]; then
        case $(( 16#$lnkctl & 0x3 )) in
            0) aspm="off" ;; 1) aspm="L0s" ;; 2) aspm="L1" ;; 3) aspm="L0s+L1" ;;
        esac
    else
        aspm="?"
    fi
    if [[ -n $devctl ]]; then
        mps=$(( 128 << ( (16#$devctl >> 5) & 0x7 ) ))
        mrrs=$(( 128 << ( (16#$devctl >> 12) & 0x7 ) ))
    else
        mps="?" mrrs="?"
    fi
    masked="none"
    if mask=$(read_aer "$addr" 14) && [[ -n ${mask//0/} ]]; then
        decode_status "$mask" corr
        masked=${DEC_NAMES[*]}
    fi
    line="  $(detail_kv "ASPM" "$aspm")  $(detail_kv "MPS" "$mps")  $(detail_kv "MRRS" "$mrrs")"
    line+="  $(detail_kv "corr masked:" "$masked")"
    BUF+="${line}${EOL}"$'\n'
    BUF+="${EOL}"$'\n'

    # --- per-type error matrix -------------------------------------------
    BUF+="${C_BOLD}${C_BLUE}AER EVENTS THIS SESSION${C_RESET}"
    BUF+="            ${ADN}${C_DIM}drive   ${C_RESET}${AUP}${C_DIM}port${C_RESET}${EOL}"$'\n'
    local any=false
    for def in "${CORR_DEF[@]}" "${UNC_DEF[@]}"; do
        n=${def#*:}
        dc=${TYPECNT[d|$addr|$n]:-0}
        pc=0
        [[ -n $port ]] && pc=${TYPECNT[p|$port|$n]:-0}
        (( dc + pc > 0 )) || continue
        any=true
        local sev="$C_YELLOW"
        [[ " ${UNC_DEF[*]} " == *":$n "* || " ${UNC_DEF[*]} " == *":$n"* ]] && sev="$C_BOLD$C_RED"
        printf -v line '  %-14s' "$n"
        BUF+="${line}$(cnt_cell "$dc" 12 "$sev") $(cnt_cell "$pc" 7 "$sev")${EOL}"$'\n'
    done
    [[ $any == false ]] && BUF+="  ${C_GREEN}clean${C_RESET} ${C_DIM}- no error events observed${C_RESET}${EOL}"$'\n'

    # header log (last uncorrectable TLP header, either end)
    local end hdr
    for end in d p; do
        hdr=${HDR_LOG[${addr}|$end]:-}
        [[ $end == p && -n $port ]] && hdr=${HDR_LOG[${port}|p]:-}
        [[ -n $hdr ]] || continue
        local hts=${HDR_TIME[${addr}|$end]:-}
        [[ $end == p ]] && hts=${HDR_TIME[${port}|p]:-}
        local arrow=$ADN; [[ $end == p ]] && arrow=$AUP
        BUF+="  ${C_DIM}hdr log${C_RESET} ${arrow} ${hts} $(decode_tlp_hdr $hdr) ${C_DIM}[$hdr]${C_RESET}${EOL}"$'\n'
    done
    BUF+="${EOL}"$'\n'

    # --- health -----------------------------------------------------------
    BUF+="${C_BOLD}${C_BLUE}HEALTH${C_RESET}${EOL}"$'\n'
    get_temp "$addr"
    line="  $(detail_kv "temp" "${TEMP_C:--}C")"
    local hdir=${HWMON_DIR_OF[$addr]:-} tf lab tv i=2
    if [[ -n $hdir ]]; then
        for tf in "$hdir"/temp[2-9]_input; do
            [[ -r $tf ]] || continue
            tv=$(sysval "$tf")
            [[ $tv =~ ^-?[0-9]+$ ]] || continue
            lab=$(sysval "${tf%_input}_label")
            line+="  ${C_DIM}${lab:-temp$i}:${C_RESET} $(( (tv + 500) / 1000 ))C"
            (( i++ ))
        done
    fi
    line+="  $(detail_kv "warn/crit" "${TEMP_WARN}/${TEMP_CRIT}C")"
    BUF+="${line}${EOL}"$'\n'
    if [[ $HAVE_NVME_CLI == true && -n ${NVME_OF[$addr]:-} && -e $DEV/${NVME_OF[$addr]} ]]; then
        local sj
        sj=$(nvme smart-log "$DEV/${NVME_OF[$addr]}" -o json 2> /dev/null)
        if [[ -n $sj ]]; then
            line="  $(detail_kv "spare" "$(smart_field "$sj" avail_spare)%")"
            line+="  $(detail_kv "used" "$(smart_field "$sj" percent_used)%")"
            line+="  $(detail_kv "media errs" "$(smart_field "$sj" media_errors)")"
            line+="  $(detail_kv "unsafe shutdowns" "$(smart_field "$sj" unsafe_shutdowns)")"
            line+="  $(detail_kv "err log entries" "$(smart_field "$sj" num_err_log_entries)")"
            BUF+="${line}${EOL}"$'\n'
        fi
    else
        BUF+="  ${C_DIM}(install nvme-cli for SMART details)${C_RESET}${EOL}"$'\n'
    fi
    BUF+="${EOL}"$'\n'

    # --- events for this drive ---------------------------------------------
    compose_events "$name" 10
    BUF+="${EOL}"$'\n'
    BUF+="${C_DIM} Esc/b back ${GLYPH_SEP} n/N next/prev ${GLYPH_SEP} t read soak ${GLYPH_SEP} c clear counters ${GLYPH_SEP} q quit"
    BUF+="${FLASH_MSG:+ ${GLYPH_SEP} ${C_RESET}${C_BOLD}${FLASH_MSG}${C_DIM}}"
    BUF+="${C_RESET}${EOL}"$'\n'
    FLASH_MSG=""
}

print_summary() {
    local addr port name dur ev ts dev end kind names raw eaddr shown=false
    printf -v dur '%s' "$(fmt_duration "$SECONDS")"
    printf '\n%sNVMe AER Monitor%s %s session summary (%s, ended %s)\n' \
        "$C_BOLD" "$C_RESET" "$GLYPH_SEP" "$dur" "$(printf '%(%F %T)T' -1)"
    printf '  events observed: %s corr / %s unc at drives, %s corr / %s unc at host ports\n' \
        "$TOT_DC" "$TOT_DU" "$TOT_PC" "$TOT_PU"
    for addr in "${DISPLAY_ORDER[@]}"; do
        port=${PORT_OF[$addr]:-}
        local d_tot=$(( ${CUM_CORR[$addr]:-0} + ${CUM_UNC[$addr]:-0} )) p_tot=0
        [[ -n $port ]] && p_tot=$(( ${P_CUM_CORR[$port]:-0} + ${P_CUM_UNC[$port]:-0} ))
        (( d_tot + p_tot > 0 )) || continue
        shown=true
        name=${NVME_OF[$addr]:-$addr}
        printf '  %-8s %-16s %s%s %s corr / %s unc   %s%s %s corr / %s unc   last: %s\n' \
            "$name" "${SERIAL_OF[$addr]:--}" \
            "$A_DN" "" "${CUM_CORR[$addr]:-0}" "${CUM_UNC[$addr]:-0}" \
            "$A_UP" "" "${P_CUM_CORR[$port]:-0}" "${P_CUM_UNC[$port]:-0}" \
            "${LAST_ERR[$addr]:-${P_LAST[$port]:--}}"
    done
    [[ $shown == false ]] && printf '  no AER errors observed\n'
    if (( ${#EVENTS[@]} > 0 )); then
        printf '  recent events:\n'
        local start=$(( ${#EVENTS[@]} > 10 ? ${#EVENTS[@]} - 10 : 0 ))
        for ev in "${EVENTS[@]:$start}"; do
            IFS='|' read -r ts dev end kind names raw eaddr <<< "$ev"
            local where="drive"
            [[ $end == p ]] && where="port $(pci_display "$eaddr")"
            printf '    %s  %-8s %-16s %-13s %s (status 0x%s)\n' \
                "$ts" "$dev" "$where" "$kind" "$names" "$raw"
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
    local addr port first=true corr unc corr_names corr_count unc_names unc_count
    local p_corr p_unc pc_names pc_count pu_names pu_count tgt
    printf '{\n'
    printf '  "version": "%s",\n' "$VERSION"
    printf '  "timestamp": "%s",\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf '  "host": "%s",\n' "$(json_escape "${HOSTNAME:-localhost}")"
    printf '  "reset_after_read": %s,\n' "$([[ $NO_RESET == true ]] && printf 'false' || printf 'true')"
    printf '  "devices": [\n'
    for addr in "${DISPLAY_ORDER[@]}"; do
        [[ $first == true ]] && first=false || printf ',\n'
        port=${PORT_OF[$addr]:-}
        corr=${CORR_RAW[$addr]:-}
        unc=${UNC_RAW[$addr]:-}
        if [[ -n $corr ]]; then decode_status "$corr" corr; else DEC_NAMES=(); fi
        corr_names=$(json_names); corr_count=${#DEC_NAMES[@]}
        if [[ -n $unc ]]; then decode_status "$unc" unc; else DEC_NAMES=(); fi
        unc_names=$(json_names); unc_count=${#DEC_NAMES[@]}
        read_link "$addr"
        case ${LINK_TARGET_X10:-} in
            25) tgt="2.5 GT/s" ;; 50) tgt="5.0 GT/s" ;; 80) tgt="8.0 GT/s" ;;
            160) tgt="16.0 GT/s" ;; 320) tgt="32.0 GT/s" ;; 640) tgt="64.0 GT/s" ;;
            *) tgt="" ;;
        esac
        printf '    {\n'
        printf '      "device": "%s",\n' "${NVME_OF[$addr]:-N/A}"
        printf '      "pci_address": "%s",\n' "$addr"
        printf '      "serial": "%s",\n' "$(json_escape "${SERIAL_OF[$addr]:-N/A}")"
        printf '      "model": "%s",\n' "$(json_escape "${MODEL_OF[$addr]:-N/A}")"
        printf '      "firmware": "%s",\n' "$(json_escape "${FW_OF[$addr]:-N/A}")"
        printf '      "link": {"speed": "%s", "width": "%s", "max_speed": "%s", "max_width": "%s", "target_speed": "%s", "degraded": %s, "capped": %s},\n' \
            "$LINK_SPEED" "$LINK_WIDTH" "$LINK_MAX_SPEED" "$LINK_MAX_WIDTH" \
            "$tgt" "$LINK_DEGRADED" "$LINK_CAPPED"
        get_temp "$addr"
        printf '      "temperature_c": %s,\n' "${TEMP_C:-null}"
        printf '      "aer_supported": %s,\n' "${AER_OK[$addr]:-false}"
        printf '      "correctable": {"status_raw": "%s", "events": %s, "types": %s},\n' \
            "${corr:-}" "$corr_count" "$corr_names"
        printf '      "uncorrectable": {"status_raw": "%s", "events": %s, "types": %s},\n' \
            "${unc:-}" "$unc_count" "$unc_names"
        if [[ -n $port ]]; then
            p_corr=${P_CORR_RAW[$port]:-}
            p_unc=${P_UNC_RAW[$port]:-}
            if [[ -n $p_corr ]]; then decode_status "$p_corr" corr; else DEC_NAMES=(); fi
            pc_names=$(json_names); pc_count=${#DEC_NAMES[@]}
            if [[ -n $p_unc ]]; then decode_status "$p_unc" unc; else DEC_NAMES=(); fi
            pu_names=$(json_names); pu_count=${#DEC_NAMES[@]}
            printf '      "host_port": {\n'
            printf '        "pci_address": "%s",\n' "$port"
            printf '        "aer_supported": %s,\n' "${P_AER_OK[$port]:-false}"
            printf '        "correctable": {"status_raw": "%s", "events": %s, "types": %s},\n' \
                "${p_corr:-}" "$pc_count" "$pc_names"
            printf '        "uncorrectable": {"status_raw": "%s", "events": %s, "types": %s}\n' \
                "${p_unc:-}" "$pu_count" "$pu_names"
            printf '      },\n'
        else
            printf '      "host_port": null,\n'
        fi
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
    SHOW_PORTS=true
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

VIEW="main"
DETAIL_IDX=0

detail_jump() {
    # detail_jump <nvme-number>: open detail for nvmeN if it exists
    local i addr
    for i in "${!DISPLAY_ORDER[@]}"; do
        addr=${DISPLAY_ORDER[$i]}
        if [[ ${NVME_OF[$addr]:-} == "nvme$1" ]]; then
            VIEW="detail"
            DETAIL_IDX=$i
            return 0
        fi
    done
    FLASH_MSG="no such device: nvme$1"
    return 0
}

while true; do
    discover_devices
    set_pci_width
    poll_all
    (( DETAIL_IDX >= ${#DISPLAY_ORDER[@]} )) && DETAIL_IDX=0
    if [[ $VIEW == detail && ${#DISPLAY_ORDER[@]} -gt 0 ]]; then
        compose_detail "${DISPLAY_ORDER[$DETAIL_IDX]}"
    else
        VIEW="main"
        compose_frame live
    fi
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
        p | P) [[ $SHOW_PORTS == true ]] && SHOW_PORTS=false || SHOW_PORTS=true ;;
        d | D)
            if [[ $VIEW == main ]]; then
                VIEW="detail"
                # jump to the first drive with errors, if any
                for i in "${!DISPLAY_ORDER[@]}"; do
                    addr=${DISPLAY_ORDER[$i]}
                    port=${PORT_OF[$addr]:-}
                    if (( ${CUM_CORR[$addr]:-0} + ${CUM_UNC[$addr]:-0} > 0 )) \
                       || { [[ -n $port ]] && (( ${P_CUM_CORR[$port]:-0} + ${P_CUM_UNC[$port]:-0} > 0 )); }; then
                        DETAIL_IDX=$i
                        break
                    fi
                done
            fi ;;
        [0-9]) detail_jump "$key" ;;
        n)     [[ $VIEW == detail ]] && DETAIL_IDX=$(( (DETAIL_IDX + 1) % ${#DISPLAY_ORDER[@]} )) ;;
        N)     [[ $VIEW == detail ]] && DETAIL_IDX=$(( (DETAIL_IDX - 1 + ${#DISPLAY_ORDER[@]}) % ${#DISPLAY_ORDER[@]} )) ;;
        c | C) [[ $VIEW == detail ]] && clear_device_counters "${DISPLAY_ORDER[$DETAIL_IDX]}" ;;
        t | T)
            if [[ $VIEW == detail ]]; then
                if [[ -n $SOAK_ADDR ]]; then
                    stop_soak
                else
                    start_soak "${DISPLAY_ORDER[$DETAIL_IDX]}"
                fi
            fi ;;
        $'\e')
            # drain any pending escape-sequence bytes (arrow keys etc.)
            IFS= read -rsn2 -t 0.01 _ 2> /dev/null
            VIEW="main" ;;
        b | B) VIEW="main" ;;
    esac
done
