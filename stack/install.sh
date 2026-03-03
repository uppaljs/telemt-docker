#!/usr/bin/env bash
set -e

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/uppaljs/telemt-docker/main/stack}"
INSTALL_DIR="${INSTALL_DIR:-$(pwd)/mtproxy-data}"
FAKE_DOMAIN="${FAKE_DOMAIN:-1c.ru}"
TELEMT_INTERNAL_PORT="${TELEMT_INTERNAL_PORT:-1234}"
LISTEN_PORT="${LISTEN_PORT:-443}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

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

check_docker() {
    if command -v docker &>/dev/null; then
        if docker info &>/dev/null 2>&1; then
            info "Docker is available."
            return 0
        fi
        echo ""
        warn "Docker is installed but the current user is not in the docker group."
        echo ""
        echo "Run the following command (add to group and apply):"
        echo -e "  ${GREEN}sudo usermod -aG docker \$USER && newgrp docker${NC}"
        echo ""
        echo "Then run this script again:"
        echo -e "  ${GREEN}$(rerun_cmd)${NC}"
        echo ""
        exit 1
    fi
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    if ! docker info &>/dev/null 2>&1; then
        echo ""
        warn "Docker installed. You need to add the user to the docker group."
        echo ""
        echo "Run the following command:"
        echo -e "  ${GREEN}sudo usermod -aG docker \$USER && newgrp docker${NC}"
        echo ""
        echo "Then run this script again:"
        echo -e "  ${GREEN}$(rerun_cmd)${NC}"
        echo ""
        exit 1
    fi
}

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
        while true; do
            if [[ -t 0 ]]; then
                echo -n "Enter port [${suggested}]: "
                read -r input
                [[ -z "$input" ]] && input=$suggested
            else
                LISTEN_PORT=$suggested
                return
            fi
            if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
                if is_port_in_use "$input"; then
                    warn "Port ${input} is also in use, choose another."
                else
                    LISTEN_PORT=$input
                    return
                fi
            else
                warn "Enter a number from 1 to 65535."
            fi
        done
    else
        if [[ -t 0 ]]; then
            echo -n "Port for proxy [443]: "
            read -r input
            [[ -n "$input" ]] && input="$input" || input=443
            while true; do
                if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
                    if is_port_in_use "$input"; then
                        warn "Port ${input} is in use, choose another."
                        echo -n "Enter port: "
                        read -r input
                    else
                        LISTEN_PORT=$input
                        return
                    fi
                else
                    warn "Enter a number from 1 to 65535."
                    echo -n "Enter port [443]: "
                    read -r input
                    [[ -z "$input" ]] && input=443
                fi
            done
        fi
    fi
}

prompt_fake_domain() {
    if [[ -n "${FAKE_DOMAIN_FROM_ENV}" ]]; then
        FAKE_DOMAIN="${FAKE_DOMAIN_FROM_ENV}"
        return
    fi
    if [[ -t 0 ]]; then
        echo -n "Domain for Fake TLS masking [${FAKE_DOMAIN}]: "
        read -r input
        [[ -n "$input" ]] && FAKE_DOMAIN="$input"
    fi
}

generate_secret() {
    openssl rand -hex 16
}

download_and_configure() {
    info "Downloading files from ${REPO_RAW} ..."
    mkdir -p "${INSTALL_DIR}/traefik/dynamic" "${INSTALL_DIR}/traefik/static"

    fetch "${REPO_RAW}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
    sed "s/443:443/${LISTEN_PORT}:443/" "${INSTALL_DIR}/docker-compose.yml" > "${INSTALL_DIR}/docker-compose.yml.tmp" && mv "${INSTALL_DIR}/docker-compose.yml.tmp" "${INSTALL_DIR}/docker-compose.yml"
    fetch "${REPO_RAW}/traefik/dynamic/tcp.yml" "${INSTALL_DIR}/traefik/dynamic/tcp.yml"
    fetch "${REPO_RAW}/telemt.toml.example" "${INSTALL_DIR}/telemt.toml.example"

    SECRET=$(generate_secret)

    sed -e "s/REPLACE_WITH_32_HEX_CHARS/${SECRET}/g" \
        -e "s/tls_domain = \"1c.ru\"/tls_domain = \"${FAKE_DOMAIN}\"/g" \
        "${INSTALL_DIR}/telemt.toml.example" > "${INSTALL_DIR}/telemt.toml"
    rm -f "${INSTALL_DIR}/telemt.toml.example"
    info "Created ${INSTALL_DIR}/telemt.toml (masking domain: ${FAKE_DOMAIN})"

    local tcp_yml="${INSTALL_DIR}/traefik/dynamic/tcp.yml"
    sed -e "s/1c\.ru/${FAKE_DOMAIN}/g" \
        -e "s/telemt:1234/telemt:${TELEMT_INTERNAL_PORT}/g" \
        "$tcp_yml" > "${tcp_yml}.tmp" && mv "${tcp_yml}.tmp" "$tcp_yml"
    info "Configured Traefik: SNI ${FAKE_DOMAIN} -> telemt:${TELEMT_INTERNAL_PORT} (TLS passthrough)"

    printf '%s' "$SECRET" > "${INSTALL_DIR}/.secret"
}

run_compose() {
    cd "${INSTALL_DIR}"
    docker compose pull -q 2>/dev/null || true
    docker compose up -d
    info "Containers started."
}

print_link() {
    local SECRET TLS_DOMAIN DOMAIN_HEX LONG_SECRET SERVER_IP LINK
    SECRET=$(cat "${INSTALL_DIR}/.secret" 2>/dev/null | tr -d '\n\r')
    [[ -z "$SECRET" ]] && err "Secret not found in ${INSTALL_DIR}/.secret"

    TLS_DOMAIN=$(grep -E '^[[:space:]]*tls_domain[[:space:]]*=' "${INSTALL_DIR}/telemt.toml" \
        | head -n1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
    [[ -z "$TLS_DOMAIN" ]] && err "tls_domain not found in ${INSTALL_DIR}/telemt.toml"

    DOMAIN_HEX=$(printf '%s' "$TLS_DOMAIN" | od -An -tx1 | tr -d ' \n')
    if [[ "$SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
        LONG_SECRET="ee${SECRET}${DOMAIN_HEX}"
    else
        LONG_SECRET="$SECRET"
    fi

    SERVER_IP=""
    for url in https://ifconfig.me/ip https://icanhazip.com https://api.ipify.org https://checkip.amazonaws.com; do
        raw=$(curl -s --connect-timeout 3 "$url" 2>/dev/null | tr -d '\n\r')
        if [[ -n "$raw" ]] && [[ ! "$raw" =~ [[:space:]] ]] && [[ ! "$raw" =~ (error|timeout|upstream|reset|refused) ]] && [[ "$raw" =~ ^([0-9.]+|[0-9a-fA-F:]+)$ ]]; then
            SERVER_IP="$raw"
            break
        fi
    done
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP="YOUR_SERVER_IP"
        warn "Could not detect external IP. Replace YOUR_SERVER_IP in the link manually."
    fi
    LINK="tg://proxy?server=${SERVER_IP}&port=${LISTEN_PORT}&secret=${LONG_SECRET}"
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Telegram Proxy Link (Fake TLS)                         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${GREEN}${LINK}${NC}"
    echo ""
    echo "  Save this link and do not share it publicly."
    echo ""
    echo "  Install directory: ${INSTALL_DIR}"
    echo "  Logs:              cd ${INSTALL_DIR} && docker compose logs -f"
    echo "  Stop:              cd ${INSTALL_DIR} && docker compose down"
    echo ""
}

main() {
    [[ "${INSTALL_DIR}" != /* ]] && INSTALL_DIR="$(pwd)/${INSTALL_DIR}"
    check_docker
    prompt_port
    prompt_fake_domain
    download_and_configure
    run_compose
    print_link
}

main "$@"
