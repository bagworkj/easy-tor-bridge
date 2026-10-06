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
[[ -f compose.yaml && -f .env.example && -f scripts/bridge-runtime.sh && -f scripts/network-check.sh && -f bridge ]] || fail 'Run install.sh from a complete copy of this project.'
[[ -x /usr/bin/perl ]] || fail 'The macOS Perl runtime is required for bounded health checks.'
source "$PROJECT_DIR/scripts/bridge-runtime.sh"
BOOTSTRAP_CACHE="$HOME/Library/Application Support/easy-tor-bridge/bootstrap"

# Keep all commands on the dedicated local Colima engine.
unset DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
PROFILE=easy-tor-bridge
CONTEXT=colima-easy-tor-bridge
heading '[1/6] Install dependencies'
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


heading '[2/6] Start Colima'
start_engine
"$COMPOSE" version >/dev/null || fail 'Docker Compose could not start.'

heading '[3/6] Configure bridge'
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
heading '[4/6] Start bridge container'
if run_bounded 30 /bin/bash "$PROJECT_DIR/scripts/network-check.sh" pre \
    "$DOCKER" "$COMPOSE" "$PROJECT_DIR" "$CONTEXT" "$GREEN" "$AMBER" "$RESET"; then
    :
else
    preflight_result=$?
    [[ $preflight_result -ne 2 ]] || fail 'Check the port configuration above before starting the bridge.'
    warning 'Port preflight found a conflict or could not finish; container startup will confirm availability.'
fi
# Fetch on first install; rerunning setup does not implicitly upgrade the image.
if ! compose up -d --pull missing obfs4-bridge; then
    warning 'Container startup failed. Gathering local network observations...'
    run_bounded 90 /bin/bash "$PROJECT_DIR/scripts/network-check.sh" post \
        "$DOCKER" "$COMPOSE" "$PROJECT_DIR" "$CONTEXT" "$GREEN" "$AMBER" "$RESET" || true
    fail 'Could not start the bridge. Review the Compose error and network observations above.'
fi

heading '[5/6] Verify Tor bootstrap'
BOOTSTRAP_VERIFIED=false
if run_bounded 300 /bin/bash "$PROJECT_DIR/scripts/bridge-runtime.sh" \
    "$DOCKER" "$COMPOSE" "$PROJECT_DIR" "$CONTEXT" "$BOOTSTRAP_CACHE" "$GREEN" "$RESET"; then
    BOOTSTRAP_VERIFIED=true
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
fi

heading '[6/6] Local network diagnostics'
if run_bounded 90 /bin/bash "$PROJECT_DIR/scripts/network-check.sh" post \
    "$DOCKER" "$COMPOSE" "$PROJECT_DIR" "$CONTEXT" "$GREEN" "$AMBER" "$RESET"; then
    LOCAL_NETWORK_STATUS='TCP checks passed; firewall observations above'
else
    LOCAL_NETWORK_STATUS='Warnings or incomplete checks; see above'
fi
[[ $BOOTSTRAP_VERIFIED == true ]] || fail 'Setup incomplete: Tor bootstrap was not confirmed. Local diagnostics are shown above.'

# A per-user LaunchAgent starts only this project's Colima profile at login.
# Container restart policies bring the bridge back when its engine starts.
configure_autostart() {
    local answer
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
                set_autostart off
                return ;;
            *) printf '  Please enter y or n: ' ;;
        esac
    done
    set_autostart on
}
configure_autostart
install_bridge_command

show_bridge_status() {
    local cid='' line='' fingerprint='' url answer=''
    cid=$(run_bounded 10 "$DOCKER" --context "$CONTEXT" ps -q \
        --filter label=com.docker.compose.project=easy-tor-bridge \
        --filter label=com.docker.compose.service=obfs4-bridge 2>/dev/null) || cid=''
    if [[ -n "$cid" ]]; then
        line=$(run_bounded 10 "$DOCKER" --context "$CONTEXT" exec "$cid" get-bridge-line 2>/dev/null) || line=''
    fi
    fingerprint=$(printf '%s\n' "$line" | awk '$1 == "obfs4" && length($3) == 40 && $3 !~ /[^0-9A-Fa-f]/ {print toupper($3); exit}')
    if [[ -z "$fingerprint" ]]; then
        warning 'Bridge status link unavailable — Could not retrieve a valid bridge fingerprint; rerun setup later.'
        return 0
    fi
    url="https://bridges.torproject.org/status?id=$fingerprint"
    printf '\nTor bridge status:\n  %s\n' "$url"
    printf '  Status information may lag; opening this page does not verify current Internet reachability.\n'
    if [[ -t 0 ]]; then
        printf '  Open status page in your browser? [y/N]: '
        IFS= read -r answer || answer=''
        case "$answer" in
            y|Y|yes|YES) open "$url" || warning 'Could not open the browser; use the link above.' ;;
        esac
    fi
    return 0
}

heading 'Setup Complete'
success 'Tor bootstrap — Complete'
printf '  Local networking — %s\n' "$LOCAL_NETWORK_STATUS"
warning 'Internet reachability — Unverified'
printf '  Automatic startup — %s\n' "$AUTOSTART_STATUS"
show_bridge_status
printf '\nKeep your Mac awake. Home routers may require forwarding both TCP ports.\n'
if [[ "$AUTOSTART_STATUS" != 'Enabled at login' ]]; then
    printf 'Run bridge up (or ./bridge from this repository) to start the bridge.\n'
fi
