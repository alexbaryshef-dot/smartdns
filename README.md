# hrdns

Единый бинарник DNS-резолвера для роутеров Keenetic с Entware со встроенным веб-интерфейсом статистики. Основан на [smartdns](https://github.com/pymumu/smartdns) и [smartdns-webui](https://github.com/pymumu/smartdns-webui). Распространяется пакетом `hrdns` в репозитории Entware Hydra Route (mipsel, mips, aarch64): веб-интерфейс Hydra Route устанавливает его при включении «Службы DNS» и обновляет вместе с остальными пакетами, отдельно устанавливать ничего не нужно.

Текущая версия: **1.2.3** (`hrdns -v`).

## Исходники и лицензии

- hrdns в целом — GNU GPL v3 (`LICENSE`); исходники этой версии — `src/hrdns/hrdns-1.2.3-src.tar.gz`.
- smartdns Release48.4 — https://github.com/pymumu/smartdns, GNU GPL v3.
- smartdns-webui — https://github.com/pymumu/smartdns-webui, MIT (`LICENSES/MIT-smartdns-webui.txt`).
- OpenSSL 3.5.8 — https://github.com/openssl/openssl/releases/tag/openssl-3.5.8, Apache 2.0 (`LICENSES/Apache-2.0-openssl.txt`).
- Происхождение и состав — `NOTICE.md`.
- 
Установите hrdns одной командой: wget -qO- https://raw.githubusercontent.com/HydraRoute/hrdns/main/install.sh | sh. Скрипт автоматически определит архитектуру, установит пакет или бинарник из GitHub, настроит конфигурацию с включенным веб-интерфейсом и создаст init-скрипты для запуска сервиса и прокси (через socat) на порту 3636. После установки панель управления будет доступна по адресу http://192.168.1.1:3636/ (порт можно изменить через переменную окружения HRDNS_PORT).
