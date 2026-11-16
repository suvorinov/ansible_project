# Клиенты RustDesk: массовая установка

> Репозиторий: <https://github.com/suvorinov/ansible_project>.
> Серверная часть — [rmm-ra](https://github.com/suvorinov/rmm-ra).

Роль `rustdesk_client` ставит RustDesk на Windows/Linux и настраивает его на
self-hosted сервер из [rmm-ra](https://github.com/suvorinov/rmm-ra) (локально
`~/opt/rmm-ra`, hbbs/hbbr). Ставится поверх того же inventory, что и агенты
MeshCentral.

## Что делает роль

1. Проверяет, установлен ли клиент и какая версия.
2. Берёт MSI из локального кэша на control-node (или с GitHub) и ставит его
   через `msiexec /i ... /qn /norestart` — с журналом и кодом возврата.
   Установщик запускается с таймаутом (`rd_windows_install_timeout`, 15 мин):
   если он завис, процесс убивается, а задача падает с последними строками
   журнала, а не висит бесконечно.
3. Регистрирует службу `RustDesk`, включает автозапуск и запускает её.
4. Прописывает параметры подключения через CLI (`rustdesk.exe --option`):
   - `custom-rendezvous-server` — адрес hbbs;
   - `relay-server` — `<hbbs>:21117`;
   - `key` — публичный ключ сервера.
5. Опционально задаёт постоянный пароль (`--password`) для unattended-доступа
   и включает `verification-method=use-permanent-password`, чтобы не нужен был
   одноразовый пароль с экрана клиента.
6. Забирает `--get-id` и сохраняет ID на control-node в
   `reports/rustdesk/<host>.txt`.
7. Проверяет, что параметры реально попали в конфиг **службы**
   (`C:\Windows\ServiceProfiles\LocalService\...\RustDesk2.toml`), а не в
   профиль пользователя WinRM — иначе `--option` при недоступном IPC тихо
   пишет не туда.

Параметры пишутся только если отличаются от текущих — повторный прогон
идемпотентен.

## Быстрый старт

```bash
cd ~/working/ansible_project

# 1. Проверить синтаксис и состав
./deploy_rustdesk.sh --syntax-check
./deploy_rustdesk.sh --list --limit 192.168.0.143

# 2. Пробный прогон
./deploy_rustdesk.sh --limit 192.168.0.143 --check

# 3. Одна машина
./deploy_rustdesk.sh --limit 192.168.0.143

# 4. Партия / весь парк
#    Маски: 192.168.0.14* — это 140-149, 14*,15* — 140-159.
./deploy_rustdesk.sh --limit '192.168.0.14*,192.168.0.15*,192.168.0.160'
./deploy_rustdesk.sh --yes
```

Адрес сервера и ключ обёртка берёт сама:

- `SERVER_IP` — из `~/opt/rmm-ra/.env`;
- ключ — из `~/opt/rmm-ra/rustdesk-data/id_ed25519.pub`.

Проверить, что она видит:

```bash
cd ~/opt/rmm-ra && make rustdesk-info
```

## Установщики: локальный кэш

По умолчанию каждый клиент качает установщик с GitHub сам. Это требует
интернета на клиентах и даёт ~25 МБ трафика на машину. Надёжнее один раз
положить установщики на control-node и раздавать их по WinRM:

```bash
./deploy_rustdesk.sh --prefetch             # latest
./deploy_rustdesk.sh --prefetch --version 1.5.3
```

Файлы появятся в `files/installers/` (`x86_64.msi` и `aarch64.msi`).
Дальше роль сама увидит кэш (`deploy_rustdesk.sh` пишет «Установщик:
локальный кэш MSI») и скопирует нужный файл на хост — GitHub клиентам уже не
нужен. Контрольные суммы — в `files/installers/SHA256SUMS.txt`.

Ставится именно MSI: exe-установщик RustDesk (`--silent-install`) — это
NSIS-обёртка, которая из WinRM-сессии может повиснуть на невидимом диалоге
UAC. Если exe всё же нужен, задай `-e rd_windows_package_format=exe` (или
`--installer-url` со ссылкой на `.exe`); таймаут действует и там.

## Пароль WinRM

Как и для MeshCentral:

```bash
./deploy_rustdesk.sh --limit 192.168.0.143                 # спросит
./deploy_rustdesk.sh --password-file ~/.winrm_pass         # из файла
ANSIBLE_WINRM_PASSWORD=... ./deploy_rustdesk.sh --limit ... # из окружения
```

## Постоянный пароль RustDesk (unattended-доступ)

По умолчанию RustDesk показывает на удалённом экране одноразовый пароль — он
меняется и нужен только для разового подключения «здесь и сейчас». Для
постоянного доступа задай постоянный пароль:

```bash
./deploy_rustdesk.sh --limit 192.168.0.143 --ask-password
# или
RUSTDESK_PERMANENT_PASSWORD='...' ./deploy_rustdesk.sh --limit 192.168.0.143
```

Что делает роль:

- пароль уходит в конфиг **службы** (`C:\Windows\ServiceProfiles\LocalService\
  AppData\Roaming\RustDesk\config\RustDesk.toml`, шифрованный вид), а не в
  профиль WinRM-пользователя; после установки это проверяется, как и остальные
  параметры;
- при заданном пароле включается опция `verification-method=use-permanent-password`
  — одноразовый пароль с экрана больше не нужен и не принимается;
- пароль ставится только если его ещё нет; перезаписать — `--force-password`;
- в отчёт `reports/rustdesk/<host>.txt` пишется `permanent_password=yes/no`.

Команда `rustdesk.exe --password` общается со службой по IPC и при таймауте
(ACK ждётся 1 секунда) или отказе печатает ошибку, но возвращает код 0. Поэтому
роль делает до 5 попыток и проверяет результат **по файлу конфига**, а не по
коду возврата. Если пароль так и не записался, роль **не** включает режим
«только постоянный пароль» (иначе на хосте не останется ни одного рабочего
пароля), возвращает одноразовый пароль с экрана, пишет в ошибке ответ команды
`--password` и список ключей в `RustDesk.toml`, и падает. В этом случае просто
повтори прогон.

Пароль общий на парк или свой на хост — решай сам; в git его не кладём
(`--ask-password` не пишет его в лог и в историю shell).

## Подключение без ввода пароля

Полностью «без пароля» в OSS-версии нельзя: hbbs только сводит пиров, а
удалённый хост сам проверяет пароль (серверной аутентификации нет). Но пароль
можно передать клиенту сразу, и диалог не появится:

```powershell
& 'C:\Program Files\RustDesk\rustdesk.exe' --connect 511788413 --password 'ТвойПароль'
```

То же ссылкой (её можно повесить ярлыком):

```
rustdesk://connection/new/511788413?password=ТвойПароль
```

Это штатный CLI RustDesk: `--connect <ID> --password <пароль>` заполняет
параметры нового подключения и сразу подключается. Если на удалённой машине
есть человек, альтернатива паролю — подтверждение кликом
(`--option approve-mode click`), но для необслуживаемых хостов это не вариант.

ID машин по парку:

```bash
grep -H rustdesk_id ~/working/ansible_project/reports/rustdesk/*.txt
grep -L 'permanent_password=yes' ~/working/ansible_project/reports/rustdesk/*.txt
```

## Полезные ключи обёртки

| Ключ | Что делает |
|---|---|
| `--server HOST` | адрес hbbs (по умолчанию из `.env`) |
| `--key BASE64` | публичный ключ (по умолчанию из `rustdesk-data`) |
| `--relay-port N` | порт hbbr (21117) |
| `--version X.Y.Z` | версия клиента (по умолчанию `latest`) |
| `--prefetch` | скачать установщики в `files/installers` и выйти |
| `--installer-url URL` | явный URL установщика |
| `--package-format msi\|exe` | формат установщика (по умолчанию `msi`) |
| `--install-timeout SEC` | сколько ждать установщик (по умолчанию 900) |
| `--check` | пробный прогон |
| `--force` | переустановить клиент |
| `--no-validate-certs` | не проверять TLS при скачивании |
| `--limit`, `--forks`, `--yes` | как у `deploy_mesh_agent.sh` |

## Проверка результата

На клиенте:

```powershell
Get-Service RustDesk
& 'C:\Program Files\RustDesk\rustdesk.exe' --get-id
& 'C:\Program Files\RustDesk\rustdesk.exe' --option custom-rendezvous-server
```

На сервере:

```bash
cd ~/opt/rmm-ra
make rustdesk-info            # «пиров в базе» должно вырасти
docker logs rustdesk-hbbs --since 10m | tail -20
```

ID машин: `grep -H rustdesk_id ~/working/ansible_project/reports/rustdesk/*.txt`.

## Диагностика

| Симптом | Причина / решение |
|---|---|
| `Installation and administrative privileges required` | WinRM-сессия без прав администратора; проверь `ansible_user` |
| `Параметры не попали в конфиг службы` | IPC службы недоступен сессии WinRM; проверь, что служба запущена, а пользователь — админ; перезапусти службу и повтори |
| `--option` возвращает пусто | служба `RustDesk` не запущена |
| ID не получен | служба не стартовала; `Get-Service RustDesk`, `--install-service` |
| Пиры не появляются | нет связи с `192.168.0.9:21116` (TCP/UDP) — проверь firewall |
| UDP закрыт | клиенты обычно падают на TCP; при проблемах задай `--option disable-udp Y` |
| ID изменился после переустановки | клиент пересоздал конфиг; ID берётся из отчёта после прогона |
| Не скачивается установщик | корпоративный прокси/антивирус; сделай `--prefetch` или задай `--installer-url` |
| Установка упала с `rc=990` | установщик не уложился в `rd_windows_install_timeout` (15 мин) и был убит; смотри журнал `C:\Windows\Temp\rustdesk-install.log` на хосте (он печатается в ошибке) |
| Прогон «завис» на установке | так вёл себя exe-установщик (`--silent-install` + невидимый UAC); роль теперь ставит MSI с таймаутом и сама снимает зависшие процессы из `C:\Windows\Temp` |
| `1618` / «другая установка уже идёт» | на хосте остался чужой msiexec; дождись или сними процесс, повтори |
| MSI: «installed by self-installation method» | на хосте версия от exe-инсталлятора; удали её (`rustdesk.exe --uninstall`) и повтори; без `--force` роль просто настроит её |
| Часть хостов «недоступна» | WinRM/питание/5985; остальные хосты обрабатываются, код выхода 4 |

## Безопасность

- OSS-сервер RustDesk не имеет своей аутентификации: кто знает ID и пароль —
  тот и подключится. Поэтому постоянные пароли обязательны, а порты
  `21115-21119` не стоит публиковать в интернет.
- `21115-21119` должны быть доступны клиентам, но не всему миру: ограничь
  firewall'ом подсетью `192.168.0.0/24`.
- На NPM RustDesk не проксируется — это отдельные TCP/UDP-порты.
