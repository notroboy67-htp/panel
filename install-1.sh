#!/usr/bin/env bash
# ============================================================
# NRB Minecraft Panel - One Click Installer
# Installs mcpanelv1.zip as a systemd service.
# Target: Ubuntu/Debian
# ============================================================

set -Eeuo pipefail

APP_NAME="nrb-minecraft-panel"
APP_DIR="/opt/${APP_NAME}"
SERVICE_NAME="${APP_NAME}.service"
PANEL_PORT="${PANEL_PORT:-3000}"

# Change this only if you move the ZIP to another GitHub location.
PANEL_ZIP_URL="${PANEL_ZIP_URL:-https://raw.githubusercontent.com/notroboy67-htp/Notroboy-/refs/heads/main/mcpanelv1.zip}"

NODE_MAJOR="${NODE_MAJOR:-20}"
PANEL_USER="${PANEL_USER:-nrbpanel}"

log()  { echo -e "\033[1;32m[NRB]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

cleanup() {
    rm -f /tmp/nrb-mcpanel-*.zip
}
trap cleanup EXIT

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash install.sh"
}

detect_os() {
    [[ -r /etc/os-release ]] || die "Cannot detect operating system."
    . /etc/os-release

    case "${ID:-}" in
        ubuntu|debian) ;;
        *)
            die "This installer supports Ubuntu and Debian only. Detected: ${ID:-unknown}"
            ;;
    esac
}

install_packages() {
    log "Updating package lists..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y

    log "Installing required packages..."
    apt-get install -y \
        ca-certificates \
        curl \
        wget \
        unzip \
        git \
        build-essential \
        python3 \
        python3-dev \
        make \
        g++ \
        openssl \
        jq \
        openjdk-21-jre-headless

    # Install Node.js 20 LTS if the required major version is missing.
    local current_major=""
    if command -v node >/dev/null 2>&1; then
        current_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
    fi

    if [[ "${current_major}" != "${NODE_MAJOR}" ]]; then
        log "Installing Node.js ${NODE_MAJOR}.x LTS..."
        curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
        apt-get install -y nodejs
    fi

    command -v node >/dev/null 2>&1 || die "Node.js installation failed."
    command -v npm  >/dev/null 2>&1 || die "npm installation failed."
    command -v java >/dev/null 2>&1 || die "Java installation failed."

    log "Node.js: $(node --version)"
    log "npm:      $(npm --version)"
    log "Java:     $(java -version 2>&1 | head -n 1)"
}

create_user() {
    if ! id "${PANEL_USER}" >/dev/null 2>&1; then
        log "Creating service user: ${PANEL_USER}"
        useradd --system --home-dir "${APP_DIR}" --create-home \
            --shell /usr/sbin/nologin "${PANEL_USER}"
    fi
}

download_panel() {
    local zip="/tmp/nrb-mcpanel-$$.zip"
    local extract="/tmp/nrb-mcpanel-extract-$$"

    log "Downloading panel ZIP..."
    curl -fL --retry 5 --retry-delay 2 --connect-timeout 15 \
        "${PANEL_ZIP_URL}" -o "${zip}" \
        || die "Could not download panel ZIP from: ${PANEL_ZIP_URL}"

    [[ -s "${zip}" ]] || die "Downloaded ZIP is empty."

    log "Checking ZIP archive..."
    unzip -tq "${zip}" || die "The downloaded file is not a valid ZIP archive."

    rm -rf "${extract}"
    mkdir -p "${extract}"
    unzip -q "${zip}" -d "${extract}"

    # The supplied archive contains a top-level "panel/" directory.
    # Also support an archive whose files are at the root.
    local source=""
    if [[ -d "${extract}/panel" ]]; then
        source="${extract}/panel"
    else
        source="${extract}"
    fi

    [[ -f "${source}/package.json" ]] || \
        die "package.json was not found in the downloaded ZIP."

    log "Installing panel into ${APP_DIR}..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true

    rm -rf "${APP_DIR}"
    mkdir -p "${APP_DIR}"

    # Copy the actual application while excluding Git metadata and editor files.
    cp -a "${source}/." "${APP_DIR}/"
    rm -rf "${APP_DIR}/.git" "${APP_DIR}/.vscode"

    # Runtime directories used by the panel.
    mkdir -p \
        "${APP_DIR}/servers" \
        "${APP_DIR}/backups" \
        "${APP_DIR}/uploads" \
        "${APP_DIR}/temp" \
        "${APP_DIR}/public/uploads/profiles" \
        "${APP_DIR}/public/worlds"

    rm -rf "${extract}" "${zip}"
}

install_node_dependencies() {
    cd "${APP_DIR}"

    log "Installing Node.js dependencies..."
    if [[ -f package-lock.json ]]; then
        npm ci --omit=dev
    else
        npm install --omit=dev
    fi

    # The supplied project uses sqlite3 and may need a native build on some
    # architectures. Rebuild it explicitly after dependency installation.
    npm rebuild sqlite3 || warn "sqlite3 rebuild returned a non-zero status; npm's installed binary may still work."

    node --check app.js || die "app.js contains a JavaScript syntax error."

    log "Node.js dependencies installed successfully."
}

configure_environment() {
    cat > "${APP_DIR}/.env" <<EOF
NODE_ENV=production
PORT=${PANEL_PORT}
EOF

    chmod 640 "${APP_DIR}/.env"
}

configure_permissions() {
    log "Setting application permissions..."
    chown -R "${PANEL_USER}:${PANEL_USER}" "${APP_DIR}"
    chmod 750 "${APP_DIR}"
    chmod 640 "${APP_DIR}/package.json" 2>/dev/null || true
    chmod 640 "${APP_DIR}/.env"
}

create_systemd_service() {
    log "Creating systemd service..."

    cat > "/etc/systemd/system/${SERVICE_NAME}" <<EOF
[Unit]
Description=NRB Minecraft Panel
Documentation=https://github.com/notroboy67-htp/Notroboy-
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${PANEL_USER}
Group=${PANEL_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
Environment=HOME=${APP_DIR}
Environment=NODE_ENV=production
ExecStart=/usr/bin/node ${APP_DIR}/app.js
Restart=always
RestartSec=5
TimeoutStopSec=30
KillSignal=SIGTERM
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
}

configure_firewall() {
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -qi "Status: active"; then
            log "Opening TCP port ${PANEL_PORT} in UFW..."
            ufw allow "${PANEL_PORT}/tcp" >/dev/null || \
                warn "Could not update UFW rules."
        fi
    fi
}

start_panel() {
    log "Starting ${APP_NAME}..."
    systemctl restart "${SERVICE_NAME}"

    sleep 3

    if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
        warn "Panel service did not stay running."
        echo
        systemctl --no-pager --full status "${SERVICE_NAME}" || true
        echo
        warn "Recent logs:"
        journalctl -u "${SERVICE_NAME}" -n 80 --no-pager || true
        die "Installation completed, but the panel failed to start."
    fi
}

get_ip() {
    local ip=""
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "${ip}" ]] && echo "${ip}" || echo "YOUR_SERVER_IP"
}

print_success() {
    local ip
    ip="$(get_ip)"

    echo
    echo "============================================================"
    echo "        NRB MINECRAFT PANEL - INSTALLATION COMPLETE"
    echo "============================================================"
    echo
    echo " Panel URL : http://${ip}:${PANEL_PORT}"
    echo " Local URL : http://127.0.0.1:${PANEL_PORT}"
    echo
    echo " Default login:"
    echo "   Username : admin"
    echo "   Password : admin123"
    echo
    echo " IMPORTANT: Change the default password immediately."
    echo
    echo " Service:"
    echo "   systemctl status ${SERVICE_NAME}"
    echo "   systemctl restart ${SERVICE_NAME}"
    echo "   systemctl stop ${SERVICE_NAME}"
    echo "   journalctl -u ${SERVICE_NAME} -f"
    echo
    echo " Application directory:"
    echo "   ${APP_DIR}"
    echo
    echo " Panel ZIP source:"
    echo "   ${PANEL_ZIP_URL}"
    echo
    echo "============================================================"
}

main() {
    require_root
    detect_os

    log "Starting NRB Minecraft Panel one-click installation..."
    log "Target directory: ${APP_DIR}"
    log "Panel port: ${PANEL_PORT}"

    install_packages
    create_user
    download_panel
    install_node_dependencies
    configure_environment
    configure_permissions
    create_systemd_service
    configure_firewall
    start_panel
    print_success
}

main "$@"
