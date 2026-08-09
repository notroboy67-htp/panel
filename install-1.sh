#!/usr/bin/env bash
# ============================================================
# NRB PANEL - CLEAN DOCKER / CODESPACES INSTALLER
# ============================================================
#
# This installer was written after inspecting mcpanelv1.zip.
#
# It intentionally uses:
#   - NO apt
#   - NO apt-get
#   - NO dpkg
#   - NO git
#   - NO sudo
#
# It downloads the GitHub repository with Python, extracts the
# repository and mcpanelv1.zip with Python, installs Node.js
# locally when necessary, installs npm dependencies, validates
# app.js, and starts the actual app with "npm start".
#
# Repository:
#   https://github.com/notroboy67-htp/Panel
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

# ------------------------------------------------------------
# Required base tools
# ------------------------------------------------------------

command -v python3 >/dev/null 2>&1 || die \
"python3 is required. This installer will NOT use apt to install it."

python3 - <<'PY'
import sys
required = ["ssl", "urllib.request", "zipfile", "tarfile", "lzma"]
missing = []
for name in required:
    try:
        __import__(name)
    except Exception:
        missing.append(name)
if missing:
    print("Missing Python modules:", ", ".join(missing))
    raise SystemExit(1)
PY

log "Python: $(python3 --version)"

# ------------------------------------------------------------
# Python helper: download
# ------------------------------------------------------------

py_download() {
    python3 - "$1" "$2" <<'PY'
import sys
import urllib.request

url, destination = sys.argv[1], sys.argv[2]

request = urllib.request.Request(
    url,
    headers={"User-Agent": "NRB-Panel-Installer/1.0"}
)

with urllib.request.urlopen(request, timeout=60) as response:
    with open(destination, "wb") as out:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            out.write(chunk)

print(f"Downloaded: {destination}")
PY
}

# ------------------------------------------------------------
# Python helper: extract ZIP
# ------------------------------------------------------------

py_extract_zip() {
    python3 - "$1" "$2" <<'PY'
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
}

# ------------------------------------------------------------
# Python helper: extract Node's .tar.xz
# ------------------------------------------------------------

py_extract_tar_xz() {
    python3 - "$1" "$2" <<'PY'
import sys
import tarfile
from pathlib import Path

archive = Path(sys.argv[1])
destination = Path(sys.argv[2])
destination.mkdir(parents=True, exist_ok=True)

with tarfile.open(archive, "r:xz") as tar:
    tar.extractall(destination, filter="data")
PY
}

# ------------------------------------------------------------
# Fresh working directory
# ------------------------------------------------------------

log "Cleaning previous installer files..."
rm -rf "${BASE_DIR}"
mkdir -p "${BASE_DIR}" "${REPO_DIR}" "${APP_DIR}" "${NODE_DIR}"

# ------------------------------------------------------------
# Download the GitHub repository WITHOUT git
# ------------------------------------------------------------

log "Downloading Panel repository..."

py_download "${REPO_ZIP_URL}" "${REPO_ARCHIVE}" \
    || die "Could not download the Panel repository."

[ -s "${REPO_ARCHIVE}" ] || die "Repository archive is empty."

log "Extracting repository..."
py_extract_zip "${REPO_ARCHIVE}" "${REPO_DIR}" \
    || die "Could not extract the repository."

REPO_ROOT="$(find "${REPO_DIR}" -mindepth 1 -maxdepth 1 -type d -print -quit)"

[ -n "${REPO_ROOT}" ] || die "GitHub repository directory was not found."

# ------------------------------------------------------------
# Locate mcpanelv1.zip
# ------------------------------------------------------------

ZIP_FILE="$(find "${REPO_ROOT}" -maxdepth 3 -type f \
    -iname 'mcpanelv1.zip' -print -quit || true)"

if [ -z "${ZIP_FILE}" ]; then
    ZIP_FILE="$(find "${REPO_ROOT}" -maxdepth 3 -type f \
        -iname '*.zip' -print -quit || true)"
fi

[ -n "${ZIP_FILE}" ] || die \
"mcpanelv1.zip was not found in the Panel repository."

log "Found panel archive: ${ZIP_FILE}"

# ------------------------------------------------------------
# Extract mcpanelv1.zip
# ------------------------------------------------------------

log "Extracting mcpanelv1.zip..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}"

py_extract_zip "${ZIP_FILE}" "${APP_DIR}" \
    || die "Could not extract mcpanelv1.zip."

# The uploaded archive has a top-level panel/ directory.
if [ -f "${APP_DIR}/panel/package.json" ]; then
    APP_ROOT="${APP_DIR}/panel"
else
    APP_ROOT="$(find "${APP_DIR}" -type f -name package.json \
        -print -quit | xargs -r dirname)"
fi

[ -n "${APP_ROOT}" ] || die \
"package.json was not found inside mcpanelv1.zip."

cd "${APP_ROOT}"

log "Application directory: ${APP_ROOT}"

# ------------------------------------------------------------
# Check the actual project we inspected
# ------------------------------------------------------------

[ -f package.json ] || die "package.json is missing."
[ -f app.js ] || warn "app.js was not found; startup will use package.json."

# Syntax check before installing/starting.
if command -v node >/dev/null 2>&1; then
    node --check app.js || die "app.js has a JavaScript syntax error."
fi

# ------------------------------------------------------------
# Node.js
# ------------------------------------------------------------

if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"

    if [ "${NODE_MAJOR}" -ge 18 ]; then
        log "Using existing Node.js $(node --version)"
        log "Using existing npm $(npm --version)"
    else
        warn "Existing Node.js is too old (${NODE_MAJOR})."
        unset NODE_MAJOR
    fi
fi

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    log "Installing Node.js ${NODE_VERSION} locally (NO apt/dpkg)..."

    ARCH="$(uname -m)"
    case "${ARCH}" in
        x86_64|amd64) NODE_ARCH="x64" ;;
        aarch64|arm64) NODE_ARCH="arm64" ;;
        armv7l|armv7) NODE_ARCH="armv7l" ;;
        *) die "Unsupported CPU architecture: ${ARCH}" ;;
    esac

    NODE_ARCHIVE="${BASE_DIR}/node.tar.xz"
    NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"

    py_download "${NODE_URL}" "${NODE_ARCHIVE}" \
        || die "Could not download Node.js ${NODE_VERSION}."

    py_extract_tar_xz "${NODE_ARCHIVE}" "${NODE_DIR}" \
        || die "Could not extract Node.js."

    NODE_ROOT="$(find "${NODE_DIR}" -mindepth 1 -maxdepth 1 \
        -type d -name 'node-v*' -print -quit)"

    [ -n "${NODE_ROOT}" ] || die "Node.js directory was not found."

    export PATH="${NODE_ROOT}/bin:${PATH}"

    command -v node >/dev/null 2>&1 || die "Node.js installation failed."
    command -v npm >/dev/null 2>&1 || die "npm installation failed."

    log "Node.js: $(node --version)"
    log "npm: $(npm --version)"
fi

# ------------------------------------------------------------
# Final syntax check using the Node version we will actually use
# ------------------------------------------------------------

node --check app.js || die "app.js failed Node.js syntax validation."

# ------------------------------------------------------------
# Install dependencies
# ------------------------------------------------------------

log "Installing panel dependencies..."
log "This may take a few minutes because the panel uses SQLite/native modules."

export npm_config_audit=false
export npm_config_fund=false

if [ -f package-lock.json ]; then
    npm ci --omit=dev
else
    npm install --omit=dev
fi

# Rebuild native modules such as sqlite3/bcrypt when necessary.
npm rebuild || warn "npm rebuild reported a problem; continuing to startup test."

# Verify critical modules used directly by app.js.
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
    missing.push(`${name}: ${e.message}`);
  }
}

if (missing.length) {
  console.error("\nMissing/broken required modules:");
  for (const item of missing) console.error(" - " + item);
  process.exit(1);
}

console.log("Required Node.js modules: OK");
NODE

# ------------------------------------------------------------
# Prepare writable runtime directories
# ------------------------------------------------------------

mkdir -p \
    "${APP_ROOT}/servers" \
    "${APP_ROOT}/backups" \
    "${APP_ROOT}/uploads" \
    "${APP_ROOT}/temp" \
    "${APP_ROOT}/public/uploads" \
    "${APP_ROOT}/public/uploads/profiles"

# ------------------------------------------------------------
# Database
# ------------------------------------------------------------
#
# app.js creates/opens database.db itself. We intentionally do
# NOT run init-database.js because that file references
# database-updates.sql, which is not included in the supplied ZIP.
#
# This is based on inspection of the uploaded project.
# ------------------------------------------------------------

if [ -f "${APP_ROOT}/database.db" ]; then
    log "Existing database.db found; preserving it."
else
    log "database.db will be created automatically by app.js."
fi

# ------------------------------------------------------------
# Detect Java
# ------------------------------------------------------------

if command -v java >/dev/null 2>&1; then
    log "Java: $(java -version 2>&1 | head -n 1)"
else
    warn "Java is not installed."
    warn "The web panel can start, but Minecraft Java servers launched"
    warn "from the panel will require Java to be installed in the container."
fi

# ------------------------------------------------------------
# Start command
# ------------------------------------------------------------

START_SCRIPT="$(node -e '
const p=require("./package.json");
process.stdout.write((p.scripts && p.scripts.start) || "");
' 2>/dev/null || true)"

if [ -n "${START_SCRIPT}" ]; then
    START="npm start"
else
    START="node app.js"
fi

# ------------------------------------------------------------
# Final information
# ------------------------------------------------------------

echo
echo "============================================================"
echo "             NRB PANEL - READY"
echo "============================================================"
echo
echo "Project : Minecraft Server Panel"
echo "Path    : ${APP_ROOT}"
echo "Node    : $(node --version)"
echo "npm     : $(npm --version)"
echo "Port    : ${PORT}"
echo "Start   : ${START}"
echo
echo "Docker:"
echo "  Publish/expose TCP port ${PORT}."
echo
echo "GitHub Codespaces:"
echo "  Forward TCP port ${PORT} in the Ports tab."
echo
echo "The panel will now run in the foreground."
echo "Press Ctrl+C to stop it."
echo "============================================================"
echo

export NODE_ENV="${NODE_ENV:-production}"
export PORT

exec npm start
