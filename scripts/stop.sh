#!/usr/bin/env bash
# Stops Alan: the systemd service (if active), any running `python -m alan` for this repo,
# and the Whisper container. Ollama keeps running unless --all is given.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
else
    C_RESET=""; C_BLUE=""; C_YELLOW=""; C_RED=""; C_GREEN=""
fi
info()  { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[ERR ]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()   { error "$*"; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Stops the alan systemd service, any running Alan process from this repo,
and the Whisper container. Ollama is left running by default.

Options:
  --all        Also stop the Ollama service
  -h, --help   Show this help and exit
EOF
}

STOP_OLLAMA=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)     STOP_OLLAMA=1 ;;
        -h|--help) usage; exit 0 ;;
        *)         usage >&2; die "Unknown option: $1" ;;
    esac
    shift
done

HAVE_SYSTEMCTL=0
command -v systemctl >/dev/null 2>&1 && HAVE_SYSTEMCTL=1

# ---------------------------------------------------------------------------
# 1. systemd service
# ---------------------------------------------------------------------------
if [[ "$HAVE_SYSTEMCTL" -eq 1 ]] && systemctl is-active --quiet alan.service; then
    info "Stopping alan.service"
    sudo systemctl stop alan.service
    ok "alan.service stopped"
fi

# ---------------------------------------------------------------------------
# 2. Stray `python -m alan` processes from this repo
# ---------------------------------------------------------------------------
regex_escape() { printf '%s' "$1" | sed -e 's/[][\\.*^$+?(){}|]/\\&/g'; }
PATTERN="$(regex_escape "$REPO_DIR/.venv/bin/python") -m alan"

if pgrep -f "$PATTERN" >/dev/null 2>&1; then
    info "Stopping running Alan process(es)"
    pkill -TERM -f "$PATTERN" || true
    for _ in $(seq 1 10); do
        pgrep -f "$PATTERN" >/dev/null 2>&1 || break
        sleep 0.5
    done
    if pgrep -f "$PATTERN" >/dev/null 2>&1; then
        warn "Alan did not exit after SIGTERM; sending SIGKILL"
        pkill -KILL -f "$PATTERN" || true
    fi
    ok "Alan process stopped"
fi

# ---------------------------------------------------------------------------
# 3. Whisper container
# ---------------------------------------------------------------------------
ENV_FILE="$REPO_DIR/config.env"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$REPO_DIR/config.example.env"

if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
        DOCKER=(docker)
    else
        DOCKER=(sudo docker)
    fi
    info "Stopping Whisper container"
    "${DOCKER[@]}" compose --env-file "$ENV_FILE" -f "$REPO_DIR/docker-compose.yml" down
    ok "Whisper container stopped"
else
    warn "docker not found; skipping Whisper container"
fi

# ---------------------------------------------------------------------------
# 4. Ollama (only with --all)
# ---------------------------------------------------------------------------
if [[ "$STOP_OLLAMA" -eq 1 ]]; then
    if [[ "$HAVE_SYSTEMCTL" -eq 1 ]] && systemctl is-active --quiet ollama; then
        info "Stopping ollama.service"
        sudo systemctl stop ollama
        ok "Ollama stopped"
    else
        info "Ollama is not running"
    fi
else
    info "Ollama left running (use --all to stop it too)"
fi
