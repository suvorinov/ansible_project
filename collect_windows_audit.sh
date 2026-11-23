#!/usr/bin/env bash
# ============================================================
#  collect_windows_audit.sh - аудит Windows-хостов
#
#  Собирает с хостов по WinRM:
#    - нагрузку: ОС, CPU, RAM, диски, uptime, процессы (память/CPU/владелец);
#    - браузеры: установленные и запущенные (Chrome, Edge, Yandex, Brave,
#      Vivaldi, Chromium, Opera, Firefox);
#    - историю посещений и закладки по профилям пользователей.
#
#  Архивы складываются в reports/windows_audit/<прогон>/raw/,
#  затем разбираются в HTML/CSV в reports/windows_audit/<прогон>/report/.
#
#  Примеры:
#    ./collect_windows_audit.sh --limit 192.168.0.90
#    ./collect_windows_audit.sh --limit 192.168.0.90 --history-days 30
#    ./collect_windows_audit.sh --limit 192.168.0.14* --yes
#    ./collect_windows_audit.sh --syntax-check
#    ./collect_windows_audit.sh --limit 192.168.0.90 --no-history
#
#  Пароль WinRM:
#    по умолчанию спросит интерактивно;
#    либо --password-file /path/to/secret;
#    либо ANSIBLE_WINRM_PASSWORD=... ./collect_windows_audit.sh
#
#  Полезное:
#    --history-days N   глубина истории (по умолчанию 7; 0 = вся);
#    --no-history       не собирать историю;
#    --no-bookmarks     не собирать закладки;
#    --no-profiles      только система, процессы и браузеры;
#    --keep-script      оставить .ps1 на хосте;
#    --keep-zip         оставить ZIP на хосте;
#    --check            пробный прогон без изменений;
#    --list             показать хосты, которые попадут в прогон;
#    --forks N          параллельность (по умолчанию 10);
#    --report-root DIR  куда класть прогоны.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INVENTORY="inventory/windows_hosts.yml"
PLAYBOOK="playbooks/windows_audit.yml"
REPORT_ROOT="$SCRIPT_DIR/reports/windows_audit"

LIMIT=""
PASS_FILE=""
FORKS="${FORKS:-10}"
MODE="run"
CHECK=0
ASSUME_YES=0
HISTORY_DAYS="${AUDIT_HISTORY_DAYS:-7}"
MAX_HISTORY=500
MAX_BOOKMARKS=1000
TITLE="Аудит Windows-хостов"
INCLUDE_HISTORY=1
INCLUDE_BOOKMARKS=1
INCLUDE_PROFILES=1
KEEP_SCRIPT=0
KEEP_ZIP=0
COLLECT_TIMEOUT=1200
PARSE=1

usage() {
    cat <<'EOF'
============================================================
 collect_windows_audit.sh - аудит Windows-хостов
============================================================

 Примеры:
   ./collect_windows_audit.sh --limit 192.168.0.90
   ./collect_windows_audit.sh --limit 192.168.0.90 --history-days 30
   ./collect_windows_audit.sh --limit 192.168.0.14* --yes
   ./collect_windows_audit.sh --syntax-check

 Пароль WinRM:
   по умолчанию спросит интерактивно (без эха);
   либо --password-file /path/to/secret;
   либо ANSIBLE_WINRM_PASSWORD=... ./collect_windows_audit.sh

 Что собирается:
   нагрузка и процессы, установленные/запущенные браузеры,
   история посещений и закладки по профилям пользователей.

 Ограничения сбора:
   --history-days N   глубина истории в днях (по умолчанию 7, 0 = вся)
   --no-history       не собирать историю
   --no-bookmarks     не собирать закладки
   --no-profiles      не обходить профили (только система и браузеры)
   --keep-script      оставить PowerShell-сборщик на хосте
   --keep-zip         оставить ZIP на хосте

 Прогон:
   --limit PATTERN    ограничить хосты (IP, диапазон, группа)
   --check            пробный прогон без изменений
   --list             показать хосты, которые попадут в прогон
   --forks N          параллельность (по умолчанию 10)
   --inventory FILE   другой inventory
   --report-root DIR  каталог для прогонов
   --title TEXT       заголовок HTML-отчёта
   --max-history N    сколько записей истории показывать в HTML
   --max-bookmarks N  сколько закладок показывать в HTML
   --no-parse         только собрать архивы, без отчёта
   --yes              не спрашивать подтверждение для всего парка
EOF
    exit "${1:-0}"
}

die() { echo "ОШИБКА: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --limit|-l)        LIMIT="${2:?--limit требует значение}"; shift 2 ;;
        --limit=*)         LIMIT="${1#*=}"; shift ;;
        --password-file)   PASS_FILE="${2:?--password-file требует значение}"; shift 2 ;;
        --forks)           FORKS="${2:?--forks требует значение}"; shift 2 ;;
        --inventory|-i)    INVENTORY="${2:?--inventory требует значение}"; shift 2 ;;
        --history-days)    HISTORY_DAYS="${2:?--history-days требует значение}"; shift 2 ;;
        --max-history)     MAX_HISTORY="${2:?--max-history требует значение}"; shift 2 ;;
        --max-bookmarks)   MAX_BOOKMARKS="${2:?--max-bookmarks требует значение}"; shift 2 ;;
        --report-root)     REPORT_ROOT="${2:?--report-root требует значение}"; shift 2 ;;
        --title)           TITLE="${2:?--title требует значение}"; shift 2 ;;
        --collect-timeout) COLLECT_TIMEOUT="${2:?--collect-timeout требует значение}"; shift 2 ;;
        --no-history)      INCLUDE_HISTORY=0; shift ;;
        --no-bookmarks)    INCLUDE_BOOKMARKS=0; shift ;;
        --no-profiles)     INCLUDE_PROFILES=0; shift ;;
        --keep-script)     KEEP_SCRIPT=1; shift ;;
        --keep-zip)        KEEP_ZIP=1; shift ;;
        --no-parse)        PARSE=0; shift ;;
        --check|-C)        CHECK=1; shift ;;
        --yes|-y)          ASSUME_YES=1; shift ;;
        --syntax-check|-S) MODE="syntax"; shift ;;
        --list)            MODE="list"; shift ;;
        --help|-h)         usage 0 ;;
        *) die "неизвестный аргумент: $1 (см. --help)" ;;
    esac
done

[[ -f "$INVENTORY" ]] || die "inventory не найден: $INVENTORY"
[[ -f "$PLAYBOOK" ]]  || die "playbook не найден: $PLAYBOOK"

[[ "$HISTORY_DAYS" =~ ^[0-9]+$ ]] || die "--history-days: нужно целое число дней"
[[ "$MAX_HISTORY" =~ ^[0-9]+$ ]] || die "--max-history: нужно целое число"
[[ "$MAX_BOOKMARKS" =~ ^[0-9]+$ ]] || die "--max-bookmarks: нужно целое число"
[[ "$COLLECT_TIMEOUT" =~ ^[0-9]+$ ]] || die "--collect-timeout: нужно целое число секунд"
[[ "$FORKS" =~ ^[0-9]+$ ]] || die "--forks: нужно целое число"

# --- Режим проверки синтаксиса ---
if [[ "$MODE" == "syntax" ]]; then
    exec ansible-playbook -i "$INVENTORY" "$PLAYBOOK" --syntax-check
fi

# --- Режим просмотра хостов ---
if [[ "$MODE" == "list" ]]; then
    cmd=(ansible-playbook -i "$INVENTORY" "$PLAYBOOK" --list-hosts)
    [[ -n "$LIMIT" ]] && cmd+=(--limit "$LIMIT")
    exec "${cmd[@]}"
fi

# --- Защита от случайного прогона по всему парку ---
if [[ -z "$LIMIT" && "$CHECK" != "1" && "$ASSUME_YES" != "1" ]]; then
    read -r -p "Будет обработан ВЕСЬ inventory ($INVENTORY). Продолжить? [y/N] " answer
    [[ "$answer" =~ ^[YyДд]$ ]] || { echo "Отменено."; exit 1; }
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

# --- Каталог прогона ---
STAMP="$(date +%Y-%m-%d_%H%M%S)"
RUN_DIR="$REPORT_ROOT/$STAMP"
mkdir -p "$RUN_DIR/raw"
chmod 700 "$REPORT_ROOT" "$RUN_DIR" "$RUN_DIR/raw"

# --- Переменные роли в JSON (пароль в командной строке не светится) ---
TMP_VARS="$(mktemp)"
chmod 600 "$TMP_VARS"
python3 - "$TMP_VARS" "$RUN_DIR" "$INCLUDE_HISTORY" "$INCLUDE_BOOKMARKS" \
    "$INCLUDE_PROFILES" "$KEEP_SCRIPT" "$KEEP_ZIP" "$COLLECT_TIMEOUT" <<'PY'
import json
import sys

(out, run_dir, hist, bm, profiles, keep_script, keep_zip,
 timeout) = sys.argv[1:9]
data = {
    "wa_report_dir": run_dir,
    "wa_include_history": hist == "1",
    "wa_include_bookmarks": bm == "1",
    "wa_include_profiles": profiles == "1",
    "wa_keep_remote_script": keep_script == "1",
    "wa_keep_remote_zip": keep_zip == "1",
    "wa_collect_timeout": int(timeout),
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f)
PY

# --- Команда ansible ---
cmd=(ansible-playbook -i "$INVENTORY" "$PLAYBOOK" -f "$FORKS")
[[ -n "$LIMIT" ]] && cmd+=(--limit "$LIMIT")
cmd+=(-e "@$TMP_VARS")
[[ "$CHECK" == "1" ]] && cmd+=(--check --diff)
cmd+=(--connection-password-file "$PASS_FILE")

echo "──────────────────────────────────────────────"
echo " Playbook  : $PLAYBOOK"
echo " Inventory : $INVENTORY"
echo " Прогон    : $RUN_DIR"
echo " История   : $([[ "$INCLUDE_HISTORY" == 1 ]] && echo "${HISTORY_DAYS} дн." || echo 'выключена')"
echo " Закладки  : $([[ "$INCLUDE_BOOKMARKS" == 1 ]] && echo 'да' || echo 'нет')"
echo " Профили   : $([[ "$INCLUDE_PROFILES" == 1 ]] && echo 'да' || echo 'нет')"
echo " Режим     : $([[ "$CHECK" == 1 ]] && echo 'проверка (--check)' || echo 'сбор')"
echo "──────────────────────────────────────────────"

rc=0
"${cmd[@]}" || rc=$?

# 4 = часть хостов недоступна; это нормально, разбираем то, что собрали.
if [[ "$rc" != "0" && "$rc" != "4" ]]; then
    die "ansible-playbook завершился с кодом $rc"
fi
[[ "$rc" == "4" ]] && echo "ВНИМАНИЕ: часть хостов была недоступна (код 4)." >&2

ZIP_COUNT="$(find "$RUN_DIR/raw" -maxdepth 1 -name '*.zip' -type f 2>/dev/null | wc -l)"
echo "Собрано архивов: $ZIP_COUNT"

if [[ "$CHECK" == "1" ]]; then
    echo "Режим --check: отчёт не собирается."
    exit 0
fi

if [[ "$PARSE" != "1" ]]; then
    echo "Архивы: $RUN_DIR/raw"
    exit 0
fi

if [[ "$ZIP_COUNT" == "0" ]]; then
    die "ни одного архива не собрано; смотри вывод ansible выше"
fi

# --- Разбор и отчёт ---
python3 scripts/parse_windows_audit.py \
    --raw "$RUN_DIR/raw" \
    --out "$RUN_DIR/report" \
    --history-days "$HISTORY_DAYS" \
    --max-history "$MAX_HISTORY" \
    --max-bookmarks "$MAX_BOOKMARKS" \
    --title "$TITLE"

# --- Указатель на последний прогон ---
ln -sfnT "$RUN_DIR" "$REPORT_ROOT/latest"

cat <<EOF
──────────────────────────────────────────────
 Готово.
 Архивы : $RUN_DIR/raw
 Отчёт  : $RUN_DIR/report/index.html
 Ссылка : $REPORT_ROOT/latest/report/index.html

 Отчёт содержит историю и закладки — это персональные данные.
 Каталог создан с правами 0700, файлы 0600. Не публиковать.
──────────────────────────────────────────────
EOF
