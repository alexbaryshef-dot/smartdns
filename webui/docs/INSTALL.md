# Установка, обновление и удаление

## Требования

- Keenetic с KeeneticOS и установленным Entware (`/opt`);
- root-доступ (SSH/telnet или Entware-TERM);
- `wget` или `curl` для установки из GitHub;
- доступ в интернет к GitHub: установщик скачивает форк-ядро (~11–13 МБ);
- уже установленный более новый `hrdns` будет использован вместо скачанного;
  generic `smartdns` — только запасной вариант, если нет готового форк-ядра;
- свободные порты: WebUI (по умолчанию `3636/tcp`), DNS (`5353/udp+tcp`);
- по желанию: `lighttpd` + `lighttpd-mod-cgi` (если нет BusyBox `httpd`);
- для IPSet — пакет `ipset`.

Штатный hrdns при этом может работать: наш экземпляр использует другие порты,
каталоги и PID-файлы. Установщик не останавливает и не переконфигурирует его.

## Установка одной командой

```sh
wget -qO- https://raw.githubusercontent.com/alexbaryshef-dot/smartdns/main/webui/install.sh | sh
```

С параметрами:

```sh
wget -qO- https://raw.githubusercontent.com/alexbaryshef-dot/smartdns/main/webui/install.sh \
  | sh -s -- --ui-port 3637 --dns-port 5353 --password 'S3cret-pass'
```

### Опции установщика

| Опция | По умолчанию | Назначение |
|---|---|---|
| `--prefix DIR` | `/opt` | префикс Entware |
| `--dns-port N` | `5353` | DNS-порт изолированного резолвера |
| `--dns-bind ADDR` | `0.0.0.0` | адрес DNS-услышителя |
| `--ui-port N` | `3636` | порт панели |
| `--ui-bind ADDR` | `0.0.0.0` | адрес панели (для LAN-only укажите IP роутера) |
| `--web-server auto\|lighttpd\|busybox` | `auto` | веб-сервер |
| `--core PATH` | автопоиск | свой бинарник hrdns/smartdns |
| `--core-source X` | `auto` | `auto`, `existing`, `fork`, `opkg` |
| `--fork-core-ref REF` | `fab7d126…` | коммит с готовыми бинарниками форка |
| `--fork-arch ARCH` | — | переопределить архитектуру (тесты/отладка) |
| `--password PASS` | — | сразу задать пароль администратора |
| `--no-deps` | — | не устанавливать пакеты через opkg |
| `--no-start` | — | не запускать службу после установки |
| `--no-autostart` | — | не включать автозапуск |
| `--upgrade` | — | обновить существующую установку |
| `--force` | — | продолжить при занятых портах / существующей установке |
| `--source DIR` | — | локальный каталог исходников (разработка/тесты) |
| `--repo OWNER/REPO`, `--ref REF` | `alexbaryshef-dot/smartdns`, `main` | источник |

Установка из локального каталога (например, при разработке):

```sh
sh /path/to/webui/install.sh --source /path/to/webui --no-start
```

## Проверка портов

```sh
netstat -ltnu 2>/dev/null | grep -E ':(3636|5353)\b'
```

Если `3636` занят штатной панелью hrdns, установка остановится с объяснением.
Варианты:

- `--ui-port 3637` — наша панель на другом порту;
- освободить `3636` (например, отключить штатный `hrdns-web`) — но это уже
  изменение штатной службы, решайте сами.

`5353` выбран потому, что `53` обычно занят штатным резолвером. Если штатного
DNS нет, можно поставить `--dns-port 53` и направить клиентов на роутер.

## Какое ядро устанавливается

Порядок выбора:

| Приоритет | Источник | Когда |
|---|---|---|
| 1 | `--core PATH` | явное указание |
| 2 | уже установленный `hrdns` | найден и запускается |
| 3 | готовый форк `hrdns` 1.0.0 | нет более нового hrdns, архитектура aarch64/mipsel/mips |
| 4 | `opkg install smartdns` | форк-ядро недоступно/не скачалось |

Готовые бинарники форка лежат в истории репозитория (коммит
`fab7d126e4311e0441d4d29cf54a47b35de472c8`) и проверяются по `SHA256SUMS`:

- `bin/aarch64-k3.10/hrdns`
- `bin/mipselsf-k3.4/hrdns`
- `bin/mipssf-k3.4/hrdns`

Это **версия 1.0.0**. Версии 1.2.3/2.0.0 опубликованы только исходниками;
чтобы их использовать, соберите и передайте `--core PATH` (или заранее
установите свежий hrdns — он будет выбран автоматически).

Принудительно скачать форк-ядро: `--core-source fork`. Только из уже
установленного: `--core-source existing`. Только generic smartdns:
`--core-source opkg`.

## Что создаётся

```
/opt/etc/forksmartdns/
  forksmartdns.conf        конфиг ядра
  instance.env             порты, тип ядра, web-сервер
  auth.conf                хеш пароля (0600)
  setup-token              одноразовый токен первой настройки (0600)
  lighttpd.conf            конфиг отдельного экземпляра lighttpd
  bin/core                 выбранное ядро (форк hrdns 1.0.0 или существующее)
  lists/                   файлы списков
/opt/var/lib/forksmartdns/ кэш, ui-данные, tmp, backups/
/opt/var/log/forksmartdns/ логи ядра, audit, web
/opt/var/run/forksmartdns/ PID, сессии, временные файлы
/opt/share/forksmartdns/   lib, cgi, www, bin/forksmartdnsctl, docs, etc
/opt/etc/init.d/forksmartdns
/opt/bin/forksmartdnsctl   симлинк на CLI
```

## Первый вход

1. Откройте `http://<IP-роутера>:3636/`.
2. Введите установочный токен (он напечатан установщиком; файл
   `/opt/etc/forksmartdns/setup-token`).
3. Задайте пароль ≥ 8 символов.

Если пароль задан через `--password`, токен не создаётся.

## Проверка после установки

```sh
forksmartdnsctl status
forksmartdnsctl diagnose
forksmartdnsctl check
tail -n 50 /opt/var/log/forksmartdns/forksmartdns.log
tail -n 50 /opt/var/log/forksmartdns/web.log
```

Проверка DNS (с роутера):

```sh
# если экземпляр слушает стандартный 53
nslookup example.com 127.0.0.1

# если порт 5353 и установлен dig
dig @127.0.0.1 -p 5353 example.com
```

`nslookup` из BusyBox не умеет задавать порт, поэтому для нестандартного порта
используйте `dig` (если он есть в Entware), страницу Query Log или
`forksmartdnsctl diagnose`.

Проверка панели:

```sh
wget -qO- http://127.0.0.1:3636/ | head
```

## Обновление

```sh
wget -qO- https://raw.githubusercontent.com/alexbaryshef-dot/smartdns/main/webui/install.sh \
  | sh -s -- --upgrade
```

Конфигурация, списки, auth и резервные копии сохраняются. Обновляются код,
шаблоны и (если выбран источник `fork`) копия форк-ядра. Уже установленное
ядро `hrdns` не перезаписывается. Если выбран другой внутренний порт stats-моста,
установщик обновит строку `ui-listen`.

Перед изменением конфигурации панель/валидатор создаёт резервную копию.
При неудачном применении выполняется откат.

## Удаление

```sh
wget -qO- https://raw.githubusercontent.com/alexbaryshef-dot/smartdns/main/webui/uninstall.sh | sh
```

Опции:

- `--keep-config` — сохранить конфиг, списки и backups;
- `--keep-logs` — сохранить логи;
- `--force` — удалять, даже если процессы не остановились.

Удаляются только каталоги/файлы проекта. Штатный hrdns, его пакет, конфиги и
службы не затрагиваются. Пакет `lighttpd` автоматически не удаляется (он может
использоваться другими); при необходимости:

```sh
opkg remove lighttpd lighttpd-mod-cgi
```

## Откат установки

- Если конфигурация не прошла проверку при установке, установщик останавливает
  службу и (для новой установки) удаляет созданные файлы.
- При ошибке применения конфигурации из панели восстанавливается предыдущий
  конфиг из автоматического backup.
- При неудачном обновлении конфиг сохраняется, а служба возвращается к прежнему
  состоянию, если это возможно.

## Ограничения

См. `COMPATIBILITY.md`. Установщик не является «стабильным релизом»: реальные
испытания на aarch64/mips не проводились.
