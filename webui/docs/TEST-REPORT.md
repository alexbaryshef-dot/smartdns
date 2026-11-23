# Отчёт о тестировании

Дата: 2026-11-23. Версия: `0.1.0-pre1`.

## Статус

**PRE-RELEASE. Приёмочные испытания на реальном роутере не проводились.**
Результаты ниже получены в эмуляции на рабочей машине; они подтверждают
логику API/HTTP/установки, но не заменяют проверку на Keenetic/aarch64 с
настоящим ядром hrdns.

## Окружение

| Параметр | Значение |
|---|---|
| ОС | Windows 11 (эмуляция POSIX-среды) |
| Shell | BusyBox v1.39.0-FRP (ash, httpd, coreutils applets) |
| Python | 3.14 |
| Node.js | 24.21 |
| Ядро в тестах | скрипт-заглушка, печатающий `hrdns starting...` |
| Реальный smartdns/hrdns | не запускался |
| aarch64/mips | не проверялись |

Реальный aarch64/Entware в этой среде недоступен; запуск полноценного ядра
smartdns и `opkg` не выполнялся.

## Результаты

### 1. Unit-тесты JS

```
node tests/core.test.js
✔ 6/6 tests passed
```

Покрыто: `parseSchema`, `parseGlobals`/`renderGlobals` (сохранение неизвестных
директив), `parseLines`/`renderItems`, `parseGroups`/`renderGroups`, валидаторы
IP/CIDR/домен/MAC/int/yesno/speed, форматирование, экранирование.

### 2. Расширенные эмуляционные прогоны (в процессе разработки)

| Набор | Результат |
|---|---|
| CGI API (direct invocation) | 27/27 |
| HTTP через BusyBox httpd + CGI | 14/14 |
| install/upgrade/uninstall | 19/19 |
| валидатор конфига | шаблон: 0 ошибок; найден и исправлен ложный дубль `bind`/`bind-tcp` |

Эти прогоны выявили и привели к исправлению:

- парсинг query-параметров без завершающего перевода строки (BusyBox `read`);
- отсутствие CGI-заголовков у части JSON-ответов;
- `header_get` без префикса `HTTP_` (CSRF не работал);
- отсутствие префикса в пути к ядру после `sed` (Windows-пути);
- неверный код возврата `forksmartdnsctl check` после успешной проверки;
- мутирующие действия, доступные через GET (теперь POST-only);
- `json_str_file` терял завершающий перевод строки;
- путь к `api.cgi` для BusyBox httpd (`/cgi-bin/`).

### 3. Итоговый воспроизводимый self-test

```
BUSYBOX=... python3 tests/selftest.py
PASS=42 FAIL=0
```

Состав:

- **API, 22 проверки**: setup/wrong-token/session/cookie+csrf/status/config
  blocks/validator/apply/persisted/csrf/file write/read/list/backup/download/
  restore/cache→503/diag/service stop/logout/401.
- **HTTP, 11 проверок**: httpd listen, session, setup, status, apply, CSRF,
  POST-only, static index, path traversal, logout, 401.
- **Install, 9 проверок**: install, config, token, API, init, reinstall refused,
  upgrade + config preserved, uninstall, removal.

Логи прогона сохранены в истории разработки; команда воспроизводится на любой
машине с BusyBox+Python.

## Что не проверено (критично для статуса stable)

1. Реальный запуск/остановка/перезапуск `hrdns`/`smartdns` и реальные DNS-ответы.
2. DoT/DoH/HTTP3/DoQ, TLS-сертификаты, цепочки CA.
3. Stats-мост настоящего ядра (проверена только деградация при его отсутствии).
4. lighttpd-режим (запускался только BusyBox httpd).
5. KeeneticOS, Entware `opkg`, aarch64/mips, ограничения flash/USB.
6. Браузерное тестирование SPA (только синтаксис и HTTP-статика).
7. Автозапуск после реальной перезагрузки, сосуществование со штатным hrdns.
8. Поведение при нехватке памяти/места, ротации логов.

## Чек-лист перед объявлением стабильного релиза

Выполнить `docs/TESTING.md` → «Ручной чек-лист на реальном роутере» минимум на
двух архитектурах (aarch64 и mips/mipsel), с lighttpd и BusyBox httpd,
при включённом и выключенном stats-мосте. Только после этого менять статус и
публиковать тег.

## Вывод

Функциональность реализована и прошла эмуляционные проверки. Установщик и
панель **не объявляются стабильными**: непроверенные на устройстве компоненты
(реальное ядро, DNS/TLS, lighttpd, aarch64) перечислены выше.
