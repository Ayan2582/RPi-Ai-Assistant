#!/usr/bin/env bash
# Launcher for Alan: starts Whisper (Docker), makes sure Ollama is up, then runs `python -m alan`.
# Used both interactively and by the systemd unit (alan.service).
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

# wait_for_url <name> <url> <timeout-seconds>
wait_for_url() {
    local name="$1" url="$2" timeout="$3" waited=0
    printf '%s[INFO]%s Waiting for %s at %s ' "$C_BLUE" "$C_RESET" "$name" "$url"
    until curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null; do
        if (( waited >= timeout )); then
            printf ' timed out\n'
            return 1
        fi
        printf '.'
        sleep 2
        waited=$((waited + 2))
    done
    printf ' ready\n'
}

# ---------------------------------------------------------------------------
# 1. Configuration
# ---------------------------------------------------------------------------
ENV_FILE="$REPO_DIR/config.env"
if [[ ! -f "$ENV_FILE" ]]; then
    warn "config.env not found; using config.example.env defaults (run ./scripts/install.sh to create config.env)"
    ENV_FILE="$REPO_DIR/config.example.env"
fi
[[ -f "$ENV_FILE" ]] || die "No configuration file found in $REPO_DIR"
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

WHISPER_URL="${WHISPER_URL:-http://localhost:8000/v1/audio/transcriptions}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
OLLAMA_URL="${OLLAMA_URL%/}"
LLM_MODEL="${LLM_MODEL:-qwen2.5:0.5b}"
PIPER_VOICE="${PIPER_VOICE:-en_GB-alan-medium}"

# ---------------------------------------------------------------------------
# 2. Sanity checks
# ---------------------------------------------------------------------------
PYTHON="$REPO_DIR/.venv/bin/python"
[[ -x "$PYTHON" ]] || die "Python venv not found at $REPO_DIR/.venv. Run ./scripts/install.sh first."
for f in "$REPO_DIR/models/$PIPER_VOICE.onnx" "$REPO_DIR/models/$PIPER_VOICE.onnx.json"; do
    [[ -s "$f" ]] || die "Piper voice file missing: $f. Run ./scripts/install.sh first."
done
command -v curl >/dev/null 2>&1 || die "curl is not installed. Run ./scripts/install.sh first."
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run ./scripts/install.sh first."

# ---------------------------------------------------------------------------
# 3. Whisper container
# ---------------------------------------------------------------------------
# Pick a docker invocation that works: plain docker (docker group), passwordless sudo,
# or interactive sudo when attached to a terminal. Retry briefly in case dockerd is still starting.
DOCKER=()
for _ in $(seq 1 15); do
    if docker info >/dev/null 2>&1; then
        DOCKER=(docker); break
    elif sudo -n docker info >/dev/null 2>&1; then
        DOCKER=(sudo -n docker); break
    fi
    sleep 2
done
if [[ ${#DOCKER[@]} -eq 0 ]]; then
    if [[ -t 0 ]] && sudo docker info >/dev/null; then
        DOCKER=(sudo docker)
    else
        die "Cannot talk to the Docker daemon. Is docker running (sudo systemctl start docker) and is $(id -un) in the docker group (log out/in after install)?"
    fi
fi

info "Starting Whisper container"
"${DOCKER[@]}" compose --env-file "$ENV_FILE" -f "$REPO_DIR/docker-compose.yml" up -d whisper

# ---------------------------------------------------------------------------
# 4. Ollama service
# ---------------------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl is-active --quiet ollama; then
        info "Ollama service is not active; trying to start it"
        if ! sudo -n systemctl start ollama 2>/dev/null; then
            warn "Could not start ollama.service without a password. Start it with: sudo systemctl start ollama"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 5. Wait for services
# ---------------------------------------------------------------------------
WHISPER_SCHEME="${WHISPER_URL%%://*}"
WHISPER_REST="${WHISPER_URL#*://}"
WHISPER_HOSTPORT="${WHISPER_REST%%/*}"
WHISPER_HEALTH="$WHISPER_SCHEME://$WHISPER_HOSTPORT/health"

if ! wait_for_url "Whisper" "$WHISPER_HEALTH" 120; then
    die "Whisper did not become healthy within 120s. Check: docker logs alan-whisper"
fi
if ! wait_for_url "Ollama" "$OLLAMA_URL/api/tags" 60; then
    die "Ollama did not respond within 60s. Check: journalctl -u ollama   (or: sudo systemctl start ollama)"
fi

# ---------------------------------------------------------------------------
# 6. LLM model
# ---------------------------------------------------------------------------
if command -v ollama >/dev/null 2>&1; then
    MODELS="$(OLLAMA_HOST="$OLLAMA_URL" ollama list 2>/dev/null | awk 'NR > 1 { print $1 }' || true)"
    WANT="$LLM_MODEL"
    [[ "$WANT" == *:* ]] || WANT="$WANT:latest"
    if ! grep -Fxq -e "$LLM_MODEL" -e "$WANT" <<<"$MODELS"; then
        info "LLM model '$LLM_MODEL' not found in Ollama; pulling it"
        OLLAMA_HOST="$OLLAMA_URL" ollama pull "$LLM_MODEL" || die "Failed to pull '$LLM_MODEL'. Check: journalctl -u ollama"
    else
        ok "LLM model '$LLM_MODEL' is available"
    fi
else
    warn "ollama CLI not found; cannot verify that '$LLM_MODEL' is pulled"
fi

# ---------------------------------------------------------------------------
# 7. Run Alan
# ---------------------------------------------------------------------------
ok "All services ready; starting Alan"
cd "$REPO_DIR"
exec "$PYTHON" -m alan "$@"
