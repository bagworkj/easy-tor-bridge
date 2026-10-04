#!/bin/bash
# Run as your regular user: ./install.sh
set -euo pipefail

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ $(uname -s) == Darwin ]] || fail 'This installer supports macOS only.'
[[ $EUID -ne 0 ]] || fail 'Run without sudo; setup requests administrator access when needed.'
PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$PROJECT_DIR"
[[ -f compose.yaml && -f .env.example ]] || fail 'Keep install.sh beside compose.yaml and .env.example.'

# Keep all commands on the dedicated local Colima engine.
unset DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
PROFILE=easy-tor-bridge
CONTEXT=colima-easy-tor-bridge
printf '\n[1/5] Install dependencies\n'
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
    rm -f "$brew_installer"
    trap - EXIT
    if [[ -x /opt/homebrew/bin/brew ]]; then
        BREW=/opt/homebrew/bin/brew
    else
        BREW=/usr/local/bin/brew
    fi
fi
BREW_PREFIX=$("$BREW" --prefix)
export PATH="$BREW_PREFIX/bin:$PATH"
for dependency in colima docker docker-compose; do
    if ! "$BREW" list --versions "$dependency" >/dev/null 2>&1; then
        "$BREW" install "$dependency"
    fi
done
DOCKER="$BREW_PREFIX/opt/docker/bin/docker"
# Invoke Homebrew's Compose directly; no edits to the user's Docker config.
COMPOSE="$BREW_PREFIX/opt/docker-compose/bin/docker-compose"
compose() { "$COMPOSE" --context "$CONTEXT" "$@"; }

printf '\n[2/5] Start Colima\n'
colima start "$PROFILE" --runtime docker --activate=false --network-host-addresses
ready=false
for ((attempt=0; attempt<60; attempt++)); do
    if "$DOCKER" --context "$CONTEXT" info >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 5
done
[[ $ready == true ]] || fail 'Colima engine did not become ready. Check colima status easy-tor-bridge.'
compose version >/dev/null || fail 'Docker Compose could not start.'

printf '\n[3/5] Configure bridge\n'
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
printf '\n[4/5] Start bridge container\n'
# Fetch on first install; rerunning setup does not implicitly upgrade the image.
compose up -d --pull missing obfs4-bridge

# Check only the current process lifetime, rechecking state to catch restarts.
wait_for_bootstrap() {
    local deadline container_id state logs confirmed_state
    deadline=$((SECONDS + 300))
    while (( SECONDS < deadline )); do
        container_id=$(compose ps -a -q obfs4-bridge) || return 2
        [[ -n "$container_id" ]] || return 2
        state=$("$DOCKER" --context "$CONTEXT" inspect \
            --format '{{.State.Status}}|{{.State.StartedAt}}' "$container_id") || return 2
        case "$state" in
            running\|*)
                logs=$("$DOCKER" --context "$CONTEXT" logs --since "${state#*|}" "$container_id" 2>&1) || return 2
                if [[ "$logs" == *'Bootstrapped 100% (done):'* ]]; then
                    confirmed_state=$("$DOCKER" --context "$CONTEXT" inspect \
                        --format '{{.State.Status}}|{{.State.StartedAt}}' "$container_id") || return 2
                    [[ "$state" != "$confirmed_state" ]] || return 0
                fi ;;
            restarting\|*|created\|*) ;;
            *) return 2 ;;
        esac
        sleep 5
    done
    return 1
}

printf '\n[5/5] Verify Tor bootstrap\n'
printf '  Waiting up to 5 minutes for Tor to connect...\n'
if wait_for_bootstrap; then
    printf '  Tor bootstrap complete.\n'
else
    result=$?
    if [[ $result -eq 1 ]]; then
        printf '  Bootstrap is still pending. The container has been left running.\n'
    else
        printf '  Could not verify bootstrap: the container stopped or Docker returned an error.\n'
    fi
    printf '  Inspect logs: docker-compose --context colima-easy-tor-bridge logs -f --tail=100\n'
    exit 1
fi
cat <<'SUMMARY'

Setup complete
  Tor bootstrap          Complete
  Internet reachability  Unverified

Watch logs:
  docker-compose --context colima-easy-tor-bridge logs -f --tail=100
Get your bridge line:
  docker-compose --context colima-easy-tor-bridge exec obfs4-bridge get-bridge-line

Keep your Mac awake. After a reboot, rerun ./install.sh to start Colima
and the bridge. Automatic Colima startup is not configured by this script.
Home routers may require forwarding both configured TCP ports.
SUMMARY
