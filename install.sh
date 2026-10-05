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
XUI_INSTALL_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
ACME="/root/.acme.sh/acme.sh"
CERT_RENEW="/usr/local/sbin/cert-renew.sh"
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
NGINX_CONF_D="/etc/nginx/conf.d"
NGINX_REJECT_CONF="${NGINX_CONF_D}/00-reject-unknown-sni.conf"
NGINX_HTTP_REJECT_CONF="${NGINX_CONF_D}/00-http-reject.conf"
ACME_WEBROOT="/var/www/acme"

PUBLIC_TLS_PORT=443
HTTP_PORT=80
NGINX_ADDR="127.0.0.1"
NGINX_PORT=7443
REALITY_TARGET="${NGINX_ADDR}:${NGINX_PORT}"
XHTTP_PORT=8081
SUB_PORT=2096
PANEL_PORT=2053
XRAY_API_PORT=62789
HY2_DEFAULT_PORT=443
HY2_RANDOM_MIN=20000
HY2_RANDOM_MAX=60000
HY2_FORBIDDEN_PORTS=(51820 1194 500 4500 1723)
INTERNAL_PORTS=("$NGINX_PORT" "$XHTTP_PORT" "$PANEL_PORT" "$SUB_PORT" "$XRAY_API_PORT")

DOMAIN_RE='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'
EMAIL_RE='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
FOLDER_RE='^[A-Za-z0-9._-]+$'
PATH_RE='^/?[A-Za-z0-9_-]+/?$'
NAME_RE='^[A-Za-z0-9_-]+$'
USERNAME_RE='^[A-Za-z0-9_.-]{3,32}$'

CONF_KEYS=(DOMAIN CERT_FOLDER ACME_EMAIL XHTTP_PATH SUB_PATH PANEL_PATH XUI_USERNAME XUI_PASSWORD XUI_PASSWORD_HASH
    XUI_CREDENTIALS_PENDING HY2 HY2_PORT CLIENT_NAME)
declare -A CONF=()

RECONFIGURE=0
CHECK_ONLY=0
FAIL_COUNT=0
IMPORT_DB=""
IMPORTED_NOW=0
TWO_FA_RESET=0
DB_BACKUP=""
NGINX_BACKUP=""
PY_HELPER=""
FINAL_OK=1
STALE_PORTS=""

# ОБЩИЕ ФУНКЦИИ

log() {
    local line
    line="[$(date '+%F %T')] $*"
    printf '%s\n' "$line"
    printf '%s\n' "$line" >> "$LOG_FILE"
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

mismatch() {
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
        report_fail "$*"
    else
        log "  - $*"
    fi
}

mismatch_minor() {
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
        report_warn "$*"
    else
        log "  - $*"
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
        [[ -z "$line" ]] && continue
        if [[ "$CHECK_ONLY" -eq 1 ]]; then
            report_warn "$line"
        else
            log "  ! ${line}"
        fi
    done
}

template_differs() {
    local what="$1" file="$2"
    if [[ ! -e "$file" ]]; then
        mismatch "${what} ${file} отсутствует"
    else
        mismatch_minor "${what} ${file} отличается от шаблона установщика"
    fi
}

report_ok() {
    log "  [OK]   $*"
}

report_fail() {
    log "  [FAIL] $*"
    FINAL_OK=0
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

report_warn() {
    log "  [WARN] $*"
}

die() {
    log "$*"
    log "Остановлено. Подробности: ${LOG_FILE}. После исправления запустите скрипт снова."
    exit 1
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
    cat << EOF
Использование: sudo bash ${0##*/} [--reconfigure | --check]

  --reconfigure  задать вопросы заново (домен, email, пути, логин панели, Hysteria2)
  --check        только проверка, без изменений; код выхода 0 — ошибок нет, 1 — есть ошибки,
                 2 — проверку выполнить невозможно
EOF
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --reconfigure) RECONFIGURE=1 ;;
            --check) CHECK_ONLY=1 ;;
            -h | --help)
                print_usage
                exit 0
                ;;
            *)
                echo "Неизвестный параметр: $1" >&2
                print_usage >&2
                exit 1
                ;;
        esac
        shift
    done
    if [[ "$RECONFIGURE" -eq 1 && "$CHECK_ONLY" -eq 1 ]]; then
        echo "Параметры --reconfigure и --check несовместимы." >&2
        exit 2
    fi
}

# ВВОД

ask() {
    local -n _ask_out="$1"
    local _ask_prompt="$2" _ask_def="$3" _ask_regex="${4:-}" _ask_err="${5:-Неверный формат.}" _ask_value
    while true; do
        if [[ -n "$_ask_def" ]]; then
            read -r -p "${_ask_prompt} (Enter — ${_ask_def}): " _ask_value || die "Ввод прерван."
        else
            read -r -p "${_ask_prompt}: " _ask_value || die "Ввод прерван."
        fi
        _ask_value="${_ask_value:-$_ask_def}"
        if [[ -z "$_ask_value" ]]; then
            echo "  Поле обязательно."
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
    read -r -p "$2: " _opt_value || die "Ввод прерван."
    _opt_out="$_opt_value"
}

ask_yes_no() {
    local prompt="$1" def="$2" hint="[Y/n]" value
    [[ "$def" == "n" ]] && hint="[y/N]"
    while true; do
        read -r -p "${prompt} ${hint}: " value || die "Ввод прерван."
        value="${value:-$def}"
        case "${value,,}" in
            y | yes | д | да) return 0 ;;
            n | no | н | нет) return 1 ;;
        esac
        echo "  Ответьте y или n."
    done
}

ask_password() {
    local -n _pw_out="$1"
    local _pw_first _pw_second
    while true; do
        read -rs -p "$2 (Enter — случайный): " _pw_first || die "Ввод прерван."
        echo
        if [[ -z "$_pw_first" ]]; then
            _pw_out="$(random_string 'A-Za-z0-9' 16)"
            return 0
        fi
        if ((${#_pw_first} < 8)); then
            echo "  Пароль не короче 8 символов."
            continue
        fi
        read -rs -p "Повторите пароль: " _pw_second || die "Ввод прерван."
        echo
        if [[ "$_pw_first" != "$_pw_second" ]]; then
            echo "  Пароли не совпадают."
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
    log "Установка пакетов: ${missing[*]}."
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update -qq >> "$LOG_FILE" 2>&1 || ! apt-get install -y -qq "${missing[@]}" >> "$LOG_FILE" 2>&1; then
        die "Не удалось установить пакеты: ${missing[*]}."
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
XHTTP_PORT = 8081
XHTTP_LISTEN = "127.0.0.1"
FINGERPRINT = "firefox"
XHTTP_ALPN = ["h2"]
UDP_PROTOCOLS = {"hysteria", "hysteria2", "wireguard", "amneziawg", "tuic"}
LOCAL_LISTENS = {"127.0.0.1", "::1", "localhost"}
AUTO_TAG = re.compile(r"^(n\d+-)?in-\d+-(tcp|udp|tcpudp|any)(-\d+)?$")
KINDS = ("reality", "xhttp", "hy2")
KIND_NAMES = {"reality": "VLESS Reality", "xhttp": "VLESS XHTTP", "hy2": "Hysteria2"}
SETTING_DEFAULTS = {"subEnable": "true", "subPort": "2096", "webPort": "2053"}
INBOUND_FIELDS = ["id", "protocol", "port", "tag", "enable", "listen", "settings",
                  "stream_settings", "remark", "node_id", "origin_node_guid"]
CLIENT_KEYS = ("email", "enable", "subId", "limitIp", "totalGB", "expiryTime", "tgId",
               "comment", "reset", "group")


# ОБЩИЕ ФУНКЦИИ

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
    return f"id={ib['id']} tag={ib['tag']} порт={ib['port']} remark={ib['remark'] or '-'}"


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


def x25519(xray_bin):
    proc = subprocess.run([xray_bin, "x25519"], capture_output=True, text=True, timeout=15)
    if proc.returncode != 0:
        raise Failure(f"xray x25519: код {proc.returncode}: {proc.stderr.strip()}")
    private = re.search(r"^PrivateKey:\s*(\S+)", proc.stdout, re.M)
    public = re.search(r"^Password.*?:\s*(\S+)", proc.stdout, re.M)
    if not private or not public:
        raise Failure("не удалось разобрать вывод xray x25519")
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
            raise Failure(f"проверка целостности не пройдена: {check}")
        tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        conn.close()
        missing = {"inbounds", "settings"} - tables
        if missing:
            raise Failure(
                "нет таблиц 3x-ui (" + ", ".join(sorted(missing)) + "). Вероятно, база скопирована без checkpoint: "
                "на старом сервере выполните sqlite3 /etc/x-ui/x-ui.db \"PRAGMA wal_checkpoint(TRUNCATE);\" "
                "и скопируйте файл заново")
        print("ok")
    finally:
        shutil.rmtree(work, ignore_errors=True)


def cmd_import_prepare(db, xray_bin):
    conn, cur = open_db(db)
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    rekeyed = []
    for ib in read_inbounds(cur):
        if not (ib["own"] and ib["kind"] == "reality"):
            continue
        rs = ib["stream"].get("realitySettings")
        if not isinstance(rs, dict):
            continue
        private, public = x25519(xray_bin)
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
    emit({"rekeyed": rekeyed, "twofa_reset": twofa})


# ПРИВЕДЕНИЕ ИНБАУНДОВ

def fix_external_proxy(stream, domain, port, notes):
    entries = stream.get("externalProxy")
    if not isinstance(entries, list):
        return
    for entry in entries:
        if not isinstance(entry, dict) or not own_address(entry.get("dest"), domain):
            continue
        if entry.get("dest") != domain or as_int(entry.get("port")) != port:
            notes.append(f"externalProxy {entry.get('dest') or '<пусто>'}:{entry.get('port')} → {domain}:{port}")
            entry["dest"] = domain
            entry["port"] = port


def normalize_reality(ib, domain, target):
    stream = json.loads(json.dumps(ib["stream"]))
    notes, fields = [], {}
    rs = stream.get("realitySettings")
    if not isinstance(rs, dict):
        raise Failure(f"{describe(ib)}: security=reality без realitySettings")
    current = rs.get("target") or rs.get("dest") or ""
    if current != target or ("dest" in rs and rs["dest"] != target):
        notes.append(f"target {current or '<пусто>'} → {target}")
        rs["target"] = target
        if "dest" in rs:
            rs["dest"] = target
    if rs.get("serverNames") != [domain]:
        notes.append(f"serverNames {rs.get('serverNames') or []} → [{domain}]")
        rs["serverNames"] = [domain]
    inner = rs.get("settings")
    if isinstance(inner, dict) and inner.get("serverName") not in (None, "", domain):
        notes.append(f"settings.serverName {inner['serverName']} → {domain}")
        inner["serverName"] = domain
    if as_int(rs.get("xver")) != 0:
        notes.append(f"xver {rs.get('xver')} → 0")
        rs["xver"] = 0
    for key in [k for k in rs if k.lower().startswith("limitfallback")]:
        notes.append(f"{key} удалён")
        del rs[key]
    if (stream.get("network") or "").lower() == "raw":
        notes.append("network raw → tcp")
        stream["network"] = "tcp"
    fix_external_proxy(stream, domain, REALITY_PORT, notes)
    if (ib["listen"] or "").strip():
        notes.append(f"listen {ib['listen']} → пусто")
        fields["listen"] = ""
    return stream, fields, notes


def normalize_xhttp(ib, domain, path):
    stream = json.loads(json.dumps(ib["stream"]))
    notes, fields = [], {}
    xs = stream.get("xhttpSettings")
    if not isinstance(xs, dict):
        xs = {}
        stream["xhttpSettings"] = xs
    if xs.get("path") != path:
        notes.append("путь XHTTP изменён")
        xs["path"] = path
    if xs.get("mode") != "stream-one":
        notes.append(f"mode {xs.get('mode') or '<пусто>'} → stream-one")
        xs["mode"] = "stream-one"
    if (stream.get("security") or "none") != "none":
        notes.append(f"security {stream.get('security')} → none")
        stream["security"] = "none"
        stream.pop("tlsSettings", None)
        stream.pop("realitySettings", None)
    fix_external_proxy(stream, domain, REALITY_PORT, notes)
    if (ib["listen"] or "").strip() != XHTTP_LISTEN:
        notes.append(f"listen {ib['listen'] or '<пусто>'} → {XHTTP_LISTEN}")
        fields["listen"] = XHTTP_LISTEN
    if ib["port"] != XHTTP_PORT:
        notes.append(f"порт {ib['port']} → {XHTTP_PORT}")
        fields["port"] = XHTTP_PORT
    return stream, fields, notes


def normalize_hy2(ib, domain, cert_folder, port):
    stream = json.loads(json.dumps(ib["stream"]))
    notes, fields = [], {}
    fullchain = f"/etc/ssl/{cert_folder}/fullchain.pem"
    privkey = f"/etc/ssl/{cert_folder}/privkey.pem"
    if (stream.get("security") or "") != "tls":
        notes.append(f"security {stream.get('security') or '<пусто>'} → tls")
        stream["security"] = "tls"
    tls = stream.get("tlsSettings")
    if not isinstance(tls, dict):
        tls = {}
        stream["tlsSettings"] = tls
    if tls.get("serverName") != domain:
        notes.append(f"serverName {tls.get('serverName') or '<пусто>'} → {domain}")
        tls["serverName"] = domain
    certs = tls.get("certificates")
    if not isinstance(certs, list) or not certs or not all(isinstance(c, dict) for c in certs):
        certs = [{}]
    wanted = []
    for cert in certs:
        cert = {k: v for k, v in cert.items() if k not in ("certificate", "key")}
        cert["certificateFile"] = fullchain
        cert["keyFile"] = privkey
        wanted.append(cert)
    if wanted != tls.get("certificates"):
        notes.append(f"сертификат → /etc/ssl/{cert_folder}/")
        tls["certificates"] = wanted
    if tls.get("alpn") != ["h3"]:
        notes.append(f"alpn {tls.get('alpn')} → ['h3']")
        tls["alpn"] = ["h3"]
    hs = stream.get("hysteriaSettings")
    if not isinstance(hs, dict):
        hs = {}
        stream["hysteriaSettings"] = hs
    if as_int(hs.get("version")) != 2:
        notes.append(f"версия Hysteria {hs.get('version')} → 2")
        hs["version"] = 2
    masquerade = hs.get("masquerade")
    wanted_url = f"https://{domain}:{REALITY_PORT}"
    if isinstance(masquerade, dict) and masquerade.get("url") and masquerade["url"] != wanted_url:
        notes.append(f"masquerade {masquerade['url']} → {wanted_url}")
        masquerade["url"] = wanted_url
    fix_external_proxy(stream, domain, port, notes)
    if ib["port"] != port:
        notes.append(f"порт {ib['port']} → {port}")
        fields["port"] = port
    return stream, fields, notes


def unique_tag(port, transport, taken):
    base = f"in-{port}-{transport}"
    if base not in taken:
        return base
    for n in range(2, 100):
        candidate = f"{base}-{n}"
        if candidate not in taken:
            return candidate
    raise Failure(f"нет свободного тега для порта {port}")


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
    for key in ("listen", "port", "tag", "enable"):
        if key in fields:
            assignments.append(f"{key}=?")
            values.append(fields[key])
    if assignments:
        cur.execute(f"UPDATE inbounds SET {', '.join(assignments)} WHERE id=?", (*values, ib_id))


def cmd_inbounds(mode, db, domain, cert_folder, xhttp_path, hy2_port, target):
    hy2_port = as_int(hy2_port)
    conn, cur = open_db(db)
    inbounds = read_inbounds(cur)
    report = {"fatal": [], "problems": [], "warnings": [], "changes": [], "missing": [],
              "reality": None, "xhttp": None, "hy2": None, "renamed": {}, "stale_ports": []}
    selected = {}
    for kind in KINDS:
        found = own_active(inbounds, kind)
        if len(found) > 1:
            report["fatal"].append(f"{KIND_NAMES[kind]}: включено несколько инбаундов, оставьте один: "
                                   + "; ".join(describe(ib) for ib in found))
        elif found:
            selected[kind] = found[0]
            summary = {"id": found[0]["id"], "tag": found[0]["tag"], "port": found[0]["port"]}
            if kind == "reality":
                rs = found[0]["stream"].get("realitySettings") or {}
                summary["target"] = rs.get("target") or rs.get("dest") or ""
            report[kind] = summary
    wanted = ["reality", "xhttp"] + (["hy2"] if hy2_port else [])
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
            plans.append(("port", ib, None, port_fields, [f"порт {ib['port']} → {REALITY_PORT}"]))
    if "xhttp" in selected:
        ib = selected["xhttp"]
        stream, fields, notes = normalize_xhttp(ib, domain, xhttp_path)
        plans.append(("main", ib, stream, fields, notes))
    if "hy2" in selected and hy2_port:
        ib = selected["hy2"]
        stream, fields, notes = normalize_hy2(ib, domain, cert_folder, hy2_port)
        plans.append(("main", ib, stream, fields, notes))
    chosen = {ib["id"] for ib in selected.values()}
    for ib in own_active(inbounds):
        if ib["id"] in chosen:
            continue
        if ib["transport"] == "tcp" and ib["public"]:
            plans.append(("main", ib, None, {"enable": 0},
                          [f"выключен: публичный TCP-порт кроме {REALITY_PORT} не допускается"]))
        elif ib["transport"] == "udp" and ib["public"]:
            report["warnings"].append(f"{describe(ib)}: UDP-инбаунд оставлен включённым, но его порт в ufw не открывается")

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
        return {"address": domain, "port": REALITY_PORT, "security": "same", "sni": "",
                "override_sni_from_address": 0}
    if kind == "xhttp":
        return {"address": domain, "port": REALITY_PORT, "security": "tls", "fingerprint": FINGERPRINT, "alpn": XHTTP_ALPN}
    return {"address": domain, "port": hy2_port, "security": "same"}


def same_value(key, current, wanted):
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
    return value if value not in (None, "") else "<пусто>"


def cmd_hosts(mode, db, domain, hy2_port):
    hy2_port = as_int(hy2_port)
    conn, cur = open_db(db)
    inbounds = read_inbounds(cur)
    rows, present = host_rows(cur)
    report = {"problems": [], "changes": [], "missing": [], "foreign": [], "fixable": 0}
    if rows is None:
        report["problems"].append("в базе нет таблицы hosts")
        conn.close()
        emit(report)
        return
    for kind in KINDS:
        found = own_active(inbounds, kind)
        if len(found) != 1 or (kind == "hy2" and not hy2_port):
            continue
        ib = found[0]
        wanted = desired_host(kind, domain, hy2_port)
        own_hosts = []
        for host in rows:
            if host["inbound_id"] != ib["id"]:
                continue
            if own_address(host["address"], domain):
                own_hosts.append(host)
            else:
                report["foreign"].append(f"{KIND_NAMES[kind]}: Хост {host['address']}:{host['port']} оставлен без изменений")
        if not own_hosts:
            report["missing"].append({"kind": kind, "inbound_id": ib["id"], **wanted})
            report["problems"].append(f"{KIND_NAMES[kind]}: нет Хоста {domain}:{wanted['port']}")
            continue
        for host in own_hosts:
            diffs = {k: v for k, v in wanted.items() if k in present and not same_value(k, host.get(k), v)}
            if not diffs:
                continue
            text = ", ".join(f"{k} {host_value(k, host.get(k))} → {host_value(k, v)}" for k, v in diffs.items())
            report["problems"].append(f"{KIND_NAMES[kind]}: Хост id={host['id']}: {text}")
            report["fixable"] += 1
            if mode == "fix":
                assignments = ", ".join(f"{k}=?" for k in diffs)
                values = [json.dumps(v) if isinstance(v, list) else v for v in diffs.values()]
                cur.execute(f"UPDATE hosts SET {assignments} WHERE id=?", (*values, host["id"]))
                report["changes"].append(f"{KIND_NAMES[kind]}: Хост id={host['id']}: {text}")
    if mode == "fix":
        conn.commit()
    conn.close()
    emit(report)


# НАСТРОЙКИ ПАНЕЛИ

def cmd_settings_get(db, key):
    conn, cur = open_db(db)
    try:
        row = cur.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    except sqlite3.OperationalError:
        row = None
    conn.close()
    print(row[0] if row and row[0] is not None else SETTING_DEFAULTS.get(key, ""))


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
            print(f"{key}: {current or '<пусто>'} → {wanted or '<пусто>'}")


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

    def call(self, path, body=None, form=None):
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
            with self.opener.open(request, timeout=20) as response:
                parsed = json.loads(response.read().decode())
        except urllib.error.HTTPError as e:
            raise Failure(f"{path}: HTTP {e.code}: {e.read().decode(errors='replace')[:300]}")
        except (urllib.error.URLError, OSError, ValueError) as e:
            raise Failure(f"{path}: {e}")
        if not parsed.get("success"):
            raise Failure(f"{path}: {parsed.get('msg') or 'ошибка'}")
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
        "remark": "Reality-VLESS", "listen": "", "port": REALITY_PORT, "protocol": "vless",
        "settings": {"clients": clients, "decryption": "none", "fallbacks": []},
        "streamSettings": {
            "network": "tcp", "security": "reality",
            "realitySettings": {
                "show": False, "target": p["target"], "xver": 0,
                "serverNames": [p["domain"]], "privateKey": private, "shortIds": short_ids(),
                "settings": {"publicKey": public, "fingerprint": FINGERPRINT, "spiderX": "/"},
            },
        },
    }


def xhttp_inbound(p, clients):
    return {
        "remark": "XHTTP-VLESS", "listen": XHTTP_LISTEN, "port": XHTTP_PORT, "protocol": "vless",
        "settings": {"clients": clients, "decryption": "none", "fallbacks": []},
        "streamSettings": {
            "network": "xhttp", "security": "none",
            "xhttpSettings": {"path": p["xhttp_path"], "mode": "stream-one", "host": ""},
        },
    }


def hy2_inbound(p, clients):
    return {
        "remark": "Hysteria2", "listen": "", "port": p["hy2_port"], "protocol": "hysteria",
        "settings": {"clients": clients},
        "streamSettings": {
            "network": "hysteria", "security": "tls",
            "hysteriaSettings": {
                "version": 2, "udpIdleTimeout": 300,
                "masquerade": {"type": "proxy", "url": f"https://{p['domain']}:{REALITY_PORT}", "rewriteHost": True},
            },
            "tlsSettings": {
                "serverName": p["domain"], "minVersion": "1.2", "maxVersion": "1.3", "alpn": ["h3"],
                "certificates": [{
                    "certificateFile": f"/etc/ssl/{p['cert_folder']}/fullchain.pem",
                    "keyFile": f"/etc/ssl/{p['cert_folder']}/privkey.pem",
                }],
            },
            "finalmask": {"tcp": [], "udp": [{"type": "salamander",
                                              "settings": {"password": secrets.token_urlsafe(16)}}]},
        },
    }


def cmd_create_missing(base, token, db, xray_bin, domain, cert_folder, xhttp_path, hy2_port, target, client_name):
    p = {"domain": domain, "cert_folder": cert_folder, "xhttp_path": xhttp_path,
         "hy2_port": as_int(hy2_port), "target": target}
    conn, cur = open_db(db)
    inbounds = read_inbounds(cur)
    records = client_records(cur)
    conn.close()
    selected = {kind: own_active(inbounds, kind) for kind in KINDS}
    wanted = ["reality", "xhttp"] + (["hy2"] if p["hy2_port"] else [])
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
                         "sniffing": json.dumps({"enabled": False, "destOverride": ["http", "tls", "quic"]})})
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
        body = {"inboundIds": [item["inbound_id"]], "hosts": [item["address"]], "remark": "main",
                "port": item["port"], "security": item["security"]}
        if item.get("fingerprint"):
            body["fingerprint"] = item["fingerprint"]
        if item.get("alpn"):
            body["alpn"] = item["alpn"]
        api.call("panel/api/hosts/add", body=body)
        added.append(f"{KIND_NAMES[item['kind']]}: {item['address']}:{item['port']}")
    emit({"added": added})


# МАРШРУТИЗАЦИЯ И CONFIG.JSON

def is_ru_block(rule):
    return rule.get("outboundTag") == "blocked" and rule.get("ip") == ["geoip:ru"]


def is_udp443_block(rule):
    return (rule.get("outboundTag") == "blocked" and (rule.get("network") or "").lower() == "udp"
            and str(rule.get("port")) == "443")


def cmd_config_summary(path):
    with open(path) as f:
        config = json.load(f)
    result = {"reality": None, "xhttp": None, "hy2": None}
    for ib in config.get("inbounds") or []:
        stream = ib.get("streamSettings") or {}
        kind = kind_of(ib.get("protocol"), stream)
        if kind == "other" or result[kind] is not None:
            continue
        entry = {"tag": ib.get("tag") or "", "port": ib.get("port"), "listen": ib.get("listen") or ""}
        if kind == "reality":
            rs = stream.get("realitySettings") or {}
            entry["target"] = str(rs.get("target") or rs.get("dest") or "")
            entry["server_names"] = rs.get("serverNames") or []
            entry["limit_fallback"] = [k for k in rs if k.lower().startswith("limitfallback")]
        result[kind] = entry
    rules = (config.get("routing") or {}).get("rules") or []
    udp_rules = [r for r in rules if is_udp443_block(r)]
    expected = sorted({result[k]["tag"] for k in ("reality", "xhttp") if result[k]})
    actual = [sorted(set(r.get("inboundTag") or [])) for r in udp_rules]
    result["ru_block"] = any(is_ru_block(r) for r in rules)
    result["udp443_expected"] = expected
    result["udp443_actual"] = actual
    result["udp443_ok"] = len(actual) == 1 and actual[0] == expected
    emit(result)


def cmd_routing_apply(base, token, reality_tag, xhttp_tag):
    api = Api(base, token)
    template = json.loads(api.call("panel/api/xray/", form={}))["xraySetting"]
    rules = template.setdefault("routing", {}).setdefault("rules", [])
    changes = []
    if not any(is_ru_block(r) for r in rules):
        rules.append({"type": "field", "ip": ["geoip:ru"], "outboundTag": "blocked"})
        changes.append("добавлено geoip:ru → blocked")
    tags = sorted({reality_tag, xhttp_tag})
    old = [r for r in rules if is_udp443_block(r)]
    if len(old) != 1 or sorted(set(old[0].get("inboundTag") or [])) != tags:
        rules[:] = [r for r in rules if not is_udp443_block(r)]
        rules.append({"type": "field", "network": "udp", "port": "443", "inboundTag": tags, "outboundTag": "blocked"})
        changes.append(f"UDP/443 → blocked для {tags}")
    if changes:
        api.call("panel/api/xray/update", form={"xraySetting": json.dumps(template)})
    emit({"changes": changes})


def cmd_routing_test(base, token, reality_tag, xhttp_tag):
    api = Api(base, token)

    def blocked(tag, ip, network):
        obj = api.call("panel/api/xray/routeTest",
                       form={"inboundTag": tag, "ip": ip, "port": "443", "network": network})
        return bool(obj and obj.get("matched") and obj.get("outboundTag") == "blocked")

    probe = "probe-" + "".join(c for c in reality_tag + xhttp_tag if c.isalnum())
    checks = {
        "Reality UDP/443 блокируется": blocked(reality_tag, "8.8.8.8", "udp"),
        "XHTTP UDP/443 блокируется": blocked(xhttp_tag, "8.8.8.8", "udp"),
        "другой инбаунд UDP/443 не блокируется": not blocked(probe, "8.8.8.8", "udp"),
        "TCP/443 не блокируется": not blocked(reality_tag, "8.8.8.8", "tcp"),
        "geoip:ru блокируется": blocked(reality_tag, "77.88.8.8", "tcp"),
    }
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


# ЗАПУСК

COMMANDS = {
    "own-count": cmd_own_count,
    "discover": cmd_discover,
    "validate-db": cmd_validate_db,
    "import-prepare": cmd_import_prepare,
    "inbounds": cmd_inbounds,
    "hosts": cmd_hosts,
    "settings-get": cmd_settings_get,
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
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print("неизвестная команда")
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
    python3 -c "$PY_HELPER" "$@"
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

udp_listening() {
    [[ -n "$(ss -Hulnp "sport = :$1" 2> /dev/null)" ]]
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
        sshd -T 2> /dev/null | awk '$1 == "port" {print $2}'
        ss -Htlnp 2> /dev/null | awk '/"sshd"/ {n = split($4, a, ":"); print a[n]}'
    } | grep -E '^[0-9]+$' | sort -un)
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
    out=$(echo | timeout 6 openssl s_client -connect "$REALITY_TARGET" -servername "$domain" -tls1_3 -alpn h2 2>&1 | tr -d '\0')
    grep -qa 'ALPN protocol: h2' <<< "$out" || return 1
    grep -a 'subject=' <<< "$out" | grep -qF "$domain" || return 1
    [[ "$(tls_probe "$NGINX_ADDR" "$NGINX_PORT" -)" == reject ]]
}

http_code() {
    local url="$1" resolve="$2"
    curl -sk --noproxy '*' --max-time 10 --resolve "$resolve" -o /dev/null -w '%{http_code}' "$url"
}

curl_exit_code() {
    curl -s --noproxy '*' --max-time 10 -o /dev/null "$@" > /dev/null 2>&1
    printf '%s' "$?"
}

# 3X-UI: СЛУЖБА, БАЗА, API

xray_bin() {
    local arch
    case "$(uname -m)" in
        x86_64 | amd64) arch=amd64 ;;
        aarch64 | arm64) arch=arm64 ;;
        *) return 1 ;;
    esac
    [[ -x "/usr/local/x-ui/bin/xray-linux-${arch}" ]] || return 1
    printf '%s' "/usr/local/x-ui/bin/xray-linux-${arch}"
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

setting_get() {
    py settings-get "$XUI_DB" "$1"
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
        log "x-ui не запустился. Журнал x-ui записан в лог."
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
    cp "$XUI_DB" "$DB_BACKUP" || die "Не удалось сделать резервную копию базы ${XUI_DB}."
    log "Резервная копия базы: ${DB_BACKUP}"
}

api_token() {
    local out token
    out=$("$XUI_BIN" setting -getApiToken -tokenName "$SCRIPT_NAME" 2>&1)
    token=$(printf '%s\n' "$out" | grep -Eo 'apiToken: *[^ ]+' | awk '{print $2}')
    if [[ -z "$token" ]]; then
        log "Не удалось получить API-токен панели."
        log_quiet "$out"
        return 1
    fi
    printf '%s' "$token"
}

api_base() {
    printf 'http://%s:%s%s/' "$NGINX_ADDR" "$PANEL_PORT" "$(conf_get PANEL_PATH)"
}

hy2_port_answer() {
    if [[ "$(conf_get HY2)" == yes ]]; then
        conf_get HY2_PORT
    else
        printf '0'
    fi
}

# ПРИВЕДЕНИЕ К ЦЕЛЕВОМУ СОСТОЯНИЮ

converge() {
    local title="$1" name="$2"
    log ""
    log "== ${title} =="
    if "check_${name}"; then
        log "Соответствует, изменений нет."
        return 0
    fi
    "apply_${name}" || die "${title}: не удалось привести к целевому состоянию."
    log "Повторная проверка."
    "check_${name}" || die "${title}: после изменений проверка не пройдена."
    log "Готово."
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

resolve_base_answers() {
    resolve_answer DOMAIN "Домен сервера (например srv1.example.com)" "$(discover_domain)" \
        "$DOMAIN_RE" "Некорректный домен. Пример: srv1.example.com"
    resolve_answer CERT_FOLDER "Папка сертификата в /etc/ssl/" "$(conf_get DOMAIN)" \
        "$FOLDER_RE" "Только буквы, цифры, точка, дефис, подчёркивание."
    resolve_answer ACME_EMAIL "Email для Let's Encrypt" "$(discover_email)" \
        "$EMAIL_RE" "Некорректный email. Пример: you@example.com"
}

resolve_import() {
    local path reason
    IMPORT_DB=""
    if xui_has_config && [[ "$RECONFIGURE" -eq 0 ]]; then
        return 0
    fi
    while true; do
        if xui_has_config; then
            ask_optional path "Путь к x-ui.db для переноса (Enter — оставить текущую базу)"
        else
            ask_optional path "Путь к x-ui.db для переноса с другого сервера (Enter — установка с нуля)"
        fi
        [[ -z "$path" ]] && return 0
        if [[ ! -f "$path" ]]; then
            echo "  Файл не найден."
            continue
        fi
        if [[ "$(head -c 15 "$path" 2> /dev/null)" != "SQLite format 3" ]]; then
            echo "  Это не база SQLite."
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
        if [[ "$discovered" =~ ^/[A-Za-z0-9_-]+$ ]]; then
            conf_set "$key" "$discovered"
            log "${prompt}: взят из базы 3x-ui."
            return 0
        fi
    fi
    [[ -n "$current" && "$RECONFIGURE" -eq 0 ]] && return 0
    while true; do
        if [[ -n "$current" ]]; then
            ask_optional value "${prompt} (Enter — оставить текущий)"
            value="${value:-$current}"
        else
            ask_optional value "${prompt} (Enter — случайная строка)"
            value="${value:-$(random_string 'a-z0-9' 14)}"
        fi
        if [[ ! "$value" =~ $PATH_RE ]]; then
            echo "  Разрешены буквы, цифры, дефис и подчёркивание."
            continue
        fi
        conf_set "$key" "$(normalize_path "$value")"
        return 0
    done
}

resolve_paths() {
    local discovered="{}" key
    xui_has_config && discovered=$(xui_discover)
    resolve_path XHTTP_PATH "Секретный путь XHTTP" "$(json_get "$discovered" xhttp_path)"
    resolve_path SUB_PATH "Секретный путь подписки" "$(json_get "$discovered" sub_path)"
    resolve_path PANEL_PATH "Секретный путь панели" "$(json_get "$discovered" web_base_path)"
    if [[ "$(conf_get XHTTP_PATH)" == "$(conf_get SUB_PATH)" || "$(conf_get XHTTP_PATH)" == "$(conf_get PANEL_PATH)" \
        || "$(conf_get SUB_PATH)" == "$(conf_get PANEL_PATH)" ]]; then
        log "Пути XHTTP, подписки и панели должны различаться."
        for key in XHTTP_PATH SUB_PATH PANEL_PATH; do
            CONF[$key]=""
        done
        conf_save
        resolve_paths_again
    fi
}

resolve_paths_again() {
    resolve_path XHTTP_PATH "Секретный путь XHTTP" ""
    resolve_path SUB_PATH "Секретный путь подписки" ""
    resolve_path PANEL_PATH "Секретный путь панели" ""
    if [[ "$(conf_get XHTTP_PATH)" == "$(conf_get SUB_PATH)" || "$(conf_get XHTTP_PATH)" == "$(conf_get PANEL_PATH)" \
        || "$(conf_get SUB_PATH)" == "$(conf_get PANEL_PATH)" ]]; then
        die "Пути XHTTP, подписки и панели совпадают."
    fi
}

resolve_credentials() {
    local username password
    [[ -n "$(conf_get XUI_CREDENTIALS_PENDING)" ]] && return 0
    if [[ "$RECONFIGURE" -eq 1 || "$IMPORTED_NOW" -eq 1 ]]; then
        if [[ -n "$(conf_get XUI_USERNAME)" ]] || xui_has_config; then
            ask_yes_no "Задать новый логин и пароль панели?" n || return 0
        fi
    else
        [[ -n "$(conf_get XUI_USERNAME)" ]] && return 0
        xui_has_config && return 0
    fi
    ask_optional username "Логин панели (Enter — случайный)"
    [[ -z "$username" ]] && username="admin$(random_string 'a-z0-9' 6)"
    [[ "$username" =~ $USERNAME_RE ]] || die "Логин: 3–32 символа (буквы, цифры, точка, дефис, подчёркивание)."
    ask_password password "Пароль панели"
    conf_set XUI_USERNAME "$username"
    conf_set XUI_PASSWORD "$password"
    conf_unset XUI_PASSWORD_HASH
    conf_set XUI_CREDENTIALS_PENDING yes
}

# ПОРТ HYSTERIA2

hy2_port_invalid() {
    local port="$1" own="$2" p
    if [[ ! "$port" =~ ^[0-9]{1,5}$ ]]; then
        echo "нужен номер порта"
        return 0
    fi
    port=$((10#$port))
    if ((port < 1 || port > 65535)); then
        echo "допустимо 1–65535"
        return 0
    fi
    for p in "${HY2_FORBIDDEN_PORTS[@]}"; do
        if ((port == p)); then
            echo "${port} — порт по умолчанию другого VPN-протокола"
            return 0
        fi
    done
    if ((port < 1024 && port != 443)); then
        echo "порты 1–1023 запрещены, кроме 443"
        return 0
    fi
    for p in "${INTERNAL_PORTS[@]}" $(ssh_ports); do
        if ((port == p)); then
            echo "порт ${port} занят службой сервера"
            return 0
        fi
    done
    if [[ "$port" != "$own" ]] && udp_listening "$port"; then
        echo "UDP/${port} уже занят"
        return 0
    fi
    return 1
}

random_hy2_port() {
    local own="$1" port i
    for ((i = 0; i < 50; i++)); do
        port=$(shuf -i "${HY2_RANDOM_MIN}-${HY2_RANDOM_MAX}" -n 1)
        hy2_port_invalid "$port" "$own" > /dev/null || {
            printf '%s' "$port"
            return 0
        }
    done
    return 1
}

ask_hy2_port() {
    local -n _hy2_out="$1"
    local _hy2_own="$2" _hy2_value _hy2_reason
    while true; do
        read -r -p "Порт Hysteria2 (UDP) (Enter — ${HY2_DEFAULT_PORT}, r — случайный ${HY2_RANDOM_MIN}–${HY2_RANDOM_MAX}): " _hy2_value || die "Ввод прерван."
        _hy2_value="${_hy2_value:-$HY2_DEFAULT_PORT}"
        if [[ "${_hy2_value,,}" == r ]]; then
            _hy2_value=$(random_hy2_port "$_hy2_own") || die "Не удалось подобрать свободный порт."
            echo "  Выбран порт ${_hy2_value}."
        fi
        if _hy2_reason=$(hy2_port_invalid "$_hy2_value" "$_hy2_own"); then
            echo "  Не подходит: ${_hy2_reason}."
            continue
        fi
        _hy2_out=$((10#$_hy2_value))
        return 0
    done
}

resolve_hy2() {
    local current port reason
    current=$(json_get "$(xui_discover)" hy2_port)
    if [[ "$RECONFIGURE" -eq 0 ]]; then
        case "$(conf_get HY2)" in
            yes) [[ -n "$(conf_get HY2_PORT)" ]] && return 0 ;;
            no) [[ -z "$current" ]] && return 0 ;;
        esac
    fi
    if [[ -n "$current" ]]; then
        if ask_yes_no "Hysteria2 сейчас на UDP/${current}. Оставить этот порт?" y; then
            if reason=$(hy2_port_invalid "$current" "$current"); then
                echo "  UDP/${current} не подходит: ${reason}."
                ask_hy2_port port "$current"
            else
                port="$current"
            fi
        else
            ask_hy2_port port "$current"
        fi
        conf_set HY2 yes
        conf_set HY2_PORT "$port"
        return 0
    fi
    if ask_yes_no "Добавить Hysteria2 (UDP)?" y; then
        ask_hy2_port port ""
        conf_set HY2 yes
        conf_set HY2_PORT "$port"
    else
        conf_set HY2 no
        conf_unset HY2_PORT
    fi
}

resolve_client_name() {
    local name
    [[ "$(json_get "$(xui_discover)" has_clients)" == true ]] && return 0
    [[ -n "$(conf_get CLIENT_NAME)" && "$RECONFIGURE" -eq 0 ]] && return 0
    name=$(conf_get CLIENT_NAME)
    ask name "Имя первого клиента" "${name:-client1}" "$NAME_RE" "Разрешены буквы, цифры, дефис и подчёркивание."
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
        mismatch "nginx не установлен"
        return 1
    fi
    render_nginx_http_reject | cmp -s - "$NGINX_HTTP_REJECT_CONF" || {
        template_differs "антискан ${HTTP_PORT}/tcp" "$NGINX_HTTP_REJECT_CONF"
        rc=1
    }
    render_nginx_http_site | cmp -s - "$(nginx_http_site_file)" || {
        template_differs "сайт на ${HTTP_PORT}" "$(nginx_http_site_file)"
        rc=1
    }
    [[ -e "${NGINX_SITES_ENABLED}/default" ]] && {
        mismatch "подключён сайт default"
        rc=1
    }
    [[ -n "$(nginx_stale_http_sites)" ]] && {
        mismatch "лишний сайт на ${HTTP_PORT}: $(nginx_stale_http_sites | tr '\n' ' ')"
        rc=1
    }
    [[ -d "$(acme_challenge_dir)" ]] || {
        mismatch "нет каталога $(acme_challenge_dir)"
        rc=1
    }
    if ! systemctl is-active --quiet nginx; then
        mismatch "nginx не запущен"
        return 1
    fi
    while IFS= read -r addr; do
        nginx_addresses | grep -qxF "$addr" || {
            mismatch "nginx не слушает ${addr}"
            rc=1
        }
    done < <(nginx_http_addresses)
    challenge_served 127.0.0.1 || {
        mismatch "http://$(conf_get DOMAIN)/.well-known/acme-challenge/ не отдаёт файлы из $(acme_challenge_dir)"
        rc=1
    }
    code=$(curl_exit_code "http://127.0.0.1/")
    [[ "$code" == 52 ]] || {
        mismatch "http://127.0.0.1/: curl exit ${code}, ожидался 52 (закрытие без ответа)"
        rc=1
    }
    if ufw_active && ! ufw_allows "${HTTP_PORT}/tcp"; then
        mismatch "нет правила ufw ${HTTP_PORT}/tcp"
        rc=1
    fi
    return "$rc"
}

nginx_write_http_files() {
    local dir f
    dir=$(acme_challenge_dir)
    rm -f "${NGINX_SITES_ENABLED}/default"
    while IFS= read -r f; do
        [[ -n "$f" ]] && rm -f "$f" && log "  удалён ${f}"
    done < <(nginx_stale_http_sites)
    mkdir -p "$dir" && chmod 755 "$ACME_WEBROOT" "${ACME_WEBROOT}/.well-known" "$dir"
    render_nginx_http_reject > "$NGINX_HTTP_REJECT_CONF"
    render_nginx_http_site > "$(nginx_http_site_file)"
}

apply_http() {
    local others foreign stale
    others=$(tcp_listeners "$HTTP_PORT" | grep -v '"nginx"')
    if [[ -n "$others" ]]; then
        log "Порт ${HTTP_PORT}/tcp занят другим процессом:"
        log_lines "  " <<< "$others"
        return 1
    fi
    install_nginx || return 1
    mapfile -t stale < <(nginx_stale_http_sites)
    foreign=$(nginx_foreign_listeners "$HTTP_PORT" "$NGINX_HTTP_REJECT_CONF" "$(nginx_http_site_file)" "${stale[@]}")
    if [[ -n "$foreign" ]]; then
        log "Порт ${HTTP_PORT} заняли другие конфиги nginx:"
        log_lines "  " <<< "$foreign"
        return 1
    fi
    nginx_apply nginx_write_http_files nginx_listens_http || return 1
    if ufw_present && ! ufw_allows "${HTTP_PORT}/tcp"; then
        ufw allow "${HTTP_PORT}/tcp" comment "$SCRIPT_NAME" > /dev/null 2>&1 && log "  ufw: добавлено ${HTTP_PORT}/tcp."
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
        log "Нет строки Le_Webroot в ${conf}."
        return 1
    fi
    backup="${conf}.bak-$(date +%F-%H%M%S)"
    cp -p "$conf" "$backup" || return 1
    sed -i "s|^Le_Webroot=.*|Le_Webroot='${ACME_WEBROOT}'|" "$conf"
    if ! acme_webroot_set; then
        log "Не удалось записать Le_Webroot='${ACME_WEBROOT}' в ${conf}."
        return 1
    fi
    log "acme.sh: Le_Webroot='${ACME_WEBROOT}' в ${conf}, копия: ${backup}."
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
        mismatch "сертификата $(cert_dir)/fullchain.pem для $(conf_get DOMAIN) нет, он истекает в течение 30 дней или не совпадает с ключом"
        rc=1
    fi
    acme_webroot_set || {
        mismatch "acme.sh не в режиме webroot: нет строки Le_Webroot='${ACME_WEBROOT}' в $(acme_domain_conf)"
        rc=1
    }
    render_cert_renew | cmp -s - "$CERT_RENEW" || {
        template_differs "скрипт продления" "$CERT_RENEW"
        rc=1
    }
    renew_cron_present || {
        mismatch "нет задачи cron для ${CERT_RENEW}"
        rc=1
    }
    acme_cron_present && {
        mismatch "в cron есть задача acme.sh (продление идёт через ${CERT_RENEW})"
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
        log "Установка acme.sh."
        curl -fsSL https://get.acme.sh | sh -s email="$(conf_get ACME_EMAIL)" >> "$LOG_FILE" 2>&1
        [[ -x "$ACME" ]] || {
            log "Не удалось установить acme.sh."
            return 1
        }
    fi
    "$ACME" --set-default-ca --server letsencrypt >> "$LOG_FILE" 2>&1 || true
    for attempt in 1 2; do
        log "Выпуск сертификата для ${domain} (HTTP-01, webroot ${ACME_WEBROOT})."
        "$ACME" --issue -d "$domain" --keylength ec-256 -w "$ACME_WEBROOT" >> "$LOG_FILE" 2>&1
        rc=$?
        [[ "$rc" -eq 0 || "$rc" -eq 2 ]] && break
        if [[ "$attempt" -eq 1 ]]; then
            log "acme.sh завершился с кодом ${rc}, повторная попытка через 10 с."
            sleep 10
        fi
    done
    if [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
        log "acme.sh не выпустил сертификат (код ${rc}). Проверьте A-запись домена, доступность ${HTTP_PORT}/tcp снаружи и лог ${LOG_FILE}."
        return 1
    fi
    acme_webroot_set || acme_set_webroot || return 1
    acme_install_cert "$domain" "$dir"
    if ! cert_valid "$domain" "$dir" && [[ "$rc" -eq 2 ]]; then
        log "Сертификат acme.sh не подходит, перевыпуск."
        "$ACME" --renew -d "$domain" --ecc --force >> "$LOG_FILE" 2>&1
        acme_install_cert "$domain" "$dir"
    fi
    chmod 600 "${dir}/privkey.pem" 2> /dev/null
    cert_valid "$domain" "$dir" || {
        log "Сертификат не установлен в ${dir}."
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
        log "Не удалось записать задачу cron."
        return 1
    }
    "$CERT_RENEW" >> "$LOG_FILE" 2>&1
    log "Автопродление: ${CERT_RENEW}, cron root, ежедневно в 03:17."
}

# УСТАНОВКА 3X-UI И ПЕРЕНОС БАЗЫ

check_xui() {
    local rc=0
    if [[ ! -x "$XUI_BIN" ]]; then
        mismatch "3x-ui не установлен"
        return 1
    fi
    log "  3x-ui $("$XUI_BIN" -v 2> /dev/null)"
    [[ -n "$IMPORT_DB" ]] && {
        mismatch "ожидается перенос базы ${IMPORT_DB}"
        rc=1
    }
    xray_bin > /dev/null || {
        mismatch "xray-core не найден"
        rc=1
    }
    systemctl is-active --quiet x-ui || {
        mismatch "служба x-ui не запущена"
        rc=1
    }
    return "$rc"
}

install_xui() {
    local installer
    log "Установка 3x-ui (1–3 минуты)."
    installer=$(mktemp)
    if ! curl -fsSL "$XUI_INSTALL_URL" -o "$installer"; then
        rm -f "$installer"
        log "Не удалось скачать установщик 3x-ui."
        return 1
    fi
    bash "$installer" < /dev/null >> "$LOG_FILE" 2>&1
    rm -f "$installer"
    [[ -x "$XUI_BIN" ]] || {
        log "Установка 3x-ui завершилась с ошибкой."
        return 1
    }
    log "3x-ui $("$XUI_BIN" -v 2> /dev/null) установлен."
}

import_db() {
    local src="$1" work report bin
    bin=$(xray_bin) || {
        log "xray-core не найден."
        return 1
    }
    work=$(mktemp -d)
    cp "$src" "${work}/x-ui.db" || {
        rm -rf "$work"
        return 1
    }
    [[ -f "${src}-wal" ]] && cp "${src}-wal" "${work}/x-ui.db-wal"
    [[ -f "${src}-shm" ]] && cp "${src}-shm" "${work}/x-ui.db-shm"
    if ! report=$(py import-prepare "${work}/x-ui.db" "$bin"); then
        rm -rf "$work"
        log "Не удалось подготовить базу: ${report}"
        return 1
    fi
    xui_stop
    backup_db_once
    mkdir -p "$(dirname "$XUI_DB")"
    if ! cp "${work}/x-ui.db" "$XUI_DB"; then
        rm -rf "$work"
        log "Не удалось записать ${XUI_DB}."
        return 1
    fi
    rm -f "${XUI_DB}-wal" "${XUI_DB}-shm"
    rm -rf "$work"
    [[ "$(json_get "$report" twofa_reset)" == true ]] && TWO_FA_RESET=1
    conf_unset XHTTP_PATH SUB_PATH PANEL_PATH XUI_USERNAME XUI_PASSWORD XUI_PASSWORD_HASH XUI_CREDENTIALS_PENDING \
        HY2 HY2_PORT CLIENT_NAME
    IMPORTED_NOW=1
    log "База перенесена из ${src}. Ключи Reality выпущены заново: $(json_get "$report" rekeyed)."
    [[ "$TWO_FA_RESET" -eq 1 ]] && log "2FA из базы отключена, включите её заново в панели."
    xui_start
}

apply_xui() {
    if [[ ! -x "$XUI_BIN" ]]; then
        install_xui || return 1
    fi
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
    local suffix="$1" params="ssl http2"
    nginx_http2_directive && params="ssl"
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

render_nginx_site() {
    local domain folder
    domain=$(conf_get DOMAIN)
    folder=$(conf_get CERT_FOLDER)
    printf 'server {\n'
    nginx_listen_lines ""
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

    location $(conf_get XHTTP_PATH) {
        grpc_pass            grpc://127.0.0.1:${XHTTP_PORT};
        grpc_set_header      Host              \$host;
        grpc_set_header      X-Real-IP         \$remote_addr;
        grpc_set_header      X-Forwarded-For   \$proxy_add_x_forwarded_for;
        grpc_set_header      X-Forwarded-Proto \$scheme;
        client_max_body_size 0;
        client_body_timeout  1h;
        grpc_read_timeout    1h;
        grpc_send_timeout    1h;
    }

    location $(conf_get SUB_PATH) {
        proxy_pass         http://127.0.0.1:${SUB_PORT};
        proxy_set_header   Host      \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
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
    }

    location / {
        try_files \$uri \$uri/ /index.html;
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
            log "  отключён устаревший антискан ${f}"
            continue
        fi
        backup="/root/$(basename "$f").bak-$(date +%F-%H%M%S)"
        mv "$f" "$backup" && log "  устаревший антискан ${f} перенесён в ${backup}"
    done < <(nginx_stale_rejects)
}

stub_ready() {
    local dir
    dir=$(www_dir)
    [[ -s "${dir}/index.html" ]] && compgen -G "${dir}/favicon.*" > /dev/null
}

prepare_stub_site() {
    local dir favicon="" candidate
    dir=$(www_dir)
    stub_ready && return 0
    mkdir -p "$dir"
    if [[ ! -s "${dir}/index.html" ]]; then
        echo ""
        echo "Папка сайта-заглушки: ${dir}"
        echo "Можно положить туда index.html и фавиконку (favicon.ico, .svg или .png)."
        read -r -p "Enter — продолжить: " || die "Ввод прерван."
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
        log "Фавиконка не найдена, установлена стандартная."
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
        log "index.html не найден, установлена заглушка 403 Forbidden."
    fi
    stub_ready
}

install_nginx() {
    command -v nginx > /dev/null 2>&1 && return 0
    log "Установка nginx."
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update -qq >> "$LOG_FILE" 2>&1 || ! apt-get install -y -qq nginx >> "$LOG_FILE" 2>&1; then
        log "Не удалось установить nginx."
        return 1
    fi
}

nginx_backup_once() {
    [[ -n "$NGINX_BACKUP" || ! -d /etc/nginx ]] && return 0
    NGINX_BACKUP="/root/nginx-$(date +%F-%H%M%S).tgz"
    tar czf "$NGINX_BACKUP" -C / etc/nginx 2> /dev/null || NGINX_BACKUP=""
    [[ -n "$NGINX_BACKUP" ]] && log "Резервная копия /etc/nginx: ${NGINX_BACKUP}"
}

nginx_reload() {
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx > /dev/null 2>&1 && return 0
    fi
    systemctl restart nginx > /dev/null 2>&1
}

nginx_managed_files() {
    printf '%s\n' "$(nginx_site_file)" "$(nginx_site_link)" "$NGINX_REJECT_CONF" "$NGINX_HTTP_REJECT_CONF" \
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
        log "nginx -t: ошибка конфигурации, изменения отменены:"
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
        log "nginx не перезагрузился. Журнал nginx записан в лог."
        journal_tail nginx
        return 1
    fi
    if ! wait_for 15 "$listening"; then
        systemctl restart nginx > /dev/null 2>&1
        if ! wait_for 10 "$listening"; then
            log "nginx слушает: $(nginx_addresses | tr '\n' ' ')— нужно: $(nginx_expected_text). Проверьте другие конфиги в ${NGINX_SITES_ENABLED} и ${NGINX_CONF_D}."
            return 1
        fi
    fi
}

nginx_write_tls_files() {
    local site
    site=$(nginx_site_file)
    nginx_remove_stale_rejects
    render_nginx_site > "$site"
    render_nginx_reject > "$NGINX_REJECT_CONF"
    ln -sfn "$site" "$(nginx_site_link)"
    rm -f "${NGINX_SITES_ENABLED}/default"
}

nginx_write_config() {
    nginx_apply nginx_write_tls_files nginx_listens_expected
}

check_nginx() {
    local rc=0 site addr expected has_local=0
    if ! command -v nginx > /dev/null 2>&1; then
        mismatch "nginx не установлен"
        return 1
    fi
    site=$(nginx_site_file)
    render_nginx_site | cmp -s - "$site" || {
        template_differs "конфигурация сайта" "$site"
        rc=1
    }
    [[ "$(readlink -f "$(nginx_site_link)")" == "$site" ]] || {
        mismatch_minor "сайт ${site} не подключён в ${NGINX_SITES_ENABLED}"
        rc=1
    }
    render_nginx_reject | cmp -s - "$NGINX_REJECT_CONF" || {
        template_differs "антискан" "$NGINX_REJECT_CONF"
        rc=1
    }
    [[ -n "$(nginx_stale_rejects)" ]] && {
        mismatch "устаревший антискан на ${REALITY_TARGET}: $(nginx_stale_rejects | tr '\n' ' ')"
        rc=1
    }
    [[ -e "${NGINX_SITES_ENABLED}/default" ]] && {
        mismatch "подключён сайт default"
        rc=1
    }
    stub_ready || {
        mismatch_minor "нет сайта-заглушки в $(www_dir)"
        rc=1
    }
    if ! systemctl is-active --quiet nginx; then
        mismatch "nginx не запущен"
        return 1
    fi
    expected=" $(nginx_expected_addresses | tr '\n' ' ') "
    while IFS= read -r addr; do
        [[ "$addr" == "$REALITY_TARGET" ]] && has_local=1
        [[ "$expected" == *" ${addr} "* ]] && continue
        mismatch "nginx слушает лишний адрес ${addr}"
        rc=1
    done < <(nginx_addresses)
    [[ "$has_local" -eq 1 ]] || {
        mismatch "nginx не слушает ${REALITY_TARGET}"
        rc=1
    }
    dest_ready "$(conf_get DOMAIN)" || {
        mismatch "${REALITY_TARGET} не годится в target Reality (нужны TLS 1.3, h2, свой сертификат, отказ без SNI)"
        rc=1
    }
    return "$rc"
}

apply_nginx() {
    local foreign
    install_nginx || return 1
    prepare_stub_site || {
        log "Не удалось подготовить сайт-заглушку в $(www_dir)."
        return 1
    }
    foreign=$(nginx_foreign_public_listeners)
    if [[ -n "$foreign" ]]; then
        log "Публичный порт ${PUBLIC_TLS_PORT} заняли другие конфиги nginx:"
        log_lines "  " <<< "$foreign"
        return 1
    fi
    nginx_write_config
}

release_public_443() {
    local foreign
    foreign=$(nginx_foreign_public_listeners)
    if [[ -n "$foreign" ]]; then
        log "Порт ${PUBLIC_TLS_PORT} держат другие конфиги nginx:"
        log_lines "  " <<< "$foreign"
        return 1
    fi
    if nginx_holds_public_443; then
        nginx_write_config || return 1
    fi
    if ! wait_for 10 public_443_free; then
        log "Порт ${PUBLIC_TLS_PORT}/tcp занят:"
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
        mismatch "x-ui не запущен"
        return 1
    }
    mapfile -t wanted < <(panel_settings_wanted)
    diff=$(py settings-diff "$XUI_DB" "${wanted[@]}")
    if [[ -n "$diff" ]]; then
        mismatch_lines <<< "$diff"
        rc=1
    fi
    if [[ -n "$(conf_get XUI_CREDENTIALS_PENDING)" ]]; then
        mismatch_minor "новые логин и пароль панели ещё не применены"
        rc=1
    fi
    if [[ -e "$XUI_INSTALL_RESULT" || "$(py api-token-exists "$XUI_DB" install)" == yes ]]; then
        mismatch_minor "остался API-токен установщика 3x-ui"
        rc=1
    fi
    tcp_listening "$NGINX_ADDR" "$PANEL_PORT" || {
        mismatch "панель не слушает ${NGINX_ADDR}:${PANEL_PORT}"
        rc=1
    }
    code=$(http_code "https://$(conf_get DOMAIN):${NGINX_PORT}$(conf_get PANEL_PATH)/" "$(conf_get DOMAIN):${NGINX_PORT}:${NGINX_ADDR}")
    [[ "$code" =~ ^(200|301|302|307|308)$ ]] || {
        mismatch "панель через nginx отвечает кодом ${code}"
        rc=1
    }
    return "$rc"
}

apply_panel() {
    local args=(-port "$PANEL_PORT" -listenIP "$NGINX_ADDR" -webBasePath "$(conf_get PANEL_PATH)/")
    if [[ -n "$(conf_get XUI_CREDENTIALS_PENDING)" ]]; then
        args+=(-username "$(conf_get XUI_USERNAME)" -password "$(conf_get XUI_PASSWORD)")
    fi
    xui_stop
    backup_db_once
    if ! "$XUI_BIN" setting "${args[@]}" >> "$LOG_FILE" 2>&1; then
        log "x-ui setting завершился с ошибкой."
        xui_start
        return 1
    fi
    if ! py settings-set "$XUI_DB" "webCertFile=" "webKeyFile=" || ! py api-token-delete "$XUI_DB" install; then
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
        mismatch "сервер подписки не слушает ${NGINX_ADDR}:${SUB_PORT}"
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
    py inbounds "$1" "$XUI_DB" "$(conf_get DOMAIN)" "$(conf_get CERT_FOLDER)" "$(conf_get XHTTP_PATH)" \
        "$(hy2_port_answer)" "$REALITY_TARGET"
}

runtime_inbounds_ok() {
    local summary hy2_port rc=0 quiet="${1:-0}"
    hy2_port=$(hy2_port_answer)
    if [[ ! -s "$XRAY_CONFIG" ]]; then
        [[ "$quiet" -eq 1 ]] || mismatch "нет ${XRAY_CONFIG}"
        return 1
    fi
    summary=$(py config-summary "$XRAY_CONFIG") || return 1
    if [[ "$(json_get "$summary" reality.port)" != "$PUBLIC_TLS_PORT" || "$(json_get "$summary" reality.target)" != "$REALITY_TARGET" ]]; then
        [[ "$quiet" -eq 1 ]] || mismatch "config.json: Reality не на ${PUBLIC_TLS_PORT} или target не ${REALITY_TARGET}"
        rc=1
    fi
    if [[ "$(json_get "$summary" reality.limit_fallback)" != "[]" ]]; then
        [[ "$quiet" -eq 1 ]] || mismatch "config.json: в Reality есть limitFallback"
        rc=1
    fi
    xray_holds_443 || {
        [[ "$quiet" -eq 1 ]] || mismatch "Xray не слушает ${PUBLIC_TLS_PORT}/tcp"
        rc=1
    }
    tcp_listening "$NGINX_ADDR" "$XHTTP_PORT" || {
        [[ "$quiet" -eq 1 ]] || mismatch "XHTTP не слушает ${NGINX_ADDR}:${XHTTP_PORT}"
        rc=1
    }
    if [[ "$hy2_port" != 0 ]]; then
        if [[ "$(json_get "$summary" hy2.port)" != "$hy2_port" ]] || ! udp_listening "$hy2_port"; then
            [[ "$quiet" -eq 1 ]] || mismatch "Hysteria2 не слушает UDP/${hy2_port}"
            rc=1
        fi
    fi
    return "$rc"
}

check_inbounds() {
    local report rc=0 line
    if ! report=$(inbounds_report plan); then
        mismatch "не удалось прочитать инбаунды: ${report}"
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
            reality) mismatch "нет инбаунда VLESS Reality" ;;
            xhttp) mismatch "нет инбаунда VLESS XHTTP" ;;
            hy2) mismatch "нет инбаунда Hysteria2" ;;
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
        log "Не удалось изменить инбаунды: ${report}"
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
        log "После записи target Reality «${target}», а не ${REALITY_TARGET}. Остановлено, чтобы не получить петлю."
        xui_start
        return 1
    fi
    if [[ -n "$port" && "$port" != "$PUBLIC_TLS_PORT" ]]; then
        if ! release_public_443; then
            xui_start
            return 1
        fi
        if ! report=$(inbounds_report port); then
            log "Не удалось перевести Reality на ${PUBLIC_TLS_PORT}: ${report}"
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
        "$(conf_get CERT_FOLDER)" "$(conf_get XHTTP_PATH)" "$(hy2_port_answer)" "$REALITY_TARGET" \
        "$(conf_get CLIENT_NAME)"); then
        log "Не удалось создать инбаунды: ${report}"
        return 1
    fi
    log_quiet "$report"
    json_lines "$report" created | while IFS= read -r line; do
        log "  создан: $(json_get "$line" kind) $(json_get "$line" tag), порт $(json_get "$line" port)"
    done
    if [[ -n "$(json_get "$report" new_client)" ]]; then
        log "  клиент «$(json_get "$report" new_client.email)» добавлен во все инбаунды."
    fi
}

apply_inbounds() {
    local report fatal
    report=$(inbounds_report plan) || {
        log "$report"
        return 1
    }
    fatal=$(json_lines "$report" fatal)
    if [[ -n "$fatal" ]]; then
        log "Требуется ручное решение:"
        log_lines "  " <<< "$fatal"
        return 1
    fi
    if [[ -n "$(json_lines "$report" problems)" ]]; then
        fix_inbounds || return 1
    fi
    create_missing_inbounds || return 1
    xui_restart || return 1
    wait_for 20 runtime_inbounds_ok 1
}

# ХОСТЫ

hosts_report() {
    py hosts "$1" "$XUI_DB" "$(conf_get DOMAIN)" "$(hy2_port_answer)"
}

check_hosts() {
    local report rc=0 line
    report=$(hosts_report plan) || {
        mismatch "не удалось прочитать Хосты: ${report}"
        return 1
    }
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        mismatch "$line"
        rc=1
    done < <(json_lines "$report" problems)
    json_lines "$report" foreign | warn_lines
    report=$(inbounds_report plan)
    if [[ -n "$(json_lines "$report" problems)" ]]; then
        mismatch "инбаунды изменились после записи Хостов"
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
            log "Не удалось изменить Хосты: ${report}"
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
            log "Не удалось добавить Хосты: ${report}"
            return 1
        }
        json_lines "$report" added | log_lines "  добавлен Хост "
    fi
    if [[ -n "$(json_lines "$(inbounds_report plan)" problems)" ]]; then
        log "После записи Хостов изменился инбаунд, возвращаю настройки."
        fix_inbounds || return 1
    fi
    xui_restart
}

# МАРШРУТИЗАЦИЯ

check_routing() {
    local summary rc=0
    if [[ ! -s "$XRAY_CONFIG" ]]; then
        mismatch "нет ${XRAY_CONFIG}"
        return 1
    fi
    summary=$(py config-summary "$XRAY_CONFIG") || return 1
    if [[ -z "$(json_get "$summary" reality.tag)" || -z "$(json_get "$summary" xhttp.tag)" ]]; then
        mismatch "в config.json нет Reality или XHTTP"
        return 1
    fi
    [[ "$(json_get "$summary" ru_block)" == true ]] || {
        mismatch "нет правила geoip:ru → blocked"
        rc=1
    }
    [[ "$(json_get "$summary" udp443_ok)" == true ]] || {
        mismatch "правило UDP/443 → blocked: $(json_get "$summary" udp443_actual), нужно $(json_get "$summary" udp443_expected)"
        rc=1
    }
    return "$rc"
}

apply_routing() {
    local summary token report reality xhttp
    summary=$(py config-summary "$XRAY_CONFIG") || return 1
    reality=$(json_get "$summary" reality.tag)
    xhttp=$(json_get "$summary" xhttp.tag)
    token=$(api_token) || return 1
    report=$(py routing-apply "$(api_base)" "$token" "$reality" "$xhttp") || {
        log "Не удалось изменить маршрутизацию: ${report}"
        return 1
    }
    json_lines "$report" changes | while IFS= read -r line; do log_quiet "  ${line}"; done
    xui_restart || return 1
    token=$(api_token) || return 1
    report=$(py routing-test "$(api_base)" "$token" "$reality" "$xhttp") || {
        log "Проверка routeTest не пройдена: $(json_get "$report" failed)"
        return 1
    }
    log "  routeTest: правила работают."
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
    known=" ${INTERNAL_PORTS[*]} $(json_get "$(xui_discover)" ports | tr -d '[]",' ) ${STALE_PORTS} "
    while IFS='|' read -r spec comment; do
        [[ -n "$spec" ]] || continue
        [[ "$targets" == *" ${spec} "* ]] && continue
        port="${spec%%/*}"
        if [[ "$spec" == "$port" && "$targets" == *" ${port}/"* ]]; then
            continue
        fi
        if [[ "$comment" == *"$SCRIPT_NAME"* || "$comment" == *acme* ]] \
            || [[ " ${INTERNAL_PORTS[*]} " == *" ${port} "* ]] \
            || [[ "$known" == *" ${spec} "* || "$known" == *" ${port}/"* ]]; then
            printf '%s\n' "$spec"
        fi
    done < <(ufw_simple_rules)
}

check_ufw() {
    local rc=0 rule
    if ! ufw_present; then
        log "  ufw не установлен. Откройте в своём файрволе: $(ufw_target_rules | tr '\n' ' ')"
        return 0
    fi
    while IFS= read -r rule; do
        ufw_allows "$rule" || {
            mismatch "нет правила ufw ${rule}"
            rc=1
        }
    done < <(ufw_target_rules)
    return "$rc"
}

apply_ufw() {
    local rule
    while IFS= read -r rule; do
        ufw_allows "$rule" && continue
        ufw allow "$rule" comment "$SCRIPT_NAME" > /dev/null 2>&1 && log "  ufw: добавлено ${rule}."
    done < <(ufw_target_rules)
}

check_ufw_cleanup() {
    local rc=0 rule
    ufw_present || return 0
    while IFS= read -r rule; do
        [[ -n "$rule" ]] || continue
        mismatch_minor "лишнее правило ufw ${rule}"
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
        log "  ufw: удалено ${rule}."
    done < <(ufw_stale_rules)
}

# ФИНАЛЬНАЯ ПРОВЕРКА

expect_tls() {
    local host="$1" port="$2" sni="$3" want="$4" what="$5" got
    got=$(tls_probe "$host" "$port" "$sni")
    if [[ "$got" == "$want" ]]; then
        report_ok "${host}:${port}, ${what}: $([[ "$got" == cert ]] && echo 'свой сертификат' || echo 'отказ')"
    else
        report_fail "${host}:${port}, ${what}: $([[ "$got" == cert ]] && echo 'выдан сертификат' || echo 'отказ'), ожидалось обратное"
    fi
}

final_listen_checks() {
    local hy2_port addrs
    hy2_port=$(hy2_port_answer)
    if xray_holds_443 && ! tcp_listeners "$PUBLIC_TLS_PORT" | grep -qv '"xray'; then
        report_ok "${PUBLIC_TLS_PORT}/tcp слушает только Xray"
    else
        report_fail "${PUBLIC_TLS_PORT}/tcp: $(tcp_listeners "$PUBLIC_TLS_PORT" | awk '{print $4, $6}' | tr '\n' ' ')"
    fi
    addrs=$(nginx_addresses | paste -sd ',' - | sed 's/,/, /g')
    if nginx_listens_expected; then
        report_ok "nginx слушает $(nginx_expected_text)"
    else
        report_fail "nginx слушает: ${addrs:-ничего}; нужно: $(nginx_expected_text)"
    fi
    if [[ "$hy2_port" != 0 ]]; then
        if udp_listening "$hy2_port"; then
            report_ok "Hysteria2 слушает UDP/${hy2_port}"
        else
            report_fail "Hysteria2 не слушает UDP/${hy2_port}"
        fi
    fi
}

final_config_checks() {
    local summary loops
    summary=$(py config-summary "$XRAY_CONFIG") || {
        report_fail "не удалось прочитать ${XRAY_CONFIG}"
        return
    }
    if [[ "$(json_get "$summary" reality.port)" == "$PUBLIC_TLS_PORT" && "$(json_get "$summary" reality.target)" == "$REALITY_TARGET" ]]; then
        report_ok "config.json: Reality ${PUBLIC_TLS_PORT} → ${REALITY_TARGET}, тег $(json_get "$summary" reality.tag)"
    else
        report_fail "config.json: Reality порт $(json_get "$summary" reality.port), target $(json_get "$summary" reality.target)"
    fi
    if [[ "$(json_get "$summary" reality.limit_fallback)" == "[]" ]]; then
        report_ok "config.json: limitFallback нет"
    else
        report_fail "config.json: limitFallback $(json_get "$summary" reality.limit_fallback)"
    fi
    if [[ "$(json_get "$summary" udp443_ok)" == true ]]; then
        report_ok "правило UDP/443 → blocked: $(json_get "$summary" udp443_expected)"
    else
        report_fail "правило UDP/443 → blocked: $(json_get "$summary" udp443_actual), нужно $(json_get "$summary" udp443_expected)"
    fi
    loops=$(ss -Htn 2> /dev/null | grep -c "127.0.0.1:${PUBLIC_TLS_PORT} ")
    if [[ "$loops" -eq 0 ]]; then
        report_ok "петли нет: соединений на 127.0.0.1:${PUBLIC_TLS_PORT} нет"
    else
        report_fail "петля: ${loops} соединений на 127.0.0.1:${PUBLIC_TLS_PORT}"
    fi
}

final_tls_checks() {
    local domain="$1" ip="$2" code
    if dest_ready "$domain"; then
        report_ok "${REALITY_TARGET}: TLS 1.3 + h2, свой сертификат, без SNI — отказ"
    else
        report_fail "${REALITY_TARGET} не годится в target Reality"
    fi
    expect_tls "$ip" "$PUBLIC_TLS_PORT" "-" reject "без SNI"
    expect_tls "$ip" "$PUBLIC_TLS_PORT" "scanner.invalid" reject "чужой SNI"
    expect_tls "$ip" "$PUBLIC_TLS_PORT" "$domain" cert "SNI ${domain}"
    code=$(http_code "https://${domain}/" "${domain}:${PUBLIC_TLS_PORT}:${ip}")
    if [[ "$code" == 200 ]]; then
        report_ok "сайт через фолбек Reality: https://${domain}/ → 200"
    else
        report_fail "сайт через фолбек Reality: https://${domain}/ → ${code}"
    fi
    code=$(http_code "https://${domain}$(conf_get PANEL_PATH)/" "${domain}:${PUBLIC_TLS_PORT}:${ip}")
    if [[ "$code" =~ ^(200|301|302|307|308)$ ]]; then
        report_ok "панель через ${PUBLIC_TLS_PORT}: ${code}"
    else
        report_fail "панель через ${PUBLIC_TLS_PORT}: ${code}"
    fi
}

expect_empty_reply() {
    local what="$1" code
    shift
    code=$(curl_exit_code "$@")
    if [[ "$code" == 52 ]]; then
        report_ok "${what}: соединение закрыто без ответа"
    else
        report_fail "${what}: curl exit ${code}, ожидался 52 (закрытие без ответа)"
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
        report_fail "http://${domain}/check80?x=1 → ${out% }, ожидался 301 ${want}"
    fi
    if challenge_served "$ip"; then
        report_ok "http://${domain}/.well-known/acme-challenge/ отдаёт файлы из $(acme_challenge_dir)"
    else
        report_fail "http://${domain}/.well-known/acme-challenge/ не отдаёт файлы из $(acme_challenge_dir)"
    fi
    if acme_webroot_set; then
        report_ok "acme.sh: Le_Webroot='${ACME_WEBROOT}'"
    else
        report_fail "acme.sh: нет Le_Webroot='${ACME_WEBROOT}' в $(acme_domain_conf)"
    fi
    if [[ -s "$CERT_RENEW" ]] && ! grep -qE 'standalone|ufw' "$CERT_RENEW"; then
        report_ok "${CERT_RENEW}: без standalone и ufw"
    else
        report_fail "${CERT_RENEW} отсутствует или использует standalone / ufw"
    fi
    if renew_cron_present && ! acme_cron_present; then
        report_ok "cron root: ${CERT_RENEW}, без acme.sh --cron"
    else
        report_fail "cron root: нужна задача ${CERT_RENEW} и не нужна acme.sh --cron"
    fi
}

final_subscription_checks() {
    local domain="$1" ip="$2" sub_id url out body meta code type endpoints hy2_port line
    sub_id=$(json_get "$(xui_discover)" sub_id)
    if [[ -z "$sub_id" ]]; then
        report_fail "не найден клиент с subId"
        return
    fi
    out=$(curl -sk --noproxy '*' --max-time 10 --resolve "${domain}:${PUBLIC_TLS_PORT}:${ip}" \
        -w '\n%{http_code}|%{content_type}' "https://${domain}$(conf_get SUB_PATH)/${sub_id}")
    body="${out%$'\n'*}"
    meta="${out##*$'\n'}"
    code="${meta%%|*}"
    type="${meta#*|}"
    if [[ "$code" != 200 || -z "$body" || "$type" == *text/html* ]]; then
        report_fail "подписка через ${PUBLIC_TLS_PORT}: код ${code}, тип ${type}"
        return
    fi
    endpoints=$(py sub-endpoints <<< "$body")
    report_ok "подписка через ${PUBLIC_TLS_PORT}: 200, ссылки:"
    py json-lines "{\"items\": ${endpoints}}" items | while IFS= read -r line; do
        log "           $(json_get "$line" scheme)://…@$(json_get "$line" host):$(json_get "$line" port) $(json_get "$line" type) $(json_get "$line" security)"
    done
    hy2_port=$(hy2_port_answer)
    py_expect_endpoint "$endpoints" vless "$domain" "$PUBLIC_TLS_PORT" reality "VLESS Reality"
    py_expect_endpoint "$endpoints" vless "$domain" "$PUBLIC_TLS_PORT" xhttp "VLESS XHTTP"
    [[ "$hy2_port" != 0 ]] && py_expect_endpoint "$endpoints" hysteria2 "$domain" "$hy2_port" "" "Hysteria2"
    url="https://${domain}$(conf_get SUB_PATH)/verify-fake-subid-00000000"
    code=$(http_code "$url" "${domain}:${PUBLIC_TLS_PORT}:${ip}")
    if [[ "$code" == 404 ]]; then
        report_ok "несуществующий subId → 404"
    else
        report_fail "несуществующий subId → ${code}, ожидался 404"
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
        report_ok "в подписке ${name}: ${host}:${port}"
    else
        report_fail "в подписке нет ${name} с адресом ${host}:${port}"
    fi
}

final_journal_checks() {
    local since
    since=$(systemctl show -p ActiveEnterTimestamp --value x-ui 2> /dev/null)
    if [[ -z "$since" ]]; then
        report_warn "не удалось определить время запуска x-ui, журнал не проверен"
        return
    fi
    since=$(date -d "$since" '+%F %T' 2> /dev/null) || since=""
    if journalctl -u x-ui --since "${since:-today}" --no-pager 2> /dev/null | grep -qi 'non-443'; then
        report_fail "в журнале x-ui есть предупреждение REALITY о порте не 443"
    else
        report_ok "предупреждения REALITY о порте не 443 в журнале нет"
    fi
    if journalctl -u x-ui --since "${since:-today}" --no-pager 2> /dev/null | grep -v 'systemd\[' | grep -qiE 'failed to (build|start)'; then
        report_fail "в журнале x-ui есть ошибки запуска Xray"
    fi
}

final_service_checks() {
    local rule extra
    local unit
    for unit in nginx x-ui; do
        if systemctl is-active --quiet "$unit"; then
            report_ok "${unit} активен"
        else
            report_fail "${unit} не активен"
        fi
    done
    if ! ufw_present; then
        report_warn "ufw не установлен: откройте только $(ufw_target_rules | tr '\n' ' ')"
        return
    fi
    while IFS= read -r rule; do
        if ufw_allows "$rule"; then
            report_ok "ufw: ${rule}"
        else
            report_fail "ufw: нет ${rule}"
        fi
    done < <(ufw_target_rules)
    extra=$(ufw_simple_rules | cut -d'|' -f1 | grep -vxF -f <(ufw_target_rules) | grep -vxF -f <(ufw_target_rules | cut -d/ -f1) \
        | grep -vxF -f <(ufw_stale_rules; echo "-") | tr '\n' ' ')
    if [[ -n "${extra// /}" ]]; then
        report_warn "в ufw есть другие правила: ${extra}— проверьте, нужны ли они"
    fi
    if ! ufw status 2> /dev/null | grep -q 'Status: active'; then
        report_warn "ufw выключен: правила не действуют. Разрешите SSH-порт и выполните ufw enable."
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
        report_fail "не удалось определить публичный IPv4"
    fi
    final_journal_checks
    final_service_checks
    [[ "$FINAL_OK" -eq 1 ]]
}

# ЗАПУСК

panel_password_text() {
    if [[ -n "$(conf_get XUI_PASSWORD)" && "$(py panel-user "$XUI_DB" password)" == "$(conf_get XUI_PASSWORD_HASH)" ]]; then
        conf_get XUI_PASSWORD
    else
        printf 'задан не этим скриптом, новый: sudo bash %s --reconfigure' "${0##*/}"
    fi
}

print_summary() {
    log ""
    log "Установка завершена."
    log "Панель:    https://$(conf_get DOMAIN)$(conf_get PANEL_PATH)/"
    log "Логин:     $(py panel-user "$XUI_DB" username)"
    log "Пароль:    $(panel_password_text)"
    log "Подписка:  https://$(conf_get DOMAIN)$(conf_get SUB_PATH)/$(json_get "$(xui_discover)" sub_id)"
    [[ "$TWO_FA_RESET" -eq 1 ]] && log "2FA панели отключена при импорте, включите её заново."
    return 0
}

check_tools() {
    local cmd missing=()
    for cmd in curl openssl python3 ss; do
        command -v "$cmd" > /dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) && return 0
    report_fail "не найдены команды: ${missing[*]}"
    return 1
}

check_resolve_answers() {
    local discovered hy2_port key value
    [[ -n "$(conf_get DOMAIN)" ]] || CONF[DOMAIN]=$(discover_domain)
    [[ "$(conf_get DOMAIN)" =~ $DOMAIN_RE ]] || return 1
    if [[ -z "$(conf_get CERT_FOLDER)" ]]; then
        value=$(discover_cert_folder)
        CONF[CERT_FOLDER]="${value:-$(conf_get DOMAIN)}"
    fi
    discovered=$(xui_discover)
    for key in XHTTP_PATH:xhttp_path SUB_PATH:sub_path PANEL_PATH:web_base_path; do
        [[ -n "$(conf_get "${key%%:*}")" ]] && continue
        CONF[${key%%:*}]=$(normalize_path "$(json_get "$discovered" "${key#*:}")")
    done
    if [[ -z "$(conf_get HY2)" ]]; then
        hy2_port=$(json_get "$discovered" hy2_port)
        if [[ -n "$hy2_port" ]]; then
            CONF[HY2]=yes
            CONF[HY2_PORT]="$hy2_port"
        else
            CONF[HY2]=no
        fi
    fi
    log "Домен: $(conf_get DOMAIN), сертификат: $(cert_dir), Hysteria2: $([[ "$(hy2_port_answer)" != 0 ]] && echo "UDP/$(hy2_port_answer)" || echo нет)"
}

check_step() {
    local title="$1" name="$2"
    log ""
    log "== ${title} =="
    if "check_${name}"; then
        report_ok "соответствует"
    fi
    return 0
}

run_check() {
    LOG_FILE=/dev/null
    trap 'exit 2' INT TERM HUP
    log "Проверка ${SCRIPT_NAME}, без изменений."
    check_tools || exit 2
    load_py_helper
    conf_load
    if ! check_resolve_answers; then
        report_fail "домен не определён: нет файла ответов ${CONF_FILE} и server_name в конфигах nginx"
        exit 2
    fi
    check_step "nginx: порт 80" http
    check_step "Сертификат" cert
    check_step "3x-ui" xui
    if xui_has_config; then
        check_step "nginx" nginx
        check_step "Панель 3x-ui" panel
        check_step "Подписка" subscription
        check_step "Инбаунды" inbounds
        check_step "Хосты" hosts
        check_step "Маршрутизация" routing
    else
        log ""
        report_fail "в ${XUI_DB} нет инбаундов 3x-ui: проверки nginx, панели, подписки, инбаундов, Хостов и маршрутизации пропущены"
    fi
    check_step "ufw" ufw
    ufw_present && check_step "ufw: лишние правила" ufw_cleanup
    log ""
    log "== Финальная проверка =="
    final_checks
    log ""
    if [[ "$FAIL_COUNT" -eq 0 ]]; then
        log "Проверка завершена: ошибок нет."
        exit 0
    fi
    log "Проверка завершена: ошибок: ${FAIL_COUNT}."
    exit 1
}

main() {
    parse_args "$@"
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Запустите от root: sudo bash ${0##*/}" >&2
        exit $((CHECK_ONLY == 1 ? 2 : 1))
    fi
    [[ "$CHECK_ONLY" -eq 1 ]] && run_check
    init_log
    trap 'die "Прервано. Повторный запуск продолжит с текущего состояния."' INT TERM HUP
    log "Запуск ${SCRIPT_NAME}. Лог: ${LOG_FILE}"
    ensure_packages
    load_py_helper
    conf_load

    resolve_base_answers
    converge "nginx: порт 80" http
    converge "Сертификат" cert
    resolve_import
    converge "3x-ui" xui
    resolve_paths
    resolve_credentials
    converge "nginx" nginx
    converge "Панель 3x-ui" panel
    converge "Подписка" subscription
    resolve_hy2
    resolve_client_name
    converge "Инбаунды" inbounds
    converge "Хосты" hosts
    converge "Маршрутизация" routing
    converge "ufw" ufw
    log ""
    log "== Финальная проверка =="
    final_checks || die "Финальная проверка не пройдена."
    converge "ufw: лишние правила" ufw_cleanup
    print_summary
}

main "$@"
