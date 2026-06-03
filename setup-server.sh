#!/bin/bash
# ============================================================
#  Ubuntu 24.04 — Server Setup + Remnawave Node Deploy
#
#  Фаза 1 (root)        : первичная настройка сервера
#  Фаза 2 (DEPLOY_USER) : Docker, Remnawave Node, SSL, Nginx
#
#  Запуск : sudo bash setup-server.sh
#  Конфиг : setup-server.conf (рядом со скриптом, опционально)
# ============================================================
set -e

VERSION="1.0.0"
SCRIPT_REPO_URL="https://raw.githubusercontent.com/k0sha/setup-server/main/setup-server.sh"

# ── Константы путей ──────────────────────────────────────────
INSTALL_DIR="/opt/setup-server"
SCRIPT_NAME="setup-server.sh"
CONFIG_NAME="setup-server.conf"
DEPLOY_SCRIPT="/tmp/_setup-server.sh"
DEPLOY_CONFIG="/tmp/_setup-server.conf"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# ── Флаг фазы ────────────────────────────────────────────────
DEPLOY_PHASE=false
[[ "${1:-}" == "--deploy" ]] && DEPLOY_PHASE=true

# ── Цвета и хелперы ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✔ $1${NC}"; }
info() { echo -e "${BLUE}▶ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
err()  { echo -e "\r${RED}✖ $1${NC}"; echo "  Подробности: ${SETUP_LOG:-/tmp/setup-server.log}"; exit 1; }
sep()  { echo -e "${BLUE}────────────────────────────────────────────────${NC}"; }

q() {
    "$@" >> "$SETUP_LOG" 2>&1 \
        || { err "Ошибка при: $*"; }
}
qs() {
    local msg=$1; shift
    "$@" >> "$SETUP_LOG" 2>&1 &
    local pid=$! i=0 sp='/-\|'
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${BLUE}%s${NC} %s..." "${sp:i++%4:1}" "$msg"
        sleep 0.15
    done
    wait "$pid" || { printf "\r"; err "Ошибка при: $*"; }
    printf "\r%-70s\r" " "
    ok "$msg"
}
qo() { "$@" >> "$SETUP_LOG" 2>&1 || true; }

docker_up() {
    local compose_file=$1 label=$2
    while true; do
        local out exit_code=0
        out=$(sudo docker compose -f "$compose_file" up -d 2>&1) || exit_code=$?
        echo "$out" >> "$SETUP_LOG"
        [[ $exit_code -eq 0 ]] && return 0
        if echo "$out" | grep -qi "rate.limit\|toomanyrequests\|unauthenticated pull"; then
            echo ""
            warn "Docker Hub rate limit — превышен лимит скачивания образов"
            read -rp "Залогиниться в Docker Hub и повторить? [Y/n]: " _ANS
            [[ "${_ANS,,}" == "n" ]] && \
                err "Отменено. Залогинься вручную: sudo docker login"
            read -rp "  Логин: " _DH_USER
            read -rsp "  Пароль / access token: " _DH_PASS; echo ""
            if echo "$_DH_PASS" | sudo docker login \
                    -u "$_DH_USER" --password-stdin >> "$SETUP_LOG" 2>&1; then
                ok "Docker Hub: авторизован как $_DH_USER"
            else
                warn "Авторизация не удалась — пробуем снова"
            fi
            unset _DH_PASS
            info "Повторяем запуск $label..."
        else
            err "Не удалось запустить $label, смотри $SETUP_LOG"
        fi
    done
}

gen_password() {
    local lower upper digit special pass
    while true; do
        lower=$(tr -dc 'abcdefghjkmnpqrstuvwxyz' < /dev/urandom | head -c 5)
        upper=$(tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZ' < /dev/urandom | head -c 4)
        digit=$(tr -dc '23456789' < /dev/urandom | head -c 4)
        special=$(tr -dc '!@#$%^&*' < /dev/urandom | head -c 3)
        pass=$(echo "${lower}${upper}${digit}${special}" | fold -w1 | shuf | tr -d '\n')
        if [[ ${#pass} -ge 16 ]] && ! echo "$pass" | grep -qP '(.)\1\1'; then
            echo "$pass"; return
        fi
    done
}

# ── Версионность ─────────────────────────────────────────────
compare_versions() {
    local v1="$1" v2="$2"
    if printf '%s\n' "$v1" "$v2" | sort -V | head -n1 | grep -qx "$v1"; then
        [[ "$v1" != "$v2" ]]  # v1 < v2 → newer available
    else
        return 1
    fi
}

_do_update() {
    local NEW_VER="$1"
    local TEMP_SCRIPT="$INSTALL_DIR/$SCRIPT_NAME.tmp"
    info "Скачиваем версию $NEW_VER..."
    if ! curl -fsSL --max-time 30 "$SCRIPT_REPO_URL" -o "$TEMP_SCRIPT" 2>/dev/null; then
        warn "Не удалось скачать обновление — продолжаем с текущей версией"
        rm -f "$TEMP_SCRIPT"; return
    fi
    if [[ ! -s "$TEMP_SCRIPT" ]] || ! head -n 1 "$TEMP_SCRIPT" | grep -q '#!.*bash'; then
        warn "Загруженный файл невалиден — продолжаем с текущей версией"
        rm -f "$TEMP_SCRIPT"; return
    fi
    find "$INSTALL_DIR" -maxdepth 1 -name "$SCRIPT_NAME.bak.*" -delete 2>/dev/null || true
    cp "$INSTALL_DIR/$SCRIPT_NAME" "$INSTALL_DIR/$SCRIPT_NAME.bak.$(date +%s)" 2>/dev/null || true
    mv "$TEMP_SCRIPT" "$INSTALL_DIR/$SCRIPT_NAME"
    chmod 600 "$INSTALL_DIR/$SCRIPT_NAME"
    ok "Обновлено до версии $NEW_VER — перезапускаем..."
    sleep 1
    exec bash "$INSTALL_DIR/$SCRIPT_NAME" "$@"
}

check_and_update() {
    echo -e "  Версия: ${YELLOW}$VERSION${NC}"
    echo ""
    local TEMP
    TEMP=$(mktemp)
    if ! curl -fsSL --max-time 10 "$SCRIPT_REPO_URL" 2>/dev/null | head -n 20 > "$TEMP"; then
        rm -f "$TEMP"; return
    fi
    local REMOTE_VER
    REMOTE_VER=$(grep -m 1 "^VERSION=" "$TEMP" | cut -d'"' -f2)
    rm -f "$TEMP"
    [[ -z "$REMOTE_VER" ]] && return
    if compare_versions "$VERSION" "$REMOTE_VER"; then
        echo -e "${YELLOW}  Доступна новая версия: $REMOTE_VER${NC}"
        echo ""
        read -rp "  Обновить до $REMOTE_VER? [Y/n]: " _UPD
        echo ""
        [[ "${_UPD,,}" != "n" ]] && _do_update "$REMOTE_VER"
    fi
}

# ════════════════════════════════════════════════════════════
#  ФАЗА 1 — ROOT
# ════════════════════════════════════════════════════════════
if [[ "$DEPLOY_PHASE" == false ]]; then

[[ $EUID -ne 0 ]] && {
    echo -e "${RED}✖ Запускай от root: sudo bash $SCRIPT_NAME${NC}"; exit 1
}

# ── Самоперемещение ──────────────────────────────────────────
if [[ "$SCRIPT_DIR" != "$INSTALL_DIR" ]]; then
    echo ""
    echo -e "${BLUE}  ╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}  ║  Скрипт запущен не из штатного расположения     ║${NC}"
    echo -e "${BLUE}  ║  Выполняем перемещение...                       ║${NC}"
    echo -e "${BLUE}  ╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    mkdir -p "$INSTALL_DIR"
    chmod 700 "$INSTALL_DIR"
    cp "$SCRIPT_PATH" "$INSTALL_DIR/$SCRIPT_NAME"
    chmod 600 "$INSTALL_DIR/$SCRIPT_NAME"
    if [[ -f "$SCRIPT_DIR/$CONFIG_NAME" ]]; then
        mv "$SCRIPT_DIR/$CONFIG_NAME" "$INSTALL_DIR/$CONFIG_NAME"
        chmod 600 "$INSTALL_DIR/$CONFIG_NAME"
        echo -e "${GREEN}✔ Конфиг перемещён:${NC}  $SCRIPT_DIR/$CONFIG_NAME"
        echo -e "            ${BLUE}→${NC} $INSTALL_DIR/$CONFIG_NAME"
    fi
    rm -f "$SCRIPT_PATH"
    echo -e "${GREEN}✔ Скрипт перемещён:${NC}  $SCRIPT_DIR/$SCRIPT_NAME"
    echo -e "            ${BLUE}→${NC} $INSTALL_DIR/$SCRIPT_NAME"
    echo ""
    echo -e "${YELLOW}  Продолжаем из нового расположения...${NC}"
    sleep 2
    touch "$INSTALL_DIR/.check_update" 2>/dev/null || true
    exec bash "$INSTALL_DIR/$SCRIPT_NAME" "$@"
fi

mkdir -p "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR"

SETUP_LOG="$INSTALL_DIR/setup-server.log"
CONFIG_FILE="$INSTALL_DIR/$CONFIG_NAME"

# ── Вспомогательные функции ──────────────────────────────────
ldef_set() {
    local key=$1 val=$2
    if grep -q "^${key}[[:space:]]" /etc/login.defs; then
        sed -i "s/^${key}[[:space:]].*/$(printf '%s   %s' "$key" "$val")/" /etc/login.defs
    else
        echo "${key}   ${val}" >> /etc/login.defs
    fi
}

sshd_set() {
    local key=$1 value=$2
    if grep -qE "^#?[[:space:]]*${key}[[:space:]]" /etc/ssh/sshd_config; then
        sed -i -E "s|^#?[[:space:]]*${key}[[:space:]].*|${key} ${value}|" /etc/ssh/sshd_config
    else
        echo "${key} ${value}" >> /etc/ssh/sshd_config
    fi
}

save_config() {
    {
        echo "DEPLOY_USER=$(printf '%q' "${DEPLOY_USER:-}")"
        echo "SERVER_HOSTNAME=$(printf '%q' "${SERVER_HOSTNAME:-}")"
        echo "TIMEZONE=$(printf '%q' "${TIMEZONE:-}")"
        echo "USER_PASS=$(printf '%q' "${USER_PASS:-}")"
        echo "YOUR_SSH_PUBKEY=$(printf '%q' "${YOUR_SSH_PUBKEY:-}")"
        echo "SSH_PORT=$(printf '%q' "${SSH_PORT:-}")"
        echo "DISABLE_RESOLVED=$(printf '%q' "${DISABLE_RESOLVED:-}")"
        echo "REMOVE_ZABBIX=$(printf '%q' "${REMOVE_ZABBIX:-}")"
        if declare -p EXTRA_PORTS &>/dev/null 2>&1; then
            declare -p EXTRA_PORTS
        else
            echo "EXTRA_PORTS=()"
        fi
        echo "ACME_EMAIL=$(printf '%q' "${ACME_EMAIL:-}")"
        echo "DOMAIN=$(printf '%q' "${DOMAIN:-}")"
        echo "VLESS_PORT=$(printf '%q' "${VLESS_PORT:-}")"
        echo "NODE_PORT=$(printf '%q' "${NODE_PORT:-}")"
        echo "SECRET_KEY=$(printf '%q' "${SECRET_KEY:-}")"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

config_is_complete() {
    [[ -n "${DEPLOY_USER:-}"      && -n "${SERVER_HOSTNAME:-}" &&
       -n "${TIMEZONE:-}"         && -n "${USER_PASS:-}"       &&
       -n "${YOUR_SSH_PUBKEY:-}"  && -n "${SSH_PORT:-}"        &&
       -n "${DISABLE_RESOLVED+x}" && -n "${REMOVE_ZABBIX+x}"  &&
       -n "${EXTRA_PORTS+x}"      &&
       -n "${ACME_EMAIL:-}"       && -n "${DOMAIN:-}"          &&
       -n "${VLESS_PORT:-}"      && -n "${NODE_PORT:-}"       &&
       -n "${SECRET_KEY:-}" ]]
}

echo "=== Setup $(date) ===" > "$SETUP_LOG"

clear
echo -e "${BLUE}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   Ubuntu 24.04 - Server Setup Script     ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "                                     v${VERSION}${NC}"

# ── Проверка обновления (только при первом запуске из install dir) ──
if [[ -f "$INSTALL_DIR/.check_update" ]]; then
    rm -f "$INSTALL_DIR/.check_update"
    check_and_update
fi

# ── Загрузка конфига ─────────────────────────────────────────
USE_SAVED=false
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE" 2>/dev/null || true
    if config_is_complete; then
        USE_SAVED=true
        sep
        echo -e "${YELLOW}Найден заполненный конфиг:${NC}"
        echo "  Пользователь    : $DEPLOY_USER"
        echo "  Hostname        : $SERVER_HOSTNAME"
        echo "  Timezone        : $TIMEZONE"
        echo "  Пароль          : $USER_PASS"
        echo "  SSH ключ        : ${YOUR_SSH_PUBKEY:0:40}..."
        echo "  SSH порт        : $SSH_PORT"
        [[ "$DISABLE_RESOLVED" == "y" ]] \
            && echo "  systemd-resolved: отключить" \
            || echo "  systemd-resolved: оставить"
        [[ "$REMOVE_ZABBIX" == "y" ]] \
            && echo "  Zabbix Agent    : удалить" \
            || echo "  Zabbix Agent    : оставить"
        if [[ ${#EXTRA_PORTS[@]} -eq 0 ]]; then
            echo "  Доп. порты      : нет"
        else
            for ENTRY in "${EXTRA_PORTS[@]}"; do
                echo "  Доп. порт       : ${ENTRY%%|*}  (${ENTRY##*|})"
            done
        fi
        echo "  Email           : $ACME_EMAIL"
        echo "  Домен           : $DOMAIN"
        echo "  VLESS порт      : $VLESS_PORT"
        echo "  NODE_PORT       : $NODE_PORT"
        echo "  SECRET_KEY      : ${SECRET_KEY:0:20}..."
        sep
        echo ""
        read -rp "Использовать? [Y/n]: " _USE_CONF
        if [[ "${_USE_CONF,,}" == "n" ]]; then
            USE_SAVED=false
            unset DEPLOY_USER SERVER_HOSTNAME TIMEZONE USER_PASS YOUR_SSH_PUBKEY \
                  SSH_PORT DISABLE_RESOLVED REMOVE_ZABBIX EXTRA_PORTS \
                  ACME_EMAIL DOMAIN VLESS_PORT NODE_PORT SECRET_KEY
            echo ""
        fi
    else
        # Частичный конфиг — показываем что уже заполнено
        sep
        echo -e "${YELLOW}Найден частичный конфиг — продолжаем с того места:${NC}"
        [[ -n "${DEPLOY_USER:-}"     ]] && echo -e "  ${GREEN}✔${NC} Пользователь : $DEPLOY_USER"
        [[ -n "${SERVER_HOSTNAME:-}" ]] && echo -e "  ${GREEN}✔${NC} Hostname      : $SERVER_HOSTNAME"
        [[ -n "${TIMEZONE:-}"        ]] && echo -e "  ${GREEN}✔${NC} Timezone      : $TIMEZONE"
        [[ -n "${USER_PASS:-}"       ]] && echo -e "  ${GREEN}✔${NC} Пароль        : задан"
        [[ -n "${YOUR_SSH_PUBKEY:-}" ]] && echo -e "  ${GREEN}✔${NC} SSH ключ      : ${YOUR_SSH_PUBKEY:0:40}..."
        [[ -n "${SSH_PORT:-}"        ]] && echo -e "  ${GREEN}✔${NC} SSH порт      : $SSH_PORT"
        [[ -n "${DISABLE_RESOLVED:-}" ]] && echo -e "  ${GREEN}✔${NC} systemd-resolved: $DISABLE_RESOLVED"
        [[ -n "${REMOVE_ZABBIX:-}"   ]] && echo -e "  ${GREEN}✔${NC} Zabbix        : $REMOVE_ZABBIX"
        declare -p EXTRA_PORTS &>/dev/null 2>&1 \
            && echo -e "  ${GREEN}✔${NC} Доп. порты    : ${#EXTRA_PORTS[@]} шт."
        [[ -n "${ACME_EMAIL:-}"      ]] && echo -e "  ${GREEN}✔${NC} Email         : $ACME_EMAIL"
        [[ -n "${DOMAIN:-}"          ]] && echo -e "  ${GREEN}✔${NC} Домен         : $DOMAIN"
        [[ -n "${VLESS_PORT:-}"      ]] && echo -e "  ${GREEN}✔${NC} VLESS порт    : $VLESS_PORT"
        [[ -n "${NODE_PORT:-}"       ]] && echo -e "  ${GREEN}✔${NC} NODE_PORT     : $NODE_PORT"
        [[ -n "${SECRET_KEY:-}"      ]] && echo -e "  ${GREEN}✔${NC} SECRET_KEY    : задан"
        sep
        echo ""
        read -rp "Продолжить с сохранёнными данными? [Y/n]: " _CONT_CONF
        if [[ "${_CONT_CONF,,}" == "n" ]]; then
            unset DEPLOY_USER SERVER_HOSTNAME TIMEZONE USER_PASS YOUR_SSH_PUBKEY \
                  SSH_PORT DISABLE_RESOLVED REMOVE_ZABBIX EXTRA_PORTS \
                  ACME_EMAIL DOMAIN VLESS_PORT NODE_PORT SECRET_KEY
        fi
        echo ""
    fi
fi

# ── Сбор параметров ──────────────────────────────────────────
if [[ "$USE_SAVED" == false ]]; then

    # ── Блок СЕРВЕР ──────────────────────────────────────────
    sep; info "Параметры сервера"; sep; echo ""

    if [[ -z "${TIMEZONE:-}" ]]; then
        read -rp "Timezone (пример: Europe/Moscow, Asia/Yekaterinburg): " TIMEZONE
        echo ""; save_config
    else
        ok "Timezone: $TIMEZONE (из конфига)"
    fi

    if [[ -z "${SERVER_HOSTNAME:-}" ]]; then
        read -rp "Имя хоста сервера: " SERVER_HOSTNAME
        echo ""; save_config
    else
        ok "Hostname: $SERVER_HOSTNAME (из конфига)"
    fi

    if [[ -z "${DEPLOY_USER:-}" ]]; then
        read -rp "Имя нового пользователя (sudo): " DEPLOY_USER
        echo ""; save_config
    else
        ok "Пользователь: $DEPLOY_USER (из конфига)"
    fi

    if [[ -z "${USER_PASS:-}" ]]; then
        SUGGESTED_PASS=$(gen_password)
        echo "Пароль для $DEPLOY_USER:"
        echo -e "  Предложение: ${GREEN}$SUGGESTED_PASS${NC}"
        read -rp "  Enter = использовать, или введи свой: " USER_PASS
        USER_PASS=${USER_PASS:-$SUGGESTED_PASS}
        echo ""; save_config
    else
        ok "Пароль: задан (из конфига)"
    fi

    if [[ -z "${YOUR_SSH_PUBKEY:-}" ]]; then
        echo "Вставь публичный SSH-ключ (ssh-ed25519 AAAA...) и нажми Enter:"
        read -rp "> " YOUR_SSH_PUBKEY
        echo ""; save_config
    else
        ok "SSH ключ: ${YOUR_SSH_PUBKEY:0:40}... (из конфига)"
    fi

    if [[ -z "${SSH_PORT:-}" ]]; then
        SUGGESTED_SSH_PORT=$(shuf -i 49152-65535 -n 1)
        read -rp "SSH порт [Enter = $SUGGESTED_SSH_PORT]: " SSH_PORT
        SSH_PORT=${SSH_PORT:-$SUGGESTED_SSH_PORT}
        echo ""; save_config
    else
        ok "SSH порт: $SSH_PORT (из конфига)"
    fi

    if [[ -z "${DISABLE_RESOLVED:-}" ]]; then
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            warn "Обнаружен systemd-resolved (порт 53)"
            echo "  Слушает только на 127.0.0.53, но vps-audit считает его открытым."
            echo "  При отключении DNS → 1.1.1.1 / 8.8.8.8"
            read -rp "  Отключить? [y/N]: " DISABLE_RESOLVED
            DISABLE_RESOLVED=${DISABLE_RESOLVED,,}
            echo ""
        else
            DISABLE_RESOLVED="n"
        fi
        save_config
    else
        ok "systemd-resolved: $DISABLE_RESOLVED (из конфига)"
    fi

    if [[ -z "${REMOVE_ZABBIX:-}" ]]; then
        if dpkg-query -W 'zabbix*' 2>/dev/null | grep -q .; then
            warn "Обнаружен Zabbix Agent (порт 10050)"
            echo "  Обычно устанавливается провайдером. Удаление закроет порт 10050."
            read -rp "  Удалить? [y/N]: " REMOVE_ZABBIX
            REMOVE_ZABBIX=${REMOVE_ZABBIX,,}
            echo ""
        else
            REMOVE_ZABBIX="n"
        fi
        save_config
    else
        ok "Zabbix: $REMOVE_ZABBIX (из конфига)"
    fi

    if ! declare -p EXTRA_PORTS &>/dev/null 2>&1; then
        EXTRA_PORTS=()
        echo "Доп. порты в UFW (80 и 443 уже включены)."
        echo "Формат: PORT/PROTOCOL COMMENT  (пример: 9443/tcp nginx-alt)"
        echo "Пустая строка — завершить."
        echo ""
        while true; do
            read -rp "Доп. порт: " EXTRA
            [[ -z "$EXTRA" ]] && break
            PORT_PROTO=$(echo "$EXTRA" | awk '{print $1}')
            COMMENT=$(echo "$EXTRA" | cut -d' ' -f2-)
            if [[ "$PORT_PROTO" =~ ^[0-9]+/(tcp|udp)$ ]]; then
                EXTRA_PORTS+=("$PORT_PROTO|${COMMENT:-custom}")
                ok "Добавлен: $PORT_PROTO (${COMMENT:-custom})"
            else
                warn "Неверный формат (пример: 9443/tcp nginx-alt)"
            fi
        done
        save_config
    else
        ok "Доп. порты: ${#EXTRA_PORTS[@]} шт. (из конфига)"
    fi

    # ── Блок НОДА ────────────────────────────────────────────
    echo ""
    sep; info "Параметры Remnawave Node"; sep; echo ""

    if [[ -z "${ACME_EMAIL:-}" ]]; then
        read -rp "Email для acme.sh (Let's Encrypt): " ACME_EMAIL
        echo ""; save_config
    else
        ok "Email: $ACME_EMAIL (из конфига)"
    fi

    if [[ -z "${DOMAIN:-}" ]]; then
        read -rp "Домен для SSL-сертификата (пример: node1.example.com): " DOMAIN
        DOMAIN="${DOMAIN// /}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%/}"
        echo ""; save_config
    else
        ok "Домен: $DOMAIN (из конфига)"
    fi

    if [[ -z "${VLESS_PORT:-}" ]]; then
        SUGGESTED_VLESS_PORT=$(shuf -i 10000-65535 -n 1)
        read -rp "VLESS Reality порт [Enter = $SUGGESTED_VLESS_PORT]: " VLESS_PORT
        VLESS_PORT=${VLESS_PORT:-$SUGGESTED_VLESS_PORT}
        echo ""; save_config
    else
        ok "VLESS порт: $VLESS_PORT (из конфига)"
    fi

    if [[ -z "${NODE_PORT:-}" ]]; then
        read -rp "NODE_PORT (из панели Remnawave): " NODE_PORT
        echo ""; save_config
    else
        ok "NODE_PORT: $NODE_PORT (из конфига)"
    fi

    if [[ -z "${SECRET_KEY:-}" ]]; then
        echo "SECRET_KEY (из панели Remnawave, вставь и нажми Enter):"
        read -rp "> " SECRET_KEY
        echo ""; save_config
    else
        ok "SECRET_KEY: задан (из конфига)"
    fi
    echo ""

fi  # конец ввода параметров

# ── Итоговое подтверждение ───────────────────────────────────
echo ""
sep
echo "  Будет применено:"
echo "  Пользователь    : $DEPLOY_USER"
echo "  Hostname        : $SERVER_HOSTNAME"
echo "  Timezone        : $TIMEZONE"
echo "  Пароль          : $USER_PASS"
echo "  SSH ключ        : ${YOUR_SSH_PUBKEY:0:40}..."
echo "  SSH порт        : $SSH_PORT"
[[ "$DISABLE_RESOLVED" == "y" ]] \
    && echo "  systemd-resolved: отключить → DNS: 1.1.1.1 / 8.8.8.8" \
    || echo "  systemd-resolved: оставить"
[[ "$REMOVE_ZABBIX" == "y" ]] \
    && echo "  Zabbix Agent    : удалить" \
    || echo "  Zabbix Agent    : оставить"
if [[ ${#EXTRA_PORTS[@]} -eq 0 ]]; then
    echo "  Доп. порты      : нет"
else
    for ENTRY in "${EXTRA_PORTS[@]}"; do
        echo "  Доп. порт       : ${ENTRY%%|*}  (${ENTRY##*|})"
    done
fi
echo "  Email           : $ACME_EMAIL"
echo "  Домен           : $DOMAIN"
echo "  VLESS порт      : $VLESS_PORT"
echo "  NODE_PORT       : $NODE_PORT"
echo "  SECRET_KEY      : ${SECRET_KEY:0:20}..."
sep
echo ""
read -rp "Всё верно? Начать настройку? [y/N]: " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && err "Отменено."

save_config
ok "Параметры сохранены → $CONFIG_FILE"

# ════════════════════════════════════════════════════════════
#  ПУНКТ 1 — Базовая настройка
# ════════════════════════════════════════════════════════════
echo ""
sep; info "ПУНКТ 1 — Базовая настройка системы"; sep

qs "Обновляем пакеты (apt update)" apt-get update
qs "Устанавливаем обновления (apt upgrade)" apt-get upgrade -y
echo ""

q timedatectl set-timezone "$TIMEZONE"
q systemctl enable --now systemd-timesyncd
q timedatectl set-ntp true
ok "Timezone: $TIMEZONE, NTP включён"

q hostnamectl set-hostname "$SERVER_HOSTNAME"
grep -q "$SERVER_HOSTNAME" /etc/hosts \
    || echo "127.0.1.1 $SERVER_HOSTNAME" >> /etc/hosts
ok "Hostname: $SERVER_HOSTNAME"

if id "$DEPLOY_USER" &>/dev/null; then
    echo "$DEPLOY_USER:$USER_PASS" | chpasswd >> "$SETUP_LOG" 2>&1
    warn "Пользователь $DEPLOY_USER уже существует — пароль и ключ обновлены"
else
    q adduser --gecos "" --disabled-password "$DEPLOY_USER"
    echo "$DEPLOY_USER:$USER_PASS" | chpasswd >> "$SETUP_LOG" 2>&1
    q usermod -aG sudo "$DEPLOY_USER"
    ok "Пользователь $DEPLOY_USER создан"
fi

mkdir -p "/home/$DEPLOY_USER/.ssh"
echo "$YOUR_SSH_PUBKEY" > "/home/$DEPLOY_USER/.ssh/authorized_keys"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
chmod 700 "/home/$DEPLOY_USER/.ssh"
chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
ok "SSH-ключ обновлён"

# ════════════════════════════════════════════════════════════
#  ПУНКТ 2 — SSH
# ════════════════════════════════════════════════════════════
echo ""
sep; info "ПУНКТ 2 — Настройка SSH"; sep

SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"
ok "Бэкап: ${SSHD_CONFIG}.bak"

rm -f /etc/ssh/sshd_config.d/99-hardening.conf
ok "Очищены старые конфиги .d/"

sshd_set Port                   "$SSH_PORT"
sshd_set PermitRootLogin        "no"
sshd_set PasswordAuthentication "no"
sshd_set PubkeyAuthentication   "yes"
sshd_set AuthorizedKeysFile     ".ssh/authorized_keys"
sshd_set PermitEmptyPasswords   "no"
sshd_set X11Forwarding          "no"
sshd_set AllowAgentForwarding   "no"
sshd_set AllowTcpForwarding     "no"
sshd_set ClientAliveInterval    "300"
sshd_set ClientAliveCountMax    "3"
sshd_set AddressFamily          "inet"
sshd_set Banner                 "/etc/ssh/banner"
ok "sshd_config обновлён"

for conf in /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "$conf" ]] || continue
    if grep -qi "PasswordAuthentication" "$conf"; then
        sed -i 's/^.*PasswordAuthentication.*/PasswordAuthentication no/' "$conf"
        ok "Исправлен override: $(basename "$conf")"
    fi
done

cat > /etc/ssh/banner << 'BANNER'
############################################################
#           Authorized access only!                        #
#     All activity is monitored and logged.                #
############################################################
BANNER

qo systemctl stop    --quiet ssh.socket
qo systemctl disable --quiet ssh.socket
q  systemctl daemon-reload
mkdir -p /run/sshd
sshd -t >> "$SETUP_LOG" 2>&1 || err "SSH конфиг невалиден, смотри $SETUP_LOG"
ok "SSH конфиг валиден"
q systemctl restart ssh
ok "SSH перезапущен на порту $SSH_PORT"

echo ""
warn "ВАЖНО: SSH теперь на порту $SSH_PORT"
warn "Открой ВТОРОЙ терминал и проверь вход:"
warn "  ssh -p $SSH_PORT $DEPLOY_USER@<IP>"
warn "Только после успешного входа нажми Enter!"
read -rp "Вход на порту $SSH_PORT проверен и работает? [y/N]: " SSH_CHECK
[[ "$SSH_CHECK" != "y" && "$SSH_CHECK" != "Y" ]] \
    && err "Прервано. Восстанови: cp ${SSHD_CONFIG}.bak $SSHD_CONFIG && systemctl restart ssh"

# ════════════════════════════════════════════════════════════
#  ПУНКТ 3 — UFW
# ════════════════════════════════════════════════════════════
echo ""
sep; info "ПУНКТ 3 — Настройка UFW"; sep

q ufw --force reset
q ufw default deny incoming
q ufw default allow outgoing
q ufw allow "$SSH_PORT/tcp" comment 'SSH'
q ufw limit  "$SSH_PORT/tcp"
q ufw allow  80/tcp  comment 'HTTP'
q ufw allow  443/tcp comment 'HTTPS'

for ENTRY in "${EXTRA_PORTS[@]}"; do
    PORT_PROTO="${ENTRY%%|*}"; COMMENT="${ENTRY##*|}"
    q ufw allow "$PORT_PROTO" comment "$COMMENT"
    ok "Открыт: $PORT_PROTO ($COMMENT)"
done

q ufw --force enable
ok "UFW включён"

mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
ok "Docker daemon.json настроен"

# ════════════════════════════════════════════════════════════
#  ПУНКТ 3.5 — Опциональные сервисы
# ════════════════════════════════════════════════════════════
if [[ "$DISABLE_RESOLVED" == "y" ]] || [[ "$REMOVE_ZABBIX" == "y" ]]; then
    echo ""
    sep; info "ПУНКТ 3.5 — Опциональные сервисы"; sep
fi

if [[ "$DISABLE_RESOLVED" == "y" ]]; then
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        qo systemctl stop    --quiet systemd-resolved
        qo systemctl disable --quiet systemd-resolved
        rm -f /etc/resolv.conf
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
        ok "systemd-resolved отключён, DNS: 1.1.1.1 / 8.8.8.8"
    else
        ok "systemd-resolved уже неактивен — пропускаем"
    fi
fi

if [[ "$REMOVE_ZABBIX" == "y" ]]; then
    mapfile -t _ZBXPKGS < <(dpkg-query -W -f='${Package}\n' 'zabbix*' 2>/dev/null)
    if [[ ${#_ZBXPKGS[@]} -gt 0 ]]; then
        for _svc in zabbix-agent zabbix-agent2 zabbix-agentd; do
            qo systemctl stop    "$_svc"
            qo systemctl disable "$_svc"
        done
        qs "Удаляем Zabbix Agent (${_ZBXPKGS[*]})" \
            dpkg --purge "${_ZBXPKGS[@]}"
        qo apt-get autoremove -y
        ok "Zabbix Agent удалён"
    else
        ok "Zabbix Agent уже удалён — пропускаем"
    fi
fi

# ════════════════════════════════════════════════════════════
#  ПУНКТ 4 — Fail2ban
# ════════════════════════════════════════════════════════════
echo ""
sep; info "ПУНКТ 4 — Fail2ban"; sep

qs "Устанавливаем Fail2ban" apt-get install -y fail2ban

cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 ::1
backend  = systemd

[sshd]
enabled  = true
port     = $SSH_PORT
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 86400

[nginx-http-auth]
enabled  = true
port     = http,https
filter   = nginx-http-auth
logpath  = %(nginx_error_log)s
maxretry = 5
bantime  = 3600

[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = %(nginx_access_log)s
maxretry = 2
bantime  = 86400
EOF

cat > /etc/fail2ban/paths-common.local << 'EOF'
[DEFAULT]
nginx_access_log = /opt/nginx/nginx-logs/access.log
nginx_error_log  = /opt/nginx/nginx-logs/error.log
EOF

q systemctl enable fail2ban
q systemctl restart fail2ban
ok "Fail2ban запущен"

# ════════════════════════════════════════════════════════════
#  ПУНКТ 5 — Автообновления
# ════════════════════════════════════════════════════════════
echo ""
sep; info "ПУНКТ 5 — Автообновления (только security)"; sep

qs "Устанавливаем unattended-upgrades" \
    apt-get install -y unattended-upgrades apt-listchanges

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
    "linux-image*";
    "linux-headers*";
    "linux-modules*";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::SyslogEnable "true";
EOF

q systemctl enable unattended-upgrades
q systemctl restart unattended-upgrades
ok "Автообновления включены"

# ════════════════════════════════════════════════════════════
#  ПУНКТ 6 — Sudo + пароли
# ════════════════════════════════════════════════════════════
echo ""
sep; info "ПУНКТ 6 — Sudo и политика паролей"; sep

if ! grep -q 'Defaults logfile' /etc/sudoers; then
    echo 'Defaults logfile="/var/log/sudo.log"' >> /etc/sudoers
fi
if ! grep -q 'Defaults syslog=auth' /etc/sudoers; then
    echo 'Defaults syslog=auth' >> /etc/sudoers
fi
touch /var/log/sudo.log
chmod 640 /var/log/sudo.log
ok "Sudo-логирование: /var/log/sudo.log"

qs "Устанавливаем libpam-pwquality" apt-get install -y libpam-pwquality

cat > /etc/security/pwquality.conf << 'EOF'
minlen     = 12
dcredit    = -1
ucredit    = -1
lcredit    = -1
ocredit    = -1
minclass   = 3
maxrepeat  = 3
gecoscheck = 1
dictcheck  = 1
EOF

ldef_set PASS_MAX_DAYS 90
ldef_set PASS_MIN_DAYS 1
ldef_set PASS_WARN_AGE 14
ldef_set PASS_MIN_LEN  16

DEBIAN_FRONTEND=noninteractive pam-auth-update --enable pwquality \
    >> "$SETUP_LOG" 2>&1 || true

if ! grep -q 'pam_pwquality.so' /etc/pam.d/common-password; then
    awk '/^password.*pam_unix\.so/ && !ins {
        print "password\trequisite\t\t\tpam_pwquality.so retry=3 enforce_for_root"
        ins=1
    }
    { print }' /etc/pam.d/common-password > /tmp/_cpw.tmp \
    && mv /tmp/_cpw.tmp /etc/pam.d/common-password
    ok "pam_pwquality.so добавлен в common-password"
fi

q chage --maxdays 90 --mindays 1 --warndays 14 "$DEPLOY_USER"
ok "Политика паролей: min 12 символов, срок 90 дней"

# ════════════════════════════════════════════════════════════
#  ПУНКТ 7 — vps-audit
# ════════════════════════════════════════════════════════════
echo ""
sep; info "ПУНКТ 7 — Финальная проверка vps-audit"; sep

bash <(curl -s https://raw.githubusercontent.com/vernu/vps-audit/main/vps-audit.sh)

# ── Итог фазы 1 ──────────────────────────────────────────────
echo ""
sep
echo -e "${GREEN}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║     Первичная настройка завершена!       ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"
echo "  Пользователь : $DEPLOY_USER"
echo "  Пароль       : $USER_PASS"
echo "  Hostname     : $SERVER_HOSTNAME"
echo "  SSH порт     : $SSH_PORT"
echo ""
warn "Не забудь:"
echo "  • Обновлять ядро вручную: apt upgrade linux-image-* && reboot"
echo "  • Том логов nginx: ./nginx-logs:/var/log/nginx"
sep

# ── Переход к Фазе 2 ─────────────────────────────────────────
echo ""
read -rp "Продолжить установку Remnawave Node? [y/N]: " DO_DEPLOY
if [[ "$DO_DEPLOY" == "y" || "$DO_DEPLOY" == "Y" ]]; then
    echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/99-deploy
    chmod 440 /etc/sudoers.d/99-deploy

    cp "$INSTALL_DIR/$SCRIPT_NAME" "$DEPLOY_SCRIPT"
    chmod 755 "$DEPLOY_SCRIPT"
    cp "$INSTALL_DIR/$CONFIG_NAME" "$DEPLOY_CONFIG"
    chown "root:$DEPLOY_USER" "$DEPLOY_CONFIG"
    chmod 640 "$DEPLOY_CONFIG"

    echo ""
    info "Переключаемся на $DEPLOY_USER для деплоя ноды..."
    sleep 1
    exec sudo -u "$DEPLOY_USER" bash "$DEPLOY_SCRIPT" --deploy
else
    ok "Готово. Для деплоя ноды запусти позже:"
    echo "    sudo bash $INSTALL_DIR/$SCRIPT_NAME --deploy"
fi

fi  # конец DEPLOY_PHASE == false

# ════════════════════════════════════════════════════════════
#  ФАЗА 2 — DEPLOY_USER: деплой Remnawave Node
# ════════════════════════════════════════════════════════════
if [[ "$DEPLOY_PHASE" == true ]]; then

# Если запущен от root с --deploy (отложенный деплой) — переходим на DEPLOY_USER
if [[ $EUID -eq 0 ]]; then
    _ROOT_CFG="$INSTALL_DIR/$CONFIG_NAME"
    [[ -f "$_ROOT_CFG" ]] && source "$_ROOT_CFG" 2>/dev/null || true
    [[ -z "${DEPLOY_USER:-}" ]] && {
        echo -e "${RED}✖ DEPLOY_USER не найден в конфиге $INSTALL_DIR/$CONFIG_NAME${NC}"; exit 1
    }
    echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/99-deploy
    chmod 440 /etc/sudoers.d/99-deploy
    cp "$INSTALL_DIR/$SCRIPT_NAME" "$DEPLOY_SCRIPT"
    chmod 755 "$DEPLOY_SCRIPT"
    cp "$_ROOT_CFG" "$DEPLOY_CONFIG"
    chown "root:$DEPLOY_USER" "$DEPLOY_CONFIG"
    chmod 640 "$DEPLOY_CONFIG"
    echo -e "${BLUE}▶ Переключаемся на $DEPLOY_USER для деплоя...${NC}"
    sleep 1
    exec sudo -u "$DEPLOY_USER" bash "$DEPLOY_SCRIPT" --deploy
fi

# Загружаем конфиг
CONFIG_FILE="$DEPLOY_CONFIG"
[[ -f "$CONFIG_FILE" ]] || {
    echo -e "${RED}✖ Конфиг $CONFIG_FILE не найден${NC}"; exit 1
}
# shellcheck source=/dev/null
source "$CONFIG_FILE"

[[ "$(whoami)" != "$DEPLOY_USER" ]] && {
    echo -e "${RED}✖ Фаза деплоя должна запускаться от $DEPLOY_USER${NC}"; exit 1
}

SETUP_LOG="/tmp/remnawave-deploy.log"
echo "=== Remnawave Deploy $(date) ===" > "$SETUP_LOG"

# ── Cleanup при прерывании / ошибке ─────────────────────────
_LOGS_PID=""; _NGLOGS_PID=""; _LOGFIFO=""; _NGXFIFO=""
_DEPLOY_SUCCESS=false

_cleanup_deploy() {
    [[ -n "${_LOGS_PID}" ]]   && kill "${_LOGS_PID}"   2>/dev/null || true
    [[ -n "${_NGLOGS_PID}" ]] && kill "${_NGLOGS_PID}" 2>/dev/null || true
    rm -f "${_LOGFIFO}" "${_NGXFIFO}" 2>/dev/null || true
    rm -f "$DEPLOY_CONFIG" 2>/dev/null || true
    sudo rm -f "$DEPLOY_SCRIPT" 2>/dev/null || true
    sudo rm -f "$INSTALL_DIR/$CONFIG_NAME" 2>/dev/null || true
    sudo rm -f /etc/sudoers.d/99-deploy 2>/dev/null || true
    if [[ "$_DEPLOY_SUCCESS" != true ]]; then
        echo ""
        warn "Деплой прерван. Для повтора: sudo bash $INSTALL_DIR/$SCRIPT_NAME --deploy"
    fi
}
trap '_cleanup_deploy' EXIT INT TERM

clear
echo -e "${BLUE}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   Remnawave Node - Deploy Script         ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"
echo "  Пользователь : $DEPLOY_USER"
echo "  Домен        : $DOMAIN"
echo "  VLESS порт   : $VLESS_PORT"
echo ""

# ── ШАГ 1: Docker ────────────────────────────────────────────
sep; info "ШАГ 1 — Docker Engine"; sep

if command -v docker &>/dev/null; then
    ok "Docker уже установлен: $(docker --version | cut -d' ' -f3 | tr -d ',')"
else
    qs "Устанавливаем зависимости" \
        sudo apt-get install -y ca-certificates curl gnupg

    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
        >> "$SETUP_LOG" 2>&1
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    qs "Обновляем индекс пакетов" sudo apt-get update
    qs "Устанавливаем Docker Engine" \
        sudo apt-get install -y \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
    ok "Docker установлен"
fi

if ! groups | grep -q '\bdocker\b'; then
    q sudo usermod -aG docker "$DEPLOY_USER"
    warn "$DEPLOY_USER добавлен в группу docker (без re-login используем sudo docker)"
fi
q sudo systemctl enable --now docker

# ── ШАГ 2: Remnawave Node ────────────────────────────────────
echo ""
sep; info "ШАГ 2 — Remnawave Node"; sep

sudo mkdir -p /opt/remnanode
sudo chown "$DEPLOY_USER:$DEPLOY_USER" /opt/remnanode
ok "Создан /opt/remnanode"

cat > /opt/remnanode/docker-compose.yml << COMPOSEYML
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=${NODE_PORT}
      - SECRET_KEY=${SECRET_KEY}
COMPOSEYML
ok "docker-compose.yml для Remnawave Node создан"

if sudo docker compose -f /opt/remnanode/docker-compose.yml config \
        >> "$SETUP_LOG" 2>&1; then
    ok "docker-compose.yml валиден"
else
    warn "Не удалось проверить синтаксис — продолжаем"
fi

# Открываем порты ноды
info "Открываем порты Remnawave Node в UFW..."

sudo ufw allow "${NODE_PORT}/tcp" comment 'Remnawave Node' \
    >> "$SETUP_LOG" 2>&1 || true
ok "UFW: открыт ${NODE_PORT}/tcp (NODE_PORT)"

sudo ufw allow 61000/tcp comment 'Remnawave Node gRPC' \
    >> "$SETUP_LOG" 2>&1 || true
ok "UFW: открыт 61000/tcp (Remnawave Node gRPC)"

sudo ufw allow "${VLESS_PORT}/tcp" comment 'Remnawave Node VLESS' \
    >> "$SETUP_LOG" 2>&1 || true
ok "UFW: открыт ${VLESS_PORT}/tcp (VLESS Reality)"

info "Поднимаем Remnawave Node..."
docker_up /opt/remnanode/docker-compose.yml "ноду"
ok "Нода запущена"

echo ""
warn "Ожидаем запуска ноды (авто-стоп по 'Xray started', таймаут 120с):"
echo ""
sleep 1

_LOGFIFO=$(mktemp -u /tmp/node-logs-XXXX)
mkfifo "$_LOGFIFO"
sudo docker compose -f /opt/remnanode/docker-compose.yml logs -f -t \
    2>/dev/null > "$_LOGFIFO" &
_LOGS_PID=$!

( sleep 120 && kill "$_LOGS_PID" 2>/dev/null ) &
_WATCHDOG_NODE_PID=$!

_NODE_LOG_FOUND=false
while IFS= read -r line; do
    printf '%s\n' "$line"
    if printf '%s' "$line" | grep -q 'Xray started'; then
        _NODE_LOG_FOUND=true; printf '\n'; break
    fi
done < "$_LOGFIFO"

kill "$_WATCHDOG_NODE_PID" 2>/dev/null || true
wait "$_WATCHDOG_NODE_PID" 2>/dev/null || true
kill "$_LOGS_PID" 2>/dev/null || true
wait "$_LOGS_PID" 2>/dev/null || true
rm -f "$_LOGFIFO"; _LOGFIFO=""
[[ "$_NODE_LOG_FOUND" == false ]] && \
    warn "Таймаут (120с) — паттерн 'Xray started' не найден, продолжаем..."

echo ""
read -rp "Нода работает корректно? [y/N]: " NODE_OK
if [[ "$NODE_OK" != "y" && "$NODE_OK" != "Y" ]]; then
    warn "Показываю логи (Ctrl+C для выхода):"
    echo ""
    sudo docker compose -f /opt/remnanode/docker-compose.yml logs -f -t 2>/dev/null || true
    err "Разберись с нодой и запусти скрипт заново: sudo bash $INSTALL_DIR/$SCRIPT_NAME --deploy"
fi

# ── ШАГ 3: cron + socat ──────────────────────────────────────
echo ""
sep; info "ШАГ 3 — cron, socat"; sep

qs "Устанавливаем cron и socat" \
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q cron socat
q sudo systemctl enable --now cron
ok "cron и socat готовы"

# ── ШАГ 4: acme.sh + SSL ─────────────────────────────────────
echo ""
sep; info "ШАГ 4 — acme.sh + SSL-сертификат"; sep

ACME="$HOME/.acme.sh/acme.sh"

if [[ -f "$ACME" ]]; then
    ok "acme.sh уже установлен"
else
    info "Устанавливаем acme.sh..."
    ( cd "$HOME" && curl -fsSL https://get.acme.sh | sh -s "email=$ACME_EMAIL" ) \
        >> "$SETUP_LOG" 2>&1 \
        || err "Ошибка установки acme.sh, смотри $SETUP_LOG"
    # shellcheck source=/dev/null
    source "$HOME/.bashrc" 2>/dev/null || true
    ok "acme.sh установлен ($ACME_EMAIL)"
fi

"$ACME" --set-default-ca --server letsencrypt >> "$SETUP_LOG" 2>&1 || true
ok "acme.sh CA: Let's Encrypt"

# Явная регистрация аккаунта. Если в ~/.acme.sh/ca осталось битое
# состояние от прошлых запусков (accountDoesNotExist) — сносим и
# регистрируем заново.
if ! "$ACME" --register-account --server letsencrypt -m "$ACME_EMAIL" \
        >> "$SETUP_LOG" 2>&1; then
    warn "Регистрация аккаунта не удалась — чистим состояние и повторяем..."
    rm -rf "$HOME/.acme.sh/ca"
    "$ACME" --register-account --server letsencrypt -m "$ACME_EMAIL" \
        >> "$SETUP_LOG" 2>&1 \
        || err "Не удалось зарегистрировать аккаунт acme.sh, смотри $SETUP_LOG"
fi
ok "acme.sh аккаунт зарегистрирован ($ACME_EMAIL)"

sudo mkdir -p /opt/nginx
sudo chown "$DEPLOY_USER:$DEPLOY_USER" /opt/nginx

info "Генерируем временный самоподписанный сертификат..."
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout /opt/nginx/privkey.key \
    -out /opt/nginx/fullchain.pem \
    -days 30 -nodes \
    -subj "/CN=$DOMAIN" >> "$SETUP_LOG" 2>&1 \
    || err "Не удалось создать самоподписанный сертификат"
ok "Временный сертификат создан (будет заменён реальным в шаге 5)"

# ── ШАГ 5: Nginx ─────────────────────────────────────────────
echo ""
sep; info "ШАГ 5 — Nginx"; sep

if ! sudo ufw status | grep -q "9443"; then
    q sudo ufw allow 9443/tcp comment 'Nginx SELF_STEAL'
    ok "UFW: 9443/tcp открыт"
else
    ok "UFW: 9443/tcp уже открыт"
fi

cat > /opt/nginx/nginx.conf << NGINXCONF
# Отвечает 204 на порту 9443 (SELF_STEAL_PORT)
server {
    listen 9443 ssl;
    listen [::]:9443 ssl;
    server_name _;

    ssl_certificate     /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.key;
    ssl_trusted_certificate /etc/nginx/ssl/fullchain.pem;

    return 204;
}

# Healthcheck на порту 80
server {
    listen 80;
    listen [::]:80;
    server_name _;

    return 204;
}

# HTTP → HTTPS редирект (с исключением для ACME challenge)
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# Основной HTTPS
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.key;
    ssl_trusted_certificate /etc/nginx/ssl/fullchain.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    location / {
        root /var/www/html;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    gzip on; gzip_vary on; gzip_proxied any;
    gzip_comp_level 6; gzip_buffers 16 8k;
    gzip_http_version 1.1; gzip_min_length 256;
    gzip_types application/javascript application/json
               text/css text/plain application/xml
               font/ttf font/otf image/svg+xml;
}

# Защита от лишних HTTPS соединений
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;

    ssl_reject_handshake on;
}
NGINXCONF
ok "nginx.conf создан (server_name: $DOMAIN)"

cat > /opt/nginx/docker-compose.yml << 'COMPOSEYML'
services:
  nginx:
    image: nginx:1.26
    container_name: nginx
    ports:
      - "80:80"
      - "443:443"
      - "9443:9443"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
      - ./privkey.key:/etc/nginx/ssl/privkey.key:ro
      - ./www:/var/www/html:ro
      - ./nginx-logs:/var/log/nginx
    restart: always
COMPOSEYML
ok "docker-compose.yml для nginx создан"

mkdir -p /opt/nginx/www /opt/nginx/nginx-logs

cat > /opt/nginx/www/index.html << 'HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Скоро</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { min-height: 100vh; display: flex; align-items: center;
           justify-content: center; background: #0d0d0d;
           font-family: 'Courier New', monospace; color: #e0e0e0; }
    .wrap { text-align: center; }
    .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%;
           background: #3b82f6; margin: 0 3px;
           animation: bounce 1.2s infinite ease-in-out; }
    .dot:nth-child(2) { animation-delay: .2s; }
    .dot:nth-child(3) { animation-delay: .4s; }
    @keyframes bounce { 0%,80%,100%{transform:scale(0)} 40%{transform:scale(1)} }
    h1 { margin-top: 1.5rem; font-size: 1.4rem; font-weight: 400; }
    p  { margin-top: .5rem; font-size: .8rem; color: #555; }
  </style>
</head>
<body>
  <div class="wrap">
    <div>
      <span class="dot"></span><span class="dot"></span><span class="dot"></span>
    </div>
    <h1>Сайт в разработке</h1>
    <p>Скоро здесь будет что-то интересное</p>
  </div>
</body>
</html>
HTML
ok "Заглушка /opt/nginx/www/index.html создана"

info "Поднимаем Nginx..."
docker_up /opt/nginx/docker-compose.yml "nginx"
ok "Nginx запущен (с временным сертификатом)"

echo ""
warn "Ожидаем запуска Nginx (авто-стоп по 'ready for start up', таймаут 60с):"
echo ""
sleep 1

_NGXFIFO=$(mktemp -u /tmp/nginx-logs-XXXX)
mkfifo "$_NGXFIFO"
sudo docker compose -f /opt/nginx/docker-compose.yml logs -f -t \
    2>/dev/null > "$_NGXFIFO" &
_NGLOGS_PID=$!

( sleep 60 && kill "$_NGLOGS_PID" 2>/dev/null ) &
_WATCHDOG_NGX_PID=$!

_NGX_LOG_FOUND=false
while IFS= read -r line; do
    printf '%s\n' "$line"
    if printf '%s' "$line" | grep -q 'ready for start up'; then
        _NGX_LOG_FOUND=true; printf '\n'; break
    fi
done < "$_NGXFIFO"

kill "$_WATCHDOG_NGX_PID" 2>/dev/null || true
wait "$_WATCHDOG_NGX_PID" 2>/dev/null || true
kill "$_NGLOGS_PID" 2>/dev/null || true
wait "$_NGLOGS_PID" 2>/dev/null || true
rm -f "$_NGXFIFO"; _NGXFIFO=""
[[ "$_NGX_LOG_FOUND" == false ]] && \
    warn "Таймаут (60с) — паттерн 'ready for start up' не найден, продолжаем..."

echo ""
read -rp "Nginx запустился корректно? [y/N]: " NGINX_INIT_OK
if [[ "$NGINX_INIT_OK" != "y" && "$NGINX_INIT_OK" != "Y" ]]; then
    warn "Показываю логи (Ctrl+C для выхода):"
    echo ""
    sudo docker compose -f /opt/nginx/docker-compose.yml logs -f -t 2>/dev/null || true
    err "Разберись с Nginx и запусти скрипт заново: sudo bash $INSTALL_DIR/$SCRIPT_NAME --deploy"
fi

# ── ШАГ 5.1 — Let's Encrypt (webroot) ────────────────────────
echo ""
sep; info "ШАГ 5.1 — Let's Encrypt сертификат (webroot)"; sep

mkdir -p /opt/nginx/www/.well-known/acme-challenge

# DNS-проверка
info "Проверяем DNS: $DOMAIN..."
_SERVER_IP=$(curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null \
    || curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null \
    || true)
_DOMAIN_IP=$(python3 -c "import socket; print(socket.gethostbyname('$DOMAIN'))" \
    2>/dev/null || true)

if [[ -z "$_DOMAIN_IP" ]]; then
    warn "DNS для $DOMAIN не разрешается — A-запись не найдена"
    echo "  Убедись, что A-запись создана и указывает на IP сервера."
    read -rp "  Продолжить всё равно? [y/N]: " _DNS_CONT
    [[ "${_DNS_CONT,,}" != "y" ]] && err "Отменено. Настрой DNS и повтори деплой."
elif [[ -n "$_SERVER_IP" && "$_DOMAIN_IP" != "$_SERVER_IP" ]]; then
    warn "DNS для $DOMAIN → $_DOMAIN_IP, но публичный IP: $_SERVER_IP"
    echo "  Возможно, DNS ещё не обновился (propagation до 1 часа)."
    read -rp "  Продолжить всё равно? [y/N]: " _DNS_CONT
    [[ "${_DNS_CONT,,}" != "y" ]] && err "Отменено. Дождись обновления DNS."
else
    ok "DNS: $DOMAIN → $_DOMAIN_IP"
fi

info "Получаем сертификат для $DOMAIN (HTTP-01 webroot)..."
_ISSUE_FORCE=""
while true; do
    if "$ACME" --issue --webroot /opt/nginx/www \
        -d "$DOMAIN" $_ISSUE_FORCE \
        --key-file /opt/nginx/privkey.key \
        --fullchain-file /opt/nginx/fullchain.pem \
        >> "$SETUP_LOG" 2>&1; then
        break
    fi
    echo ""
    warn "Не удалось получить сертификат для $DOMAIN"

    # Авто-восстановление при битом состоянии аккаунта
    # (accountDoesNotExist / No such challenge) — чистим ca и
    # регистрируемся заново, дальше выпускаем с --force.
    if tail -40 "$SETUP_LOG" | grep -qE "accountDoesNotExist|No such challenge"; then
        warn "Обнаружено битое состояние acme.sh — чистим аккаунт и кэш заказа..."
        rm -rf "$HOME/.acme.sh/ca"
        # Кэш заказа/challenge домена тоже привязан к мёртвому аккаунту —
        # без его удаления остаётся "No such challenge".
        rm -rf "$HOME/.acme.sh/${DOMAIN}_ecc" "$HOME/.acme.sh/${DOMAIN}"
        "$ACME" --register-account --server letsencrypt -m "$ACME_EMAIL" \
            >> "$SETUP_LOG" 2>&1 || true
        _ISSUE_FORCE="--force"
    fi

    echo "  Частые причины:"
    echo "    • DNS ещё не обновились (propagation до 1 часа)"
    echo "    • Порт 80 недоступен извне"
    echo "    • Таймаут у Let's Encrypt — попробуй ещё раз"
    echo "  Последние строки лога:"
    tail -20 "$SETUP_LOG" | sed 's/^/    /'
    echo ""
    read -rp "Попробовать ещё раз? [Y/n/q]: " _RETRY
    case "${_RETRY,,}" in
        n) warn "Пропускаем — используем текущий сертификат"; break ;;
        q) err "Получение сертификата отменено. Лог: $SETUP_LOG" ;;
        *) info "Повторяем..."; _ISSUE_FORCE="--force" ;;
    esac
done
ok "Сертификат → /opt/nginx/{fullchain.pem, privkey.key}"

sudo docker compose -f /opt/nginx/docker-compose.yml exec nginx nginx -s reload \
    >> "$SETUP_LOG" 2>&1 || true
ok "Nginx перезагружен с реальным сертификатом"

"$ACME" --install-cert -d "$DOMAIN" \
    --key-file /opt/nginx/privkey.key \
    --fullchain-file /opt/nginx/fullchain.pem \
    --reloadcmd "docker compose -f /opt/nginx/docker-compose.yml exec nginx nginx -s reload" \
    >> "$SETUP_LOG" 2>&1 || true
ok "Авторенью настроен (webroot — без остановки nginx)"

# ── Финальная проверка здоровья ──────────────────────────────
echo ""
sep; info "Финальная проверка"; sep
_HEALTH_OK=true

if sudo docker compose -f /opt/remnanode/docker-compose.yml ps 2>/dev/null \
        | grep -qiE 'Up|running'; then
    ok "Remnawave Node: запущена"
else
    warn "Remnawave Node: не запущена"
    _HEALTH_OK=false
fi

if sudo docker compose -f /opt/nginx/docker-compose.yml ps 2>/dev/null \
        | grep -qiE 'Up|running'; then
    ok "Nginx: запущен"
else
    warn "Nginx: не запущен"
    _HEALTH_OK=false
fi

if [[ -f /opt/nginx/fullchain.pem ]]; then
    _CERT_EXPIRY_STR=$(openssl x509 -enddate -noout \
        -in /opt/nginx/fullchain.pem 2>/dev/null | cut -d= -f2)
    _CERT_EPOCH=$(date -d "$_CERT_EXPIRY_STR" +%s 2>/dev/null || echo 0)
    _DAYS_LEFT=$(( (_CERT_EPOCH - $(date +%s)) / 86400 ))
    if [[ $_DAYS_LEFT -gt 7 ]]; then
        ok "SSL сертификат: действителен ещё $_DAYS_LEFT дней"
    elif [[ $_DAYS_LEFT -gt 0 ]]; then
        warn "SSL сертификат: истекает через $_DAYS_LEFT дней (скоро авторенью)"
    else
        warn "SSL сертификат: истёк или невалиден!"
        _HEALTH_OK=false
    fi
else
    warn "Сертификат /opt/nginx/fullchain.pem не найден"
    _HEALTH_OK=false
fi

for _chk_port in 80 443; do
    if sudo ss -tlnp 2>/dev/null | grep -qE ":${_chk_port}[[:space:]]|:${_chk_port}$"; then
        ok "Порт $_chk_port/tcp: слушает"
    else
        warn "Порт $_chk_port/tcp: не прослушивается"
        _HEALTH_OK=false
    fi
done

echo ""
if [[ "$_HEALTH_OK" == true ]]; then
    ok "Все проверки пройдены"
else
    warn "Некоторые проверки не прошли — смотри предупреждения выше"
fi

# ── Завершение ───────────────────────────────────────────────
_DEPLOY_SUCCESS=true

echo ""
read -rp "Удалить скрипт ($INSTALL_DIR/$SCRIPT_NAME)? [y/N]: " _DEL_SCRIPT

# Создаём deploy-info.txt
_CERT_EXPIRY_HUMAN=$(openssl x509 -enddate -noout \
    -in /opt/nginx/fullchain.pem 2>/dev/null | cut -d= -f2)
_CERT_EXPIRY_HUMAN="${_CERT_EXPIRY_HUMAN:-неизвестно}"
_UFW_PORTS=$(sudo ufw status 2>/dev/null \
    | awk '/ALLOW IN/{printf "%s ", $1}' || echo "неизвестно")
# _SERVER_IP уже вычислен выше при DNS-проверке; резервный вариант
_DEPLOY_SERVER_IP="${_SERVER_IP:-$(curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || echo '<IP сервера>')}"

sudo tee "$INSTALL_DIR/deploy-info.txt" > /dev/null << DEPLOYINFO
═══════════════════════════════════════════════
  Remnawave Node — Информация о деплое
═══════════════════════════════════════════════
Дата деплоя       : $(date '+%Y-%m-%d %H:%M %Z')
Hostname          : $SERVER_HOSTNAME
IP адрес          : $_DEPLOY_SERVER_IP
Пользователь      : $DEPLOY_USER
SSH порт          : $SSH_PORT
Email (acme.sh)   : $ACME_EMAIL
Домен             : $DOMAIN
VLESS порт        : $VLESS_PORT
NODE_PORT         : $NODE_PORT

Remnawave Node    : /opt/remnanode
Nginx             : /opt/nginx
Логи nginx        : /opt/nginx/nginx-logs/
Заглушка          : /opt/nginx/www/index.html

SSL действителен  : до $_CERT_EXPIRY_HUMAN
Открытые порты    : $_UFW_PORTS

Сертификаты acme.sh:
$("$ACME" --list 2>/dev/null || echo "  (недоступно)")

Дальнейшие шаги:
  1. Заменить заглушку: git clone <repo> /opt/nginx/www
  2. Re-login для docker без sudo:
       exit → ssh -p $SSH_PORT $DEPLOY_USER@$_DEPLOY_SERVER_IP
═══════════════════════════════════════════════
DEPLOYINFO
sudo chmod 644 "$INSTALL_DIR/deploy-info.txt"

if [[ "${_DEL_SCRIPT,,}" == "y" ]]; then
    sudo rm -f "$INSTALL_DIR/$SCRIPT_NAME" 2>/dev/null || true
    ok "Скрипт удалён"
fi

sep
echo -e "${GREEN}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║         Деплой завершён!                 ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"
sudo cat "$INSTALL_DIR/deploy-info.txt"
echo ""
ok "Файл сохранён: $INSTALL_DIR/deploy-info.txt"
sep

fi  # конец DEPLOY_PHASE == true
