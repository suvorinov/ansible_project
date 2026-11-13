#!/bin/bash
# ansible_ping.sh - Ping всех Windows-хостов через Ansible

set -e

INVENTORY="inventory/windows_hosts.yml"

echo "=== Ping Windows-хостов через Ansible ==="

if [ -z "$ANSIBLE_WINRM_PASSWORD" ]; then
    read -rsp "Введите пароль для $USER: " ANSIBLE_WINRM_PASSWORD
    echo ""
    export ANSIBLE_WINRM_PASSWORD
fi

ansible-playbook -i "$INVENTORY" playbooks/ping_test.yml -e "ansible_password=$ANSIBLE_WINRM_PASSWORD"

echo ""
echo "=== Ping завершён ==="
