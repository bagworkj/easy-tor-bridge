#!/bin/bash
# Run as your regular user: ./install.sh
set -euo pipefail

# Color is optional; labels remain meaningful in plain-text logs.
RESET='' BOLD='' GREEN='' AMBER='' RED=''
if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]]; then
    RESET=$'\033[0m' BOLD=$'\033[1m' GREEN=$'\033[32m' RED=$'\033[31m'
    if [[ ${TERM:-} == *256color* || ${COLORTERM:-} == truecolor ]]; then
        AMBER=$'\033[38;5;214m'
    else
        AMBER=$'\033[33m'
    fi
fi
success() { printf '  %s✓ %s%s\n' "$GREEN" "$*" "$RESET"; }
warning() { printf '  %s! %s%s\n' "$AMBER" "$*" "$RESET"; }
heading() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }
fail() { printf '%sError: %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }
[[ $(uname -s) == Darwin ]] || fail 'This installer supports macOS only.'
[[ $EUID -ne 0 ]] || fail 'Run without sudo; setup requests administrator access when needed.'
PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$PROJECT_DIR"
[[ -f compose.yaml && -f .env.example && -f scripts/bridge-runtime.sh ]] || fail 'Run install.sh from a complete copy of this project.'
[[ -x /usr/bin/perl ]] || fail 'The macOS Perl runtime is required for bounded health checks.'
source "$PROJECT_DIR/scripts/bridge-runtime.sh"
BOOTSTRAP_CACHE="$HOME/Library/Application Support/easy-tor-bridge/bootstrap"

# Keep all commands on the dedicated local Colima engine.
unset DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
PROFILE=easy-tor-bridge
CONTEXT=colima-easy-tor-bridge
heading '[1/5] Install dependencies'
homebrew_installed_now=false
if [[ -x /opt/homebrew/bin/brew ]]; then
    BREW=/opt/homebrew/bin/brew
elif [[ -x /usr/local/bin/brew ]]; then
    BREW=/usr/local/bin/brew
elif command -v brew >/dev/null 2>&1; then
    BREW=$(command -v brew)
else
    printf '  Installing Homebrew. Follow its terminal prompts.\n'
    brew_installer=$(mktemp "${TMPDIR:-/tmp}/easy-tor-brew.XXXXXX")
    trap 'rm -f "$brew_installer"' EXIT
    curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
        https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$brew_installer"
    /bin/bash "$brew_installer"
    homebrew_installed_now=true
    rm -f "$brew_installer"
    trap - EXIT
    if [[ -x /opt/homebrew/bin/brew ]]; then
        BREW=/opt/homebrew/bin/brew
    else
        BREW=/usr/local/bin/brew
    fi
fi
BREW_PREFIX=$("$BREW" --prefix)
if [[ $homebrew_installed_now == true ]]; then
    success 'Homebrew — installed'
else
    success 'Homebrew — already installed'
fi
export PATH="$BREW_PREFIX/bin:$PATH"
for dependency in colima docker docker-compose; do
    if "$BREW" list --versions "$dependency" >/dev/null 2>&1; then
        success "$dependency — already installed"
    else
        printf '  Installing %s...\n' "$dependency"
        "$BREW" install "$dependency"
        success "$dependency — installed"
    fi
done
DOCKER="$BREW_PREFIX/opt/docker/bin/docker"
# Invoke Homebrew's Compose directly; no edits to the user's Docker config.
COMPOSE="$BREW_PREFIX/opt/docker-compose/bin/docker-compose"


heading '[2/5] Start Colima'
colima start "$PROFILE" --runtime docker --activate=false --network-host-addresses
ready=false
for ((attempt=0; attempt<60; attempt++)); do
    if run_bounded 5 "$DOCKER" --context "$CONTEXT" info >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 5
done
[[ $ready == true ]] || fail 'Colima engine did not become ready. Check colima status easy-tor-bridge.'
"$COMPOSE" version >/dev/null || fail 'Docker Compose could not start.'

heading '[3/5] Configure bridge'
umask 077
if [[ ! -e .env ]]; then
    cp .env.example .env
    printf 'Created .env from .env.example.\n'
fi


# Read configuration as data; never source .env as a shell script.
# Keep an existing nonempty EMAIL, including quoted Compose values.
configured_email=$(awk '
    /^[[:space:]]*(export[[:space:]]+)?EMAIL[[:space:]]*=/ {
        value = $0
        sub(/^[^=]*=[[:space:]]*/, "", value)
        sub(/[[:space:]]+#.*$/, "", value)
        sub(/[[:space:]]*$/, "", value)
    }
    END { print value }
' .env)
case "$configured_email" in
    ''|'""'|"''"|\#*)
        [[ -t 0 ]] || fail 'Email setup needs an interactive terminal. Run ./install.sh in Terminal.'
        printf '\nBridge contact email\n'
        printf '  Enter an address Tor operators can use to contact you about your bridge.\n'
        while true; do
            printf '\n  Your email: '
            IFS= read -r bridge_email || fail 'Email entry cancelled. Rerun setup to continue.'
            # Accept common email syntax; exclude Compose interpolation and quoting.
            if [[ "$bridge_email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
                break
            fi
            printf '  Enter an email such as you@example.com (without spaces).\n'
        done
        env_temp=$(mktemp "$PROJECT_DIR/.env.setup.XXXXXX")
        if ! awk -v email="$bridge_email" '
            /^[[:space:]]*(export[[:space:]]+)?EMAIL[[:space:]]*=/ {
                if (!written) print "EMAIL=" email
                written = 1
                next
            }
            { print }
            END { if (!written) print "EMAIL=" email }
        ' .env > "$env_temp"; then
            rm -f "$env_temp"
            fail 'Could not save email. Your existing .env was preserved.'
        fi
        if ! mv "$env_temp" .env; then
            rm -f "$env_temp"
            fail 'Could not replace .env with the updated configuration.'
        fi
        printf '  Email saved. Other bridge settings were preserved.\n'
        ;;
    *) printf 'Using the contact email already configured in .env.\n' ;;
esac

if ! compose config --quiet; then
    fail 'Bridge configuration is invalid. Review the Compose error above and your .env settings, then rerun setup.'
fi
heading '[4/5] Start bridge container'
# Fetch on first install; rerunning setup does not implicitly upgrade the image.
compose up -d --pull missing obfs4-bridge

heading '[5/5] Verify Tor bootstrap'
if run_bounded 300 /bin/bash "$PROJECT_DIR/scripts/bridge-runtime.sh" \
    "$DOCKER" "$COMPOSE" "$PROJECT_DIR" "$CONTEXT" "$BOOTSTRAP_CACHE" "$GREEN" "$RESET"; then
    printf '  Bootstrap success was observed during this container session.\n'
else
    result=$?
    if [[ $result -eq 1 || $result -eq 124 ]]; then
        printf '  Bootstrap could not be confirmed within 5 minutes. No container was stopped.\n'
        printf '  Older sessions without a saved success record may need a restart if their logs have rotated.\n'
    else
        printf '  Bootstrap verification failed; check Docker, the container, and local file permissions.\n'
    fi
    printf '  Inspect logs: docker-compose --context colima-easy-tor-bridge logs -f --tail=100\n'
    exit 1
fi
# A per-user LaunchAgent starts only this project's Colima profile at login.
# Container restart policies bring the bridge back when its engine starts.
configure_autostart() {
    local agent_dir agent_file label domain answer agent_temp
    agent_dir="$HOME/Library/LaunchAgents"
    label=org.easy-tor-bridge.colima
    agent_file="$agent_dir/$label.plist"
    domain="gui/$(id -u)"
    AUTOSTART_STATUS='Not configured'
    heading 'Automatic startup'
    printf '  Colima starts at login and stays running after logout while the Mac is awake.\n'
    printf '  Enable automatic startup? [y/n]: '
    if [[ ! -t 0 ]]; then
        printf '\n'
        warning 'No interactive terminal; automatic startup settings were left unchanged.'
        AUTOSTART_STATUS='Unchanged (not checked)'
        return
    fi
    while true; do
        if ! IFS= read -r answer; then
            printf '\n'
            warning 'No answer; automatic startup settings were left unchanged.'
            AUTOSTART_STATUS='Unchanged (not checked)'
            return
        fi
        case "$answer" in
            y|Y|yes|YES) break ;;
            n|N|no|NO)
                if launchctl print "$domain/$label" >/dev/null 2>&1; then
                    launchctl bootout "$domain/$label" || fail 'Could not disable automatic startup.'
                fi
                rm -f "$agent_file"
                AUTOSTART_STATUS='Disabled'
                return ;;
            *) printf '  Please enter y or n: ' ;;
        esac
    done
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
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
        launchctl bootout "$domain/$label" || fail 'Could not reload automatic startup.'
    fi
    mv "$agent_temp" "$agent_file"
    launchctl enable "$domain/$label"
    launchctl bootstrap "$domain" "$agent_file" || fail 'Could not register automatic startup for this login session.'
    AUTOSTART_STATUS='Enabled at login'
}
configure_autostart

heading 'Setup Complete'
success 'Tor bootstrap — Complete'
warning 'Internet reachability — Unverified'
printf '  Automatic startup — %s\n' "$AUTOSTART_STATUS"
printf '\nTest your public IP and obfs4 port:\n  https://bridges.torproject.org/scan/\n'
printf '\nKeep your Mac awake. Home routers may require forwarding both TCP ports.\n'
if [[ "$AUTOSTART_STATUS" != 'Enabled at login' ]]; then
    printf 'Rerun ./install.sh after restarting your Mac to start the bridge.\n'
fi
