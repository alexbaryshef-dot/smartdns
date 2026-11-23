# forksmartdns WebUI

Полноценная отдельная панель управления для изолированного экземпляра SmartDNS/HRDNS
на Keenetic с Entware. Проект живёт в этом каталоге (`webui/`) и **не изменяет**
штатную установку hrdns из Hydra Route: ни файлы, ни пакет, ни службы.

> **Статус: PRE-RELEASE `0.1.0-pre1`.** Код проверен в эмуляции Entware/BusyBox
> (API, HTTP, установка/обновление/удаление, валидатор, unit-тесты). Приёмочных
> испытаний на реальных роутерах aarch64/mips и с настоящим бинарником ядра
> **не проводилось**. Стабильным релизом это не объявляется. Перед использованием
> на рабочем роутере сделайте резервную копию конфигурации Keenetic.

## Зачем это

Штатная панель hrdns показывает статистику и журнал запросов, но не управляет
конфигурацией ядра. `forksmartdns` запускает **второй, независимый** экземпляр
резолвера со своим бинарником, конфигом, PID, логами и портами, а панель даёт
полный контроль над этим экземпляром:

- upstream DNS: UDP, TCP, DoT, DoH, HTTP/3, DoQ, прокси, группы, fallback;
- слушатели: UDP/TCP/DoT/DoH/DoH-без-TLS, привязка к адресам и группам;
- группы `group-begin`/`group-match`/`group-end`, наследование;
- правила доменов: `address`, `nameserver`, `domain-rules`, `cname`, `srv-record`,
  `https-record`, `txt-record`, `local-domain`, `ddns-domain`;
- списки: `domain-set`, `ip-set`, `block-file`, `hosts-file`, `bogus-nxdomain`,
  `ignore-ip`, `whitelist-ip`, `blacklist-ip`, `ip-alias`, `ip-rules` и файлы списков;
- клиенты: `client-rules` по IP/CIDR/MAC/ip-set;
- IPSet (и NFTSet с явной пометкой «не поддерживается» там, где нет nftables);
- кэш: параметры, просмотр, сброс через stats-мост ядра;
- Query Log и статистика: переиспользуется **встроенный stats-мост hrdns**
  (`ui-enable`/`ui-listen`), а не дублируется парсинг логов;
- глобальные настройки ядра (кэш, логи, audit, TTL, dualstack, DNS64, ACL,
  speed-check, response-mode и т. д.);
- сырой редактор конфигурации с валидацией и откатом;
- управление службой, автозапуск, логи, диагностика;
- backup/restore конфигурации и списков с автоматическими копиями перед изменениями.

## Установка одной командой

```sh
wget -qO- https://raw.githubusercontent.com/alexbaryshef-dot/smartdns/main/webui/install.sh | sh
```

Параметры передаются после `sh -s --`, например:

```sh
wget -qO- https://raw.githubusercontent.com/alexbaryshef-dot/smartdns/main/webui/install.sh \
  | sh -s -- --ui-port 3637 --dns-port 5353 --password 'S3cret-pass'
```

Что делает установщик:

1. проверяет Entware, root, выбранные порты и зависимости;
2. скачивает файлы WebUI по `MANIFEST` и проверяет SHA-256;
3. устанавливает **сам форк-резолвер**: скачивает готовый бинарник `hrdns` 1.0.0
   (aarch64/mipsel/mips) из истории этого репозитория и проверяет SHA-256 по
   `SHA256SUMS`; если более новый `hrdns` уже установлен — использует его;
   generic `smartdns` — только запасной вариант;
4. создаёт `/opt/etc/forksmartdns`, `/opt/var/lib/forksmartdns`,
   `/opt/var/log/forksmartdns`, `/opt/var/run/forksmartdns`,
   `/opt/share/forksmartdns` и отдельный экземпляр lighttpd (или BusyBox httpd);
5. генерирует конфиг и init-скрипт, проверяет конфиг пробным запуском ядра;
6. запускает службу, проверяет HTTP, включает автозапуск.

### Какое ядро ставится

Установщик выбирает ядро в таком порядке:

1. `--core PATH` — явно указанный бинарник;
2. уже установленный `hrdns` (Hydra Route / `/opt/bin/hrdns`, `/opt/sbin/hrdns`),
   в том числе более новой версии — он не перезаписывается;
3. **готовый бинарник форка** `hrdns` 1.0.0 из истории этого репозитория
   (коммит `fab7d126`), с проверкой SHA-256 по `SHA256SUMS`;
4. generic `smartdns` из Entware (`opkg install smartdns`) — fallback без
   stats-моста.

Готовые бинарники форка существуют только для **1.0.0** (aarch64, mipsel, mips).
Версии 1.2.3 и 2.0.0 в репозитории опубликованы только как исходники. Поэтому
по умолчанию ставится 1.0.0; если вам нужна 1.2.3/2.0.0 — соберите её из
исходников и передайте `--core PATH`, либо заранее установите свежий hrdns.
Ядро 1.0.0 основано на smartdns 48.4, поддерживает QUIC/H3 и те же маршруты
stats-моста (`/api/stats`, `/api/domain`, `/api/cache`, `/api/upstream-server`),
поэтому панель работает с ним без изменений.

### Порты и сосуществование со штатным hrdns

| Что | По умолчанию | Почему |
|---|---|---|
| WebUI | `3636/tcp` | как в задании; при занятом порте установка останавливается |
| DNS изолированного ядра | `5353/udp+tcp` | штатный hrdns обычно уже слушает `53` |
| Stats-мост (loopback) | `127.0.0.1:36390` | только внутри роутера |

Если штатная панель hrdns уже занимает `3636`, используйте `--ui-port 3637`
или освободите порт. Установщик не останавливает и не трогает штатные службы.

Клиентов нужно направить на порт `5353` (или указать свой `--dns-port`), если
изолированный резолвер должен реально обслуживать сеть.

## Первый вход

Если пароль не передан через `--password`, установщик печатает одноразовый
установочный токен и кладёт его в `/opt/etc/forksmartdns/setup-token`.
Откройте `http://<IP-роутера>:3636/`, введите токен и задайте пароль (≥ 8 символов).
После настройки токен удаляется. Пароль можно сменить и в панели.

## Управление

```sh
forksmartdnsctl status
forksmartdnsctl start|stop|restart
forksmartdnsctl check
forksmartdnsctl backup [reason]
forksmartdnsctl list-backups
forksmartdnsctl restore NAME
forksmartdnsctl passwd
forksmartdnsctl diagnose
```

## Изоляция

```
/opt/etc/forksmartdns/           конфиг, auth, instance.env, свой бинарник, шаблоны
/opt/var/lib/forksmartdns/       кэш, данные stats-моста, резервные копии
/opt/var/log/forksmartdns/       логи ядра, audit и web
/opt/var/run/forksmartdns/       PID-файлы, сессии, временные файлы
/opt/share/forksmartdns/         код WebUI, www, docs, CLI
/opt/etc/init.d/forksmartdns     init-скрипт (новый файл)
```

Штатные `/opt/etc/HydraRoute/dns`, `/opt/bin/hrdns`, `/opt/etc/init.d/hrdns*`
не изменяются.

## Ограничения и честные пометки

- **nftables/NFTSet** на Keenetic обычно отсутствует: раздел помечен как
  неподдерживаемый, ipset работает при наличии пакета `ipset`.
- **HTTP/3 и DoQ** зависят от сборки ядра: состояние проверяется на странице
  «О системе» через `--is-quic-supported`.
- **Статистика, Query Log и просмотр кэша** требуют stats-моста hrdns. С
  generic-бинарником `smartdns` (без `ui-*`) эти страницы помечаются как
  частично недоступные.
- Готовые бинарники форка — только 1.0.0; 1.2.3/2.0.0 нужно собирать из
  исходников или использовать уже установленный hrdns.
- Автоматический перезапуск при падении ядра не включён по умолчанию.
- UI работает по HTTP в LAN; TLS для панели не настроен. Не публикуйте порт в
  интернет.
- Приёмочные испытания на реальном роутере не проводились (см. TESTING.md).

## Документация

- [docs/INSTALL.md](docs/INSTALL.md) — установка, обновление, удаление, порты;
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — как устроено;
- [docs/CONFIG.md](docs/CONFIG.md) — конфигурация и поддерживаемые директивы;
- [docs/API.md](docs/API.md) — внутренний API панели;
- [docs/SECURITY.md](docs/SECURITY.md) — модель безопасности;
- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) — матрица возможностей;
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — если что-то не работает;
- [docs/TESTING.md](docs/TESTING.md) и [docs/TEST-REPORT.md](docs/TEST-REPORT.md) —
  тесты и фактический отчёт.

## Лицензии

Код WebUI распространяется по GPL-3.0 (совместимо с лицензией репозитория и
ядра hrdns/smartdns). Бинарник ядра не входит в WebUI: установщик скачивает
готовый форк-бинарник `hrdns` 1.0.0 из истории этого репозитория (с проверкой
SHA-256), копирует уже установленный более новый `hrdns` либо ставит пакет
`smartdns` из Entware как fallback.
