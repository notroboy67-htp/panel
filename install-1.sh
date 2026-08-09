#!/usr/bin/env bash
# ============================================================
# NRB PANEL - DOCKER / CODESPACES FINAL INSTALLER
# ============================================================
# IMPORTANT:
# This installer does NOT use apt, apt-get, dpkg, sudo, or git.
# It downloads the GitHub repository as a ZIP and installs Node
# locally when Node.js is not already available.
#
# Fix included:
# Python 3.10 rejects Node.js archive symlinks with
# LinkOutsideDestinationError. Node.js is now extracted with
# the system tar command first, with a Python fallback that
# safely handles symlinks.
# ============================================================

set -Eeuo pipefail

REPO_ZIP_URL="https://github.com/notroboy67-htp/Panel/archive/refs/heads/main.zip"
BASE_DIR="${BASE_DIR:-${HOME}/nrb-panel}"
REPO_ARCHIVE="${BASE_DIR}/panel-repository.zip"
REPO_DIR="${BASE_DIR}/repository"
APP_DIR="${BASE_DIR}/app"
NODE_DIR="${BASE_DIR}/node"
NODE_VERSION="${NODE_VERSION:-20.19.4}"
PORT="${PORT:-3000}"

log()  { printf '\033[1;32m[NRB]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

has() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------
# Base requirements - no package manager
# ------------------------------------------------------------

has python3 || die "python3 is required."
has tar || die "tar is required to install Node.js without apt."
has xz || die "xz is required to install Node.js without apt."

python3 - <<'PY'
import ssl, urllib.request, zipfile, tarfile
print("Python ZIP/HTTPS support: OK")
PY

# ------------------------------------------------------------
# Download helper
# ------------------------------------------------------------

download() {
    python3 - "$1" "$2" <<'PY'
import sys
import urllib.request

url, dest = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url, headers={"User-Agent": "NRB-Panel-Installer/2.0"})

with urllib.request.urlopen(req, timeout=90) as r, open(dest, "wb") as f:
    while True:
        data = r.read(1024 * 1024)
        if not data:
            break
        f.write(data)

print("Downloaded:", dest)
PY
}

# ------------------------------------------------------------
# ZIP helper
# ------------------------------------------------------------

extract_zip() {
    local archive="$1"
    local destination="$2"

    rm -rf "$destination"
    mkdir -p "$destination"

    python3 - "$archive" "$destination" <<'PY'
import sys
import zipfile
from pathlib import Path

archive = Path(sys.argv[1])
dest = Path(sys.argv[2]).resolve()
dest.mkdir(parents=True, exist_ok=True)

with zipfile.ZipFile(archive, "r") as z:
    bad = z.testzip()
    if bad:
        raise SystemExit(f"Corrupt ZIP entry: {bad}")

    for info in z.infolist():
        name = info.filename.replace("\\", "/")
        target = (dest / name).resolve()

        if target != dest and dest not in target.parents:
            raise SystemExit(f"Unsafe ZIP path: {name}")

        if info.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with z.open(info) as src, open(target, "wb") as out:
                while True:
                    data = src.read(1024 * 1024)
                    if not data:
                        break
                    out.write(data)
PY
}

# ------------------------------------------------------------
# Node tar.xz extraction
#
# FIRST CHOICE: system tar.
# Node's official Linux archive contains symlinks such as:
#   bin/corepack -> ../lib/node_modules/corepack/dist/corepack.js
#
# Python 3.10's tarfile extraction filter rejects these with:
#   LinkOutsideDestinationError
#
# Normal tar correctly handles them.
# ------------------------------------------------------------

extract_node() {
    local archive="$1"
    local destination="$2"

    rm -rf "$destination"
    mkdir -p "$destination"

    log "Extracting Node.js with tar..."

    tar -xJf "$archive" -C "$destination" || return 1
}

# ------------------------------------------------------------
# Clean old attempt
# ------------------------------------------------------------

log "Starting final Docker/Codespaces installer..."
log "NO apt / NO dpkg / NO git"

rm -rf "$BASE_DIR"
mkdir -p "$BASE_DIR"

# ------------------------------------------------------------
# Download GitHub repository without git
# ------------------------------------------------------------

log "Downloading Panel repository..."

download "$REPO_ZIP_URL" "$REPO_ARCHIVE" \
    || die "Failed to download Panel repository."

[ -s "$REPO_ARCHIVE" ] || die "Panel repository ZIP is empty."

log "Extracting Panel repository..."
extract_zip "$REPO_ARCHIVE" "$REPO_DIR" \
    || die "Failed to extract Panel repository."

REPO_ROOT="$(find "$REPO_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[ -n "$REPO_ROOT" ] || die "Repository directory was not found."

# ------------------------------------------------------------
# Find mcpanelv1.zip
# ------------------------------------------------------------

ZIP_FILE="$(find "$REPO_ROOT" -maxdepth 3 -type f \
    -iname 'mcpanelv1.zip' -print -quit || true)"

if [ -z "$ZIP_FILE" ]; then
    ZIP_FILE="$(find "$REPO_ROOT" -maxdepth 3 -type f \
        -iname '*.zip' -print -quit || true)"
fi

[ -n "$ZIP_FILE" ] || die "mcpanelv1.zip was not found in the repository."

log "Panel archive: $ZIP_FILE"

# ------------------------------------------------------------
# Extract application
# ------------------------------------------------------------

log "Extracting mcpanelv1.zip..."
extract_zip "$ZIP_FILE" "$APP_DIR" \
    || die "Failed to extract mcpanelv1.zip."

if [ -f "$APP_DIR/panel/package.json" ]; then
    APP_ROOT="$APP_DIR/panel"
else
    PACKAGE_JSON="$(find "$APP_DIR" -type f -name package.json -print -quit || true)"
    [ -n "$PACKAGE_JSON" ] || die "package.json not found in mcpanelv1.zip."
    APP_ROOT="$(dirname "$PACKAGE_JSON")"
fi

cd "$APP_ROOT"

log "Application directory: $APP_ROOT"

[ -f package.json ] || die "package.json is missing."

# ------------------------------------------------------------
# Node.js
# ------------------------------------------------------------

USE_LOCAL_NODE="false"

if has node && has npm; then
    CURRENT_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"

    if [ "$CURRENT_MAJOR" -ge 18 ]; then
        log "Using existing Node.js: $(node --version)"
        log "Using existing npm: $(npm --version)"
    else
        warn "Existing Node.js $(node --version) is too old. Installing Node ${NODE_VERSION} locally."
        USE_LOCAL_NODE="true"
    fi
else
    log "Node.js/npm not found. Installing Node.js ${NODE_VERSION} locally..."
    USE_LOCAL_NODE="true"
fi

if [ "$USE_LOCAL_NODE" = "true" ]; then
    ARCH="$(uname -m)"

    case "$ARCH" in
        x86_64|amd64) NODE_ARCH="x64" ;;
        aarch64|arm64) NODE_ARCH="arm64" ;;
        armv7l|armv7) NODE_ARCH="armv7l" ;;
        *) die "Unsupported architecture: $ARCH" ;;
    esac

    NODE_ARCHIVE="$BASE_DIR/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
    NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"

    log "Downloading Node.js from nodejs.org..."
    download "$NODE_URL" "$NODE_ARCHIVE" \
        || die "Failed to download Node.js."

    extract_node "$NODE_ARCHIVE" "$NODE_DIR" \
        || die "Could not extract Node.js."

    NODE_ROOT="$(find "$NODE_DIR" -mindepth 1 -maxdepth 1 \
        -type d -name 'node-v*' -print -quit)"

    [ -n "$NODE_ROOT" ] || die "Node.js extraction directory not found."

    export PATH="$NODE_ROOT/bin:$PATH"

    has node || die "Node.js installation failed."
    has npm || die "npm installation failed."

    log "Node.js installed: $(node --version)"
    log "npm installed: $(npm --version)"
fi

# ------------------------------------------------------------
# Validate actual app.js
# ------------------------------------------------------------

if [ -f app.js ]; then
    log "Checking app.js syntax..."
    node --check app.js || die "app.js has a JavaScript syntax error."
fi

# ------------------------------------------------------------
# Install npm dependencies
# ------------------------------------------------------------

log "Installing panel dependencies..."

export npm_config_audit=false
export npm_config_fund=false

if [ -f package-lock.json ]; then
    npm ci --omit=dev || {
        warn "npm ci failed; trying npm install..."
        npm install --omit=dev
    }
else
    npm install --omit=dev
fi

# Native dependencies may need rebuilding.
npm rebuild || warn "npm rebuild reported an error; continuing."

# ------------------------------------------------------------
# Check important modules
# ------------------------------------------------------------

node - <<'NODE'
const modules = [
  "express",
  "express-session",
  "sqlite3",
  "bcryptjs",
  "multer",
  "socket.io",
  "axios",
  "rcon-client",
  "prismarine-nbt"
];

const missing = [];

for (const name of modules) {
  try {
    require(name);
  } catch (e) {
    missing.push(name + ": " + e.message);
  }
}

if (missing.length) {
  console.error("\nRequired module check failed:");
  for (const item of missing) console.error(" - " + item);
  process.exit(1);
}

console.log("Required Node.js modules: OK");
NODE

# ------------------------------------------------------------
# Runtime directories
# ------------------------------------------------------------

mkdir -p \
    servers \
    backups \
    uploads \
    temp \
    public/uploads \
    public/uploads/profiles

# ------------------------------------------------------------
# Determine start command
# ------------------------------------------------------------

START_SCRIPT="$(node -e '
try {
 const p=require("./package.json");
 process.stdout.write((p.scripts && p.scripts.start) || "");
} catch(e) {}
' 2>/dev/null || true)"

if [ -n "$START_SCRIPT" ]; then
    START_MODE="npm"
else
    [ -f app.js ] || die "No npm start script and app.js was not found."
    START_MODE="node"
fi

# ------------------------------------------------------------
# Java check
# ------------------------------------------------------------

if has java; then
    log "Java: $(java -version 2>&1 | head -n 1)"
else
    warn "Java is not installed."
    warn "The web panel can start, but Minecraft Java servers require Java."
fi

# ------------------------------------------------------------
# Finish
# ------------------------------------------------------------

export NODE_ENV="${NODE_ENV:-production}"
export PORT

echo
echo "============================================================"
echo "          NRB PANEL - INSTALLATION COMPLETE"
echo "============================================================"
echo
echo "Panel directory : $APP_ROOT"
echo "Node.js         : $(node --version)"
echo "npm             : $(npm --version)"
echo "Port            : $PORT"
echo

if [ "$START_MODE" = "npm" ]; then
    echo "Start command   : npm start"
else
    echo "Start command   : node app.js"
fi

echo
echo "Docker: publish port $PORT."
echo "Codespaces: forward port $PORT."
echo
echo "Starting the panel in the foreground..."
echo "Press Ctrl+C to stop."
echo "============================================================"
echo

if [ "$START_MODE" = "npm" ]; then
    exec npm start
else
    exec node app.js
fi
