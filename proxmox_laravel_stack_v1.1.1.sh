#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# Proxmox VE 9 - Laravel 13 / Inertia Vue / MySQL / Redis / Horizon LXC builder
# Run as root on a Proxmox VE 9 node.
# Ubuntu 24.04 LTS containers, unprivileged by default.
#
# IMPORTANT:
# - Review this script before production use.
# - Test on a non-production Proxmox host first.
# - Make backups before extending an existing environment.
# - The Proxmox firewall is used as the primary guest firewall. UFW is not enabled.
#
# Supported:
#   1) New full stack: web + database + worker + optional Redis now
#   2) Add a single role to an existing stack: web / database / worker / Redis
#   3) Redis migration helper: update existing Laravel .env files and restart Horizon
#
# Stack:
#   web      : Ubuntu 24.04, Nginx, PHP 8.3, Composer, Node 22
#   database : Ubuntu 24.04, MySQL
#   worker   : same web runtime + Laravel Horizon process monitor
#   redis    : Ubuntu 24.04, Redis, password auth, restricted bind/firewall

VERSION="1.1.1"
STATE_DIR="/root/.pve-laravel-builder"
TMP_DIR=""
NODE="$(hostname -s)"
TEMPLATE_STORAGE="local"
ROOTFS_STORAGE="local-lvm"
BRIDGE="vmbr0"
VLAN_TAG=""
SUBNET=""
PREFIX=""
GATEWAY=""
SSH_RANGE1=""
SSH_RANGE2=""
NAMESERVER=""
APP_PATH="/var/www/laravel"
APP_USER="www-data"
APP_DOMAIN=""
WORKER_DOMAIN=""
EXPOSURE_MODE=""
PROXY_SOURCE=""
PROXY_UPSTREAM="http"
SSL_MODE="none"
LE_EMAIL=""
DEPLOY_MODE="prepare"
GIT_URL=""
GIT_BRANCH="main"
APP_KEY=""
DB_NAME="laravel"
DB_USER="laravel"
DB_PASS=""
DB_ROOT_PASS=""
REDIS_PASS=""
REDIS_IP=""
DB_IP=""
WEB_IP=""
WORKER_IP=""
WEB_CT=""
DB_CT=""
WORKER_CT=""
REDIS_CT=""
SSH_KEY_PATH=""
INSTALL_REDIS_NOW="yes"
HORIZON_ACCESS="internal"
DRY_RUN="no"
TX_ACTIVE="no"
ROLLING_BACK="no"
DATACENTER_FW_CHANGED="no"
PROXY_TLS_CERT_MODE="selfsigned"
INTERNAL_CA_CERT=""
INTERNAL_CA_KEY=""
INTERNAL_CA_CREATED_THIS_RUN="no"
CREATED_CTS=()
ENV_BACKUPS=()
HEALTH_NAMES=()
HEALTH_STATUS=()
HEALTH_DETAIL=()

# ---------- Visual CLI ----------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_BLUE=$'\033[38;5;39m'; C_GREEN=$'\033[38;5;42m'
  C_YELLOW=$'\033[38;5;214m'; C_RED=$'\033[38;5;196m'
  C_CYAN=$'\033[38;5;51m'; C_MAGENTA=$'\033[38;5;141m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_BLUE=""; C_GREEN=""
  C_YELLOW=""; C_RED=""; C_CYAN=""; C_MAGENTA=""
fi

banner() {
  clear 2>/dev/null || true
  cat <<EOF
${C_BLUE}${C_BOLD}
╔══════════════════════════════════════════════════════════════════════╗
║             PROXMOX VE 9 · LARAVEL 13 STACK BUILDER                 ║
║       Ubuntu 24.04 · Nginx · PHP 8.3 · MySQL · Redis · Horizon      ║
╚══════════════════════════════════════════════════════════════════════╝${C_RESET}
${C_DIM}Version ${VERSION} · Node: ${NODE}${C_RESET}

EOF
}

section() {
  printf "\n${C_CYAN}${C_BOLD}━━ %s ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n" "$1"
}
ok()   { printf "${C_GREEN}✔${C_RESET} %s\n" "$*"; }
info() { printf "${C_BLUE}ℹ${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}⚠${C_RESET} %s\n" "$*" >&2; }

transaction_start() {
  TX_ACTIVE="yes"
  CREATED_CTS=()
  ENV_BACKUPS=()
  DATACENTER_FW_CHANGED="no"
  INTERNAL_CA_CREATED_THIS_RUN="no"
}

register_created_ct() { CREATED_CTS+=("$1"); }

backup_ct_file() {
  local vmid="$1" file="$2" backup="/root/.pve-laravel-builder-rollback-$(date +%s)-$RANDOM"
  if ct_exec "$vmid" "test -e '$file'" >/dev/null 2>&1; then
    ct_exec "$vmid" "cp -a '$file' '$backup'"
    ENV_BACKUPS+=("$vmid|$file|$backup|exists")
  else
    ENV_BACKUPS+=("$vmid|$file|$backup|missing")
  fi
}

rollback_transaction() {
  [[ "$TX_ACTIVE" == "yes" && "$ROLLING_BACK" == "no" ]] || return 0
  ROLLING_BACK="yes"
  warn "Rollback gestart voor wijzigingen uit deze run..."
  local i rec vmid file backup existed
  for ((i=${#ENV_BACKUPS[@]}-1; i>=0; i--)); do
    rec="${ENV_BACKUPS[$i]}"; IFS='|' read -r vmid file backup existed <<<"$rec"
    if ct_exists "$vmid"; then
      if [[ "$existed" == "exists" ]]; then
        ct_exec "$vmid" "test -e '$backup' && cp -a '$backup' '$file'; rm -f '$backup'" >/dev/null 2>&1 || true
      else
        ct_exec "$vmid" "rm -f '$file' '$backup'" >/dev/null 2>&1 || true
      fi
    fi
  done
  for ((i=${#CREATED_CTS[@]}-1; i>=0; i--)); do
    vmid="${CREATED_CTS[$i]}"
    if ct_exists "$vmid"; then
      warn "Verwijder nieuw aangemaakte CT $vmid..."
      pct stop "$vmid" --skiplock 1 >/dev/null 2>&1 || true
      pct destroy "$vmid" --purge 1 >/dev/null 2>&1 || true
    fi
  done
  if [[ "$DATACENTER_FW_CHANGED" == "yes" ]]; then
    warn "Herstel Datacenter firewall naar uitgeschakelde toestand."
    pvesh set /cluster/firewall/options --enable 0 >/dev/null 2>&1 || true
  fi
  if [[ "$INTERNAL_CA_CREATED_THIS_RUN" == "yes" ]]; then
    warn "Verwijder interne CA die uitsluitend voor de mislukte transactie is aangemaakt."
    rm -f "$INTERNAL_CA_KEY" "$INTERNAL_CA_CERT" "${INTERNAL_CA_CERT%.crt}.srl" >/dev/null 2>&1 || true
  fi
  TX_ACTIVE="no"
  ROLLING_BACK="no"
}

transaction_commit() {
  local rec vmid file backup existed
  for rec in "${ENV_BACKUPS[@]}"; do
    IFS='|' read -r vmid file backup existed <<<"$rec"
    ct_exists "$vmid" && ct_exec "$vmid" "rm -f '$backup'" >/dev/null 2>&1 || true
  done
  TX_ACTIVE="no"
}

die() {
  printf "${C_RED}✖ %s${C_RESET}\n" "$*" >&2
  rollback_transaction
  exit 1
}

cleanup() {
  local rc=$?
  if (( rc != 0 )) && [[ "$TX_ACTIVE" == "yes" ]]; then
    rollback_transaction || true
  fi
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
  return "$rc"
}
trap cleanup EXIT

# ---------- Input helpers ----------
ask() {
  local prompt="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    read -r -p "$(printf "${C_BOLD}%s${C_RESET} ${C_DIM}[%s]${C_RESET}: " "$prompt" "$default")" value
    printf '%s' "${value:-$default}"
  else
    read -r -p "$(printf "${C_BOLD}%s${C_RESET}: " "$prompt")" value
    printf '%s' "$value"
  fi
}

ask_required() {
  local prompt="$1" default="${2:-}" value=""
  while [[ -z "$value" ]]; do
    value="$(ask "$prompt" "$default")"
    [[ -n "$value" ]] || warn "Deze waarde is verplicht."
  done
  printf '%s' "$value"
}

ask_yes_no() {
  local prompt="$1" default="${2:-y}" answer suffix
  if [[ "$default" == "y" ]]; then suffix="Y/n"; else suffix="y/N"; fi
  while true; do
    read -r -p "$(printf "${C_BOLD}%s${C_RESET} ${C_DIM}[%s]${C_RESET}: " "$prompt" "$suffix")" answer
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes|j|ja) return 0 ;;
      n|no|nee) return 1 ;;
      *) warn "Antwoord met ja of nee." ;;
    esac
  done
}

ask_secret() {
  local prompt="$1" a b
  if [[ "$DRY_RUN" == "yes" ]]; then
    printf '%s' '<dry-run-secret>'
    return 0
  fi
  while true; do
    read -r -s -p "$(printf "${C_BOLD}%s${C_RESET}: " "$prompt")" a; printf "\n" >&2
    [[ ${#a} -ge 12 ]] || { warn "Gebruik minimaal 12 tekens."; continue; }
    read -r -s -p "$(printf "${C_BOLD}%s bevestigen${C_RESET}: " "$prompt")" b; printf "\n" >&2
    [[ "$a" == "$b" ]] || { warn "De waarden komen niet overeen."; continue; }
    printf '%s' "$a"
    return 0
  done
}

menu() {
  local prompt="$1"; shift
  local options=("$@") choice i
  printf "\n${C_BOLD}%s${C_RESET}\n" "$prompt" >&2
  for i in "${!options[@]}"; do
    printf "  ${C_MAGENTA}%d)${C_RESET} %s\n" "$((i+1))" "${options[$i]}" >&2
  done
  while true; do
    read -r -p "> " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )) && {
      printf '%s' "$choice"
      return
    }
    warn "Kies een nummer tussen 1 en ${#options[@]}."
  done
}

# ---------- Validation ----------
require_root() {
  [[ $EUID -eq 0 ]] || die "Voer dit script uit als root op de Proxmox-host."
}

require_commands() {
  local cmd
  for cmd in pct pveam pvesh pvesm pveversion ip awk sed grep openssl python3; do
    command -v "$cmd" >/dev/null 2>&1 || die "Vereist commando ontbreekt: $cmd"
  done
}

check_pve9() {
  local ver
  ver="$(pveversion 2>/dev/null || true)"
  [[ "$ver" == pve-manager/9.* ]] || warn "Dit script is voor Proxmox VE 9 getest/bedoeld. Gedetecteerd: ${ver:-onbekend}"
}

valid_ipv4() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
PY
}

valid_cidr() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ipaddress.ip_network(sys.argv[1], strict=False)
PY
}

ip_in_subnet() {
  python3 - "$1" "$2" <<'PY' >/dev/null 2>&1
import ipaddress, sys
sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False) else 1)
PY
}

cidr_prefix() {
  python3 - "$1" <<'PY'
import ipaddress, sys
print(ipaddress.ip_network(sys.argv[1], strict=False).prefixlen)
PY
}

validate_name() {
  [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]
}

default_gateway() {
  python3 - "$1" <<'PY'
import ipaddress,sys
n=ipaddress.ip_network(sys.argv[1], strict=False)
print(next(n.hosts()))
PY
}

nth_host() {
  python3 - "$1" "$2" <<'PY'
import ipaddress,sys
n=ipaddress.ip_network(sys.argv[1], strict=False)
i=int(sys.argv[2])
h=list(n.hosts())
print(h[i] if len(h)>i else h[min(len(h)-1,1)])
PY
}

next_vmid() {
  pvesh get /cluster/nextid 2>/dev/null
}

ct_exists() {
  if pct status "$1" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

wait_ct() {
  local vmid="$1" tries=30
  while (( tries-- > 0 )); do
    pct exec "$vmid" -- true >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "Container $vmid reageert niet."
}

ct_exec() {
  local vmid="$1"; shift
  pct exec "$vmid" -- bash -lc "$*"
}

push_text() {
  local vmid="$1" dest="$2" mode="$3" content="$4" tmp
  tmp="$TMP_DIR/file.$RANDOM"
  printf '%s' "$content" > "$tmp"
  chmod "$mode" "$tmp"
  pct push "$vmid" "$tmp" "$dest" --perms "$mode"
  rm -f "$tmp"
}

ensure_unique_ctid() {
  local id="$1"
  [[ "$id" =~ ^[0-9]+$ ]] || die "CTID moet numeriek zijn."
  if ct_exists "$id"; then
    die "CTID $id bestaat al."
  fi
  return 0
}

ensure_unique_ip() {
  local ip="$1"
  valid_ipv4 "$ip" || die "Ongeldig IPv4-adres: $ip"
  ip_in_subnet "$ip" "$SUBNET" || die "$ip valt niet binnen $SUBNET."
  if ip addr | grep -qw "$ip"; then
    warn "IP $ip komt voor op de Proxmox-host. Controleer op conflicten."
  fi
  return 0
}

# ---------- Proxmox template / firewall ----------
ensure_template() {
  section "Ubuntu 24.04 template"
  [[ "$DRY_RUN" == "yes" ]] && { info "PLAN: Ubuntu 24.04 template controleren/downloaden op $TEMPLATE_STORAGE."; return 0; }
  local available template_file
  pveam update >/dev/null
  available="$(pveam available --section system | awk '/ubuntu-24\.04-standard/ {print $2}' | tail -n1)"
  [[ -n "$available" ]] || die "Geen Ubuntu 24.04 LXC-template gevonden via pveam."
  template_file="${available##*/}"

  if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$template_file"; then
    ok "Template aanwezig: $TEMPLATE_STORAGE:vztmpl/$template_file"
  else
    info "Download $available naar template-storage '$TEMPLATE_STORAGE'..."
    pveam download "$TEMPLATE_STORAGE" "$template_file"
  fi
  OSTEMPLATE="$TEMPLATE_STORAGE:vztmpl/$template_file"
}

ensure_datacenter_firewall() {
  [[ "$DRY_RUN" == "yes" ]] && { info "PLAN: Datacenter firewall status controleren/zo nodig inschakelen."; return 0; }
  local enabled
  enabled="$(pvesh get /cluster/firewall/options --output-format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("enable",0))' 2>/dev/null || echo 0)"
  if [[ "$enabled" == "1" ]]; then
    ok "Proxmox Datacenter firewall is ingeschakeld."
    return
  fi
  warn "De Proxmox Datacenter firewall lijkt uitgeschakeld."
  if ask_yes_no "Datacenter firewall nu inschakelen?" "y"; then
    pvesh set /cluster/firewall/options --enable 1 >/dev/null
    DATACENTER_FW_CHANGED="yes"
    ok "Datacenter firewall ingeschakeld."
  else
    die "Gestopt: LXC firewallregels zijn niet betrouwbaar actief zolang de Datacenter firewall uit staat."
  fi
}

fw_options() {
  local vmid="$1"
  pvesh set "/nodes/$NODE/lxc/$vmid/firewall/options" \
    --enable 1 --policy_in DROP --policy_out ACCEPT >/dev/null
}

fw_rule() {
  local vmid="$1" action="$2" proto="$3" dport="$4" source="$5" comment="$6"
  local args=(--type in --action "$action" --enable 1 --comment "$comment")
  [[ -n "$proto" ]] && args+=(--proto "$proto")
  [[ -n "$dport" ]] && args+=(--dport "$dport")
  [[ -n "$source" ]] && args+=(--source "$source")
  pvesh create "/nodes/$NODE/lxc/$vmid/firewall/rules" "${args[@]}" >/dev/null
}

fw_base() {
  local vmid="$1"
  fw_options "$vmid"
  fw_rule "$vmid" ACCEPT tcp 22 "$SSH_RANGE1" "SSH primary trusted range"
  [[ -n "$SSH_RANGE2" ]] && fw_rule "$vmid" ACCEPT tcp 22 "$SSH_RANGE2" "SSH optional trusted range"
  fw_rule "$vmid" ACCEPT icmp "" "$SUBNET" "ICMP from application subnet"
}

fw_web() {
  local vmid="$1"
  fw_base "$vmid"
  if [[ "$EXPOSURE_MODE" == "direct" ]]; then
    fw_rule "$vmid" ACCEPT tcp 80 "0.0.0.0/0" "Public HTTP / ACME redirect"
    [[ "$SSL_MODE" == "letsencrypt" ]] && fw_rule "$vmid" ACCEPT tcp 443 "0.0.0.0/0" "Public HTTPS"
  else
    if [[ "$PROXY_UPSTREAM" == "https" ]]; then
      fw_rule "$vmid" ACCEPT tcp 443 "$PROXY_SOURCE" "HTTPS only from reverse proxy"
    else
      fw_rule "$vmid" ACCEPT tcp 80 "$PROXY_SOURCE" "HTTP from reverse proxy"
    fi
  fi
}

fw_worker() {
  local vmid="$1"
  fw_base "$vmid"
  case "$HORIZON_ACCESS" in
    internal)
      fw_rule "$vmid" ACCEPT tcp 80 "$SSH_RANGE1" "Horizon/web from primary trusted range"
      [[ -n "$SSH_RANGE2" ]] && fw_rule "$vmid" ACCEPT tcp 80 "$SSH_RANGE2" "Horizon/web from optional trusted range"
      ;;
    proxy)
      if [[ "$PROXY_UPSTREAM" == "https" ]]; then
        fw_rule "$vmid" ACCEPT tcp 443 "$PROXY_SOURCE" "Worker HTTPS only from reverse proxy"
      else
        fw_rule "$vmid" ACCEPT tcp 80 "$PROXY_SOURCE" "Worker HTTP from reverse proxy"
      fi
      ;;
    none) ;;
  esac
}

fw_db() {
  local vmid="$1"
  fw_base "$vmid"
  [[ -n "$WEB_IP" ]] && fw_rule "$vmid" ACCEPT tcp 3306 "$WEB_IP/32" "MySQL from web node"
  [[ -n "$WORKER_IP" ]] && fw_rule "$vmid" ACCEPT tcp 3306 "$WORKER_IP/32" "MySQL from worker node"
}

fw_redis() {
  local vmid="$1"
  fw_base "$vmid"
  [[ -n "$WEB_IP" ]] && fw_rule "$vmid" ACCEPT tcp 6379 "$WEB_IP/32" "Redis from web node"
  [[ -n "$WORKER_IP" ]] && fw_rule "$vmid" ACCEPT tcp 6379 "$WORKER_IP/32" "Redis from worker node"
}

# ---------- Container creation ----------
create_ct() {
  local vmid="$1" hostname="$2" ip="$3" cores="$4" memory="$5" swap="$6" disk="$7" rootpass="$8" order="$9"
  local net="name=eth0,bridge=$BRIDGE,firewall=1,ip=$ip/$PREFIX,gw=$GATEWAY,type=veth"
  [[ -n "$VLAN_TAG" ]] && net+=",tag=$VLAN_TAG"

  # Bouw pct-argumenten als array op. Met de globale IFS zonder spatie mag een
  # constructie zoals ${NAMESERVER:+--nameserver "$NAMESERVER"} niet inline
  # worden gebruikt: die kan als één argument "--nameserver 1.2.3.4" eindigen.
  local pct_args=(
    create "$vmid" "$OSTEMPLATE"
    --hostname "$hostname"
    --unprivileged 1
    --features "keyctl=1,nesting=1"
    --cores "$cores"
    --memory "$memory"
    --swap "$swap"
    --rootfs "$ROOTFS_STORAGE:$disk"
    --net0 "$net"
    --password "$rootpass"
    --onboot 1
    --startup "order=$order,up=10,down=30"
    --ostype ubuntu
  )
  if [[ -n "$NAMESERVER" ]]; then
    pct_args+=(--nameserver "$NAMESERVER")
  fi

  info "Maak LXC $vmid ($hostname, $ip) ..."
  register_created_ct "$vmid"
  
  pct "${pct_args[@]}"

  pct start "$vmid"
  wait_ct "$vmid"
  ok "LXC $vmid gestart."
}

harden_ssh() {
  local vmid="$1"
  ct_exec "$vmid" "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server ca-certificates"
  local cfg='PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no
X11Forwarding no
AllowTcpForwarding yes
ClientAliveInterval 300
ClientAliveCountMax 2
'
  if [[ -n "$SSH_KEY_PATH" ]]; then
    [[ -f "$SSH_KEY_PATH" ]] || die "SSH public key niet gevonden: $SSH_KEY_PATH"
    local pub
    pub="$(cat "$SSH_KEY_PATH")"
    ct_exec "$vmid" "install -d -m 700 /root/.ssh"
    push_text "$vmid" "/root/.ssh/authorized_keys" 600 "$pub"$'\n'
    cfg+='PermitRootLogin prohibit-password
'
  else
    cfg+='PermitRootLogin yes
'
  fi
  push_text "$vmid" "/etc/ssh/sshd_config.d/90-pve-laravel-hardening.conf" 644 "$cfg"
  ct_exec "$vmid" "systemctl restart ssh"
}

# ---------- Laravel runtime ----------
install_php_web_runtime() {
  local vmid="$1"
  info "Installeer Nginx, PHP 8.3, Composer, Git en Node.js 22 in CT $vmid..."
  ct_exec "$vmid" "export DEBIAN_FRONTEND=noninteractive;
    apt-get update -qq;
    apt-get install -y -qq nginx git unzip curl ca-certificates gnupg composer \
      php8.3-fpm php8.3-cli php8.3-common php8.3-mysql php8.3-redis php8.3-curl \
      php8.3-mbstring php8.3-xml php8.3-zip php8.3-bcmath php8.3-intl php8.3-gd;
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1;
    apt-get install -y -qq nodejs;
    systemctl enable --now php8.3-fpm nginx"
  ok "Webruntime geïnstalleerd in CT $vmid."
}

configure_php() {
  local vmid="$1"
  local ini='memory_limit = 512M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 60
expose_php = Off
cgi.fix_pathinfo = 0
'
  push_text "$vmid" "/etc/php/8.3/fpm/conf.d/99-laravel.ini" 644 "$ini"
  push_text "$vmid" "/etc/php/8.3/cli/conf.d/99-laravel.ini" 644 "$ini"
  ct_exec "$vmid" "systemctl restart php8.3-fpm"
}

nginx_config() {
  local vmid="$1" domain="$2" node_ip="$3"
  local server_name="${domain:-_}"
  local tls_block=""
  if [[ "$EXPOSURE_MODE" == "proxy" && "$PROXY_UPSTREAM" == "https" && ( "$vmid" == "$WEB_CT" || "$HORIZON_ACCESS" == "proxy" ) ]]; then
    if [[ "$PROXY_TLS_CERT_MODE" == "internal_ca" ]]; then
      install_internal_ca_cert "$vmid" "$server_name" "$node_ip"
    else
      ct_exec "$vmid" "mkdir -p /etc/nginx/ssl; openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 825 -subj '/CN=${server_name}' -addext 'subjectAltName=DNS:${server_name},IP:${node_ip}' -keyout /etc/nginx/ssl/upstream.key -out /etc/nginx/ssl/upstream.crt >/dev/null 2>&1; chmod 600 /etc/nginx/ssl/upstream.key"
    fi
    tls_block='    listen 443 ssl;
    listen [::]:443 ssl;
    ssl_certificate /etc/nginx/ssl/upstream.crt;
    ssl_certificate_key /etc/nginx/ssl/upstream.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
'
  fi
  local cfg
  cfg="server {
    listen 80;
    listen [::]:80;
${tls_block}    server_name ${server_name};

    root ${APP_PATH}/public;
    index index.php;
    charset utf-8;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ ^/index\\.php(/|$) {
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
        fastcgi_read_timeout 60s;
    }

    location ~ \\.php$ { return 404; }
    location ~ /\\. { deny all; }
}
"
  push_text "$vmid" "/etc/nginx/sites-available/laravel" 644 "$cfg"
  ct_exec "$vmid" "rm -f /etc/nginx/sites-enabled/default; ln -sfn /etc/nginx/sites-available/laravel /etc/nginx/sites-enabled/laravel; nginx -t; systemctl reload nginx"
}

ensure_internal_ca() {
  mkdir -p "$STATE_DIR/pki"
  INTERNAL_CA_KEY="$STATE_DIR/pki/internal-proxy-ca.key"
  INTERNAL_CA_CERT="$STATE_DIR/pki/internal-proxy-ca.crt"
  if [[ -s "$INTERNAL_CA_KEY" && -s "$INTERNAL_CA_CERT" ]]; then
    return 0
  fi
  info "Maak lokale CA voor geverifieerde proxy-upstream TLS..."
  openssl req -x509 -new -nodes -newkey rsa:4096 -sha256 -days 3650 \
    -subj "/CN=PVE Laravel Internal Proxy CA" \
    -keyout "$INTERNAL_CA_KEY" -out "$INTERNAL_CA_CERT" >/dev/null 2>&1
  chmod 600 "$INTERNAL_CA_KEY"
  chmod 644 "$INTERNAL_CA_CERT"
  INTERNAL_CA_CREATED_THIS_RUN="yes"
}

install_internal_ca_cert() {
  local vmid="$1" domain="$2" node_ip="$3"
  ensure_internal_ca
  local key="$TMP_DIR/upstream-$vmid.key" csr="$TMP_DIR/upstream-$vmid.csr" crt="$TMP_DIR/upstream-$vmid.crt" ext="$TMP_DIR/upstream-$vmid.ext"
  openssl req -new -nodes -newkey rsa:3072 -sha256 -subj "/CN=$domain" -keyout "$key" -out "$csr" >/dev/null 2>&1
  if [[ "$domain" == "_" || -z "$domain" ]]; then
    printf 'subjectAltName=IP:%s\nextendedKeyUsage=serverAuth\n' "$node_ip" > "$ext"
  else
    printf 'subjectAltName=DNS:%s,IP:%s\nextendedKeyUsage=serverAuth\n' "$domain" "$node_ip" > "$ext"
  fi
  openssl x509 -req -in "$csr" -CA "$INTERNAL_CA_CERT" -CAkey "$INTERNAL_CA_KEY" -CAcreateserial \
    -days 825 -sha256 -extfile "$ext" -out "$crt" >/dev/null 2>&1
  ct_exec "$vmid" "mkdir -p /etc/nginx/ssl"
  pct push "$vmid" "$key" /etc/nginx/ssl/upstream.key --perms 600 >/dev/null
  pct push "$vmid" "$crt" /etc/nginx/ssl/upstream.crt --perms 644 >/dev/null
  pct push "$vmid" "$INTERNAL_CA_CERT" /etc/nginx/ssl/internal-ca.crt --perms 644 >/dev/null
}

set_env_value() {
  local vmid="$1" file="$2" key="$3" value="$4"
  # Pass through environment to avoid shell quoting the secret into sed expressions.
  pct exec "$vmid" -- env ENV_FILE="$file" ENV_KEY="$key" ENV_VALUE="$value" python3 - <<'PY'
import os, pathlib
p = pathlib.Path(os.environ["ENV_FILE"])
key = os.environ["ENV_KEY"]
value = os.environ["ENV_VALUE"]
text = p.read_text() if p.exists() else ""
lines = text.splitlines()
out = []
found = False
for line in lines:
    if line.startswith(key + "="):
        out.append(f"{key}={value}")
        found = True
    else:
        out.append(line)
if not found:
    out.append(f"{key}={value}")
p.write_text("\n".join(out).rstrip() + "\n")
PY
}

prepare_app_dir() {
  local vmid="$1"
  ct_exec "$vmid" "mkdir -p '$APP_PATH/public' '$APP_PATH/storage/framework/'{cache,sessions,views} '$APP_PATH/storage/logs' '$APP_PATH/bootstrap/cache';
    chown -R www-data:www-data '$APP_PATH';
    chmod -R ug+rwX '$APP_PATH/storage' '$APP_PATH/bootstrap/cache' 2>/dev/null || true"
  if [[ "$DEPLOY_MODE" == "prepare" ]]; then
    local placeholder='<!doctype html><html><head><meta charset="utf-8"><title>Laravel node ready</title></head><body><h1>Laravel node ready</h1><p>Deploy the application to /var/www/laravel and run /usr/local/sbin/laravel-finalize.</p></body></html>'
    push_text "$vmid" "$APP_PATH/public/index.html" 644 "$placeholder"
  fi
}

git_deploy() {
  local vmid="$1"
  [[ "$DEPLOY_MODE" == "git" ]] || return 0
  info "Clone Laravel repository in CT $vmid..."
  ct_exec "$vmid" "rm -rf '$APP_PATH'; mkdir -p '$(dirname "$APP_PATH")';
    git clone --depth 1 --branch '$GIT_BRANCH' '$GIT_URL' '$APP_PATH';
    chown -R www-data:www-data '$APP_PATH'"
}

make_finalize_helper() {
  local vmid="$1" worker="${2:-no}"
  local helper
  helper='#!/usr/bin/env bash
set -Eeuo pipefail
cd /var/www/laravel
test -f composer.json || { echo "composer.json ontbreekt"; exit 1; }
export COMPOSER_ALLOW_SUPERUSER=1
composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader
if [[ -f package.json ]]; then
  npm ci
  npm run build
fi
mkdir -p storage/framework/{cache,sessions,views} storage/logs bootstrap/cache
chown -R www-data:www-data /var/www/laravel
chmod -R ug+rwX storage bootstrap/cache
php artisan optimize:clear
php artisan config:cache
php artisan route:cache || true
php artisan view:cache || true
'
  if [[ "$worker" == "yes" ]]; then
    helper+='if ! grep -q "\"laravel/horizon\"" composer.json; then composer require laravel/horizon --no-interaction; fi
php artisan horizon:install --no-interaction || true
systemctl enable --now laravel-horizon.service
php artisan horizon:terminate || true
'
  fi
  push_text "$vmid" "/usr/local/sbin/laravel-finalize" 755 "$helper"
}

configure_laravel_env() {
  local vmid="$1"
  ct_exec "$vmid" "cd '$APP_PATH'; if [[ ! -f .env && -f .env.example ]]; then cp .env.example .env; fi; touch .env; chown www-data:www-data .env"
  set_env_value "$vmid" "$APP_PATH/.env" "APP_ENV" "production"
  set_env_value "$vmid" "$APP_PATH/.env" "APP_DEBUG" "false"
  if [[ -n "$APP_DOMAIN" && "$APP_DOMAIN" != "_" ]]; then
    local app_scheme="https"
    [[ "$EXPOSURE_MODE" == "direct" && "$SSL_MODE" == "none" ]] && app_scheme="http"
    set_env_value "$vmid" "$APP_PATH/.env" "APP_URL" "$app_scheme://$APP_DOMAIN"
  fi
  [[ -n "$APP_KEY" ]] && set_env_value "$vmid" "$APP_PATH/.env" "APP_KEY" "$APP_KEY"
  if [[ -n "$DB_IP" ]]; then
    set_env_value "$vmid" "$APP_PATH/.env" "DB_CONNECTION" "mysql"
    set_env_value "$vmid" "$APP_PATH/.env" "DB_HOST" "$DB_IP"
    set_env_value "$vmid" "$APP_PATH/.env" "DB_PORT" "3306"
    set_env_value "$vmid" "$APP_PATH/.env" "DB_DATABASE" "$DB_NAME"
    set_env_value "$vmid" "$APP_PATH/.env" "DB_USERNAME" "$DB_USER"
    set_env_value "$vmid" "$APP_PATH/.env" "DB_PASSWORD" "$DB_PASS"
  fi
  if [[ -n "$REDIS_IP" ]]; then
    set_env_value "$vmid" "$APP_PATH/.env" "REDIS_CLIENT" "phpredis"
    set_env_value "$vmid" "$APP_PATH/.env" "REDIS_HOST" "$REDIS_IP"
    set_env_value "$vmid" "$APP_PATH/.env" "REDIS_PASSWORD" "$REDIS_PASS"
    set_env_value "$vmid" "$APP_PATH/.env" "REDIS_PORT" "6379"
    set_env_value "$vmid" "$APP_PATH/.env" "QUEUE_CONNECTION" "redis"
    set_env_value "$vmid" "$APP_PATH/.env" "CACHE_STORE" "redis"
  fi
}

install_certbot() {
  local vmid="$1" domain="$2"
  [[ "$SSL_MODE" == "letsencrypt" ]] || return 0
  [[ -n "$domain" ]] || die "Let's Encrypt vereist een domeinnaam."
  info "Installeer Certbot voor $domain..."
  ct_exec "$vmid" "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq certbot python3-certbot-nginx;
    certbot --nginx --non-interactive --agree-tos --redirect --email '$LE_EMAIL' -d '$domain'"
  ok "Let's Encrypt ingesteld voor $domain."
}

# ---------- Worker / Horizon ----------
install_horizon_service() {
  local vmid="$1"
  local svc="[Unit]
Description=Laravel Horizon
After=network-online.target
Wants=network-online.target
ConditionPathExists=$APP_PATH/artisan

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=$APP_PATH
ExecStart=/usr/bin/php $APP_PATH/artisan horizon
ExecStop=/usr/bin/php $APP_PATH/artisan horizon:terminate
Restart=always
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=3600

[Install]
WantedBy=multi-user.target
"
  push_text "$vmid" "/etc/systemd/system/laravel-horizon.service" 644 "$svc"
  ct_exec "$vmid" "systemctl daemon-reload"
}

# ---------- Database ----------
sql_escape_literal() {
  # Escapes for a single-quoted MySQL string.
  printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/''/g"
}

install_mysql() {
  local vmid="$1"
  info "Installeer MySQL in CT $vmid..."
  ct_exec "$vmid" "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq mysql-server; systemctl enable --now mysql"

  local root_e db_e user_e
  root_e="$(sql_escape_literal "$DB_ROOT_PASS")"
  db_e="$DB_NAME"
  user_e="$DB_USER"

  local sql="ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${root_e}';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS \`${db_e}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
"
  if [[ -n "$WEB_IP" ]]; then
    sql+="CREATE USER IF NOT EXISTS '${user_e}'@'${WEB_IP}' IDENTIFIED BY '$(sql_escape_literal "$DB_PASS")';
ALTER USER '${user_e}'@'${WEB_IP}' IDENTIFIED BY '$(sql_escape_literal "$DB_PASS")';
GRANT ALL PRIVILEGES ON \`${db_e}\`.* TO '${user_e}'@'${WEB_IP}';
"
  fi
  if [[ -n "$WORKER_IP" ]]; then
    sql+="CREATE USER IF NOT EXISTS '${user_e}'@'${WORKER_IP}' IDENTIFIED BY '$(sql_escape_literal "$DB_PASS")';
ALTER USER '${user_e}'@'${WORKER_IP}' IDENTIFIED BY '$(sql_escape_literal "$DB_PASS")';
GRANT ALL PRIVILEGES ON \`${db_e}\`.* TO '${user_e}'@'${WORKER_IP}';
"
  fi
  sql+="FLUSH PRIVILEGES;\n"

  push_text "$vmid" "/root/bootstrap.sql" 600 "$sql"
  ct_exec "$vmid" "mysql < /root/bootstrap.sql; rm -f /root/bootstrap.sql"

  local mycnf="[client]
user=root
password=$(printf '%s' "$DB_ROOT_PASS")
"
  push_text "$vmid" "/root/.my.cnf" 600 "$mycnf"

  ct_exec "$vmid" "sed -ri 's/^[[:space:]]*bind-address[[:space:]]*=.*/bind-address = $DB_IP/' /etc/mysql/mysql.conf.d/mysqld.cnf;
    systemctl restart mysql"
  ok "MySQL luistert op $DB_IP:3306."
}

# ---------- Redis ----------
install_redis() {
  local vmid="$1"
  info "Installeer Redis in CT $vmid..."
  ct_exec "$vmid" "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq redis-server"
  local redis_conf="/etc/redis/redis.conf"
  # Use Python to safely replace values while passing the password as an env variable.
  pct exec "$vmid" -- env REDIS_IP="$REDIS_IP" REDIS_PASSWORD="$REDIS_PASS" REDIS_CONF="$redis_conf" python3 - <<'PY'
import os, pathlib, re
p = pathlib.Path(os.environ["REDIS_CONF"])
text = p.read_text()
def repl(key, value):
    global text
    pat = re.compile(rf"^\s*#?\s*{re.escape(key)}\s+.*$", re.M)
    line = f"{key} {value}"
    if pat.search(text):
        text = pat.sub(line, text, count=1)
    else:
        text += "\n" + line + "\n"
repl("bind", f"127.0.0.1 {os.environ['REDIS_IP']}")
repl("protected-mode", "yes")
repl("requirepass", os.environ["REDIS_PASSWORD"])
p.write_text(text)
PY
  ct_exec "$vmid" "systemctl enable --now redis-server; systemctl restart redis-server"
  pct exec "$vmid" -- env REDISCLI_AUTH="$REDIS_PASS" redis-cli -h "$REDIS_IP" ping | grep -q PONG
  ok "Redis luistert beveiligd op $REDIS_IP:6379."
}

# ---------- Role provisioners ----------
provision_web() {
  local rootpass="$1"
  if [[ "$DRY_RUN" == "yes" ]]; then info "PLAN: web CT ${WEB_CT} op ${WEB_IP} aanmaken/configureren + firewall + healthcheck."; return 0; fi
  create_ct "$WEB_CT" "laravel-web" "$WEB_IP" "$WEB_CORES" "$WEB_RAM" "$WEB_SWAP" "$WEB_DISK" "$rootpass" 30
  harden_ssh "$WEB_CT"
  install_php_web_runtime "$WEB_CT"
  configure_php "$WEB_CT"
  prepare_app_dir "$WEB_CT"
  git_deploy "$WEB_CT"
  nginx_config "$WEB_CT" "$APP_DOMAIN" "$WEB_IP"
  make_finalize_helper "$WEB_CT" "no"
  if [[ "$DEPLOY_MODE" == "git" ]]; then
    configure_laravel_env "$WEB_CT"
    ct_exec "$WEB_CT" "/usr/local/sbin/laravel-finalize"
  fi
  fw_web "$WEB_CT"
  install_certbot "$WEB_CT" "$APP_DOMAIN"
  ok "Webnode gereed: CT $WEB_CT / $WEB_IP"
}

provision_worker() {
  local rootpass="$1"
  if [[ "$DRY_RUN" == "yes" ]]; then info "PLAN: worker CT ${WORKER_CT} op ${WORKER_IP} aanmaken/configureren + firewall + healthcheck."; return 0; fi
  create_ct "$WORKER_CT" "laravel-worker" "$WORKER_IP" "$WORKER_CORES" "$WORKER_RAM" "$WORKER_SWAP" "$WORKER_DISK" "$rootpass" 40
  harden_ssh "$WORKER_CT"
  install_php_web_runtime "$WORKER_CT"
  configure_php "$WORKER_CT"
  prepare_app_dir "$WORKER_CT"
  git_deploy "$WORKER_CT"
  nginx_config "$WORKER_CT" "${WORKER_DOMAIN:-_}" "$WORKER_IP"
  install_horizon_service "$WORKER_CT"
  make_finalize_helper "$WORKER_CT" "yes"
  if [[ "$DEPLOY_MODE" == "git" ]]; then
    configure_laravel_env "$WORKER_CT"
    if [[ -n "$REDIS_IP" ]]; then
      ct_exec "$WORKER_CT" "/usr/local/sbin/laravel-finalize"
    else
      info "Redis is nog niet aanwezig: dependencies worden geïnstalleerd, Horizon blijft uit."
      ct_exec "$WORKER_CT" "cd '$APP_PATH'; COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader; chown -R www-data:www-data '$APP_PATH'"
    fi
  fi
  fw_worker "$WORKER_CT"
  ok "Workernode gereed: CT $WORKER_CT / $WORKER_IP"
}

provision_db() {
  local rootpass="$1"
  if [[ "$DRY_RUN" == "yes" ]]; then info "PLAN: database CT ${DB_CT} op ${DB_IP} aanmaken/configureren + firewall + healthcheck."; return 0; fi
  create_ct "$DB_CT" "laravel-db" "$DB_IP" "$DB_CORES" "$DB_RAM" "$DB_SWAP" "$DB_DISK" "$rootpass" 10
  harden_ssh "$DB_CT"
  install_mysql "$DB_CT"
  fw_db "$DB_CT"
  ok "Databasenode gereed: CT $DB_CT / $DB_IP"
}

provision_redis() {
  local rootpass="$1"
  if [[ "$DRY_RUN" == "yes" ]]; then info "PLAN: redis CT ${REDIS_CT} op ${REDIS_IP} aanmaken/configureren + firewall + healthcheck."; return 0; fi
  create_ct "$REDIS_CT" "laravel-redis" "$REDIS_IP" "$REDIS_CORES" "$REDIS_RAM" "$REDIS_SWAP" "$REDIS_DISK" "$rootpass" 20
  harden_ssh "$REDIS_CT"
  install_redis "$REDIS_CT"
  fw_redis "$REDIS_CT"
  ok "Redisnode gereed: CT $REDIS_CT / $REDIS_IP"
}

# ---------- Interactive collection ----------
collect_common_network() {
  section "Netwerk"
  BRIDGE="$(ask_required "Proxmox bridge" "$BRIDGE")"
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "Bridge $BRIDGE bestaat niet."

  while true; do
    SUBNET="$(ask_required "Applicatie subnet (CIDR)" "${SUBNET:-10.20.30.0/24}")"
    valid_cidr "$SUBNET" && break
    warn "Ongeldige CIDR, bijvoorbeeld 10.20.30.0/24."
  done
  PREFIX="$(cidr_prefix "$SUBNET")"

  while true; do
    GATEWAY="$(ask_required "Gateway" "${GATEWAY:-$(default_gateway "$SUBNET")}")"
    valid_ipv4 "$GATEWAY" && ip_in_subnet "$GATEWAY" "$SUBNET" && break
    warn "Gateway moet een geldig IPv4-adres binnen $SUBNET zijn."
  done

  NAMESERVER="$(ask "DNS server (leeg = host/default)" "${NAMESERVER:-}")"
  VLAN_TAG="$(ask "VLAN tag (leeg = geen)" "${VLAN_TAG:-}")"
  if [[ -n "$VLAN_TAG" ]]; then
    [[ "$VLAN_TAG" =~ ^[0-9]+$ ]] && (( VLAN_TAG >= 1 && VLAN_TAG <= 4094 )) || die "VLAN tag moet 1-4094 zijn."
  fi

  SSH_RANGE1="$(ask_required "Primair intern SSH-beheerbereik" "${SSH_RANGE1:-$SUBNET}")"
  valid_cidr "$SSH_RANGE1" || die "Ongeldig SSH CIDR."
  SSH_RANGE2="$(ask "Tweede SSH-beheerbereik (optioneel)" "${SSH_RANGE2:-}")"
  [[ -z "$SSH_RANGE2" ]] || valid_cidr "$SSH_RANGE2" || die "Ongeldig tweede SSH CIDR."

  if ask_yes_no "SSH public key voor root installeren?" "y"; then
    SSH_KEY_PATH="$(ask_required "Pad naar public key op Proxmox-host" "/root/.ssh/authorized_keys")"
    [[ -f "$SSH_KEY_PATH" ]] || die "Bestand niet gevonden: $SSH_KEY_PATH"
  else
    SSH_KEY_PATH=""
    warn "Root SSH met wachtwoord blijft toegestaan, maar uitsluitend vanaf de firewall-ranges."
  fi
}

collect_storage() {
  section "Storage"
  TEMPLATE_STORAGE="$(ask_required "Template storage" "${TEMPLATE_STORAGE:-local}")"
  pvesm status -storage "$TEMPLATE_STORAGE" >/dev/null 2>&1 || die "Storage '$TEMPLATE_STORAGE' bestaat niet."
  ROOTFS_STORAGE="$(ask_required "LXC rootfs storage" "${ROOTFS_STORAGE:-local-lvm}")"
  pvesm status -storage "$ROOTFS_STORAGE" >/dev/null 2>&1 || die "Storage '$ROOTFS_STORAGE' bestaat niet."
}

collect_exposure() {
  section "Web exposure en SSL"
  local c
  c="$(menu "Hoe wordt de Laravel website gepubliceerd?" \
    "Direct: web-LXC accepteert publiek HTTP/HTTPS" \
    "Reverse proxy: alleen verkeer vanaf proxy-IP/subnet")"
  if [[ "$c" == "1" ]]; then
    EXPOSURE_MODE="direct"
    c="$(menu "SSL-afhandeling" \
      "Let's Encrypt direct in de web-LXC (Certbot)" \
      "Geen automatische SSL-configuratie")"
    if [[ "$c" == "1" ]]; then
      SSL_MODE="letsencrypt"
      APP_DOMAIN="$(ask_required "Publieke domeinnaam" "${APP_DOMAIN:-example.nl}")"
      LE_EMAIL="$(ask_required "E-mailadres voor Let's Encrypt" "${LE_EMAIL:-}")"
    else
      SSL_MODE="none"
      APP_DOMAIN="$(ask "Domeinnaam/server_name (optioneel)" "${APP_DOMAIN:-_}")"
    fi
  else
    EXPOSURE_MODE="proxy"
    SSL_MODE="external"
    PROXY_SOURCE="$(ask_required "IP/CIDR van reverse proxy (bijv. Nginx Proxy Manager)" "${PROXY_SOURCE:-}")"
    valid_cidr "$PROXY_SOURCE" || valid_ipv4 "$PROXY_SOURCE" || die "Ongeldig proxy IP/CIDR."
    [[ "$PROXY_SOURCE" == */* ]] || PROXY_SOURCE="$PROXY_SOURCE/32"
    APP_DOMAIN="$(ask_required "Publieke domeinnaam" "${APP_DOMAIN:-example.nl}")"
    c="$(menu "Upstream van reverse proxy naar web-LXC" \
      "HTTP op poort 80 (SSL eindigt op proxy)" \
      "HTTPS op poort 443")"
    [[ "$c" == "2" ]] && PROXY_UPSTREAM="https" || PROXY_UPSTREAM="http"
    if [[ "$PROXY_UPSTREAM" == "https" ]]; then
      c="$(menu "Certificaat voor proxy → LXC TLS" \
        "Interne CA (aanbevolen): verifieerbaar certificaat met DNS/IP SAN" \
        "Self-signed leaf: wel encryptie, geen centrale trust")"
      if [[ "$c" == "1" ]]; then
        PROXY_TLS_CERT_MODE="internal_ca"
        info "De interne CA wordt op de Proxmox-host bewaard; importeer het CA-certificaat op de reverse proxy en schakel upstream-verificatie in."
      else
        PROXY_TLS_CERT_MODE="selfsigned"
        warn "Self-signed upstream TLS versleutelt verkeer, maar de proxy kan de identiteit niet betrouwbaar verifiëren zonder expliciete trust/pinning."
      fi
    fi
  fi

  c="$(menu "Toegang tot webserver/Horizon op de worker" \
    "Alleen vanaf interne SSH-beheerbereiken" \
    "Via dezelfde reverse proxy (alleen proxy-bron)" \
    "Geen HTTP-toegang; alleen workerproces")"
  case "$c" in
    1) HORIZON_ACCESS="internal" ;;
    2)
      HORIZON_ACCESS="proxy"
      if [[ -z "$PROXY_SOURCE" ]]; then
        PROXY_SOURCE="$(ask_required "IP/CIDR van reverse proxy" "")"
        valid_cidr "$PROXY_SOURCE" || valid_ipv4 "$PROXY_SOURCE" || die "Ongeldig proxy IP/CIDR."
        [[ "$PROXY_SOURCE" == */* ]] || PROXY_SOURCE="$PROXY_SOURCE/32"
      fi
      WORKER_DOMAIN="$(ask "Worker/Horizon domeinnaam (optioneel)" "horizon.$APP_DOMAIN")"
      ;;
    3) HORIZON_ACCESS="none" ;;
  esac
}

collect_deploy() {
  section "Laravel applicatie"
  local c
  c="$(menu "Applicatiecode" \
    "Server voorbereiden; code later zelf deployen" \
    "Git repository automatisch clonen en build uitvoeren")"
  if [[ "$c" == "2" ]]; then
    DEPLOY_MODE="git"
    GIT_URL="$(ask_required "Git repository URL" "${GIT_URL:-}")"
    GIT_BRANCH="$(ask_required "Branch/tag" "${GIT_BRANCH:-main}")"
    info "Bij een private repository moet de repository vanuit de LXC zonder interactieve prompt toegankelijk zijn."
  else
    DEPLOY_MODE="prepare"
  fi

  DB_NAME="$(ask_required "MySQL database naam" "${DB_NAME:-laravel}")"
  validate_name "$DB_NAME" || die "Database naam mag alleen letters, cijfers en underscore bevatten."
  DB_USER="$(ask_required "MySQL Laravel gebruiker" "${DB_USER:-laravel}")"
  validate_name "$DB_USER" || die "Database gebruiker mag alleen letters, cijfers en underscore bevatten."
  DB_PASS="$(ask_secret "MySQL Laravel wachtwoord")"
  DB_ROOT_PASS="$(ask_secret "MySQL root wachtwoord")"

  if ask_yes_no "Bestaande Laravel APP_KEY invoeren?" "n"; then
    APP_KEY="$(ask_secret "Laravel APP_KEY (minimaal 12 tekens; bij voorkeur base64:...)")"
  else
    APP_KEY="base64:$(openssl rand -base64 32 | tr -d '\n')"
    info "Er is één gedeelde APP_KEY gegenereerd voor web en worker."
  fi
}

collect_resources_full() {
  section "Container-ID's, IP's en resources"
  local next
  next="$(next_vmid)"

  WEB_CT="$(ask_required "Web CTID" "$next")"; ensure_unique_ctid "$WEB_CT"
  next=$((WEB_CT+1))
  DB_CT="$(ask_required "Database CTID" "$next")"; ensure_unique_ctid "$DB_CT"
  next=$((DB_CT+1))
  WORKER_CT="$(ask_required "Worker CTID" "$next")"; ensure_unique_ctid "$WORKER_CT"

  WEB_IP="$(ask_required "Web IP" "$(nth_host "$SUBNET" 9)")"; ensure_unique_ip "$WEB_IP"
  DB_IP="$(ask_required "Database IP" "$(nth_host "$SUBNET" 19)")"; ensure_unique_ip "$DB_IP"
  WORKER_IP="$(ask_required "Worker IP" "$(nth_host "$SUBNET" 29)")"; ensure_unique_ip "$WORKER_IP"
  [[ "$WEB_IP" != "$DB_IP" && "$WEB_IP" != "$WORKER_IP" && "$DB_IP" != "$WORKER_IP" ]] || die "IP-adressen moeten uniek zijn."

  WEB_CORES="$(ask_required "Web CPU cores" "2")"
  WEB_RAM="$(ask_required "Web RAM MB" "4096")"
  WEB_SWAP="$(ask_required "Web swap MB" "512")"
  WEB_DISK="$(ask_required "Web disk GB" "20")"

  DB_CORES="$(ask_required "Database CPU cores" "2")"
  DB_RAM="$(ask_required "Database RAM MB" "4096")"
  DB_SWAP="$(ask_required "Database swap MB" "512")"
  DB_DISK="$(ask_required "Database disk GB" "40")"

  WORKER_CORES="$(ask_required "Worker CPU cores" "4")"
  WORKER_RAM="$(ask_required "Worker RAM MB" "4096")"
  WORKER_SWAP="$(ask_required "Worker swap MB" "512")"
  WORKER_DISK="$(ask_required "Worker disk GB" "20")"

  if ask_yes_no "Redis-node nu aanmaken?" "y"; then
    INSTALL_REDIS_NOW="yes"
    REDIS_CT="$(ask_required "Redis CTID" "$((WORKER_CT+1))")"; ensure_unique_ctid "$REDIS_CT"
    REDIS_IP="$(ask_required "Redis IP" "$(nth_host "$SUBNET" 39)")"; ensure_unique_ip "$REDIS_IP"
    [[ "$REDIS_IP" != "$WEB_IP" && "$REDIS_IP" != "$DB_IP" && "$REDIS_IP" != "$WORKER_IP" ]] || die "Redis IP moet uniek zijn."
    REDIS_CORES="$(ask_required "Redis CPU cores" "2")"
    REDIS_RAM="$(ask_required "Redis RAM MB" "2048")"
    REDIS_SWAP="$(ask_required "Redis swap MB" "256")"
    REDIS_DISK="$(ask_required "Redis disk GB" "10")"
    REDIS_PASS="$(ask_secret "Redis wachtwoord")"
  else
    INSTALL_REDIS_NOW="no"
    REDIS_IP=""
    warn "Horizon kan pas actief worden zodra Redis later is toegevoegd."
  fi
}

summary_full() {
  section "Controle"
  cat <<EOF
  Node / bridge      : $NODE / $BRIDGE
  Subnet / gateway   : $SUBNET / $GATEWAY
  Storage            : template=$TEMPLATE_STORAGE, rootfs=$ROOTFS_STORAGE
  SSH ranges         : $SSH_RANGE1${SSH_RANGE2:+, $SSH_RANGE2}
  Web                : CT $WEB_CT · $WEB_IP · ${WEB_CORES}c/${WEB_RAM}MB/${WEB_DISK}GB
  Database           : CT $DB_CT · $DB_IP · ${DB_CORES}c/${DB_RAM}MB/${DB_DISK}GB
  Worker             : CT $WORKER_CT · $WORKER_IP · ${WORKER_CORES}c/${WORKER_RAM}MB/${WORKER_DISK}GB
  Redis              : ${INSTALL_REDIS_NOW}${REDIS_IP:+ · CT $REDIS_CT · $REDIS_IP}
  Exposure           : $EXPOSURE_MODE
  SSL                : $SSL_MODE
  Domain             : ${APP_DOMAIN:-geen}
  Deploy             : $DEPLOY_MODE${GIT_URL:+ · $GIT_URL @ $GIT_BRANCH}
  Uitvoering          : $([[ "$DRY_RUN" == "yes" ]] && echo "DRY-RUN / PLAN" || echo "EXECUTE")
  Proxy upstream TLS  : $PROXY_UPSTREAM${PROXY_UPSTREAM:+ / $PROXY_TLS_CERT_MODE}
  MySQL database     : $DB_NAME
  Horizon web        : $HORIZON_ACCESS

${C_YELLOW}Wachtwoorden worden om veiligheidsredenen niet in dit overzicht getoond.${C_RESET}
EOF
}

# ---------- Existing stack / modular role ----------
collect_existing_base() {
  collect_common_network
  collect_storage
  WEB_IP="$(ask "Bestaande web IP (optioneel)" "${WEB_IP:-}")"
  [[ -z "$WEB_IP" ]] || valid_ipv4 "$WEB_IP" || die "Ongeldig web IP."
  DB_IP="$(ask "Bestaande database IP (optioneel)" "${DB_IP:-}")"
  [[ -z "$DB_IP" ]] || valid_ipv4 "$DB_IP" || die "Ongeldig database IP."
  WORKER_IP="$(ask "Bestaande worker IP (optioneel)" "${WORKER_IP:-}")"
  [[ -z "$WORKER_IP" ]] || valid_ipv4 "$WORKER_IP" || die "Ongeldig worker IP."
  REDIS_IP="$(ask "Bestaande Redis IP (optioneel)" "${REDIS_IP:-}")"
  [[ -z "$REDIS_IP" ]] || valid_ipv4 "$REDIS_IP" || die "Ongeldig Redis IP."
}

add_redis_existing() {
  section "Redis toevoegen aan bestaande stack"
  REDIS_CT="$(ask_required "Nieuwe Redis CTID" "$(next_vmid)")"; ensure_unique_ctid "$REDIS_CT"
  REDIS_IP="$(ask_required "Nieuwe Redis IP" "")"; ensure_unique_ip "$REDIS_IP"
  REDIS_CORES="$(ask_required "Redis CPU cores" "2")"
  REDIS_RAM="$(ask_required "Redis RAM MB" "2048")"
  REDIS_SWAP="$(ask_required "Redis swap MB" "256")"
  REDIS_DISK="$(ask_required "Redis disk GB" "10")"
  REDIS_PASS="$(ask_secret "Redis wachtwoord")"
  local rootpass
  rootpass="$(ask_secret "Redis LXC root wachtwoord")"

  ensure_template
  ensure_datacenter_firewall
  provision_redis "$rootpass"
  [[ "$DRY_RUN" == "yes" ]] && return 0

  if ask_yes_no "Bestaande Laravel .env op web/worker bijwerken?" "y"; then
    APP_PATH="$(ask_required "Laravel pad in bestaande containers" "/var/www/laravel")"
    local id
    if [[ -n "$WEB_IP" ]]; then
      id="$(ask "Bestaande web CTID (leeg = overslaan)" "")"
      if [[ -n "$id" ]]; then
        ct_exists "$id" || die "Web CT $id bestaat niet."
        configure_redis_env_only "$id"
      fi
    fi
    if [[ -n "$WORKER_IP" ]]; then
      id="$(ask "Bestaande worker CTID (leeg = overslaan)" "")"
      if [[ -n "$id" ]]; then
        ct_exists "$id" || die "Worker CT $id bestaat niet."
        configure_redis_env_only "$id"
        if [[ -f "/etc/pve/lxc/$id.conf" ]]; then
          ct_exec "$id" "cd '$APP_PATH'; php artisan optimize:clear || true; php artisan horizon:terminate || true"
          ct_exec "$id" "systemctl restart laravel-horizon.service 2>/dev/null || true"
        fi
      fi
    fi
  fi
}

configure_redis_env_only() {
  local vmid="$1"
  [[ "$DRY_RUN" == "yes" ]] && { info "PLAN: Redis-instellingen in $APP_PATH/.env van CT $vmid bijwerken (met rollback-backup)."; return 0; }
  backup_ct_file "$vmid" "$APP_PATH/.env"
  ct_exec "$vmid" "test -f '$APP_PATH/.env' || touch '$APP_PATH/.env'"
  set_env_value "$vmid" "$APP_PATH/.env" "REDIS_CLIENT" "phpredis"
  set_env_value "$vmid" "$APP_PATH/.env" "REDIS_HOST" "$REDIS_IP"
  set_env_value "$vmid" "$APP_PATH/.env" "REDIS_PASSWORD" "$REDIS_PASS"
  set_env_value "$vmid" "$APP_PATH/.env" "REDIS_PORT" "6379"
  set_env_value "$vmid" "$APP_PATH/.env" "QUEUE_CONNECTION" "redis"
  set_env_value "$vmid" "$APP_PATH/.env" "CACHE_STORE" "redis"
  ct_exec "$vmid" "cd '$APP_PATH'; php artisan optimize:clear 2>/dev/null || true"
  ok "Redis-instellingen bijgewerkt in CT $vmid."
}

add_single_role() {
  collect_existing_base
  [[ "$DRY_RUN" == "no" ]] && transaction_start
  local role
  role="$(menu "Welke component wil je toevoegen?" \
    "Web node" \
    "Database node" \
    "Worker/Horizon node" \
    "Redis node")"

  case "$role" in
    1)
      collect_exposure
      collect_deploy
      WEB_CT="$(ask_required "Nieuwe web CTID" "$(next_vmid)")"; ensure_unique_ctid "$WEB_CT"
      WEB_IP="$(ask_required "Nieuwe web IP" "")"; ensure_unique_ip "$WEB_IP"
      WEB_CORES="$(ask_required "Web CPU cores" "2")"; WEB_RAM="$(ask_required "Web RAM MB" "4096")"
      WEB_SWAP="$(ask_required "Web swap MB" "512")"; WEB_DISK="$(ask_required "Web disk GB" "20")"
      local rp; rp="$(ask_secret "Web LXC root wachtwoord")"
      ensure_template
      ensure_datacenter_firewall
      provision_web "$rp"
      ;;
    2)
      DB_CT="$(ask_required "Nieuwe database CTID" "$(next_vmid)")"; ensure_unique_ctid "$DB_CT"
      DB_IP="$(ask_required "Nieuwe database IP" "")"; ensure_unique_ip "$DB_IP"
      DB_CORES="$(ask_required "Database CPU cores" "2")"; DB_RAM="$(ask_required "Database RAM MB" "4096")"
      DB_SWAP="$(ask_required "Database swap MB" "512")"; DB_DISK="$(ask_required "Database disk GB" "40")"
      DB_NAME="$(ask_required "MySQL database naam" "laravel")"; validate_name "$DB_NAME" || die "Ongeldige DB-naam."
      DB_USER="$(ask_required "MySQL Laravel gebruiker" "laravel")"; validate_name "$DB_USER" || die "Ongeldige DB-user."
      DB_PASS="$(ask_secret "MySQL Laravel wachtwoord")"; DB_ROOT_PASS="$(ask_secret "MySQL root wachtwoord")"
      local rp; rp="$(ask_secret "Database LXC root wachtwoord")"
      ensure_template
      ensure_datacenter_firewall
      provision_db "$rp"
      ;;
    3)
      collect_exposure
      collect_deploy
      WORKER_CT="$(ask_required "Nieuwe worker CTID" "$(next_vmid)")"; ensure_unique_ctid "$WORKER_CT"
      WORKER_IP="$(ask_required "Nieuwe worker IP" "")"; ensure_unique_ip "$WORKER_IP"
      WORKER_CORES="$(ask_required "Worker CPU cores" "4")"; WORKER_RAM="$(ask_required "Worker RAM MB" "4096")"
      WORKER_SWAP="$(ask_required "Worker swap MB" "512")"; WORKER_DISK="$(ask_required "Worker disk GB" "20")"
      [[ -z "$REDIS_IP" ]] || REDIS_PASS="$(ask_secret "Wachtwoord van bestaande Redis")"
      local rp; rp="$(ask_secret "Worker LXC root wachtwoord")"
      ensure_template
      ensure_datacenter_firewall
      provision_worker "$rp"
      ;;
    4)
      add_redis_existing
      ;;
  esac
  if [[ "$DRY_RUN" == "yes" ]]; then
    plan_report
  else
    run_health_checks
    save_state
    final_report
    transaction_commit
  fi
}

# ---------- Full deployment ----------
full_stack() {
  collect_common_network
  collect_storage
  collect_exposure
  collect_deploy
  collect_resources_full
  summary_full
  if [[ "$DRY_RUN" == "yes" ]]; then
    plan_report
    return 0
  fi
  ask_yes_no "Configuratie uitvoeren?" "n" || die "Geannuleerd door gebruiker."

  transaction_start
  ensure_template
  ensure_datacenter_firewall

  section "Container-wachtwoorden"
  local db_root web_root worker_root redis_root=""
  db_root="$(ask_secret "Database LXC root wachtwoord")"
  web_root="$(ask_secret "Web LXC root wachtwoord")"
  worker_root="$(ask_secret "Worker LXC root wachtwoord")"
  [[ "$INSTALL_REDIS_NOW" == "yes" ]] && redis_root="$(ask_secret "Redis LXC root wachtwoord")"

  # Dependency-first startup/order.
  section "Provisioning"
  provision_db "$db_root"
  [[ "$INSTALL_REDIS_NOW" == "yes" ]] && provision_redis "$redis_root"
  provision_web "$web_root"
  provision_worker "$worker_root"

  run_health_checks
  save_state
  final_report
  transaction_commit
}

save_state() {
  mkdir -p "$STATE_DIR"
  local state="$STATE_DIR/stack-$(date +%Y%m%d-%H%M%S).conf"
  # Do not persist passwords.
  cat > "$state" <<EOF
NODE=$NODE
BRIDGE=$BRIDGE
VLAN_TAG=$VLAN_TAG
SUBNET=$SUBNET
GATEWAY=$GATEWAY
SSH_RANGE1=$SSH_RANGE1
SSH_RANGE2=$SSH_RANGE2
ROOTFS_STORAGE=$ROOTFS_STORAGE
TEMPLATE_STORAGE=$TEMPLATE_STORAGE
WEB_CT=$WEB_CT
WEB_IP=$WEB_IP
DB_CT=$DB_CT
DB_IP=$DB_IP
WORKER_CT=$WORKER_CT
WORKER_IP=$WORKER_IP
REDIS_CT=$REDIS_CT
REDIS_IP=$REDIS_IP
APP_PATH=$APP_PATH
APP_DOMAIN=$APP_DOMAIN
EXPOSURE_MODE=$EXPOSURE_MODE
PROXY_SOURCE=$PROXY_SOURCE
SSL_MODE=$SSL_MODE
PROXY_UPSTREAM=$PROXY_UPSTREAM
PROXY_TLS_CERT_MODE=$PROXY_TLS_CERT_MODE
INTERNAL_CA_CERT=$INTERNAL_CA_CERT
DEPLOY_MODE=$DEPLOY_MODE
GIT_URL=$GIT_URL
GIT_BRANCH=$GIT_BRANCH
DB_NAME=$DB_NAME
DB_USER=$DB_USER
EOF
  chmod 600 "$state"
  ok "Niet-geheime stackgegevens opgeslagen: $state"
}

plan_report() {
  section "DRY-RUN / uitvoeringsplan"
  cat <<EOF
Geen wijzigingen zijn uitgevoerd.

Volgorde bij execute:
  1. Proxmox prerequisites, template en Datacenter firewall valideren.
  2. Dependency-first: database${REDIS_IP:+ → Redis} → web → worker.
  3. Per nieuwe CT: OS/runtime hardening, serviceconfiguratie en policy_in=DROP firewall.
  4. Proxy-upstream: ${PROXY_UPSTREAM}; TLS-certificaatmodus: ${PROXY_TLS_CERT_MODE}.
  5. Post-deploy connectivity- en servicetests uitvoeren.
  6. Alleen bij succesvolle tests state bewaren/transaction committen.

Rollback bij een fout:
  - nieuw aangemaakte CT's uit deze run worden in omgekeerde volgorde verwijderd;
  - bestaande .env-bestanden die door een modulaire Redis-migratie wijzigen worden teruggezet;
  - een Datacenter-firewallstatus die deze run van uit→aan veranderde wordt hersteld.
  - externe side-effects (DNS, Git/Composer registries, Let's Encrypt issuance) zijn niet volledig transactioneel terug te draaien.
EOF
  firewall_plan_report
}

firewall_plan_report() {
  section "Firewall-plan"
  printf "%-10s %-8s %-8s %-24s %s\n" "ROLE" "PROTO" "PORT" "SOURCE" "DOEL"
  printf "%-10s %-8s %-8s %-24s %s\n" "alle" "tcp" "22" "$SSH_RANGE1" "SSH beheer"
  [[ -n "$SSH_RANGE2" ]] && printf "%-10s %-8s %-8s %-24s %s\n" "alle" "tcp" "22" "$SSH_RANGE2" "SSH beheer 2"
  printf "%-10s %-8s %-8s %-24s %s\n" "alle" "icmp" "-" "$SUBNET" "diagnostiek"
  if [[ "$EXPOSURE_MODE" == "direct" ]]; then
    if [[ "$SSL_MODE" == "letsencrypt" ]]; then
      printf "%-10s %-8s %-8s %-24s %s\n" "web" "tcp" "80/443" "0.0.0.0/0" "publiek web + ACME"
    else
      printf "%-10s %-8s %-8s %-24s %s\n" "web" "tcp" "80" "0.0.0.0/0" "publiek HTTP (geen TLS)"
    fi
  elif [[ "$PROXY_UPSTREAM" == "https" ]]; then
    printf "%-10s %-8s %-8s %-24s %s\n" "web" "tcp" "443" "$PROXY_SOURCE" "HTTPS-only proxy upstream"
  else
    printf "%-10s %-8s %-8s %-24s %s\n" "web" "tcp" "80" "$PROXY_SOURCE" "HTTP proxy upstream"
  fi
  case "$HORIZON_ACCESS" in
    internal)
      printf "%-10s %-8s %-8s %-24s %s\n" "worker" "tcp" "80" "$SSH_RANGE1" "Horizon/web intern"
      [[ -n "$SSH_RANGE2" ]] && printf "%-10s %-8s %-8s %-24s %s\n" "worker" "tcp" "80" "$SSH_RANGE2" "Horizon/web intern 2"
      ;;
    proxy)
      if [[ "$PROXY_UPSTREAM" == "https" ]]; then
        printf "%-10s %-8s %-8s %-24s %s\n" "worker" "tcp" "443" "$PROXY_SOURCE" "Horizon via HTTPS proxy"
      else
        printf "%-10s %-8s %-8s %-24s %s\n" "worker" "tcp" "80" "$PROXY_SOURCE" "Horizon via HTTP proxy"
      fi
      ;;
    none) ;;
  esac
  [[ -n "$WEB_IP" ]] && printf "%-10s %-8s %-8s %-24s %s\n" "database" "tcp" "3306" "$WEB_IP/32" "MySQL vanaf web"
  [[ -n "$WORKER_IP" ]] && printf "%-10s %-8s %-8s %-24s %s\n" "database" "tcp" "3306" "$WORKER_IP/32" "MySQL vanaf worker"
  if [[ -n "$REDIS_IP" ]]; then
    [[ -n "$WEB_IP" ]] && printf "%-10s %-8s %-8s %-24s %s\n" "redis" "tcp" "6379" "$WEB_IP/32" "Redis vanaf web"
    [[ -n "$WORKER_IP" ]] && printf "%-10s %-8s %-8s %-24s %s\n" "redis" "tcp" "6379" "$WORKER_IP/32" "Redis vanaf worker"
  fi
  echo "Default inbound policy per CT: DROP; outbound: ACCEPT."
}

health_add() {
  HEALTH_NAMES+=("$1"); HEALTH_STATUS+=("$2"); HEALTH_DETAIL+=("$3")
}

health_cmd() {
  local name="$1" detail="$2"; shift 2
  if "$@" >/dev/null 2>&1; then health_add "$name" "PASS" "$detail"; else health_add "$name" "FAIL" "$detail"; fi
}

run_health_checks() {
  section "Post-deploy connectivity-tests"
  HEALTH_NAMES=(); HEALTH_STATUS=(); HEALTH_DETAIL=()
  [[ -n "$WEB_CT" ]] && health_cmd "web/nginx" "nginx config + service" pct exec "$WEB_CT" -- bash -lc "nginx -t && systemctl is-active --quiet nginx && systemctl is-active --quiet php8.3-fpm"
  [[ -n "$DB_CT" ]] && health_cmd "db/mysql" "MySQL service actief" pct exec "$DB_CT" -- bash -lc "systemctl is-active --quiet mysql"
  [[ -n "$REDIS_CT" ]] && health_cmd "redis/service" "Redis service actief" pct exec "$REDIS_CT" -- bash -lc "systemctl is-active --quiet redis-server"
  if [[ -n "$WEB_CT" && -n "$DB_IP" ]]; then health_cmd "web→mysql" "$DB_IP:3306 bereikbaar" pct exec "$WEB_CT" -- bash -lc "timeout 5 bash -c '</dev/tcp/$DB_IP/3306'"; fi
  if [[ -n "$WORKER_CT" && -n "$DB_IP" ]]; then health_cmd "worker→mysql" "$DB_IP:3306 bereikbaar" pct exec "$WORKER_CT" -- bash -lc "timeout 5 bash -c '</dev/tcp/$DB_IP/3306'"; fi
  if [[ -n "$REDIS_IP" && -n "$WEB_CT" ]]; then health_cmd "web→redis" "$REDIS_IP:6379 bereikbaar" pct exec "$WEB_CT" -- bash -lc "timeout 5 bash -c '</dev/tcp/$REDIS_IP/6379'"; fi
  if [[ -n "$REDIS_IP" && -n "$WORKER_CT" ]]; then health_cmd "worker→redis" "$REDIS_IP:6379 bereikbaar" pct exec "$WORKER_CT" -- bash -lc "timeout 5 bash -c '</dev/tcp/$REDIS_IP/6379'"; fi
  if [[ -n "$WORKER_CT" ]]; then
    if [[ -n "$REDIS_IP" && "$DEPLOY_MODE" == "git" ]]; then
      health_cmd "worker/horizon" "Horizon service actief" pct exec "$WORKER_CT" -- bash -lc "systemctl is-active --quiet laravel-horizon.service"
    else
      health_add "worker/horizon" "INFO" "Niet verplicht actief (Redis/code mogelijk later)."
    fi
  fi
  if [[ "$EXPOSURE_MODE" == "proxy" && "$PROXY_UPSTREAM" == "https" && -n "$WEB_CT" ]]; then
    if [[ "$PROXY_TLS_CERT_MODE" == "internal_ca" ]]; then
      health_cmd "web/TLS" "CA + hostname/SAN verificatie lokaal" pct exec "$WEB_CT" -- bash -lc "curl -fsS --max-time 5 --cacert /etc/nginx/ssl/internal-ca.crt --resolve '$APP_DOMAIN:443:127.0.0.1' 'https://$APP_DOMAIN/' >/dev/null"
    else
      health_cmd "web/TLS" "TLS handshake (self-signed, identiteit niet geverifieerd)" pct exec "$WEB_CT" -- bash -lc "curl -fkSs --max-time 5 --resolve '$APP_DOMAIN:443:127.0.0.1' 'https://$APP_DOMAIN/' >/dev/null"
    fi
  elif [[ -n "$WEB_CT" ]]; then
    health_cmd "web/http" "lokale HTTP response" pct exec "$WEB_CT" -- bash -lc "curl -fsS --max-time 5 http://127.0.0.1/ >/dev/null"
  fi
  if [[ "$EXPOSURE_MODE" == "proxy" ]]; then
    health_add "proxy-origin" "INFO" "Niet vanaf de externe proxy getest; firewall beperkt upstream tot $PROXY_SOURCE."
  fi

  local failed=0 i
  for i in "${!HEALTH_NAMES[@]}"; do
    printf "  %-18s %-5s %s\n" "${HEALTH_NAMES[$i]}" "${HEALTH_STATUS[$i]}" "${HEALTH_DETAIL[$i]}"
    [[ "${HEALTH_STATUS[$i]}" == "FAIL" ]] && failed=1
  done
  if (( failed )); then
    die "Een of meer verplichte post-deploy healthchecks zijn mislukt; rollback wordt uitgevoerd."
  fi
}

health_report() {
  section "Health-eindrapport"
  local i
  printf "%-20s %-7s %s\n" "CHECK" "STATUS" "DETAIL"
  for i in "${!HEALTH_NAMES[@]}"; do
    printf "%-20s %-7s %s\n" "${HEALTH_NAMES[$i]}" "${HEALTH_STATUS[$i]}" "${HEALTH_DETAIL[$i]}"
  done
}

final_report() {
  section "Gereed"
  local report_scheme="https" report_url=""
  [[ "$EXPOSURE_MODE" == "direct" && "$SSL_MODE" == "none" ]] && report_scheme="http"
  [[ -n "$APP_DOMAIN" && "$APP_DOMAIN" != "_" ]] && report_url="$report_scheme://$APP_DOMAIN"
  cat <<EOF
${C_GREEN}${C_BOLD}De stack is opgebouwd.${C_RESET}

Web:
  CT/IP       : $WEB_CT / $WEB_IP
  URL         : ${report_url:-n.v.t.}
  Laravel pad : $APP_PATH

Database:
  CT/IP       : $DB_CT / $DB_IP
  Poort       : 3306 (alleen web/worker via Proxmox firewall)
  Database    : $DB_NAME

Worker:
  CT/IP       : $WORKER_CT / $WORKER_IP
  Service     : laravel-horizon.service
  Horizon     : ${REDIS_IP:+Redis $REDIS_IP:6379}${REDIS_IP:-nog niet actief; voeg Redis later toe}

Redis:
  ${REDIS_IP:+CT/IP       : $REDIS_CT / $REDIS_IP}
  ${REDIS_IP:+Poort       : 6379 (alleen web/worker)}
  ${REDIS_IP:-Niet aangemaakt. Kies later in ditzelfde script "component toevoegen" → Redis.}

SSH:
  Toegestaan  : $SSH_RANGE1${SSH_RANGE2:+ en $SSH_RANGE2}
  Internet    : poort 22 is door policy_in=DROP niet publiek toegestaan.

Proxy/TLS:
  Upstream     : $PROXY_UPSTREAM
  Certificaat : $PROXY_TLS_CERT_MODE
  ${INTERNAL_CA_CERT:+CA trust      : $INTERNAL_CA_CERT}

${C_YELLOW}Aanbevolen controles:${C_RESET}
  pct list
  pvesh get /nodes/$NODE/lxc/$WEB_CT/firewall/rules
  pct exec $WEB_CT -- nginx -t
  pct exec $DB_CT -- systemctl status mysql --no-pager
  ${REDIS_CT:+pct exec $REDIS_CT -- systemctl status redis-server --no-pager}
  pct exec $WORKER_CT -- systemctl status laravel-horizon --no-pager

EOF
  firewall_plan_report
  health_report
  if [[ "$EXPOSURE_MODE" == "proxy" && "$PROXY_UPSTREAM" == "https" && "$PROXY_TLS_CERT_MODE" == "internal_ca" ]]; then
    cat <<EOF

${C_YELLOW}Reverse proxy actie vereist:${C_RESET}
  Importeer/trust CA: $INTERNAL_CA_CERT
  Verifieer upstream certificaat en hostname/SNI: $APP_DOMAIN
  Gebruik uitsluitend https://$WEB_IP:443 als upstream. HTTP/80 vanaf de proxy wordt door de LXC-firewall niet toegestaan.
EOF
  fi

  if [[ "$DEPLOY_MODE" == "prepare" ]]; then
    cat <<EOF
${C_YELLOW}Applicatiecode is nog niet gedeployed.${C_RESET}
Na deployment op web en worker:
  /usr/local/sbin/laravel-finalize

Zorg dat dezelfde applicatieversie en dezelfde APP_KEY op web en worker worden gebruikt.
EOF
  fi
}

# ---------- Main ----------
main() {
  require_root
  require_commands
  TMP_DIR="$(mktemp -d /tmp/pve-laravel-builder.XXXXXX)"
  banner
  check_pve9

  section "Modus"
  local choice runmode
  choice="$(menu "Wat wil je doen?" \
    "Nieuwe complete Laravel-stack bouwen" \
    "Een component toevoegen aan een bestaande stack")"
  runmode="$(menu "Uitvoeringsmodus" \
    "DRY-RUN / plan: niets wijzigen" \
    "EXECUTE: uitvoeren met transactionele rollback waar haalbaar")"
  [[ "$runmode" == "1" ]] && DRY_RUN="yes" || DRY_RUN="no"

  case "$choice" in
    1) full_stack ;;
    2) add_single_role ;;
  esac

  printf "\n${C_GREEN}${C_BOLD}Klaar.${C_RESET}\n"
}

main "$@"
