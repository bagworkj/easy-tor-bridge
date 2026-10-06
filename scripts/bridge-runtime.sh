#!/bin/bash
# Sourced by install.sh, or run as a bootstrap-check worker under a watchdog.

compose() {
    (
        # Saved project configuration wins over unrelated shell/Compose settings.
        for variable in ${!COMPOSE_@}; do unset "$variable"; done
        unset EMAIL OR_PORT PT_PORT NICKNAME
        "$COMPOSE" --context "$CONTEXT" --project-name easy-tor-bridge \
            --project-directory "$PROJECT_DIR" --env-file "$PROJECT_DIR/.env" \
            -f "$PROJECT_DIR/compose.yaml" "$@"
    )
}

run_bounded() {
    /usr/bin/perl -MPOSIX=:sys_wait_h,setpgid -e '
        my $seconds = shift @ARGV;
        my $pid = fork();
        defined $pid or die "fork: $!";
        if (!$pid) {
            setpgid(0, 0) == 0 or die "setpgid: $!";
            exec @ARGV;
            die "exec: $!";
        }
        sub stop_child {
            my ($code) = @_;
            kill "TERM", -$pid;
            select undef, undef, undef, 0.1;
            kill "KILL", -$pid;
            waitpid($pid, 0);
            exit $code;
        }
        $SIG{ALRM} = sub { stop_child(124) };
        $SIG{INT} = sub { stop_child(130) };
        $SIG{TERM} = sub { stop_child(143) };
        alarm $seconds;
        waitpid($pid, 0);
        my $status = $?;
        alarm 0;
        exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
    ' "$@"
}

wait_for_bootstrap() {
    local deadline container_id state logs confirmed_state session cached marker
    local waiting=false
    deadline=$((SECONDS + 300))
    while (( SECONDS < deadline )); do
        container_id=$(compose ps -a -q obfs4-bridge) || return 2
        [[ -n "$container_id" ]] || return 2
        state=$("$DOCKER" --context "$CONTEXT" inspect \
            --format '{{.State.Status}}|{{.State.StartedAt}}' "$container_id") || return 2
        case "$state" in
            running\|*)
                session="$container_id|$state"
                cached=''
                if [[ -f "$BOOTSTRAP_CACHE" ]]; then
                    IFS= read -r cached < "$BOOTSTRAP_CACHE" || cached=''
                fi
                logs=''
                if [[ "$cached" != "$session" ]]; then
                    logs=$("$DOCKER" --context "$CONTEXT" logs --since "${state#*|}" "$container_id" 2>&1) || return 2
                fi
                if [[ "$cached" == "$session" || "$logs" == *'Bootstrapped 100% (done):'* ]]; then
                    confirmed_state=$("$DOCKER" --context "$CONTEXT" inspect \
                        --format '{{.State.Status}}|{{.State.StartedAt}}' "$container_id") || return 2
                    if [[ "$state" == "$confirmed_state" ]]; then
                        # An interrupted write cannot become a valid record for another start.
                        umask 077
                        mkdir -p "$(dirname "$BOOTSTRAP_CACHE")" || return 2
                        marker=$(mktemp "${BOOTSTRAP_CACHE}.XXXXXX") || return 2
                        if ! printf '%s\n' "$session" > "$marker" || ! mv "$marker" "$BOOTSTRAP_CACHE"; then
                            rm -f "$marker"
                            return 2
                        fi
                        if [[ $waiting == false ]]; then
                            success 'Current Tor session already bootstrapped.'
                        else
                            success 'Tor bootstrap complete.'
                        fi
                        return 0
                    fi
                fi ;;
            restarting\|*|created\|*) ;;
            *) return 2 ;;
        esac
        if [[ $waiting == false ]]; then
            printf '  Waiting for Tor to bootstrap (up to 5 minutes)...\n'
            waiting=true
        fi
        sleep 5
    done
    return 1
}

unload_autostart() {
    local label=org.easy-tor-bridge.colima domain="gui/$(id -u)"
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
        launchctl bootout "$domain/$label" || fail 'Could not unload automatic startup.'
    fi
}

set_autostart() {
    local agent_dir="$HOME/Library/LaunchAgents" agent_file label=org.easy-tor-bridge.colima
    local domain="gui/$(id -u)" agent_temp
    agent_file="$agent_dir/$label.plist"
    if [[ $1 == off ]]; then
        unload_autostart
        rm -f "$agent_file"
        AUTOSTART_STATUS='Disabled'
        return
    fi
    mkdir -p "$agent_dir"
    agent_temp=$(mktemp "$agent_dir/.easy-tor-bridge.XXXXXX")
    # plutil encodes paths safely, including spaces and XML special characters.
    /usr/bin/plutil -create xml1 "$agent_temp"
    /usr/bin/plutil -insert Label -string "$label" "$agent_temp"
    /usr/bin/plutil -insert ProgramArguments -array "$agent_temp"
    /usr/bin/plutil -insert ProgramArguments.0 -string "$BREW_PREFIX/bin/colima" "$agent_temp"
    /usr/bin/plutil -insert ProgramArguments.1 -string start "$agent_temp"
    /usr/bin/plutil -insert ProgramArguments.2 -string "$PROFILE" "$agent_temp"
    /usr/bin/plutil -insert ProgramArguments.3 -string '--activate=false' "$agent_temp"
    /usr/bin/plutil -insert RunAtLoad -bool YES "$agent_temp"
    # Colima detaches its VM processes; preserve them when this one-shot job exits.
    # This also leaves the bridge running on logout, until Colima or the Mac stops.
    /usr/bin/plutil -insert AbandonProcessGroup -bool YES "$agent_temp"
    /usr/bin/plutil -insert KeepAlive -dictionary "$agent_temp"
    /usr/bin/plutil -insert KeepAlive.SuccessfulExit -bool NO "$agent_temp"
    /usr/bin/plutil -insert ThrottleInterval -integer 30 "$agent_temp"
    /usr/bin/plutil -insert EnvironmentVariables -dictionary "$agent_temp"
    /usr/bin/plutil -insert EnvironmentVariables.PATH -string "$BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$agent_temp"
    /usr/bin/plutil -insert EnvironmentVariables.HOME -string "$HOME" "$agent_temp"
    /usr/bin/plutil -lint "$agent_temp" >/dev/null
    chmod 600 "$agent_temp"
    unload_autostart
    mv "$agent_temp" "$agent_file"
    launchctl enable "$domain/$label"
    launchctl bootstrap "$domain" "$agent_file" || fail 'Could not register automatic startup for this login session.'
    AUTOSTART_STATUS='Enabled at login'
}

start_engine() {
    local attempt ready=false
    colima start "$PROFILE" --runtime docker --activate=false --network-host-addresses
    for ((attempt=0; attempt<60; attempt++)); do
        if run_bounded 5 "$DOCKER" --context "$CONTEXT" info >/dev/null 2>&1; then
            ready=true
            break
        fi
        sleep 5
    done
    [[ $ready == true ]] || fail 'Colima engine did not become ready. Check colima status easy-tor-bridge.'
}

install_bridge_command() {
    local target="$HOME/.local/bin/bridge"
    mkdir -p "$(dirname "$target")"
    if [[ -e "$target" || -L "$target" ]]; then
        if [[ -L "$target" && $(readlink "$target") == "$PROJECT_DIR/bridge" ]]; then
            printf '  bridge command — Already installed\n'
        else
            warning 'Existing ~/.local/bin/bridge was preserved; use ./bridge from this repository.'
            return
        fi
    else
        ln -s "$PROJECT_DIR/bridge" "$target"
        printf '  bridge command — Installed in ~/.local/bin\n'
    fi
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) printf '  To use bridge in this terminal, run:\n    export PATH="$HOME/.local/bin:$PATH"\n'
           printf '  Add that line to ~/.zshrc to keep it for future terminals.\n' ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    DOCKER=$1 COMPOSE=$2 PROJECT_DIR=$3 CONTEXT=$4 BOOTSTRAP_CACHE=$5
    GREEN=${6:-} RESET=${7:-}
    success() { printf '  %s✓ %s%s\n' "$GREEN" "$*" "$RESET"; }
    # Keep error handling inside the function active rather than implicit errexit.
    if wait_for_bootstrap; then exit 0; else exit $?; fi
fi
