#!/usr/bin/env bash
set -e

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/uppaljs/telemt-docker/main/stack}"
INSTALL_DIR="${INSTALL_DIR:-$(pwd)/mtproxy-data}"
FAKE_DOMAIN="${FAKE_DOMAIN:-1c.ru}"
TELEMT_INTERNAL_PORT="${TELEMT_INTERNAL_PORT:-1234}"
LISTEN_PORT="${LISTEN_PORT:-443}"
SERVER_ADDR="${SERVER_ADDR:-}"
SECRET=""
ACTION=""
INTERACTIVE=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

# Prompt and read from /dev/tty so it works when piped via curl | bash.
# When stdin is a pipe, normal read/echo go to the pipe, not the user.
# /dev/tty always refers to the controlling terminal.
say() {
    echo -e "$@" >/dev/tty
}
say_n() {
    echo -n -e "$@" >/dev/tty
}
ask() {
    local var="$1"
    IFS= read -r "$var" </dev/tty
}

detect_interactive() {
    # Try writing to /dev/tty — if it works, we have a terminal
    if (echo -n >/dev/tty) 2>/dev/null; then
        INTERACTIVE=true
    fi
}

usage() {
    echo "Usage: $(basename "$0") [install|uninstall|reinstall|status|link]"
    echo ""
    echo "Commands:"
    echo "  install     Install and start the MTProxy stack (default)"
    echo "  uninstall   Stop containers and remove all data"
    echo "  reinstall   Uninstall then install fresh"
    echo "  status      Show container status and proxy link"
    echo "  link        Print the tg://proxy link"
    echo ""
    echo "Environment variables:"
    echo "  SERVER_ADDR   Server domain or IP for the proxy link"
    echo "  INSTALL_DIR   Install directory (default: ./mtproxy-data)"
    echo "  LISTEN_PORT   External port (default: 443)"
    echo "  FAKE_DOMAIN   Fake TLS domain (default: 1c.ru)"
    exit 0
}

fetch() {
    local url="$1"
    local dest="$2"
    if ! curl -fsSL "$url" -o "$dest"; then
        err "Failed to download: $url"
    fi
}

rerun_cmd() {
    if [[ "$0" == *bash* ]] || [[ "$0" == -* ]]; then
        echo "curl -sSL https://raw.githubusercontent.com/uppaljs/telemt-docker/main/stack/install.sh | bash"
    else
        local dir
        dir="$(cd "$(dirname "$0")" && pwd)"
        echo "bash ${dir}/$(basename "$0")"
    fi
}

# ── Docker ──────────────────────────────────────────────────

need_sudo() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "sudo"
    fi
}

check_docker() {
    if command -v docker &>/dev/null; then
        if docker info &>/dev/null 2>&1; then
            info "Docker is available."
            return 0
        fi
        echo ""
        warn "Docker is installed but the current user is not in the docker group."
        echo ""
        echo "Run the following commands:"
        echo -e "  ${GREEN}sudo usermod -aG docker \$USER && newgrp docker${NC}"
        echo ""
        echo "Then run this script again:"
        echo -e "  ${GREEN}$(rerun_cmd)${NC}"
        echo ""
        exit 1
    fi

    info "Docker not found. Installing Docker..."
    echo ""
    local sudo_cmd
    sudo_cmd=$(need_sudo)
    if ! curl -fsSL https://get.docker.com | ${sudo_cmd} sh; then
        err "Docker installation failed. Install Docker manually and re-run this script."
    fi
    info "Docker installed successfully."

    # If not root, add current user to docker group
    if [[ "$(id -u)" -ne 0 ]]; then
        if ! groups | grep -qw docker; then
            info "Adding $(whoami) to the docker group..."
            sudo usermod -aG docker "$(whoami)" || true
        fi
    fi

    # Check if docker works now
    if docker info &>/dev/null 2>&1; then
        info "Docker is ready."
        return 0
    fi

    # Docker installed but group not active in current session
    echo ""
    warn "Docker installed, but you need to activate the docker group."
    echo ""
    echo "Run the following command:"
    echo -e "  ${GREEN}newgrp docker${NC}"
    echo ""
    echo "Then run this script again:"
    echo -e "  ${GREEN}$(rerun_cmd)${NC}"
    echo ""
    exit 1
}

# ── Port ────────────────────────────────────────────────────

is_port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tuln 2>/dev/null | grep -qE "[.:]${port}[[:space:]]"
        return $?
    fi
    if command -v nc &>/dev/null; then
        nc -z 127.0.0.1 "$port" 2>/dev/null
        return $?
    fi
    return 1
}

prompt_port() {
    local suggested=443
    if is_port_in_use 443; then
        warn "Port 443 is in use."
        suggested=1443
    fi
    if ! $INTERACTIVE; then
        LISTEN_PORT=$suggested
        return
    fi
    local input
    while true; do
        say_n "Port for proxy [${suggested}]: "
        ask input
        [[ -z "$input" ]] && input=$suggested
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
            if is_port_in_use "$input"; then
                warn "Port ${input} is in use, choose another."
            else
                LISTEN_PORT=$input
                return
            fi
        else
            warn "Enter a number from 1 to 65535."
        fi
    done
}

# ── Server address ──────────────────────────────────────────

detect_server_ip() {
    # Try IPv4 first (curl -4), then fall back to any
    local raw
    for url in https://ifconfig.me/ip https://icanhazip.com https://api.ipify.org https://checkip.amazonaws.com; do
        raw=$(curl -4 -s --connect-timeout 3 "$url" 2>/dev/null | tr -d '\n\r') || true
        if [[ -n "$raw" ]] && [[ "$raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$raw"
            return
        fi
    done
    # Fall back to any IP (may be IPv6)
    for url in https://ifconfig.me/ip https://icanhazip.com https://api.ipify.org; do
        raw=$(curl -s --connect-timeout 3 "$url" 2>/dev/null | tr -d '\n\r') || true
        if [[ -n "$raw" ]] && [[ ! "$raw" =~ [[:space:]] ]] && [[ "$raw" =~ ^([0-9.]+|[0-9a-fA-F:]+)$ ]]; then
            echo "$raw"
            return
        fi
    done
}

prompt_server_addr() {
    local detected
    detected=$(detect_server_ip)
    if $INTERACTIVE; then
        local input
        if [[ -n "$detected" ]]; then
            say ""
            say "  Detected server IP: ${CYAN}${detected}${NC}"
            say ""
            say_n "Server address (domain, IPv4, or IPv6) [${detected}]: "
            ask input
            if [[ -n "$input" ]]; then
                SERVER_ADDR="$input"
            else
                SERVER_ADDR="$detected"
            fi
        else
            say_n "Server address (domain or IP) — could not auto-detect: "
            ask input
            if [[ -n "$input" ]]; then
                SERVER_ADDR="$input"
            else
                SERVER_ADDR="YOUR_SERVER_IP"
                warn "No server address provided. Replace YOUR_SERVER_IP in the link manually."
            fi
        fi
    else
        SERVER_ADDR="${detected:-YOUR_SERVER_IP}"
        [[ "$SERVER_ADDR" == "YOUR_SERVER_IP" ]] && warn "Could not detect server IP."
    fi
    info "Server address: ${SERVER_ADDR}"
}

# ── Domain ──────────────────────────────────────────────────

prompt_fake_domain() {
    if $INTERACTIVE; then
        local input
        say_n "Domain for Fake TLS masking [${FAKE_DOMAIN}]: "
        ask input
        [[ -n "$input" ]] && FAKE_DOMAIN="$input"
    fi
    info "Fake TLS domain: ${FAKE_DOMAIN}"
}

# ── Secret ──────────────────────────────────────────────────

generate_secret() {
    openssl rand -hex 16
}

prompt_secret() {
    local generated input
    generated=$(generate_secret)
    if ! $INTERACTIVE; then
        SECRET="$generated"
        info "Secret: ${SECRET}"
        return
    fi
    say ""
    say "  Generated secret: ${CYAN}${generated}${NC}"
    say ""
    say_n "Use this secret? [Y/n] or paste your own 32-hex-char secret: "
    ask input
    if [[ -z "$input" ]] || [[ "$input" =~ ^[Yy]$ ]]; then
        SECRET="$generated"
    elif [[ "$input" =~ ^[0-9a-fA-F]{32}$ ]]; then
        SECRET="$input"
    elif [[ "$input" =~ ^[Nn]$ ]]; then
        while true; do
            say_n "Enter your 32-hex-char secret: "
            ask input
            if [[ "$input" =~ ^[0-9a-fA-F]{32}$ ]]; then
                SECRET="$input"
                break
            else
                warn "Invalid secret. Must be exactly 32 hex characters."
            fi
        done
    else
        warn "Invalid input. Using generated secret."
        SECRET="$generated"
    fi
    info "Secret: ${SECRET}"
}

# ── Internal port ───────────────────────────────────────────

prompt_internal_port() {
    if $INTERACTIVE; then
        local input
        say_n "Internal Telemt port [${TELEMT_INTERNAL_PORT}]: "
        ask input
        if [[ -n "$input" ]]; then
            if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
                TELEMT_INTERNAL_PORT=$input
            else
                warn "Invalid port. Using default ${TELEMT_INTERNAL_PORT}."
            fi
        fi
    fi
}

# ── Download & configure ───────────────────────────────────

download_and_configure() {
    info "Downloading files from ${REPO_RAW} ..."
    mkdir -p "${INSTALL_DIR}/traefik/dynamic" "${INSTALL_DIR}/traefik/static"

    fetch "${REPO_RAW}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
    sed "s/443:443/${LISTEN_PORT}:443/" "${INSTALL_DIR}/docker-compose.yml" > "${INSTALL_DIR}/docker-compose.yml.tmp" && mv "${INSTALL_DIR}/docker-compose.yml.tmp" "${INSTALL_DIR}/docker-compose.yml"
    fetch "${REPO_RAW}/traefik/dynamic/tcp.yml" "${INSTALL_DIR}/traefik/dynamic/tcp.yml"
    fetch "${REPO_RAW}/telemt.toml.example" "${INSTALL_DIR}/telemt.toml.example"

    sed -e "s/REPLACE_WITH_32_HEX_CHARS/${SECRET}/g" \
        -e "s/tls_domain = \"1c.ru\"/tls_domain = \"${FAKE_DOMAIN}\"/g" \
        -e "s/^port = 1234$/port = ${TELEMT_INTERNAL_PORT}/" \
        "${INSTALL_DIR}/telemt.toml.example" > "${INSTALL_DIR}/telemt.toml"
    rm -f "${INSTALL_DIR}/telemt.toml.example"
    info "Created ${INSTALL_DIR}/telemt.toml (domain: ${FAKE_DOMAIN}, port: ${TELEMT_INTERNAL_PORT})"

    local tcp_yml="${INSTALL_DIR}/traefik/dynamic/tcp.yml"
    sed -e "s/telemt:1234/telemt:${TELEMT_INTERNAL_PORT}/g" \
        "$tcp_yml" > "${tcp_yml}.tmp" && mv "${tcp_yml}.tmp" "$tcp_yml"
    info "Configured Traefik: SNI * -> telemt:${TELEMT_INTERNAL_PORT} (TLS passthrough)"

    printf '%s' "$SECRET" > "${INSTALL_DIR}/.secret"
    printf '%s' "$LISTEN_PORT" > "${INSTALL_DIR}/.port"
    printf '%s' "$SERVER_ADDR" > "${INSTALL_DIR}/.server"
}

# ── Compose ─────────────────────────────────────────────────

run_compose() {
    cd "${INSTALL_DIR}"
    docker compose pull -q 2>/dev/null || true
    docker compose up -d
    info "Containers started."
}

stop_compose() {
    if [[ -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
        cd "${INSTALL_DIR}"
        docker compose down --remove-orphans 2>/dev/null || true
        info "Containers stopped."
    fi
}

# ── Link ────────────────────────────────────────────────────

build_link() {
    local secret="$1"
    local port="$2"
    local tls_domain="$3"
    local server="$4"
    local domain_hex long_secret

    domain_hex=$(printf '%s' "$tls_domain" | od -An -tx1 | tr -d ' \n')
    if [[ "$secret" =~ ^[0-9a-fA-F]{32}$ ]]; then
        long_secret="ee${secret}${domain_hex}"
    else
        long_secret="$secret"
    fi

    echo "tg://proxy?server=${server}&port=${port}&secret=${long_secret}"
}

print_link() {
    local secret port tls_domain server link

    secret=$(cat "${INSTALL_DIR}/.secret" 2>/dev/null | tr -d '\n\r')
    [[ -z "$secret" ]] && err "Secret not found in ${INSTALL_DIR}/.secret"

    port=$(cat "${INSTALL_DIR}/.port" 2>/dev/null | tr -d '\n\r')
    [[ -z "$port" ]] && port="$LISTEN_PORT"

    server=$(cat "${INSTALL_DIR}/.server" 2>/dev/null | tr -d '\n\r')
    if [[ -z "$server" ]]; then
        server=$(detect_server_ip)
        [[ -z "$server" ]] && server="YOUR_SERVER_IP"
    fi

    tls_domain=$(grep -E '^[[:space:]]*tls_domain[[:space:]]*=' "${INSTALL_DIR}/telemt.toml" \
        | head -n1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
    [[ -z "$tls_domain" ]] && err "tls_domain not found in ${INSTALL_DIR}/telemt.toml"

    link=$(build_link "$secret" "$port" "$tls_domain" "$server")

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Telegram Proxy Link (Fake TLS)                         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${GREEN}${link}${NC}"
    echo ""
    echo "  Save this link and do not share it publicly."
    echo ""
    echo "  Install directory: ${INSTALL_DIR}"
    echo "  Logs:              cd ${INSTALL_DIR} && docker compose logs -f"
    echo "  Stop:              cd ${INSTALL_DIR} && docker compose down"
    echo ""
}

# ── Actions ─────────────────────────────────────────────────

do_install() {
    if [[ -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
        warn "Existing installation found at ${INSTALL_DIR}"
        if $INTERACTIVE; then
            say_n "Reinstall from scratch? This will DELETE all data. [y/N]: "
            ask confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                do_uninstall
            else
                info "Keeping existing installation. Use 'reinstall' to force."
                return 0
            fi
        else
            err "Existing installation found. Use 'reinstall' to replace it."
        fi
    fi

    check_docker
    echo ""
    echo -e "${CYAN}── MTProxy Configuration ──────────────────────────────────${NC}"
    echo ""
    prompt_server_addr
    prompt_port
    prompt_fake_domain
    prompt_secret
    prompt_internal_port
    echo ""
    echo -e "${CYAN}── Summary ────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  Server address:  ${GREEN}${SERVER_ADDR}${NC}"
    echo -e "  Listen port:     ${GREEN}${LISTEN_PORT}${NC}"
    echo -e "  Fake TLS domain: ${GREEN}${FAKE_DOMAIN}${NC}"
    echo -e "  Secret:          ${GREEN}${SECRET}${NC}"
    echo -e "  Internal port:   ${GREEN}${TELEMT_INTERNAL_PORT}${NC}"
    echo -e "  Install dir:     ${GREEN}${INSTALL_DIR}${NC}"
    echo ""

    if $INTERACTIVE; then
        say_n "Proceed with installation? [Y/n]: "
        ask confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            info "Aborted."
            exit 0
        fi
    fi

    echo ""
    download_and_configure
    run_compose
    print_link
}

do_uninstall() {
    if [[ ! -d "${INSTALL_DIR}" ]]; then
        warn "No installation found at ${INSTALL_DIR}. Nothing to remove."
        return 0
    fi

    if $INTERACTIVE && [[ "$ACTION" != "reinstall" ]]; then
        say ""
        warn "This will stop all containers and DELETE ${INSTALL_DIR}"
        say_n "Are you sure? [y/N]: "
        ask confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "Aborted."
            exit 0
        fi
    fi

    stop_compose
    rm -rf "${INSTALL_DIR}"
    info "Removed ${INSTALL_DIR}"
}

do_reinstall() {
    ACTION="reinstall"
    do_uninstall
    do_install
}

do_status() {
    if [[ ! -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
        warn "No installation found at ${INSTALL_DIR}"
        return 1
    fi
    echo ""
    echo -e "${CYAN}── Container Status ───────────────────────────────────────${NC}"
    echo ""
    cd "${INSTALL_DIR}"
    docker compose ps 2>/dev/null || warn "Could not get container status."
    print_link
}

do_link() {
    if [[ ! -f "${INSTALL_DIR}/telemt.toml" ]]; then
        err "No installation found at ${INSTALL_DIR}"
    fi
    print_link
}

# ── Main ────────────────────────────────────────────────────

main() {
    [[ "${INSTALL_DIR}" != /* ]] && INSTALL_DIR="$(pwd)/${INSTALL_DIR}"
    detect_interactive

    local cmd="${1:-install}"
    case "$cmd" in
        install)    do_install ;;
        uninstall)  do_uninstall ;;
        reinstall)  do_reinstall ;;
        status)     do_status ;;
        link)       do_link ;;
        -h|--help|help) usage ;;
        *)
            err "Unknown command: $cmd. Use --help for usage."
            ;;
    esac
}

main "$@"
