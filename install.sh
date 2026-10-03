# Run as your regular user: ./install.sh
set -euo pipefail

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ $(uname -s) == Darwin ]] || fail 'This installer supports macOS only.'
[[ $EUID -ne 0 ]] || fail 'Run without sudo; setup requests administrator access when needed.'
PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$PROJECT_DIR"
[[ -f compose.yaml && -f .env.example ]] || fail 'Keep install.sh beside compose.yaml and .env.example.'

unset DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
DOCKER_APP=/Applications/Docker.app
if [[ ! -d "$DOCKER_APP" && -d "$HOME/Applications/Docker.app" ]]; then
    DOCKER_APP="$HOME/Applications/Docker.app"
fi
INSTALL_TMP=''
cleanup() {
    if [[ -n "$INSTALL_TMP" ]]; then
        if mount | /usr/bin/grep -Fq " on $INSTALL_TMP/mount "; then
            hdiutil detach "$INSTALL_TMP/mount" -quiet || return
        fi
        rm -rf -- "$INSTALL_TMP"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ! -d "$DOCKER_APP" ]]; then
    case $(uname -m) in
        arm64) ARCH=arm64 ;;
        x86_64)
            if [[ $(sysctl -in sysctl.proc_translated 2>/dev/null || true) == 1 ]]; then
                ARCH=arm64
            else
                ARCH=amd64
            fi ;;
        *) fail 'Unsupported Mac architecture.' ;;
    esac
    printf 'Downloading Docker Desktop (%s)...\n' "$ARCH"
    INSTALL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/easy-tor-bridge.XXXXXX")
    curl --fail --location --retry 3 --connect-timeout 30 \
        --proto '=https' --proto-redir '=https' \
        "https://desktop.docker.com/mac/main/$ARCH/Docker.dmg" \
        --output "$INSTALL_TMP/Docker.dmg"
    mkdir "$INSTALL_TMP/mount"
    hdiutil attach "$INSTALL_TMP/Docker.dmg" -nobrowse -readonly \
        -mountpoint "$INSTALL_TMP/mount" -quiet
    # Verify the mounted app before executing its privileged installer.
    codesign --verify --deep --strict "$INSTALL_TMP/mount/Docker.app"
    codesign --verify -R 'anchor apple generic and certificate leaf[subject.OU] = "9BNSXJN65R"' \
        "$INSTALL_TMP/mount/Docker.app"
    printf 'Installing Docker Desktop; macOS may request your password.\n'
    sudo "$INSTALL_TMP/mount/Docker.app/Contents/MacOS/install"
    cleanup
    INSTALL_TMP=''
fi

DOCKER="$DOCKER_APP/Contents/Resources/bin/docker"
[[ -x "$DOCKER" ]] || fail 'Docker Desktop is incomplete. Reinstall it and rerun setup.'
export PATH="$DOCKER_APP/Contents/Resources/bin:$PATH"
open "$DOCKER_APP"
printf 'Waiting for Docker Desktop. Complete any first-run prompts in Docker.\n'
# Explicit context avoids accidentally deploying to a remote engine.
ready=false
for ((attempt=0; attempt<120; attempt++)); do
    if "$DOCKER" --context desktop-linux info >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 5
done
[[ $ready == true ]] || fail 'Docker was not ready within 10 minutes. Finish Docker setup and rerun ./install.sh.'
"$DOCKER" --context desktop-linux compose version >/dev/null || fail 'Docker Compose is missing. Repair Docker Desktop.'

umask 077
if [[ ! -e .env ]]; then
    cp .env.example .env
    printf 'Created .env from .env.example.\n'
fi

if ! "$DOCKER" --context desktop-linux compose config --quiet; then
    fail 'Edit .env (including EMAIL), then rerun ./install.sh. Existing settings were preserved.'
fi
printf 'Pulling Tor and its transport, then starting the bridge...\n'
"$DOCKER" --context desktop-linux compose pull obfs4-bridge
"$DOCKER" --context desktop-linux compose up -d obfs4-bridge
printf '\nContainer started. Tor bootstrap and Internet reachability are not yet verified.\n'
printf 'View logs: docker --context desktop-linux compose logs -f --tail=100\n'
printf 'Bridge line: docker --context desktop-linux compose exec obfs4-bridge get-bridge-line\n'
printf 'Keep your Mac awake and Docker running. Enable Docker startup at login in Docker settings.\n'
printf 'Home networks may require forwarding both configured TCP ports.\n'
