#!/usr/bin/env python3
# ~/ansible_project/generate_inventory.py

"""
Скрипт для генерации статического YAML-файла инвентаря Ansible
с хостами Windows в диапазоне 192.168.0.31 - 192.168.0.190.
"""

RANGE_START = 31
RANGE_END = 191  # range() не включает последнее число

# Шаблон YAML для инвентаря
yaml_template = '''all:
  children:
    windows_hosts:
      hosts:
{hosts_block}
      vars:
        ansible_port: 5985
        ansible_connection: winrm
        ansible_winrm_server_cert_validation: ignore
        ansible_winrm_transport: ntlm
        ansible_user: Oleg.Suvorinov
        ansible_python_interpreter: powershell
'''

# Шаблон для одного хоста
host_entry_template = '''        "{ip_addr}":
          ansible_host: {ip_addr}

'''


def generate_hosts_block():
    hosts_lines = []
    for i in range(RANGE_START, RANGE_END):
        ip_addr = f"192.168.0.{i}"
        hosts_lines.append(host_entry_template.format(ip_addr=ip_addr))
    return "".join(hosts_lines)


def main():
    hosts_block = generate_hosts_block()
    final_yaml = yaml_template.format(hosts_block=hosts_block)
    output_filename = 'generated_inventory.yml'

    try:
        with open(output_filename, 'w', encoding='utf-8') as f:
            f.write(final_yaml)
        print(f"Файл инвентаря '{output_filename}' успешно создан.")
        print(f"Количество хостов: {RANGE_END - RANGE_START}")
    except IOError as e:
        print(f"Ошибка при записи файла инвентаря: {e}")


if __name__ == '__main__':
    main()
