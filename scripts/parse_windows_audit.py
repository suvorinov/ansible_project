#!/usr/bin/env python3
"""Разбор архивов аудита Windows и сборка HTML/CSV-отчёта.

На вход подаётся каталог с ZIP-файлами, которые собрала роль
windows_audit (или вручную Invoke-WindowsAudit.ps1). На выходе:

    index.html              - сводка по хостам;
    hosts/<host>.html       - карточка хоста;
    hosts/<host>.json       - те же данные для интеграций;
    summary.csv             - одна строка на хост;
    history.csv             - история посещений (все хосты);
    bookmarks.csv           - закладки (все хосты);
    top_processes.csv       - топ процессов по памяти/CPU.

История и закладки — персональные данные. Скрипт ставит права 0700/0600
и не должен использоваться для публикации отчётов в открытый доступ.
"""

from __future__ import annotations

import argparse
import csv
import html
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

CHROME_EPOCH = datetime(1601, 1, 1, tzinfo=timezone.utc)
UNIX_EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)

CSS = """
:root {
  color-scheme: light dark;
  --bg: #f4f6f9; --card: #fff; --text: #1c2430; --muted: #6b7785;
  --line: #e3e8ef; --accent: #2563eb; --warn: #b45309; --warn-bg: #fff4e5;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #12161c; --card: #1a2029; --text: #e6ebf2; --muted: #93a0b0;
    --line: #2a3440; --accent: #6ea8fe; --warn: #ffc078; --warn-bg: #3a2a12;
  }
}
* { box-sizing: border-box; }
body { margin: 0; padding: 24px; background: var(--bg); color: var(--text);
       font: 15px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
.wrap { max-width: 1280px; margin: 0 auto; }
h1 { font-size: 22px; margin: 0 0 4px; }
h2 { font-size: 18px; margin: 24px 0 8px; }
h3 { font-size: 16px; margin: 18px 0 6px; }
.sub { color: var(--muted); margin-bottom: 18px; }
.cards { display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 16px; }
.stat { background: var(--card); border: 1px solid var(--line); border-radius: 10px;
        padding: 12px 16px; min-width: 150px; }
.stat b { display: block; font-size: 24px; }
.stat span { color: var(--muted); font-size: 13px; }
.alert { background: var(--warn-bg); border: 1px solid var(--line); border-radius: 10px;
         padding: 12px 16px; margin-bottom: 16px; }
.toolbar { display: flex; gap: 10px; align-items: center; margin: 0 0 12px; }
input[type=search] { flex: 1 1 260px; padding: 9px 12px; border-radius: 8px;
                     border: 1px solid var(--line); background: var(--card); color: var(--text); }
table { width: 100%; border-collapse: collapse; background: var(--card);
        border: 1px solid var(--line); border-radius: 10px; overflow: hidden; }
th, td { padding: 8px 12px; border-bottom: 1px solid var(--line); text-align: left;
         vertical-align: top; }
th { position: sticky; top: 0; background: var(--card); font-size: 13px;
     color: var(--muted); text-transform: uppercase; letter-spacing: .03em; }
tr:last-child td { border-bottom: none; }
tr.hide { display: none; }
.muted { color: var(--muted); }
.mono { font: 13px ui-monospace, SFMono-Regular, Consolas, monospace; }
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
code { font: 12px ui-monospace, SFMono-Regular, Consolas, monospace;
       background: rgba(127,127,127,.12); padding: 2px 5px; border-radius: 5px; }
footer { color: var(--muted); font-size: 13px; margin-top: 24px; }
ul.compact { margin: 6px 0; padding-left: 20px; }
"""


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Разбор архивов аудита Windows и сборка отчёта")
    p.add_argument("--raw", required=True,
                   help="каталог с ZIP-архивами (или один ZIP)")
    p.add_argument("--out", required=True, help="каталог для отчёта")
    p.add_argument("--history-days", type=int, default=1,
                   help="глубина истории в днях от времени сбора; 0 = вся история (по умолчанию 1)")
    p.add_argument("--max-history", type=int, default=500,
                   help="сколько записей истории показывать в HTML на профиль (CSV всегда полные)")
    p.add_argument("--max-bookmarks", type=int, default=1000,
                   help="сколько закладок показывать в HTML на профиль (CSV всегда полные)")
    p.add_argument("--top", type=int, default=20, help="размер топ-списков процессов")
    p.add_argument("--title", default="Аудит Windows-хостов", help="заголовок отчёта")
    return p.parse_args()


def read_json(path: Path, default=None):
    if not path.is_file():
        return default
    try:
        with path.open(encoding="utf-8-sig") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8-sig", errors="replace")
    except OSError:
        return ""


def read_csv(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    try:
        with path.open(encoding="utf-8-sig", newline="") as fh:
            return list(csv.DictReader(fh))
    except OSError:
        return []


def as_float(value, default=None):
    try:
        return float(str(value).replace(",", "."))
    except (TypeError, ValueError):
        return default


def as_int(value, default=0):
    try:
        return int(float(str(value)))
    except (TypeError, ValueError):
        return default


def parse_iso(value):
    if not value:
        return None
    try:
        text = str(value).replace("Z", "+00:00")
        dt = datetime.fromisoformat(text)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except ValueError:
        return None


def safe_name(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9._-]+", "_", value or "host")
    return value.strip("._") or "host"


def human_gb(value):
    return f"{value:.1f} ГБ" if isinstance(value, (int, float)) else "—"


def pct(value):
    return f"{value}%" if value is not None else "—"


def esc(value) -> str:
    return html.escape("" if value is None else str(value), quote=True)


def link(url: str) -> str:
    url = "" if url is None else str(url)
    if url.startswith(("http://", "https://")):
        return (f'<a href="{esc(url)}" target="_blank" '
                f'rel="noopener noreferrer">{esc(url)}</a>')
    return esc(url)


def chrome_time(value):
    try:
        return CHROME_EPOCH + timedelta(microseconds=int(value))
    except (TypeError, ValueError, OverflowError):
        return None


def unix_us_time(value):
    try:
        return UNIX_EPOCH + timedelta(microseconds=int(value))
    except (TypeError, ValueError, OverflowError):
        return None


def open_sqlite(path: Path):
    """Открывает копию SQLite. WAL/SHM уже лежат рядом."""
    return sqlite3.connect(str(path), timeout=5)


def chromium_history(path: Path, since_utc):
    rows = []
    if not path.is_file():
        return rows, None

    threshold = None
    if since_utc is not None:
        threshold = int((since_utc - CHROME_EPOCH).total_seconds() * 1_000_000)

    try:
        conn = open_sqlite(path)
        try_sql = """
            SELECT u.url, u.title, v.visit_time
            FROM visits v JOIN urls u ON u.id = v.url
            WHERE v.visit_time > 0
        """
        params = []
        if threshold is not None:
            try_sql += " AND v.visit_time >= ?"
            params.append(threshold)
        try_sql += " ORDER BY v.visit_time DESC"
        for url, title, visit_time in conn.execute(try_sql, params):
            dt = chrome_time(visit_time)
            if dt is not None:
                rows.append({"utc": dt, "url": url or "", "title": title or ""})
        conn.close()
        return rows, None
    except sqlite3.Error as exc:
        return rows, f"Chromium History: {exc}"


def chromium_bookmarks(path: Path):
    rows = []
    data = read_json(path, default={}) or {}
    roots = data.get("roots") or {}

    def walk(node, folders):
        if not isinstance(node, dict):
            return
        node_type = node.get("type")
        if node_type == "url":
            rows.append({
                "folder": " / ".join(folders),
                "name": node.get("name") or "",
                "url": node.get("url") or "",
            })
        elif node_type == "folder":
            name = node.get("name") or ""
            next_folders = folders + ([name] if name else [])
            for child in node.get("children") or []:
                walk(child, next_folders)

    for root_name, root_node in roots.items():
        if isinstance(root_node, dict):
            # Имя корневой папки добавит сам walk(): иначе оно задвоится.
            walk(root_node, [])
    return rows


def firefox_history(conn, since_utc):
    rows = []
    threshold = None
    if since_utc is not None:
        threshold = int((since_utc - UNIX_EPOCH).total_seconds() * 1_000_000)

    sql = """
        SELECT p.url, p.title, v.visit_date
        FROM moz_historyvisits v JOIN moz_places p ON p.id = v.place_id
        WHERE v.visit_date > 0
    """
    params = []
    if threshold is not None:
        sql += " AND v.visit_date >= ?"
        params.append(threshold)
    sql += " ORDER BY v.visit_date DESC"

    for url, title, visit_date in conn.execute(sql, params):
        dt = unix_us_time(visit_date)
        if dt is not None:
            rows.append({"utc": dt, "url": url or "", "title": title or ""})
    return rows


def firefox_bookmarks(conn):
    rows = []
    # Папки Firefox лежат в той же таблице: строим путь рекурсивно.
    sql = """
        WITH RECURSIVE folders(id, parent, title, path) AS (
            SELECT id, parent, title, COALESCE(title, '')
            FROM moz_bookmarks WHERE parent = 0
            UNION ALL
            SELECT b.id, b.parent, b.title,
                   CASE WHEN folders.path = '' THEN COALESCE(b.title, '')
                        ELSE folders.path || ' / ' || COALESCE(b.title, '') END
            FROM moz_bookmarks b JOIN folders ON b.parent = folders.id
        )
        SELECT COALESCE(f.path, ''), b.title, p.url
        FROM moz_bookmarks b
        JOIN moz_places p ON p.id = b.fk
        LEFT JOIN folders f ON f.id = b.parent
        WHERE b.type = 1
        ORDER BY f.path, b.position
    """
    try:
        for folder, name, url in conn.execute(sql):
            rows.append({"folder": folder or "", "name": name or "", "url": url or ""})
    except sqlite3.Error:
        # Старые/нестандартные сборки: отдаём хотя бы имя и URL.
        for name, url in conn.execute(
            "SELECT b.title, p.url FROM moz_bookmarks b "
            "JOIN moz_places p ON p.id = b.fk WHERE b.type = 1"
        ):
            rows.append({"folder": "", "name": name or "", "url": url or ""})
    return rows


def firefox_data(path: Path, since_utc):
    history, bookmarks = [], []
    if not path.is_file():
        return history, bookmarks, None
    try:
        conn = open_sqlite(path)
        try:
            history = firefox_history(conn, since_utc)
            bookmarks = firefox_bookmarks(conn)
        finally:
            conn.close()
        return history, bookmarks, None
    except sqlite3.Error as exc:
        return history, bookmarks, f"Firefox places.sqlite: {exc}"


def find_host_root(base: Path) -> Path:
    if (base / "system.json").is_file():
        return base
    matches = list(base.glob("*/system.json"))
    if matches:
        return matches[0].parent
    return base


def analyze_host(host_dir: Path, history_days: int) -> dict:
    system = read_json(host_dir / "system.json", default={}) or {}
    processes = read_csv(host_dir / "processes.csv")
    browsers = read_json(host_dir / "browsers.json", default={}) or {}
    warnings = []
    if (host_dir / "warnings.txt").is_file():
        warnings = [ln.strip() for ln in read_text(host_dir / "warnings.txt").splitlines()
                    if ln.strip()]

    collected = parse_iso(system.get("collected_at_utc"))
    offset = as_int(system.get("utc_offset_minutes"), 0)
    local_tz = timezone(timedelta(minutes=offset))
    since = None
    if history_days > 0:
        since = (collected or datetime.now(timezone.utc)) - timedelta(days=history_days)

    for proc in processes:
        proc["working_set_mb"] = as_float(proc.get("working_set_mb"), 0.0) or 0.0
        proc["private_mb"] = as_float(proc.get("private_mb"), 0.0) or 0.0
        proc["cpu_seconds"] = as_float(proc.get("cpu_seconds"), 0.0) or 0.0
        proc["cpu_percent"] = as_float(proc.get("cpu_percent"))

    profiles = []
    users_dir = host_dir / "users"
    if users_dir.is_dir():
        for user_dir in sorted(p for p in users_dir.iterdir() if p.is_dir()):
            for browser_dir in sorted(p for p in user_dir.iterdir() if p.is_dir()):
                for profile_dir in sorted(p for p in browser_dir.iterdir() if p.is_dir()):
                    meta = read_json(profile_dir / "meta.json", default={}) or {}
                    browser = meta.get("browser") or browser_dir.name
                    profile = meta.get("profile") or profile_dir.name

                    want_history = meta.get("include_history", True) is not False
                    want_bookmarks = meta.get("include_bookmarks", True) is not False

                    if (profile_dir / "places.sqlite").is_file():
                        hist, bms, err = firefox_data(profile_dir / "places.sqlite", since)
                    else:
                        hist, err = chromium_history(profile_dir / "History", since)
                        bms = chromium_bookmarks(profile_dir / "Bookmarks")
                        if not hist:
                            hist = []

                    # В places.sqlite история и закладки лежат вместе:
                    # уважаем флаги сбора для Firefox.
                    if not want_history:
                        hist = []
                    if not want_bookmarks:
                        bms = []

                    for item in hist:
                        item["local"] = item["utc"].astimezone(local_tz)
                    for item in bms:
                        item["local"] = None

                    if err:
                        warnings.append(f"{user_dir.name} / {browser} / {profile}: {err}")

                    if not hist and not bms:
                        continue
                    profiles.append({
                        "user": user_dir.name,
                        "browser": browser,
                        "profile": profile,
                        "history": hist,
                        "bookmarks": bms,
                    })

    profiles.sort(key=lambda p: (p["user"].lower(), p["browser"].lower(), p["profile"].lower()))
    processes.sort(key=lambda p: p["working_set_mb"], reverse=True)

    hostname = system.get("hostname") or host_dir.name
    return {
        "host": hostname,
        "system": system,
        "processes": processes,
        "browsers": browsers,
        "profiles": profiles,
        "warnings": warnings,
        "history_count": sum(len(p["history"]) for p in profiles),
        "bookmarks_count": sum(len(p["bookmarks"]) for p in profiles),
    }


def top_by(processes: list[dict], key: str, limit: int) -> list[dict]:
    usable = [p for p in processes if as_float(p.get(key)) not in (None, 0.0)]
    return sorted(usable, key=lambda p: as_float(p.get(key), 0), reverse=True)[:limit]


def host_link(host: str) -> str:
    return f"hosts/{safe_name(host)}.html"


def render_index(hosts: list[dict], title: str, raw_dir: Path, history_days: int) -> str:
    total_proc = sum(len(h["processes"]) for h in hosts)
    total_profiles = sum(len(h["profiles"]) for h in hosts)
    total_history = sum(h["history_count"] for h in hosts)
    total_bm = sum(h["bookmarks_count"] for h in hosts)
    generated = datetime.now().strftime("%d.%m.%Y %H:%M")

    rows = []
    for h in sorted(hosts, key=lambda x: x["host"].lower()):
        s = h["system"]
        cpu = s.get("cpu") or {}
        mem = s.get("memory") or {}
        mem_total = mem.get("total_gb")
        mem_free = mem.get("free_gb")
        if isinstance(mem_total, (int, float)) and isinstance(mem_free, (int, float)):
            mem_text = f"{mem_total - mem_free:.1f} / {mem_total:.1f} ГБ"
        else:
            mem_text = "—"

        running = h["browsers"].get("running") or []
        browser_names = sorted({b.get("name") or b.get("path") or "?" for b in running})
        browser_labels = sorted({
            (b.get("name") or "?") +
            (f" — {str(b.get('user')).split(chr(92))[-1]}" if b.get("user") else "")
            for b in running
        })
        top = h["processes"][0]["name"] if h["processes"] else "—"
        rows.append(
            "<tr "
            f'data-host="{esc(h["host"])}" '
            f'data-os="{esc(s.get("os"))}" '
            f'data-browsers="{esc(" ".join(browser_names))}">'
            f'<td><a href="{host_link(h["host"])}"><b>{esc(h["host"])}</b></a></td>'
            f'<td>{esc(s.get("os") or "—")}</td>'
            f'<td>{pct(cpu.get("load_percent"))}</td>'
            f'<td>{esc(mem_text)}</td>'
            f'<td class="mono">{esc(top)}</td>'
            f'<td>{esc(", ".join(browser_labels) or "—")}</td>'
            f'<td>{h["history_count"]}</td>'
            f'<td>{h["bookmarks_count"]}</td>'
            "</tr>"
        )

    return f"""<!DOCTYPE html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title><style>{CSS}</style></head><body><div class="wrap">
<h1>{esc(title)}</h1>
<div class="sub">Собрано {esc(generated)} из <code>{esc(raw_dir)}</code>.
Глубина истории: {esc(history_days if history_days > 0 else "вся") }.
Отчёт содержит персональные данные — хранить в защищённом каталоге.</div>

<div class="cards">
  <div class="stat"><b>{len(hosts)}</b><span>хостов</span></div>
  <div class="stat"><b>{total_proc}</b><span>процессов</span></div>
  <div class="stat"><b>{total_profiles}</b><span>профилей браузеров</span></div>
  <div class="stat"><b>{total_history}</b><span>записей истории</span></div>
  <div class="stat"><b>{total_bm}</b><span>закладок</span></div>
</div>

<div class="toolbar">
  <input type="search" id="q" placeholder="Фильтр: хост, ОС, браузер…" autocomplete="off">
</div>

<table><thead><tr>
<th>Хост</th><th>ОС</th><th>CPU</th><th>RAM (занято/всего)</th>
<th>Топ по памяти</th><th>Браузеры запущены</th><th>История</th><th>Закладки</th>
</tr></thead><tbody id="rows">
{''.join(rows) if rows else '<tr><td colspan="8" class="muted">Нет данных</td></tr>'}
</tbody></table>

<footer>Сборщик: <code>files/windows/Invoke-WindowsAudit.ps1</code>.
Отчёт собран <code>scripts/parse_windows_audit.py</code>.
Пароли, cookies и токены не собираются.</footer>
</div>
<script>
const q = document.getElementById('q');
const rows = Array.from(document.querySelectorAll('#rows tr[data-host]'));
q.addEventListener('input', () => {{
  const term = q.value.trim().toLowerCase();
  rows.forEach(tr => {{
    const hay = (tr.dataset.host + ' ' + tr.dataset.os + ' ' + tr.dataset.browsers).toLowerCase();
    tr.classList.toggle('hide', term && !hay.includes(term));
  }});
}});
</script></body></html>"""


def render_host(host: dict, title: str, max_history: int = 500,
                max_bookmarks: int = 1000) -> str:
    s = host["system"]
    cpu = s.get("cpu") or {}
    mem = s.get("memory") or {}
    disks = s.get("disks") or []
    installed = host["browsers"].get("installed") or []
    running = host["browsers"].get("running") or []

    disk_rows = "".join(
        f'<tr><td class="mono">{esc(d.get("drive"))}</td>'
        f'<td>{esc(d.get("size_gb"))} ГБ</td>'
        f'<td>{esc(d.get("free_gb"))} ГБ</td></tr>'
        for d in disks
    ) or '<tr><td colspan="3" class="muted">Нет данных</td></tr>'

    def proc_table(items, key, value_title):
        body = "".join(
            f'<tr><td class="mono">{esc(p.get("name"))}</td>'
            f'<td>{esc(p.get("pid"))}</td>'
            f'<td>{esc(p.get("user") or "")}</td>'
            f'<td>{esc(p.get(key))}</td>'
            f'<td class="mono">{esc((p.get("path") or "")[:120])}</td></tr>'
            for p in items
        ) or f'<tr><td colspan="5" class="muted">Нет данных</td></tr>'
        return (f"<table><thead><tr><th>Процесс</th><th>PID</th><th>Пользователь</th>"
                f"<th>{value_title}</th><th>Путь</th></tr></thead><tbody>{body}</tbody></table>")

    top_mem = top_by(host["processes"], "working_set_mb", 20)
    top_cpu = top_by(host["processes"], "cpu_percent", 20)

    running_rows = "".join(
        f'<tr><td class="mono">{esc(p.get("name"))}</td><td>{esc(p.get("pid"))}</td>'
        f'<td>{esc(p.get("user") or "")}</td><td>{esc(p.get("working_set_mb"))}</td>'
        f'<td>{esc(p.get("cpu_percent") if p.get("cpu_percent") is not None else "—")}</td>'
        f'<td class="mono">{esc((p.get("command_line") or p.get("path") or "")[:160])}</td></tr>'
        for p in running
    ) or '<tr><td colspan="6" class="muted">Браузеры не запущены</td></tr>'

    installed_rows = "".join(
        f'<tr><td>{esc(b.get("name"))}</td><td>{esc(b.get("version") or "—")}</td>'
        f'<td class="mono">{esc(b.get("exe") or "")}</td></tr>'
        for b in installed
    ) or '<tr><td colspan="3" class="muted">Не найдены</td></tr>'

    profile_blocks = []
    for p in host["profiles"]:
        hist = p["history"]
        bms = p["bookmarks"]
        hist_rows = "".join(
            f'<tr><td class="mono">{esc(h["local"].strftime("%Y-%m-%d %H:%M:%S"))}</td>'
            f'<td>{esc(h.get("title") or "")}</td><td>{link(h.get("url"))}</td></tr>'
            for h in hist[:max_history]
        ) or '<tr><td colspan="3" class="muted">Истории за период нет</td></tr>'
        more_hist = (f'<div class="muted">Показаны первые {max_history} из {len(hist)}; '
                     f'полностью — в <code>history.csv</code>.</div>'
                     if len(hist) > max_history else "")
        bm_rows = "".join(
            f'<tr><td>{esc(b.get("folder") or "")}</td><td>{esc(b.get("name") or "")}</td>'
            f'<td>{link(b.get("url"))}</td></tr>'
            for b in bms[:max_bookmarks]
        ) or '<tr><td colspan="3" class="muted">Закладок нет</td></tr>'
        more_bm = (f'<div class="muted">Показаны первые {max_bookmarks} из {len(bms)}; '
                   f'полностью — в <code>bookmarks.csv</code>.</div>'
                   if len(bms) > max_bookmarks else "")
        profile_blocks.append(f"""
<h3>{esc(p["user"])} / {esc(p["browser"])} / {esc(p["profile"])}
  <span class="muted">({len(hist)} история, {len(bms)} закладок)</span></h3>
<h4>История</h4>
<table><thead><tr><th>Время</th><th>Заголовок</th><th>URL</th></tr></thead>
<tbody>{hist_rows}</tbody></table>{more_hist}
<h4>Закладки</h4>
<table><thead><tr><th>Папка</th><th>Название</th><th>URL</th></tr></thead>
<tbody>{bm_rows}</tbody></table>{more_bm}
""")

    warnings = "".join(f"<li>{esc(w)}</li>" for w in host["warnings"])
    warning_block = (f'<div class="alert"><b>Предупреждения</b><ul class="compact">'
                     f"{warnings}</ul></div>") if warnings else ""

    return f"""<!DOCTYPE html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(host["host"])} — {esc(title)}</title><style>{CSS}</style></head>
<body><div class="wrap">
<div class="sub"><a href="../index.html">← Ко всем хостам</a></div>
<h1>{esc(host["host"])}</h1>
<div class="sub">{esc(s.get("os") or "—")} · {esc(s.get("fqdn") or "")} ·
сбор {esc(s.get("collected_at_utc") or "—")}</div>

{warning_block}

<h2>Система</h2>
<table><tbody>
<tr><th>Домен / рабочий стол</th><td>{esc(s.get("domain") or "—")}</td></tr>
<tr><th>Пользователь в системе</th><td>{esc(s.get("logged_on_user") or "—")}</td></tr>
<tr><th>Последняя загрузка</th><td>{esc(s.get("last_boot") or "—")}</td></tr>
<tr><th>Uptime</th><td>{esc(s.get("uptime_hours"))} ч</td></tr>
<tr><th>CPU</th><td>{esc(cpu.get("name") or "—")} · {esc(cpu.get("cores"))} ядер / {esc(cpu.get("logical"))} потоков · загрузка {pct(cpu.get("load_percent"))}</td></tr>
<tr><th>RAM</th><td>{esc(mem.get("total_gb"))} ГБ всего, {esc(mem.get("free_gb"))} ГБ свободно</td></tr>
<tr><th>IP</th><td class="mono">{esc(", ".join(s.get("ipv4") or []))}</td></tr>
<tr><th>Часовой пояс</th><td>{esc(s.get("timezone") or "—")} (UTC{esc(s.get("utc_offset_minutes"))} мин)</td></tr>
</tbody></table>

<h3>Диски</h3>
<table><thead><tr><th>Диск</th><th>Всего</th><th>Свободно</th></tr></thead>
<tbody>{disk_rows}</tbody></table>

<h2>Нагрузка и процессы</h2>
<div class="sub">Всего процессов: {len(host["processes"])}. Топ-20 по памяти и по CPU.</div>
<h3>По памяти</h3>
{proc_table(top_mem, "working_set_mb", "Память, МБ")}
<h3>По CPU</h3>
{proc_table(top_cpu, "cpu_percent", "CPU, %")}

<h2>Браузеры</h2>
<h3>Запущены</h3>
<table><thead><tr><th>Процесс</th><th>PID</th><th>Пользователь</th><th>Память, МБ</th><th>CPU, %</th><th>Командная строка</th></tr></thead>
<tbody>{running_rows}</tbody></table>
<h3>Установлены</h3>
<table><thead><tr><th>Браузер</th><th>Версия</th><th>Путь</th></tr></thead>
<tbody>{installed_rows}</tbody></table>

<h2>История и закладки по профилям</h2>
{''.join(profile_blocks) if profile_blocks else '<div class="muted">Профили браузеров не найдены.</div>'}

<footer>История и закладки — персональные данные. Не публиковать.
Отчёт собран <code>parse_windows_audit.py</code>.</footer>
</div></body></html>"""


def write_csv(path: Path, header: list[str], rows) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(header)
        writer.writerows(rows)


def main() -> int:
    args = parse_args()
    raw_dir = Path(args.raw).expanduser()
    out_dir = Path(args.out).expanduser()

    if not raw_dir.exists():
        print(f"Нет такого пути: {raw_dir}", file=sys.stderr)
        return 2

    zips = [raw_dir] if raw_dir.is_file() and raw_dir.suffix.lower() == ".zip" else sorted(raw_dir.glob("*.zip"))
    if not zips:
        print(f"В {raw_dir} нет ZIP-архивов", file=sys.stderr)
        return 2

    os.umask(0o077)
    out_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(out_dir, 0o700)
    hosts_dir = out_dir / "hosts"
    hosts_dir.mkdir(exist_ok=True)
    os.chmod(hosts_dir, 0o700)

    hosts = []
    for zip_path in zips:
        tmp = Path(tempfile.mkdtemp(prefix="win-audit-"))
        try:
            tmp_root = tmp.resolve()
            with zipfile.ZipFile(zip_path) as zf:
                for member in zf.infolist():
                    target = (tmp / member.filename).resolve()
                    if target != tmp_root and tmp_root not in target.parents:
                        print(f"Пропуск подозрительного пути в {zip_path}: {member.filename}",
                              file=sys.stderr)
                        continue
                    zf.extract(member, tmp)
            host_dir = find_host_root(tmp)
            if not (host_dir / "system.json").is_file():
                print(f"В {zip_path.name} нет system.json — пропуск", file=sys.stderr)
                continue
            hosts.append(analyze_host(host_dir, args.history_days))
        except (zipfile.BadZipFile, OSError) as exc:
            print(f"Ошибка чтения {zip_path}: {exc}", file=sys.stderr)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    if not hosts:
        print("Не удалось разобрать ни одного хоста", file=sys.stderr)
        return 1

    # Один хост может попасть дважды (повторный прогон) — берём самый свежий.
    newest = {}
    for h in hosts:
        key = h["host"].lower()
        current = newest.get(key)
        if current is None:
            newest[key] = h
            continue
        old_time = parse_iso(current["system"].get("collected_at_utc")) or datetime.min.replace(tzinfo=timezone.utc)
        new_time = parse_iso(h["system"].get("collected_at_utc")) or datetime.min.replace(tzinfo=timezone.utc)
        if new_time >= old_time:
            newest[key] = h
    hosts = list(newest.values())

    # --- CSV -----------------------------------------------------------------
    summary_rows = []
    history_rows = []
    bookmark_rows = []
    process_rows = []

    for h in hosts:
        s = h["system"]
        cpu = s.get("cpu") or {}
        mem = s.get("memory") or {}
        running = h["browsers"].get("running") or []
        summary_rows.append([
            h["host"], s.get("os") or "", s.get("os_version") or "",
            cpu.get("load_percent") if cpu.get("load_percent") is not None else "",
            mem.get("total_gb") or "", mem.get("free_gb") or "",
            len(h["processes"]), h["history_count"], h["bookmarks_count"],
            ", ".join(sorted({b.get("name") or "" for b in running if b.get("name")})),
            s.get("collected_at_utc") or "",
        ])

        for p in h["profiles"]:
            for item in p["history"]:
                history_rows.append([
                    h["host"], p["user"], p["browser"], p["profile"],
                    item["local"].strftime("%Y-%m-%d %H:%M:%S"),
                    item.get("title") or "", item.get("url") or "",
                ])
            for item in p["bookmarks"]:
                bookmark_rows.append([
                    h["host"], p["user"], p["browser"], p["profile"],
                    item.get("folder") or "", item.get("name") or "", item.get("url") or "",
                ])

        for proc in top_by(h["processes"], "working_set_mb", args.top):
            process_rows.append([
                h["host"], proc.get("name") or "", proc.get("pid") or "",
                proc.get("user") or "", proc.get("working_set_mb") or "",
                proc.get("cpu_percent") if proc.get("cpu_percent") is not None else "",
                proc.get("cpu_seconds") or "", proc.get("path") or "",
            ])

    write_csv(out_dir / "summary.csv",
              ["host", "os", "os_version", "cpu_load_percent", "ram_total_gb",
               "ram_free_gb", "processes", "history", "bookmarks", "browsers_running",
               "collected_at_utc"], summary_rows)
    write_csv(out_dir / "history.csv",
              ["host", "user", "browser", "profile", "time_local", "title", "url"],
              history_rows)
    write_csv(out_dir / "bookmarks.csv",
              ["host", "user", "browser", "profile", "folder", "name", "url"],
              bookmark_rows)
    write_csv(out_dir / "top_processes.csv",
              ["host", "name", "pid", "user", "working_set_mb", "cpu_percent",
               "cpu_seconds", "path"], process_rows)

    # --- HTML и JSON ---------------------------------------------------------
    for h in hosts:
        host_html = render_host(h, args.title, args.max_history, args.max_bookmarks)
        (hosts_dir / f"{safe_name(h['host'])}.html").write_text(host_html, encoding="utf-8")
        os.chmod(hosts_dir / f"{safe_name(h['host'])}.html", 0o600)

        export = dict(h)
        export["profiles"] = [
            {
                **{k: v for k, v in p.items() if k not in ("history", "bookmarks")},
                "history": [
                    {**item, "time_local": item["local"].strftime("%Y-%m-%d %H:%M:%S")}
                    for item in p["history"]
                ],
                "bookmarks": p["bookmarks"],
            }
            for p in h["profiles"]
        ]
        for p in export["profiles"]:
            for item in p["history"]:
                item.pop("local", None)
                item.pop("utc", None)
        (hosts_dir / f"{safe_name(h['host'])}.json").write_text(
            json.dumps(export, ensure_ascii=False, indent=2), encoding="utf-8")
        os.chmod(hosts_dir / f"{safe_name(h['host'])}.json", 0o600)

    index_html = render_index(hosts, args.title, raw_dir, args.history_days)
    (out_dir / "index.html").write_text(index_html, encoding="utf-8")
    os.chmod(out_dir / "index.html", 0o600)

    info = (
        f"Отчёт: {out_dir}\n"
        f"Источник: {raw_dir}\n"
        f"Хостов: {len(hosts)}\n"
        f"История: {sum(h['history_count'] for h in hosts)} записей\n"
        f"Закладки: {sum(h['bookmarks_count'] for h in hosts)}\n"
        f"Глубина истории: {args.history_days if args.history_days > 0 else 'вся'}\n"
        f"Собрано: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
    )
    (out_dir / "REPORT_INFO.txt").write_text(info, encoding="utf-8")
    os.chmod(out_dir / "REPORT_INFO.txt", 0o600)

    print(info.rstrip())
    print(f"Открыть: {out_dir / 'index.html'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
