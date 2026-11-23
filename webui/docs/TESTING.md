# Тестирование

## Что можно запустить без роутера

### Unit-тесты JS

```sh
node tests/core.test.js
```

Проверяют парсинг схемы, блоков, групп, валидаторы, форматирование. DOM не нужен.

### Self-test (API + HTTP + install)

Нужен Python 3.9+, POSIX shell и BusyBox с applet `httpd` (подходит
`busybox-w32` на Windows или полноценный BusyBox на Linux).

```sh
BUSYBOX=/path/to/busybox python3 tests/selftest.py
# Windows:
# set BUSYBOX=C:\path\busybox.exe
# set FSD_TEST_WORK=C:\path\work
# python tests\selftest.py
```

Тест создаёт временный префикс, копирует проект, подменяет настоящее ядро
скриптом-заглушкой и проверяет:

- статический валидатор (неизвестная директива, корректный конфиг);
- API: setup/login, сессии, CSRF, status, config.get, config.validate,
  config.block (с пробным запуском и backup), files, backups, restore,
  cache (явный 503 при недоступном мосте), diag, service stop, logout;
- реальный HTTP через BusyBox httpd + CGI: cookie, CSRF, POST-only для
  изменяющих действий, статика, защита от path traversal;
- `install.sh` → повторная установка (отказ) → `--upgrade` → `uninstall.sh`
  с проверкой, что конфиг сохранился, а файлы удалены;
- установка форк-ядра из локального фида: скачивание, проверка SHA-256 и запись
  `FSD_CORE_SOURCE=fork`.

Заглушка ядра печатает `hrdns starting...` и живёт несколько секунд; она НЕ
резолвит DNS и НЕ является smartdns.

## Что self-test не проверяет

- запуск настоящего `hrdns`/`smartdns` и реальные DNS-ответы;
- DoT/DoH/DoH3/DoQ и TLS-сертификаты;
- stats-мост реального ядра (проверяется только корректная деградация);
- lighttpd (запускается только BusyBox httpd);
- aarch64/mips, KeeneticOS, `opkg`;
- работу SPA в браузере (только синтаксис и HTTP-статика).

Поэтому статус проекта — **PRE-RELEASE**, без тега stable.

## Ручной чек-лист на реальном роутере

Выполняйте на тестовом роутере, предварительно сохранив конфигурацию Keenetic.

1. **Сосуществование**
   - установить при работающем штатном hrdns;
   - убедиться, что `3636` занят → installer просит `--ui-port`;
   - поставить `--ui-port 3637`, проверить, что `/opt/etc/HydraRoute/dns` и
     `/opt/bin/hrdns` не изменились (`md5sum` до/после).
2. **Запуск/остановка**
   - `forksmartdnsctl start|status|stop|start`;
   - `restart`, проверить, что старый PID исчез, новый появился;
   - перезагрузка роутера → автозапуск.
3. **DNS**
   - если резолвер слушает `53` — `nslookup example.com 127.0.0.1`;
   - если `5353` — `dig @127.0.0.1 -p 5353 example.com` (BusyBox `nslookup`
     не умеет порт) либо смотрите Query Log/диагностику;
   - добавить DoT/DoH upstream, проверить ответы;
   - проверить кэш (второй запрос), Query Log, статистику;
   - если мост недоступен — проверить `ui-enable`/`ui-listen` и лог.
4. **Конфигурация**
   - применить заведомо плохой конфиг → отказ и отсутствие изменений;
   - применить рабочий → backup создан, служба поднялась;
   - восстановить backup;
   - выключить `ui-enable` в сыром конфиге → страницы stats показывают
     недоступность, управление работает.
5. **Удаление**
   - `uninstall.sh`; проверить, что штатный hrdns работает;
   - `--keep-config` и повторная установка.
6. **Веб-сервер**
   - lighttpd-режим (`--web-server lighttpd`), проверить `lighttpd -t`,
     логи и CGI.
7. **Браузер**
   - desktop и телефон, все разделы, тёмная тема, отсутствие внешних запросов
     (CSP), смена пароля, logout, истечение сессии.

## Автоматизация в CI

`tests/selftest.py` можно запускать в Linux-контейнере с `busybox` (applet
`httpd`) и Python. Для теста установки нужен `FORKSMDNS_ALLOW_NONROOT=1` и
временный префикс. Настоящий `opkg`/aarch64 в CI не проверяются.
