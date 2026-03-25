#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║          TELEMT STACK INSTALLER v3.0.0                                      ║
# ║          HAProxy + Traefik + Telemt + Telemt Panel + GeoIP                  ║
# ╠══════════════════════════════════════════════════════════════════════════════╣
# ║                                                                             ║
# ║  Работает на голой машине: автоустановка Docker, git, curl, openssl.        ║
# ║                                                                             ║
# ║  Архитектура:                                                               ║
# ║                                                                             ║
# ║  Клиент:443  → HAProxy (send-proxy-v2) → telemt:443    MTProxy, реальный IP ║
# ║  Клиент:8443 → HAProxy → Traefik:443   → telemt:9091   API (HTTPS)         ║
# ║  Клиент:8443 → HAProxy → Traefik:443   → panel:8080    Panel (HTTPS)       ║
# ║  Клиент:80   → HAProxy → Traefik:80    → ACME / redirect                   ║
# ║                                                                             ║
# ║  Docker сеть: internal (bridge)                                             ║
# ║  Наружу открыт ТОЛЬКО HAProxy (порты 80, 443, 8443)                        ║
# ║                                                                             ║
# ║  TLS:                                                                       ║
# ║    • Traefik — Let's Encrypt сертификаты для Panel и API доменов            ║
# ║    • telemt [censorship] — TLS-маскировка MTProxy трафика                   ║
# ║    • Panel [tls] — НЕ используется (Traefik делает SSL termination)         ║
# ║                                                                             ║
# ║  GeoIP: GeoLite2-City + GeoLite2-ASN (P3TERX/GeoLite.mmdb, без API ключей) ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Соответствие репозиториям:
#   telemt:       https://github.com/telemt/telemt          (3.3.28+)
#   telemt_panel: https://github.com/amirotin/telemt_panel  (v0.4.0+)
#
# Использование:
#   curl -sL https://... | bash                     # интерактивная установка
#   bash install.sh install                          # установка
#   bash install.sh update                           # обновление
#   bash install.sh remove                           # удаление

BASE_DIR="/opt/telemt-stack"
TELEMT_REPO="https://github.com/telemt/telemt"
PANEL_REPO="https://github.com/amirotin/telemt_panel"
TELEMT_VERSION=""
PANEL_VERSION=""

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  НАСТРОЙКИ — ИЗМЕНИТЕ ПОД СВОЙ СЕРВЕР                                      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

MT_PROXY_DOMAIN="mtproxy.vpnkeys.ru"
PANEL_DOMAIN="mtpanel.vpnkeys.ru"
API_DOMAIN="mtapi.vpnkeys.ru"
TLS_MASK_DOMAIN="mtproxy.vpnkeys.ru"        # Домен для TLS-маскировки (должен быть ЧУЖОЙ популярный сайт!)
LE_EMAIL="kefir7676@gmail.com"             # Email для Let's Encrypt

# Порты (наружу через HAProxy)
PUBLIC_MT_PORT="443"                        # MTProxy (HAProxy → telemt, PROXY protocol v2)
PUBLIC_HTTPS_PORT="8443"                    # Panel + API (HAProxy → Traefik → сервисы)

# GeoLite2 — скачивается автоматически с GitHub (P3TERX/GeoLite.mmdb)
GEOLITE2_BASE_URL="https://github.com/P3TERX/GeoLite.mmdb/raw/download"

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  УТИЛИТЫ                                                                    ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

log_info()  { echo -e "\033[32m[INFO]\033[0m  $*"; }
log_warn()  { echo -e "\033[33m[WARN]\033[0m  $*" >&2; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }
log_step()  { echo -e "\n\033[36m══► $*\033[0m"; }

ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log_error "Запустите скрипт от root: sudo bash $0"
    exit 1
  fi
}

ensure_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_docker_api() {
  local api required
  api="$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || true)"
  required="1.41"
  if [ -z "$api" ]; then
    log_error "Не удалось получить версию Docker API. Запущен ли Docker?"
    exit 1
  fi
  if [ "$(printf '%s\n' "$required" "$api" | sort -V | head -n1)" != "$required" ]; then
    log_error "Docker API $api слишком старый. Нужна >= $required."
    exit 1
  fi
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  АВТОУСТАНОВКА ЗАВИСИМОСТЕЙ (голая машина)                                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

detect_os() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "$ID"
  elif [ -f /etc/redhat-release ]; then
    echo "centos"
  else
    echo "unknown"
  fi
}

install_dependencies() {
  log_step "Проверка и установка зависимостей..."

  local os
  os="$(detect_os)"
  local need_docker=false
  local need_packages=()

  # Проверяем что нужно установить
  if ! ensure_cmd docker; then
    need_docker=true
  fi
  if ! ensure_cmd git; then
    need_packages+=("git")
  fi
  if ! ensure_cmd curl; then
    need_packages+=("curl")
  fi
  if ! ensure_cmd openssl; then
    need_packages+=("openssl")
  fi
  if ! ensure_cmd tar; then
    need_packages+=("tar")
  fi
  if ! ensure_cmd jq; then
    need_packages+=("jq")
  fi

  # Всё уже установлено?
  if [ "$need_docker" = false ] && [ ${#need_packages[@]} -eq 0 ]; then
    log_info "Все зависимости уже установлены."
    return
  fi

  case "$os" in
    ubuntu|debian)
      log_info "Обнаружена ОС: $os"
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq

      if [ ${#need_packages[@]} -gt 0 ]; then
        log_info "Устанавливаю: ${need_packages[*]}"
        apt-get install -y -qq "${need_packages[@]}"
      fi

      if [ "$need_docker" = true ]; then
        install_docker_official
      fi
      ;;

    centos|rhel|rocky|almalinux|fedora)
      log_info "Обнаружена ОС: $os"
      local pkg_mgr="dnf"
      if ! ensure_cmd dnf; then
        pkg_mgr="yum"
      fi

      if [ ${#need_packages[@]} -gt 0 ]; then
        log_info "Устанавливаю: ${need_packages[*]}"
        $pkg_mgr install -y -q "${need_packages[@]}"
      fi

      if [ "$need_docker" = true ]; then
        install_docker_official
      fi
      ;;

    *)
      if [ "$need_docker" = true ] || [ ${#need_packages[@]} -gt 0 ]; then
        log_error "Неизвестная ОС: $os"
        log_error "Установите вручную: docker, git, curl, openssl, tar, jq"
        exit 1
      fi
      ;;
  esac

  # Проверяем Docker Compose plugin
  if ! docker compose version >/dev/null 2>&1; then
    log_error "Docker Compose plugin не установлен."
    log_error "Установите: apt-get install docker-compose-plugin"
    exit 1
  fi

  log_info "Все зависимости установлены."
}

install_docker_official() {
  log_info "Устанавливаю Docker через официальный скрипт..."

  # Удаляем конфликтующие пакеты (неофициальные)
  for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt-get remove -y -qq "$pkg" 2>/dev/null || true
  done

  # Официальный установщик Docker
  curl -fsSL https://get.docker.com | sh

  # Включаем и запускаем
  systemctl enable docker
  systemctl start docker

  log_info "Docker установлен: $(docker --version)"
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  GEOIP — СКАЧИВАНИЕ GeoLite2                                               ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
# Автоматическое скачивание с GitHub-зеркала P3TERX/GeoLite.mmdb.
# Обновляется еженедельно из MaxMind. Не требует регистрации и API ключей.
# Источник: https://github.com/P3TERX/GeoLite.mmdb
#
# Файлы:
#   GeoLite2-City.mmdb — геолокация (страна, город, координаты)
#   GeoLite2-ASN.mmdb  — информация о провайдере (ASN, ISP)
#
# Хранятся в: $BASE_DIR/geoip/

download_geolite2() {
  log_step "Скачивание GeoLite2 баз данных..."

  mkdir -p "$BASE_DIR/geoip"

  local files=("GeoLite2-City.mmdb" "GeoLite2-ASN.mmdb")
  local success=true

  for file in "${files[@]}"; do
    local mmdb_file="$BASE_DIR/geoip/${file}"

    # Не перекачиваем если файл свежее 7 дней
    if [ -f "$mmdb_file" ]; then
      local age
      age=$(( $(date +%s) - $(stat -c %Y "$mmdb_file" 2>/dev/null || echo 0) ))
      if [ "$age" -lt 604800 ]; then
        log_info "$file уже актуален ($(( age / 86400 )) дней)."
        continue
      fi
    fi

    log_info "Скачиваю $file ..."

    local http_code
    http_code=$(curl -sSL -w '%{http_code}' -o "$mmdb_file.tmp" \
      "${GEOLITE2_BASE_URL}/${file}" 2>/dev/null) || true

    if [ "$http_code" = "200" ] && [ -s "$mmdb_file.tmp" ]; then
      mv "$mmdb_file.tmp" "$mmdb_file"
      chmod 644 "$mmdb_file"
      log_info "$file скачан → $mmdb_file ($(du -h "$mmdb_file" | cut -f1))"
    else
      rm -f "$mmdb_file.tmp"
      log_warn "Не удалось скачать $file (HTTP $http_code). Пропускаю."
      success=false
    fi
  done

  if [ "$success" = false ]; then
    log_warn "Некоторые GeoIP базы не скачаны. Панель будет работать без полной геолокации."
  fi
}

has_geoip() {
  [ -f "$BASE_DIR/geoip/GeoLite2-City.mmdb" ] || [ -f "$BASE_DIR/geoip/GeoLite2-ASN.mmdb" ]
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  ВЕРСИИ — ВЫБОР ИЗ GIT ТЕГОВ                                               ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

list_versions() {
  local repo_url="$1"
  git ls-remote --tags "$repo_url" 2>/dev/null \
    | awk '{print $2}' \
    | sed 's|refs/tags/||; s/\^{}//' \
    | sort -V | uniq
}

select_version() {
  local name="$1"
  local repo_url="$2"
  local versions chosen i

  versions="$(list_versions "$repo_url" | tail -n 30)"
  if [ -z "$versions" ]; then
    log_warn "Не удалось получить список версий для $name."
    echo "Введите версию вручную (или Enter для latest main):" >&2
    read -r chosen
    echo "$chosen"
    return
  fi

  echo "" >&2
  echo "Доступные версии $name (последние 30):" >&2
  i=1
  while read -r v; do
    printf "  %2d) %s\n" "$i" "$v" >&2
    i=$((i+1))
  done <<< "$versions"
  echo "" >&2

  echo "Введите номер, тег/commit, или Enter для latest main:" >&2
  read -r chosen

  if [ -z "$chosen" ]; then
    echo ""
    return
  fi
  if echo "$chosen" | grep -qE '^[0-9]+$'; then
    echo "$versions" | sed -n "${chosen}p"
    return
  fi
  echo "$chosen"
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  ПРОВЕРКИ                                                                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

check_ports() {
  if ensure_cmd ss; then
    local busy=""
    for p in 80 "$PUBLIC_MT_PORT" "$PUBLIC_HTTPS_PORT"; do
      if ss -tulpn 2>/dev/null | grep -qE ":${p}\b"; then
        busy="${busy} ${p}"
      fi
    done
    if [ -n "$busy" ]; then
      log_error "Порты${busy} уже заняты. Освободите перед запуском."
      exit 1
    fi
  fi
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  GIT — КЛОНИРОВАНИЕ / ОБНОВЛЕНИЕ                                           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

clone_or_update() {
  local repo="$1"
  local dir="$2"
  local ref="$3"

  if [ -d "$dir/.git" ]; then
    log_info "Обновляю $dir ..."
    git -C "$dir" fetch --all --tags --prune
    if [ -n "$ref" ]; then
      git -C "$dir" checkout --force "$ref"
    else
      git -C "$dir" checkout --force main 2>/dev/null || git -C "$dir" checkout --force master
      git -C "$dir" reset --hard "origin/$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
    fi
  else
    log_info "Клонирую $repo → $dir ..."
    git clone "$repo" "$dir"
    if [ -n "$ref" ]; then
      git -C "$dir" fetch --all --tags
      git -C "$dir" checkout --force "$ref"
    fi
  fi
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  СЕКРЕТЫ (.env)                                                             ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

gen_secrets() {
  if validate_env; then
    log_info "Секреты уже существуют (.env), пропускаю генерацию."
    return
  fi

  local api_secret jwt_secret user_secret
  api_secret="$(openssl rand -hex 32)"
  jwt_secret="$(openssl rand -hex 32)"
  user_secret="$(openssl rand -hex 16)"

  # Кавычки ОБЯЗАТЕЛЬНЫ для TELEMT_API_AUTH — значение содержит пробел (Bearer xxx).
  # При source bash корректно убирает кавычки.
  cat > "$BASE_DIR/.env" <<ENVEOF
TELEMT_API_AUTH="Bearer ${api_secret}"
PANEL_JWT_SECRET="${jwt_secret}"
TELEMT_USER_SECRET="${user_secret}"
ENVEOF
  chmod 600 "$BASE_DIR/.env"
  log_info "Секреты сгенерированы → $BASE_DIR/.env"
}

validate_env() {
  [ -f "$BASE_DIR/.env" ] \
    && grep -q '^TELEMT_API_AUTH=' "$BASE_DIR/.env" \
    && grep -q '^PANEL_JWT_SECRET=' "$BASE_DIR/.env" \
    && grep -q '^TELEMT_USER_SECRET=' "$BASE_DIR/.env"
}

load_env() {
  # shellcheck disable=SC1091
  set -a
  source "$BASE_DIR/.env"
  set +a
}

# fix_env_format — миграция .env: добавляет кавычки для значений с пробелами.
# Старый формат: TELEMT_API_AUTH=Bearer xxx  (bash source ломается на пробеле)
# Новый формат:  TELEMT_API_AUTH="Bearer xxx" (bash source работает корректно)
fix_env_format() {
  local envfile="$BASE_DIR/.env"
  [ -f "$envfile" ] || return 0

  # Если строка имеет вид KEY=VALUE (без кавычек) и VALUE содержит пробел → добавляем кавычки
  if grep -qE '^[A-Z_]+=[^"].* ' "$envfile"; then
    log_info "Миграция .env — добавляю кавычки..."
    sed -i -E 's/^([A-Z_]+)=([^"].*)$/\1="\2"/' "$envfile"
  fi
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  HAPROXY КОНФИГ                                                             ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
# HAProxy — единственная точка входа из интернета.
# 1) MTProxy:  клиент:443  → telemt:443  (PROXY protocol v2 для реального IP)
# 2) HTTPS:    клиент:8443 → Traefik:443 (TLS termination + роутинг по домену)
# 3) HTTP:     клиент:80   → Traefik:80  (ACME challenges + redirect → HTTPS)

write_haproxy_config() {
  log_info "Записываю конфиг HAProxy..."
  mkdir -p "$BASE_DIR/haproxy"
  cat > "$BASE_DIR/haproxy/haproxy.cfg" <<'HAEOF'
global
    log stdout format raw local0
    maxconn 50000

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5s
    timeout client  1h
    timeout server  1h
    timeout tunnel  1h

resolvers docker
    nameserver dns1 127.0.0.11:53
    resolve_retries 30
    timeout resolve 1s
    timeout retry   1s
    hold valid 10s

# ─── MTProxy: клиент:443 → telemt с PROXY protocol v2 ───────────────────
frontend ft_mtproxy
    bind *:443
    default_backend bk_telemt

backend bk_telemt
    server telemt telemt:443 resolvers docker init-addr last,libc,none send-proxy-v2

# ─── HTTP: ACME challenge (Let's Encrypt) + redirect → HTTPS ────────────
frontend ft_http
    bind *:80
    default_backend bk_traefik_http

backend bk_traefik_http
    server traefik traefik:80 resolvers docker init-addr last,libc,none

# ─── HTTPS: Panel + API → Traefik ───────────────────────────────────────
frontend ft_https
    bind *:8443
    default_backend bk_traefik_https

backend bk_traefik_https
    server traefik traefik:443 resolvers docker init-addr last,libc,none
HAEOF
  log_info "HAProxy конфиг записан."
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  DOCKER COMPOSE                                                             ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

write_compose() {
  log_info "Записываю docker-compose.yml..."

  # Определяем volumes для panel в зависимости от наличия GeoIP
  local panel_geoip_volumes=""
  if has_geoip; then
    panel_geoip_volumes="      - ./geoip:/var/lib/telemt-panel/geoip:ro"
  fi

  cat > "$BASE_DIR/docker-compose.yml" <<COMPEOF
networks:
  internal:
    driver: bridge

services:

  # ─── HAProxy ─────────────────────────────────────────────────────────────
  # Единственный контейнер с портами наружу.
  # MTProxy:443, HTTP:80 (ACME), HTTPS:${PUBLIC_HTTPS_PORT} (Panel + API).
  haproxy:
    image: haproxy:lts-alpine
    container_name: telemt-haproxy
    restart: unless-stopped
    ports:
      - "${PUBLIC_MT_PORT}:443"
      - "80:80"
      - "${PUBLIC_HTTPS_PORT}:8443"
    volumes:
      - ./haproxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    networks:
      - internal
    depends_on:
      - telemt
      - traefik

  # ─── Traefik ─────────────────────────────────────────────────────────────
  # Let's Encrypt SSL для Panel и API доменов.
  # НЕ открыт наружу — весь трафик идёт через HAProxy.
  traefik:
    image: traefik:latest
    container_name: telemt-traefik
    restart: unless-stopped
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=telemt-stack_internal
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
      - --certificatesresolvers.le.acme.email=${LE_EMAIL}
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
    expose:
      - "80"
      - "443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./letsencrypt:/letsencrypt
    networks:
      - internal

  # ─── Telemt ──────────────────────────────────────────────────────────────
  # MTProxy сервер (Rust).
  # working_dir = /run/telemt — telemt ищет config.toml в CWD.
  # telemt-data монтируется как директория (НЕ отдельный файл!) —
  # telemt делает атомарную запись (temp + rename), это требует одной FS.
  # proxy_protocol = true — принимает PROXY v2 от HAProxy (реальный IP).
  telemt:
    build:
      context: ./telemt
    container_name: telemt
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    environment:
      - RUST_LOG=info
    working_dir: /run/telemt
    volumes:
      - ./telemt-data:/run/telemt:rw
    expose:
      - "443"
      - "9090"
      - "9091"
    networks:
      - internal
    labels:
      # API доступен через Traefik по домену ${API_DOMAIN}
      - traefik.enable=true
      - traefik.http.routers.mtapi.rule=Host(\`${API_DOMAIN}\`)
      - traefik.http.routers.mtapi.entrypoints=websecure
      - traefik.http.routers.mtapi.tls.certresolver=le
      - traefik.http.services.mtapi.loadbalancer.server.port=9091

  # ─── Telemt Panel ─────────────────────────────────────────────────────────
  # Web-панель (Go + React). Подключается к Telemt API по Docker DNS.
  # Монтирует конфиг telemt для чтения/записи (панель управляет пользователями).
  telemt-panel:
    build: ./telemt_panel
    container_name: telemt-panel
    restart: unless-stopped
    expose:
      - "8080"
    volumes:
      - ./telemt-panel-config/config.toml:/etc/telemt-panel/config.toml:ro
      - ./telemt-data:/etc/telemt:rw
${panel_geoip_volumes}
    networks:
      - internal
    labels:
      - traefik.enable=true
      - traefik.http.routers.mtpanel.rule=Host(\`${PANEL_DOMAIN}\`)
      - traefik.http.routers.mtpanel.entrypoints=websecure
      - traefik.http.routers.mtpanel.tls.certresolver=le
      - traefik.http.services.mtpanel.loadbalancer.server.port=8080
COMPEOF
  log_info "docker-compose.yml записан."
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  TOML УТИЛИТЫ                                                              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set_key_in_section() {
  local file="$1" section="$2" key="$3" value="$4"
  local section_header="[$section]"

  awk -v hdr="$section_header" -v k="$key" -v v="$value" '
    BEGIN { in_sec=0; done=0; found=0 }
    $0 == hdr { in_sec=1; found=1; print; next }
    /^\[/ && $0 != hdr {
      if (in_sec && !done) { print k " = " v; done=1 }
      in_sec=0
    }
    in_sec && $0 ~ "^"k"[[:space:]]*=" {
      print k " = " v; done=1; next
    }
    { print }
    END {
      if (in_sec && !done) { print k " = " v }
      if (!found) { print "\n" hdr; print k " = " v }
    }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

strip_access_sections() {
  local file="$1"
  awk '
    BEGIN {skip=0}
    /^\[access/ {skip=1; next}
    /^\[/ { if (skip) {skip=0} }
    {if (!skip) print}
  ' "$file"
}

extract_access_sections() {
  local file="$1"
  awk '
    BEGIN {p=0}
    /^\[access/ {p=1}
    /^\[/ && $0 !~ /^\[access/ {p=0}
    {if (p) print}
  ' "$file"
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  КОНФИГ TELEMT                                                              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
# Основан на официальном config.toml из репозитория telemt.
#
# Ключевые параметры:
#   proxy_protocol = true       — за HAProxy (реальный IP клиента)
#   public_host / public_port   — для генерации tg:// ссылок
#   auth_header                 — защита API
#   whitelist                   — ограничен Docker-сетью (172.16.0.0/12)
#   [censorship] tls_domain     — TLS-маскировка MTProxy трафика

write_telemt_config() {
  local cfg="$BASE_DIR/telemt-data/config.toml"
  local template="$BASE_DIR/telemt/config.toml"

  if [ -f "$cfg" ]; then
    log_info "Конфиг telemt уже существует, пропускаю (миграция при update)."
    return
  fi

  if [ ! -f "$template" ]; then
    log_error "Шаблон конфига telemt не найден: $template"
    exit 1
  fi

  # Берём шаблон из репозитория, убираем секцию [access] (добавим свою)
  strip_access_sections "$template" > "$cfg"

  # Добавляем первого пользователя
  printf '\n[access.users]\nuser1 = "%s"\n' "$TELEMT_USER_SECRET" >> "$cfg"

  # Настраиваем параметры
  apply_telemt_settings "$cfg"

  # Разрешаем запись для панели (панель работает от непривилегированного пользователя)
  chmod 666 "$cfg"

  log_info "Конфиг telemt записан → $cfg"
}

migrate_telemt_config() {
  local cfg="$BASE_DIR/telemt-data/config.toml"
  local template="$BASE_DIR/telemt/config.toml"
  local backup_dir="$BASE_DIR/backups"

  if [ ! -f "$cfg" ] || [ ! -f "$template" ]; then
    return
  fi

  mkdir -p "$backup_dir"
  cp "$cfg" "$backup_dir/telemt-config.toml.$(date +%Y%m%d%H%M%S)"
  log_info "Бэкап конфига telemt → $backup_dir/"

  # Сохраняем секцию [access] (пользователи + ad_tags)
  local saved_access
  saved_access="$(extract_access_sections "$cfg")"

  # Берём свежий шаблон, убираем [access]
  strip_access_sections "$template" > "$cfg"

  # Восстанавливаем пользователей
  if [ -n "$saved_access" ]; then
    printf '\n%s\n' "$saved_access" >> "$cfg"
  else
    printf '\n[access.users]\nuser1 = "%s"\n' "$TELEMT_USER_SECRET" >> "$cfg"
  fi

  # Применяем настройки
  apply_telemt_settings "$cfg"

  # Разрешаем запись для панели
  chmod 666 "$cfg"

  log_info "Миграция конфига telemt завершена."
}

apply_telemt_settings() {
  local cfg="$1"

  # [general.links] — публичный хост для tg:// ссылок
  set_key_in_section "$cfg" "general.links" "show"        '"*"'
  set_key_in_section "$cfg" "general.links" "public_host" "\"$MT_PROXY_DOMAIN\""
  set_key_in_section "$cfg" "general.links" "public_port" "$PUBLIC_MT_PORT"

  # [server] — PROXY protocol от HAProxy
  set_key_in_section "$cfg" "server" "proxy_protocol" "true"

  # [server.api] — REST API для панели и SHM
  set_key_in_section "$cfg" "server.api" "enabled"                      "true"
  set_key_in_section "$cfg" "server.api" "listen"                       '"0.0.0.0:9091"'
  set_key_in_section "$cfg" "server.api" "auth_header"                  "\"$TELEMT_API_AUTH\""
  set_key_in_section "$cfg" "server.api" "whitelist"                    '["172.16.0.0/12", "127.0.0.0/8"]'
  set_key_in_section "$cfg" "server.api" "minimal_runtime_enabled"      "true"
  set_key_in_section "$cfg" "server.api" "minimal_runtime_cache_ttl_ms" "1000"
  set_key_in_section "$cfg" "server.api" "runtime_edge_enabled"         "true"
  set_key_in_section "$cfg" "server.api" "runtime_edge_cache_ttl_ms"    "1000"

  # [censorship] — TLS-маскировка MTProxy трафика
  set_key_in_section "$cfg" "censorship" "tls_domain"    "\"$TLS_MASK_DOMAIN\""
  set_key_in_section "$cfg" "censorship" "mask"          "true"
  set_key_in_section "$cfg" "censorship" "tls_emulation" "true"
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  КОНФИГ TELEMT-PANEL                                                        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
# Основан на config.example.toml v0.4.0.
#
# Docker-режим: url = "http://telemt:9091" (Docker DNS, не localhost).
# TLS: не используется (Traefik делает SSL termination).
# GeoIP: подключается если скачаны GeoLite2 базы.

write_panel_config() {
  local panel_cfg_dir="$BASE_DIR/telemt-panel-config"
  mkdir -p "$panel_cfg_dir"

  # Защита: если config.toml — директория (от битого предыдущего запуска), удаляем
  if [ -d "$panel_cfg_dir/config.toml" ]; then
    rm -rf "$panel_cfg_dir/config.toml"
  fi

  local password_hash

  if [ -f "$panel_cfg_dir/.panel_password_hash" ]; then
    password_hash="$(cat "$panel_cfg_dir/.panel_password_hash")"
    log_info "Используется сохранённый хэш пароля панели."
  else
    log_step "Генерация пароля панели..."
    echo "" >&2
    echo "Введите пароль для панели управления:" >&2
    password_hash="$(cd "$BASE_DIR" && docker compose run --rm --no-deps telemt-panel hash-password 2>/dev/null)" || {
      log_error "Не удалось сгенерировать хэш пароля."
      log_error "Убедитесь, что образ панели собран."
      exit 1
    }
    echo "$password_hash" > "$panel_cfg_dir/.panel_password_hash"
    chmod 600 "$panel_cfg_dir/.panel_password_hash"
  fi

  # GeoIP секция
  local geoip_section=""
  if has_geoip; then
    geoip_section='[geoip]'
    if [ -f "$BASE_DIR/geoip/GeoLite2-City.mmdb" ]; then
      geoip_section="${geoip_section}
db_path = \"/var/lib/telemt-panel/geoip/GeoLite2-City.mmdb\""
    fi
    if [ -f "$BASE_DIR/geoip/GeoLite2-ASN.mmdb" ]; then
      geoip_section="${geoip_section}
asn_db_path = \"/var/lib/telemt-panel/geoip/GeoLite2-ASN.mmdb\""
    fi
  else
    geoip_section='[geoip]
# GeoIP не скачался. Проверьте доступность:
# curl -sSL https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb -o geoip/GeoLite2-City.mmdb
# Затем: bash install.sh update
# db_path = "/var/lib/telemt-panel/geoip/GeoLite2-City.mmdb"
# asn_db_path = "/var/lib/telemt-panel/geoip/GeoLite2-ASN.mmdb"'
  fi

  cat > "$panel_cfg_dir/config.toml" <<PANELEOF
# Telemt Panel Configuration
# Сгенерировано install.sh v3.0.0 — $(date +%Y-%m-%d)
# Документация: https://github.com/amirotin/telemt_panel

listen = "0.0.0.0:8080"

[telemt]
# URL API Telemt — Docker DNS имя (НЕ localhost, т.к. panel в отдельном контейнере)
url = "http://telemt:9091"
# Authorization заголовок — должен совпадать с auth_header в telemt config.toml
auth_header = "${TELEMT_API_AUTH}"
# Путь к конфигу telemt (монтируется в панель для чтения/записи настроек и пользователей)
config_path = "/etc/telemt/config.toml"
# GitHub репозиторий для проверки обновлений
github_repo = "telemt/telemt"

[panel]
github_repo = "amirotin/telemt_panel"

[tls]
# TLS панели используется для маскировки MTProxy трафика, НЕ для HTTPS.
# HTTPS обеспечивает Traefik (Let's Encrypt).
# Не включайте здесь TLS — это сломает reverse proxy.

${geoip_section}

[auth]
username = "admin"
password_hash = "${password_hash}"
jwt_secret = "${PANEL_JWT_SECRET}"
session_ttl = "24h"
PANELEOF

  chmod 600 "$panel_cfg_dir/config.toml"
  log_info "Конфиг панели записан → $panel_cfg_dir/config.toml"
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  ИНФРАСТРУКТУРА                                                             ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

ensure_base() {
  mkdir -p "$BASE_DIR"
  mkdir -p "$BASE_DIR/letsencrypt"
  mkdir -p "$BASE_DIR/telemt-data"
  mkdir -p "$BASE_DIR/telemt-panel-config"
  mkdir -p "$BASE_DIR/haproxy"
  mkdir -p "$BASE_DIR/backups"
  mkdir -p "$BASE_DIR/geoip"

  chmod 700 "$BASE_DIR/letsencrypt"

  if [ ! -f "$BASE_DIR/letsencrypt/acme.json" ]; then
    touch "$BASE_DIR/letsencrypt/acme.json"
    chmod 600 "$BASE_DIR/letsencrypt/acme.json"
  fi
}

migrate_old_config_location() {
  local new_cfg="$BASE_DIR/telemt-data/config.toml"
  [ -f "$new_cfg" ] && return

  local old_cfg=""
  for candidate in \
    "$BASE_DIR/telemt/config.runtime.toml" \
    "$BASE_DIR/telemt-data/config.runtime.toml"; do
    if [ -f "$candidate" ]; then
      old_cfg="$candidate"
      break
    fi
  done

  if [ -n "$old_cfg" ]; then
    log_info "Миграция конфига: $old_cfg → $new_cfg"
    cp "$old_cfg" "$new_cfg"
    mv "$old_cfg" "${old_cfg}.migrated.$(date +%Y%m%d%H%M%S)"
  fi
}

is_installed() {
  [ -f "$BASE_DIR/docker-compose.yml" ] \
    && [ -d "$BASE_DIR/telemt" ] \
    && [ -d "$BASE_DIR/telemt_panel" ]
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  УДАЛЕНИЕ                                                                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

remove_stack() {
  ensure_cmd docker || true

  if [ -d "$BASE_DIR" ]; then
    if [ -f "$BASE_DIR/docker-compose.yml" ]; then
      log_info "Останавливаю контейнеры..."
      (cd "$BASE_DIR" && docker compose down --remove-orphans 2>/dev/null || true)
    fi

    echo "" >&2
    echo "Удалить ВСЕ данные (секреты, конфиги, сертификаты, бэкапы)?" >&2
    read -r -p "[y/N]: " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
      rm -rf "$BASE_DIR"
      log_info "Полное удаление завершено."
    else
      # Удаляем только docker-compose и образы, данные сохраняем
      rm -f "$BASE_DIR/docker-compose.yml"
      rm -rf "$BASE_DIR/telemt" "$BASE_DIR/telemt_panel"
      rm -rf "$BASE_DIR/haproxy"
      log_info "Контейнеры удалены. Данные сохранены в $BASE_DIR."
    fi
  else
    log_info "Ничего не установлено."
  fi
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  УСТАНОВКА                                                                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

install_stack() {
  ensure_root

  # ── Шаг 1: Зависимости ──
  install_dependencies
  ensure_docker_api

  # ── Шаг 2: Выбор версий ──
  log_step "Выбор версий"
  TELEMT_VERSION="$(select_version "Telemt" "$TELEMT_REPO")"
  PANEL_VERSION="$(select_version "Telemt Panel" "$PANEL_REPO")"

  # ── Шаг 3: Проверки ──
  check_ports
  ensure_base

  # ── Шаг 4: Клонирование ──
  log_step "Клонирование репозиториев"
  clone_or_update "$TELEMT_REPO"  "$BASE_DIR/telemt"       "$TELEMT_VERSION"
  clone_or_update "$PANEL_REPO"   "$BASE_DIR/telemt_panel" "$PANEL_VERSION"

  # ── Шаг 5: Секреты ──
  log_step "Генерация секретов"
  gen_secrets
  fix_env_format
  load_env

  # ── Шаг 6: GeoIP ──
  download_geolite2

  # ── Шаг 7: Конфиги инфраструктуры ──
  log_step "Генерация конфигов"
  write_haproxy_config
  write_compose

  # ── Шаг 8: Сборка Docker-образов ──
  log_step "Сборка Docker-образов (это может занять несколько минут)..."
  (cd "$BASE_DIR" && docker compose build --pull)

  # ── Шаг 9: Конфиги сервисов ──
  log_step "Настройка сервисов"
  migrate_old_config_location
  write_telemt_config
  write_panel_config

  # ── Шаг 10: Запуск ──
  log_step "Запуск стека"
  (cd "$BASE_DIR" && docker compose up -d)

  # ── Шаг 11: Проверка ──
  wait_for_healthy

  print_summary
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  ОБНОВЛЕНИЕ                                                                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

update_stack() {
  ensure_root
  install_dependencies
  ensure_docker_api

  log_step "Выбор версий"
  TELEMT_VERSION="$(select_version "Telemt" "$TELEMT_REPO")"
  PANEL_VERSION="$(select_version "Telemt Panel" "$PANEL_REPO")"

  ensure_base

  log_step "Обновление репозиториев"
  clone_or_update "$TELEMT_REPO"  "$BASE_DIR/telemt"       "$TELEMT_VERSION"
  clone_or_update "$PANEL_REPO"   "$BASE_DIR/telemt_panel" "$PANEL_VERSION"

  fix_env_format
  load_env

  # Обновляем GeoIP базы
  download_geolite2

  log_step "Обновление конфигов"
  write_haproxy_config
  write_compose

  log_step "Пересборка Docker-образов..."
  (cd "$BASE_DIR" && docker compose build --pull)

  migrate_old_config_location
  migrate_telemt_config
  write_panel_config

  log_step "Перезапуск стека"
  (cd "$BASE_DIR" && docker compose up -d --remove-orphans)

  wait_for_healthy

  print_summary
  log_info "Обновление завершено."
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  HEALTH CHECK                                                               ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

wait_for_healthy() {
  log_step "Проверка запуска контейнеров..."

  local max_wait=30
  local waited=0
  local all_running=false

  while [ "$waited" -lt "$max_wait" ]; do
    local running
    running="$(docker compose -f "$BASE_DIR/docker-compose.yml" ps --format '{{.State}}' 2>/dev/null | grep -c 'running' || true)"
    local total
    total="$(docker compose -f "$BASE_DIR/docker-compose.yml" ps --format '{{.State}}' 2>/dev/null | wc -l || true)"

    if [ "$running" -ge 4 ] 2>/dev/null; then
      all_running=true
      break
    fi

    sleep 2
    waited=$((waited + 2))
    printf "."
  done
  echo ""

  if [ "$all_running" = true ]; then
    log_info "Все 4 контейнера запущены."
  else
    log_warn "Не все контейнеры запустились за ${max_wait}с. Проверьте:"
    log_warn "  cd $BASE_DIR && docker compose ps"
    log_warn "  docker compose logs --tail 50"
  fi

  # Показываем статус
  (cd "$BASE_DIR" && docker compose ps)
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  ИТОГ                                                                       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

print_summary() {
  local geoip_status="отключён"
  if has_geoip; then
    geoip_status="включён ✓"
  fi

  echo ""
  echo "╔══════════════════════════════════════════════════════════════════════╗"
  echo "║               TELEMT STACK — УСТАНОВКА ЗАВЕРШЕНА ✓                   ║"
  echo "╠══════════════════════════════════════════════════════════════════════╣"
  printf "║  MTProxy:  %-59s ║\n" "${MT_PROXY_DOMAIN}:${PUBLIC_MT_PORT}"
  printf "║  Panel:    %-59s ║\n" "https://${PANEL_DOMAIN}:${PUBLIC_HTTPS_PORT}"
  printf "║  API:      %-59s ║\n" "https://${API_DOMAIN}:${PUBLIC_HTTPS_PORT}"
  printf "║  GeoIP:    %-59s ║\n" "$geoip_status"
  echo "╠══════════════════════════════════════════════════════════════════════╣"
  echo "║  Архитектура:                                                        ║"
  echo "║    HAProxy:443  → telemt (PROXY protocol v2, реальный IP)            ║"
  echo "║    HAProxy:8443 → Traefik → Panel/API (Let's Encrypt SSL)            ║"
  echo "║    HAProxy:80   → Traefik → ACME challenge + redirect → HTTPS        ║"
  echo "║  API whitelist: Docker internal (172.16.0.0/12)                      ║"
  echo "╠══════════════════════════════════════════════════════════════════════╣"
  echo "║  Файлы:                                                              ║"
  printf "║    telemt config:  %-51s ║\n" "$BASE_DIR/telemt-data/config.toml"
  printf "║    panel config:   %-51s ║\n" "$BASE_DIR/telemt-panel-config/config.toml"
  printf "║    секреты:        %-51s ║\n" "$BASE_DIR/.env"
  printf "║    GeoIP базы:     %-51s ║\n" "$BASE_DIR/geoip/"
  printf "║    бэкапы:         %-51s ║\n" "$BASE_DIR/backups/"
  echo "╠══════════════════════════════════════════════════════════════════════╣"
  echo "║  SHM коннектор — настройки сервера:                                  ║"
  printf "║    api.host = %-56s ║\n" "https://${API_DOMAIN}:${PUBLIC_HTTPS_PORT}"
  echo "╠══════════════════════════════════════════════════════════════════════╣"
  echo "║  Команды:                                                            ║"
  echo "║    Статус:  cd $BASE_DIR && docker compose ps                        ║"
  echo "║    Логи:    docker compose logs -f --tail 100                        ║"
  echo "║    Стоп:    docker compose down                                      ║"
  echo "║    Update:  bash install.sh update                                   ║"
  echo "╚══════════════════════════════════════════════════════════════════════╝"
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  ГЛАВНОЕ МЕНЮ                                                               ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

show_menu() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║          TELEMT STACK INSTALLER v3.0.0                           ║"
  echo "╠══════════════════════════════════════════════════════════════════╣"

  if is_installed; then
    echo "║  Статус: установлен ✓                                           ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║  1) Обновить (новые версии telemt/panel)                        ║"
    echo "║  2) Переустановить полностью                                    ║"
    echo "║  3) Перезапустить контейнеры                                    ║"
    echo "║  4) Показать статус                                             ║"
    echo "║  5) Показать логи                                               ║"
    echo "║  6) Удалить всё                                                 ║"
    echo "║  0) Выход                                                       ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    read -r -p "Выбор [0-6]: " choice

    case "$choice" in
      1) update_stack ;;
      2) remove_stack; install_stack ;;
      3) restart_stack ;;
      4) show_status ;;
      5) show_logs ;;
      6) remove_stack ;;
      0) echo "Выход."; exit 0 ;;
      *) log_error "Неверный выбор."; exit 1 ;;
    esac
  else
    echo "║  Статус: не установлен                                          ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║  1) Установить                                                  ║"
    echo "║  0) Выход                                                       ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    read -r -p "Выбор [0-1]: " choice

    case "$choice" in
      1) install_stack ;;
      0) echo "Выход."; exit 0 ;;
      *) log_error "Неверный выбор."; exit 1 ;;
    esac
  fi
}

restart_stack() {
  ensure_root
  log_step "Перезапуск контейнеров..."
  (cd "$BASE_DIR" && docker compose restart)
  wait_for_healthy
}

show_status() {
  echo ""
  (cd "$BASE_DIR" && docker compose ps)
  echo ""
  echo "Секреты: $BASE_DIR/.env"
  echo "Telemt:  $BASE_DIR/telemt-data/config.toml"
  echo "Panel:   $BASE_DIR/telemt-panel-config/config.toml"
}

show_logs() {
  (cd "$BASE_DIR" && docker compose logs -f --tail 100)
}

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  ТОЧКА ВХОДА                                                                ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

case "${1:-}" in
  install) install_stack ;;
  update)  update_stack  ;;
  remove)  remove_stack  ;;
  restart) restart_stack ;;
  status)  show_status   ;;
  logs)    show_logs     ;;
  "")      show_menu     ;;
  *)
    echo "Использование: $0 [install|update|remove|restart|status|logs]"
    echo "Без аргументов — интерактивное меню."
    exit 1
    ;;
esac
