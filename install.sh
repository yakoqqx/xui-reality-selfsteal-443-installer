#!/usr/bin/env bash

set -u
set -o pipefail

# НАСТРОЙКИ

SCRIPT_NAME="xui-reality-selfsteal-443-installer"
CONF_FILE="${CONF_FILE:-/root/.${SCRIPT_NAME}.conf}"
LOG_FILE="${LOG_FILE:-/root/${SCRIPT_NAME}.log}"

XUI_BIN="/usr/local/x-ui/x-ui"
XUI_DB="/etc/x-ui/x-ui.db"
XUI_INSTALL_RESULT="/etc/x-ui/install-result.env"
XRAY_CONFIG="/usr/local/x-ui/bin/config.json"
XUI_SUPPORTED_VERSION="v3.11.0"
declare -A XUI_SHA256=(
    [install.sh]="9684bae4f769b2127fcceceb4f200045657381311867529e6ba76c6b58e2825d"
    [x-ui.sh]="26c229d5fb3b184e81581b4b223b801582ca7cf5908aaedeb8d1c7c70ad4cc25"
    [x-ui-amd64]="fb7b3776334fce69299f90168c8c31377b69f89c7787088e6dbf561d07b3d345"
    [xray-amd64]="a27e3f95ab6ce270956d0cecd32eda4686a811afc71c64a6a734a3dede14883e"
    [x-ui-arm64]="053f4c0da86d6b6aff41af2aa7b579a62ebc3105ef5eac77fee5b79ab9a2a8a4"
    [xray-arm64]="dc3324f437132d70d29ddadea19b202949c2d1230b5d90dac469b03f68829c8b"
)
XUI_REPO="MHSanaei/3x-ui"
SPONSORS_EMPTY='{"success":true,"msg":"","obj":{"sponsors":[]}}'
ACME="/root/.acme.sh/acme.sh"
CERT_RENEW="/usr/local/sbin/cert-renew.sh"
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
NGINX_CONF_D="/etc/nginx/conf.d"
NGINX_REJECT_CONF="${NGINX_CONF_D}/00-reject-unknown-sni.conf"
NGINX_HTTP_REJECT_CONF="${NGINX_CONF_D}/00-http-reject.conf"
NGINX_REAL_IP_CONF="${NGINX_CONF_D}/30-real-ip.conf"
NGINX_PANEL_SNIPPETS="/etc/nginx/snippets/xui-panel*.conf"
NGINX_STUB_SNIPPETS="/etc/nginx/snippets/site-*.conf"
ACME_WEBROOT="/var/www/acme"

PUBLIC_TLS_PORT=443
HTTP_PORT=80
NGINX_ADDR="127.0.0.1"
NGINX_PORT=7443
REALITY_TARGET="${NGINX_ADDR}:${NGINX_PORT}"
XHTTP_DEFAULT_PORT=8081
REMARK_TEMPLATE="{{HOST}}|📊{{TRAFFIC_LEFT}}|⏳{{DAYS_LEFT}}D"
SUB_PORT=2096
PANEL_PORT=2053
XRAY_API_PORT=62789
HY2_PORT=443
ALT_SVC_LINE="    add_header Alt-Svc 'h3=\":${HY2_PORT}\"; ma=86400' always;"
INTERNAL_PORTS=("$NGINX_PORT" "$PANEL_PORT" "$SUB_PORT" "$XRAY_API_PORT")

DOMAIN_RE='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'
EMAIL_RE='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
FOLDER_RE='^[A-Za-z0-9._-]+$'
PATH_RE='^/?[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*/?$'
NAME_RE='^[A-Za-z0-9_-]+$'
USERNAME_RE='^[A-Za-z0-9_.-]{3,32}$'

CONF_KEYS=(LANGUAGE INSTALL_MODE DOMAIN CERT_FOLDER ACME_EMAIL XHTTP XHTTP_PORT XHTTP_PATH SUB_PATH PANEL_PATH XUI_USERNAME XUI_PASSWORD XUI_PASSWORD_HASH
    XUI_CREDENTIALS_PENDING XUI_VERIFY_PENDING HY2 WARP CLIENT_NAME)
declare -A CONF=()

RECONFIGURE=0
UNINSTALL=0
XUI_VERSION=""
CHECK_ONLY=0
FAIL_COUNT=0
IMPORT_DB=""
IMPORTED_NOW=0
XUI_INSTALLED_NOW=0
TWO_FA_RESET=0
DB_BACKUP=""
NGINX_BACKUP=""
PY_HELPER=""
FINAL_OK=1
STALE_PORTS=""
INDENT="        "
STEP_NO=0
STEP_TOTAL=0
IN_STEP=0
LAST_BLANK=1
UI_LANG=ru

# ОБЩИЕ ФУНКЦИИ

L() {
    if [[ "$UI_LANG" == en ]]; then
        printf '%s' "$2"
    else
        printf '%s' "$1"
    fi
}

emit() {
    printf '%s\n' "$1"
    printf '[%s] %s\n' "$(date '+%F %T')" "$1" >> "$LOG_FILE"
    [[ -z "$1" ]] && LAST_BLANK=1 || LAST_BLANK=0
}

log() {
    if [[ "$IN_STEP" -eq 1 && -n "$*" ]]; then
        emit "${INDENT}$*"
    else
        emit "$*"
    fi
}

log_quiet() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}

log_lines() {
    local prefix="$1" line
    while IFS= read -r line; do
        [[ -n "$line" ]] && log "${prefix}${line}"
    done
}

step() {
    STEP_NO=$((STEP_NO + 1))
    [[ "$LAST_BLANK" -eq 1 ]] || emit ""
    emit "$(printf '%-8s%s' "[${STEP_NO}/${STEP_TOTAL}]" "$1")"
    IN_STEP=1
}

step_end() {
    IN_STEP=0
    emit ""
}

mismatch() {
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
        report_fail "$*"
    else
        log "$*"
    fi
}

mismatch_minor() {
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
        report_warn "$*"
    else
        log "$*"
    fi
}

mismatch_lines() {
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && mismatch "$line"
    done
}

warn_lines() {
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && report_warn "$line"
    done
}

template_differs() {
    local what="$1" file="$2"
    if [[ ! -e "$file" ]]; then
        mismatch "$(L "${what} ${file} отсутствует" "${what} ${file} is missing")"
    else
        mismatch_minor "$(L "${what} ${file} отличается от шаблона" "${what} ${file} differs from the template")"
    fi
}

report_ok() {
    log "✓ $*"
}

report_fail() {
    log "✗ $*"
    FINAL_OK=0
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

report_warn() {
    log "! $*"
}

die() {
    if [[ "$IN_STEP" -eq 1 ]]; then
        log "✗ $*"
    else
        log "$*"
    fi
    IN_STEP=0
    emit ""
    emit "$(L "Остановлено. Журнал: ${LOG_FILE}" "Stopped. Log: ${LOG_FILE}")"
    exit 1
}

prompted() {
    LAST_BLANK=0
}

init_log() {
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
}

random_string() {
    tr -dc "$1" < /dev/urandom | head -c "$2"
}

wait_for() {
    local seconds="$1" i
    shift
    for ((i = 0; i < seconds; i++)); do
        "$@" && return 0
        sleep 1
    done
    "$@"
}

version_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# ПАРАМЕТРЫ ЗАПУСКА

print_usage() {
    if [[ "$UI_LANG" == en ]]; then
        cat << EOF
Usage: sudo bash ${0##*/} [--reconfigure | --check | --uninstall]

  --reconfigure  answer the questions again (language, domain, email, XHTTP, paths, panel login, Hysteria2, WARP)
  --check        check only, no changes; exit code 0 — no errors, 1 — errors found,
                 2 — the check cannot be performed
  --uninstall    remove components of choice: 3x-ui, nginx, certificate, ufw rules, everything
EOF
        return
    fi
    cat << EOF
Использование: sudo bash ${0##*/} [--reconfigure | --check | --uninstall]

  --reconfigure  задать вопросы заново (язык, домен, email, XHTTP, пути, логин панели, Hysteria2, WARP)
  --check        только проверка, без изменений; код выхода 0 — ошибок нет, 1 — есть ошибки,
                 2 — проверку выполнить невозможно
  --uninstall    удаление компонентов на выбор: 3x-ui, nginx, сертификат, правила ufw, всё
EOF
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --reconfigure) RECONFIGURE=1 ;;
            --check) CHECK_ONLY=1 ;;
            --uninstall) UNINSTALL=1 ;;
            -h | --help)
                print_usage
                exit 0
                ;;
            *)
                printf '%s\n' "$(L "Неизвестный параметр: $1" "Unknown option: $1")" >&2
                print_usage >&2
                exit 1
                ;;
        esac
        shift
    done
    if ((RECONFIGURE + CHECK_ONLY + UNINSTALL > 1)); then
        printf '%s\n' "$(L "Параметры --reconfigure, --check и --uninstall несовместимы." "Options --reconfigure, --check and --uninstall cannot be combined.")" >&2
        exit 2
    fi
}

# ВВОД

ask() {
    local -n _ask_out="$1"
    local _ask_prompt="$2" _ask_def="$3" _ask_regex="${4:-}" _ask_err _ask_value
    _ask_err="$(L "${5:-Неверный формат.}" "${5:-Invalid format.}")"
    while true; do
        if [[ -n "$_ask_def" ]]; then
            prompted
            read -r -p "${_ask_prompt} (Enter — ${_ask_def}): " _ask_value || die "$(L "Ввод прерван." "Input interrupted.")"
        else
            prompted
            read -r -p "${_ask_prompt}: " _ask_value || die "$(L "Ввод прерван." "Input interrupted.")"
        fi
        _ask_value="${_ask_value:-$_ask_def}"
        if [[ -z "$_ask_value" ]]; then
            printf '%s\n' "$(L "  Поле обязательно." "  This field is required.")"
            continue
        fi
        if [[ -n "$_ask_regex" && ! "$_ask_value" =~ $_ask_regex ]]; then
            echo "  ${_ask_err}"
            continue
        fi
        _ask_out="$_ask_value"
        return 0
    done
}

ask_optional() {
    local -n _opt_out="$1"
    local _opt_value
    prompted
    read -r -p "$2: " _opt_value || die "$(L "Ввод прерван." "Input interrupted.")"
    _opt_out="$_opt_value"
}

ask_yes_no() {
    local prompt="$1" def="$2" hint="[Y/n]" value
    [[ "$def" == "n" ]] && hint="[y/N]"
    while true; do
        prompted
        read -r -p "${prompt} ${hint}: " value || die "$(L "Ввод прерван." "Input interrupted.")"
        value="${value:-$def}"
        case "${value,,}" in
            y | yes | д | да) return 0 ;;
            n | no | н | нет) return 1 ;;
        esac
        printf '%s\n' "$(L "  Ожидается y или n." "  Expected y or n.")"
    done
}

ask_password() {
    local -n _pw_out="$1"
    local _pw_first _pw_second
    while true; do
        prompted
        read -rs -p "$(L "$2 (Enter — случайный): " "$2 (Enter — random): ")" _pw_first || die "$(L "Ввод прерван." "Input interrupted.")"
        echo
        if [[ -z "$_pw_first" ]]; then
            _pw_out="$(random_string 'A-Za-z0-9' 16)"
            return 0
        fi
        if ((${#_pw_first} < 8)); then
            printf '%s\n' "$(L "  Пароль не короче 8 символов." "  The password must be at least 8 characters.")"
            continue
        fi
        read -rs -p "$(L "Повторите пароль: " "Repeat the password: ")" _pw_second || die "$(L "Ввод прерван." "Input interrupted.")"
        echo
        if [[ "$_pw_first" != "$_pw_second" ]]; then
            printf '%s\n' "$(L "  Пароли не совпадают." "  Passwords do not match.")"
            continue
        fi
        _pw_out="$_pw_first"
        return 0
    done
}

# ФАЙЛ ОТВЕТОВ

conf_load() {
    local key value
    [[ -f "$CONF_FILE" ]] || return 0
    while IFS='=' read -r key value; do
        [[ " ${CONF_KEYS[*]} " == *" ${key} "* ]] && CONF[$key]="$value"
    done < "$CONF_FILE"
    [[ "${CONF[LANGUAGE]:-}" == en ]] && UI_LANG=en
    return 0
}

conf_save() {
    local key tmp
    tmp=$(mktemp "${CONF_FILE}.XXXXXX")
    for key in "${CONF_KEYS[@]}"; do
        if [[ -n "${CONF[$key]:-}" ]]; then
            printf '%s=%s\n' "$key" "${CONF[$key]}"
        fi
    done > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$CONF_FILE"
}

conf_get() {
    printf '%s' "${CONF[$1]:-}"
}

conf_set() {
    CONF[$1]="$2"
    conf_save
}

conf_unset() {
    local key
    for key in "$@"; do
        unset "CONF[$key]"
    done
    conf_save
}

normalize_path() {
    local path="$1"
    path="/${path#/}"
    while [[ "$path" == */ && "$path" != "/" ]]; do
        path="${path%/}"
    done
    [[ "$path" == "/" ]] && path=""
    printf '%s' "$path"
}

# ПАКЕТЫ И PYTHON-ПОМОЩНИК

ensure_packages() {
    local -A needed=([curl]=curl [openssl]=openssl [python3]=python3 [sqlite3]=sqlite3 [ss]=iproute2 [crontab]=cron)
    local missing=() cmd
    for cmd in "${!needed[@]}"; do
        command -v "$cmd" > /dev/null 2>&1 || missing+=("${needed[$cmd]}")
    done
    ((${#missing[@]} == 0)) && return 0
    log "$(L "Установка пакетов: ${missing[*]}." "Installing packages: ${missing[*]}.")"
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update -qq >> "$LOG_FILE" 2>&1 || ! apt-get install -y -qq "${missing[@]}" >> "$LOG_FILE" 2>&1; then
        die "$(L "Не удалось установить пакеты: ${missing[*]}." "Failed to install packages: ${missing[*]}.")"
    fi
}

load_py_helper() {
    IFS= read -r -d '' PY_HELPER << 'PYEOF' || true
import base64
import ipaddress
import json
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid

# НАСТРОЙКИ

REALITY_PORT = 443
REALITY_XVER = 1
XHTTP_TRUSTED_HEADER = "X-Real-IP"
WARP_TAG = "warp"
WARP_MTU = 1280
WARP_STRATEGY = "ForceIPv4"
XHTTP_LISTEN = "127.0.0.1"
HY2_IDLE_TIMEOUT = 300
FINGERPRINT = "firefox"
XHTTP_ALPN = ["h2"]
UDP_PROTOCOLS = {"hysteria", "hysteria2", "wireguard", "amneziawg", "tuic"}
LOCAL_LISTENS = {"127.0.0.1", "::1", "localhost"}
AUTO_TAG = re.compile(r"^(n\d+-)?in-\d+-(tcp|udp|tcpudp|any)(-\d+)?$")
KINDS = ("reality", "xhttp", "hy2")
KIND_NAMES = {"reality": "VLESS Reality", "xhttp": "VLESS XHTTP", "hy2": "Hysteria2"}
REMARKS = {"reality": "VLESS-TCP", "xhttp": "VLESS-XHTTP", "hy2": "HYSTERIA2"}
SETTING_DEFAULTS = {"subEnable": "true", "subPort": "2096", "webPort": "2053"}
INBOUND_FIELDS = ["id", "protocol", "port", "tag", "enable", "listen", "settings",
                  "stream_settings", "sniffing", "remark", "node_id", "origin_node_guid"]
CLIENT_KEYS = ("email", "enable", "subId", "limitIp", "totalGB", "expiryTime", "tgId",
               "comment", "reset", "group")
RU_GEOIP = re.compile(r"^(geoip:ru|ext:[^:]+:ru)$", re.I)
RULE_MATCH_KEYS = ("domain", "ip", "port", "sourcePort", "localPort", "network", "source", "sourceIP", "localIP",
                   "user", "inboundTag", "protocol", "attrs", "vlessRoute", "process")
SNIFFING = {"enabled": True, "destOverride": ["http", "tls", "quic"], "metadataOnly": False, "routeOnly": True}
BLOCK_IP = ["geoip:private", "ext:geoip_RU.dat:ru"]
BLOCK_PROTOCOL = ["bittorrent"]
BLOCK_DOMAIN = ["ext:geosite_RU.dat:ru-available-only-inside", "regexp:.*\\.ru$", "regexp:.*\\.su$",
                "regexp:.*\\.xn--p1ai$", "ext:geosite_RU.dat:category-ads-all", "geosite:category-ads-all"]


# ОБЩИЕ ФУНКЦИИ

UI_LANG = os.environ.get("XUI_LANG", "ru")


def L(ru, en):
    return en if UI_LANG == "en" else ru


EMPTY = L("<пусто>", "<empty>")


class Failure(Exception):
    pass


def emit(value):
    print(json.dumps(value, ensure_ascii=False))


def enabled(value):
    if value is None:
        return True
    if isinstance(value, str):
        return value.strip().lower() not in ("0", "false", "")
    return bool(value)


def as_dict(raw):
    if isinstance(raw, dict):
        return raw
    try:
        value = json.loads(raw or "{}")
    except (TypeError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def json_list(raw):
    if isinstance(raw, list):
        return raw
    try:
        value = json.loads(raw or "[]")
    except (TypeError, ValueError):
        return []
    return value if isinstance(value, list) else []


def as_int(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def columns(cur, table):
    return {row[1] for row in cur.execute(f"PRAGMA table_info({table})").fetchall()}


def kind_of(protocol, stream):
    if (stream.get("security") or "").lower() == "reality":
        return "reality"
    if (stream.get("network") or "").lower() == "xhttp":
        return "xhttp"
    if (protocol or "").lower() in ("hysteria", "hysteria2"):
        return "hy2"
    return "other"


def read_inbounds(cur):
    present = columns(cur, "inbounds")
    select = ", ".join(f if f in present else f"NULL AS {f}" for f in INBOUND_FIELDS)
    result = []
    for row in cur.execute(f"SELECT {select} FROM inbounds ORDER BY id").fetchall():
        ib = dict(zip(INBOUND_FIELDS, row))
        ib["stream"] = as_dict(ib["stream_settings"])
        ib["conf"] = as_dict(ib["settings"])
        ib["sniff"] = as_dict(ib["sniffing"])
        ib["own"] = ib["node_id"] is None and not (ib["origin_node_guid"] or "").strip()
        ib["active"] = enabled(ib["enable"])
        ib["kind"] = kind_of(ib["protocol"], ib["stream"])
        ib["transport"] = "udp" if (ib["protocol"] or "").lower() in UDP_PROTOCOLS else "tcp"
        ib["public"] = (ib["listen"] or "").strip() not in LOCAL_LISTENS
        result.append(ib)
    return result


def own_active(inbounds, kind=None):
    return [ib for ib in inbounds
            if ib["own"] and ib["active"] and (kind is None or ib["kind"] == kind)]


def describe(ib):
    return L(f"id={ib['id']} tag={ib['tag']} порт={ib['port']} remark={ib['remark'] or '-'}",
             f"id={ib['id']} tag={ib['tag']} port={ib['port']} remark={ib['remark'] or '-'}")


def clients_of(ib):
    return [c for c in (ib["conf"].get("clients") or []) if isinstance(c, dict) and c.get("email")]


def settings_map(cur):
    try:
        return {key: value for key, value in cur.execute("SELECT key, value FROM settings").fetchall()}
    except sqlite3.OperationalError:
        return {}


def set_setting(cur, key, value):
    if cur.execute("SELECT 1 FROM settings WHERE key=?", (key,)).fetchone():
        cur.execute("UPDATE settings SET value=? WHERE key=?", (value, key))
    else:
        cur.execute("INSERT INTO settings(key, value) VALUES(?, ?)", (key, value))


def own_address(address, domain):
    address = (address or "").strip()
    if not address or address == domain:
        return True
    try:
        ipaddress.ip_address(address.strip("[]"))
        return True
    except ValueError:
        return False


def x25519(xray_bin, command="x25519"):
    proc = subprocess.run([xray_bin, command], capture_output=True, text=True, timeout=15)
    if proc.returncode != 0:
        raise Failure(L(f"xray {command}: код {proc.returncode}: {proc.stderr.strip()}",
                          f"xray {command}: code {proc.returncode}: {proc.stderr.strip()}"))
    private = re.search(r"^PrivateKey:\s*(\S+)", proc.stdout, re.M)
    public = re.search(r"^Password.*?:\s*(\S+)", proc.stdout, re.M)
    if not private or not public:
        raise Failure(L(f"не удалось разобрать вывод xray {command}", f"failed to parse xray {command} output"))
    return private.group(1), public.group(1)


def short_ids():
    return [secrets.token_hex(n) for n in (2, 4, 8)]


def open_db(path):
    conn = sqlite3.connect(path, timeout=15)
    return conn, conn.cursor()


# ЧТЕНИЕ И ПЕРЕНОС БАЗЫ

def cmd_own_count(db):
    conn, cur = open_db(db)
    print(len([ib for ib in read_inbounds(cur) if ib["own"]]))
    conn.close()


def cmd_discover(db):
    conn, cur = open_db(db)
    inbounds = read_inbounds(cur)
    values = settings_map(cur)
    conn.close()
    xhttp = own_active(inbounds, "xhttp")
    hy2 = own_active(inbounds, "hy2")
    reality = own_active(inbounds, "reality")
    sub_id = ""
    for ib in reality + xhttp + hy2:
        for client in clients_of(ib):
            if client.get("subId"):
                sub_id = client["subId"]
                break
        if sub_id:
            break
    emit({
        "xhttp_path": (xhttp[0]["stream"].get("xhttpSettings") or {}).get("path", "") if len(xhttp) == 1 else "",
        "sub_path": values.get("subPath", ""),
        "web_base_path": values.get("webBasePath", ""),
        "hy2_port": hy2[0]["port"] if len(hy2) == 1 else "",
        "xhttp_port": xhttp[0]["port"] if len(xhttp) == 1 else "",
        "has_clients": any(clients_of(ib) for ib in own_active(inbounds)),
        "sub_id": sub_id,
        "ports": sorted({f"{ib['port']}/{ib['transport']}" for ib in inbounds if ib["own"] and ib["port"]}),
    })


def cmd_validate_db(path):
    work = tempfile.mkdtemp()
    try:
        copy = os.path.join(work, "x-ui.db")
        shutil.copy(path, copy)
        for suffix in ("-wal", "-shm"):
            if os.path.exists(path + suffix):
                shutil.copy(path + suffix, copy + suffix)
        conn = sqlite3.connect(copy)
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        check = conn.execute("PRAGMA integrity_check").fetchone()[0]
        if check != "ok":
            raise Failure(L(f"проверка целостности не пройдена: {check}", f"integrity check failed: {check}"))
        tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        conn.close()
        missing = {"inbounds", "settings"} - tables
        if missing:
            raise Failure(
                L("нет таблиц 3x-ui (", "no 3x-ui tables (") + ", ".join(sorted(missing))
                + L("). Вероятно, база скопирована без checkpoint: на старом сервере выполните "
                    "sqlite3 /etc/x-ui/x-ui.db \"PRAGMA wal_checkpoint(TRUNCATE);\" и скопируйте файл заново",
                    "). The database was probably copied without a checkpoint: run "
                    "sqlite3 /etc/x-ui/x-ui.db \"PRAGMA wal_checkpoint(TRUNCATE);\" on the old server and copy the file again"))
        print("ok")
    finally:
        shutil.rmtree(work, ignore_errors=True)


def cmd_import_prepare(db, xray_bin, domain, target):
    conn, cur = open_db(db)
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    rekeyed, kept = [], []
    for ib in read_inbounds(cur):
        if not (ib["own"] and ib["kind"] == "reality"):
            continue
        rs = ib["stream"].get("realitySettings")
        if not isinstance(rs, dict):
            continue
        names = [str(n).lower() for n in rs.get("serverNames") or []]
        if ((rs.get("target") or rs.get("dest")) == target and domain.lower() in names
                and rs.get("privateKey") and rs.get("shortIds")):
            kept.append(ib["tag"])
            continue
        private, public = x25519(xray_bin)
        rs["serverNames"] = [domain]
        rs["privateKey"] = private
        inner = rs.get("settings") if isinstance(rs.get("settings"), dict) else {}
        inner["publicKey"] = public
        rs["settings"] = inner
        rs["shortIds"] = short_ids()
        cur.execute("UPDATE inbounds SET stream_settings=? WHERE id=?", (json.dumps(ib["stream"]), ib["id"]))
        rekeyed.append(ib["tag"])
    twofa = str(settings_map(cur).get("twoFactorEnable", "")).lower() == "true"
    if twofa:
        set_setting(cur, "twoFactorEnable", "false")
        set_setting(cur, "twoFactorToken", "")
    conn.commit()
    conn.execute("PRAGMA journal_mode=DELETE")
    conn.close()
    emit({"rekeyed": rekeyed, "kept": kept, "twofa_reset": twofa})


# ПРИВЕДЕНИЕ ИНБАУНДОВ

def drop_external_proxy(stream, notes):
    if stream.get("externalProxy"):
        notes.append(L("externalProxy удалён: ссылки строятся из Хостов", "externalProxy removed: links are built from Hosts"))
        del stream["externalProxy"]


def limit_fallback_active(rs):
    active = []
    for key, value in rs.items():
        if not key.lower().startswith("limitfallback"):
            continue
        values = value.values() if isinstance(value, dict) else [value]
        if any(as_int(v) > 0 for v in values):
            active.append(key)
    return active


def tag_suffixed(tag):
    return bool(re.match(r"^in-\d+-(tcp|udp|tcpudp|any)-\d+$", tag or ""))


def sniffing_ok(sniffing):
    if not isinstance(sniffing, dict):
        return False
    return (sniffing.get("enabled") is True and sorted(sniffing.get("destOverride") or []) == sorted(SNIFFING["destOverride"])
            and not sniffing.get("metadataOnly") and sniffing.get("routeOnly") is True)


def normalize_sniffing(ib, notes, fields):
    if sniffing_ok(ib["sniff"]):
        return
    wanted = dict(ib["sniff"])
    wanted.update(SNIFFING)
    notes.append("sniffing → http, tls, quic, routeOnly")
    fields["sniffing"] = json.dumps(wanted)


def normalize_reality(ib, domain, target):
    stream = json.loads(json.dumps(ib["stream"]))
    notes, fields = [], {}
    rs = stream.get("realitySettings")
    if not isinstance(rs, dict):
        raise Failure(L(f"{describe(ib)}: security=reality без realitySettings", f"{describe(ib)}: security=reality without realitySettings"))
    current = rs.get("target") or rs.get("dest") or ""
    if current != target or ("dest" in rs and rs["dest"] != target):
        notes.append(f"target {current or EMPTY} → {target}")
        rs["target"] = target
        if "dest" in rs:
            rs["dest"] = target
    names = rs.get("serverNames") if isinstance(rs.get("serverNames"), list) else []
    if domain not in names:
        notes.append(f"serverNames {names} → {[domain] + names}")
        rs["serverNames"] = [domain] + names
    inner = rs.get("settings")
    if isinstance(inner, dict) and inner.get("serverName") not in (None, "", domain):
        notes.append(f"settings.serverName {inner['serverName']} → {domain}")
        inner["serverName"] = domain
    if as_int(rs.get("xver")) != REALITY_XVER:
        notes.append(f"xver {rs.get('xver')} → {REALITY_XVER}")
        rs["xver"] = REALITY_XVER
    for key in limit_fallback_active(rs):
        notes.append(L(f"{key} удалён", f"{key} removed"))
        del rs[key]
    if (stream.get("network") or "").lower() == "raw":
        notes.append("network raw → tcp")
        stream["network"] = "tcp"
    drop_external_proxy(stream, notes)
    if (ib["listen"] or "").strip():
        notes.append(f"listen {ib['listen']} → {EMPTY}")
        fields["listen"] = ""
    normalize_sniffing(ib, notes, fields)
    return stream, fields, notes


def xhttp_trusted(sockopt):
    trusted = sockopt.get("trustedXForwardedFor") if isinstance(sockopt, dict) else None
    return isinstance(trusted, list) and any(str(h).lower() == XHTTP_TRUSTED_HEADER.lower() for h in trusted)


def normalize_xhttp(ib, domain, path, port):
    stream = json.loads(json.dumps(ib["stream"]))
    notes, fields = [], {}
    xs = stream.get("xhttpSettings")
    if not isinstance(xs, dict):
        xs = {}
        stream["xhttpSettings"] = xs
    if xs.get("path") != path:
        notes.append(L("путь XHTTP изменён", "XHTTP path changed"))
        xs["path"] = path
    if xs.get("mode") != "stream-one":
        notes.append(f"mode {xs.get('mode') or EMPTY} → stream-one")
        xs["mode"] = "stream-one"
    if (stream.get("security") or "none") != "none":
        notes.append(f"security {stream.get('security')} → none")
        stream["security"] = "none"
        stream.pop("tlsSettings", None)
        stream.pop("realitySettings", None)
    drop_external_proxy(stream, notes)
    sockopt = stream.get("sockopt") if isinstance(stream.get("sockopt"), dict) else {}
    if not xhttp_trusted(sockopt):
        trusted = sockopt.get("trustedXForwardedFor") if isinstance(sockopt.get("trustedXForwardedFor"), list) else []
        notes.append(f"sockopt.trustedXForwardedFor {trusted} → {trusted + [XHTTP_TRUSTED_HEADER]}")
        sockopt["trustedXForwardedFor"] = trusted + [XHTTP_TRUSTED_HEADER]
        stream["sockopt"] = sockopt
    if sockopt.get("acceptProxyProtocol"):
        notes.append("sockopt.acceptProxyProtocol true → false")
        sockopt["acceptProxyProtocol"] = False
    if (ib["listen"] or "").strip() != XHTTP_LISTEN:
        notes.append(f"listen {ib['listen'] or EMPTY} → {XHTTP_LISTEN}")
        fields["listen"] = XHTTP_LISTEN
    if ib["port"] != port:
        notes.append(L(f"порт {ib['port']} → {port}", f"port {ib['port']} → {port}"))
        fields["port"] = port
    normalize_sniffing(ib, notes, fields)
    return stream, fields, notes


def hy2_masquerade(domain):
    return {"type": "proxy", "url": f"https://{domain}:{REALITY_PORT}", "rewriteHost": True}


def normalize_hy2(ib, domain, cert_folder, port):
    stream = json.loads(json.dumps(ib["stream"]))
    notes, fields = [], {}
    fullchain = f"/etc/ssl/{cert_folder}/fullchain.pem"
    privkey = f"/etc/ssl/{cert_folder}/privkey.pem"
    if (stream.get("security") or "") != "tls":
        notes.append(f"security {stream.get('security') or EMPTY} → tls")
        stream["security"] = "tls"
    tls = stream.get("tlsSettings")
    if not isinstance(tls, dict):
        tls = {}
        stream["tlsSettings"] = tls
    if tls.get("serverName") != domain:
        notes.append(f"serverName {tls.get('serverName') or EMPTY} → {domain}")
        tls["serverName"] = domain
    certs = tls.get("certificates")
    if not isinstance(certs, list) or not certs or not all(isinstance(c, dict) for c in certs):
        certs = [{}]
    wanted = []
    for cert in certs:
        cert = {k: v for k, v in cert.items() if k not in ("certificate", "key")}
        cert["certificateFile"] = fullchain
        cert["keyFile"] = privkey
        if cert.get("oneTimeLoading"):
            cert["oneTimeLoading"] = False
        wanted.append(cert)
    if wanted != tls.get("certificates"):
        notes.append(L(f"сертификат → /etc/ssl/{cert_folder}/", f"certificate → /etc/ssl/{cert_folder}/"))
        tls["certificates"] = wanted
    if tls.get("alpn") != ["h3"]:
        notes.append(f"alpn {tls.get('alpn')} → ['h3']")
        tls["alpn"] = ["h3"]
    if tls.get("rejectUnknownSni") is not True:
        notes.append(L("rejectUnknownSni → вкл", "rejectUnknownSni → on"))
        tls["rejectUnknownSni"] = True
    hs = stream.get("hysteriaSettings")
    if not isinstance(hs, dict):
        hs = {}
        stream["hysteriaSettings"] = hs
    if as_int(hs.get("version")) != 2:
        notes.append(L(f"версия Hysteria {hs.get('version')} → 2", f"Hysteria version {hs.get('version')} → 2"))
        hs["version"] = 2
    if as_int(hs.get("udpIdleTimeout")) != HY2_IDLE_TIMEOUT:
        notes.append(f"udpIdleTimeout {hs.get('udpIdleTimeout') or EMPTY} → {HY2_IDLE_TIMEOUT}")
        hs["udpIdleTimeout"] = HY2_IDLE_TIMEOUT
    for key in ("up", "down", "udphop"):
        if hs.get(key):
            notes.append(L(f"{key} удалён", f"{key} removed"))
            del hs[key]
    masquerade = hs.get("masquerade") if isinstance(hs.get("masquerade"), dict) else {}
    wanted_masquerade = hy2_masquerade(domain)
    if any(masquerade.get(k) != v for k, v in wanted_masquerade.items()) or masquerade.get("xForwarded") \
            or masquerade.get("insecure"):
        notes.append(f"masquerade {masquerade.get('type') or EMPTY} {masquerade.get('url') or EMPTY} "
                     f"→ proxy {wanted_masquerade['url']}")
        masquerade.update(wanted_masquerade)
        masquerade.pop("xForwarded", None)
        masquerade.pop("insecure", None)
        hs["masquerade"] = masquerade
    fm = stream.get("finalmask") if isinstance(stream.get("finalmask"), dict) else None
    if fm is not None and (fm.get("udp") or fm.get("quicParams")):
        masks = [str(m.get("type")) for m in fm.get("udp") or [] if isinstance(m, dict)]
        if masks:
            notes.append(L(f"UDP-маски {', '.join(masks)} удалены", f"UDP masks {', '.join(masks)} removed"))
        if fm.get("quicParams"):
            notes.append(L("quicParams удалён", "quicParams removed"))
        fm["udp"] = []
        fm.pop("quicParams", None)
    drop_external_proxy(stream, notes)
    if (ib["listen"] or "").strip():
        notes.append(f"listen {ib['listen']} → {EMPTY}")
        fields["listen"] = ""
    if ib["port"] != port:
        notes.append(L(f"порт {ib['port']} → {port}", f"port {ib['port']} → {port}"))
        fields["port"] = port
    normalize_sniffing(ib, notes, fields)
    return stream, fields, notes


def cmd_reality_xver(mode, db, target):
    conn, cur = open_db(db)
    pending = []
    for ib in own_active(read_inbounds(cur), "reality"):
        rs = ib["stream"].get("realitySettings")
        if not isinstance(rs, dict) or (rs.get("target") or rs.get("dest")) != target:
            continue
        if as_int(rs.get("xver")) == REALITY_XVER:
            continue
        pending.append(f"VLESS Reality ({describe(ib)}): xver {rs.get('xver')} → {REALITY_XVER}")
        if mode == "set":
            rs["xver"] = REALITY_XVER
            write_inbound(cur, ib["id"], ib["stream"], {})
    if mode == "set":
        conn.commit()
    conn.close()
    emit({"changes": pending})


def unique_tag(port, transport, taken):
    base = f"in-{port}-{transport}"
    if base not in taken:
        return base
    for n in range(2, 100):
        candidate = f"{base}-{n}"
        if candidate not in taken:
            return candidate
    raise Failure(L(f"нет свободного тега для порта {port}", f"no free tag for port {port}"))


def rename_template_tags(cur, renamed):
    if not renamed:
        return
    row = cur.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    if not row or not row[0]:
        return
    template = json.loads(row[0])
    for rule in (template.get("routing") or {}).get("rules") or []:
        tags = rule.get("inboundTag")
        if isinstance(tags, list):
            new_tags = []
            for tag in tags:
                tag = renamed.get(tag, tag)
                if tag not in new_tags:
                    new_tags.append(tag)
            rule["inboundTag"] = new_tags
    cur.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (json.dumps(template, indent=2),))


def write_inbound(cur, ib_id, stream, fields):
    assignments, values = [], []
    if stream is not None:
        assignments.append("stream_settings=?")
        values.append(json.dumps(stream))
    for key in ("listen", "port", "tag", "enable", "sniffing"):
        if key in fields:
            assignments.append(f"{key}=?")
            values.append(fields[key])
    if assignments:
        cur.execute(f"UPDATE inbounds SET {', '.join(assignments)} WHERE id=?", (*values, ib_id))


def cmd_inbounds(mode, db, domain, cert_folder, xhttp_path, hy2_port, target, xhttp_port):
    hy2_port = as_int(hy2_port)
    xhttp_port = as_int(xhttp_port)
    conn, cur = open_db(db)
    inbounds = read_inbounds(cur)
    report = {"fatal": [], "problems": [], "warnings": [], "changes": [], "missing": [],
              "reality": None, "xhttp": None, "hy2": None, "renamed": {}, "stale_ports": []}
    selected = {}
    for kind in KINDS:
        found = own_active(inbounds, kind)
        if len(found) > 1:
            report["fatal"].append(L(f"{KIND_NAMES[kind]}: включено несколько инбаундов, допускается один: ",
                                     f"{KIND_NAMES[kind]}: several inbounds are enabled, only one is allowed: ")
                                   + "; ".join(describe(ib) for ib in found))
        elif found:
            selected[kind] = found[0]
            summary = {"id": found[0]["id"], "tag": found[0]["tag"], "port": found[0]["port"]}
            if kind == "reality":
                rs = found[0]["stream"].get("realitySettings") or {}
                summary["target"] = rs.get("target") or rs.get("dest") or ""
            report[kind] = summary
    wanted = ["reality"] + (["xhttp"] if xhttp_path else []) + (["hy2"] if hy2_port else [])
    report["missing"] = [kind for kind in wanted if kind not in selected]
    if report["fatal"]:
        conn.close()
        emit(report)
        return

    taken = {ib["tag"] for ib in inbounds}
    plans = []
    if "reality" in selected:
        ib = selected["reality"]
        stream, fields, notes = normalize_reality(ib, domain, target)
        plans.append(("main", ib, stream, fields, notes))
        if ib["port"] != REALITY_PORT:
            port_fields = {"port": REALITY_PORT}
            if AUTO_TAG.match(ib["tag"] or ""):
                port_fields["tag"] = unique_tag(REALITY_PORT, "tcp", taken - {ib["tag"]})
            plans.append(("port", ib, None, port_fields, [L(f"порт {ib['port']} → {REALITY_PORT}", f"port {ib['port']} → {REALITY_PORT}")]))
    if "xhttp" in selected and xhttp_path:
        ib = selected["xhttp"]
        stream, fields, notes = normalize_xhttp(ib, domain, xhttp_path, xhttp_port)
        plans.append(("main", ib, stream, fields, notes))
    if "hy2" in selected and hy2_port:
        ib = selected["hy2"]
        stream, fields, notes = normalize_hy2(ib, domain, cert_folder, hy2_port)
        plans.append(("main", ib, stream, fields, notes))
    for kind, ib in selected.items():
        if tag_suffixed(ib["tag"]):
            report["warnings"].append(L(f"{KIND_NAMES[kind]} ({describe(ib)}): тег с суффиксом — если сервер станет "
                                        "узлом мастер-панели 3x-ui, синхронизация не найдёт этот инбаунд",
                                        f"{KIND_NAMES[kind]} ({describe(ib)}): suffixed tag — if the server becomes "
                                        "a node of a 3x-ui master panel, sync will not find this inbound"))
    chosen = {ib["id"] for ib in selected.values()}
    for ib in own_active(inbounds):
        if ib["id"] in chosen:
            continue
        if ib["transport"] == "tcp" and ib["public"]:
            plans.append(("main", ib, None, {"enable": 0},
                          [L(f"выключен: публичный TCP-порт кроме {REALITY_PORT} не допускается",
                            f"disabled: no public TCP port other than {REALITY_PORT} is allowed")]))
        elif ib["transport"] == "udp" and ib["public"]:
            report["warnings"].append(L(f"{describe(ib)}: UDP-инбаунд оставлен включённым, но его порт в ufw не открывается",
                                        f"{describe(ib)}: the UDP inbound stays enabled, but its port is not opened in ufw"))

    for stage, ib, stream, fields, notes in plans:
        if stream is not None and stream == ib["stream"]:
            stream = None
        if not notes:
            continue
        name = KIND_NAMES.get(ib["kind"], ib["protocol"] or "inbound")
        for note in notes:
            report["problems"].append(f"{name} ({describe(ib)}): {note}")
        if mode != stage:
            continue
        if "port" in fields and "tag" not in fields and AUTO_TAG.match(ib["tag"] or "") and stage == "main":
            fields["tag"] = unique_tag(fields["port"], ib["transport"], taken - {ib["tag"]})
        if fields.get("tag") and fields["tag"] != ib["tag"]:
            report["renamed"][ib["tag"]] = fields["tag"]
            taken.discard(ib["tag"])
            taken.add(fields["tag"])
        if "port" in fields or "enable" in fields:
            report["stale_ports"].append(f"{ib['port']}/{ib['transport']}")
        write_inbound(cur, ib["id"], stream, fields)
        for note in notes:
            report["changes"].append(f"{name} ({describe(ib)}): {note}")
    if mode in ("main", "port"):
        rename_template_tags(cur, report["renamed"])
        conn.commit()
    conn.close()
    emit(report)


# ХОСТЫ

def host_rows(cur):
    present = columns(cur, "hosts")
    if not present:
        return None, present
    wanted = ["id", "inbound_id", "address", "port", "security", "sni", "fingerprint", "alpn",
              "override_sni_from_address", "is_disabled"]
    select = ", ".join(f if f in present else f"NULL AS {f}" for f in wanted)
    return [dict(zip(wanted, row)) for row in cur.execute(f"SELECT {select} FROM hosts ORDER BY id")], present


def desired_host(kind, domain, hy2_port):
    if kind == "reality":
        return {"address": domain, "port": REALITY_PORT, "security": "same", "sni": domain,
                "override_sni_from_address": 0}
    if kind == "xhttp":
        return {"address": domain, "port": REALITY_PORT, "security": "tls", "sni": domain, "fingerprint": FINGERPRINT,
                "alpn": XHTTP_ALPN}
    return {"address": domain, "port": hy2_port, "security": "same"}


def same_value(key, current, wanted, kind, single_name):
    if key == "sni" and (current or "") == "":
        return kind == "reality" and single_name
    if key == "sni" and kind == "xhttp":
        return True
    if key == "override_sni_from_address":
        return enabled(current) == bool(wanted) if current not in (None, "") else not wanted
    if key == "port":
        return as_int(current) == wanted
    if key == "alpn":
        return json_list(current) == wanted
    return (current or "") == wanted


def host_value(key, value):
    if key == "alpn":
        value = ",".join(json_list(value))
    return value if value not in (None, "") else EMPTY


def cmd_hosts(mode, db, domain, hy2_port):
    hy2_port = as_int(hy2_port)
    conn, cur = open_db(db)
    inbounds = read_inbounds(cur)
    rows, present = host_rows(cur)
    report = {"problems": [], "changes": [], "missing": [], "fixable": 0}
    if rows is None:
        report["problems"].append(L("в базе нет таблицы hosts", "the database has no hosts table"))
        conn.close()
        emit(report)
        return
    for kind in KINDS:
        found = own_active(inbounds, kind)
        if len(found) != 1 or (kind == "hy2" and not hy2_port):
            continue
        ib = found[0]
        wanted = desired_host(kind, domain, hy2_port)
        single_name = len((ib["stream"].get("realitySettings") or {}).get("serverNames") or []) <= 1
        own_hosts = []
        for host in rows:
            if host["inbound_id"] != ib["id"]:
                continue
            if own_address(host["address"], domain):
                own_hosts.append(host)
        if not own_hosts:
            report["missing"].append({"kind": kind, "inbound_id": ib["id"], "remark": REMARKS[kind], **wanted})
            report["problems"].append(L(f"{KIND_NAMES[kind]}: нет Хоста {domain}:{wanted['port']}",
                                         f"{KIND_NAMES[kind]}: no Host {domain}:{wanted['port']}"))
            continue
        for host in own_hosts:
            diffs = {k: v for k, v in wanted.items() if k in present and not same_value(k, host.get(k), v, kind, single_name)}
            if not diffs:
                continue
            text = ", ".join(f"{k} {host_value(k, host.get(k))} → {host_value(k, v)}" for k, v in diffs.items())
            report["problems"].append(L(f"{KIND_NAMES[kind]}: Хост id={host['id']}: {text}",
                                       f"{KIND_NAMES[kind]}: Host id={host['id']}: {text}"))
            report["fixable"] += 1
            if mode == "fix":
                assignments = ", ".join(f"{k}=?" for k in diffs)
                values = [json.dumps(v) if isinstance(v, list) else v for v in diffs.values()]
                cur.execute(f"UPDATE hosts SET {assignments} WHERE id=?", (*values, host["id"]))
                report["changes"].append(L(f"{KIND_NAMES[kind]}: Хост id={host['id']}: {text}",
                                          f"{KIND_NAMES[kind]}: Host id={host['id']}: {text}"))
    if mode == "fix":
        conn.commit()
    conn.close()
    emit(report)


# НАСТРОЙКИ ПАНЕЛИ

def cmd_settings_diff(db, *pairs):
    conn, cur = open_db(db)
    values = settings_map(cur)
    conn.close()
    for pair in pairs:
        key, _, wanted = pair.partition("=")
        current = values.get(key)
        if current is None:
            current = SETTING_DEFAULTS.get(key, "")
        if current != wanted:
            print(f"{key}: {current or EMPTY} → {wanted or EMPTY}")


def cmd_settings_set(db, *pairs):
    conn, cur = open_db(db)
    for pair in pairs:
        key, _, value = pair.partition("=")
        set_setting(cur, key, value)
    conn.commit()
    conn.close()



def cmd_panel_user(db, field):
    conn, cur = open_db(db)
    row = cur.execute("SELECT username, password FROM users ORDER BY id LIMIT 1").fetchone()
    conn.close()
    print((row[0] if field == "username" else row[1]) if row else "")


def cmd_api_token_exists(db, name):
    conn, cur = open_db(db)
    try:
        row = cur.execute("SELECT 1 FROM api_tokens WHERE name=?", (name,)).fetchone()
    except sqlite3.OperationalError:
        row = None
    conn.close()
    print("yes" if row else "no")


def cmd_api_token_delete(db, name):
    conn, cur = open_db(db)
    try:
        cur.execute("DELETE FROM api_tokens WHERE name=?", (name,))
        conn.commit()
    except sqlite3.OperationalError:
        pass
    conn.close()

# API ПАНЕЛИ И СОЗДАНИЕ ИНБАУНДОВ

class Api:
    def __init__(self, base, token):
        self.base = base
        self.token = token
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def call(self, path, body=None, form=None, timeout=20):
        headers = {"Authorization": f"Bearer {self.token}"}
        data, method = None, "GET"
        if body is not None:
            data, method = json.dumps(body).encode(), "POST"
            headers["Content-Type"] = "application/json"
        elif form is not None:
            data, method = urllib.parse.urlencode(form).encode(), "POST"
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        request = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=timeout) as response:
                parsed = json.loads(response.read().decode())
        except urllib.error.HTTPError as e:
            raise Failure(f"{path}: HTTP {e.code}: {e.read().decode(errors='replace')[:300]}")
        except (urllib.error.URLError, OSError, ValueError) as e:
            raise Failure(f"{path}: {e}")
        if not parsed.get("success"):
            raise Failure(f"{path}: {parsed.get('msg') or L('ошибка', 'error')}")
        return parsed.get("obj")


def client_records(cur):
    present = columns(cur, "clients")
    if not {"email", "uuid", "sub_id"} <= present:
        return {}
    auth = "auth" if "auth" in present else "''"
    return {email.lower(): {"id": uid or "", "subId": sub or "", "auth": au or ""}
            for email, uid, sub, au in cur.execute(f"SELECT email, uuid, sub_id, {auth} FROM clients")}


def cloned_clients(source, kind, records):
    result = []
    for client in source:
        record = records.get(client["email"].lower(), {})
        client = {**client, **{k: v for k, v in record.items() if v and not client.get(k)}}
        if record.get("subId"):
            client["subId"] = record["subId"]
        item = {k: client[k] for k in CLIENT_KEYS if k in client}
        item.setdefault("enable", True)
        item.setdefault("subId", secrets.token_hex(8))
        if kind in ("reality", "xhttp"):
            item["id"] = client.get("id") or str(uuid.uuid4())
        if kind == "reality":
            item["flow"] = "xtls-rprx-vision"
        if kind == "hy2":
            item["auth"] = client.get("auth") or secrets.token_urlsafe(16)
        result.append(item)
    return result


def reality_inbound(p, clients, xray_bin):
    private, public = x25519(xray_bin)
    return {
        "remark": REMARKS["reality"], "listen": "", "port": REALITY_PORT, "protocol": "vless",
        "settings": {"clients": clients, "decryption": "none", "fallbacks": []},
        "streamSettings": {
            "network": "tcp", "security": "reality",
            "realitySettings": {
                "show": False, "target": p["target"], "xver": REALITY_XVER,
                "serverNames": [p["domain"]], "privateKey": private, "shortIds": short_ids(),
                "settings": {"publicKey": public, "fingerprint": FINGERPRINT, "spiderX": "/"},
            },
        },
    }


def xhttp_inbound(p, clients):
    return {
        "remark": REMARKS["xhttp"], "listen": XHTTP_LISTEN, "port": p["xhttp_port"], "protocol": "vless",
        "settings": {"clients": clients, "decryption": "none", "fallbacks": []},
        "streamSettings": {
            "network": "xhttp", "security": "none",
            "xhttpSettings": {"path": p["xhttp_path"], "mode": "stream-one", "host": ""},
            "sockopt": {"acceptProxyProtocol": False, "trustedXForwardedFor": [XHTTP_TRUSTED_HEADER]},
        },
    }


def hy2_inbound(p, clients):
    return {
        "remark": REMARKS["hy2"], "listen": "", "port": p["hy2_port"], "protocol": "hysteria",
        "settings": {"clients": clients},
        "streamSettings": {
            "network": "hysteria", "security": "tls",
            "hysteriaSettings": {
                "version": 2, "udpIdleTimeout": HY2_IDLE_TIMEOUT, "masquerade": hy2_masquerade(p["domain"]),
            },
            "tlsSettings": {
                "serverName": p["domain"], "minVersion": "1.2", "maxVersion": "1.3", "alpn": ["h3"],
                "rejectUnknownSni": True,
                "certificates": [{
                    "certificateFile": f"/etc/ssl/{p['cert_folder']}/fullchain.pem",
                    "keyFile": f"/etc/ssl/{p['cert_folder']}/privkey.pem",
                }],
            },
        },
    }


def cmd_create_missing(base, token, db, xray_bin, domain, cert_folder, xhttp_path, hy2_port, target, client_name,
                       xhttp_port):
    p = {"domain": domain, "cert_folder": cert_folder, "xhttp_path": xhttp_path,
         "hy2_port": as_int(hy2_port), "target": target, "xhttp_port": as_int(xhttp_port)}
    conn, cur = open_db(db)
    inbounds = read_inbounds(cur)
    records = client_records(cur)
    conn.close()
    selected = {kind: own_active(inbounds, kind) for kind in KINDS}
    wanted = ["reality"] + (["xhttp"] if p["xhttp_path"] else []) + (["hy2"] if p["hy2_port"] else [])
    missing = [kind for kind in wanted if not selected[kind]]
    report = {"created": [], "new_client": None}
    if not missing:
        emit(report)
        return
    source = None
    for kind in KINDS:
        for ib in selected[kind]:
            if clients_of(ib):
                source = clients_of(ib)
                break
        if source:
            break
    if source is None:
        record = records.get(client_name.lower(), {})
        source = [{"email": client_name, "id": record.get("id") or str(uuid.uuid4()),
                   "subId": record.get("subId") or secrets.token_hex(8), "enable": True}]
        report["new_client"] = {"email": client_name, "subId": source[0]["subId"]}
    api = Api(base, token)
    created = []
    try:
        for kind in missing:
            clients = cloned_clients(source, kind, records)
            if kind == "reality":
                body = reality_inbound(p, clients, xray_bin)
            elif kind == "xhttp":
                body = xhttp_inbound(p, clients)
            else:
                body = hy2_inbound(p, clients)
            body.update({"up": 0, "down": 0, "total": 0, "enable": True, "expiryTime": 0,
                         "sniffing": json.dumps(SNIFFING)})
            body["settings"] = json.dumps(body["settings"])
            body["streamSettings"] = json.dumps(body["streamSettings"])
            obj = api.call("panel/api/inbounds/add", body=body)
            created.append(obj["id"])
            report["created"].append({"kind": kind, "id": obj["id"], "tag": obj.get("tag"), "port": obj.get("port")})
    except Failure:
        for inbound_id in created:
            try:
                api.call(f"panel/api/inbounds/del/{inbound_id}", body={})
            except Failure:
                pass
        raise
    emit(report)


def cmd_hosts_add(base, token, missing_json):
    api = Api(base, token)
    added = []
    for item in json.loads(missing_json):
        body = {"inboundIds": [item["inbound_id"]], "hosts": [item["address"]], "remark": item.get("remark") or "main",
                "port": item["port"], "security": item["security"]}
        if item.get("sni"):
            body["sni"] = item["sni"]
        if item.get("fingerprint"):
            body["fingerprint"] = item["fingerprint"]
        if item.get("alpn"):
            body["alpn"] = item["alpn"]
        api.call("panel/api/hosts/add", body=body)
        added.append(f"{KIND_NAMES[item['kind']]}: {item['address']}:{item['port']}")
    emit({"added": added})


# МАРШРУТИЗАЦИЯ И CONFIG.JSON

def plain_block(rule, field):
    return (rule.get("outboundTag") == "blocked" and rule.get("enabled", True) is not False
            and isinstance(rule.get(field), list)
            and not any(rule.get(key) for key in RULE_MATCH_KEYS if key != field))


def is_udp443_block(rule):
    return (rule.get("outboundTag") == "blocked" and (rule.get("network") or "").lower() == "udp"
            and str(rule.get("port")) == "443")


def is_warp_rule(rule):
    return (rule.get("outboundTag") == WARP_TAG and isinstance(rule.get("inboundTag"), list)
            and rule.get("enabled", True) is not False
            and not any(rule.get(key) for key in RULE_MATCH_KEYS if key != "inboundTag"))


def warp_summary(outbounds, rules, tags):
    found = [sorted(set(r["inboundTag"])) for r in rules if is_warp_rule(r)]
    last = bool(rules) and is_warp_rule(rules[-1])
    outbound = any(isinstance(o, dict) and o.get("tag") == WARP_TAG for o in outbounds)
    return {"outbound": outbound, "rules": found, "expected": tags, "last": last,
            "ok": outbound and found == [tags] and last}


def warp_outbound(api, xray_bin):
    data = api.call("panel/api/xray/warp/data", form={})
    if data:
        data = json.loads(data)
        config = json.loads(api.call("panel/api/xray/warp/config", form={}))
    else:
        private, public = x25519(xray_bin, "wg")
        registered = json.loads(api.call("panel/api/xray/warp/reg", form={"privateKey": private, "publicKey": public}))
        data, config = registered.get("data") or {}, registered.get("config") or {}
    cfg = config.get("config") if isinstance(config.get("config"), dict) else {}
    peers = cfg.get("peers") or []
    addresses = (cfg.get("interface") or {}).get("addresses") or {}
    address = [f"{addresses[key]}/{bits}" for key, bits in (("v4", 32), ("v6", 128)) if addresses.get(key)]
    if not peers or not address or not data.get("private_key"):
        raise Failure(L("Cloudflare не вернул настройки WARP", "Cloudflare did not return the WARP settings"))
    return {
        "tag": WARP_TAG, "protocol": "wireguard",
        "settings": {
            "mtu": WARP_MTU, "secretKey": data["private_key"], "address": address,
            "reserved": list(base64.b64decode(cfg.get("client_id") or data.get("client_id") or "")),
            "peers": [{"publicKey": peers[0].get("public_key"), "allowedIPs": ["0.0.0.0/0", "::/0"],
                       "endpoint": (peers[0].get("endpoint") or {}).get("host")}],
            "noKernelTun": True,
        },
        "streamSettings": {"sockopt": {"domainStrategy": WARP_STRATEGY}},
        "targetStrategy": WARP_STRATEGY,
    }


def apply_warp(api, template, tags, xray_bin):
    changes = []
    outbounds = template.setdefault("outbounds", [])
    rules = template["routing"]["rules"]
    outbound = next((o for o in outbounds if isinstance(o, dict) and o.get("tag") == WARP_TAG), None)
    ours = [r for r in rules if is_warp_rule(r)]
    if outbound is None or not ours:
        created = outbound is None
        if created:
            outbound = warp_outbound(api, xray_bin)
        try:
            result = api.call("panel/api/xray/testOutbound", timeout=90, form={
                "outbound": json.dumps(outbound), "allOutbounds": json.dumps(outbounds + ([outbound] if created else []))}) or {}
        except Failure as e:
            result = {"error": str(e)}
        if not result.get("success"):
            raise Failure(L(f"исходящий {WARP_TAG} не отвечает ({result.get('error') or 'нет ответа'}), маршрутизация не изменена",
                              f"the {WARP_TAG} outbound does not respond ({result.get('error') or 'no response'}), routing is not changed"))
        if created:
            outbounds.append(outbound)
            changes.append(L(f"добавлен исходящий {WARP_TAG} (Cloudflare WARP), задержка {result.get('delay')} мс",
                             f"added the {WARP_TAG} outbound (Cloudflare WARP), delay {result.get('delay')} ms"))
    if len(ours) != 1 or sorted(set(ours[0]["inboundTag"])) != tags or rules[-1] is not ours[0]:
        rules[:] = [r for r in rules if not is_warp_rule(r)]
        rules.append({"type": "field", "inboundTag": tags, "outboundTag": WARP_TAG})
        changes.append(f"{tags} → {WARP_TAG}")
    return changes


def block_missing(rules):
    have = {field: {str(v) for r in rules if plain_block(r, field) for v in r[field]}
            for field in ("ip", "protocol", "domain")}
    missing = {
        "ip": [v for v in BLOCK_IP if v not in have["ip"]],
        "protocol": [v for v in BLOCK_PROTOCOL if v not in have["protocol"]],
        "domain": [v for v in BLOCK_DOMAIN if v not in have["domain"]],
    }
    if any(RU_GEOIP.match(v) for v in have["ip"]):
        missing["ip"] = [v for v in missing["ip"] if not RU_GEOIP.match(v)]
    return missing


def cmd_config_summary(path):
    with open(path) as f:
        config = json.load(f)
    result = {"reality": None, "xhttp": None, "hy2": None}
    for ib in config.get("inbounds") or []:
        stream = ib.get("streamSettings") or {}
        kind = kind_of(ib.get("protocol"), stream)
        if kind == "other" or result[kind] is not None:
            continue
        entry = {"tag": ib.get("tag") or "", "port": ib.get("port"), "listen": ib.get("listen") or "",
                 "sniffing": sniffing_ok(ib.get("sniffing"))}
        if kind == "hy2":
            fm = stream.get("finalmask") if isinstance(stream.get("finalmask"), dict) else {}
            tls = stream.get("tlsSettings") if isinstance(stream.get("tlsSettings"), dict) else {}
            entry["plain"] = not fm.get("udp") and not fm.get("quicParams")
            entry["reject_sni"] = tls.get("rejectUnknownSni") is True
        if kind == "xhttp":
            sockopt = stream.get("sockopt") if isinstance(stream.get("sockopt"), dict) else {}
            entry["real_ip"] = xhttp_trusted(sockopt) and not sockopt.get("acceptProxyProtocol")
        if kind == "reality":
            rs = stream.get("realitySettings") or {}
            entry["target"] = str(rs.get("target") or rs.get("dest") or "")
            entry["xver"] = as_int(rs.get("xver"))
            entry["server_names"] = rs.get("serverNames") or []
            entry["limit_fallback"] = limit_fallback_active(rs)
        result[kind] = entry
    rules = (config.get("routing") or {}).get("rules") or []
    udp_rules = [r for r in rules if is_udp443_block(r)]
    expected = sorted({result[k]["tag"] for k in ("reality", "xhttp") if result[k]})
    actual = [sorted(set(r.get("inboundTag") or [])) for r in udp_rules]
    result["block_missing"] = [v for values in block_missing(rules).values() for v in values]
    result["sniffing_off"] = [KIND_NAMES[k] for k in KINDS if result[k] and not result[k]["sniffing"]]
    result["udp443_expected"] = expected
    result["udp443_actual"] = actual
    result["udp443_ok"] = len(actual) == 1 and actual[0] == expected
    result["warp"] = warp_summary(config.get("outbounds") or [], rules, sorted({result[k]["tag"] for k in KINDS if result[k]}))
    emit(result)


def add_block_rules(rules, missing):
    changed = []
    anchor = 0
    for i, rule in enumerate(rules):
        if rule.get("outboundTag") == "api" or any(plain_block(rule, f) for f in ("ip", "protocol", "domain")):
            anchor = i + 1
    for field in ("ip", "protocol", "domain"):
        if not missing[field]:
            continue
        target = next((r for r in rules if plain_block(r, field)), None)
        if target is None:
            target = {"type": "field", field: [], "outboundTag": "blocked"}
            rules.insert(anchor, target)
            anchor += 1
        target[field].extend(missing[field])
        changed.append(target)
    return changed


def xray_test(config_path, xray_bin, rules):
    assets = os.path.dirname(xray_bin)
    for value in (str(v) for rule in rules for f in ("ip", "domain") for v in rule.get(f) or []):
        if value.startswith("ext:"):
            name = value.split(":")[1]
            if not os.path.isfile(os.path.join(assets, name)):
                raise Failure(L(f"нет файла {os.path.join(assets, name)} для {value}",
                                  f"no file {os.path.join(assets, name)} for {value}"))
    with open(config_path) as f:
        config = json.load(f)
    config.setdefault("routing", {}).setdefault("rules", [])[0:0] = rules
    fd, path = tempfile.mkstemp(suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(config, f)
        proc = subprocess.run([xray_bin, "run", "-test", "-c", path], capture_output=True, text=True,
                              env=dict(os.environ, XRAY_LOCATION_ASSET=assets), timeout=60)
    finally:
        os.unlink(path)
    if proc.returncode != 0:
        lines = [line for line in (proc.stdout + proc.stderr).splitlines() if line.strip()]
        raise Failure("xray -test: " + (lines[-1] if lines else L(f"код {proc.returncode}", f"code {proc.returncode}")))


def cmd_routing_apply(base, token, reality_tag, xhttp_tag, config_path, xray_bin, hy2_tag="", warp=""):
    api = Api(base, token)
    loaded = json.loads(api.call("panel/api/xray/", form={}))
    template = loaded["xraySetting"]
    rules = template.setdefault("routing", {}).setdefault("rules", [])
    changes = []
    missing = block_missing(rules)
    changed = add_block_rules(rules, missing)
    if changed:
        xray_test(config_path, xray_bin, json.loads(json.dumps(changed)))
        changes.append(L("blocked: добавлено ", "blocked: added ") + ", ".join(v for values in missing.values() for v in values))
    tags = sorted({tag for tag in (reality_tag, xhttp_tag) if tag})
    old = [r for r in rules if is_udp443_block(r)]
    if len(old) != 1 or sorted(set(old[0].get("inboundTag") or [])) != tags:
        rules[:] = [r for r in rules if not is_udp443_block(r)]
        rules.append({"type": "field", "network": "udp", "port": "443", "inboundTag": tags, "outboundTag": "blocked"})
        changes.append(L(f"UDP/443 → blocked для {tags}", f"UDP/443 → blocked for {tags}"))
    if warp == "yes":
        changes += apply_warp(api, template, sorted({tag for tag in (reality_tag, xhttp_tag, hy2_tag) if tag}), xray_bin)
    if changes:
        form = {"xraySetting": json.dumps(template)}
        if loaded.get("outboundTestUrl"):
            form["outboundTestUrl"] = loaded["outboundTestUrl"]
        api.call("panel/api/xray/update", form=form)
    emit({"changes": changes})


def cmd_routing_test(base, token, reality_tag, xhttp_tag, hy2_tag="", warp=""):
    api = Api(base, token)

    def routed(tag, network="tcp", **target):
        form = {"inboundTag": tag, "port": "443", "network": network}
        form.update(target)
        obj = api.call("panel/api/xray/routeTest", form=form)
        return obj.get("outboundTag") if obj and obj.get("matched") else ""

    def blocked(tag, network="tcp", **target):
        return routed(tag, network, **target) == "blocked"

    probe = "probe-" + "".join(c for c in reality_tag + xhttp_tag if c.isalnum())
    checks = {
        L("Reality UDP/443 блокируется", "Reality UDP/443 is blocked"): blocked(reality_tag, "udp", ip="8.8.8.8"),
        L("другой инбаунд UDP/443 не блокируется", "another inbound UDP/443 is not blocked"): not blocked(probe, "udp", ip="8.8.8.8"),
        L("TCP/443 не блокируется", "TCP/443 is not blocked"): not blocked(reality_tag, ip="8.8.8.8"),
        L("geoip:private блокируется", "geoip:private is blocked"): blocked(reality_tag, ip="10.0.0.1"),
        L("RU IP блокируется", "RU IP is blocked"): blocked(reality_tag, ip="77.88.8.8"),
        L("домен .ru блокируется", "a .ru domain is blocked"): blocked(reality_tag, domain="test.ru"),
        L("example.com не блокируется", "example.com is not blocked"): not blocked(reality_tag, domain="example.com"),
        L("bittorrent блокируется", "bittorrent is blocked"): blocked(reality_tag, ip="8.8.8.8", protocol="bittorrent"),
    }
    if xhttp_tag:
        checks[L("XHTTP UDP/443 блокируется", "XHTTP UDP/443 is blocked")] = blocked(xhttp_tag, "udp", ip="8.8.8.8")
    if warp == "yes":
        for tag in sorted({tag for tag in (reality_tag, xhttp_tag, hy2_tag) if tag}):
            checks[L(f"{tag}: example.com выходит через {WARP_TAG}", f"{tag}: example.com exits through {WARP_TAG}")] = \
                routed(tag, domain="example.com") == WARP_TAG
    failed = [name for name, ok in checks.items() if not ok]
    emit({"failed": failed})
    if failed:
        sys.exit(1)


# ПОДПИСКА И JSON

def cmd_sub_endpoints():
    raw = sys.stdin.buffer.read().strip()
    text = ""
    try:
        text = base64.b64decode(raw + b"=" * (-len(raw) % 4), validate=False).decode()
    except (ValueError, UnicodeDecodeError):
        text = ""
    if "://" not in text:
        text = raw.decode(errors="replace")
    result = []
    for line in text.splitlines():
        line = line.strip()
        if "://" not in line:
            continue
        parts = urllib.parse.urlsplit(line)
        query = urllib.parse.parse_qs(parts.query)
        try:
            port = parts.port
        except ValueError:
            port = None
        result.append({"scheme": parts.scheme, "host": parts.hostname or "", "port": port,
                       "type": query.get("type", [""])[0], "security": query.get("security", [""])[0]})
    emit(result)


def cmd_json_get(raw, path):
    value = json.loads(raw)
    for part in path.split("."):
        if isinstance(value, dict):
            value = value.get(part)
        elif isinstance(value, list) and part.isdigit() and int(part) < len(value):
            value = value[int(part)]
        else:
            value = None
        if value is None:
            break
    if value is None:
        print("")
    elif isinstance(value, str):
        print(value)
    else:
        print(json.dumps(value, ensure_ascii=False))


def cmd_json_lines(raw, key):
    value = json.loads(raw).get(key) or []
    for item in value:
        print(item if isinstance(item, str) else json.dumps(item, ensure_ascii=False))


def db_signature(path):
    conn, cur = open_db(path)
    tables = {row[0] for row in cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
              if not row[0].startswith("sqlite_")}
    seeders = set()
    if "history_of_seeders" in tables:
        seeders = {row[0] for row in cur.execute("SELECT seeder_name FROM history_of_seeders")}
    conn.close()
    return tables, seeders


def cmd_db_newer(imported, installed):
    if not os.path.exists(installed):
        return
    tables, seeders = db_signature(imported)
    known_tables, known_seeders = db_signature(installed)
    for name in sorted(seeders - known_seeders):
        print(L(f"миграция {name}", f"migration {name}"))
    for name in sorted(tables - known_tables):
        print(L(f"таблица {name}", f"table {name}"))


# ЗАПУСК

COMMANDS = {
    "own-count": cmd_own_count,
    "discover": cmd_discover,
    "validate-db": cmd_validate_db,
    "import-prepare": cmd_import_prepare,
    "inbounds": cmd_inbounds,
    "reality-xver": cmd_reality_xver,
    "hosts": cmd_hosts,
    "settings-diff": cmd_settings_diff,
    "settings-set": cmd_settings_set,
    "panel-user": cmd_panel_user,
    "api-token-exists": cmd_api_token_exists,
    "api-token-delete": cmd_api_token_delete,
    "create-missing": cmd_create_missing,
    "hosts-add": cmd_hosts_add,
    "config-summary": cmd_config_summary,
    "routing-apply": cmd_routing_apply,
    "routing-test": cmd_routing_test,
    "sub-endpoints": cmd_sub_endpoints,
    "json-get": cmd_json_get,
    "json-lines": cmd_json_lines,
    "db-newer": cmd_db_newer,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(L("неизвестная команда", "unknown command"))
        sys.exit(2)
    try:
        COMMANDS[sys.argv[1]](*sys.argv[2:])
    except Failure as e:
        print(e)
        sys.exit(1)
    except (sqlite3.Error, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as e:
        print(f"{type(e).__name__}: {e}")
        sys.exit(1)


main()
PYEOF
}

py() {
    XUI_LANG="$UI_LANG" python3 -c "$PY_HELPER" "$@"
}

json_get() {
    py json-get "$1" "$2"
}

json_lines() {
    py json-lines "$1" "$2"
}

# СЕТЬ И TLS

tcp_listeners() {
    ss -Htlnp "sport = :$1" 2> /dev/null
}

tcp_listening() {
    tcp_listeners "$2" | awk '{print $4}' | grep -qxF "$1:$2"
}

udp_listeners() {
    ss -Hulnp "sport = :$1" 2> /dev/null
}

xray_holds_udp() {
    udp_listeners "$1" | grep -q '"xray'
}

tcp_port_free() {
    [[ -z "$(tcp_listeners "$1")" ]]
}

public_443_free() {
    tcp_port_free "$PUBLIC_TLS_PORT"
}

nginx_holds_public_443() {
    tcp_listeners "$PUBLIC_TLS_PORT" | grep '"nginx"' | awk '{print $4}' | grep -qvE '^(127\.|\[::1\])'
}

ipv6_enabled() {
    [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2> /dev/null)" == 0 ]]
}

nginx_http_addresses() {
    printf '0.0.0.0:%s\n' "$HTTP_PORT"
    if ipv6_enabled; then
        printf '[::]:%s\n' "$HTTP_PORT"
    fi
}

nginx_expected_addresses() {
    printf '%s\n' "$REALITY_TARGET"
    nginx_http_addresses
}

nginx_expected_text() {
    nginx_expected_addresses | paste -sd ',' - | sed 's/,/, /g'
}

nginx_listens_expected() {
    [[ "$(nginx_addresses | tr '\n' ' ')" == "$(nginx_expected_addresses | sort -u | tr '\n' ' ')" ]]
}

nginx_listens_http() {
    local addr actual
    actual=" $(nginx_addresses | tr '\n' ' ') "
    while IFS= read -r addr; do
        [[ "$actual" == *" ${addr} "* ]] || return 1
    done < <(nginx_http_addresses)
}

xray_holds_443() {
    tcp_listeners "$PUBLIC_TLS_PORT" | grep -q '"xray'
}

nginx_addresses() {
    ss -Htlnp 2> /dev/null | grep '"nginx"' | awk '{print $4}' | sort -u
}

ssh_ports() {
    local ports
    ports=$({
        ss -Htlnp 2> /dev/null | awk '/"sshd"/ {n = split($4, a, ":"); print a[n]}'
        if systemctl is-active --quiet ssh.socket 2> /dev/null; then
            systemctl show -p Listen --value ssh.socket 2> /dev/null | grep -oE ':[0-9]+ \(Stream\)' | grep -oE '[0-9]+'
        fi
    } | grep -E '^[0-9]+$' | sort -un)
    if [[ -z "$ports" ]]; then
        ports=$(sshd -T 2> /dev/null | awk '$1 == "port" {print $2}' | grep -E '^[0-9]+$' | sort -un)
    fi
    printf '%s\n' "${ports:-22}"
}

get_public_ipv4() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2> /dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}')
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip=$(curl -s4 --max-time 5 https://api.ipify.org || true)
    fi
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s' "$ip"
}

tls_probe() {
    local host="$1" port="$2" sni="$3" out
    local args=(-connect "${host}:${port}")
    if [[ "$sni" == "-" ]]; then
        args+=(-noservername)
    else
        args+=(-servername "$sni")
    fi
    out=$(echo | timeout 6 openssl s_client "${args[@]}" 2>&1 | tr -d '\0')
    if grep -qa 'subject=' <<< "$out"; then
        echo cert
    else
        echo reject
    fi
}

dest_ready() {
    local domain="$1" out
    out=$(curl -sk --noproxy '*' --max-time 6 --haproxy-protocol --tlsv1.3 --http2 \
        --resolve "${domain}:${NGINX_PORT}:${NGINX_ADDR}" -o /dev/null -w '%{http_version}\n%{certs}' \
        "https://${domain}:${NGINX_PORT}/" 2> /dev/null)
    [[ "$(head -n1 <<< "$out")" == 2 ]] || return 1
    grep -ai '^subject:' <<< "$out" | grep -qF "$domain" || return 1
    [[ "$(curl_exit_code -k --haproxy-protocol "https://${NGINX_ADDR}:${NGINX_PORT}/")" == 35 ]]
}

http_code() {
    local url="$1" resolve="$2"
    shift 2
    curl -sk --noproxy '*' --max-time 10 --resolve "$resolve" -o /dev/null -w '%{http_code}' "$@" "$url"
}

curl_exit_code() {
    curl -s --noproxy '*' --max-time 10 -o /dev/null "$@" > /dev/null 2>&1
    printf '%s' "$?"
}

# 3X-UI: СЛУЖБА, БАЗА, API

xui_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) printf 'amd64' ;;
        aarch64 | arm64) printf 'arm64' ;;
        *) return 1 ;;
    esac
}

xray_bin() {
    local arch
    arch=$(xui_arch) || return 1
    [[ -x "/usr/local/x-ui/bin/xray-linux-${arch}" ]] || return 1
    printf '%s' "/usr/local/x-ui/bin/xray-linux-${arch}"
}

sha256_of() {
    sha256sum "$1" 2> /dev/null | awk '{print $1}'
}

xui_sum_mismatches() {
    local arch item
    arch=$(xui_arch) || return 0
    for item in "x-ui-${arch}:${XUI_BIN}" "xray-${arch}:/usr/local/x-ui/bin/xray-linux-${arch}" "x-ui.sh:/usr/bin/x-ui"; do
        [[ "$(sha256_of "${item#*:}")" == "${XUI_SHA256[${item%%:*}]}" ]] || printf '%s\n' "${item#*:}"
    done
}

xui_has_config() {
    [[ -s "$XUI_DB" && "$(py own-count "$XUI_DB" 2> /dev/null)" =~ ^[1-9] ]]
}

xui_discover() {
    if [[ -s "$XUI_DB" ]]; then
        py discover "$XUI_DB" 2> /dev/null || echo '{}'
    else
        echo '{}'
    fi
}

journal_tail() {
    journalctl -u "$1" -n 40 --no-pager >> "$LOG_FILE" 2>&1 || true
}

xui_ready() {
    systemctl is-active --quiet x-ui && ss -Htlnp 2> /dev/null | grep -q '"x-ui"'
}

xui_stop() {
    systemctl stop x-ui > /dev/null 2>&1 || true
    sleep 1
}

xui_start() {
    systemctl reset-failed x-ui > /dev/null 2>&1 || true
    if ! systemctl start x-ui > /dev/null 2>&1 || ! wait_for 30 xui_ready; then
        log "$(L "x-ui не запустился, журнал x-ui записан в ${LOG_FILE}" "x-ui did not start, the x-ui journal is saved to ${LOG_FILE}")"
        journal_tail x-ui
        return 1
    fi
    sleep 2
}

xui_restart() {
    xui_stop
    xui_start
}

backup_db_once() {
    [[ -n "$DB_BACKUP" || ! -s "$XUI_DB" ]] && return 0
    DB_BACKUP="${XUI_DB}.bak-$(date +%F-%H%M%S)"
    cp "$XUI_DB" "$DB_BACKUP" || die "$(L "Не удалось сделать резервную копию базы ${XUI_DB}" "Failed to back up the database ${XUI_DB}")"
    log "$(L "Резервная копия базы: ${DB_BACKUP}" "Database backup: ${DB_BACKUP}")"
}

api_token() {
    local out token
    out=$("$XUI_BIN" setting -getApiToken -tokenName "$SCRIPT_NAME" 2>&1)
    token=$(printf '%s\n' "$out" | grep -Eo 'apiToken: *[^ ]+' | awk '{print $2}')
    if [[ -z "$token" ]]; then
        log "$(L "API-токен панели не получен" "Panel API token not received")"
        log_quiet "$out"
        return 1
    fi
    printf '%s' "$token"
}

api_base() {
    printf 'http://%s:%s%s/' "$NGINX_ADDR" "$PANEL_PORT" "$(conf_get PANEL_PATH)"
}

xhttp_enabled() {
    [[ "$(conf_get XHTTP)" != no ]]
}

recommended() {
    [[ "$(conf_get INSTALL_MODE)" == recommended ]]
}

xhttp_port() {
    local port
    port=$(conf_get XHTTP_PORT)
    printf '%s' "${port:-$XHTTP_DEFAULT_PORT}"
}

site_names() {
    awk '$1 == "server_name" {for (i = 2; i <= NF; i++) {gsub(/;/, "", $i); if ($i != "") print $i}}' "$1" 2> /dev/null
}

other_domain_site() {
    local names
    names=$(site_names "$1")
    [[ -n "$names" ]] || return 1
    grep -qE '^[[:space:]]*listen[^;]*default_server' "$1" && return 1
    ! grep -qxF -e "$(conf_get DOMAIN)" -e "_" <<< "$names"
}

xhttp_path_answer() {
    xhttp_enabled || return 0
    conf_get XHTTP_PATH
}

warp_enabled() {
    [[ "$(conf_get WARP)" == yes ]]
}

hy2_port_answer() {
    if [[ "$(conf_get HY2)" == yes ]]; then
        printf '%s' "$HY2_PORT"
    else
        printf '0'
    fi
}

# ПРИВЕДЕНИЕ К ЦЕЛЕВОМУ СОСТОЯНИЮ

converge() {
    local title="$1" name="$2"
    step "$title"
    if "check_${name}"; then
        report_ok "$(L "без изменений" "no changes")"
        step_end
        return 0
    fi
    "apply_${name}" || die "$(L "не удалось привести к целевому состоянию" "failed to reach the target state")"
    log_quiet "$(L "Повторная проверка." "Checking again.")"
    "check_${name}" || die "$(L "после изменений проверка не пройдена" "check failed after the changes")"
    report_ok "$(L "готово" "done")"
    step_end
}

# ОТВЕТЫ ПОЛЬЗОВАТЕЛЯ

discover_domain() {
    grep -RhoE '^[[:space:]]*server_name[[:space:]]+[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$NGINX_SITES_ENABLED" "$NGINX_CONF_D" \
        2> /dev/null | awk '{print $2}' | head -n1
}

discover_cert_folder() {
    grep -RhoE '^[[:space:]]*ssl_certificate[[:space:]]+/etc/ssl/[A-Za-z0-9._-]+/' "$NGINX_SITES_ENABLED" 2> /dev/null \
        | awk '{print $2}' | cut -d/ -f4 | head -n1
}

discover_email() {
    sed -n "s/^ACCOUNT_EMAIL='\(.*\)'$/\1/p" /root/.acme.sh/account.conf 2> /dev/null | head -n1
}

resolve_answer() {
    local key="$1" prompt="$2" def="$3" regex="$4" err="$5" value
    value=$(conf_get "$key")
    [[ -n "$value" && "$RECONFIGURE" -eq 0 ]] && return 0
    ask value "$prompt" "${value:-$def}" "$regex" "$err"
    conf_set "$key" "$value"
}

resolve_language() {
    local choice def=1
    if [[ "$RECONFIGURE" -eq 0 ]]; then
        [[ -n "$(conf_get LANGUAGE)" || -n "$(conf_get DOMAIN)" || -s "$XUI_DB" ]] && return 0
    fi
    [[ "$UI_LANG" == en ]] && def=2
    echo "Язык / Language:"
    echo "  1  Русский"
    echo "  2  English"
    while true; do
        prompted
        read -r -p "Выбор / Choice (Enter — ${def}): " choice || die "$(L "Ввод прерван." "Input interrupted.")"
        case "${choice:-$def}" in
            1) UI_LANG=ru ;;
            2) UI_LANG=en ;;
            *)
                echo "  1 / 2"
                continue
                ;;
        esac
        conf_set LANGUAGE "$UI_LANG"
        return 0
    done
}

resolve_install_mode() {
    local choice
    if [[ "$RECONFIGURE" -eq 1 ]]; then
        [[ "$(conf_get INSTALL_MODE)" == manual ]] || conf_set INSTALL_MODE manual
        return 0
    fi
    [[ -n "$(conf_get INSTALL_MODE)" || -n "$(conf_get DOMAIN)" ]] && return 0
    xui_has_config && return 0
    printf '%s\n' "$(L "Вариант установки:" "Installation type:")"
    printf '%s\n' "$(L "  1  Стандартная — только VLESS Reality на 443, нужны домен и email," "  1  Standard — VLESS Reality on 443 only, the domain and email are needed,")"
    printf '%s\n' "$(L "     остальные параметры заполняются автоматически" "     everything else is filled in automatically")"
    printf '%s\n' "$(L "  2  Расширенная — дополнительно XHTTP и Hysteria2, свои пути, логин и пароль панели," "  2  Extended — XHTTP and Hysteria2 on top, custom paths, panel username and password,")"
    printf '%s\n' "$(L "     перенос базы x-ui.db" "     moving an x-ui.db database")"
    while true; do
        prompted
        read -r -p "$(L "Выбор (Enter — 1): " "Choice (Enter — 1): ")" choice || die "$(L "Ввод прерван." "Input interrupted.")"
        case "${choice:-1}" in
            1)
                conf_set INSTALL_MODE recommended
                return 0
                ;;
            2)
                conf_set INSTALL_MODE manual
                return 0
                ;;
        esac
        printf '%s\n' "$(L "  Ожидается 1 или 2." "  Expected 1 or 2.")"
    done
}

resolve_base_answers() {
    resolve_answer DOMAIN "$(L "Домен сервера (например srv1.example.com)" "Server domain (for example srv1.example.com)")" "$(discover_domain)" \
        "$DOMAIN_RE" "$(L "Некорректный домен. Пример: srv1.example.com" "Invalid domain. Example: srv1.example.com")"
    recommended && [[ -z "$(conf_get CERT_FOLDER)" ]] && conf_set CERT_FOLDER "$(conf_get DOMAIN)"
    resolve_answer CERT_FOLDER "$(L "Папка сертификата в /etc/ssl/" "Certificate folder in /etc/ssl/")" "$(conf_get DOMAIN)" \
        "$FOLDER_RE" "$(L "Только буквы, цифры, точка, дефис, подчёркивание." "Letters, digits, dot, hyphen and underscore only.")"
    resolve_answer ACME_EMAIL "$(L "Email для Let's Encrypt" "Email for Let's Encrypt")" "$(discover_email)" \
        "$EMAIL_RE" "$(L "Некорректный email. Пример: you@example.com" "Invalid email. Example: you@example.com")"
}

resolve_import() {
    local path reason
    IMPORT_DB=""
    recommended && return 0
    if xui_has_config && [[ "$RECONFIGURE" -eq 0 ]]; then
        return 0
    fi
    while true; do
        if xui_has_config; then
            ask_optional path "$(L "Путь к x-ui.db для переноса (Enter — оставить текущую базу)" "Path to x-ui.db to move (Enter — keep the current database)")"
        else
            ask_optional path "$(L "Путь к x-ui.db для переноса с другого сервера (Enter — установка с нуля)" "Path to x-ui.db from another server (Enter — fresh install)")"
        fi
        [[ -z "$path" ]] && return 0
        if [[ ! -f "$path" ]]; then
            printf '%s\n' "$(L "  Файл не найден." "  File not found.")"
            continue
        fi
        if [[ "$(head -c 15 "$path" 2> /dev/null)" != "SQLite format 3" ]]; then
            printf '%s\n' "$(L "  Это не база SQLite." "  This is not an SQLite database.")"
            continue
        fi
        if ! reason=$(py validate-db "$path" 2>&1); then
            echo "  ${reason}"
            continue
        fi
        IMPORT_DB="$path"
        return 0
    done
}

resolve_path() {
    local key="$1" prompt="$2" discovered="$3" current value
    current=$(conf_get "$key")
    if [[ -z "$current" && -n "$discovered" ]]; then
        discovered=$(normalize_path "$discovered")
        if [[ "$discovered" =~ ^(/[A-Za-z0-9_-]+)+$ ]]; then
            conf_set "$key" "$discovered"
            log "$(L "${prompt}: взят из базы 3x-ui." "${prompt}: taken from the 3x-ui database.")"
            return 0
        fi
    fi
    [[ -n "$current" && "$RECONFIGURE" -eq 0 ]] && return 0
    if recommended && [[ -z "$current" ]]; then
        conf_set "$key" "/$(random_string 'a-z0-9' 14)"
        return 0
    fi
    while true; do
        if [[ -n "$current" ]]; then
            ask_optional value "$(L "${prompt} (Enter — оставить текущий)" "${prompt} (Enter — keep the current one)")"
            value="${value:-$current}"
        else
            ask_optional value "$(L "${prompt} (Enter — случайная строка)" "${prompt} (Enter — random string)")"
            value="${value:-$(random_string 'a-z0-9' 14)}"
        fi
        if [[ ! "$value" =~ $PATH_RE ]]; then
            printf '%s\n' "$(L "  Разрешены буквы, цифры, дефис, подчёркивание и / между частями пути." "  Letters, digits, hyphen, underscore and / between path parts are allowed.")"
            continue
        fi
        conf_set "$key" "$(normalize_path "$value")"
        return 0
    done
}

paths_conflict() {
    local -a paths=("$(conf_get XHTTP_PATH)" "$(conf_get SUB_PATH)" "$(conf_get PANEL_PATH)")
    local i j
    for ((i = 0; i < ${#paths[@]}; i++)); do
        for ((j = 0; j < ${#paths[@]}; j++)); do
            ((i == j)) && continue
            [[ -n "${paths[i]}" && -n "${paths[j]}" ]] || continue
            [[ "${paths[i]}/" == "${paths[j]}/"* ]] && return 0
        done
    done
    return 1
}

resolve_xhttp() {
    local current
    current=$(json_get "$(xui_discover)" xhttp_path)
    if [[ -n "$current" ]]; then
        [[ "$(conf_get XHTTP)" == yes ]] || conf_set XHTTP yes
        return 0
    fi
    [[ -n "$(conf_get XHTTP)" && "$RECONFIGURE" -eq 0 ]] && return 0
    if recommended; then
        conf_set XHTTP no
        return 0
    fi
    if ask_yes_no "$(L "Добавить VLESS XHTTP?" "Add VLESS XHTTP?")" y; then
        conf_set XHTTP yes
    else
        conf_set XHTTP no
        conf_unset XHTTP_PATH
    fi
}

xhttp_port_invalid() {
    local port="$1" p
    if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || ((10#$port < 1024 || 10#$port > 65535)); then
        printf '%s\n' "$(L "допустимо 1024–65535" "allowed 1024–65535")"
        return 0
    fi
    port=$((10#$port))
    for p in "${INTERNAL_PORTS[@]}" "$HTTP_PORT" "$PUBLIC_TLS_PORT" $(ssh_ports); do
        if ((port == p)); then
            printf '%s\n' "$(L "порт ${port} занят службой сервера" "port ${port} is used by a server service")"
            return 0
        fi
    done
    if ! tcp_port_free "$port"; then
        printf '%s\n' "$(L "TCP/${port} уже занят" "TCP/${port} is already in use")"
        return 0
    fi
    return 1
}

resolve_xhttp_port() {
    local current value reason
    xhttp_enabled || return 0
    current=$(json_get "$(xui_discover)" xhttp_port)
    if [[ -n "$current" ]]; then
        [[ "$(conf_get XHTTP_PORT)" == "$current" ]] || conf_set XHTTP_PORT "$current"
        return 0
    fi
    [[ -n "$(conf_get XHTTP_PORT)" && "$RECONFIGURE" -eq 0 ]] && return 0
    if recommended; then
        conf_set XHTTP_PORT "$XHTTP_DEFAULT_PORT"
        return 0
    fi
    while true; do
        ask_optional value "$(L "Внутренний порт XHTTP (Enter — $(xhttp_port), допустимо 1024–65535)" "Internal XHTTP port (Enter — $(xhttp_port), allowed 1024–65535)")"
        value="${value:-$(xhttp_port)}"
        if reason=$(xhttp_port_invalid "$value"); then
            printf '%s\n' "$(L "  Не подходит: ${reason}." "  Not suitable: ${reason}.")"
            continue
        fi
        conf_set XHTTP_PORT "$((10#$value))"
        return 0
    done
}

resolve_paths() {
    local discovered="{}" key
    xui_has_config && discovered=$(xui_discover)
    xhttp_enabled && resolve_path XHTTP_PATH "$(L "Секретный путь XHTTP" "Secret XHTTP path")" "$(json_get "$discovered" xhttp_path)"
    resolve_path SUB_PATH "$(L "Секретный путь подписки" "Secret subscription path")" "$(json_get "$discovered" sub_path)"
    resolve_path PANEL_PATH "$(L "Секретный путь панели" "Secret panel path")" "$(json_get "$discovered" web_base_path)"
    if paths_conflict; then
        log "$(L "Пути XHTTP, подписки и панели совпадают или вложены друг в друга." "XHTTP, subscription and panel paths match or are nested in each other.")"
        for key in $(xhttp_enabled && echo XHTTP_PATH) SUB_PATH PANEL_PATH; do
            CONF[$key]=""
        done
        conf_save
        resolve_paths_again
    fi
}

resolve_paths_again() {
    xhttp_enabled && resolve_path XHTTP_PATH "$(L "Секретный путь XHTTP" "Secret XHTTP path")" ""
    resolve_path SUB_PATH "$(L "Секретный путь подписки" "Secret subscription path")" ""
    resolve_path PANEL_PATH "$(L "Секретный путь панели" "Secret panel path")" ""
    if paths_conflict; then
        die "$(L "Пути XHTTP, подписки и панели совпадают или входят один в другой." "XHTTP, subscription and panel paths match or are nested in each other.")"
    fi
}

resolve_credentials() {
    local username password
    [[ -n "$(conf_get XUI_CREDENTIALS_PENDING)" ]] && return 0
    if [[ "$RECONFIGURE" -eq 1 || "$IMPORTED_NOW" -eq 1 ]]; then
        if [[ -n "$(conf_get XUI_USERNAME)" ]] || xui_has_config; then
            ask_yes_no "$(L "Задать новый логин и пароль панели?" "Set a new panel username and password?")" n || return 0
        fi
    else
        [[ -n "$(conf_get XUI_USERNAME)" ]] && return 0
        xui_has_config && return 0
    fi
    if recommended; then
        conf_set XUI_USERNAME "admin$(random_string 'a-z0-9' 6)"
        conf_set XUI_PASSWORD "$(random_string 'A-Za-z0-9' 16)"
        conf_unset XUI_PASSWORD_HASH
        conf_set XUI_CREDENTIALS_PENDING yes
        return 0
    fi
    ask_optional username "$(L "Логин панели (Enter — случайный)" "Panel username (Enter — random)")"
    [[ -z "$username" ]] && username="admin$(random_string 'a-z0-9' 6)"
    [[ "$username" =~ $USERNAME_RE ]] || die "$(L "Логин: 3–32 символа (буквы, цифры, точка, дефис, подчёркивание)." "Username: 3–32 characters (letters, digits, dot, hyphen, underscore).")"
    ask_password password "$(L "Пароль панели" "Panel password")"
    conf_set XUI_USERNAME "$username"
    conf_set XUI_PASSWORD "$password"
    conf_unset XUI_PASSWORD_HASH
    conf_set XUI_CREDENTIALS_PENDING yes
}

# HYSTERIA2

resolve_hy2() {
    if [[ -n "$(json_get "$(xui_discover)" hy2_port)" ]]; then
        [[ "$(conf_get HY2)" == yes ]] || conf_set HY2 yes
        return 0
    fi
    [[ -n "$(conf_get HY2)" && "$RECONFIGURE" -eq 0 ]] && return 0
    if recommended; then
        conf_set HY2 no
        return 0
    fi
    if ask_yes_no "$(L "Добавить Hysteria2 (UDP/${HY2_PORT})?" "Add Hysteria2 (UDP/${HY2_PORT})?")" y; then
        conf_set HY2 yes
    else
        conf_set HY2 no
    fi
}

resolve_warp() {
    local previous
    previous=$(conf_get WARP)
    [[ -n "$previous" && "$RECONFIGURE" -eq 0 ]] && return 0
    if recommended || { [[ "$RECONFIGURE" -eq 0 ]] && xui_has_config; }; then
        conf_set WARP no
        return 0
    fi
    if ask_yes_no "$(L "Добавить выход в интернет через Cloudflare WARP?" "Add an exit to the internet through Cloudflare WARP?")" n; then
        conf_set WARP yes
        return 0
    fi
    conf_set WARP no
    if [[ "$previous" == yes ]]; then
        printf '%s\n' "$(L "  Исходящий warp и правило маршрутизации остаются, они удаляются в панели 3x-ui." "  The warp outbound and the routing rule stay, they are removed in the 3x-ui panel.")"
    fi
}

resolve_client_name() {
    local name
    [[ "$(json_get "$(xui_discover)" has_clients)" == true ]] && return 0
    [[ -n "$(conf_get CLIENT_NAME)" && "$RECONFIGURE" -eq 0 ]] && return 0
    if recommended; then
        conf_set CLIENT_NAME client1
        return 0
    fi
    name=$(conf_get CLIENT_NAME)
    ask name "$(L "Имя первого клиента" "First client name")" "${name:-client1}" "$NAME_RE" "$(L "Разрешены буквы, цифры, дефис и подчёркивание." "Letters, digits, hyphen and underscore are allowed.")"
    conf_set CLIENT_NAME "$name"
}

# ПОРТ 80

nginx_http_site_file() {
    printf '%s/10-http-%s.conf' "$NGINX_CONF_D" "$(conf_get DOMAIN)"
}

acme_challenge_dir() {
    printf '%s/.well-known/acme-challenge' "$ACME_WEBROOT"
}

render_nginx_http_reject() {
    printf 'server {\n'
    printf '    listen %s default_server;\n' "$HTTP_PORT"
    if ipv6_enabled; then
        printf '    listen [::]:%s default_server;\n' "$HTTP_PORT"
    fi
    printf '    server_name _;\n'
    printf '    return 444;\n'
    printf '}\n'
}

render_nginx_http_site() {
    local domain
    domain=$(conf_get DOMAIN)
    printf 'server {\n'
    printf '    listen %s;\n' "$HTTP_PORT"
    if ipv6_enabled; then
        printf '    listen [::]:%s;\n' "$HTTP_PORT"
    fi
    cat << EOF
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 301 https://${domain}\$request_uri;
    }
}
EOF
}

nginx_stale_http_sites() {
    local f current
    current=$(nginx_http_site_file)
    for f in "$NGINX_CONF_D"/10-http-*.conf; do
        [[ -f "$f" && "$f" != "$current" ]] || continue
        grep -qF "root ${ACME_WEBROOT};" "$f" && grep -qF 'return 301 https://' "$f" && printf '%s\n' "$f"
    done
    return 0
}

challenge_served() {
    local addr="$1" domain dir name token body
    domain=$(conf_get DOMAIN)
    dir=$(acme_challenge_dir)
    [[ -d "$dir" ]] || return 1
    name="check-$(random_string 'a-z0-9' 16)"
    token=$(random_string 'A-Za-z0-9' 32)
    printf '%s' "$token" > "${dir}/${name}" 2> /dev/null || return 1
    chmod 644 "${dir}/${name}"
    body=$(curl -s --noproxy '*' --max-time 10 --resolve "${domain}:${HTTP_PORT}:${addr}" \
        "http://${domain}/.well-known/acme-challenge/${name}")
    rm -f "${dir}/${name}"
    [[ "$body" == "$token" ]]
}

ufw_active() {
    ufw_present && ufw status 2> /dev/null | grep -q 'Status: active'
}

check_http() {
    local rc=0 code addr
    if ! command -v nginx > /dev/null 2>&1; then
        mismatch "$(L "nginx не установлен" "nginx is not installed")"
        return 1
    fi
    render_nginx_http_reject | cmp -s - "$NGINX_HTTP_REJECT_CONF" || {
        template_differs "$(L "антискан ${HTTP_PORT}/tcp" "anti-scan ${HTTP_PORT}/tcp")" "$NGINX_HTTP_REJECT_CONF"
        rc=1
    }
    render_nginx_http_site | cmp -s - "$(nginx_http_site_file)" || {
        template_differs "$(L "сайт на ${HTTP_PORT}" "site on ${HTTP_PORT}")" "$(nginx_http_site_file)"
        rc=1
    }
    [[ -e "${NGINX_SITES_ENABLED}/default" ]] && {
        mismatch "$(L "подключён сайт default" "the default site is enabled")"
        rc=1
    }
    [[ -n "$(nginx_stale_http_sites)" ]] && {
        mismatch "$(L "лишний сайт на ${HTTP_PORT}: $(nginx_stale_http_sites | tr '\n' ' ')" "extra site on ${HTTP_PORT}: $(nginx_stale_http_sites | tr '\n' ' ')")"
        rc=1
    }
    [[ -d "$(acme_challenge_dir)" ]] || {
        mismatch "$(L "нет каталога $(acme_challenge_dir)" "no directory $(acme_challenge_dir)")"
        rc=1
    }
    if ! systemctl is-active --quiet nginx; then
        mismatch "$(L "nginx не запущен" "nginx is not running")"
        return 1
    fi
    while IFS= read -r addr; do
        nginx_addresses | grep -qxF "$addr" || {
            mismatch "$(L "nginx не слушает ${addr}" "nginx does not listen on ${addr}")"
            rc=1
        }
    done < <(nginx_http_addresses)
    challenge_served 127.0.0.1 || {
        mismatch "$(L "http://$(conf_get DOMAIN)/.well-known/acme-challenge/ не отдаёт файлы из $(acme_challenge_dir)" "http://$(conf_get DOMAIN)/.well-known/acme-challenge/ does not serve files from $(acme_challenge_dir)")"
        rc=1
    }
    code=$(curl_exit_code "http://127.0.0.1/")
    [[ "$code" == 52 ]] || {
        mismatch "$(L "http://127.0.0.1/: curl exit ${code}, ожидался 52 (закрытие без ответа)" "http://127.0.0.1/: curl exit ${code}, expected 52 (closed without a response)")"
        rc=1
    }
    if ufw_active && ! ufw_allows "${HTTP_PORT}/tcp"; then
        mismatch "$(L "нет правила ufw ${HTTP_PORT}/tcp" "no ufw rule ${HTTP_PORT}/tcp")"
        rc=1
    fi
    return "$rc"
}

nginx_write_http_files() {
    local dir f
    dir=$(acme_challenge_dir)
    rm -f "${NGINX_SITES_ENABLED}/default"
    while IFS= read -r f; do
        [[ -n "$f" ]] && rm -f "$f" && log "$(L "удалён ${f}" "removed ${f}")"
    done < <(nginx_stale_http_sites)
    mkdir -p "$dir" && chmod 755 "$ACME_WEBROOT" "${ACME_WEBROOT}/.well-known" "$dir"
    render_nginx_http_reject > "$NGINX_HTTP_REJECT_CONF"
    render_nginx_http_site > "$(nginx_http_site_file)"
}

apply_http() {
    local others foreign stale
    others=$(tcp_listeners "$HTTP_PORT" | grep -v '"nginx"')
    if [[ -n "$others" ]]; then
        log "$(L "Порт ${HTTP_PORT}/tcp занят другим процессом:" "Port ${HTTP_PORT}/tcp is used by another process:")"
        log_lines "  " <<< "$others"
        return 1
    fi
    install_nginx || return 1
    mapfile -t stale < <(nginx_stale_http_sites)
    foreign=$(nginx_foreign_listeners "$HTTP_PORT" "$NGINX_HTTP_REJECT_CONF" "$(nginx_http_site_file)" "${stale[@]}")
    if [[ -n "$foreign" ]]; then
        log "$(L "Порт ${HTTP_PORT} заняли другие конфиги nginx:" "Port ${HTTP_PORT} is taken by other nginx configs:")"
        log_lines "  " <<< "$foreign"
        return 1
    fi
    nginx_apply nginx_write_http_files nginx_listens_http || return 1
    if ufw_present && ! ufw_allows "${HTTP_PORT}/tcp"; then
        ufw allow "${HTTP_PORT}/tcp" comment "$SCRIPT_NAME" > /dev/null 2>&1 && log "$(L "ufw: добавлено ${HTTP_PORT}/tcp" "ufw: added ${HTTP_PORT}/tcp")"
    fi
    return 0
}

# СЕРТИФИКАТ

cert_dir() {
    printf '/etc/ssl/%s' "$(conf_get CERT_FOLDER)"
}

cert_valid() {
    local domain="$1" dir="$2" cert_pub key_pub
    [[ -s "${dir}/fullchain.pem" && -s "${dir}/privkey.pem" ]] || return 1
    openssl x509 -checkend $((30 * 86400)) -noout -in "${dir}/fullchain.pem" > /dev/null 2>&1 || return 1
    openssl x509 -noout -ext subjectAltName -in "${dir}/fullchain.pem" 2> /dev/null \
        | grep -qE "DNS:${domain//./\\.}(,|[[:space:]]|$)" || return 1
    cert_pub=$(openssl x509 -noout -pubkey -in "${dir}/fullchain.pem" 2> /dev/null) || return 1
    key_pub=$(openssl pkey -pubout -in "${dir}/privkey.pem" 2> /dev/null) || return 1
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

acme_domain_conf() {
    local domain
    domain=$(conf_get DOMAIN)
    printf '/root/.acme.sh/%s_ecc/%s.conf' "$domain" "$domain"
}

acme_webroot_set() {
    grep -qxF "Le_Webroot='${ACME_WEBROOT}'" "$(acme_domain_conf)" 2> /dev/null
}

acme_set_webroot() {
    local conf backup
    conf=$(acme_domain_conf)
    if ! grep -q '^Le_Webroot=' "$conf" 2> /dev/null; then
        log "$(L "Нет строки Le_Webroot в ${conf}" "No Le_Webroot line in ${conf}")"
        return 1
    fi
    backup="${conf}.bak-$(date +%F-%H%M%S)"
    cp -p "$conf" "$backup" || return 1
    sed -i "s|^Le_Webroot=.*|Le_Webroot='${ACME_WEBROOT}'|" "$conf"
    if ! acme_webroot_set; then
        log "$(L "Не удалось записать Le_Webroot='${ACME_WEBROOT}' в ${conf}" "Failed to write Le_Webroot='${ACME_WEBROOT}' to ${conf}")"
        return 1
    fi
    log "$(L "acme.sh: Le_Webroot='${ACME_WEBROOT}' в ${conf}, копия: ${backup}" "acme.sh: Le_Webroot='${ACME_WEBROOT}' in ${conf}, backup: ${backup}")"
}

render_cert_renew() {
    cat << EOF
#!/usr/bin/env bash
set -u
DOMAIN="$(conf_get DOMAIN)"
ACME="${ACME}"
CERT="$(cert_dir)/fullchain.pem"
DAYS_BEFORE=30
LOG="/var/log/cert-renew.log"
log() { echo "\$(date '+%F %T') \$*" >> "\$LOG"; }

if [ "\${FORCE:-0}" != "1" ] && openssl x509 -checkend \$((DAYS_BEFORE * 86400)) -noout -in "\$CERT"; then
    log "Cert valid >\${DAYS_BEFORE}d — no action."
    exit 0
fi
log "Renewal due (or FORCE=1) — starting (webroot)."
if "\$ACME" --renew -d "\$DOMAIN" --ecc --force; then
    log "Renewal OK."
    systemctl reload nginx && log "nginx reloaded."
else
    log "Renewal FAILED (acme exit \$?)."
fi
EOF
}

renew_cron_present() {
    crontab -l -u root 2> /dev/null | grep -qF "$CERT_RENEW"
}

acme_cron_present() {
    crontab -l -u root 2> /dev/null | grep -q 'acme.sh --cron'
}

check_cert() {
    local rc=0
    if ! cert_valid "$(conf_get DOMAIN)" "$(cert_dir)"; then
        mismatch "$(L "сертификат $(cert_dir)/fullchain.pem для $(conf_get DOMAIN) отсутствует, истекает в течение 30 дней или не совпадает с ключом" "certificate $(cert_dir)/fullchain.pem for $(conf_get DOMAIN) is missing, expires within 30 days or does not match the key")"
        rc=1
    fi
    acme_webroot_set || {
        mismatch "$(L "acme.sh не в режиме webroot: нет строки Le_Webroot='${ACME_WEBROOT}' в $(acme_domain_conf)" "acme.sh is not in webroot mode: no Le_Webroot='${ACME_WEBROOT}' line in $(acme_domain_conf)")"
        rc=1
    }
    render_cert_renew | cmp -s - "$CERT_RENEW" || {
        template_differs "$(L "скрипт продления" "renewal script")" "$CERT_RENEW"
        rc=1
    }
    renew_cron_present || {
        mismatch "$(L "нет задачи cron для ${CERT_RENEW}" "no cron job for ${CERT_RENEW}")"
        rc=1
    }
    acme_cron_present && {
        mismatch "$(L "в cron есть задача acme.sh (продление идёт через ${CERT_RENEW})" "cron has an acme.sh job (renewal goes through ${CERT_RENEW})")"
        rc=1
    }
    return "$rc"
}

acme_install_cert() {
    local domain="$1" dir="$2"
    mkdir -p "$dir"
    "$ACME" --install-cert -d "$domain" --ecc \
        --fullchain-file "${dir}/fullchain.pem" \
        --key-file "${dir}/privkey.pem" \
        --reloadcmd "systemctl reload nginx 2>/dev/null || true" >> "$LOG_FILE" 2>&1
}

issue_cert() {
    local domain dir rc attempt
    domain=$(conf_get DOMAIN)
    dir=$(cert_dir)
    if [[ ! -x "$ACME" ]]; then
        log "$(L "Установка acme.sh" "Installing acme.sh")"
        curl -fsSL https://get.acme.sh | sh -s email="$(conf_get ACME_EMAIL)" >> "$LOG_FILE" 2>&1
        [[ -x "$ACME" ]] || {
            log "$(L "Не удалось установить acme.sh" "Failed to install acme.sh")"
            return 1
        }
    fi
    "$ACME" --set-default-ca --server letsencrypt >> "$LOG_FILE" 2>&1 || true
    for attempt in 1 2; do
        log "$(L "Выпуск сертификата для ${domain} (HTTP-01, webroot ${ACME_WEBROOT})" "Issuing a certificate for ${domain} (HTTP-01, webroot ${ACME_WEBROOT})")"
        "$ACME" --issue -d "$domain" --keylength ec-256 -w "$ACME_WEBROOT" >> "$LOG_FILE" 2>&1
        rc=$?
        [[ "$rc" -eq 0 || "$rc" -eq 2 ]] && break
        if [[ "$attempt" -eq 1 ]]; then
            log "$(L "acme.sh завершился с кодом ${rc}, повторная попытка через 10 с" "acme.sh exited with code ${rc}, retrying in 10 s")"
            sleep 10
        fi
    done
    if [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
        log "$(L "acme.sh не выпустил сертификат, код ${rc}. Возможные причины: A-запись домена указывает не на этот сервер, ${HTTP_PORT}/tcp закрыт снаружи" "acme.sh did not issue the certificate, code ${rc}. Possible causes: the domain's A record does not point to this server, ${HTTP_PORT}/tcp is closed from the outside")"
        return 1
    fi
    acme_webroot_set || acme_set_webroot || return 1
    acme_install_cert "$domain" "$dir"
    if ! cert_valid "$domain" "$dir" && [[ "$rc" -eq 2 ]]; then
        log "$(L "Сертификат acme.sh не подходит, перевыпуск" "The acme.sh certificate is not suitable, reissuing")"
        "$ACME" --renew -d "$domain" --ecc --force >> "$LOG_FILE" 2>&1
        acme_install_cert "$domain" "$dir"
    fi
    chmod 600 "${dir}/privkey.pem" 2> /dev/null
    cert_valid "$domain" "$dir" || {
        log "$(L "Сертификат не установлен в ${dir}" "The certificate is not installed in ${dir}")"
        return 1
    }
}

apply_cert() {
    if ! cert_valid "$(conf_get DOMAIN)" "$(cert_dir)" || [[ ! -f "$(acme_domain_conf)" ]]; then
        issue_cert || return 1
    fi
    acme_webroot_set || acme_set_webroot || return 1
    render_cert_renew > "$CERT_RENEW"
    chmod 700 "$CERT_RENEW"
    [[ -x "$ACME" ]] && "$ACME" --uninstall-cronjob >> "$LOG_FILE" 2>&1
    {
        crontab -l -u root 2> /dev/null | grep -vF "$CERT_RENEW" | grep -v 'acme.sh --cron'
        echo "17 3 * * * ${CERT_RENEW}"
    } | crontab -u root - || {
        log "$(L "Не удалось записать задачу cron" "Failed to write the cron job")"
        return 1
    }
    "$CERT_RENEW" >> "$LOG_FILE" 2>&1
    log "$(L "Автопродление: ${CERT_RENEW}, cron root, ежедневно в 03:17" "Auto-renewal: ${CERT_RENEW}, root cron, daily at 03:17")"
}

# УСТАНОВКА 3X-UI И ПЕРЕНОС БАЗЫ

check_xui() {
    local rc=0 version file
    if [[ ! -x "$XUI_BIN" ]]; then
        mismatch "$(L "3x-ui не установлен" "3x-ui is not installed")"
        return 1
    fi
    version="v$("$XUI_BIN" -v 2> /dev/null)"
    log "3x-ui ${version}"
    if [[ "$version" != "$XUI_SUPPORTED_VERSION" ]]; then
        warn_lines <<< "$(L "3x-ui ${version}: со скриптом проверена ${XUI_SUPPORTED_VERSION}" "3x-ui ${version}: the script is tested with ${XUI_SUPPORTED_VERSION}")"
    fi
    [[ -n "$(conf_get XUI_VERIFY_PENDING)" ]] && {
        mismatch "$(L "файлы 3x-ui не сверены с суммами SHA-256 из скрипта" "3x-ui files are not verified against the SHA-256 sums from the script")"
        rc=1
    }
    if [[ "$CHECK_ONLY" -eq 1 && "$version" == "$XUI_SUPPORTED_VERSION" ]]; then
        while IFS= read -r file; do
            [[ -n "$file" ]] && report_warn "$(L "SHA-256 ${file} отличается от суммы 3x-ui ${version} из скрипта" "SHA-256 of ${file} differs from the 3x-ui ${version} sum in the script")"
        done < <(xui_sum_mismatches)
    fi
    [[ -n "$IMPORT_DB" ]] && {
        mismatch "$(L "ожидается перенос базы ${IMPORT_DB}" "database move ${IMPORT_DB} is pending")"
        rc=1
    }
    xray_bin > /dev/null || {
        mismatch "$(L "xray-core не найден" "xray-core not found")"
        rc=1
    }
    systemctl is-active --quiet x-ui || {
        mismatch "$(L "служба x-ui не запущена" "the x-ui service is not running")"
        rc=1
    }
    return "$rc"
}

xui_latest_version() {
    curl -fsS --max-time 10 "https://api.github.com/repos/${XUI_REPO}/releases/latest" 2> /dev/null \
        | python3 -c 'import json, sys; print(json.load(sys.stdin).get("tag_name", ""))' 2> /dev/null
}

resolve_xui_version() {
    local latest choice
    XUI_VERSION="$XUI_SUPPORTED_VERSION"
    [[ -x "$XUI_BIN" ]] && return 0
    latest=$(xui_latest_version)
    if [[ ! "$latest" =~ ^v[0-9]+(\.[0-9]+)*$ ]]; then
        log_quiet "$(L "Последняя версия 3x-ui не получена из GitHub API, выбрана ${XUI_SUPPORTED_VERSION}." "The latest 3x-ui version was not received from the GitHub API, ${XUI_SUPPORTED_VERSION} selected.")"
        return 0
    fi
    version_ge "${XUI_SUPPORTED_VERSION#v}" "${latest#v}" && return 0
    recommended && return 0
    if [[ ! -t 0 ]]; then
        log_quiet "$(L "Последняя версия 3x-ui ${latest}, ввод не с терминала, выбрана ${XUI_SUPPORTED_VERSION}." "The latest 3x-ui version is ${latest}, input is not from a terminal, ${XUI_SUPPORTED_VERSION} selected.")"
        return 0
    fi
    printf '%s\n' "$(L "Версия 3x-ui:" "3x-ui version:")"
    printf '%s\n' "$(L "  1 — ${XUI_SUPPORTED_VERSION}, проверена со скриптом" "  1 — ${XUI_SUPPORTED_VERSION}, tested with the script")"
    printf '%s\n' "$(L "  2 — ${latest}, последняя, со скриптом не проверена" "  2 — ${latest}, the latest, not tested with the script")"
    while true; do
        prompted
        read -r -p "$(L "Выбор (Enter — 1): " "Choice (Enter — 1): ")" choice || die "$(L "Ввод прерван." "Input interrupted.")"
        case "${choice:-1}" in
            1) return 0 ;;
            2)
                XUI_VERSION="$latest"
                return 0
                ;;
        esac
        printf '%s\n' "$(L "  Ожидается 1 или 2." "  Expected 1 or 2.")"
    done
}

install_xui() {
    local installer sum version="${XUI_VERSION:-$XUI_SUPPORTED_VERSION}"
    log "$(L "Установка 3x-ui ${version} (1–3 минуты)" "Installing 3x-ui ${version} (1–3 minutes)")"
    installer=$(mktemp)
    if ! curl -fsSL "https://raw.githubusercontent.com/${XUI_REPO}/${version}/install.sh" -o "$installer"; then
        rm -f "$installer"
        log "$(L "Не удалось скачать установщик 3x-ui ${version}" "Failed to download the 3x-ui installer ${version}")"
        return 1
    fi
    if [[ "$version" == "$XUI_SUPPORTED_VERSION" ]]; then
        sum=$(sha256_of "$installer")
        if [[ "$sum" != "${XUI_SHA256[install.sh]}" ]]; then
            rm -f "$installer"
            log "$(L "SHA-256 установщика 3x-ui ${version} не совпадает с суммой из скрипта, 3x-ui не установлен" "SHA-256 of the 3x-ui installer ${version} does not match the sum in the script, 3x-ui is not installed")"
            log "$(L "  получено: ${sum}" "  received: ${sum}")"
            log "$(L "  ожидалось: ${XUI_SHA256[install.sh]}" "  expected: ${XUI_SHA256[install.sh]}")"
            return 1
        fi
        conf_set XUI_VERIFY_PENDING "$version"
    else
        log_quiet "$(L "Суммы SHA-256 для 3x-ui ${version} в скрипт не зашиты, архив сверяется с файлом .sha256 релиза." "SHA-256 sums for 3x-ui ${version} are not built into the script, the archive is verified against the release .sha256 file.")"
    fi
    bash "$installer" "$version" < /dev/null >> "$LOG_FILE" 2>&1
    rm -f "$installer"
    [[ -x "$XUI_BIN" ]] || {
        log "$(L "Установка 3x-ui завершилась с ошибкой" "3x-ui installation failed")"
        return 1
    }
}

verify_xui_files() {
    local bad
    [[ -n "$(conf_get XUI_VERIFY_PENDING)" ]] || return 0
    bad=$(xui_sum_mismatches)
    if [[ -n "$bad" ]]; then
        systemctl disable x-ui > /dev/null 2>&1 || true
        xui_stop
        log "$(L "SHA-256 файлов 3x-ui $(conf_get XUI_VERIFY_PENDING) не совпадает с суммами из скрипта, x-ui остановлен:" "SHA-256 of 3x-ui $(conf_get XUI_VERIFY_PENDING) files does not match the sums in the script, x-ui is stopped:")"
        log_lines "  " <<< "$bad"
        return 1
    fi
    conf_unset XUI_VERIFY_PENDING
    log "$(L "Файлы 3x-ui сверены с суммами SHA-256 из скрипта" "3x-ui files verified against the SHA-256 sums from the script")"
}

import_db() {
    local src="$1" work report bin newer
    bin=$(xray_bin) || {
        log "$(L "xray-core не найден" "xray-core not found")"
        return 1
    }
    work=$(mktemp -d)
    cp "$src" "${work}/x-ui.db" || {
        rm -rf "$work"
        return 1
    }
    [[ -f "${src}-wal" ]] && cp "${src}-wal" "${work}/x-ui.db-wal"
    [[ -f "${src}-shm" ]] && cp "${src}-shm" "${work}/x-ui.db-shm"
    newer=$(py db-newer "${work}/x-ui.db" "$XUI_DB" 2>&1)
    if [[ -n "$newer" ]]; then
        rm -rf "$work"
        log "$(L "База ${src} создана более новой версией 3x-ui, чем установленная v$("$XUI_BIN" -v 2> /dev/null):" "Database ${src} was created by a newer 3x-ui version than the installed v$("$XUI_BIN" -v 2> /dev/null):")"
        log_lines "  " <<< "$newer"
        log "$(L "Требуется 3x-ui той же версии, что на исходном сервере, или новее" "3x-ui of the same version as on the source server or newer is required")"
        return 1
    fi
    if ! report=$(py import-prepare "${work}/x-ui.db" "$bin" "$(conf_get DOMAIN)" "$REALITY_TARGET"); then
        rm -rf "$work"
        log "$(L "Не удалось подготовить базу: ${report}" "Failed to prepare the database: ${report}")"
        return 1
    fi
    xui_stop
    backup_db_once
    mkdir -p "$(dirname "$XUI_DB")"
    if ! cp "${work}/x-ui.db" "$XUI_DB"; then
        rm -rf "$work"
        log "$(L "Не удалось записать ${XUI_DB}" "Failed to write ${XUI_DB}")"
        return 1
    fi
    rm -f "${XUI_DB}-wal" "${XUI_DB}-shm"
    rm -rf "$work"
    [[ "$(json_get "$report" twofa_reset)" == true ]] && TWO_FA_RESET=1
    conf_unset XHTTP XHTTP_PORT XHTTP_PATH SUB_PATH PANEL_PATH XUI_USERNAME XUI_PASSWORD XUI_PASSWORD_HASH XUI_CREDENTIALS_PENDING \
        HY2 CLIENT_NAME
    IMPORTED_NOW=1
    log "$(L "База перенесена из ${src}" "Database moved from ${src}")"
    [[ "$(json_get "$report" kept)" != "[]" ]] && log "$(L "Ключи Reality сохранены: $(json_get "$report" kept)" "Reality keys kept: $(json_get "$report" kept)")"
    [[ "$(json_get "$report" rekeyed)" != "[]" ]] && log "$(L "Ключи Reality выпущены заново: $(json_get "$report" rekeyed)" "Reality keys reissued: $(json_get "$report" rekeyed)")"
    [[ "$TWO_FA_RESET" -eq 1 ]] && log "$(L "2FA из базы отключена" "2FA from the database is disabled")"
    xui_start
}

apply_xui() {
    if [[ ! -x "$XUI_BIN" ]]; then
        install_xui || return 1
        XUI_INSTALLED_NOW=1
    fi
    verify_xui_files || return 1
    if [[ -n "$IMPORT_DB" ]]; then
        import_db "$IMPORT_DB" || return 1
        IMPORT_DB=""
    fi
    systemctl enable x-ui > /dev/null 2>&1 || true
    systemctl is-active --quiet x-ui || xui_start
}

# NGINX

nginx_site_file() {
    printf '%s/%s' "$NGINX_SITES_AVAILABLE" "$(conf_get CERT_FOLDER)"
}

nginx_site_link() {
    printf '%s/%s' "$NGINX_SITES_ENABLED" "$(conf_get CERT_FOLDER)"
}

www_dir() {
    printf '/var/www/%s' "$(conf_get CERT_FOLDER)"
}

nginx_http2_directive() {
    local version
    version=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    [[ -n "$version" ]] && version_ge "$version" 1.25.1
}

nginx_listen_lines() {
    local suffix="$1" params="proxy_protocol ssl http2"
    nginx_http2_directive && params="proxy_protocol ssl"
    printf '    listen %s:%s %s%s;\n' "$NGINX_ADDR" "$NGINX_PORT" "$params" "$suffix"
    if nginx_http2_directive; then
        printf '    http2 on;\n'
    fi
}

render_nginx_reject() {
    printf 'server {\n'
    nginx_listen_lines " default_server"
    printf '    server_name _;\n'
    printf '    ssl_reject_handshake on;\n'
    printf '}\n'
}

render_nginx_real_ip() {
    printf 'set_real_ip_from %s;\n' "$NGINX_ADDR"
    printf 'real_ip_header proxy_protocol;\n'
}

nginx_foreign_real_ip() {
    local depth f
    {
        printf '1 /etc/nginx/nginx.conf\n'
        nginx_loaded_files | sed 's/^/0 /'
    } | while read -r depth f; do
        [[ "$(readlink -f "$f")" == "$NGINX_REAL_IP_CONF" ]] && continue
        awk -v want="$depth" '
            /^[ \t]*#/ { next }
            depth == want && /^[ \t]*real_ip_header[ \t]/ { found = 1 }
            { depth += gsub(/\{/, "{") - gsub(/\}/, "}") }
            END { exit !found }
        ' "$f" 2> /dev/null && printf '%s\n' "$f"
    done
    return 0
}

render_nginx_xhttp_location() {
    cat << EOF
    location $(conf_get XHTTP_PATH) {
        grpc_pass            grpc://127.0.0.1:$(xhttp_port);
        grpc_set_header      Host              \$host;
        grpc_set_header      X-Real-IP         \$remote_addr;
        grpc_set_header      X-Forwarded-For   \$remote_addr;
        grpc_set_header      X-Forwarded-Proto \$scheme;
        client_max_body_size 0;
        client_body_timeout  1h;
        grpc_read_timeout    1h;
        grpc_send_timeout    1h;
    }

EOF
}

site_stub_includes() {
    awk '
        depth == 1 && /^[ \t]*include[ \t]+(\/etc\/nginx\/)?snippets\/site-[^ \t;]*\.conf[ \t]*;[ \t]*$/ { print }
        { depth += gsub(/\{/, "{") - gsub(/\}/, "}") }
    ' "$(nginx_site_file)" 2> /dev/null
}

render_nginx_site() {
    local domain folder stub
    domain=$(conf_get DOMAIN)
    folder=$(conf_get CERT_FOLDER)
    stub=$(site_stub_includes)
    printf 'server {\n'
    nginx_listen_lines ""
    [[ "$(hy2_port_answer)" != 0 ]] && printf '%s\n' "$ALT_SVC_LINE"
    cat << EOF

    server_name ${domain};

    ssl_certificate     /etc/ssl/${folder}/fullchain.pem;
    ssl_certificate_key /etc/ssl/${folder}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    root  /var/www/${folder};
    index index.html;

EOF
    if xhttp_enabled; then
        render_nginx_xhttp_location
    fi
    cat << EOF
    location $(conf_get SUB_PATH) {
        proxy_pass         http://127.0.0.1:${SUB_PORT};
        proxy_set_header   Host      \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        add_header         socks-auth-mode auto;
        add_header         http-auth-mode  auto;
EOF
    [[ "$(hy2_port_answer)" != 0 ]] && printf '    %s\n' "$ALT_SVC_LINE"
    cat << EOF
    }

    location = $(conf_get PANEL_PATH)/sponsors {
        default_type application/json;
        return 200 '${SPONSORS_EMPTY}';
    }

    location ^~ $(conf_get PANEL_PATH)/sponsors/ {
        return 404;
    }

    location $(conf_get PANEL_PATH)/ {
        proxy_pass         http://127.0.0.1:${PANEL_PORT};
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
        include            ${NGINX_PANEL_SNIPPETS};
    }

EOF
    if [[ -n "$stub" ]]; then
        printf '%s\n}\n' "$stub"
        return 0
    fi
    cat << EOF
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
}

nginx_loaded_files() {
    local f
    for f in "$NGINX_SITES_ENABLED"/* "$NGINX_CONF_D"/*.conf; do
        [[ -f "$f" ]] && printf '%s\n' "$f"
    done
    return 0
}

nginx_foreign_listeners() {
    local port="$1" f real
    shift
    while IFS= read -r f; do
        real=$(readlink -f "$f")
        [[ " $* " == *" ${real} "* ]] && continue
        [[ "$f" == "${NGINX_SITES_ENABLED}/default" ]] && continue
        [[ "$port" == "$HTTP_PORT" ]] && other_domain_site "$f" && continue
        if grep -E '^[[:space:]]*listen[[:space:]]' "$f" | grep -vE '127\.0\.0\.1|\[::1\]' \
            | grep -qE "[[:space:]:]${port}([[:space:];]|$)"; then
            printf '%s\n' "$f"
        fi
    done < <(nginx_loaded_files)
}

nginx_foreign_public_listeners() {
    nginx_foreign_listeners "$PUBLIC_TLS_PORT" "$(nginx_site_file)" "$NGINX_REJECT_CONF"
}

nginx_stale_rejects() {
    local f
    while IFS= read -r f; do
        [[ "$(readlink -f "$f")" == "$NGINX_REJECT_CONF" ]] && continue
        grep -qE '^[[:space:]]*ssl_reject_handshake[[:space:]]+on[[:space:]]*;' "$f" || continue
        grep -E '^[[:space:]]*listen[[:space:]]' "$f" | grep -F "${REALITY_TARGET}" | grep -q 'default_server' || continue
        printf '%s\n' "$f"
    done < <(nginx_loaded_files)
}

nginx_remove_stale_rejects() {
    local f backup
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        if [[ -L "$f" ]]; then
            rm -f "$f"
            log "$(L "отключён устаревший антискан ${f}" "disabled the outdated anti-scan ${f}")"
            continue
        fi
        backup="/root/$(basename "$f").bak-$(date +%F-%H%M%S)"
        mv "$f" "$backup" && log "$(L "устаревший антискан ${f} перенесён в ${backup}" "outdated anti-scan ${f} moved to ${backup}")"
    done < <(nginx_stale_rejects)
}

stub_ready() {
    local dir
    [[ -n "$(site_stub_includes)" ]] && return 0
    dir=$(www_dir)
    [[ -s "${dir}/index.html" ]] && compgen -G "${dir}/favicon.*" > /dev/null
}

prepare_stub_site() {
    local dir favicon="" candidate
    dir=$(www_dir)
    stub_ready && return 0
    mkdir -p "$dir"
    if [[ ! -s "${dir}/index.html" ]] && ! recommended; then
        printf '%s\n' "$(L "${INDENT}Папка сайта-заглушки: ${dir}" "${INDENT}Decoy site folder: ${dir}")"
        printf '%s\n' "$(L "${INDENT}Можно положить туда index.html и фавиконку (favicon.ico, .svg или .png)." "${INDENT}index.html and a favicon (favicon.ico, .svg or .png) can be placed there.")"
        prompted
        read -r -p "$(L "${INDENT}Enter — продолжить: " "${INDENT}Enter — continue: ")" || die "$(L "Ввод прерван." "Input interrupted.")"
    fi
    for candidate in favicon.ico favicon.svg favicon.png; do
        if [[ -s "${dir}/${candidate}" ]]; then
            favicon="$candidate"
            break
        fi
    done
    if [[ -z "$favicon" ]]; then
        favicon="favicon.ico"
        base64 -d > "${dir}/favicon.ico" << 'B64EOF'
AAABAAIAEBAAAAAAIAAtAQAAJgAAACAgAAAAACAApQAAAFMBAACJUE5HDQoaCgAAAA1JSERSAAAAEAAAABAIBgAAAB/z/2EAAAD0SURBVHic7ZMxTsNAEEX/zO46WPGZaAM0uYVBaVAOgCLEARANSnKLVJCWMzk4eHb3U6SIIkVGVlq+NOV7+lN8qetVWK/v7eHx6XY8rq5/2n0i6HAmAkmj8srtds3X8u3lo65XQQBgNl/chFBsfAgFcz7HHiWqiGadWTd9f33+lNl8cedd2BDZ5ZwiKdIrEFLVeYGmmGzqRWQSiuDb9ttEJPTjh0dSSlaWo5D2caIgGjIT+Bs97ZEJolEAOgw+SgCoDgdP8y84CDJADkdJAFkhqERUhklIERUIKiW5tc6ic84DNBKx7wCac85bZ5Hk9vIxXTrnX31kpEilEQNGAAAAAElFTkSuQmCCiVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAbElEQVR4nO3XsQ0AIQwDwLzXpfsJmOA75oWK4hMQVUxjl4DwSaTB7HKe1WJ5a88oa18NfWCV7+7G6UA2ArsNFgLsco8IM8COAAIIIIAAAggggAACwGz9Y8nO7IRfYJb/ACyE7wgzkIm48dTHDMFSJDwZtkmoAAAAAElFTkSuQmCC
B64EOF
        log "$(L "фавиконка не найдена, установлена стандартная" "favicon not found, the default one is installed")"
    fi
    if [[ ! -s "${dir}/index.html" ]]; then
        cat > "${dir}/index.html" << EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>403 Forbidden</title>
<link rel="icon" href="/${favicon}">
</head>
<body style="font-family: sans-serif; text-align:center; margin-top:15%; color:#333;">
<h1>403 Forbidden</h1>
<p>nginx</p>
</body>
</html>
EOF
        log "$(L "index.html не найден, установлена страница 403 Forbidden" "index.html not found, a 403 Forbidden page is installed")"
    fi
    stub_ready
}

install_nginx() {
    command -v nginx > /dev/null 2>&1 && return 0
    log "$(L "Установка nginx" "Installing nginx")"
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update -qq >> "$LOG_FILE" 2>&1 || ! apt-get install -y -qq nginx >> "$LOG_FILE" 2>&1; then
        log "$(L "Не удалось установить nginx" "Failed to install nginx")"
        return 1
    fi
}

nginx_backup_once() {
    [[ -n "$NGINX_BACKUP" || ! -d /etc/nginx ]] && return 0
    NGINX_BACKUP="/root/nginx-$(date +%F-%H%M%S).tgz"
    tar czf "$NGINX_BACKUP" -C / etc/nginx 2> /dev/null || NGINX_BACKUP=""
    [[ -n "$NGINX_BACKUP" ]] && log "$(L "Резервная копия /etc/nginx: ${NGINX_BACKUP}" "/etc/nginx backup: ${NGINX_BACKUP}")"
}

nginx_reload() {
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx > /dev/null 2>&1 && return 0
    fi
    systemctl restart nginx > /dev/null 2>&1
}

nginx_managed_files() {
    printf '%s\n' "$(nginx_site_file)" "$(nginx_site_link)" "$NGINX_REJECT_CONF" "$NGINX_REAL_IP_CONF" "$NGINX_HTTP_REJECT_CONF" \
        "$(nginx_http_site_file)"
}

nginx_apply() {
    local writer="$1" listening="$2" snapshot f
    local -A existed=()
    nginx_backup_once
    snapshot=$(mktemp)
    tar czf "$snapshot" -C / etc/nginx 2> /dev/null
    while IFS= read -r f; do
        [[ -e "$f" || -L "$f" ]] && existed[$f]=1
    done < <(nginx_managed_files)
    mkdir -p "$NGINX_SITES_AVAILABLE" "$NGINX_SITES_ENABLED" "$NGINX_CONF_D"
    "$writer"
    if ! nginx -t >> "$LOG_FILE" 2>&1; then
        log "$(L "nginx -t: ошибка конфигурации, изменения отменены:" "nginx -t: configuration error, changes reverted:")"
        nginx -t 2>&1 | tail -n 5 | log_lines "  "
        while IFS= read -r f; do
            [[ -n "${existed[$f]:-}" ]] || rm -f "$f"
        done < <(nginx_managed_files)
        tar xzf "$snapshot" -C / 2> /dev/null
        rm -f "$snapshot"
        return 1
    fi
    rm -f "$snapshot"
    if ! nginx_reload; then
        log "$(L "nginx не перезагрузился, журнал nginx записан в ${LOG_FILE}" "nginx did not reload, the nginx journal is saved to ${LOG_FILE}")"
        journal_tail nginx
        return 1
    fi
    if ! wait_for 15 "$listening"; then
        systemctl restart nginx > /dev/null 2>&1
        if ! wait_for 10 "$listening"; then
            log "$(L "nginx слушает: $(nginx_addresses | tr '\n' ' ')ожидается: $(nginx_expected_text); адреса задают другие конфиги в ${NGINX_SITES_ENABLED} или ${NGINX_CONF_D}" "nginx listens on: $(nginx_addresses | tr '\n' ' ')expected: $(nginx_expected_text); the addresses come from other configs in ${NGINX_SITES_ENABLED} or ${NGINX_CONF_D}")"
            return 1
        fi
    fi
}

nginx_write_tls_files() {
    local site content
    site=$(nginx_site_file)
    nginx_remove_stale_rejects
    content=$(render_nginx_site)
    printf '%s\n' "$content" > "$site"
    render_nginx_reject > "$NGINX_REJECT_CONF"
    render_nginx_real_ip > "$NGINX_REAL_IP_CONF"
    ln -sfn "$site" "$(nginx_site_link)"
    rm -f "${NGINX_SITES_ENABLED}/default"
}

nginx_write_config() {
    nginx_apply nginx_write_tls_files nginx_listens_expected
}

alt_svc_count() {
    grep -ciE '^[[:space:]]*add_header[[:space:]]+Alt-Svc[[:space:]]' "$1" 2> /dev/null
}

check_nginx() {
    local rc=0 site addr expected has_local=0 header alt_svc=0
    if ! command -v nginx > /dev/null 2>&1; then
        mismatch "$(L "nginx не установлен" "nginx is not installed")"
        return 1
    fi
    site=$(nginx_site_file)
    render_nginx_site | cmp -s - "$site" || {
        template_differs "$(L "конфигурация сайта" "site configuration")" "$site"
        rc=1
    }
    [[ "$(hy2_port_answer)" != 0 ]] && alt_svc=2
    if [[ -e "$site" ]]; then
        if [[ "$(alt_svc_count "$site")" != "$alt_svc" ]]; then
            mismatch "$(L "Alt-Svc в ${site}: строк $(alt_svc_count "$site"), нужно ${alt_svc}" "Alt-Svc in ${site}: $(alt_svc_count "$site") lines, expected ${alt_svc}")"
            rc=1
        fi
        for header in socks-auth-mode http-auth-mode; do
            grep -qiE "^[[:space:]]*add_header[[:space:]]+${header}[[:space:]]+auto[[:space:]]*;" "$site" || {
                mismatch "$(L "в ${site} нет заголовка ${header} в location подписки" "${site} has no ${header} header in the subscription location")"
                rc=1
            }
        done
    fi
    [[ "$(readlink -f "$(nginx_site_link)")" == "$site" ]] || {
        mismatch_minor "$(L "сайт ${site} не подключён в ${NGINX_SITES_ENABLED}" "site ${site} is not enabled in ${NGINX_SITES_ENABLED}")"
        rc=1
    }
    render_nginx_reject | cmp -s - "$NGINX_REJECT_CONF" || {
        template_differs "$(L "антискан" "anti-scan")" "$NGINX_REJECT_CONF"
        rc=1
    }
    render_nginx_real_ip | cmp -s - "$NGINX_REAL_IP_CONF" || {
        template_differs "$(L "конфигурация real_ip" "real_ip configuration")" "$NGINX_REAL_IP_CONF"
        rc=1
    }
    [[ -n "$(nginx_foreign_real_ip)" ]] && {
        mismatch "$(L "real_ip_header задан в других конфигах nginx: $(nginx_foreign_real_ip | tr '\n' ' ')" "real_ip_header is set in other nginx configs: $(nginx_foreign_real_ip | tr '\n' ' ')")"
        rc=1
    }
    [[ -n "$(nginx_stale_rejects)" ]] && {
        mismatch "$(L "устаревший антискан на ${REALITY_TARGET}: $(nginx_stale_rejects | tr '\n' ' ')" "outdated anti-scan on ${REALITY_TARGET}: $(nginx_stale_rejects | tr '\n' ' ')")"
        rc=1
    }
    [[ -e "${NGINX_SITES_ENABLED}/default" ]] && {
        mismatch "$(L "подключён сайт default" "the default site is enabled")"
        rc=1
    }
    stub_ready || {
        mismatch_minor "$(L "нет сайта-заглушки в $(www_dir)" "no decoy site in $(www_dir)")"
        rc=1
    }
    if ! systemctl is-active --quiet nginx; then
        mismatch "$(L "nginx не запущен" "nginx is not running")"
        return 1
    fi
    expected=" $(nginx_expected_addresses | tr '\n' ' ') "
    while IFS= read -r addr; do
        [[ "$addr" == "$REALITY_TARGET" ]] && has_local=1
        [[ "$expected" == *" ${addr} "* ]] && continue
        mismatch "$(L "nginx слушает лишний адрес ${addr}" "nginx listens on an extra address ${addr}")"
        rc=1
    done < <(nginx_addresses)
    [[ "$has_local" -eq 1 ]] || {
        mismatch "$(L "nginx не слушает ${REALITY_TARGET}" "nginx does not listen on ${REALITY_TARGET}")"
        rc=1
    }
    dest_ready "$(conf_get DOMAIN)" || {
        mismatch "$(L "${REALITY_TARGET} не годится в target Reality (нужны PROXY protocol, TLS 1.3, h2, свой сертификат, отказ без SNI)" "${REALITY_TARGET} is not suitable as the Reality target (PROXY protocol, TLS 1.3, h2, own certificate and rejection without SNI are required)")"
        rc=1
    }
    return "$rc"
}

apply_nginx() {
    local foreign
    install_nginx || return 1
    prepare_stub_site || {
        log "$(L "Не удалось подготовить сайт-заглушку в $(www_dir)" "Failed to prepare the decoy site in $(www_dir)")"
        return 1
    }
    foreign=$(nginx_foreign_public_listeners)
    if [[ -n "$foreign" ]]; then
        log "$(L "Публичный порт ${PUBLIC_TLS_PORT} заняли другие конфиги nginx:" "Public port ${PUBLIC_TLS_PORT} is taken by other nginx configs:")"
        log_lines "  " <<< "$foreign"
        return 1
    fi
    foreign=$(nginx_foreign_real_ip)
    if [[ -n "$foreign" ]]; then
        log "$(L "Директива real_ip_header уже задана в других конфигах nginx:" "The real_ip_header directive is already set in other nginx configs:")"
        log_lines "  " <<< "$foreign"
        return 1
    fi
    nginx_write_config || return 1
    sync_reality_xver
}

sync_reality_xver() {
    local report
    [[ -s "$XUI_DB" ]] || return 0
    report=$(py reality-xver plan "$XUI_DB" "$REALITY_TARGET") || return 0
    [[ -n "$(json_lines "$report" changes)" ]] || return 0
    xui_stop
    backup_db_once
    if ! report=$(py reality-xver set "$XUI_DB" "$REALITY_TARGET"); then
        log "$(L "Не удалось изменить xver у Reality: ${report}" "Failed to change the Reality xver: ${report}")"
        xui_start
        return 1
    fi
    json_lines "$report" changes | log_lines ""
    xui_start
}

release_public_443() {
    local foreign
    foreign=$(nginx_foreign_public_listeners)
    if [[ -n "$foreign" ]]; then
        log "$(L "Порт ${PUBLIC_TLS_PORT} держат другие конфиги nginx:" "Port ${PUBLIC_TLS_PORT} is held by other nginx configs:")"
        log_lines "  " <<< "$foreign"
        return 1
    fi
    if nginx_holds_public_443; then
        nginx_write_config || return 1
    fi
    if ! wait_for 10 public_443_free; then
        log "$(L "Порт ${PUBLIC_TLS_PORT}/tcp занят:" "Port ${PUBLIC_TLS_PORT}/tcp is in use:")"
        tcp_listeners "$PUBLIC_TLS_PORT" | log_lines "  "
        return 1
    fi
}

# ПАНЕЛЬ 3X-UI

panel_settings_wanted() {
    printf '%s\n' "webPort=${PANEL_PORT}" "webListen=${NGINX_ADDR}" "webBasePath=$(conf_get PANEL_PATH)/" \
        "webCertFile=" "webKeyFile="
}

check_panel() {
    local rc=0 diff code wanted
    systemctl is-active --quiet x-ui || {
        mismatch "$(L "x-ui не запущен" "x-ui is not running")"
        return 1
    }
    mapfile -t wanted < <(panel_settings_wanted)
    diff=$(py settings-diff "$XUI_DB" "${wanted[@]}")
    if [[ -n "$diff" ]]; then
        mismatch_lines <<< "$diff"
        rc=1
    fi
    if [[ -n "$(conf_get XUI_CREDENTIALS_PENDING)" ]]; then
        mismatch_minor "$(L "новые логин и пароль панели ещё не применены" "the new panel username and password are not applied yet")"
        rc=1
    fi
    if [[ -e "$XUI_INSTALL_RESULT" ]]; then
        mismatch_minor "$(L "остался ${XUI_INSTALL_RESULT}" "${XUI_INSTALL_RESULT} is left over")"
        rc=1
    fi
    if fresh_xui_token && [[ "$(py api-token-exists "$XUI_DB" install)" == yes ]]; then
        mismatch_minor "$(L "остался API-токен установщика 3x-ui" "the 3x-ui installer API token is left over")"
        rc=1
    fi
    tcp_listening "$NGINX_ADDR" "$PANEL_PORT" || {
        mismatch "$(L "панель не слушает ${NGINX_ADDR}:${PANEL_PORT}" "the panel does not listen on ${NGINX_ADDR}:${PANEL_PORT}")"
        rc=1
    }
    code=$(http_code "https://$(conf_get DOMAIN):${NGINX_PORT}$(conf_get PANEL_PATH)/" "$(conf_get DOMAIN):${NGINX_PORT}:${NGINX_ADDR}" \
        --haproxy-protocol)
    [[ "$code" =~ ^(200|301|302|307|308)$ ]] || {
        mismatch "$(L "панель через nginx отвечает кодом ${code}" "the panel responds through nginx with code ${code}")"
        rc=1
    }
    return "$rc"
}

fresh_xui_token() {
    [[ "$XUI_INSTALLED_NOW" -eq 1 && "$IMPORTED_NOW" -eq 0 ]]
}

apply_panel() {
    local args=(-port "$PANEL_PORT" -listenIP "$NGINX_ADDR" -webBasePath "$(conf_get PANEL_PATH)/")
    if [[ -n "$(conf_get XUI_CREDENTIALS_PENDING)" ]]; then
        args+=(-username "$(conf_get XUI_USERNAME)" -password "$(conf_get XUI_PASSWORD)")
    fi
    xui_stop
    backup_db_once
    if ! "$XUI_BIN" setting "${args[@]}" >> "$LOG_FILE" 2>&1; then
        log "$(L "x-ui setting завершился с ошибкой" "x-ui setting failed")"
        xui_start
        return 1
    fi
    if ! py settings-set "$XUI_DB" "webCertFile=" "webKeyFile="; then
        xui_start
        return 1
    fi
    if fresh_xui_token && ! py api-token-delete "$XUI_DB" install; then
        xui_start
        return 1
    fi
    if fresh_xui_token && ! py settings-set "$XUI_DB" "remarkTemplate=${REMARK_TEMPLATE}"; then
        xui_start
        return 1
    fi
    rm -f "$XUI_INSTALL_RESULT"
    if [[ -n "$(conf_get XUI_CREDENTIALS_PENDING)" ]]; then
        conf_set XUI_PASSWORD_HASH "$(py panel-user "$XUI_DB" password)"
        conf_unset XUI_CREDENTIALS_PENDING
    fi
    xui_start || return 1
    wait_for 15 tcp_listening "$NGINX_ADDR" "$PANEL_PORT"
}

# ПОДПИСКА

subscription_settings_wanted() {
    printf '%s\n' "subEnable=true" "subListen=${NGINX_ADDR}" "subPort=${SUB_PORT}" \
        "subPath=$(conf_get SUB_PATH)/" "subURI=https://$(conf_get DOMAIN)$(conf_get SUB_PATH)/" \
        "subDomain=" "subCertFile=" "subKeyFile="
}

check_subscription() {
    local rc=0 diff wanted
    mapfile -t wanted < <(subscription_settings_wanted)
    diff=$(py settings-diff "$XUI_DB" "${wanted[@]}")
    if [[ -n "$diff" ]]; then
        mismatch_lines <<< "$diff"
        rc=1
    fi
    tcp_listening "$NGINX_ADDR" "$SUB_PORT" || {
        mismatch "$(L "сервер подписки не слушает ${NGINX_ADDR}:${SUB_PORT}" "the subscription server does not listen on ${NGINX_ADDR}:${SUB_PORT}")"
        rc=1
    }
    return "$rc"
}

apply_subscription() {
    local wanted
    mapfile -t wanted < <(subscription_settings_wanted)
    xui_stop
    backup_db_once
    py settings-set "$XUI_DB" "${wanted[@]}" || {
        xui_start
        return 1
    }
    xui_start || return 1
    wait_for 15 tcp_listening "$NGINX_ADDR" "$SUB_PORT"
}

# ИНБАУНДЫ

inbounds_report() {
    py inbounds "$1" "$XUI_DB" "$(conf_get DOMAIN)" "$(conf_get CERT_FOLDER)" "$(xhttp_path_answer)" \
        "$(hy2_port_answer)" "$REALITY_TARGET" "$(xhttp_port)"
}

runtime_inbounds_ok() {
    local summary hy2_port port rc=0 quiet="${1:-0}"
    hy2_port=$(hy2_port_answer)
    if [[ ! -s "$XRAY_CONFIG" ]]; then
        [[ "$quiet" -eq 1 ]] || mismatch "$(L "нет ${XRAY_CONFIG}" "no ${XRAY_CONFIG}")"
        return 1
    fi
    summary=$(py config-summary "$XRAY_CONFIG") || return 1
    if [[ "$(json_get "$summary" reality.port)" != "$PUBLIC_TLS_PORT" || "$(json_get "$summary" reality.target)" != "$REALITY_TARGET" ]]; then
        [[ "$quiet" -eq 1 ]] || mismatch "$(L "config.json: Reality не на ${PUBLIC_TLS_PORT} или target не ${REALITY_TARGET}" "config.json: Reality is not on ${PUBLIC_TLS_PORT} or the target is not ${REALITY_TARGET}")"
        rc=1
    fi
    if [[ "$(json_get "$summary" reality.limit_fallback)" != "[]" ]]; then
        [[ "$quiet" -eq 1 ]] || mismatch "$(L "config.json: в Reality ненулевые limitFallback" "config.json: Reality has non-zero limitFallback")"
        rc=1
    fi
    xray_holds_443 || {
        [[ "$quiet" -eq 1 ]] || mismatch "$(L "Xray не слушает ${PUBLIC_TLS_PORT}/tcp" "Xray does not listen on ${PUBLIC_TLS_PORT}/tcp")"
        rc=1
    }
    if xhttp_enabled && ! tcp_listening "$NGINX_ADDR" "$(xhttp_port)"; then
        [[ "$quiet" -eq 1 ]] || mismatch "$(L "XHTTP не слушает ${NGINX_ADDR}:$(xhttp_port)" "XHTTP does not listen on ${NGINX_ADDR}:$(xhttp_port)")"
        rc=1
    fi
    if [[ "$hy2_port" != 0 ]]; then
        if [[ "$(json_get "$summary" hy2.port)" != "$hy2_port" ]] || ! xray_holds_udp "$hy2_port"; then
            [[ "$quiet" -eq 1 ]] || mismatch "$(L "Hysteria2 не слушает UDP/${hy2_port}" "Hysteria2 does not listen on UDP/${hy2_port}")"
            rc=1
        fi
        if [[ "$(json_get "$summary" hy2.plain)" != true || "$(json_get "$summary" hy2.reject_sni)" != true ]]; then
            [[ "$quiet" -eq 1 ]] || mismatch "$(L "config.json: у Hysteria2 есть маски или выключен rejectUnknownSni" "config.json: Hysteria2 has masks or rejectUnknownSni is off")"
            rc=1
        fi
    fi
    for port in $STALE_PORTS; do
        [[ "$port" == */udp ]] && xray_holds_udp "${port%/udp}" && {
            [[ "$quiet" -eq 1 ]] || mismatch "$(L "UDP/${port%/udp} всё ещё слушается после переноса Hysteria2" "UDP/${port%/udp} is still listening after moving Hysteria2")"
            rc=1
        }
    done
    return "$rc"
}

check_inbounds() {
    local report rc=0 line
    if ! report=$(inbounds_report plan); then
        mismatch "$(L "не удалось прочитать инбаунды: ${report}" "failed to read inbounds: ${report}")"
        return 1
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        mismatch "$line"
        rc=1
    done < <(json_lines "$report" fatal
        json_lines "$report" problems)
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        case "$line" in
            reality) mismatch "$(L "нет инбаунда VLESS Reality" "no VLESS Reality inbound")" ;;
            xhttp) mismatch "$(L "нет инбаунда VLESS XHTTP" "no VLESS XHTTP inbound")" ;;
            hy2) mismatch "$(L "нет инбаунда Hysteria2" "no Hysteria2 inbound")" ;;
        esac
        rc=1
    done < <(json_lines "$report" missing)
    json_lines "$report" warnings | warn_lines
    [[ "$rc" -eq 0 ]] || return 1
    runtime_inbounds_ok 0
}

fix_inbounds() {
    local report target port
    xui_stop
    backup_db_once
    if ! report=$(inbounds_report main); then
        log "$(L "Не удалось изменить инбаунды: ${report}" "Failed to change inbounds: ${report}")"
        xui_start
        return 1
    fi
    json_lines "$report" changes | while IFS= read -r line; do log_quiet "  ${line}"; done
    log_quiet "$report"
    STALE_PORTS+=" $(json_lines "$report" stale_ports | tr '\n' ' ')"
    report=$(inbounds_report plan)
    target=$(json_get "$report" reality.target)
    port=$(json_get "$report" reality.port)
    if [[ -n "$target" && "$target" != "$REALITY_TARGET" ]]; then
        log "$(L "target Reality после записи: ${target}, ожидался ${REALITY_TARGET}; остановка, возможна петля" "Reality target after writing: ${target}, expected ${REALITY_TARGET}; stopping, a loop is possible")"
        xui_start
        return 1
    fi
    if [[ -n "$port" && "$port" != "$PUBLIC_TLS_PORT" ]]; then
        if ! release_public_443; then
            xui_start
            return 1
        fi
        if ! report=$(inbounds_report port); then
            log "$(L "Не удалось перевести Reality на ${PUBLIC_TLS_PORT}: ${report}" "Failed to move Reality to ${PUBLIC_TLS_PORT}: ${report}")"
            xui_start
            return 1
        fi
        json_lines "$report" changes | while IFS= read -r line; do log_quiet "  ${line}"; done
        STALE_PORTS+=" $(json_lines "$report" stale_ports | tr '\n' ' ')"
        log_quiet "$report"
    fi
    xui_start
}

create_missing_inbounds() {
    local report missing token
    report=$(inbounds_report plan) || return 1
    missing=$(json_lines "$report" missing | tr '\n' ' ')
    [[ -z "${missing// /}" ]] && return 0
    if [[ " $missing " == *" reality "* ]] && ! public_443_free; then
        release_public_443 || return 1
    fi
    systemctl is-active --quiet x-ui || xui_start || return 1
    token=$(api_token) || return 1
    if ! report=$(py create-missing "$(api_base)" "$token" "$XUI_DB" "$(xray_bin)" "$(conf_get DOMAIN)" \
        "$(conf_get CERT_FOLDER)" "$(xhttp_path_answer)" "$(hy2_port_answer)" "$REALITY_TARGET" \
        "$(conf_get CLIENT_NAME)" "$(xhttp_port)"); then
        log "$(L "Не удалось создать инбаунды: ${report}" "Failed to create inbounds: ${report}")"
        return 1
    fi
    log_quiet "$report"
    json_lines "$report" created | while IFS= read -r line; do
        log "$(L "создан инбаунд $(json_get "$line" kind) $(json_get "$line" tag), порт $(json_get "$line" port)" "created inbound $(json_get "$line" kind) $(json_get "$line" tag), port $(json_get "$line" port)")"
    done
    if [[ -n "$(json_get "$report" new_client)" ]]; then
        log "$(L "клиент $(json_get "$report" new_client.email) добавлен во все инбаунды" "client $(json_get "$report" new_client.email) added to all inbounds")"
    fi
}

apply_inbounds() {
    local report fatal others
    report=$(inbounds_report plan) || {
        log "$report"
        return 1
    }
    fatal=$(json_lines "$report" fatal)
    if [[ -n "$fatal" ]]; then
        log "$(L "Требуется ручное решение:" "Manual action required:")"
        log_lines "  " <<< "$fatal"
        return 1
    fi
    others=$(udp_listeners "$HY2_PORT" | grep -v '"xray')
    if [[ "$(hy2_port_answer)" != 0 && -n "$others" ]]; then
        log "$(L "Порт ${HY2_PORT}/udp для Hysteria2 занят другим процессом:" "Port ${HY2_PORT}/udp for Hysteria2 is used by another process:")"
        log_lines "  " <<< "$others"
        return 1
    fi
    if [[ "$(hy2_port_answer)" != 0 ]] && ufw_present && ! ufw_allows "${HY2_PORT}/udp"; then
        ufw allow "${HY2_PORT}/udp" comment "$SCRIPT_NAME" > /dev/null 2>&1 && log "$(L "ufw: добавлено ${HY2_PORT}/udp" "ufw: added ${HY2_PORT}/udp")"
    fi
    if [[ -n "$(json_lines "$report" problems)" ]]; then
        fix_inbounds || return 1
    fi
    create_missing_inbounds || return 1
    xui_restart || return 1
    wait_for 20 runtime_inbounds_ok 1 && return 0
    runtime_inbounds_ok 0
    for port in $STALE_PORTS; do
        [[ "$port" == */udp ]] && log "$(L "правило ufw ${port} оставлено" "ufw rule ${port} is kept")"
    done
    return 1
}

# ХОСТЫ

hosts_report() {
    py hosts "$1" "$XUI_DB" "$(conf_get DOMAIN)" "$(hy2_port_answer)"
}

check_hosts() {
    local report rc=0 line
    report=$(hosts_report plan) || {
        mismatch "$(L "не удалось прочитать Хосты: ${report}" "failed to read Hosts: ${report}")"
        return 1
    }
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        mismatch "$line"
        rc=1
    done < <(json_lines "$report" problems)
    [[ "$CHECK_ONLY" -eq 1 ]] && return "$rc"
    report=$(inbounds_report plan)
    if [[ -n "$(json_lines "$report" problems)" ]]; then
        mismatch "$(L "инбаунды изменились после записи Хостов" "inbounds changed after writing Hosts")"
        json_lines "$report" problems | mismatch_lines
        rc=1
    fi
    return "$rc"
}

apply_hosts() {
    local report missing token
    report=$(hosts_report plan) || return 1
    if [[ "$(json_get "$report" fixable)" != 0 ]]; then
        xui_stop
        backup_db_once
        report=$(hosts_report fix) || {
            log "$(L "Не удалось изменить Хосты: ${report}" "Failed to change Hosts: ${report}")"
            xui_start
            return 1
        }
        json_lines "$report" changes | while IFS= read -r line; do log_quiet "  ${line}"; done
        xui_start || return 1
        report=$(hosts_report plan) || return 1
    fi
    missing=$(json_get "$report" missing)
    if [[ -n "$missing" && "$missing" != "[]" ]]; then
        token=$(api_token) || return 1
        report=$(py hosts-add "$(api_base)" "$token" "$missing") || {
            log "$(L "Не удалось добавить Хосты: ${report}" "Failed to add Hosts: ${report}")"
            return 1
        }
        json_lines "$report" added | log_lines "$(L "добавлен Хост " "added Host ")"
    fi
    if [[ -n "$(json_lines "$(inbounds_report plan)" problems)" ]]; then
        log "$(L "После записи Хостов изменился инбаунд, настройки инбаунда возвращены" "An inbound changed after writing Hosts, the inbound settings are restored")"
        fix_inbounds || return 1
    fi
    xui_restart
}

# МАРШРУТИЗАЦИЯ

check_routing() {
    local summary rc=0
    if [[ ! -s "$XRAY_CONFIG" ]]; then
        mismatch "$(L "нет ${XRAY_CONFIG}" "no ${XRAY_CONFIG}")"
        return 1
    fi
    summary=$(py config-summary "$XRAY_CONFIG") || return 1
    if [[ -z "$(json_get "$summary" reality.tag)" ]] || { xhttp_enabled && [[ -z "$(json_get "$summary" xhttp.tag)" ]]; }; then
        mismatch "$(L "в config.json нет Reality$(xhttp_enabled && echo " или XHTTP")" "config.json has no Reality$(xhttp_enabled && echo " or XHTTP")")"
        return 1
    fi
    if [[ "$(json_get "$summary" block_missing)" != "[]" ]]; then
        mismatch "$(L "нет в правилах blocked: $(block_missing_text "$summary")" "missing from blocked rules: $(block_missing_text "$summary")")"
        rc=1
    fi
    [[ "$(json_get "$summary" udp443_ok)" == true ]] || {
        mismatch "$(L "правило UDP/443 → blocked: $(json_get "$summary" udp443_actual), нужно $(json_get "$summary" udp443_expected)" "UDP/443 → blocked rule: $(json_get "$summary" udp443_actual), expected $(json_get "$summary" udp443_expected)")"
        rc=1
    }
    if warp_enabled && [[ "$(json_get "$summary" warp.ok)" != true ]]; then
        warp_problems "$summary" | mismatch_lines
        rc=1
    fi
    return "$rc"
}

warp_problems() {
    local rules expected
    rules=$(json_get "$1" warp.rules)
    expected=$(json_get "$1" warp.expected)
    [[ "$rules" == "[]" ]] || rules="${rules:1:-1}"
    if [[ "$(json_get "$1" warp.outbound)" != true ]]; then
        printf '%s\n' "$(L "нет исходящего warp" "no warp outbound")"
    fi
    if [[ "$rules" != "$expected" ]]; then
        printf '%s\n' "$(L "правило → warp: ${rules}, нужно ${expected}" "→ warp rule: ${rules}, expected ${expected}")"
    elif [[ "$(json_get "$1" warp.last)" != true ]]; then
        printf '%s\n' "$(L "правило → warp стоит не последним" "the → warp rule is not the last one")"
    fi
}

block_missing_text() {
    json_lines "$1" block_missing | paste -sd ' ' -
}

apply_routing() {
    local summary token report reality xhttp hy2
    summary=$(py config-summary "$XRAY_CONFIG") || return 1
    reality=$(json_get "$summary" reality.tag)
    xhttp=$(json_get "$summary" xhttp.tag)
    hy2=$(json_get "$summary" hy2.tag)
    token=$(api_token) || return 1
    warp_enabled && log "$(L "Cloudflare WARP: проверка исходящего warp" "Cloudflare WARP: testing the warp outbound")"
    report=$(py routing-apply "$(api_base)" "$token" "$reality" "$xhttp" "$XRAY_CONFIG" "$(xray_bin)" "$hy2" "$(conf_get WARP)") || {
        log "$(L "Не удалось изменить маршрутизацию: ${report}" "Failed to change routing: ${report}")"
        return 1
    }
    json_lines "$report" changes | while IFS= read -r line; do log_quiet "  ${line}"; done
    xui_restart || return 1
    token=$(api_token) || return 1
    report=$(py routing-test "$(api_base)" "$token" "$reality" "$xhttp" "$hy2" "$(conf_get WARP)") || {
        log "$(L "Проверка routeTest не пройдена: $(json_get "$report" failed)" "routeTest check failed: $(json_get "$report" failed)")"
        return 1
    }
    log "$(L "routeTest: правила срабатывают" "routeTest: the rules match")"
}

# UFW

ufw_present() {
    command -v ufw > /dev/null 2>&1
}

ufw_target_rules() {
    local port
    while IFS= read -r port; do
        printf '%s/tcp\n' "$port"
    done < <(ssh_ports)
    printf '%s/tcp\n' "$HTTP_PORT" "$PUBLIC_TLS_PORT"
    [[ "$(hy2_port_answer)" != 0 ]] && printf '%s/udp\n' "$(hy2_port_answer)"
    return 0
}

ufw_simple_rules() {
    ufw show added 2> /dev/null | sed -nE "s/^ufw allow ([0-9]+(\/(tcp|udp))?)( comment '(.*)')?$/\1|\5/p"
}

ufw_allows() {
    local rule="$1" port="${1%%/*}"
    ufw_simple_rules | cut -d'|' -f1 | grep -qxE "(${rule}|${port})"
}

ufw_stale_rules() {
    local spec comment port targets known
    targets=" $(ufw_target_rules | tr '\n' ' ') "
    known=" ${INTERNAL_PORTS[*]} $(xhttp_port) $(json_get "$(xui_discover)" ports | tr -d '[]",' ) ${STALE_PORTS} "
    while IFS='|' read -r spec comment; do
        [[ -n "$spec" ]] || continue
        [[ "$targets" == *" ${spec} "* ]] && continue
        port="${spec%%/*}"
        if [[ "$spec" == "$port" && "$targets" == *" ${port}/"* ]]; then
            continue
        fi
        if [[ "$comment" == *"$SCRIPT_NAME"* || "$comment" == *acme* ]] \
            || [[ " ${INTERNAL_PORTS[*]} $(xhttp_port) " == *" ${port} "* ]] \
            || [[ "$known" == *" ${spec} "* || "$known" == *" ${port}/"* ]]; then
            printf '%s\n' "$spec"
        fi
    done < <(ufw_simple_rules)
}

check_ufw() {
    local rc=0 rule
    if ! ufw_present; then
        log "$(L "ufw не установлен, порты для внешнего файрвола: $(ufw_target_rules | tr '\n' ' ')" "ufw is not installed, ports for an external firewall: $(ufw_target_rules | tr '\n' ' ')")"
        return 0
    fi
    while IFS= read -r rule; do
        ufw_allows "$rule" || {
            mismatch "$(L "нет правила ufw ${rule}" "no ufw rule ${rule}")"
            rc=1
        }
    done < <(ufw_target_rules)
    return "$rc"
}

apply_ufw() {
    local rule
    while IFS= read -r rule; do
        ufw_allows "$rule" && continue
        ufw allow "$rule" comment "$SCRIPT_NAME" > /dev/null 2>&1 && log "$(L "ufw: добавлено ${rule}" "ufw: added ${rule}")"
    done < <(ufw_target_rules)
}

check_ufw_cleanup() {
    local rc=0 rule
    ufw_present || return 0
    while IFS= read -r rule; do
        [[ -n "$rule" ]] || continue
        mismatch_minor "$(L "лишнее правило ufw ${rule}" "extra ufw rule ${rule}")"
        rc=1
    done < <(ufw_stale_rules)
    return "$rc"
}

apply_ufw_cleanup() {
    local rule i
    while IFS= read -r rule; do
        [[ -n "$rule" ]] || continue
        for i in 1 2 3; do
            ufw --force delete allow "$rule" > /dev/null 2>&1 || break
        done
        log "$(L "ufw: удалено ${rule}" "ufw: removed ${rule}")"
    done < <(ufw_stale_rules)
}

# ФИНАЛЬНАЯ ПРОВЕРКА

expect_tls() {
    local host="$1" port="$2" sni="$3" want="$4" what="$5" got
    got=$(tls_probe "$host" "$port" "$sni")
    if [[ "$got" == "$want" ]]; then
        report_ok "$(L "${host}:${port}, ${what}: $([[ "$got" == cert ]] && echo 'свой сертификат' || echo 'отказ')" "${host}:${port}, ${what}: $([[ "$got" == cert ]] && echo 'own certificate' || echo 'rejected')")"
    else
        report_fail "$(L "${host}:${port}, ${what}: $([[ "$got" == cert ]] && echo 'выдан сертификат, ожидался отказ' || echo 'отказ, ожидался сертификат')" "${host}:${port}, ${what}: $([[ "$got" == cert ]] && echo 'certificate served, rejection expected' || echo 'rejected, certificate expected')")"
    fi
}

final_listen_checks() {
    local hy2_port addrs
    hy2_port=$(hy2_port_answer)
    if xray_holds_443 && ! tcp_listeners "$PUBLIC_TLS_PORT" | grep -qv '"xray'; then
        report_ok "$(L "${PUBLIC_TLS_PORT}/tcp слушает только Xray" "Only Xray listens on ${PUBLIC_TLS_PORT}/tcp")"
    else
        report_fail "${PUBLIC_TLS_PORT}/tcp: $(tcp_listeners "$PUBLIC_TLS_PORT" | awk '{print $4, $6}' | tr '\n' ' ')"
    fi
    addrs=$(nginx_addresses | paste -sd ',' - | sed 's/,/, /g')
    if nginx_listens_expected; then
        report_ok "$(L "nginx слушает $(nginx_expected_text)" "nginx listens on $(nginx_expected_text)")"
    else
        report_fail "$(L "nginx слушает: ${addrs:-ничего}; нужно: $(nginx_expected_text)" "nginx listens on: ${addrs:-nothing}; expected: $(nginx_expected_text)")"
    fi
    if [[ "$hy2_port" != 0 ]]; then
        if xray_holds_udp "$hy2_port"; then
            report_ok "$(L "Hysteria2 слушает UDP/${hy2_port}" "Hysteria2 listens on UDP/${hy2_port}")"
        else
            report_fail "$(L "Hysteria2 не слушает UDP/${hy2_port}" "Hysteria2 does not listen on UDP/${hy2_port}")"
        fi
    fi
}

final_config_checks() {
    local summary loops line
    summary=$(py config-summary "$XRAY_CONFIG") || {
        report_fail "$(L "не удалось прочитать ${XRAY_CONFIG}" "failed to read ${XRAY_CONFIG}")"
        return
    }
    if [[ "$(json_get "$summary" reality.port)" == "$PUBLIC_TLS_PORT" && "$(json_get "$summary" reality.target)" == "$REALITY_TARGET" ]]; then
        report_ok "$(L "config.json: Reality ${PUBLIC_TLS_PORT} → ${REALITY_TARGET}, тег $(json_get "$summary" reality.tag)" "config.json: Reality ${PUBLIC_TLS_PORT} → ${REALITY_TARGET}, tag $(json_get "$summary" reality.tag)")"
    else
        report_fail "$(L "config.json: Reality порт $(json_get "$summary" reality.port), target $(json_get "$summary" reality.target)" "config.json: Reality port $(json_get "$summary" reality.port), target $(json_get "$summary" reality.target)")"
    fi
    if [[ "$(json_get "$summary" reality.xver)" == 1 ]]; then
        report_ok "$(L "config.json: Reality xver 1, nginx получает адрес клиента" "config.json: Reality xver 1, nginx receives the client address")"
    else
        report_fail "$(L "config.json: Reality xver $(json_get "$summary" reality.xver), нужен 1" "config.json: Reality xver $(json_get "$summary" reality.xver), expected 1")"
    fi
    if xhttp_enabled; then
        if [[ "$(json_get "$summary" xhttp.real_ip)" == true ]]; then
            report_ok "$(L "config.json: XHTTP берёт адрес клиента из X-Forwarded-For (trustedXForwardedFor: X-Real-IP)" "config.json: XHTTP takes the client address from X-Forwarded-For (trustedXForwardedFor: X-Real-IP)")"
        else
            report_fail "$(L "config.json: у XHTTP нет X-Real-IP в sockopt.trustedXForwardedFor или включён acceptProxyProtocol" "config.json: XHTTP has no X-Real-IP in sockopt.trustedXForwardedFor or acceptProxyProtocol is on")"
        fi
    fi
    if [[ "$(json_get "$summary" reality.limit_fallback)" == "[]" ]]; then
        report_ok "$(L "config.json: ненулевых limitFallback нет" "config.json: no non-zero limitFallback")"
    else
        report_fail "config.json: limitFallback $(json_get "$summary" reality.limit_fallback)"
    fi
    if [[ "$(hy2_port_answer)" != 0 ]]; then
        if [[ "$(json_get "$summary" hy2.port)" == "$HY2_PORT" && "$(json_get "$summary" hy2.plain)" == true \
            && "$(json_get "$summary" hy2.reject_sni)" == true ]]; then
            report_ok "$(L "config.json: Hysteria2 на ${HY2_PORT}/udp без маскировки, чужой SNI — отказ" "config.json: Hysteria2 on ${HY2_PORT}/udp without obfuscation, foreign SNI rejected")"
        else
            report_fail "$(L "config.json: Hysteria2 не по эталону (порт $(json_get "$summary" hy2.port), без маскировки: $(json_get "$summary" hy2.plain), rejectUnknownSni: $(json_get "$summary" hy2.reject_sni))" "config.json: Hysteria2 does not match the reference (port $(json_get "$summary" hy2.port), without obfuscation: $(json_get "$summary" hy2.plain), rejectUnknownSni: $(json_get "$summary" hy2.reject_sni))")"
        fi
    fi
    if [[ "$(json_get "$summary" sniffing_off)" == "[]" ]]; then
        report_ok "$(L "config.json: sniffing http, tls, quic, routeOnly на всех инбаундах" "config.json: sniffing http, tls, quic, routeOnly on all inbounds")"
    else
        report_fail "$(L "config.json: sniffing не по шаблону: $(json_lines "$summary" sniffing_off | paste -sd ',' - | sed 's/,/, /g')" "config.json: sniffing does not match the template: $(json_lines "$summary" sniffing_off | paste -sd ',' - | sed 's/,/, /g')")"
    fi
    if [[ "$(json_get "$summary" block_missing)" == "[]" ]]; then
        report_ok "$(L "правила blocked: geoip:private, IP RU, bittorrent, домены RU, реклама" "blocked rules: geoip:private, RU IPs, bittorrent, RU domains, ads")"
    else
        report_fail "$(L "нет в правилах blocked: $(block_missing_text "$summary")" "missing from blocked rules: $(block_missing_text "$summary")")"
    fi
    if [[ "$(json_get "$summary" udp443_ok)" == true ]]; then
        report_ok "$(L "правило UDP/443 → blocked: $(json_get "$summary" udp443_expected)" "UDP/443 → blocked rule: $(json_get "$summary" udp443_expected)")"
    else
        report_fail "$(L "правило UDP/443 → blocked: $(json_get "$summary" udp443_actual), нужно $(json_get "$summary" udp443_expected)" "UDP/443 → blocked rule: $(json_get "$summary" udp443_actual), expected $(json_get "$summary" udp443_expected)")"
    fi
    if warp_enabled; then
        if [[ "$(json_get "$summary" warp.ok)" == true ]]; then
            report_ok "$(L "правило → warp (Cloudflare WARP): $(json_get "$summary" warp.expected)" "→ warp rule (Cloudflare WARP): $(json_get "$summary" warp.expected)")"
        else
            while IFS= read -r line; do
                [[ -n "$line" ]] && report_fail "$line"
            done < <(warp_problems "$summary")
        fi
    fi
    loops=$(ss -Htn 2> /dev/null | grep -c "127.0.0.1:${PUBLIC_TLS_PORT} ")
    if [[ "$loops" -eq 0 ]]; then
        report_ok "$(L "петли нет: соединений на 127.0.0.1:${PUBLIC_TLS_PORT} нет" "no loop: no connections to 127.0.0.1:${PUBLIC_TLS_PORT}")"
    else
        report_fail "$(L "петля: ${loops} соединений на 127.0.0.1:${PUBLIC_TLS_PORT}" "loop: ${loops} connections to 127.0.0.1:${PUBLIC_TLS_PORT}")"
    fi
}

final_tls_checks() {
    local domain="$1" ip="$2" code body
    if dest_ready "$domain"; then
        report_ok "$(L "${REALITY_TARGET}: PROXY protocol, TLS 1.3 + h2, свой сертификат, без SNI — отказ" "${REALITY_TARGET}: PROXY protocol, TLS 1.3 + h2, own certificate, rejection without SNI")"
    else
        report_fail "$(L "${REALITY_TARGET} не годится в target Reality" "${REALITY_TARGET} is not suitable as the Reality target")"
    fi
    expect_tls "$ip" "$PUBLIC_TLS_PORT" "-" reject "$(L "без SNI" "without SNI")"
    expect_tls "$ip" "$PUBLIC_TLS_PORT" "scanner.invalid" reject "$(L "чужой SNI" "foreign SNI")"
    expect_tls "$ip" "$PUBLIC_TLS_PORT" "$domain" cert "SNI ${domain}"
    code=$(http_code "https://${domain}/" "${domain}:${PUBLIC_TLS_PORT}:${ip}")
    if [[ "$code" == 200 ]]; then
        report_ok "$(L "сайт через фолбек Reality: https://${domain}/ → 200" "site through the Reality fallback: https://${domain}/ → 200")"
    else
        report_fail "$(L "сайт через фолбек Reality: https://${domain}/ → ${code}" "site through the Reality fallback: https://${domain}/ → ${code}")"
    fi
    code=$(http_code "https://${domain}$(conf_get PANEL_PATH)/" "${domain}:${PUBLIC_TLS_PORT}:${ip}")
    if [[ "$code" =~ ^(200|301|302|307|308)$ ]]; then
        report_ok "$(L "панель через ${PUBLIC_TLS_PORT}: ${code}" "panel through ${PUBLIC_TLS_PORT}: ${code}")"
    else
        report_fail "$(L "панель через ${PUBLIC_TLS_PORT}: ${code}" "panel through ${PUBLIC_TLS_PORT}: ${code}")"
    fi
    body=$(curl -sk --noproxy '*' --max-time 10 --resolve "${domain}:${PUBLIC_TLS_PORT}:${ip}" \
        "https://${domain}$(conf_get PANEL_PATH)/sponsors")
    if [[ "$body" == "$SPONSORS_EMPTY" ]]; then
        report_ok "$(L "запрос рекламы 3x-ui перехватывает nginx: пустой список" "the 3x-ui ad request is intercepted by nginx: empty list")"
    else
        report_fail "$(L "запрос рекламы 3x-ui не перехвачен nginx, ответ: ${body:0:80}" "the 3x-ui ad request is not intercepted by nginx, response: ${body:0:80}")"
    fi
}

expect_empty_reply() {
    local what="$1" code
    shift
    code=$(curl_exit_code "$@")
    if [[ "$code" == 52 ]]; then
        report_ok "$(L "${what}: соединение закрыто без ответа" "${what}: connection closed without a response")"
    else
        report_fail "$(L "${what}: curl exit ${code}, ожидался 52 (закрытие без ответа)" "${what}: curl exit ${code}, expected 52 (closed without a response)")"
    fi
}

final_http_checks() {
    local domain="$1" ip="$2" out want
    expect_empty_reply "http://${ip}/" "http://${ip}/"
    expect_empty_reply "http://${ip}/, Host: scanner.invalid" -H 'Host: scanner.invalid' "http://${ip}/"
    want="https://${domain}/check80?x=1"
    out=$(curl -s --noproxy '*' --max-time 10 --resolve "${domain}:${HTTP_PORT}:${ip}" -o /dev/null \
        -w '%{http_code} %{redirect_url}' "http://${domain}/check80?x=1")
    if [[ "$out" == "301 ${want}" ]]; then
        report_ok "http://${domain}/check80?x=1 → 301 ${want}"
    else
        report_fail "$(L "http://${domain}/check80?x=1 → ${out% }, ожидался 301 ${want}" "http://${domain}/check80?x=1 → ${out% }, expected 301 ${want}")"
    fi
    if challenge_served "$ip"; then
        report_ok "$(L "http://${domain}/.well-known/acme-challenge/ отдаёт файлы из $(acme_challenge_dir)" "http://${domain}/.well-known/acme-challenge/ serves files from $(acme_challenge_dir)")"
    else
        report_fail "$(L "http://${domain}/.well-known/acme-challenge/ не отдаёт файлы из $(acme_challenge_dir)" "http://${domain}/.well-known/acme-challenge/ does not serve files from $(acme_challenge_dir)")"
    fi
    if acme_webroot_set; then
        report_ok "acme.sh: Le_Webroot='${ACME_WEBROOT}'"
    else
        report_fail "$(L "acme.sh: нет Le_Webroot='${ACME_WEBROOT}' в $(acme_domain_conf)" "acme.sh: no Le_Webroot='${ACME_WEBROOT}' in $(acme_domain_conf)")"
    fi
    if [[ -s "$CERT_RENEW" ]] && ! grep -qE 'standalone|ufw' "$CERT_RENEW"; then
        report_ok "$(L "${CERT_RENEW}: без standalone и ufw" "${CERT_RENEW}: without standalone and ufw")"
    else
        report_fail "$(L "${CERT_RENEW} отсутствует или использует standalone / ufw" "${CERT_RENEW} is missing or uses standalone / ufw")"
    fi
    if renew_cron_present && ! acme_cron_present; then
        report_ok "$(L "cron root: ${CERT_RENEW}, без acme.sh --cron" "root cron: ${CERT_RENEW}, without acme.sh --cron")"
    else
        report_fail "$(L "cron root: нужна задача ${CERT_RENEW} и не нужна acme.sh --cron" "root cron: the ${CERT_RENEW} job is required and acme.sh --cron is not")"
    fi
}

final_subscription_checks() {
    local domain="$1" ip="$2" sub_id url out body meta code type endpoints hy2_port line
    sub_id=$(json_get "$(xui_discover)" sub_id)
    if [[ -z "$sub_id" ]]; then
        report_fail "$(L "не найден клиент с subId" "no client with a subId found")"
        return
    fi
    out=$(curl -sk --noproxy '*' --max-time 10 --resolve "${domain}:${PUBLIC_TLS_PORT}:${ip}" \
        -w '\n%{http_code}|%{content_type}' "https://${domain}$(conf_get SUB_PATH)/${sub_id}")
    body="${out%$'\n'*}"
    meta="${out##*$'\n'}"
    code="${meta%%|*}"
    type="${meta#*|}"
    if [[ "$code" != 200 || -z "$body" || "$type" == *text/html* ]]; then
        report_fail "$(L "подписка через ${PUBLIC_TLS_PORT}: код ${code}, тип ${type}" "subscription through ${PUBLIC_TLS_PORT}: code ${code}, type ${type}")"
        return
    fi
    endpoints=$(py sub-endpoints <<< "$body")
    report_ok "$(L "подписка через ${PUBLIC_TLS_PORT}: 200, ссылки:" "subscription through ${PUBLIC_TLS_PORT}: 200, links:")"
    py json-lines "{\"items\": ${endpoints}}" items | while IFS= read -r line; do
        log "  $(json_get "$line" scheme)://…@$(json_get "$line" host):$(json_get "$line" port) $(json_get "$line" type) $(json_get "$line" security)"
    done
    hy2_port=$(hy2_port_answer)
    py_expect_endpoint "$endpoints" vless "$domain" "$PUBLIC_TLS_PORT" reality "VLESS Reality"
    xhttp_enabled && py_expect_endpoint "$endpoints" vless "$domain" "$PUBLIC_TLS_PORT" xhttp "VLESS XHTTP"
    [[ "$hy2_port" != 0 ]] && py_expect_endpoint "$endpoints" hysteria2 "$domain" "$hy2_port" "" "Hysteria2"
    url="https://${domain}$(conf_get SUB_PATH)/verify-fake-subid-00000000"
    code=$(http_code "$url" "${domain}:${PUBLIC_TLS_PORT}:${ip}")
    if [[ "$code" == 404 ]]; then
        report_ok "$(L "несуществующий subId → 404" "non-existent subId → 404")"
    else
        report_fail "$(L "несуществующий subId → ${code}, ожидался 404" "non-existent subId → ${code}, expected 404")"
    fi
}

py_expect_endpoint() {
    local endpoints="$1" scheme="$2" host="$3" port="$4" marker="$5" name="$6"
    if python3 -c '
import json, sys
items = json.loads(sys.argv[1])
scheme, host, port, marker = sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
schemes = {"hysteria2": ("hysteria2", "hy2")}.get(scheme, (scheme,))
ok = any(i["scheme"] in schemes and i["host"] == host and i["port"] == port
         and (not marker or marker in (i["type"], i["security"])) for i in items)
sys.exit(0 if ok else 1)
' "$endpoints" "$scheme" "$host" "$port" "$marker"; then
        report_ok "$(L "в подписке ${name}: ${host}:${port}" "in the subscription ${name}: ${host}:${port}")"
    else
        report_fail "$(L "в подписке нет ${name} с адресом ${host}:${port}" "the subscription has no ${name} with address ${host}:${port}")"
    fi
}

final_journal_checks() {
    local since
    since=$(systemctl show -p ActiveEnterTimestamp --value x-ui 2> /dev/null)
    if [[ -z "$since" ]]; then
        report_warn "$(L "не удалось определить время запуска x-ui, журнал не проверен" "failed to determine the x-ui start time, the journal is not checked")"
        return
    fi
    since=$(date -d "$since" '+%F %T' 2> /dev/null) || since=""
    if journalctl -u x-ui --since "${since:-today}" --no-pager 2> /dev/null | grep -qi 'non-443'; then
        report_fail "$(L "в журнале x-ui есть предупреждение REALITY о порте не 443" "the x-ui journal has a REALITY warning about a port other than 443")"
    else
        report_ok "$(L "предупреждения REALITY о порте не 443 в журнале нет" "no REALITY warning about a port other than 443 in the journal")"
    fi
    if journalctl -u x-ui --since "${since:-today}" --no-pager 2> /dev/null | grep -v 'systemd\[' | grep -qiE 'failed to (build|start)'; then
        report_fail "$(L "в журнале x-ui есть ошибки запуска Xray" "the x-ui journal has Xray start errors")"
    fi
}

final_service_checks() {
    local rule extra
    local unit
    for unit in nginx x-ui; do
        if systemctl is-active --quiet "$unit"; then
            report_ok "$(L "${unit} активен" "${unit} is active")"
        else
            report_fail "$(L "${unit} не активен" "${unit} is not active")"
        fi
    done
    if ! ufw_present; then
        report_warn "$(L "ufw не установлен, порты для внешнего файрвола: $(ufw_target_rules | tr '\n' ' ')" "ufw is not installed, ports for an external firewall: $(ufw_target_rules | tr '\n' ' ')")"
        return
    fi
    while IFS= read -r rule; do
        if ufw_allows "$rule"; then
            report_ok "ufw: ${rule}"
        else
            report_fail "$(L "ufw: нет ${rule}" "ufw: no ${rule}")"
        fi
    done < <(ufw_target_rules)
    extra=$(ufw_simple_rules | cut -d'|' -f1 | grep -vxF -f <(ufw_target_rules) | grep -vxF -f <(ufw_target_rules | cut -d/ -f1) \
        | grep -vxF -f <(ufw_stale_rules; echo "-") | tr '\n' ' ')
    if [[ -n "${extra// /}" ]]; then
        report_warn "$(L "в ufw есть другие правила: ${extra% }" "ufw has other rules: ${extra% }")"
    fi
    if ! ufw status 2> /dev/null | grep -q 'Status: active'; then
        report_warn "$(L "ufw выключен, правила не действуют" "ufw is disabled, the rules have no effect")"
    fi
}

final_checks() {
    local domain ip
    domain=$(conf_get DOMAIN)
    FINAL_OK=1
    final_listen_checks
    final_config_checks
    if ip=$(get_public_ipv4); then
        final_tls_checks "$domain" "$ip"
        final_http_checks "$domain" "$ip"
        final_subscription_checks "$domain" "$ip"
    else
        report_fail "$(L "не удалось определить публичный IPv4" "failed to determine the public IPv4")"
    fi
    final_journal_checks
    final_service_checks
    [[ "$FINAL_OK" -eq 1 ]]
}

# УДАЛЕНИЕ

xui_files() {
    local unit
    unit=$(systemctl show -p FragmentPath --value x-ui 2> /dev/null)
    printf '%s\n' "${unit:-/etc/systemd/system/x-ui.service}" /etc/systemd/system/x-ui.service.d /usr/bin/x-ui \
        /usr/local/x-ui /etc/x-ui /etc/default/x-ui /var/log/x-ui \
        /etc/fail2ban/jail.d/3x-ipl.conf /etc/fail2ban/jail.d/3x-ipl-backend.conf \
        /etc/fail2ban/filter.d/3x-ipl.conf /etc/fail2ban/action.d/3x-ipl.conf
}

nginx_files() {
    local f
    while IFS= read -r f; do
        [[ -f "$f" || -L "$f" ]] && printf '%s\n' "$f"
    done < <(nginx_managed_files)
}

acme_domain_dirs() {
    local domain
    domain=$(conf_get DOMAIN)
    [[ -n "$domain" ]] || return 0
    printf '%s\n' "/root/.acme.sh/${domain}_ecc" "/root/.acme.sh/${domain}"
}

acme_other_domains() {
    local own dir
    own=" $(acme_domain_dirs | tr '\n' ' ') "
    find /root/.acme.sh -mindepth 1 -maxdepth 1 -type d -name '*.*' 2> /dev/null | while IFS= read -r dir; do
        [[ "$own" == *" ${dir} "* ]] || basename "$dir"
    done
}

cert_files() {
    local folder
    folder=$(conf_get CERT_FOLDER)
    printf '%s\n' "$CERT_RENEW" /var/log/cert-renew.log "$ACME_WEBROOT"
    acme_domain_dirs
    [[ "$folder" =~ $FOLDER_RE ]] && printf '/etc/ssl/%s\n' "$folder"
}

script_ufw_rules() {
    local ssh rule comment
    ufw_present || return 0
    ssh=" $(ssh_ports | tr '\n' ' ') "
    while IFS='|' read -r rule comment; do
        [[ "$comment" == "$SCRIPT_NAME" ]] || continue
        [[ "$rule" != */udp && "$ssh" == *" ${rule%/tcp} "* ]] && continue
        printf '%s\n' "$rule"
    done < <(ufw_simple_rules)
}

rest_files() {
    local folder
    folder=$(conf_get CERT_FOLDER)
    [[ "$folder" =~ $FOLDER_RE ]] && printf '/var/www/%s\n' "$folder"
    compgen -G '/root/nginx-*.tgz' || true
    printf '%s\n' "$CONF_FILE" "$LOG_FILE"
}

existing() {
    local f
    while IFS= read -r f; do
        [[ -n "$f" && (-e "$f" || -L "$f") ]] && printf '%s\n' "$f"
    done
}

installed_packages() {
    dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' "$@" 2> /dev/null | awk '$1 == "ii" {print $2}'
}

remove_paths() {
    local f
    while IFS= read -r f; do
        rm -rf -- "$f" && log "$(L "удалён ${f}" "removed ${f}")"
    done
}

uninstall_xui() {
    local files backup f2b=0
    files=$(xui_files | existing)
    systemctl disable --now x-ui > /dev/null 2>&1
    if [[ -s "$XUI_DB" ]]; then
        backup="/root/x-ui.db.$(date +%F-%H%M%S)"
        cp -p "$XUI_DB" "$backup" || die "$(L "не удалось скопировать ${XUI_DB}" "failed to copy ${XUI_DB}")"
        log "$(L "копия базы: ${backup}" "database copy: ${backup}")"
    fi
    [[ "$files" == *"/etc/fail2ban/"* ]] && f2b=1
    remove_paths <<< "$files"
    systemctl daemon-reload > /dev/null 2>&1
    systemctl reset-failed x-ui > /dev/null 2>&1
    if ((f2b)) && systemctl is-active --quiet fail2ban; then
        systemctl restart fail2ban > /dev/null 2>&1
    fi
    conf_unset XHTTP XHTTP_PORT XHTTP_PATH SUB_PATH PANEL_PATH XUI_USERNAME XUI_PASSWORD XUI_PASSWORD_HASH \
        XUI_CREDENTIALS_PENDING XUI_VERIFY_PENDING HY2 WARP CLIENT_NAME
}

uninstall_nginx() {
    remove_paths < <(nginx_files)
    if systemctl is-active --quiet nginx; then
        if nginx -t > /dev/null 2>&1; then
            systemctl reload nginx > /dev/null 2>&1
        else
            report_warn "$(L "nginx -t: ошибка конфигурации после удаления" "nginx -t: configuration error after removal")"
        fi
    fi
}

uninstall_cert() {
    local domain others
    domain=$(conf_get DOMAIN)
    if renew_cron_present; then
        { crontab -l -u root 2> /dev/null | grep -vF "$CERT_RENEW" || true; } | crontab -u root - && log "$(L "удалена задача cron ${CERT_RENEW}" "removed the cron job ${CERT_RENEW}")"
    fi
    if [[ -x "$ACME" && -n "$domain" ]]; then
        "$ACME" --remove -d "$domain" --ecc >> "$LOG_FILE" 2>&1
    fi
    remove_paths < <(cert_files | existing)
    if [[ -x "$ACME" ]]; then
        others=$(acme_other_domains | tr '\n' ' ')
        if [[ -z "$others" ]]; then
            "$ACME" --uninstall >> "$LOG_FILE" 2>&1
            rm -rf /root/.acme.sh && log "$(L "удалён /root/.acme.sh" "removed /root/.acme.sh")"
        else
            log "$(L "acme.sh оставлен, другие домены: ${others% }" "acme.sh kept, other domains: ${others% }")"
        fi
    fi
}

uninstall_ufw() {
    local rule
    if ! ufw_present; then
        log "$(L "ufw не установлен" "ufw is not installed")"
        return 0
    fi
    while IFS= read -r rule; do
        ufw --force delete allow "$rule" > /dev/null 2>&1 && log "$(L "ufw: удалено ${rule}" "ufw: removed ${rule}")"
    done < <(script_ufw_rules)
}

uninstall_packages() {
    local packages=("$@")
    if ! DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "${packages[@]}" >> "$LOG_FILE" 2>&1; then
        die "$(L "apt-get purge завершился с ошибкой" "apt-get purge failed")"
    fi
    log "$(L "удалены пакеты: ${packages[*]}" "removed packages: ${packages[*]}")"
    if [[ " ${packages[*]} " == *" nginx "* && "$(ls -A /var/www/html 2> /dev/null)" == index.nginx-debian.html ]]; then
        rm -rf /var/www/html && log "$(L "удалён /var/www/html" "removed /var/www/html")"
        rmdir /var/www 2> /dev/null && log "$(L "удалён /var/www" "removed /var/www")"
    fi
}

uninstall_rest() {
    local kept log_file="$LOG_FILE"
    remove_paths < <(rest_files | grep -vxF "$log_file" | existing)
    if [[ -z "$(installed_packages nginx)" ]]; then
        rmdir /var/www 2> /dev/null && log "$(L "удалён /var/www" "removed /var/www")"
    fi
    kept=$({ compgen -G "$NGINX_PANEL_SNIPPETS"; compgen -G "$NGINX_STUB_SNIPPETS"; } | tr '\n' ' ')
    [[ -n "$kept" ]] && log "$(L "оставлены файлы пользователя: ${kept% }" "user files kept: ${kept% }")"
    LOG_FILE=/dev/null
    rm -f "$log_file"
    log "$(L "удалён ${log_file}" "removed ${log_file}")"
}

uninstall_plan() {
    local item="$1"
    case "$item" in
        xui)
            xui_files | existing
            [[ -s "$XUI_DB" ]] && printf '%s\n' "$(L "(копия базы сохраняется в /root/x-ui.db.<дата>)" "(the database is copied to /root/x-ui.db.<date>)")"
            ;;
        nginx) nginx_files ;;
        cert)
            renew_cron_present && printf '%s\n' "$(L "задача cron ${CERT_RENEW}" "cron job ${CERT_RENEW}")"
            cert_files | existing
            [[ -x "$ACME" && -z "$(acme_other_domains)" ]] && echo "/root/.acme.sh"
            ;;
        ufw) script_ufw_rules ;;
        rest) rest_files | existing ;;
    esac
}

read_components() {
    local -n _rc_out="$1"
    local choice n
    while true; do
        prompted
        read -r -p "$(L "Номера через пробел: " "Numbers separated by spaces: ")" choice || die "$(L "Ввод прерван." "Input interrupted.")"
        _rc_out=()
        for n in $choice; do
            if [[ ! "$n" =~ ^[1-5]$ ]]; then
                _rc_out=()
                break
            fi
            _rc_out+=("$n")
        done
        ((${#_rc_out[@]} > 0)) && return 0
        printf '%s\n' "$(L "  Ожидаются номера 1–5." "  Expected numbers 1–5.")"
    done
}

run_uninstall() {
    local -a numbers=() items=() packages=() candidates=()
    local -A titles=([xui]="3x-ui" [nginx]="nginx" [cert]="$(L "Сертификат" "Certificate")" [ufw]="ufw" [rest]="$(L "Прочие файлы" "Other files")")
    local -A picked=()
    local item n line plan folder
    if [[ ! -t 0 ]]; then
        printf '%s\n' "$(L "--uninstall: нужен ввод с терминала" "--uninstall: terminal input is required")" >&2
        exit 1
    fi
    init_log
    trap 'die "$(L "Прервано." "Interrupted.")"' INT TERM HUP
    conf_load
    [[ -n "$(conf_get DOMAIN)" ]] || CONF[DOMAIN]=$(discover_domain)
    if [[ -z "$(conf_get CERT_FOLDER)" ]]; then
        folder=$(discover_cert_folder)
        CONF[CERT_FOLDER]="${folder:-$(conf_get DOMAIN)}"
    fi
    emit "$(L "${SCRIPT_NAME} --uninstall, журнал: ${LOG_FILE}" "${SCRIPT_NAME} --uninstall, log: ${LOG_FILE}")"
    if [[ -n "$(conf_get DOMAIN)" ]]; then
        emit "$(L "Домен: $(conf_get DOMAIN)" "Domain: $(conf_get DOMAIN)")"
    else
        emit "$(L "Домен не определён: файлы сайта nginx, сертификата и заглушки не найдены" "Domain not determined: nginx site, certificate and decoy files not found")"
    fi
    emit ""
    emit "$(L "Компоненты:" "Components:")"
    emit "$(L "  1  3x-ui: панель, Xray, база, служба x-ui, jail fail2ban 3x-ipl" "  1  3x-ui: panel, Xray, database, x-ui service, fail2ban jail 3x-ipl")"
    emit "$(L "  2  nginx: конфиги сайта, антискан, порт 80" "  2  nginx: site configs, anti-scan, port 80")"
    emit "$(L "  3  сертификат: $(cert_dir), acme.sh, cert-renew.sh, задача cron" "  3  certificate: $(cert_dir), acme.sh, cert-renew.sh, cron job")"
    emit "$(L "  4  правила ufw с комментарием ${SCRIPT_NAME}, кроме SSH" "  4  ufw rules with the ${SCRIPT_NAME} comment, except SSH")"
    emit "$(L "  5  всё перечисленное, сайт-заглушка, файл ответов, журнал, архивы /root/nginx-*.tgz" "  5  everything above, decoy site, answers file, log, /root/nginx-*.tgz archives")"
    read_components numbers
    for n in "${numbers[@]}"; do
        case "$n" in
            1) picked[xui]=1 ;;
            2) picked[nginx]=1 ;;
            3) picked[cert]=1 ;;
            4) picked[ufw]=1 ;;
            5) picked=([xui]=1 [nginx]=1 [cert]=1 [ufw]=1 [rest]=1) ;;
        esac
    done
    for item in xui nginx cert ufw rest; do
        [[ -n "${picked[$item]:-}" ]] && items+=("$item")
    done
    [[ -n "${picked[nginx]:-}" ]] && mapfile -t -O "${#candidates[@]}" candidates < <(installed_packages 'nginx*' 'libnginx-mod-*')
    [[ -n "${picked[xui]:-}" ]] && mapfile -t -O "${#candidates[@]}" candidates < <(installed_packages fail2ban)
    if ((${#candidates[@]} > 0)) && ask_yes_no "$(L "Удалить пакеты: ${candidates[*]}?" "Remove packages: ${candidates[*]}?")" n; then
        packages=("${candidates[@]}")
    fi

    emit ""
    emit "$(L "Будет удалено:" "To be removed:")"
    for item in "${items[@]}"; do
        emit "  ${titles[$item]}:"
        plan=$(uninstall_plan "$item")
        if [[ -n "$plan" ]]; then
            while IFS= read -r line; do emit "    ${line}"; done <<< "$plan"
        else
            emit "$(L "    нечего удалять" "    nothing to remove")"
        fi
    done
    ((${#packages[@]} > 0)) && emit "$(L "  Пакеты: ${packages[*]}" "  Packages: ${packages[*]}")"
    if [[ -n "${picked[nginx]:-}" && -z "${picked[xui]:-}" && -x "$XUI_BIN" ]]; then
        emit "$(L "! 3x-ui остаётся: Reality без nginx на ${REALITY_TARGET} не работает" "! 3x-ui stays: Reality does not work without nginx on ${REALITY_TARGET}")"
    fi
    if [[ -n "${picked[cert]:-}" && (-z "${picked[nginx]:-}" || -z "${picked[xui]:-}") ]]; then
        emit "$(L "! nginx и Hysteria2 используют сертификат из $(cert_dir)" "! nginx and Hysteria2 use the certificate from $(cert_dir)")"
    fi
    ask_yes_no "$(L "Удалить?" "Remove?")" n || {
        emit "$(L "Отменено." "Cancelled.")"
        exit 0
    }

    STEP_TOTAL=$((${#items[@]} + (${#packages[@]} > 0 ? 1 : 0)))
    emit ""
    for item in "${items[@]}"; do
        if [[ "$item" == rest ]] && ((${#packages[@]} > 0)); then
            step "$(L "Пакеты" "Packages")"
            uninstall_packages "${packages[@]}"
            report_ok "$(L "готово" "done")"
            step_end
            packages=()
        fi
        step "${titles[$item]}"
        "uninstall_${item}"
        report_ok "$(L "готово" "done")"
        step_end
    done
    if ((${#packages[@]} > 0)); then
        step "$(L "Пакеты" "Packages")"
        uninstall_packages "${packages[@]}"
        report_ok "$(L "готово" "done")"
        step_end
    fi
    emit "$(L "Удаление завершено." "Removal complete.")"
    exit 0
}

# ЗАПУСК

panel_password_text() {
    if [[ -n "$(conf_get XUI_PASSWORD)" && "$(py panel-user "$XUI_DB" password)" == "$(conf_get XUI_PASSWORD_HASH)" ]]; then
        conf_get XUI_PASSWORD
    else
        L "задан вне скрипта, смена: sudo bash ${0##*/} --reconfigure" "set outside the script, to change: sudo bash ${0##*/} --reconfigure"
    fi
}

print_summary() {
    local domain user password sub
    domain=$(conf_get DOMAIN)
    user=$(py panel-user "$XUI_DB" username)
    password=$(panel_password_text)
    sub="https://${domain}$(conf_get SUB_PATH)/$(json_get "$(xui_discover)" sub_id)"
    log "$(L "Установка завершена." "Installation complete.")"
    log "$(L "Панель:    " "Panel:        ")https://${domain}$(conf_get PANEL_PATH)/"
    log "$(L "Логин:     " "Username:     ")${user}"
    log "$(L "Пароль:    " "Password:     ")${password}"
    log "$(L "Подписка:  " "Subscription: ")${sub}"
    [[ "$TWO_FA_RESET" -eq 1 ]] && log "$(L "2FA:       отключена при импорте" "2FA:          disabled on import")"
    if grep -qF '<title>403 Forbidden</title>' "$(www_dir)/index.html" 2> /dev/null; then
        log ""
        log "$(L "Сейчас на сайте страница 403. Свою заглушку — index.html и фавиконку — можно положить в $(www_dir)/" "The site now shows a 403 page. A custom decoy — index.html and a favicon — can be placed in $(www_dir)/")"
        log "$(L "Заглушка — обычный небольшой сайт по теме домена: статические файлы в этой папке, без упоминаний VPN и прокси." "A decoy is an ordinary small site that fits the domain: static files in this folder, no mentions of VPN or proxy.")"
    fi
    return 0
}

check_tools() {
    local cmd missing=()
    for cmd in curl openssl python3 ss; do
        command -v "$cmd" > /dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) && return 0
    report_fail "$(L "не найдены команды: ${missing[*]}" "commands not found: ${missing[*]}")"
    return 1
}

check_resolve_answers() {
    local discovered hy2_port key value name field label
    [[ -n "$(conf_get DOMAIN)" ]] || CONF[DOMAIN]=$(discover_domain)
    [[ "$(conf_get DOMAIN)" =~ $DOMAIN_RE ]] || return 1
    if [[ -z "$(conf_get CERT_FOLDER)" ]]; then
        value=$(discover_cert_folder)
        CONF[CERT_FOLDER]="${value:-$(conf_get DOMAIN)}"
    fi
    discovered=$(xui_discover)
    for key in "$(L "XHTTP_PATH:xhttp_path:путь XHTTP" "XHTTP_PATH:xhttp_path:XHTTP path")" "$(L "SUB_PATH:sub_path:путь подписки" "SUB_PATH:sub_path:subscription path")" "$(L "PANEL_PATH:web_base_path:путь панели" "PANEL_PATH:web_base_path:panel path")"; do
        IFS=: read -r name field label <<< "$key"
        value=$(normalize_path "$(json_get "$discovered" "$field")")
        if [[ -n "$value" && -n "$(conf_get "$name")" && "$value" != "$(normalize_path "$(conf_get "$name")")" ]]; then
            report_warn "$(L "файл ответов ${CONF_FILE}: ${label} $(normalize_path "$(conf_get "$name")"), в базе 3x-ui ${value}; проверка по базе, запуск без --check применит значение из файла ответов" "answers file ${CONF_FILE}: ${label} $(normalize_path "$(conf_get "$name")"), in the 3x-ui database ${value}; checking against the database, a run without --check applies the value from the answers file")"
        fi
        [[ -n "$value" || -z "$(conf_get "$name")" ]] && CONF[$name]="$value"
    done
    if [[ -z "$(conf_get XHTTP)" ]]; then
        CONF[XHTTP]=$([[ -n "$(conf_get XHTTP_PATH)" ]] && echo yes || echo no)
    fi
    value=$(json_get "$discovered" xhttp_port)
    [[ -n "$value" ]] && CONF[XHTTP_PORT]="$value"
    if [[ -z "$(conf_get HY2)" ]]; then
        hy2_port=$(json_get "$discovered" hy2_port)
        if [[ -n "$hy2_port" ]]; then
            CONF[HY2]=yes
        else
            CONF[HY2]=no
        fi
    fi
    log "$(L "Домен: $(conf_get DOMAIN), сертификат: $(cert_dir), XHTTP: $(xhttp_enabled && echo да || echo нет), Hysteria2: $([[ "$(hy2_port_answer)" != 0 ]] && echo "UDP/$(hy2_port_answer)" || echo нет), WARP: $(warp_enabled && echo да || echo нет)" "Domain: $(conf_get DOMAIN), certificate: $(cert_dir), XHTTP: $(xhttp_enabled && echo yes || echo no), Hysteria2: $([[ "$(hy2_port_answer)" != 0 ]] && echo "UDP/$(hy2_port_answer)" || echo no), WARP: $(warp_enabled && echo yes || echo no)")"
}

check_step() {
    local title="$1" name="$2"
    step "$title"
    if "check_${name}"; then
        report_ok "$(L "соответствует" "matches")"
    fi
    step_end
}

run_check() {
    LOG_FILE=/dev/null
    trap 'exit 2' INT TERM HUP
    emit "$(L "${SCRIPT_NAME} --check: проверка без изменений на сервере" "${SCRIPT_NAME} --check: check without changes on the server")"
    check_tools || exit 2
    load_py_helper
    conf_load
    if ! check_resolve_answers; then
        report_fail "$(L "домен не определён: нет файла ответов ${CONF_FILE} и server_name в конфигах nginx" "domain not determined: no answers file ${CONF_FILE} and no server_name in nginx configs")"
        exit 2
    fi
    STEP_TOTAL=$((5 + $(xui_has_config && echo 6 || echo 0) + $(ufw_present && echo 1 || echo 0)))
    emit ""
    check_step "$(L "nginx: порт 80" "nginx: port 80")" http
    check_step "$(L "Сертификат" "Certificate")" cert
    check_step "3x-ui" xui
    if xui_has_config; then
        check_step "nginx" nginx
        check_step "$(L "Панель 3x-ui" "3x-ui panel")" panel
        check_step "$(L "Подписка" "Subscription")" subscription
        check_step "$(L "Инбаунды" "Inbounds")" inbounds
        check_step "$(L "Хосты" "Hosts")" hosts
        check_step "$(L "Маршрутизация" "Routing")" routing
    else
        report_fail "$(L "в ${XUI_DB} нет инбаундов 3x-ui: проверки nginx, панели, подписки, инбаундов, Хостов и маршрутизации пропущены" "${XUI_DB} has no 3x-ui inbounds: nginx, panel, subscription, inbound, Host and routing checks are skipped")"
        emit ""
    fi
    check_step "ufw" ufw
    ufw_present && check_step "$(L "ufw: лишние правила" "ufw: extra rules")" ufw_cleanup
    step "$(L "Проверка" "Check")"
    final_checks
    step_end
    if [[ "$FAIL_COUNT" -eq 0 ]]; then
        log "$(L "Проверка завершена: ошибок нет." "Check complete: no errors.")"
        exit 0
    fi
    log "$(L "Проверка завершена: ошибок: ${FAIL_COUNT}." "Check complete, errors: ${FAIL_COUNT}.")"
    exit 1
}

main() {
    [[ -r "$CONF_FILE" ]] && conf_load
    parse_args "$@"
    if [[ "$(id -u)" -ne 0 ]]; then
        printf '%s\n' "Нужен root / Root is required: sudo bash ${0##*/}" >&2
        exit $((CHECK_ONLY == 1 ? 2 : 1))
    fi
    [[ "$CHECK_ONLY" -eq 1 ]] && run_check
    [[ "$UNINSTALL" -eq 1 ]] && run_uninstall
    init_log
    conf_load
    [[ -f "$CONF_FILE" ]] && conf_save
    resolve_language
    trap 'die "$(L "Прервано. Повторный запуск продолжит с текущего состояния." "Interrupted. A re-run continues from the current state.")"' INT TERM HUP
    STEP_TOTAL=12
    emit "$(L "${SCRIPT_NAME}, журнал: ${LOG_FILE}" "${SCRIPT_NAME}, log: ${LOG_FILE}")"
    ensure_packages
    load_py_helper

    resolve_install_mode
    resolve_base_answers
    converge "$(L "nginx: порт 80" "nginx: port 80")" http
    converge "$(L "Сертификат" "Certificate")" cert
    resolve_import
    resolve_xui_version
    converge "3x-ui" xui
    resolve_xhttp
    resolve_xhttp_port
    resolve_hy2
    resolve_warp
    resolve_paths
    resolve_credentials
    converge "nginx" nginx
    converge "$(L "Панель 3x-ui" "3x-ui panel")" panel
    converge "$(L "Подписка" "Subscription")" subscription
    resolve_client_name
    converge "$(L "Инбаунды" "Inbounds")" inbounds
    converge "$(L "Хосты" "Hosts")" hosts
    converge "$(L "Маршрутизация" "Routing")" routing
    converge "ufw" ufw
    step "$(L "Проверка" "Check")"
    final_checks || die "$(L "проверка не пройдена" "check failed")"
    step_end
    converge "$(L "ufw: лишние правила" "ufw: extra rules")" ufw_cleanup
    print_summary
}

main "$@"
