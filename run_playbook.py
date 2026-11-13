#!/usr/bin/env python3
# ~/ansible_project/run_playbook.py
# Универсальный скрипт для запуска ansible-playbook из Python

import subprocess
import os
import sys
import json
import argparse


def run_playbook(playbook, inventory, limit=None, password=None, extra_vars=None):
    """Запуск ansible-playbook из Python."""
    cmd = [
        "ansible-playbook",
        "-i", inventory,
        playbook,
    ]

    if limit:
        cmd.extend(["--limit", limit])

    vars_dict = {}
    if password:
        vars_dict["ansible_password"] = password
    if extra_vars:
        vars_dict.update(extra_vars)

    if vars_dict:
        vars_json = json.dumps(vars_dict)
        cmd.extend(["-e", vars_json])

    print(f"Запуск: {' '.join(cmd)}")
    print("-" * 60)

    result = subprocess.run(
        cmd,
        capture_output=False,
        text=True,
        cwd=os.path.dirname(os.path.abspath(__file__))
    )

    return result.returncode


def gather_info(password, host=None):
    limit = host if host else None
    return run_playbook(
        playbook="playbooks/gather_info.yml",
        inventory="inventory/windows_hosts.yml",
        limit=limit,
        password=password
    )


def host_detail(password, host):
    return run_playbook(
        playbook="playbooks/host_detail.yml",
        inventory="inventory/windows_hosts.yml",
        limit=host,
        password=password
    )


def ping_hosts(password, host=None):
    limit = host if host else None
    return run_playbook(
        playbook="playbooks/ping_test.yml",
        inventory="inventory/windows_hosts.yml",
        limit=limit,
        password=password
    )


def run_app(password, host, app):
    return run_playbook(
        playbook="playbooks/run_app.yml",
        inventory="inventory/windows_hosts.yml",
        limit=host,
        password=password,
        extra_vars={"app": app}
    )


def proxy(password, host, proxy_action, proxy_server=None):
    extra = {"proxy_action": proxy_action}
    if proxy_server:
        extra["proxy_server"] = proxy_server
    return run_playbook(
        playbook="playbooks/proxy.yml",
        inventory="inventory/windows_hosts.yml",
        limit=host,
        password=password,
        extra_vars=extra
    )


def main():
    parser = argparse.ArgumentParser(description="Запуск Ansible playbooks")
    parser.add_argument("action", choices=["ping", "info", "detail", "run", "proxy"],
                        help="Действие: ping, info, detail, run, proxy")
    parser.add_argument("-H", "--host", help="IP-адрес хоста")
    parser.add_argument("-p", "--password", help="Пароль WinRM")
    parser.add_argument("-a", "--app", help="URL или путь к приложению (для run)")
    parser.add_argument("-s", "--server", help="Прокси-сервер (для proxy), например: 192.168.1.100:8080")
    parser.add_argument("--disable", action="store_true", help="Выключить прокси (для proxy)")

    args = parser.parse_args()

    password = args.password or os.environ.get("ANSIBLE_WINRM_PASSWORD")
    if not password:
        password = input("Введите пароль WinRM: ")

    if args.action == "ping":
        rc = ping_hosts(password, args.host)
    elif args.action == "info":
        rc = gather_info(password, args.host)
    elif args.action == "detail":
        if not args.host:
            print("Нужно указать хост: --host 192.168.0.90")
            sys.exit(1)
        rc = host_detail(password, args.host)
    elif args.action == "run":
        if not args.host or not args.app:
            print("Нужно указать хост и приложение:")
            print("  python3 run_playbook.py run -H 192.168.0.90 -a https://google.com")
            sys.exit(1)
        rc = run_app(password, args.host, args.app)
    elif args.action == "proxy":
        if not args.host:
            print("Нужно указать хост: --host 192.168.0.90")
            sys.exit(1)
        if args.disable:
            proxy_act = "disable"
            server = None
        elif args.server:
            proxy_act = "enable"
            server = args.server
        else:
            proxy_act = "status"
            server = None
        rc = proxy(password, args.host, proxy_act, server)

    sys.exit(rc)


if __name__ == "__main__":
    main()
