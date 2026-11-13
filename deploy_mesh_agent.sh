#!/usr/bin/env bash
# ============================================================
#  deploy_mesh_agent.sh - массовая установка агента MeshCentral
#
#  Обёртка над playbooks/meshcentral_agent.yml. Сама подхватывает
#  ID группы устройств из базы MeshCentral, если он не задан.
#
#  Примеры:
#    ./deploy_mesh_agent.sh --syntax-check
#    ./deploy_mesh_agent.sh --mesh-id <ID> --limit 192.168.0.90 --check
#    ./deploy_mesh_agent.sh --mesh-id <ID> --limit 192.168.0.90
#    ./deploy_mesh_agent.sh --limit 192.168.0.90      # ID группы определится сам
#    ./deploy_mesh_agent.sh                           # весь флот
#
#  Пароль:
#    по умолчанию спросит интерактивно (--ask-pass);
#    либо задай файл:  --password-file /path/to/secret
#    либо переменную:  ANSIBLE_WINRM_PASSWORD=... ./deploy_mesh_agent.sh
#
#  Полезное:
#    --limit PATTERN   ограничить хосты (IP, диапазон, группа)
#    --check           пробный прогон без изменений
#    --force           переустановить агент, даже если уже стоит
#    --forks N         параллельность (по умолчанию 20)
#    --list            только показать, какие хосты попадут в прогон
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RMM_RA_DIR="${RMM_RA_DIR:-$HOME/opt/rmm-ra}"
INVENTORY="inventory/windows_hosts.yml"
PLAYBOOK="playbooks/meshcentral_agent.yml"
LIMIT=""
MESH_ID=""
PASS_FILE=""
FORKS="${FORKS:-20}"
MODE="deploy"
CHECK=0
FORCE=0
ASSUME_YES=0

usage() {
    cat <<'EOF'
============================================================
 deploy_mesh_agent.sh - массовая установка агента MeshCentral
============================================================

 Примеры:
   ./deploy_mesh_agent.sh --syntax-check
   ./deploy_mesh_agent.sh --mesh-id <ID> --limit 192.168.0.90 --check
   ./deploy_mesh_agent.sh --mesh-id <ID> --limit 192.168.0.90
   ./deploy_mesh_agent.sh --limit 192.168.0.90    # ID группы определится сам
   ./deploy_mesh_agent.sh --yes                   # весь флот без вопросов

 Пароль:
   по умолчанию спросит пароль WinRM интерактивно (без эха);
   либо --password-file /path/to/secret;
   либо ANSIBLE_WINRM_PASSWORD=... ./deploy_mesh_agent.sh

 Полезное:
   --mesh-id ID      ID группы устройств MeshCentral
   --limit PATTERN   ограничить хосты (IP, диапазон, группа)
   --check           пробный прогон без изменений
   --force           переустановить агент, даже если уже стоит
   --forks N         параллельность (по умолчанию 20)
   --list            показать хосты, которые попадут в прогон
   --yes             не спрашивать подтверждение для всего парка
   --inventory FILE  другой inventory
EOF
    exit "${1:-0}"
}

die() { echo "ОШИБКА: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mesh-id)          MESH_ID="${2:?--mesh-id требует значение}"; shift 2 ;;
        --mesh-id=*)        MESH_ID="${1#*=}"; shift ;;
        --limit|-l)         LIMIT="${2:?--limit требует значение}"; shift 2 ;;
        --limit=*)          LIMIT="${1#*=}"; shift ;;
        --inventory|-i)     INVENTORY="${2:?--inventory требует значение}"; shift 2 ;;
        --password-file)    PASS_FILE="${2:?--password-file требует значение}"; shift 2 ;;
        --forks)            FORKS="${2:?--forks требует значение}"; shift 2 ;;
        --check|-C)         CHECK=1; shift ;;
        --force)            FORCE=1; shift ;;
        --yes|-y)           ASSUME_YES=1; shift ;;
        --syntax-check|-S)  MODE="syntax"; shift ;;
        --list)             MODE="list"; shift ;;
        --help|-h)          usage 0 ;;
        *) die "неизвестный аргумент: $1 (см. --help)" ;;
    esac
done

[[ -f "$INVENTORY" ]] || die "inventory не найден: $INVENTORY"
[[ -f "$PLAYBOOK" ]]  || die "playbook не найден: $PLAYBOOK"

# --- Режим проверки синтаксиса: ни пароль, ни meshid не нужны ---
if [[ "$MODE" == "syntax" ]]; then
    exec ansible-playbook -i "$INVENTORY" "$PLAYBOOK" --syntax-check -e mc_mesh_id=__syntax_check__
fi

# --- Режим просмотра хостов ---
if [[ "$MODE" == "list" ]]; then
    cmd=(ansible-playbook -i "$INVENTORY" "$PLAYBOOK" --list-hosts)
    [[ -n "$LIMIT" ]] && cmd+=(--limit "$LIMIT")
    exec "${cmd[@]}"
fi

# --- Автоопределение ID группы устройств ---
if [[ -z "$MESH_ID" ]]; then
    [[ -x "$RMM_RA_DIR/scripts/mesh-id.sh" ]] || \
        die "не задан --mesh-id, а helper не найден: $RMM_RA_DIR/scripts/mesh-id.sh"

    mapfile -t ids < <("$RMM_RA_DIR/scripts/mesh-id.sh" --raw 2>/dev/null || true)
    case "${#ids[@]}" in
        0)  die "в MeshCentral нет групп устройств. Создай группу в UI и повтори, либо передай --mesh-id." ;;
        1)  MESH_ID="${ids[0]}"
            echo "→ Группа устройств определена автоматически: $MESH_ID" ;;
        *)  echo "Найдено несколько групп устройств:" >&2
            "$RMM_RA_DIR/scripts/mesh-id.sh" >&2 || true
            die "укажи нужную через --mesh-id <ID>" ;;
    esac
fi

# --- Защита от случайного прогона по всему парку ---
if [[ -z "$LIMIT" && "$CHECK" != "1" && "$ASSUME_YES" != "1" ]]; then
    read -r -p "Будет обработан ВЕСЬ inventory ($INVENTORY). Продолжить? [y/N] " answer
    [[ "$answer" =~ ^[YyДд]$ ]] || { echo "Отменено."; exit 1; }
fi

# --- Подготовка временного файла для пароля ---
TMP_PASS=""
cleanup() { [[ -n "$TMP_PASS" ]] && rm -f "$TMP_PASS"; }
trap cleanup EXIT

if [[ -n "${ANSIBLE_WINRM_PASSWORD:-}" ]]; then
    TMP_PASS="$(mktemp)"
    chmod 600 "$TMP_PASS"
    printf '%s' "$ANSIBLE_WINRM_PASSWORD" > "$TMP_PASS"
    PASS_FILE="$TMP_PASS"
fi

# --- Пароль: файл/переменная окружения или интерактивный ввод без эха ---
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

# --- Сборка команды ---
cmd=(ansible-playbook -i "$INVENTORY" "$PLAYBOOK" -f "$FORKS")
[[ -n "$LIMIT" ]] && cmd+=(--limit "$LIMIT")
cmd+=(-e "mc_mesh_id=$MESH_ID")
[[ "$FORCE" == "1" ]] && cmd+=(-e "mc_force_install=true")
[[ "$CHECK" == "1" ]] && cmd+=(--check --diff)
cmd+=(--connection-password-file "$PASS_FILE")

echo "──────────────────────────────────────────────"
echo " Playbook : $PLAYBOOK"
echo " Inventory: $INVENTORY"
echo " Mesh ID  : $MESH_ID"
echo " Limit    : ${LIMIT:-весь инвентарь}"
echo " Forks    : $FORKS"
[[ "$FORCE" == "1" ]] && echo " Force    : да (переустановка)"
[[ "$CHECK" == "1" ]] && echo " Режим    : CHECK (без изменений)"
echo "──────────────────────────────────────────────"

exec "${cmd[@]}"
