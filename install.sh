#!/bin/sh
# hrdns — единый DNS-резолвер со встроенным веб-интерфейсом для роутеров Keenetic с Entware.
#
# Установка одной ссылкой (под root на роутере):
#   wget -qO- https://raw.githubusercontent.com/HydraRoute/hrdns/main/install.sh | sh
# или, если wget нет:
#   curl -fsSL https://raw.githubusercontent.com/HydraRoute/hrdns/main/install.sh | sh
#
# После установки панель доступна по адресу http://192.168.1.1:3636/
# (IP роутера может быть другим — см. вывод скрипта).
#
# Переменные окружения:
#   HRDNS_URL_BASE  — зеркало/каталог выпуска (по умолчанию GitHub Releases HydraRoute/hrdns)
#   HRDNS_PORT      — порт веб-панели (по умолчанию 3636)
#   HRDNS_NO_START  =1 — не запускать сервис сразу

set -eu

PORT="${HRDNS_PORT:-3636}"
URL_BASE="${HRDNS_URL_BASE:-https://github.com/HydraRoute/hrdns/releases/latest/download}"
PREFIX="${HRDNS_PREFIX:-/opt}"
BIN="$PREFIX/bin"
ETC="$PREFIX/etc"
INITD="$PREFIX/etc/init.d"
CONF_DIR="$ETC/HydraRoute/dns"
CONF="$CONF_DIR/hrdns.conf"
DATA_DIR="$CONF_DIR/data"
LOG_FILE="$PREFIX/var/log/hrdns.log"
PIDFILE="$PREFIX/var/run/hrdns.pid"
# по умолчанию панель слушает unix-сокет (см. core/ui/ui_main.c); tcp-listen включает loopback TCP
UI_SOCK="$PREFIX/var/run/hrdns-ui.sock"

say() { echo "==> $*"; }
die() { echo "hrdns: $*" >&2; exit 1; }

# --- проверки окружения -------------------------------------------------------

[ "$(id -u)" = "0" ] || die "запускайте под root (на Keenetic: через Entware-TERM или telnet/ssh)"
[ -d "$PREFIX" ] || die "Entware не найден ($PREFIX отсутствует). Сначала установите Entware."
command -v opkg >/dev/null 2>&1 || [ -x "$BIN/opkg" ] || die "opkg не найден — Entware не установлен?"

OPKG="opkg --offline-root $PREFIX"

fetch() { # fetch <url> <файл>
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 15 -O "$2" "$1"
    else
        die "не найдены curl или wget"
    fi
}

# --- определение архитектуры --------------------------------------------------

ARCH="$(uname -m 2>/dev/null || echo unknown)"
case "$ARCH" in
    mipsel|mipsle|4kec*) PKG_ARCH="mipsel" ;;
    mips)                PKG_ARCH="mips" ;;
    aarch64|arm64)       PKG_ARCH="aarch64" ;;
    armv7l|armv6l|arm*)  PKG_ARCH="aarch64" ; say "WARN: ARM32 ($ARCH) официально не поддерживается, пробуем aarch64-пакет" ;;
    x86_64)              PKG_ARCH="x86_64" ;;
    *)                   die "неизвестная архитектура: $ARCH" ;;
esac
say "Архитектура: $ARCH -> пакет hrdns.$PKG_ARCH"

TMP="$(mktemp -d 2>/dev/null || echo /tmp/hrdns.$$)"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

# --- установка бинарника ------------------------------------------------------

if "$OPKG" install hrdns >/dev/null 2>&1; then
    say "Пакет hrdns установлен из репозитория Entware"
else
    say "Через opkg не вышло — ставим бинарник напрямую из выпуска"
    fetch "$URL_BASE/hrdns-$PKG_ARCH.tar.gz" "$TMP/hrdns.tar.gz" || \
        fetch "$URL_BASE/hrdns.$PKG_ARCH.tar.gz" "$TMP/hrdns.tar.gz"
    tar xzf "$TMP/hrdns.tar.gz" -C "$TMP"
    [ -f "$TMP/hrdns" ] || die "в архиве нет файла hrdns"
    mkdir -p "$BIN"
    # даунгрейд/обновление: удаляем старый файл до копирования (Text file busy)
    [ -f "$BIN/hrdns" ] && rm -f "$BIN/hrdns"
    cp "$TMP/hrdns" "$BIN/hrdns"
    chmod 755 "$BIN/hrdns"
    say "Бинарник установлен: $("$BIN/hrdns" -v 2>/dev/null || echo '?')"
fi

HRDNS_BIN="$BIN/hrdns"
[ -x "$HRDNS_BIN" ] || HRDNS_BIN="$PREFIX/sbin/hrdns"
[ -x "$HRDNS_BIN" ] || die "hrdns не найден среди установленных файлов"

# --- конфигурация -------------------------------------------------------------

mkdir -p "$CONF_DIR" "$DATA_DIR" "$PREFIX/var/log" "$PREFIX/var/run"

if [ ! -f "$CONF" ]; then
    cat > "$CONF" <<EOF
# Конфигурация hrdns (создана установщиком $(date '+%Y-%m-%d %H:%M'))
# Полная синтаксическая справка: https://github.com/pymumu/smartdns/blob/master/configuration-files.md

# --- Веб-панель статистики ---
# Панель доступна по адресу http://<IP-роутера>:$PORT/
ui-enable yes
ui-listen unix:$UI_SOCK
tcp-listen 127.0.0.1:$PORT
ui-data-dir $DATA_DIR
ui-days 7
ui-max-mb 256

# --- Слушатели DNS ---
bind [::]:53
bind-tcp [::]:53

# --- Вышестоящие серверы ---
server 223.5.5.5 -name alidns -exclude-default-group
server https://dns.alidns.com/dns-query -name alidns-doh -exclude-default-group
server 8.8.8.8 -name google -exclude-default-group
server https://dns.google/dns-query -name google-doh -exclude-default-group
server-tls 1.1.1.1 -name cloudflare -exclude-default-group

# --- Прочее ---
cache-size 3000
speed-check-mode ping,tcp:443
rr-check yes
audit-log enable
EOF
    say "Создана конфигурация $CONF"
else
    say "Конфигурация уже существует, не трогаем её: $CONF"
    # гарантируем включённую панель
    grep -q '^ui-enable' "$CONF" || sed -i "1i ui-enable yes" "$CONF"
    grep -q '^ui-listen\|^tcp-listen' "$CONF" || { echo "ui-listen unix:$UI_SOCK" >> "$CONF"; echo "tcp-listen 127.0.0.1:$PORT" >> "$CONF"; }
fi

# --- прокси панели: LAN -> 127.0.0.1:PORT / unix-сокет ------------------------
# Панель hrdns слушает только loopback/сокет; этот скрипт пробрасывает её на LAN.

cat > "$INITD/hrdns-web" <<EOF
#!/bin/sh
# PRO-TITLE: Прокси веб-панели hrdns (LAN:$PORT)
# PRO-DESC: Пробрасывает доступ к панели hrdns с $PORT на LAN-интерфейс роутера.
### BEGIN INIT INFO
# Provides:          hrdns-web
# Required-Start:
# Required-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: hrdns web panel proxy on port $PORT
### END INIT INFO

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/opt/sbin:/opt/bin
PORT=$PORT
BACKEND=""
PIDF="$PREFIX/var/run/hrdns-web.pid"

running() { [ -f "\$PIDF" ] && kill -0 "\$(cat "\$PIDF")" 2>/dev/null; }

pick_backend() {
    i=0
    while [ \$i -lt 30 ]; do
        if command -v ss >/dev/null 2>&1; then
            ss -ltn 2>/dev/null | grep -q "127.0.0.1:$PORT\$" && { BACKEND="tcp:127.0.0.1:$PORT"; return 0; }
        else
            netstat -ltn 2>/dev/null | grep -q "127.0.0.1:$PORT" && { BACKEND="tcp:127.0.0.1:$PORT"; return 0; }
        fi
        [ -S "$UI_SOCK" ] && { BACKEND="unix:$UI_SOCK"; return 0; }
        sleep 1; i=\$((i+1))
    done
    return 1
}

start() {
    running && return 0
    pick_backend || { echo "hrdns-ui backend (tcp 127.0.0.1:$PORT or socket) not found" >&2; return 1; }
    socat TCP-LISTEN:\$PORT,fork,reuseaddr "\$BACKEND" &
    echo \$! > "\$PIDF"
    return 0
}

stop() {
    running && kill "\$(cat "\$PIDF")" 2>/dev/null
    pkill -f "TCP-LISTEN:\$PORT.*hrdns" 2>/dev/null
    rm -f "\$PIDF"
    return 0
}

case "\$1" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    status)  running && echo "running (\$BACKEND)" || echo stopped ;;
    *) echo "usage: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
chmod 755 "$INITD/hrdns-web"

if ! command -v socat >/dev/null 2>&1; then
    say "Ставим socat для прокси панели на порт $PORT"
    "$OPKG" update >/dev/null 2>&1 || true
    "$OPKG" install socat >/dev/null 2>&1 || say "WARN: socat не установился — панель будет доступна только через ssh-туннель"
fi

# --- init-скрипт сервиса ------------------------------------------------------

cat > "$INITD/hrdns" <<EOF
#!/bin/sh
# PRO-TITLE: hrdns — DNS-резолвер с веб-панелью
# PRO-DESC: Единый DNS-резолвер (smartdns) со встроенной панелью статистики на порту $PORT.
### BEGIN INIT INFO
# Provides:          hrdns
# Required-Start:
# Required-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: hrdns DNS resolver with built-in web stats UI
### END INIT INFO

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/opt/sbin:/opt/bin
BIN="$HRDNS_BIN"
CONF="$CONF"
LOG="$LOG_FILE"
PIDF="$PIDFILE"

running() { [ -f "\$PIDF" ] && kill -0 "\$(cat "\$PIDF")" 2>/dev/null; }

start() {
    running && return 0
    "\$BIN" -c "\$CONF" -p "\$PIDF"
    rc=\$?
    [ \$rc -eq 0 ] && "$INITD/hrdns-web" start
    return \$rc
}

stop() {
    "$INITD/hrdns-web" stop
    running && kill "\$(cat "\$PIDF")" 2>/dev/null
    sleep 1
    running && kill -9 "\$(cat "\$PIDF")" 2>/dev/null
    rm -f "\$PIDF"
    return 0
}

restart() { stop; sleep 1; start; }

case "\$1" in
    start)   start ;;
    stop)    stop ;;
    restart) restart ;;
    reload)  kill -HUP "\$(cat "\$PIDF")" 2>/dev/null || "\$0" restart ;;
    status)  running && echo running || echo stopped ;;
    enable)  touch "$PREFIX/etc/rc.local"; \
             grep -q "$INITD/hrdns start" "$PREFIX/etc/rc.local" || \
             echo "$INITD/hrdns start" >> "$PREFIX/etc/rc.local"; chmod +x "$PREFIX/etc/rc.local" ;;
    disable) sed -i "\|$INITD/hrdns start|d" "$PREFIX/etc/rc.local" 2>/dev/null; true ;;
    *) echo "usage: \$0 {start|stop|restart|reload|status|enable|disable}"; exit 1 ;;
esac
EOF
chmod 755 "$INITD/hrdns"

# автозагрузка
if [ -f "$PREFIX/etc/rc.local" ] || [ ! -d "$PREFIX/etc/rc.d" ]; then
    touch "$PREFIX/etc/rc.local"
    grep -q "$INITD/hrdns start" "$PREFIX/etc/rc.local" || echo "$INITD/hrdns start" >> "$PREFIX/etc/rc.local"
    chmod +x "$PREFIX/etc/rc.local"
fi
# стандартный путь entware
if [ -d "$PREFIX/etc/rc.d" ]; then
    ln -sf "$INITD/hrdns" "$PREFIX/etc/rc.d/S99hrdns"
    ln -sf "$INITD/hrdns-web" "$PREFIX/etc/rc.d/S99hrdns-web"
fi

# --- запуск -------------------------------------------------------------------

if [ "${HRDNS_NO_START:-0}" != "1" ]; then
    say "Запускаем hrdns..."
    "$INITD/hrdns" restart || die "сервис не запустился; проверьте $LOG_FILE"
    say "Прокси панели..."
    "$INITD/hrdns-web" restart || say "WARN: прокси панели не запустился (порт $PORT может быть занят)"
fi

LAN_IP="$(ip -4 addr show 2>/dev/null | awk '/inet (192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01]))/{print $2; exit}' | cut -d/ -f1)"
[ -n "$LAN_IP" ] || LAN_IP="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
[ -n "$LAN_IP" ] || LAN_IP="<IP-роутера>"

say "Готово!"
echo
echo "  Веб-панель hrdns:  http://$LAN_IP:$PORT/"
echo "  Конфигурация:      $CONF"
echo "  Управление:        $INITD/hrdns {start|stop|restart|status}"
echo "  Логи:              $LOG_FILE"
echo
echo "Не забудьте направить DNS клиентов на роутер (Keenetic: Интернет -> Сетевые правила -> DNS)."
