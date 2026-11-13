#!/bin/bash
# host_info.sh - Получить информацию о конкретном Windows-хосте

set -e

if [ -z "$1" ]; then
    echo "Использование: $0 <IP-адрес>"
    echo "Пример: $0 192.168.0.90"
    exit 1
fi

HOST="$1"
INVENTORY="inventory/windows_hosts.yml"

if [ -z "$ANSIBLE_WINRM_PASSWORD" ]; then
    read -rsp "Введите пароль для $USER: " ANSIBLE_WINRM_PASSWORD
    echo ""
    export ANSIBLE_WINRM_PASSWORD
fi

echo "=== Информация о хосте $HOST ==="
ansible-playbook -i "$INVENTORY" playbooks/host_detail.yml --limit "$HOST" -e "ansible_password=$ANSIBLE_WINRM_PASSWORD"
