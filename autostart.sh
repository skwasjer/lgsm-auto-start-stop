#!/bin/bash
set -e -o pipefail -o noclobber -o nounset

# Author: skwas
# Github: https://github.com/skwasjer/

RED="\033[0;31m"
GREEN="\033[1;32m"
BLUE="\033[1;34m"
WHITE="\033[1;37m"
NC="\033[0m"

CH_U="\033[4m"

CLR="\r\033[0K"                 # Move caret to start and clear entire line.
RESET_POS="\r\033[21C\033[0K"   # Move caret to pos 21 and clear rest of line.

show_usage() {
    err=${1:-""}
    if [[ $err != "" ]]; then
        echo -e "Error: ${err}" >&2
    fi
    echo -e "${WHITE}${CH_U}Usage:${NC} ${0} LGSM_SCRIPT [OPTION]"
    echo
    echo -e "${WHITE}${CH_U}Options:${NC}"
    echo -e "  ${WHITE}-t, --stop-delay${NC} <SECONDS>      Number of seconds of network inactivity before server is stopped (default: 30)"
    echo -e "  ${WHITE}-p, --port${NC} <NUMBER>             Port number to listen on. Always use the game port, never the query port (if any)"
    echo -e "  ${WHITE}--tcp${NC}                           Listen for TCP packets (default: true)"
    echo -e "  ${WHITE}--udp${NC}                           Listen for UDP packets (default: true)"
    echo
    exit 1
}

echo_dbg() {
    if [[ $debug -eq 1 ]]; then
        if [[ $# -gt 0 ]]; then
            printf '%s\n' "$*"
        else
            echo
        fi
    fi
}

if [ "$(whoami)" == "root" ]; then
    show_usage "Do NOT run as root!"
fi

# ==== ARGS

getopt --test > /dev/null && true
if [[ $? -ne 4 ]]; then
    echo '`getopt --test` failed in this environment.' >&2
    exit 1
fi

LONGOPTS=debug,verbose,port:,tcp,udp,stop-delay:
OPTIONS=dvp:t:

PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@") || exit 2
# Read getopt output this way to handle the quoting right
eval set -- "$PARSED"

debug=0
verbose=0
port=0
tcp=0
udp=0
auto_stop_after_sec=30

# Parse options until we see -- or a parse/option error
re_int='^[0-9]+$'
while true; do
    case "$1" in
        -d|--debug)
            debug=1
            shift
            ;;
        -v|--verbose)
            verbose=1
            shift
            ;;
        -p|--port)
            port="$2"
            shift 2
            ;;
        --tcp)
            tcp=1
            shift
            ;;
        --udp)
            udp=1
            shift
            ;;
        -t|--stop-delay)
            auto_stop_after_sec="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Invalid operation"
            exit 3
            ;;
    esac
done

if [[ $# -ne 1 ]]; then
    show_usage
fi
lgsm_cmd=$1
lgsm_server=${lgsm_cmd##*/}

if ! [[ -f "${lgsm_cmd}" ]]; then
    echo -e "${0}: LGSM_SCRIPT not found." >&2
    exit 2
fi

if ! [[ $port =~ $re_int ]] || [[ $port -le 1024 ]]; then
    if [[ $port -eq 0 ]]; then
        show_usage
    else
        echo -e "${0}: --port must be greater than 1024." >&2
        exit 2
    fi
fi

if ! [[ $auto_stop_after_sec =~ $re_int ]] || [[ $auto_stop_after_sec -lt 30 ]]; then
    echo -e "${0}: --stop-delay must be greater than or equal to 30." >&2
    exit 2
fi

if [[ $tcp -eq 0 ]] && [[ $udp -eq 0 ]]; then
    # If neither is explicitly specified, enable both.
    tcp=1
    udp=1
fi

echo_dbg debug=$debug verbose=$verbose lgsm_cmd=$lgsm_cmd port=$port auto_stop_after_sec=$auto_stop_after_sec tcp=$tcp udp=$udp

set +e


# ==== SCRIPT START
poll_interval_sec=$(bc <<< "scale=2; ${auto_stop_after_sec}/10")
packet_count=40


is_server_running() {
    pgrep -fa "PalServer-Linux-Shipping.*\-port=${port}" > /dev/null
}

start_server() {
    if [[ $debug -eq 0 ]]; then
        ${lgsm_cmd} start
        # TODO: do smth with exit code (if it returns 0 and >0)
    fi
    # TODO: only wait for n seconds.
    while ! is_server_running; do
        sleep 0.5
    done
}

stop_server() {
    if [[ $debug -eq 0 ]]; then
        ${lgsm_cmd} stop
        # TODO: do smth with exit code (if it returns 0 and >0)
    fi
    # TODO: only wait for n seconds.
    while is_server_running; do
        sleep 0.5
    done
}

listen() {
    local packet_count="${1:-1}"
    local interval="${2:-$poll_interval_sec}"
    local proto="'tcp or udp'"
    if [[ $tcp -eq 0 ]]; then
        proto="udp"
    fi
    if [[ $udp -eq 0 ]]; then
        proto="tcp"
    fi
    timeout -f ${interval} tcpdump ${proto} -tttt -c ${packet_count} -Q in "port ${port}" 2> /dev/null
}

prev_packet_epoch_time=$(date -u +%s)
while :; do
    if is_server_running; then
        echo -ne "${CLR}${lgsm_server} is ${GREEN}RUNNING${NC}: Monitoring client activity..."
        while is_server_running; do
            last_packet=$(listen ${packet_count} | tail -2)
            conn_state=$?

            if [[ "$last_packet" != "" ]]; then
                # Record last inbound packet timestamp.
                echo -ne "${RESET_POS}One or more client(s) connected..."
                prev_packet_epoch_time=$(echo $last_packet | cut -c-19 | date -ud - +%s)
                # Introduce extra delay before we check again so we don't waste unnecessary cycles.
                sleep ${poll_interval_sec}

            elif [[ $conn_state -eq 124 ]] || [[ "$last_packet" == "" ]]; then
                # Calculate how long ago the last client disconnected, and stop the server once we hit the desired delay.
                now=$(date -u +%s)
                delta=$((now - prev_packet_epoch_time))
                echo -ne "${RESET_POS}No clients connected for ${delta} seconds..."
                if [[ $delta -ge $auto_stop_after_sec ]]; then
                    echo
                    stop_server
                    break
                fi
            fi
        done
    else
        echo -ne "${CLR}${lgsm_server} is ${RED}STOPPED${NC}: Waiting for clients..."
        while ! is_server_running; do
            # As soon as an inbound packet is received, start the server.
            last_packet=$(listen)
            conn_state=$?

            if [[ $conn_state -eq 0 ]]; then
                echo -e "${RESET_POS}Client attempting to connect..."
                start_server
                break
            fi
        done
    fi
done