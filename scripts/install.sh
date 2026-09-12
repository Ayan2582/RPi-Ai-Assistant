#!/usr/bin/env bash
# One-shot, idempotent installer for Alan on a Raspberry Pi 5 (Raspberry Pi OS Bookworm 64-bit).
# Run as your normal user; sudo is used where needed.
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
step()  { printf '\n%s==> %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Installs everything Alan needs: apt packages, Docker (for the Whisper server),
Ollama (native), the Python venv, the Piper voice and the Whisper image.
Safe to re-run.

Options:
  --service       Also install and enable the systemd unit (autostart on boot, tty1)
  --skip-docker   Do not install Docker or pull the Whisper image
  --skip-ollama   Do not install Ollama or pull the LLM model
  -h, --help      Show this help and exit
EOF
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
INSTALL_SERVICE=0
SKIP_DOCKER=0
SKIP_OLLAMA=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --service)     INSTALL_SERVICE=1 ;;
        --skip-docker) SKIP_DOCKER=1 ;;
        --skip-ollama) SKIP_OLLAMA=1 ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage >&2; die "Unknown option: $1" ;;
    esac
    shift
done

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    die "Do not run this script as root or with sudo. Run it as your normal user: ./scripts/install.sh"
fi
command -v sudo >/dev/null 2>&1 || die "sudo is required but not installed."

USER="${USER:-$(id -un)}"
USER_UID="$(id -u)"
NEEDS_RELOGIN=0

# wait_for_url <name> <url> <timeout-seconds>
wait_for_url() {
    local name="$1" url="$2" timeout="$3" waited=0
    printf '%s[INFO]%s Waiting for %s at %s ' "$C_BLUE" "$C_RESET" "$name" "$url"
    until curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null; do
        if (( waited >= timeout )); then
            printf '\n'
            return 1
        fi
        printf '.'
        sleep 2
        waited=$((waited + 2))
    done
    printf ' ready\n'
}

# ---------------------------------------------------------------------------
# 1. Platform check
# ---------------------------------------------------------------------------
step "Checking platform"
ARCH="$(uname -m)"
if [[ "$ARCH" != "aarch64" ]]; then
    warn "Architecture is '$ARCH', not aarch64. Alan targets 64-bit Raspberry Pi OS; continuing anyway."
fi
MODEL=""
if [[ -r /proc/device-tree/model ]]; then
    MODEL="$(tr -d '\0' </proc/device-tree/model)"
fi
if [[ "$MODEL" != *"Raspberry Pi"* ]]; then
    warn "This does not look like a Raspberry Pi (model: '${MODEL:-unknown}'); continuing anyway."
else
    ok "Detected: $MODEL ($ARCH)"
fi

info "sudo may ask for your password."
sudo -v

# ---------------------------------------------------------------------------
# 2. apt packages
# ---------------------------------------------------------------------------
step "Installing apt packages"
APT_PACKAGES=(
    python3-venv python3-pip python3-dev
    alsa-utils pipewire-bin
    curl git
    libsdl2-2.0-0 libsdl2-ttf-2.0-0 libsdl2-image-2.0-0 libsdl2-mixer-2.0-0
    libportaudio2
)
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PACKAGES[@]}"
ok "apt packages installed"

# ---------------------------------------------------------------------------
# 5. Config (done before Docker/Ollama because later steps need LLM_MODEL / PIPER_VOICE)
# ---------------------------------------------------------------------------
step "Preparing configuration"
ENV_FILE="$REPO_DIR/config.env"
if [[ ! -f "$ENV_FILE" ]]; then
    cp "$REPO_DIR/config.example.env" "$ENV_FILE"
    ok "Created config.env from config.example.env"
else
    ok "config.env already exists (left untouched)"
fi
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a
LLM_MODEL="${LLM_MODEL:-qwen2.5:0.5b}"
PIPER_VOICE="${PIPER_VOICE:-en_GB-alan-medium}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"

# ---------------------------------------------------------------------------
# 3. Docker
# ---------------------------------------------------------------------------
add_user_to_group() {
    local group="$1"
    if ! getent group "$group" >/dev/null 2>&1; then
        warn "Group '$group' does not exist; skipping."
        return 0
    fi
    local db_groups session_groups
    db_groups=" $(id -nG "$USER") "
    session_groups=" $(id -nG) "
    if [[ "$db_groups" != *" $group "* ]]; then
        sudo usermod -aG "$group" "$USER"
        ok "Added $USER to group '$group'"
        NEEDS_RELOGIN=1
    elif [[ "$session_groups" != *" $group "* ]]; then
        # Member in /etc/group but not in this login session yet.
        NEEDS_RELOGIN=1
    fi
}

if [[ "$SKIP_DOCKER" -eq 0 ]]; then
    step "Setting up Docker"
    if ! command -v docker >/dev/null 2>&1; then
        info "Docker not found; installing via get.docker.com"
        curl -fsSL https://get.docker.com | sh
    else
        ok "Docker already installed: $(docker --version)"
    fi
    sudo systemctl enable --now docker >/dev/null 2>&1 || warn "Could not enable/start docker.service"
    if ! docker compose version >/dev/null 2>&1; then
        info "Docker Compose plugin missing; installing docker-compose-plugin"
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin \
            || die "Could not install docker-compose-plugin. Install Docker Compose v2 manually."
    fi
    docker compose version >/dev/null 2>&1 || die "'docker compose' does not work after installation."
    ok "$(docker compose version)"
    add_user_to_group docker
else
    warn "Skipping Docker setup (--skip-docker)"
fi

step "Adding $USER to audio and video groups"
add_user_to_group audio
add_user_to_group video

# ---------------------------------------------------------------------------
# 4. Ollama
# ---------------------------------------------------------------------------
if [[ "$SKIP_OLLAMA" -eq 0 ]]; then
    step "Setting up Ollama"
    if ! command -v ollama >/dev/null 2>&1; then
        info "Ollama not found; installing via ollama.com/install.sh"
        curl -fsSL https://ollama.com/install.sh | sh
    else
        ok "Ollama already installed"
    fi
    sudo systemctl enable --now ollama
    if ! wait_for_url "Ollama" "$OLLAMA_URL/api/tags" 60; then
        die "Ollama did not respond at $OLLAMA_URL. Check: journalctl -u ollama"
    fi
    info "Pulling LLM model '$LLM_MODEL' (this can take a while)"
    OLLAMA_HOST="$OLLAMA_URL" ollama pull "$LLM_MODEL"
    ok "LLM model '$LLM_MODEL' is available"
else
    warn "Skipping Ollama setup (--skip-ollama)"
fi

# ---------------------------------------------------------------------------
# 6. Python venv
# ---------------------------------------------------------------------------
step "Setting up the Python virtual environment"
VENV_DIR="$REPO_DIR/.venv"
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    python3 -m venv "$VENV_DIR"
    ok "Created $VENV_DIR"
else
    ok "Virtual environment already exists"
fi
"$VENV_DIR/bin/python" -m pip install --upgrade pip wheel
"$VENV_DIR/bin/python" -m pip install -r "$REPO_DIR/requirements.txt"
ok "Python dependencies installed"

# ---------------------------------------------------------------------------
# 7. Piper voice
# ---------------------------------------------------------------------------
step "Downloading Piper voice '$PIPER_VOICE'"
MODELS_DIR="$REPO_DIR/models"
mkdir -p "$MODELS_DIR"

# en_GB-alan-medium -> locale en_GB, name alan, quality medium, family en
if [[ "$PIPER_VOICE" != *-*-* ]]; then
    die "PIPER_VOICE '$PIPER_VOICE' is not of the form <locale>-<name>-<quality> (e.g. en_GB-alan-medium)"
fi
VOICE_LOCALE="${PIPER_VOICE%%-*}"
VOICE_QUALITY="${PIPER_VOICE##*-}"
VOICE_REST="${PIPER_VOICE#*-}"
VOICE_NAME="${VOICE_REST%-*}"
VOICE_FAMILY="${VOICE_LOCALE%%_*}"
VOICE_BASE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/$VOICE_FAMILY/$VOICE_LOCALE/$VOICE_NAME/$VOICE_QUALITY"

download() {
    local url="$1" dest="$2" tmp
    if [[ -s "$dest" ]]; then
        ok "$(basename "$dest") already present"
        return 0
    fi
    tmp="$(mktemp "$dest.part.XXXXXX")"
    info "Downloading $url"
    if ! curl -fL --retry 3 --progress-bar -o "$tmp" "$url"; then
        rm -f "$tmp"
        die "Download failed: $url"
    fi
    mv -f "$tmp" "$dest"
    ok "Saved $dest"
}
download "$VOICE_BASE_URL/$PIPER_VOICE.onnx"      "$MODELS_DIR/$PIPER_VOICE.onnx"
download "$VOICE_BASE_URL/$PIPER_VOICE.onnx.json" "$MODELS_DIR/$PIPER_VOICE.onnx.json"

# ---------------------------------------------------------------------------
# 8. Whisper image
# ---------------------------------------------------------------------------
if [[ "$SKIP_DOCKER" -eq 0 ]]; then
    step "Pulling the Whisper image"
    if docker info >/dev/null 2>&1; then
        DOCKER=(docker)
    else
        info "Your shell is not in the docker group yet; using sudo docker"
        DOCKER=(sudo docker)
    fi
    "${DOCKER[@]}" compose --env-file "$ENV_FILE" -f "$REPO_DIR/docker-compose.yml" pull
    ok "Whisper image pulled"
fi

# ---------------------------------------------------------------------------
# 9. Permissions
# ---------------------------------------------------------------------------
chmod +x "$SCRIPT_DIR"/*.sh

# ---------------------------------------------------------------------------
# 10. systemd service (optional)
# ---------------------------------------------------------------------------
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

if [[ "$INSTALL_SERVICE" -eq 1 ]]; then
    step "Installing the systemd service"
    UNIT_DEST="/etc/systemd/system/alan.service"
    sed -e "s|__USER__|$(sed_escape "$USER")|g" \
        -e "s|__REPO_DIR__|$(sed_escape "$REPO_DIR")|g" \
        -e "s|__UID__|$USER_UID|g" \
        "$SCRIPT_DIR/alan.service" | sudo tee "$UNIT_DEST" >/dev/null
    ok "Wrote $UNIT_DEST"
    sudo loginctl enable-linger "$USER"
    ok "Enabled lingering for $USER (keeps PipeWire available without a login)"
    sudo systemctl daemon-reload
    sudo systemctl enable alan.service
    ok "alan.service enabled (starts on boot on tty1)"
fi

# ---------------------------------------------------------------------------
# 11. Summary
# ---------------------------------------------------------------------------
step "Installation complete"
OLLAMA_NOTE=""
DOCKER_NOTE=""
[[ "$SKIP_OLLAMA" -eq 1 ]] && OLLAMA_NOTE=" (Ollama skipped)"
[[ "$SKIP_DOCKER" -eq 1 ]] && DOCKER_NOTE=" (Docker skipped)"
cat <<EOF
  Repo:        $REPO_DIR
  Config:      $ENV_FILE
  LLM model:   $LLM_MODEL$OLLAMA_NOTE
  Piper voice: $MODELS_DIR/$PIPER_VOICE.onnx
  Whisper:     ${WHISPER_IMAGE:-fedirz/faster-whisper-server:latest-cpu}$DOCKER_NOTE
  Service:     $([[ "$INSTALL_SERVICE" -eq 1 ]] && printf 'installed' || printf 'not installed')
EOF

printf '\nNext steps:\n'
n=1
if [[ "$NEEDS_RELOGIN" -eq 1 ]]; then
    printf '  %d. Your group membership changed. Log out and back in, or reboot: sudo reboot\n' "$n"; n=$((n + 1))
fi
printf '  %d. Review settings in config.env (e.g. AUDIO_INPUT, LLM_MODEL).\n' "$n"; n=$((n + 1))
if [[ "$INSTALL_SERVICE" -eq 1 ]]; then
    printf '  %d. Start the service now: sudo systemctl start alan   (or just reboot)\n' "$n"; n=$((n + 1))
    printf '  %d. Follow the logs:       journalctl -u alan -f\n' "$n"; n=$((n + 1))
    printf '  %d. Press ENTER on the keyboard attached to the Pi to talk to Alan.\n' "$n"; n=$((n + 1))
else
    printf '  %d. Start Alan: ./scripts/start.sh   then press ENTER to talk.\n' "$n"; n=$((n + 1))
    printf '  %d. Optional autostart on boot: ./scripts/install.sh --service\n' "$n"; n=$((n + 1))
fi

printf '\n'
warn "The 3.5\" SPI LCD needs a dtoverlay in /boot/firmware/config.txt."
warn "This script does not edit config.txt; see the README section on connecting the LCD."
