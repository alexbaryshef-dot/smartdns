#!/bin/sh
# forksmartdns WebUI — isolated one-command installer for Keenetic + Entware.
#
#   wget -qO- https://raw.githubusercontent.com/alexbaryshef-dot/smartdns/main/webui/install.sh | sh
#
# Nothing from the stock Hydra Route hrdns installation is modified: the
# instance lives in its own directories, has its own binary/PID/config/logs
# and uses its own ports.
#
# Options (pass after `sh -s --`):
#   --prefix DIR        install prefix (default /opt)
#   --dns-port N        DNS port of the isolated resolver (default 5353)
#   --dns-bind ADDR     DNS bind address (default 0.0.0.0)
#   --ui-port N         WebUI port (default 3636)
#   --ui-bind ADDR      WebUI bind address (default 0.0.0.0)
#   --web-server X      auto|lighttpd|busybox (default auto)
#   --core PATH         use this resolver binary instead of autodetection
#   --password PASS     set the admin password now (or use --password-stdin)
#   --password-stdin    read the admin password from stdin (first line)
#   --no-deps           do not install packages with opkg
#   --no-start          install without starting the service
#   --no-autostart      do not enable autostart
#   --upgrade           upgrade an existing installation (keeps config/lists)
#   --force             continue when ports are busy / installation exists
#   --source DIR        use a local source tree (development/tests)
#   --repo OWNER/REPO   source repository (default alexbaryshef-dot/smartdns)
#   --ref REF           git ref (default main)
#   --help

set -u

PREFIX=${FORKSMDNS_PREFIX:-/opt}
DNS_PORT=5353
DNS_BIND=0.0.0.0
UI_PORT=3636
UI_BIND=0.0.0.0
WEB_SERVER=auto
CORE_PATH=""
PASSWORD=""
PASSWORD_STDIN=0
NO_DEPS=0
NO_START=0
NO_AUTOSTART=0
UPGRADE=0
FORCE=0
SOURCE_DIR=""
REPO=${FORKSMDNS_REPO:-alexbaryshef-dot/smartdns}
REF=${FORKSMDNS_REF:-main}
URL_BASE=${FORKSMDNS_URL_BASE:-https://raw.githubusercontent.com/$REPO/$REF/webui}

say()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'forksmartdns: %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<'EOF'
forksmartdns WebUI — установка одной командой (Keenetic + Entware).

  wget -qO- https://raw.githubusercontent.com/alexbaryshef-dot/smartdns/main/webui/install.sh | sh

Опции (после `sh -s --`):
  --prefix DIR        префикс установки (по умолчанию /opt)
  --dns-port N        DNS-порт изолированного резолвера (5353)
  --dns-bind ADDR     адрес DNS (0.0.0.0)
  --ui-port N         порт панели (3636)
  --ui-bind ADDR      адрес панели (0.0.0.0)
  --web-server X      auto|lighttpd|busybox
  --core PATH         свой бинарник hrdns/smartdns
  --password PASS     сразу задать пароль администратора
  --no-deps           не устанавливать пакеты через opkg
  --no-start          не запускать службу
  --no-autostart      не включать автозапуск
  --upgrade           обновить существующую установку (конфиг сохраняется)
  --force             продолжить при занятых портах / существующей установке
  --source DIR        локальный каталог исходников (разработка/тесты)
  --repo OWNER/REPO   репозиторий-источник
  --ref REF           git ref (main)
  --help
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--prefix) PREFIX=${2:?}; shift 2 ;;
		--dns-port) DNS_PORT=${2:?}; shift 2 ;;
		--dns-bind) DNS_BIND=${2:?}; shift 2 ;;
		--ui-port) UI_PORT=${2:?}; shift 2 ;;
		--ui-bind) UI_BIND=${2:?}; shift 2 ;;
		--web-server) WEB_SERVER=${2:?}; shift 2 ;;
		--core) CORE_PATH=${2:?}; shift 2 ;;
		--password) PASSWORD=${2:?}; shift 2 ;;
		--password-stdin) PASSWORD_STDIN=1; shift ;;
		--no-deps) NO_DEPS=1; shift ;;
		--no-start) NO_START=1; shift ;;
		--no-autostart) NO_AUTOSTART=1; shift ;;
		--upgrade) UPGRADE=1; shift ;;
		--force) FORCE=1; shift ;;
		--source) SOURCE_DIR=${2:?}; shift 2 ;;
		--repo) REPO=${2:?}; URL_BASE=${FORKSMDNS_URL_BASE:-https://raw.githubusercontent.com/$REPO/$REF/webui}; shift 2 ;;
		--ref) REF=${2:?}; URL_BASE=${FORKSMDNS_URL_BASE:-https://raw.githubusercontent.com/$REPO/$REF/webui}; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown option: $1 (try --help)" ;;
	esac
done

[ "$(id -u 2>/dev/null || echo 1)" = "0" ] || [ "${FORKSMDNS_ALLOW_NONROOT:-0}" = "1" ] || die "запускайте под root"
PREFIX=$(printf '%s' "$PREFIX" | tr '\\' '/')
[ -n "$SOURCE_DIR" ] && SOURCE_DIR=$(printf '%s' "$SOURCE_DIR" | tr '\\' '/')
[ -d "$PREFIX" ] || die "Entware не найден: $PREFIX отсутствует"
case "$PREFIX" in *' '*|*"'"*) die "prefix не должен содержать пробелов/кавычек" ;; esac
is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_uint "$DNS_PORT" || die "--dns-port должен быть числом"
is_uint "$UI_PORT" || die "--ui-port должен быть числом"
[ "$DNS_PORT" -ge 1 ] && [ "$DNS_PORT" -le 65535 ] || die "некорректный --dns-port"
[ "$UI_PORT" -ge 1 ] && [ "$UI_PORT" -le 65535 ] || die "некорректный --ui-port"
[ "$DNS_PORT" != "$UI_PORT" ] || die "--dns-port и --ui-port должны различаться"

ETC="$PREFIX/etc/forksmartdns"
LIB="$PREFIX/share/forksmartdns"
VAR="$PREFIX/var/lib/forksmartdns"
LOG="$PREFIX/var/log/forksmartdns"
RUN="$PREFIX/var/run/forksmartdns"
CONF="$ETC/forksmartdns.conf"
INITD="$PREFIX/etc/init.d"
INIT="$INITD/forksmartdns"
CTL="$LIB/bin/forksmartdnsctl"
TMP="$PREFIX/tmp/forksmartdns-install.$$"
TMP_FALLBACK="$PREFIX/var/lib/forksmartdns/.install.$$"

fetch() {
	# fetch URL DEST — try wget first, fall back to curl
	_url=$1
	_dst=$2
	if command -v wget >/dev/null 2>&1; then
		wget -q -T 25 -O "$_dst" "$_url" 2>/dev/null && [ -s "$_dst" ] && return 0
		: >"$_dst"
	fi
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 20 -o "$_dst" "$_url" 2>/dev/null && [ -s "$_dst" ] && return 0
	fi
	return 1
}

cleanup() {
	[ -n "${TMP:-}" ] && rm -rf "$TMP" 2>/dev/null || true
	[ -n "${TMP_FALLBACK:-}" ] && rm -rf "$TMP_FALLBACK" 2>/dev/null || true
}
trap 'cleanup' EXIT INT TERM

mkdir -p "$TMP" 2>/dev/null || { mkdir -p "$TMP_FALLBACK" || die "cannot create temp dir"; TMP="$TMP_FALLBACK"; }

# --- source tree ------------------------------------------------------------
SRC=""
if [ -n "$SOURCE_DIR" ]; then
	[ -f "$SOURCE_DIR/src/lib/common.sh" ] || die "--source: не найден $SOURCE_DIR/src/lib/common.sh"
	SRC=$SOURCE_DIR
else
	command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || die "нужны wget или curl"
	say "Загрузка исходников WebUI из $URL_BASE"
	mkdir -p "$TMP/wh"
	if ! fetch "$URL_BASE/MANIFEST" "$TMP/wh/MANIFEST"; then
		die "не удалось загрузить MANIFEST. Проверьте URL/доступ в интернет; для локальной установки используйте --source DIR"
	fi
	_ok=1
	while IFS= read -r _line; do
		case "$_line" in
			''|'#'*) continue ;;
		esac
		_hash=${_line%% *}
		_path=${_line#* }
		_path=$(printf '%s' "$_path" | sed 's/^ *//; s/ *$//')
		[ -n "$_hash" ] && [ -n "$_path" ] || continue
		_dst="$TMP/wh/$_path"
		mkdir -p "$(dirname "$_dst")" || die "mkdir failed"
		fetch "$URL_BASE/$_path" "$_dst" || { warn "не удалось загрузить $_path"; _ok=0; continue; }
		_got=$(sha256sum "$_dst" 2>/dev/null | cut -c1-64)
		[ "$_got" = "$_hash" ] || { warn "SHA-256 не совпал: $_path"; _ok=0; }
	done <"$TMP/wh/MANIFEST"
	[ "$_ok" = "1" ] || die "целостность загрузки не подтверждена"
	SRC="$TMP/wh"
fi
[ -f "$SRC/src/lib/common.sh" ] || die "повреждённый набор файлов: нет src/lib/common.sh"
VERSION=$(cat "$SRC/VERSION" 2>/dev/null | head -n 1)
[ -n "$VERSION" ] || VERSION="0.0.0"

FORKSMDNS_PREFIX="$PREFIX"
export FORKSMDNS_PREFIX
. "$SRC/src/lib/common.sh"

# --- existing installation --------------------------------------------------
EXISTING=0
if [ -f "$ETC/instance.env" ]; then
	EXISTING=1
	if [ "$UPGRADE" = "0" ] && [ "$FORCE" = "0" ]; then
		die "forksmartdns уже установлен в $PREFIX. Для обновления: --upgrade (конфигурация сохранится)"
	fi
	UPGRADE=1
fi
OURS_RUNNING=0
if [ -f "$RUN/forksmartdns.pid" ]; then
	_p=$(cat "$RUN/forksmartdns.pid" 2>/dev/null | tr -dc '0-9')
	[ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && OURS_RUNNING=1
fi

# --- ports ------------------------------------------------------------------
free_or_ours() {
	_port=$1
	_proto=$2
	_label=$3
	if port_listening "$_port" "$_proto"; then
		if [ "$OURS_RUNNING" = "1" ]; then
			return 0
		fi
		if [ "$FORCE" = "1" ]; then
			warn "$_label: порт $_port уже занят, продолжаю из-за --force"
			return 0
		fi
		die "$_label: порт $_port ($_proto) уже занят. Укажите другой порт (--$4) или освободите его. Оригинальный hrdns WebUI обычно занимает 3636 — для сосуществования используйте, например, --ui-port 3637."
	fi
	return 0
}
free_or_ours "$UI_PORT" tcp "WebUI" "ui-port"
free_or_ours "$DNS_PORT" udp "DNS" "dns-port"
free_or_ours "$DNS_PORT" tcp "DNS" "dns-port"

INTERNAL_PORT=36390
while port_listening "$INTERNAL_PORT" tcp; do
	INTERNAL_PORT=$((INTERNAL_PORT + 1))
	[ "$INTERNAL_PORT" -lt 36420 ] || die "не удалось выбрать внутренний порт stats-моста"
done

# --- dependencies -----------------------------------------------------------
OPKG=""
command -v opkg >/dev/null 2>&1 && OPKG=opkg
[ -z "$OPKG" ] && [ -x "$PREFIX/bin/opkg" ] && OPKG="$PREFIX/bin/opkg"
export OPKG

opkg_install() {
	[ -n "$OPKG" ] || return 1
	"$OPKG" update >/dev/null 2>&1 || true
	"$OPKG" install "$@" >/dev/null 2>&1
}

busybox_httpd() {
	_bb=""
	command -v busybox >/dev/null 2>&1 && _bb=busybox
	[ -z "$_bb" ] && [ -x /bin/busybox ] && _bb=/bin/busybox
	[ -n "$_bb" ] || return 1
	"$_bb" --list 2>/dev/null | grep -qx httpd || return 1
	printf '%s' "$_bb"
}

have_lighttpd() {
	command -v lighttpd >/dev/null 2>&1 || [ -x "$PREFIX/sbin/lighttpd" ] || [ -x "$PREFIX/bin/lighttpd" ]
}

choose_web_server() {
	case "$WEB_SERVER" in
		lighttpd)
			have_lighttpd || [ "$NO_DEPS" = "0" ] || die "lighttpd не установлен и указан --no-deps"
			if ! have_lighttpd; then
				opkg_install lighttpd lighttpd-mod-cgi || die "не удалось установить lighttpd"
			fi
			printf 'lighttpd'
			;;
		busybox)
			busybox_httpd >/dev/null || die "busybox без applet httpd; используйте --web-server lighttpd"
			printf 'busybox'
			;;
		auto|*)
			if have_lighttpd; then
				printf 'lighttpd'
				return 0
			fi
			if busybox_httpd >/dev/null; then
				printf 'busybox'
				return 0
			fi
			if [ "$NO_DEPS" = "0" ] && opkg_install lighttpd lighttpd-mod-cgi && have_lighttpd; then
				printf 'lighttpd'
				return 0
			fi
			busybox_httpd >/dev/null && { printf 'busybox'; return 0; }
			die "не найден веб-сервер: установите lighttpd+lighttpd-mod-cgi или busybox с httpd"
			;;
	esac
}
WEB_SERVER=$(choose_web_server)
say "Веб-сервер: $WEB_SERVER"

# --- required userland tools ------------------------------------------------
if ! command -v sha256sum >/dev/null 2>&1 && ! busybox sha256sum </dev/null >/dev/null 2>&1; then
	if [ "$NO_DEPS" = "0" ]; then
		opkg_install coreutils-sha256sum || true
	fi
	command -v sha256sum >/dev/null 2>&1 || die "не найден sha256sum (нужен для паролей и проверки конфигурации)"
fi
for _t in sed awk grep tar od; do
	command -v "$_t" >/dev/null 2>&1 || die "не найден $_t (BusyBox coreutils)"
done
command -v nc >/dev/null 2>&1 || warn "nc не найден: страницы статистики/кэша могут быть недоступны"
command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || warn "нет wget/curl"

# --- core binary ------------------------------------------------------------
find_core() {
	for _c in "$PREFIX/bin/hrdns" "$PREFIX/sbin/hrdns" /opt/bin/hrdns /opt/sbin/hrdns \
		"$PREFIX/bin/smartdns" "$PREFIX/sbin/smartdns" /opt/bin/smartdns /opt/sbin/smartdns; do
		[ -x "$_c" ] || continue
		"$_c" -v >/dev/null 2>&1 || continue
		printf '%s' "$_c"
		return 0
	done
	return 1
}

CORE=""
if [ -n "$CORE_PATH" ]; then
	[ -x "$CORE_PATH" ] || die "--core: файл не исполняемый: $CORE_PATH"
	"$CORE_PATH" -v >/dev/null 2>&1 || die "--core: бинарник не запускается"
	CORE=$CORE_PATH
else
	CORE=$(find_core 2>/dev/null || true)
	if [ -z "$CORE" ] && [ "$NO_DEPS" = "0" ]; then
		say "Резолвер не найден — ставлю пакет smartdns"
		opkg_install smartdns || true
		CORE=$(find_core 2>/dev/null || true)
	fi
	[ -n "$CORE" ] || die "не найден hrdns/smartdns. Установите пакет hrdns (Hydra Route) или smartdns, либо укажите --core PATH"
fi
CORE_VER=$("$CORE" -v 2>/dev/null | head -n 1)
case "$CORE_VER $CORE" in
	*hrdns*) CORE_KIND=hrdns ;;
	*) CORE_KIND=smartdns ;;
esac
say "Ядро: $CORE ($CORE_VER, тип $CORE_KIND)"
if [ "$CORE_KIND" != "hrdns" ]; then
	warn "Выбран generic smartdns: страницы статистики/кэша/Query Log будут недоступны (нет stats-моста hrdns)."
fi

# --- stop previous instance -------------------------------------------------
if [ "$UPGRADE" = "1" ] && [ -x "$INIT" ]; then
	say "Останавливаю предыдущий экземпляр"
	"$INIT" stop >/dev/null 2>&1 || true
fi

# Preserve configuration for upgrade / abort.
PRE_CONF=""
if [ -f "$CONF" ]; then
	PRE_CONF="$TMP/forksmartdns.conf.pre"
	cp "$CONF" "$PRE_CONF" 2>/dev/null || true
fi

# --- install files ----------------------------------------------------------
say "Установка файлов"
mkdir -p "$ETC" "$VAR" "$LOG" "$RUN" "$LIB/lib" "$LIB/cgi" "$LIB/www" "$LIB/www/cgi-bin" "$LIB/bin" "$LIB/etc" "$LIB/docs" "$ETC/bin" "$ETC/lists" "$VAR/tmp" "$VAR/backups" "$INITD" "$PREFIX/bin"
chmod 700 "$VAR/backups" 2>/dev/null || true

cp -R "$SRC/src/lib/." "$LIB/lib/" || die "copy lib failed"
cp -R "$SRC/src/cgi/." "$LIB/cgi/" || die "copy cgi failed"
cp "$LIB/cgi/api.cgi" "$LIB/www/cgi-bin/api.cgi" 2>/dev/null || true
cp -R "$SRC/src/www/." "$LIB/www/" || die "copy www failed"
cp -R "$SRC/src/bin/." "$LIB/bin/" || die "copy bin failed"
cp -R "$SRC/src/etc/." "$LIB/etc/" || die "copy etc failed"
if [ -d "$SRC/docs" ]; then cp -R "$SRC/docs/." "$LIB/docs/" 2>/dev/null || true; fi
cp "$SRC/uninstall.sh" "$LIB/uninstall.sh" 2>/dev/null || true
cp "$SRC/README.md" "$SRC/CHANGELOG.md" "$SRC/NOTICE.md" "$SRC/VERSION" "$LIB/" 2>/dev/null || true
cp "$SRC/src/etc/schema.tsv" "$LIB/www/schema.tsv" 2>/dev/null || true
cp "$SRC/src/etc/directives.txt" "$LIB/www/directives.txt" 2>/dev/null || true

chmod 755 "$LIB/lib/"*.sh 2>/dev/null || true
chmod 755 "$LIB/cgi/api.cgi" "$LIB/bin/forksmartdnsctl" 2>/dev/null || true
chmod 755 "$LIB/uninstall.sh" 2>/dev/null || true
find "$LIB/www" -type f -name '*.sh' -exec chmod 755 {} \; 2>/dev/null || true
find "$LIB/www" -type d -exec chmod 755 {} \; 2>/dev/null || true
find "$LIB/www" -type f -exec chmod 644 {} \; 2>/dev/null || true
chmod 755 "$LIB/www/cgi-bin/api.cgi" 2>/dev/null || true
chmod 755 "$LIB/cgi/api.cgi" 2>/dev/null || true
chmod 755 "$LIB/bin/forksmartdnsctl" 2>/dev/null || true
ln -sf "$LIB/bin/forksmartdnsctl" "$PREFIX/bin/forksmartdnsctl" 2>/dev/null || true

mkdir -p "$ETC/bin"
cp "$CORE" "$ETC/bin/core.new" || die "copy core failed"
chmod 755 "$ETC/bin/core.new"
mv "$ETC/bin/core.new" "$ETC/bin/core" || die "install core failed"
CORE_BIN="$ETC/bin/core"

cp "$SRC/src/init/forksmartdns.init" "$INIT" || die "copy init failed"
chmod 755 "$INIT"

# --- instance.env -----------------------------------------------------------
(
	umask 077
	{
		echo "# forksmartdns instance — generated by install.sh"
		echo "FSD_VERSION='$VERSION'"
		echo "FSD_UI_PORT=$UI_PORT"
		echo "FSD_UI_BIND='$UI_BIND'"
		echo "FSD_DNS_PORT=$DNS_PORT"
		echo "FSD_DNS_BIND='$DNS_BIND'"
		echo "FSD_UI_INTERNAL_PORT=$INTERNAL_PORT"
		echo "FSD_WEB_SERVER='$WEB_SERVER'"
		echo "FSD_CORE_KIND='$CORE_KIND'"
		echo "FSD_CORE_BIN='$CORE_BIN'"
		echo "FSD_INSTALLED_AT='$(date '+%Y-%m-%d %H:%M:%S')'"
	} >"$ETC/instance.env"
)
chmod 600 "$ETC/instance.env"

# --- config -----------------------------------------------------------------
if [ ! -f "$CONF" ]; then
	say "Создаю конфигурацию ядра"
	sed -e "s|@DNS_BIND@|$DNS_BIND|g" \
		-e "s|@DNS_PORT@|$DNS_PORT|g" \
		-e "s|@UI_INTERNAL_PORT@|$INTERNAL_PORT|g" \
		-e "s|@VAR@|$VAR|g" \
		-e "s|@LOG@|$LOG|g" \
		"$LIB/etc/forksmartdns.conf.in" >"$CONF" || die "config generation failed"
	chmod 600 "$CONF"
else
	say "Сохраняю существующую конфигурацию, обновляю только адрес stats-моста"
	sed -i "s|^ui-listen .*|ui-listen 127.0.0.1:$INTERNAL_PORT|" "$CONF" 2>/dev/null || true
fi

sed -e "s|@WWW@|$LIB/www|g" \
	-e "s|@UI_PORT@|$UI_PORT|g" \
	-e "s|@UI_BIND@|$UI_BIND|g" \
	-e "s|@RUN@|$RUN|g" \
	-e "s|@LOG@|$LOG|g" \
	-e "s|@VAR@|$VAR|g" \
	"$LIB/etc/lighttpd.conf.in" >"$ETC/lighttpd.conf" || die "lighttpd config generation failed"
chmod 600 "$ETC/lighttpd.conf"

# --- authentication ---------------------------------------------------------
if [ "$PASSWORD_STDIN" = "1" ]; then
	if [ -r /dev/tty ]; then
		printf 'Пароль администратора: ' >/dev/tty
		IFS= read -r PASSWORD </dev/tty || true
		printf '\n' >/dev/tty
	elif [ -n "$PASSWORD" ]; then
		:
	else
		die "--password-stdin требует терминал; используйте --password PASS"
	fi
fi
if [ ! -f "$ETC/auth.conf" ]; then
	if [ -n "$PASSWORD" ]; then
		printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" | "$CTL" passwd --stdin || die "не удалось задать пароль"
	else
		_tok=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
		[ -n "$_tok" ] || _tok=$(date +%s$$)
		(
			umask 077
			printf '%s\n' "$_tok" >"$ETC/setup-token"
		)
		chmod 600 "$ETC/setup-token"
	fi
fi

# --- autostart --------------------------------------------------------------
if [ "$NO_AUTOSTART" = "0" ]; then
	"$INIT" enable >/dev/null 2>&1 || warn "не удалось включить автозапуск"
fi

# --- validate ---------------------------------------------------------------
say "Проверка конфигурации"
if ! "$CTL" check "$CONF"; then
	echo "--- последние строки лога ---" >&2
	tail -n 20 "$LOG/forksmartdns.log" 2>/dev/null >&2 || true
	"$INIT" stop >/dev/null 2>&1 || true
	if [ -n "$PRE_CONF" ]; then cp "$PRE_CONF" "$CONF" 2>/dev/null || true; fi
	if [ "$EXISTING" = "0" ]; then
		"$INIT" disable >/dev/null 2>&1 || true
		rm -rf "$ETC" "$LIB" "$VAR" "$LOG" "$RUN" 2>/dev/null || true
		rm -f "$INIT" "$PREFIX/etc/rc.d/S99forksmartdns" "$PREFIX/etc/rc.d/K10forksmartdns" "$PREFIX/bin/forksmartdnsctl" 2>/dev/null || true
		die "конфигурация не прошла проверку; установка отменена (rollback выполнен)"
	fi
	die "конфигурация не прошла проверку; предыдущая конфигурация восстановлена. Логи: $LOG"
fi

# --- start ------------------------------------------------------------------
if [ "$NO_START" = "0" ]; then
	say "Запуск службы"
	if ! "$INIT" start; then
		warn "служба не запустилась"
		[ -f "$LOG/forksmartdns.log" ] && tail -n 20 "$LOG/forksmartdns.log" >&2
		[ -f "$ETC/setup-token" ] && rm -f "$ETC/setup-token"
		exit 1
	fi
	_i=0
	_http=0
	while [ "$_i" -lt 15 ]; do
		if command -v wget >/dev/null 2>&1; then
			wget -q -T 2 -O /dev/null "http://127.0.0.1:$UI_PORT/" 2>/dev/null && { _http=1; break; }
		fi
		sleep 1
		_i=$((_i + 1))
	done
	[ "$_http" = "1" ] || warn "WebUI пока не отвечает на 127.0.0.1:$UI_PORT — проверьте $LOG/web.log"
fi

# --- summary ----------------------------------------------------------------
LAN_IP=$(ip -4 addr show 2>/dev/null | awk '/inet (192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01]))/ { print $2; exit }' | cut -d/ -f1)
[ -n "$LAN_IP" ] || LAN_IP="<IP-роутера>"

echo
echo "forksmartdns $VERSION установлен (ядро: $CORE_KIND, $WEB_SERVER)."
echo
echo "  Панель:        http://$LAN_IP:$UI_PORT/"
echo "  DNS-услышитель: $DNS_BIND:$DNS_PORT (UDP/TCP)"
echo "  Конфигурация:  $CONF"
echo "  Логи:          $LOG/"
echo "  Резервные копии: $VAR/backups/"
echo "  Управление:    $CTL {status|start|stop|restart|check|backup|restore|passwd|diagnose}"
echo
if [ -f "$ETC/setup-token" ]; then
	echo "  Первичная настройка: введите пароль на странице панели."
	echo "  Установочный токен:  $(cat "$ETC/setup-token")"
	echo "  (файл $ETC/setup-token, будет удалён после настройки)"
	echo
fi
if [ -x "$PREFIX/bin/hrdns" ] || [ -x "$PREFIX/sbin/hrdns" ]; then
	echo "  Обнаружена штатная установка hrdns (Hydra Route). Она не изменялась."
	echo "  Наш экземпляр независим: свои каталоги, PID, конфиг, логи и порты."
	echo
fi
echo "  ВАЖНО: это изолированный экземпляр. Он не меняет /opt/etc/HydraRoute/dns,"
echo "  пакет hrdns и его службы. Клиентов нужно направить на порт $DNS_PORT."
echo "  Статус: PRE-RELEASE. Установщик не проходил сертификацию на всех моделях Keenetic;"
echo "  перед использованием на рабочем роутере сделайте резервную копию конфигурации."
echo
