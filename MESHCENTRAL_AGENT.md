# Массовая установка агента MeshCentral через Ansible

> Репозиторий: <https://github.com/suvorinov/ansible_project>.
> Серверная часть — [rmm-ra](https://github.com/suvorinov/rmm-ra).

Роль `meshcentral_agent` ставит агента MeshCentral на Windows и Linux хосты
из существующего inventory `inventory/windows_hosts.yml`.

## Что делает роль

**Windows**
1. Определяет разрядность и выбирает тип агента: x64 → `4`, x86 → `3`, ARM64 → `43`.
2. Проверяет службу `Mesh Agent`.
3. Если агента нет (или задан `mc_force_install=true`) — скачивает установщик
   с `https://rmm.zr.local/meshagents?id=<тип>&meshid=<ID>&installflags=0`.
4. Запускает `MeshAgent.exe -fullinstall`.
5. Ждёт появления службы и запускает её.
6. Удаляет временный установщик и проверяет, что служба существует.

**Linux**
1. Проверяет наличие `/usr/local/mesh/meshagent`.
2. Скачивает официальный `https://rmm.zr.local/meshagents?script=1`.
3. Запускает `meshinstall.sh <url> <meshid>` через `become`.
4. Проверяет результат.

Роль идемпотентна: повторный прогон ничего не переустанавливает, если агент уже
стоит. Для принудительной переустановки — `--force`.

## Требования

- Ansible 2.16+ с коллекциями `ansible.windows` и `community.windows`;
  на этом сервере уже стоит.
- WinRM на хостах (порт 5985) и учётка с правами локального администратора.
- На клиентах резолвится `rmm.zr.local`:
  ```powershell
  Resolve-DnsName rmm.zr.local
  ```
- TLS-сертификат `rmm.zr.local` выписан внутренним УЦ `ZR-ADMIN Root CA`.
  Если корневой сертификат не добавлен в доверенные на клиенте — роль по
  умолчанию не проверяет сертификат (`mc_validate_certs: false`). Когда
  раскатаете корневой CA на клиентов, поставьте `mc_validate_certs: true`.
- В MeshCentral создана **группа устройств** — её ID (`meshid`) обязателен.

## Шаг 1. Создать группу устройств

В UI MeshCentral: **Мои устройства → Добавить группу устройств**
(например, `Windows`). ID группы появится после создания.

Либо посмотреть существующие группы из консоли на сервере RMM:

```bash
cd ~/opt/rmm-ra
make mesh-groups          # имя + meshid
./scripts/mesh-id.sh --raw   # только ID, для скриптов
```

## Шаг 2. Проверить синтаксис и список хостов

```bash
cd ~/working/ansible_project

./deploy_mesh_agent.sh --syntax-check
./deploy_mesh_agent.sh --list --limit 192.168.0.90
```

## Шаг 3. Пробный прогон на одном хосте

```bash
./deploy_mesh_agent.sh --mesh-id <MESHID> --limit 192.168.0.90 --check
```

`--check` показывает, что было бы сделано, но **не устанавливает** агент.
Некоторые шаги в check-режиме пропускаются — это нормально.

## Шаг 4. Установка на один хост

```bash
./deploy_mesh_agent.sh --mesh-id <MESHID> --limit 192.168.0.90
```

Пароль спросят интерактивно. Дальше проверьте в UI MeshCentral, что устройство
появилось в группе.

## Шаг 5. Раскатка на флот

```bash
# конкретные хосты
./deploy_mesh_agent.sh --mesh-id <MESHID> --limit "192.168.0.90,192.168.0.91"

# диапазон
./deploy_mesh_agent.sh --mesh-id <MESHID> --limit "192.168.0.3[1-5]"

# все хосты inventory
./deploy_mesh_agent.sh --mesh-id <MESHID>
```

Если группа в MeshCentral одна, `--mesh-id` можно не указывать — скрипт
подхватит её автоматически.

## Пароль и безопасность

По умолчанию пароль запрашивается интерактивно (ввод без эха) и не попадает
в историю команд и в `ps`. Варианты для автоматизации:

```bash
# файл с паролем (права 600)
./deploy_mesh_agent.sh --mesh-id <ID> --password-file ~/.winrm_pass

# переменная окружения (создаётся временный файл, удаляется после прогона)
ANSIBLE_WINRM_PASSWORD='...' ./deploy_mesh_agent.sh --mesh-id <ID>
```

Не коммитьте пароли и не передавайте их через `-e ansible_password=...` —
они видны в списке процессов.

## Полезные ключи

| Ключ | Значение |
|---|---|
| `--mesh-id ID` | ID группы устройств MeshCentral |
| `--limit PATTERN` | ограничить хосты (IP, диапазон, группа) |
| `--check` | пробный прогон без изменений |
| `--force` | переустановить агент, даже если стоит |
| `--forks N` | параллельность (по умолчанию 20) |
| `--list` | показать хосты, которые попадут в прогон |
| `--yes` | не спрашивать подтверждение для прогона по всему парку |
| `--inventory FILE` | другой inventory |
| `--password-file FILE` | файл с паролем WinRM |
| `--syntax-check` | только проверить синтаксис |

## Настройки роли

Файл `roles/meshcentral_agent/defaults/main.yml`:

| Переменная | По умолчанию | Смысл |
|---|---|---|
| `mc_base_url` | `https://rmm.zr.local` | адрес MeshCentral |
| `mc_mesh_id` | — | ID группы устройств (обязателен) |
| `mc_validate_certs` | `false` | проверять TLS-сертификат |
| `mc_force_install` | `false` | переустановка поверх |
| `mc_windows_service_name` | `Mesh Agent` | имя службы Windows |
| `mc_linux_install_path` | `/usr/local/mesh` | каталог агента Linux |

Переопределение на лету:

```bash
ansible-playbook -i inventory/windows_hosts.yml playbooks/meshcentral_agent.yml \
  -e mc_mesh_id=<ID> -e mc_validate_certs=true --limit 192.168.0.90 --ask-pass
```

## Диагностика

| Симптом | Что проверить |
|---|---|
| `UNREACHABLE` | WinRM/5985, firewall, пароль, `ansible_user` |
| `401`/`403` при скачивании агента | `lockagentdownload` в MeshCentral, доступность `rmm.zr.local` |
| Служба не появилась | права администратора, лог установки, антивирус |
| Устройство не в UI | время/часы на клиенте, DNS, `mc_mesh_id`; на сервере RMM: `make mesh-doctor` |
| Устройство мигает online/offline (рвётся раз в ~90с) | NPM режет WebSocket: на сервере RMM выполнить `make npm-ws-timeout` |
| Агент уже стоял, но в другой группе | роль пропустит установку; запусти с `--force` |
| `desktop_interact` у службы сбросился | обновись до текущей версии роли: она не трогает параметры службы |
| TLS-ошибка | добавить `ZR-ADMIN Root CA` в доверенные или `mc_validate_certs=false` |
| В логах MC `Agent bad web cert hash` | на сервере RMM выполнить `make pin-cert` |

Установленный агент на Windows можно проверить так:

```powershell
Get-Service 'Mesh Agent'
# точный путь к exe
(Get-CimInstance Win32_Service -Filter "Name='Mesh Agent'").PathName
```

На Linux:

```bash
sudo systemctl status meshagent
sudo /usr/local/mesh/meshagent -info
```

## Удаление агента

Windows — запустить `-fulluninstall` у того же exe, что прописан в службе:

```powershell
$exe = ((Get-CimInstance Win32_Service -Filter "Name='Mesh Agent'").PathName -replace '^"([^"]+)".*$','$1')
& $exe -fulluninstall
```

Linux (официальный скрипт поддерживает режим удаления):

```bash
wget -q https://rmm.zr.local/meshagents?script=1 -O /tmp/meshinstall.sh
chmod +x /tmp/meshinstall.sh
sudo /tmp/meshinstall.sh uninstall https://rmm.zr.local <MESHID>
```

После удаления устройство останется в MeshCentral — его нужно удалить в UI
вручную.
