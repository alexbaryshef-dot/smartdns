# Конфигурация

Файл: `/opt/etc/forksmartdns/forksmartdns.conf` (права `0600`).

## Содержимое по умолчанию

- `fsd:globals` — глобальные параметры ядра;
- `fsd:listeners` — `bind`/`bind-tcp`, по умолчанию `0.0.0.0:5353`;
- `fsd:upstreams` — два публичных резолвера;
- остальные блоки пусты.

Управляемые блоки:

```
# >>> fsd:globals
...
# <<< fsd:globals
```

Структурированные страницы панели перерисовывают только соответствующий блок.
Всё, что вне блоков, сохраняется. Сырой редактор (`Конфигурация`) может изменить
весь файл — это полный доступ к возможностям ядра.

## Валидация

1. **Статическая** (`validate.awk`):
   - директива должна быть известна ядру (список взят из `dns_conf.c`);
   - проверяются типы: `yes/no`, целые с диапазоном, размеры (`128k`), enum,
     IP/CIDR, домены, пути, режимы `speed-check-mode`;
   - проверяется структура `group-begin`/`group-end`, дубли `bind`, опции
     `server*`, `bind*`, `client-rules`, `domain-rules`;
   - неизвестная опция сервера — предупреждение (ядро её игнорирует).
2. **Пробный запуск** настоящего ядра на копии конфига:
   - все `bind` заменяются на `127.0.0.1:0`, `ui-enable` выключается,
     log/cache/data перенаправляются во временный каталог;
   - если ядро не стартует или пишет об ошибке конфигурации — применение
     отклоняется.
3. Только после этого создаётся backup, файл пишется атомарно и служба
   перезапускается. При неудаче выполняется откат.

## Глобальные параметры (`fsd:globals`)

Полный список с типами и подсказками — `schema.tsv` (он же используется панелью).
Основные группы:

- **Общие**: `server-name`, `resolv-hostname`, `mdns-lookup`, `local-ptr-enable`,
  `expand-ptr-from-address`, `tcp-idle-time`, `max-query-limit`,
  `socket-buff-size`, `response-mode`, `speed-check-mode`, `max-reply-ip-num`,
  `force-AAAA-SOA`, `force-no-CNAME`.
- **Кэш**: `cache-size`, `cache-mem-size`, `cache-persist`, `cache-checkpoint-time`,
  `cache-file`, `prefetch-domain`, `serve-expired*`, `dualstack-ip-*`.
- **Логи**: `log-level`, `log-file`, `log-size`, `log-num`, `log-color`,
  `log-console`, `log-syslog`.
- **Audit**: `audit-enable`, `audit-SOA`, `audit-file`, `audit-size`, `audit-num`,
  `audit-console`, `audit-syslog`.
- **TTL**: `rr-ttl`, `rr-ttl-min`, `rr-ttl-max`, `rr-ttl-reply-max`, `local-ttl`.
- **Безопасность**: `acl-enable`, `ca-file`, `ca-path`, `user`,
  `edns-client-subnet`, `edns-client-subnet-strip`, `ipset-timeout`,
  `nftset-timeout`, `nftset-debug`.
- **Stats-мост**: `ui-enable`, `ui-listen`, `ui-data-dir`, `ui-days`,
  `ui-max-mb`, `ui-flush-seconds`.
- **Диагностика**: `debug-save-fail-packet`, `resolv-file`.

Не меняйте `ui-listen` без необходимости: панель обращается к мосту по этому
адресу. Если мост выключить, страницы статистики/журнала/кэша станут недоступны,
но управление конфигом продолжит работать.

## Upstream

```
server 223.5.5.5
server 1.1.1.1 -group default
server-tcp 8.8.8.8:53
server-tls 1.1.1.1:853 -host-name one.one.one.one
server-https https://dns.google/dns-query
server-h3 https://dns.cloudflare.com/dns-query
server-quic quic://dns.adguard-dns.com:853
```

Опции ядра (проверяются валидатором):

`-group`, `-exclude-default-group`, `-proxy`, `-bootstrap-dns`, `-interface`,
`-check-edns`, `-whitelist-ip`, `-blacklist-ip`, `-set-mark`, `-subnet`,
`-hitchhiking`, `-host-ip`, `-spki-pin`, `-host-name`, `-http-host`,
`-tls-host-verify`, `-tcp-keepalive`, `-subnet-all-query-types`, `-fallback`,
`-alpn`, `-drop-packet-latency`, `-no-check-certificate`.

> В конфиге штатного hrdns встречается `-name`. В этой сборке ядра опции `-name`
> нет: она игнорируется. Не используйте её; для подписи используйте комментарии
> или группы.

DoH/DoT/DoQ требуют корректного CA и времени на роутере. Для самоподписанных
серверов допустим `-no-check-certificate`, но это снижает безопасность.

## Слушатели

```
bind 0.0.0.0:5353
bind-tcp 0.0.0.0:5353
bind-tls 0.0.0.0:853
bind-https 0.0.0.0:443
```

Опции: `-group`, `-no-rule-addr`, `-no-rule-nameserver`, `-no-rule-ipset`,
`-no-speed-check`, `-no-cache`, `-no-rule-soa`, `-no-dualstack-selection`,
`-no-ip-alias`, `-force-aaaa-soa`, `-force-https-soa`, `-no-serve-expired`,
`-no-rules`, `-acl`, `-ipset`, `-nftset`, `-alpn`, `-ddr`.

TLS/DoH-сертификат ядро умеет генерировать автоматически
(`bind-cert-generate auto`), но эти директивы задаются в сыром редакторе.

## Группы

```
group-begin office -inherit default
group-match -domain example.com
group-match -client-ip 192.168.1.0/24
speed-check-mode tcp:443
group-end
```

Серверы привязываются к группе через `-group office` в `server*`, domены — через
`nameserver /domain/office` или `domain-rules /domain/ -group office`.

## Правила доменов

```
address /blocked.example/# 
address /static.example/1.2.3.4
nameserver /corp.example/office
domain-rules /video.example/ -speed-check-mode tcp:443 -group fast
cname /alias.example/target.example
srv-record /_ldap._tcp.example/ldap.example.com,389
https-record /example.com/ipv4hint=192.168.1.2
txt-record /_acme-challenge.example/value
local-domain printer.lan
```

Селектор: `/example.com/` или `/domain-set:name/`.

## Списки и файлы

```
domain-set -name ads -type list -file /opt/etc/forksmartdns/lists/ads.txt
ip-set -name lan -type list -file /opt/etc/forksmartdns/lists/lan.txt
block-file /opt/etc/forksmartdns/lists/block.txt
hosts-file /opt/etc/forksmartdns/lists/hosts
bogus-nxdomain 1.2.3.4
ignore-ip 10.0.0.0/8
whitelist-ip 203.0.113.0/24
blacklist-ip 198.51.100.0/24
ip-alias 192.168.0.1/24 10.9.0.1,10.9.0.2
```

Файлы списков лежат в `/opt/etc/forksmartdns/lists/` и редактируются на странице
«Списки». Формат domain-set — по одному домену в строке (`#` — комментарий,
`*.example.com` — wildcard). ip-set — CIDR/IP.

## Клиенты

```
client-rules 192.168.1.10 -group office
client-rules 192.168.1.0/24 -no-cache -no-speed-check
client-rules aa:bb:cc:dd:ee:ff -group kids
client-rules ip-set:guests -group guests
```

Флаги: `-group`, `-no-rule-addr`, `-no-rule-nameserver`, `-no-rule-ipset`,
`-no-speed-check`, `-no-cache`, `-no-rule-soa`, `-no-dualstack-selection`,
`-no-ip-alias`, `-force-aaaa-soa`, `-acl`, `-no-rules`, `-no-serve-expired`.

MAC-правила работают в пределах L2-сегмента (ядро смотрит таблицу соседей).

## IPSet / NFTSet

```
ipset /example.com/example_v4
ipset-no-speed direct_v4
ipset-timeout yes
```

Для NFTSet синтаксис: `#4:ip#table#set`. На Keenetic nftables обычно отсутствует,
поэтому раздел помечен как неподдерживаемый; правила можно сохранить, но ядро
не сможет их применить.

## Кэш, логи, audit

- `cache-persist yes` + `cache-file` — кэш переживает перезапуск;
- `cache-checkpoint-time` — период записи;
- `audit-enable yes` + `audit-file` — текстовый журнал (дублирует Query Log);
- `ui-days`/`ui-max-mb` — хранение журнала и статистики stats-мостом.

## Ручное редактирование

Можно править файл вручную. После правки:

```sh
forksmartdnsctl check
forksmartdnsctl restart
```

Панель при следующем открытии покажет новое содержимое. Если удалить маркеры
`fsd:*`, структурированные страницы добавят блоки заново в конец файла.

## Неподдерживаемое

- `nftset*` — при отсутствии nftables (пометка в UI);
- `server-h3`/`server-quic` — если сборка ядра без QUIC (проверка
  `--is-quic-supported`);
- `systemd`, Docker, nginx — не используются;
- авто-перезапуск при падении ядра — не включён.
