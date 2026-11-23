# Архитектура

## Схема

```
 Браузер (LAN)
    │  HTTP :3636
    ▼
 lighttpd (отдельный экземпляр)            BusyBox httpd (fallback)
    │  CGI /cgi-bin/api.cgi
    ▼
 CGI-бэкенд на BusyBox ash
    ├── auth/session/CSRF
    ├── config: чтение, блоки, валидация, backup, apply
    ├── files: lists/
    ├── service: init.d/forksmartdns
    └── stats proxy ──────────────┐
                                  │ HTTP 127.0.0.1:36390
                                  ▼
                         stats-мост ядра hrdns
                         (ui-enable / ui-listen)
                                  ▲
                                  │ unix-fd bridge
                                  │
 Ядро hrdns/smartdns  ────────────┘
   DNS :5353/udp+tcp
   собственный конфиг, PID, логи
```

## Компоненты

### 1. Ядро (изолированный резолвер)

Установщик сам обеспечивает ядро: если более новый `hrdns` уже установлен —
копирует его; иначе скачивает готовый форк-бинарник `hrdns` 1.0.0
(aarch64/mipsel/mips) из истории репозитория и проверяет SHA-256 по
`SHA256SUMS`. Только если форк-ядро недоступно, ставится generic `smartdns`.
Выбранный бинарник кладётся в `/opt/etc/forksmartdns/bin/core`; процесс
запускается со своим конфигом, PID и каталогом данных. Штатный бинарник и его
служба не используются и не меняются.

Конфиг включает `ui-enable yes` и `ui-listen 127.0.0.1:<внутренний порт>`.
Благодаря этому ядро поднимает свой встроенный stats-мост — тот же источник
данных, что использует штатная панель hrdns. Мы **переиспользуем** его для
статистики, Query Log и кэша, а не парсим audit-лог и не дублируем движок.

Если выбран generic `smartdns` без `ui-*`, мост недоступен: страницы статистики,
журнала и кэша помечаются как частично недоступные.

### 2. Веб-сервер

По умолчанию устанавливается отдельный экземпляр `lighttpd`:

- собственный конфиг `/opt/etc/forksmartdns/lighttpd.conf`;
- собственный PID `/opt/var/run/forksmartdns/web.pid`;
- свой лог `/opt/var/log/forksmartdns/web.log`;
- docroot `/opt/share/forksmartdns/www`;
- CGI `/cgi-bin/api.cgi` → `/bin/sh`.

Если lighttpd недоступен, используется BusyBox `httpd` (applet `httpd`).
Оба сервера запускают один и тот же CGI.

### 3. CGI-бэкенд

`/opt/share/forksmartdns/www/cgi-bin/api.cgi` — точка входа. Он подключает
библиотеки из `/opt/share/forksmartdns/lib`:

| Файл | Назначение |
|---|---|
| `common.sh` | пути, JSON, CGI-хелперы, порты/процессы, случайные токены |
| `auth.sh` | пароль, сессии, CSRF, throttling, setup |
| `config.sh` | блоки конфига, статическая/динамическая валидация, безопасное применение |
| `validate.awk` | синтаксическая проверка директив и значений |
| `service.sh` | статус/запуск/остановка через init-скрипт |
| `coreapi.sh` | HTTP-клиент к loopback stats-мосту (nc) |
| `backup.sh` | tar.gz-копии, восстановление, ротация |
| `api_actions.sh` | реализации действий API |

CGI не использует сторонние библиотеки и не требует компиляции. Все команды
выполняются от root (как и обычные init-скрипты Entware).

### 4. Init и CLI

`/opt/etc/init.d/forksmartdns` запускает/останавливает ядро и веб-сервер,
управляет автозапуском. PID-файлы:

- ядро: `/opt/var/run/forksmartdns/forksmartdns.pid`;
- веб: `/opt/var/run/forksmartdns/web.pid`.

`forksmartdnsctl` — обёртка для людей: status/start/stop/restart/check/backup/
restore/passwd/diagnose. Симлинк: `/opt/bin/forksmartdnsctl`.

## Модель конфигурации

Один файл `/opt/etc/forksmartdns/forksmartdns.conf` содержит управляемые блоки:

```
# >>> fsd:globals
key value
# <<< fsd:globals

# >>> fsd:listeners     bind / bind-tcp / bind-tls / bind-https / bind-http
# >>> fsd:upstreams     server, server-tcp, server-tls, server-https, server-h3, server-quic
# >>> fsd:groups        group-begin / group-match / group-end
# >>> fsd:domains       address, nameserver, domain-rules, cname, srv/txt/https
# >>> fsd:lists         domain-set, ip-set, block-file, hosts-file, ...
# >>> fsd:clients       client-rules
# >>> fsd:ipset         ipset / nftset правила
# >>> fsd:extra         произвольные директивы
```

- Структурированные страницы перерисовывают только свой блок.
- `fsd:globals` редактируется схемой `schema.tsv` (тип, диапазон, enum, подсказка).
- Сырой редактор позволяет изменить весь файл; это полный контроль над ядром.
- Комментарии и директивы вне `fsd:*` сохраняются при редактировании блоков.

## Применение конфигурации

```
новый текст
   │
   ├─ 1. статическая проверка (validate.awk):
   │      известные директивы, типы, форматы, группы, bind
   ├─ 2. пробный запуск ядра на копии:
   │      все bind заменены на 127.0.0.1:0, ui выключен,
   │      временные log/cache/data; ядро должно стартовать
   ├─ 3. автоматический backup (tar.gz)
   ├─ 4. атомарная запись (tmp + mv)
   ├─ 5. перезапуск службы (если она запущена)
   ├─ 6. ожидание готовности PID + stats-моста
   └─ 7. при ошибке — восстановление backup и перезапуск
```

Пробный запуск ядра — авторитетная проверка синтаксиса: именно ядро решает,
принимать ли конфиг. Статический валидатор ловит опечатки в директивах (ядро к
неизвестным директивам относится как к предупреждению) и неверные значения.

## Аутентификация

- пароль хранится как salted SHA-256 с числом итераций (по умолчанию 150);
- сессия — 32 hex-символа в HttpOnly/SameSite=Strict cookie, TTL 8 ч,
  привязка к IP;
- CSRF-токен обязателен для всех изменяющих запросов;
- 5 неудачных попыток входа → блокировка IP на 5 минут;
- первая настройка — по одноразовому токену из файла `setup-token`;
- смена пароля инвалидирует все сессии.

Подробнее — `SECURITY.md`.

## Изоляция от штатного hrdns

| Ресурс | Штатный hrdns | forksmartdns |
|---|---|---|
| Каталог конфига | `/opt/etc/HydraRoute/dns` | `/opt/etc/forksmartdns` |
| Бинарник | `/opt/bin/hrdns` | `/opt/etc/forksmartdns/bin/core` |
| PID | `/opt/var/run/hrdns.pid` | `/opt/var/run/forksmartdns/forksmartdns.pid` |
| Логи | `/opt/var/log/hrdns.log` | `/opt/var/log/forksmartdns/` |
| Web UI | `3636` (socat → hrdns-ui) | `3636` (свой lighttpd; при конфликте — другой порт) |
| DNS | `53` | `5353` |
| Init | `/opt/etc/init.d/hrdns*` | `/opt/etc/init.d/forksmartdns` |

Единственные новые файлы вне наших каталогов — init-скрипт и симлинк CLI;
штатные файлы не перезаписываются.

## Отказоустойчивость

- конфиг применяется только после двух проверок;
- перед изменением всегда создаётся backup;
- при неудачном перезапуске конфиг откатывается и служба возвращается к работе;
- логи и диагностика показывают причину отказа;
- установка без `--no-start` проверяет HTTP и (если включён мост) его доступность.
