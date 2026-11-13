#!/usr/bin/env bash
# ============================================================
#  deploy_rustdesk.sh - массовая установка клиента RustDesk
#
#  Ставит RustDesk и настраивает его на self-hosted hbbs из
#  проекта ~/opt/rmm-ra: адрес сервера берётся из .env, ключ —
#  из rustdesk-data/id_ed25519.pub. Ничего копировать вручную
#  не нужно.
#
#  Примеры:
#    ./deploy_rustdesk.sh --syntax-check
#    ./deploy_rustdesk.sh --limit 192.168.0.143 --check
#    ./deploy_rustdesk.sh --limit 192.168.0.143
#    ./deploy_rustdesk.sh                 # весь парк (спросит)
#
#  Пароль WinRM:
#    по умолчанию спросит интерактивно;
#    либо --password-file /path/to/secret;
#    либо ANSIBLE_WINRM_PASSWORD=... ./deploy_rustdesk.sh
#
#  Постоянный пароль RustDesk (для unattended-доступа):
#    RUSTDESK_PERMANENT_PASSWORD=... ./deploy_rustdesk.sh ...
#    ./deploy_rustdesk.sh --ask-password ...
#
#  Полезное:
#    --limit PATTERN   ограничить хосты (IP, маска 192.168.0.14*, группа)
#    --check           пробный прогон без изменений
#    --force           переустановить клиент
#    --version X.Y.Z   версия клиента (по умолчанию latest)
#    --prefetch        скачать установщики в files/installers и выйти
#    --forks N         параллельность (по умолчанию 20)
#    --list            показать хосты, которые попадут в прогон
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RMM_RA_DIR="${RMM_RA_DIR:-$HOME/opt/rmm-ra}"
INVENTORY="inventory/windows_hosts.yml"
PLAYBOOK="playbooks/rustdesk_client.yml"
REPORT_DIR="$SCRIPT_DIR/reports/rustdesk"

LIMIT=""
SERVER=""
KEY=""
RELAY_PORT="21117"
VERSION="${RUSTDESK_VERSION:-latest}"
INSTALLER_URL=""
VALIDATE_CERTS=1
PERM_PW="${RUSTDESK_PERMANENT_PASSWORD:-}"
FORCE_PW=0
ASK_PW=0
PASS_FILE=""
FORKS="${FORKS:-20}"
MODE="deploy"
CHECK=0
FORCE=0
ASSUME_YES=0
PREFETCH=0
INSTALL_TIMEOUT=""
PACKAGE_FORMAT=""
CACHE_DIR="$SCRIPT_DIR/files/installers"

usage() {
    cat <<'EOF'
============================================================
 deploy_rustdesk.sh - массовая установка клиента RustDesk
============================================================

 Примеры:
   ./deploy_rustdesk.sh --syntax-check
   ./deploy_rustdesk.sh --limit 192.168.0.143 --check
   ./deploy_rustdesk.sh --limit 192.168.0.143
   ./deploy_rustdesk.sh --yes          # весь парк без вопросов

 Пароль WinRM:
   по умолчанию спросит интерактивно (без эха);
   либо --password-file /path/to/secret;
   либо ANSIBLE_WINRM_PASSWORD=... ./deploy_rustdesk.sh

 Полезное:
   --server HOST          адрес hbbs (по умолчанию из rmm-ra/.env)
   --key BASE64           публичный ключ (по умолчанию из rustdesk-data)
   --relay-port N         порт hbbr (по умолчанию 21117)
   --version X.Y.Z|latest версия клиента (по умолчанию latest)
   --prefetch             скачать установщики в локальный кэш и выйти
   --installer-url URL    явный URL установщика
   --package-format FMT   msi (по умолчанию) или exe
   --install-timeout SEC  сколько ждать установщик (по умолчанию 900)
   --ask-password         спросить постоянный пароль RustDesk
   --force-password       перезаписать уже заданный постоянный пароль
   --no-validate-certs    не проверять TLS при скачивании
   --limit PATTERN        ограничить хосты (IP, диапазон, группа)
   --check                пробный прогон без изменений
   --force                переустановить клиент
   --forks N              параллельность (по умолчанию 20)
   --list                 показать хосты, которые попадут в прогон
   --yes                  не спрашивать подтверждение для всего парка
   --inventory FILE       другой inventory
EOF
    exit "${1:-0}"
}

die() { echo "ОШИБКА: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)             SERVER="${2:?--server требует значение}"; shift 2 ;;
        --key)                KEY="${2:?--key требует значение}"; shift 2 ;;
        --relay-port)         RELAY_PORT="${2:?--relay-port требует значение}"; shift 2 ;;
        --version)            VERSION="${2:?--version требует значение}"; shift 2 ;;
        --prefetch)           PREFETCH=1; shift ;;
        --installer-url)      INSTALLER_URL="${2:?--installer-url требует значение}"; shift 2 ;;
        --package-format)     PACKAGE_FORMAT="${2:?--package-format требует значение}"; shift 2 ;;
        --install-timeout)    INSTALL_TIMEOUT="${2:?--install-timeout требует значение}"; shift 2 ;;
        --permanent-password) PERM_PW="${2:?--permanent-password требует значение}"; shift 2 ;;
        --ask-password)       ASK_PW=1; shift ;;
        --force-password)     FORCE_PW=1; shift ;;
        --no-validate-certs)  VALIDATE_CERTS=0; shift ;;
        --limit|-l)           LIMIT="${2:?--limit требует значение}"; shift 2 ;;
        --limit=*)            LIMIT="${1#*=}"; shift ;;
        --inventory|-i)       INVENTORY="${2:?--inventory требует значение}"; shift 2 ;;
        --password-file)      PASS_FILE="${2:?--password-file требует значение}"; shift 2 ;;
        --forks)              FORKS="${2:?--forks требует значение}"; shift 2 ;;
        --check|-C)           CHECK=1; shift ;;
        --force)              FORCE=1; shift ;;
        --yes|-y)             ASSUME_YES=1; shift ;;
        --syntax-check|-S)    MODE="syntax"; shift ;;
        --list)               MODE="list"; shift ;;
        --help|-h)            usage 0 ;;
        *) die "неизвестный аргумент: $1 (см. --help)" ;;
    esac
done

[[ -f "$INVENTORY" ]] || die "inventory не найден: $INVENTORY"
[[ -f "$PLAYBOOK" ]]  || die "playbook не найден: $PLAYBOOK"

if [[ -n "$PACKAGE_FORMAT" && "$PACKAGE_FORMAT" != "msi" && "$PACKAGE_FORMAT" != "exe" ]]; then
    die "--package-format: допустимо msi или exe (получено '$PACKAGE_FORMAT')"
fi
if [[ -n "$INSTALL_TIMEOUT" && ! "$INSTALL_TIMEOUT" =~ ^[0-9]+$ ]]; then
    die "--install-timeout: нужно целое число секунд (получено '$INSTALL_TIMEOUT')"
fi

# --- Режим проверки синтаксиса ---
if [[ "$MODE" == "syntax" ]]; then
    exec ansible-playbook -i "$INVENTORY" "$PLAYBOOK" --syntax-check \
        -e rd_server=__syntax_check__ -e rd_key=__syntax_check__
fi

# --- Режим просмотра хостов ---
if [[ "$MODE" == "list" ]]; then
    cmd=(ansible-playbook -i "$INVENTORY" "$PLAYBOOK" --list-hosts)
    [[ -n "$LIMIT" ]] && cmd+=(--limit "$LIMIT")
    exec "${cmd[@]}"
fi

# --- Адрес сервера из rmm-ra/.env ---
if [[ -z "$SERVER" ]]; then
    ENV_FILE="$RMM_RA_DIR/.env"
    [[ -r "$ENV_FILE" ]] || die "не найден $ENV_FILE; укажи --server"
    SERVER="$(sed -n 's/^SERVER_IP=//p' "$ENV_FILE" | head -1 | tr -d '"'"'"' ')"
    [[ -n "$SERVER" ]] || die "в $ENV_FILE не задан SERVER_IP; укажи --server"
fi

# --- Публичный ключ сервера ---
if [[ -z "$KEY" ]]; then
    KEY_FILE="$RMM_RA_DIR/rustdesk-data/id_ed25519.pub"
    [[ -r "$KEY_FILE" ]] || die "не найден $KEY_FILE; укажи --key"
    KEY="$(tr -d '[:space:]' < "$KEY_FILE")"
    [[ -n "$KEY" ]] || die "пустой $KEY_FILE; укажи --key"
fi

# --- Версия клиента ---
if [[ "$VERSION" == "latest" ]]; then
    VERSION="$(curl -fsSL https://api.github.com/repos/rustdesk/rustdesk/releases/latest 2>/dev/null \
        | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"].lstrip("v"))' 2>/dev/null || true)"
    [[ -n "$VERSION" ]] || die "не удалось узнать последнюю версию RustDesk; укажи --version X.Y.Z"
fi

# --- Локальный кэш установщиков ---
prefetch_installers() {
    local ver="$1"
    local dir="$CACHE_DIR"
    local base="https://github.com/rustdesk/rustdesk/releases/download/$ver"
    local name out size
    mkdir -p "$dir"
    for name in "rustdesk-$ver-x86_64.msi" "rustdesk-$ver-aarch64.msi"; do
        out="$dir/$name"
        if [[ -s "$out" ]]; then
            echo "уже есть : $name"
            continue
        fi
        echo "скачиваю : $name"
        rm -f "$out.part"
        if ! curl -fL --retry 3 --connect-timeout 15 -o "$out.part" "$base/$name"; then
            rm -f "$out.part"
            die "не удалось скачать $name"
        fi
        size="$(stat -c %s "$out.part" 2>/dev/null || echo 0)"
        if [[ "$size" -lt 1000000 ]]; then
            rm -f "$out.part"
            die "файл $name подозрительно мал ($size байт)"
        fi
        mv "$out.part" "$out"
    done
    echo
    echo "Готово. Кэш: $dir"
    ( cd "$dir" && sha256sum rustdesk-*.exe rustdesk-*.msi > SHA256SUMS.txt 2>/dev/null || true )
    ls -lh "$dir"
}

if [[ "$PREFETCH" == "1" ]]; then
    prefetch_installers "$VERSION"
    exit 0
fi

# --- Защита от случайного прогона по всему парку ---
if [[ -z "$LIMIT" && "$CHECK" != "1" && "$ASSUME_YES" != "1" ]]; then
    read -r -p "Будет обработан ВЕСЬ inventory ($INVENTORY). Продолжить? [y/N] " answer
    [[ "$answer" =~ ^[YyДд]$ ]] || { echo "Отменено."; exit 1; }
fi

# --- Постоянный пароль RustDesk (необязательно) ---
if [[ "$ASK_PW" == "1" && -z "$PERM_PW" ]]; then
    [[ -t 0 ]] || die "--ask-password требует TTY"
    read -r -s -p "Постоянный пароль RustDesk: " PERM_PW
    echo
    read -r -s -p "Повтори пароль: " PERM_PW2
    echo
    [[ "$PERM_PW" == "$PERM_PW2" ]] || die "пароли не совпадают"
    unset PERM_PW2
fi

# --- Временные файлы (права 600, удаляются по выходу) ---
TMP_PASS=""
TMP_VARS=""
cleanup() {
    [[ -n "$TMP_PASS" ]] && rm -f "$TMP_PASS"
    [[ -n "$TMP_VARS" ]] && rm -f "$TMP_VARS"
    return 0
}
trap cleanup EXIT

# --- Пароль WinRM ---
if [[ -n "${ANSIBLE_WINRM_PASSWORD:-}" ]]; then
    TMP_PASS="$(mktemp)"
    chmod 600 "$TMP_PASS"
    printf '%s' "$ANSIBLE_WINRM_PASSWORD" > "$TMP_PASS"
    PASS_FILE="$TMP_PASS"
fi

if [[ -n "$PASS_FILE" && ! -r "$PASS_FILE" ]]; then
    die "файл с паролем недоступен: $PASS_FILE"
fi
if [[ -z "$PASS_FILE" ]]; then
    [[ -t 0 ]] || die "нет TTY для ввода пароля; используй --password-file или ANSIBLE_WINRM_PASSWORD"
    read -r -s -p "Пароль Windows (WinRM): " winpass
    echo
    [[ -n "$winpass" ]] || die "пустой пароль"
    TMP_PASS="$(mktemp)"
    chmod 600 "$TMP_PASS"
    printf '%s' "$winpass" > "$TMP_PASS"
    PASS_FILE="$TMP_PASS"
    unset winpass
fi

# --- Переменные роли в JSON-файл (чтобы пароль не светился в ps) ---
TMP_VARS="$(mktemp)"
chmod 600 "$TMP_VARS"
python3 - "$TMP_VARS" "$SERVER" "$KEY" "$VERSION" "$RELAY_PORT" \
    "$PERM_PW" "$FORCE" "$INSTALLER_URL" "$VALIDATE_CERTS" "$FORCE_PW" \
    "$INSTALL_TIMEOUT" "$PACKAGE_FORMAT" <<'PY'
import json
import sys

(out, server, key, version, port, perm_pw, force, url, validate, force_pw,
 timeout, pkg_format) = sys.argv[1:13]
data = {
    "rd_server": server,
    "rd_key": key,
    "rd_version": version,
    "rd_relay_port": int(port),
    "rd_permanent_password": perm_pw,
    "rd_force_install": force == "1",
    "rd_installer_url": url,
    "rd_validate_certs": validate == "1",
    "rd_force_password": force_pw == "1",
}
if timeout:
    data["rd_windows_install_timeout"] = int(timeout)
if pkg_format:
    data["rd_windows_package_format"] = pkg_format
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f)
PY

# --- Сборка команды ---
cmd=(ansible-playbook -i "$INVENTORY" "$PLAYBOOK" -f "$FORKS")
[[ -n "$LIMIT" ]] && cmd+=(--limit "$LIMIT")
cmd+=(-e "@$TMP_VARS")
[[ "$CHECK" == "1" ]] && cmd+=(--check --diff)
cmd+=(--connection-password-file "$PASS_FILE")

KEY_SHORT="${KEY:0:8}…${KEY: -4}"
PASSWORD_STATE="нет"
[[ -n "$PERM_PW" ]] && PASSWORD_STATE="да"
CACHE_COUNT="$(find "$CACHE_DIR" -maxdepth 1 -type f \
    \( -name "rustdesk-$VERSION-x86_64.msi" -o -name "rustdesk-$VERSION-aarch64.msi" \) \
    2>/dev/null | wc -l || true)"
INSTALLER_MODE="GitHub (с клиента)"
[[ "$CACHE_COUNT" != "0" ]] && INSTALLER_MODE="локальный кэш MSI ($CACHE_COUNT шт.)"
[[ -n "$INSTALLER_URL" ]] && INSTALLER_MODE="URL ($INSTALLER_URL)"

echo "──────────────────────────────────────────────"
echo " Playbook  : $PLAYBOOK"
echo " Inventory : $INVENTORY"
echo " Сервер    : $SERVER (relay :$RELAY_PORT)"
echo " Ключ      : $KEY_SHORT"
echo " Версия    : $VERSION"
echo " Установщик: $INSTALLER_MODE"
echo " Формат    : ${PACKAGE_FORMAT:-msi} (таймаут ${INSTALL_TIMEOUT:-900} с)"
echo " Пароль RD : $PASSWORD_STATE"
echo " Limit     : ${LIMIT:-весь инвентарь}"
echo " Forks     : $FORKS"
[[ "$FORCE" == "1" ]] && echo " Force     : да (переустановка)"
[[ "$FORCE_PW" == "1" ]] && echo " Force pw  : да (перезапись пароля)"
[[ "$CHECK" == "1" ]] && echo " Режим     : CHECK (без изменений)"
echo "──────────────────────────────────────────────"

rc=0
"${cmd[@]}" || rc=$?

if [[ "$rc" == "2" ]]; then
    echo >&2
    echo "ВНИМАНИЕ: на части хостов задачи завершились ошибкой (см. вывод выше)." >&2
elif [[ "$rc" == "4" ]]; then
    echo >&2
    echo "ВНИМАНИЕ: часть хостов недоступна по WinRM (выключены или закрыт 5985)." >&2
    echo "Остальные хосты обработаны; список успешных — в $REPORT_DIR." >&2
elif [[ "$rc" != "0" ]]; then
    echo >&2
    echo "ВНИМАНИЕ: ansible-playbook завершился с кодом $rc." >&2
fi

if [[ -d "$REPORT_DIR" && "$CHECK" != "1" ]]; then
    count="$(find "$REPORT_DIR" -maxdepth 1 -name '*.txt' -type f | wc -l)"
    echo
    echo "ID машин сохранены в $REPORT_DIR (файлов: $count)"
    echo "Посмотреть: grep -H rustdesk_id $REPORT_DIR/*.txt"
fi

exit "$rc"
