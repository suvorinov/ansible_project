# Ansible: раскатка MeshCentral и RustDesk

Ansible-роли и обёртки для массовой установки агентов MeshCentral и клиентов
RustDesk на парк Windows-машин (и Linux, где это поддерживается) через WinRM.
Серверная часть — в отдельном репозитории
[rmm-ra](https://github.com/suvorinov/rmm-ra).

## Состав

| Путь | Что делает |
|---|---|
| `roles/meshcentral_agent/` | установка и регистрация агента MeshCentral |
| `roles/rustdesk_client/` | установка RustDesk, привязка к своему hbbs/relay, постоянный пароль для unattended-доступа |
| `roles/windows_audit/` | снимок нагрузки/процессов, браузеры, история и закладки |
| `deploy_mesh_agent.sh` | обёртка для роли MeshCentral |
| `deploy_rustdesk.sh` | обёртка для роли RustDesk: кэш установщиков, `--check`, `--limit`, `--ask-password` |
| `collect_windows_audit.sh` | обёртка аудита: сбор, вывоз ZIP, HTML/CSV-отчёт |
| `playbooks/` | плейбуки ролей + вспомогательные (ping, сбор информации, прокси) |
| `inventory/windows_hosts.yml` | inventory парка (160 хостов) |
| `MESHCENTRAL_AGENT.md` | подробно про агент MeshCentral |
| `RUSTDESK_CLIENT.md` | подробно про клиент RustDesk, MSI, пароли, диагностику |
| `WINDOWS_AUDIT.md` | аудит хостов, правовая часть, отчёты |
| `ansible.cfg` | настройки Ansible (collections, roles, таймауты) |

## Требования

- Ansible 2.16+ на control-node, коллекция `ansible.windows`, `pywinrm`;
- WinRM на хостах (порт 5985), учётка администратора;
- для RustDesk — работающий сервер из [rmm-ra](https://github.com/suvorinov/rmm-ra)
  (hbbs/hbbr, ключ и адрес покажет `make rustdesk-info`).

Пароль WinRM **не хранится** в inventory: обёртки спрашивают его интерактивно
или читают из файла (`ANSIBLE_WINRM_PASSWORD`, `--password-file`).

## Быстрый старт

```bash
git clone git@github.com:suvorinov/ansible_project.git
cd ansible_project

# клиенты RustDesk: один раз положить MSI в кэш
./deploy_rustdesk.sh --prefetch

# проверка и установка на одном хосте
./deploy_rustdesk.sh --limit 192.168.0.90 --check
./deploy_rustdesk.sh --limit 192.168.0.90

# постоянный пароль (unattended-доступ), пароль спрашивается и не логируется
./deploy_rustdesk.sh --limit 192.168.0.90 --ask-password

# агент MeshCentral
./deploy_mesh_agent.sh --mesh-id <MESHID> --limit 192.168.0.90 --check
./deploy_mesh_agent.sh --mesh-id <MESHID> --limit 192.168.0.90

# аудит хоста: нагрузка, браузеры, история (7 дней), закладки
./collect_windows_audit.sh --limit 192.168.0.90
# отчёт: reports/windows_audit/latest/report/index.html
```

Массовый прогон — без `--limit` (обёртки попросят подтверждение). ID машин
складываются в `reports/rustdesk/<host>.txt`, отчёты аудита — в
`reports/windows_audit/`.

## Что не попадает в git

Установщики (`files/installers/*.msi`, ~50 МБ), отчёты прогонов с ID машин,
временный inventory и бэкапы — см. `.gitignore`. Установщики качаются командой
`./deploy_rustdesk.sh --prefetch`.

## Вспомогательные скрипты

`ansible_ping.sh`, `ansible_ping_host.sh`, `host_info.sh`, `run_playbook.py` и
плейбуки `ping_*`, `gather_*`, `host_detail`, `proxy`, `run_app` — ранние
утилиты для проверки связи и сбора информации. Они передают пароль через
`-e ansible_password=...` (виден в `ps`), поэтому для боевых прогонов
используйте обёртки `deploy_*.sh`.

## Документация

- [MESHCENTRAL_AGENT.md](MESHCENTRAL_AGENT.md) — агент MeshCentral;
- [RUSTDESK_CLIENT.md](RUSTDESK_CLIENT.md) — клиент RustDesk: MSI, `--check`,
  постоянный пароль, `verification-method`, разбор ошибок;
- [WINDOWS_AUDIT.md](WINDOWS_AUDIT.md) — аудит хостов: процессы, браузеры,
  история и закладки, правовая часть и хранение отчётов;
- [rmm-ra](https://github.com/suvorinov/rmm-ra) — серверная часть и её README.
