#!/bin/bash
# ansible_ping_host.sh - Ping одного Windows-хоста через Ansible

set -e

if [ -z "$1" ]; then
    echo "Использование: $0 <IP-адрес>"
    echo "Пример: $0 192.168.0.90"
    exit 1
fi

HOST="$1"

if [ -z "$ANSIBLE_WINRM_PASSWORD" ]; then
    read -rsp "Введите пароль для $USER: " ANSIBLE_WINRM_PASSWORD
    echo ""
    export ANSIBLE_WINRM_PASSWORD
fi

ansible -i "$HOST," all -m ansible.windows.win_ping -e "ansible_port=5985 ansible_connection=winrm ansible_winrm_server_cert_validation=ignore ansible_winrm_transport=ntlm ansible_user=Oleg.Suvorinov ansible_password=$ANSIBLE_WINRM_PASSWORD ansible_python_interpreter=powershell"
