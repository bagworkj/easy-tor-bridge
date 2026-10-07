#!/bin/bash
# Read-only observations plus short TCP connections to this Mac. No external scan.
network_command() { run_bounded 5 "$@"; }
network_config() {
    (
        export -f compose
        export COMPOSE CONTEXT PROJECT_DIR
        run_bounded 5 /bin/bash -c 'compose config --format json'
    )
}

network_diagnostics() {
    local mode=$1 config ports='' port cid='' mapping listeners status issue=0
    local route_info='' interface='' gateway='' local_ip='' addresses='' firewall='' blockall='' pf=''
    local state='' logs='' tor_event=''
    # Resolve saved ports under a watchdog; other observations survive config failure.
    if config=$(network_config 2>/dev/null); then
        ports=$(printf '%s' "$config" | /usr/bin/perl -MJSON::PP -0777 -e '
            my $env = decode_json(<>)->{services}{"obfs4-bridge"}{environment};
            my @ports = map { $env->{$_} // "" } qw(OR_PORT PT_PORT);
            for (@ports) { /^\d+$/ && $_ >= 1 && $_ <= 65535 or die "Invalid TCP port\n"; }
            $ports[0] != $ports[1] or die "Bridge ports must be distinct\n";
            print join(" ", @ports);
        ' 2>/dev/null) || ports=''
    fi
    if [[ -z "$ports" ]]; then
        warning 'Network checks — Could not resolve two valid, distinct bridge TCP ports'
        [[ "$mode" != pre ]] || return 2
        issue=1
    fi
    cid=$(network_command "$DOCKER" --context "$CONTEXT" ps -q \
        --filter label=com.docker.compose.project=easy-tor-bridge \
        --filter label=com.docker.compose.service=obfs4-bridge 2>/dev/null) || cid=''

    if [[ "$mode" == pre ]]; then
        progress '  Checking configured TCP ports before startup...\n'
        for port in $ports; do
            mapping=''
            if [[ -n "$cid" ]]; then
                mapping=$(network_command "$DOCKER" --context "$CONTEXT" port "$cid" "$port/tcp" 2>/dev/null) || mapping=''
            fi
            if printf '%s\n' "$mapping" | awk -F: -v port="$port" '$NF == port {found=1} END {exit !found}'; then
                progress '  TCP %s — Already published by the bridge\n' "$port"
            elif listeners=$(network_command /usr/sbin/lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null); then
                warning "TCP $port — Occupied; startup may conflict with another program"
                printf '%s\n' "$listeners" | awk 'NR > 1 {printf "    Process: %s (PID %s)\n", $1, $2}'
                issue=1
            else
                status=$?
                if [[ $status -eq 1 ]]; then
                    progress '  TCP %s — No visible listener\n' "$port"
                else
                    warning "TCP $port — Listener check unavailable"
                    issue=1
                fi
            fi
        done
        return "$issue"
    fi

    route_info=$(network_command /sbin/route -n get default 2>/dev/null) || route_info=''
    interface=$(printf '%s\n' "$route_info" | awk '$1 == "interface:" {print $2; exit}')
    gateway=$(printf '%s\n' "$route_info" | awk '$1 == "gateway:" {print $2; exit}')
    if [[ -n "$interface" ]]; then
        progress '  Network interface — %s\n  IPv4 gateway — %s\n' "$interface" "${gateway:-Unknown}"
        addresses=$(network_command /sbin/ifconfig "$interface" 2>/dev/null) || addresses=''
        local_ip=$(network_command /usr/sbin/ipconfig getifaddr "$interface" 2>/dev/null) || local_ip=''
        if [[ -z "$local_ip" ]]; then
            local_ip=$(printf '%s\n' "$addresses" | awk '$1 == "inet" {print $2; exit}')
        fi
        case "$interface" in
            utun*|tun*|ppp*) warning 'Tunnel interface detected; the route may differ from your physical network' ;;
        esac
        if [[ -n "$local_ip" ]]; then
            progress '  Mac IPv4 address — %s\n' "$local_ip"
        else
            warning 'Mac IPv4 address — Unavailable; local-address tests will be skipped'
            issue=1
        fi
        if [[ "$addresses" == *inet6* ]]; then
            progress '  IPv6 — Present on this interface; these TCP checks cover IPv4 only\n'
        fi
    else
        warning 'IPv4 route — Unavailable; local-address tests will be skipped'
        issue=1
    fi

    for port in $ports; do
        mapping=''
        if [[ -n "$cid" ]]; then
            mapping=$(network_command "$DOCKER" --context "$CONTEXT" port "$cid" "$port/tcp" 2>/dev/null) || mapping=''
        fi
        if [[ -n "$mapping" ]]; then
            progress '  Docker TCP %s published at:\n' "$port"
            printf '%s\n' "$mapping" | while IFS= read -r address; do printf '    %s\n' "$address"; done
        else
            warning "TCP $port — Docker mapping unavailable"
            issue=1
        fi
        if network_command /usr/bin/nc -4 -z -G 2 -w 2 127.0.0.1 "$port" >/dev/null 2>&1; then
            success "Loopback TCP test passed — 127.0.0.1:$port"
        else
            warning "Loopback TCP test failed — 127.0.0.1:$port; check the container and Colima forwarding"
            issue=1
        fi
        if [[ -n "$local_ip" ]]; then
            if network_command /usr/bin/nc -4 -z -G 2 -w 2 "$local_ip" "$port" >/dev/null 2>&1; then
                success "Local-address TCP test passed — $local_ip:$port"
            else
                warning "Local-address TCP test failed — $local_ip:$port; check forwarding and firewall rules"
                issue=1
            fi
        fi
    done
    progress '  TCP tests originate on this Mac; access from other devices remains unverified.\n'

    firewall=$(network_command /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null) || firewall=''
    case "$firewall" in
        *'State = 0'*) progress '  macOS application firewall — Disabled\n' ;;
        *'State = 1'*|*'State = 2'*) progress '  macOS application firewall — Enabled; individual application rules were not verified\n' ;;
        *) warning 'macOS application firewall — Unknown; could not read its state' ;;
    esac
    blockall=$(network_command /usr/libexec/ApplicationFirewall/socketfilterfw --getblockall 2>/dev/null) || blockall=''
    case "$blockall" in
        *'set to enabled'*) warning 'Block all incoming connections — Enabled'; issue=1 ;;
        *'set to disabled'*) progress '  Block all incoming connections — Disabled\n' ;;
        *) warning 'Block all incoming connections — Unknown' ;;
    esac
    pf=$(network_command /sbin/pfctl -s info 2>/dev/null) || pf=''
    case "$pf" in
        *'Status: Enabled'*) warning 'PF packet filter — Enabled; effects of its rules are unverified' ;;
        *'Status: Disabled'*) progress '  PF packet filter — Disabled\n' ;;
        *) progress '  PF packet filter — Unknown (inspection may require administrator access)\n' ;;
    esac

    if [[ -n "$cid" ]]; then
        state=$(network_command "$DOCKER" --context "$CONTEXT" inspect \
            --format '{{.State.Status}}|{{.State.StartedAt}}' "$cid" 2>/dev/null) || state=''
        if [[ "$state" == running\|* ]]; then
            logs=$(network_command "$DOCKER" --context "$CONTEXT" logs \
                --since "${state#*|}" --tail 300 "$cid" 2>&1) || logs=''
        fi
    fi
    # Report the last relevant event in retained logs, not a current reachability guarantee.
    tor_event=$(printf '%s\n' "$logs" | awk '
        /Self-testing indicates your ORPort.*reachable/ {event="confirmed"}
        /has not managed to confirm reachability.*ORPort/ {event="unconfirmed"}
        END {print event}
    ')
    case "$tor_event" in
        confirmed) success 'OR port — Tor reported external reachability (historical log evidence)' ;;
        unconfirmed) warning 'OR port — Tor has not confirmed external reachability' ;;
        *) progress '  OR port — No reachability report found in recent retained logs\n' ;;
    esac
    warning 'obfs4 Internet reachability — Unverified; use an external test'
    if [[ -n "$ports" && -n "$local_ip" && "$interface" != utun* && "$interface" != tun* && "$interface" != ppp* ]]; then
        progress '\n  If you control a home router, the forwarding destinations would be:\n'
        for port in $ports; do progress '    TCP %s → %s:%s\n' "$port" "$local_ip" "$port"; done
        progress '  Network/router permission is still required. No router changes were made.\n'
    fi
    progress '  Managed networks may block inbound traffic. No firewall settings were changed.\n'
    return "$issue"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    mode=$1 DOCKER=$2 COMPOSE=$3 PROJECT_DIR=$4 CONTEXT=$5
    GREEN=${6:-} AMBER=${7:-} RESET=${8:-}
    source "$(dirname "${BASH_SOURCE[0]}")/bridge-runtime.sh"
    success() { progress '  %s✓ %s%s\n' "$GREEN" "$*" "$RESET"; }
    warning() { progress '  %s! %s%s\n' "$AMBER" "$*" "$RESET"; }
    if network_diagnostics "$mode"; then exit 0; else exit $?; fi
fi
