#!/usr/bin/env bash
# ============================================================
# NRB PANEL - ZERO-APT DOCKER / CODESPACES INSTALLER
# Repository: https://github.com/notroboy67-htp/Panel
#
# IMPORTANT:
#   This installer NEVER runs apt, apt-get, dpkg, or installs Git.
#   This avoids Docker/Codespaces "Invalid cross-device link"
#   package errors.
# ============================================================

set -Eeuo pipefail

REPO_ZIP_URL="https://github.com/notroboy67-htp/Panel/archive/refs/heads/main.zip"
BASE_DIR="${HOME}/nrb-panel"
REPO_ZIP="${BASE_DIR}/repository.zip"
REPO_EXTRACT="${BASE_DIR}/repository"
PANEL_EXTRACT="${BASE_DIR}/panel"
NODE_DIR="${BASE_DIR}/node"
PANEL_PORT="${PANEL_PORT:-3000}"
NODE_VERSION="${NODE_VERSION:-20.19.4}"

log()  { printf '\033[1;32m[NRB]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

has() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------
# We intentionally do not use apt/dpkg.
# ------------------------------------------------------------

log "Starting ZERO-APT Docker/Codespaces installer..."

if ! has curl && ! has wget; then
    die "curl or wget is required to download the Panel repository."
fi

if ! has python3; then
    die "python3 is required for ZIP extraction.
This installer intentionally does not install Python with apt,
because your container has a broken dpkg/filesystem setup."
fi

has tar || die "tar is required."
has xz || die "xz is required for the Node.js archive."

# ------------------------------------------------------------
# Prepare directories
# ------------------------------------------------------------

rm -rf "${BASE_DIR}"
mkdir -p "${BASE_DIR}" "${REPO_EXTRACT}" "${PANEL_EXTRACT}"

# ------------------------------------------------------------
# Download repository directly from GitHub.
# This completely avoids Git and apt/dpkg.
# ------------------------------------------------------------

log "Downloading Panel repository from GitHub..."

if has curl; then
    curl -fL --retry 5 --connect-timeout 15 \
        "${REPO_ZIP_URL}" -o "${REPO_ZIP}" \
        || die "Failed to download the Panel repository."
else
    wget -q --show-progress \
        "${REPO_ZIP_URL}" -O "${REPO_ZIP}" \
        || die "Failed to download the Panel repository."
fi

[ -s "${REPO_ZIP}" ] || die "Downloaded repository archive is empty."

# ------------------------------------------------------------
# Extract repository ZIP using Python stdlib.
# ------------------------------------------------------------

log "Extracting repository..."

python3 - "${REPO_ZIP}" "${REPO_EXTRACT}" <<'PY'
import sys
import zipfile
from pathlib import Path

archive = Path(sys.argv[1])
destination = Path(sys.argv[2])
destination.mkdir(parents=True, exist_ok=True)

with zipfile.ZipFile(archive, "r") as z:
    bad = z.testzip()
    if bad:
        raise SystemExit(f"Corrupt ZIP entry: {bad}")
    z.extractall(destination)
PY

REPO_ROOT="$(find "${REPO_EXTRACT}" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[ -n "${REPO_ROOT}" ] || die "Could not locate extracted repository."

# ------------------------------------------------------------
# Find mcpanelv1.zip.
# ------------------------------------------------------------

ZIP_FILE="$(find "${REPO_ROOT}" -maxdepth 3 -type f \
    \( -iname 'mcpanelv1.zip' -o -iname '*.zip' \) \
    -print -quit || true)"

[ -n "${ZIP_FILE}" ] || die "mcpanelv1.zip was not found in the GitHub repository."

log "Found: ${ZIP_FILE}"

# ------------------------------------------------------------
# Extract mcpanelv1.zip.
# ------------------------------------------------------------

log "Extracting mcpanelv1.zip..."

python3 - "${ZIP_FILE}" "${PANEL_EXTRACT}" <<'PY'
import sys
import zipfile
from pathlib import Path

archive = Path(sys.argv[1])
destination = Path(sys.argv[2])
destination.mkdir(parents=True, exist_ok=True)

with zipfile.ZipFile(archive, "r") as z:
    bad = z.testzip()
    if bad:
        raise SystemExit(f"Corrupt ZIP entry: {bad}")
    z.extractall(destination)
PY

# ------------------------------------------------------------
# Locate actual Node.js panel directory.
# ------------------------------------------------------------

PACKAGE_JSON="$(find "${PANEL_EXTRACT}" -type f -name package.json -print -quit || true)"
[ -n "${PACKAGE_JSON}" ] || die "package.json was not found inside mcpanelv1.zip."

PANEL_DIR="$(dirname "${PACKAGE_JSON}")"
cd "${PANEL_DIR}"

log "Panel directory: ${PANEL_DIR}"

# ------------------------------------------------------------
# Install Node.js WITHOUT apt/dpkg if necessary.
# ------------------------------------------------------------

if has node && has npm; then
    log "Existing Node.js: $(node --version)"
    log "Existing npm: $(npm --version)"
else
    log "Node.js/npm not found."
    log "Downloading official Node.js ${NODE_VERSION} binary..."

    ARCH="$(uname -m)"
    case "${ARCH}" in
        x86_64|amd64) NODE_ARCH="x64" ;;
        aarch64|arm64) NODE_ARCH="arm64" ;;
        armv7l|armv7) NODE_ARCH="armv7l" ;;
        *) die "Unsupported CPU architecture: ${ARCH}" ;;
    esac

    NODE_FILE="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
    NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_FILE}"

    rm -rf "${NODE_DIR}"
    mkdir -p "${NODE_DIR}"

    if has curl; then
        curl -fL --retry 5 --connect-timeout 15 \
            "${NODE_URL}" -o "${BASE_DIR}/${NODE_FILE}" \
            || die "Failed to download Node.js."
    else
        wget -q --show-progress \
            "${NODE_URL}" -O "${BASE_DIR}/${NODE_FILE}" \
            || die "Failed to download Node.js."
    fi

    tar -xJf "${BASE_DIR}/${NODE_FILE}" -C "${NODE_DIR}" \
        || die "Failed to extract Node.js."

    NODE_ROOT="$(find "${NODE_DIR}" -mindepth 1 -maxdepth 1 -type d -name 'node-v*' -print -quit)"
    [ -n "${NODE_ROOT}" ] || die "Node.js extraction directory not found."

    export PATH="${NODE_ROOT}/bin:${PATH}"

    rm -f "${BASE_DIR}/${NODE_FILE}"

    has node || die "Node.js installation failed."
    has npm || die "npm installation failed."

    log "Node.js installed: $(node --version)"
    log "npm installed: $(npm --version)"
fi

# ------------------------------------------------------------
# Install panel dependencies.
# ------------------------------------------------------------

log "Installing npm dependencies..."

if [ -f package-lock.json ]; then
    npm ci --omit=dev || {
        warn "npm ci failed; retrying with npm install..."
        npm install --omit=dev
    }
else
    npm install --omit=dev
fi

npm rebuild >/dev/null 2>&1 || \
    warn "npm rebuild returned an error; continuing."

# ------------------------------------------------------------
# Determine how the panel starts.
# ------------------------------------------------------------

START_SCRIPT="$(node -e '
try {
  const p=require("./package.json");
  process.stdout.write((p.scripts && p.scripts.start) || "");
} catch(e) {}
' 2>/dev/null || true)"

START_MODE=""
ENTRY_FILE=""

if [ -n "${START_SCRIPT}" ]; then
    START_MODE="npm"
else
    for candidate in app.js server.js index.js main.js; do
        if [ -f "${candidate}" ]; then
            ENTRY_FILE="${candidate}"
            break
        fi
    done

    if [ -z "${ENTRY_FILE}" ]; then
        PACKAGE_MAIN="$(node -e '
try {
  const p=require("./package.json");
  process.stdout.write(p.main || "");
} catch(e) {}
' 2>/dev/null || true)"

        if [ -n "${PACKAGE_MAIN}" ] && [ -f "${PACKAGE_MAIN}" ]; then
            ENTRY_FILE="${PACKAGE_MAIN}"
        fi
    fi

    [ -n "${ENTRY_FILE}" ] && START_MODE="node"
fi

[ -n "${START_MODE}" ] || \
    die "Could not determine the panel startup command."

export NODE_ENV="${NODE_ENV:-production}"
export PORT="${PANEL_PORT}"

mkdir -p servers backups uploads temp 2>/dev/null || true

# ------------------------------------------------------------
# Final message
# ------------------------------------------------------------

echo
echo "============================================================"
echo "       NRB PANEL - INSTALLATION COMPLETE"
echo "============================================================"
echo
echo "Repository : notroboy67-htp/Panel"
echo "Panel      : ${PANEL_DIR}"
echo "Port       : ${PANEL_PORT}"
echo "Node       : $(node --version)"
echo "npm        : $(npm --version)"
echo

if [ "${START_MODE}" = "npm" ]; then
    echo "Starting with: npm start"
else
    echo "Starting with: node ${ENTRY_FILE}"
fi

echo
echo "Docker: publish/expose port ${PANEL_PORT}."
echo "Codespaces: forward port ${PANEL_PORT}."
echo
echo "============================================================"
echo

# Keep the Node process in the foreground for Docker/Codespaces.
if [ "${START_MODE}" = "npm" ]; then
    exec npm start
else
    exec node "${ENTRY_FILE}"
fi
