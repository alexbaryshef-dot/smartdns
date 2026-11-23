# API панели

Внутренний API предназначен для SPA этой панели. Он не является публичным
контрактом и может меняться без сохранения совместимости между пре-релизами.

## Точка входа

```
/cgi-bin/api.cgi?action=<action>[&параметры]
```

Методы: `GET` для чтения, `POST` для изменений. Тело запроса — один из форматов:

- `application/x-www-form-urlencoded` — простые формы (`login`, `service`,
  `config.restore`, `password`);
- `text/plain` — текст конфигурации/блока (`config.apply`, `config.block`,
  `files.write`);
- `application/gzip` — архив для `config.upload`.

## Аутентификация

- Cookie `fsd_session=<32 hex>` (HttpOnly, SameSite=Strict, TTL 8 ч).
- Для `POST` обязателен заголовок `X-FSD-CSRF: <token>`.
- Токен выдаётся в `session` (если сессия есть), `login` и `setup`.
- Ошибки: `401 unauthorized`, `403 csrf`, `403 origin`.

## Формат ответа

```json
{"ok": true, "data": { ... }}
```

```json
{"ok": false, "error": {"code": "config_invalid", "message": "...", "detail": "..."}}
```

HTTP-коды: 200, 400, 401, 403, 404, 405, 409, 413, 429, 500, 503.

## Публичные действия

| Действие | Метод | Параметры | Ответ |
|---|---|---|---|
| `session` | GET | — | `authenticated`, `initialized`, `setup_required`, `csrf` |
| `setup` | POST | form: `token`, `password` | cookie + `csrf`; только если пароль ещё не задан |
| `login` | POST | form: `password` | cookie + `csrf` |

## Сессия и пароль

| Действие | Метод | Параметры |
|---|---|---|
| `logout` | POST | CSRF; удаляет сессию |
| `password` | POST | form: `current`, `new`; инвалидирует все сессии |

## Система

| Действие | Метод | Ответ |
|---|---|---|
| `status` | GET | служба, экземпляр, платформа, конфиг, мост, предупреждения |
| `capabilities` | GET | матрица возможностей и причина недоступности |
| `diag` | GET | список проверок `{id,state,detail}` |
| `about` | GET | версии, лицензия, пути |
| `service` | POST | form: `action=start|stop|restart|enable|disable` |
| `logs.tail` | GET | `name=core|audit|web|validate`, `lines<=2000` |

## Конфигурация

| Действие | Метод | Параметры | Тело |
|---|---|---|---|
| `config.get` | GET | — | `raw`, `blocks`, `path`, `mtime`, `sha256`, `lines` |
| `config.blocks` | GET | — | только блоки |
| `config.validate` | POST | `runtime=0|1` | текст конфига; `valid`, `errors`, `warnings`, `runtime` |
| `config.apply` | POST | — | текст конфига; backup + restart + rollback |
| `config.block` | POST | `name=<блок>`, `restart=0|1` | текст блока |
| `config.backups` | GET | — | список архивов |
| `config.backup` | POST | — | создать копию |
| `config.restore` | POST | form: `name` | восстановить копию |
| `config.upload` | POST | `name=<файл.tgz>` | gzip-тело, проверка и восстановление |
| `config.download` | GET | `name` | поток `application/gzip` |
| `config.delete-backup` | POST | form: `name` | удалить архив |

Допустимые имена блоков: `globals`, `listeners`, `upstreams`, `groups`, `domains`,
`lists`, `clients`, `ipset`, `extra`.

## Файлы списков

Работают только с плоскими именами в `/opt/etc/forksmartdns/lists/`
(`[A-Za-z0-9._-]`, не более 128 символов, без `..`).

| Действие | Метод | Параметры | Тело |
|---|---|---|---|
| `files.list` | GET | — | `{dir, files:[{name,size,mtime}]}` |
| `files.read` | GET | `name` | `{name,size,content}` (≤ 1 МиБ) |
| `files.write` | POST | `name` | текст файла (≤ 1 МиБ) |
| `files.delete` | POST | `name` | удалить |

## Статистика, кэш, журнал (через stats-мост)

Проксируются в `http://127.0.0.1:<ui-listen>/api/...`; при недоступном мосте
возвращается `503 bridge`.

| Действие | Метод | Параметры |
|---|---|---|
| `stats.metrics` | GET | — |
| `stats.overview` | GET | — |
| `stats.hourly` | GET | `past_hours` (1…9600) |
| `stats.daily` | GET | `past_days` (1…400) |
| `stats.top.domain` | GET | `count`, `is_blocked` |
| `stats.top.client` | GET | `count` |
| `stats.upstream` | GET | — |
| `cache.count` | GET | — |
| `cache.list` | GET | — |
| `cache.flush` | POST | CSRF; `PUT /api/cache/flush` |
| `querylog` | GET | `page_num`, `page_size`, `domain`, `domain_filter_mode`, `domain_type`, `client`, `domain_group`, `reply_code`, `is_blocked`, `is_cached`, `timestamp_after`, `timestamp_before`, `order`, `cursor`, `cursor_direction`, `total_count`, `id` |
| `querylog.count` | GET | — |

## Примеры

```sh
# вход и сохранение cookie
curl -c /tmp/fsd.jar -X POST \
  -d 'password=S3cret-pass' \
  'http://192.168.1.1:3636/cgi-bin/api.cgi?action=login'

# статус
curl -b /tmp/fsd.jar 'http://192.168.1.1:3636/cgi-bin/api.cgi?action=status'

# CSRF берётся из ответа session/login
CSRF=...
curl -b /tmp/fsd.jar -H "X-FSD-CSRF: $CSRF" \
  --data-binary @/tmp/upstreams.txt \
  'http://192.168.1.1:3636/cgi-bin/api.cgi?action=config.block&name=upstreams'

# проверка конфига без применения
curl -b /tmp/fsd.jar -H "X-FSD-CSRF: $CSRF" \
  --data-binary @/tmp/forksmartdns.conf \
  'http://192.168.1.1:3636/cgi-bin/api.cgi?action=config.validate&runtime=1'
```

## Коды ошибок

| code | Смысл |
|---|---|
| `unauthorized` | нет/истекла сессия |
| `csrf` | неверный/отсутствующий CSRF |
| `origin` | cross-origin запрос |
| `invalid_credentials` | неверный пароль |
| `locked` | слишком много попыток |
| `setup_token` | неверный установочный токен |
| `config_invalid` | конфиг не прошёл проверку |
| `bridge` | stats-мост недоступен |
| `restore` | ошибка восстановления |
| `bad_name` | недопустимое имя файла/архива |
| `not_found` | объект не найден |
