#!/bin/sh
# forksmartdns WebUI — uninstaller.
#
#   wget -qO- https://raw.githubusercontent.com/alexbaryshef-dot/smartdns/main/webui/uninstall.sh | sh
#
# Removes only files created by this project. The stock Hydra Route hrdns
# installation, its package, configs and services are never touched.
#
# Options: --prefix DIR | --keep-config | --keep-logs | --force | --help

set -u

PREFIX=${FORKSMDNS_PREFIX:-/opt}
KEEP_CONFIG=0
KEEP_LOGS=0
FORCE=0

say()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'forksmartdns: %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<'EOF'
forksmartdns WebUI — удаление.

  --prefix DIR     префикс установки (по умолчанию /opt)
  --keep-config    сохранить конфигурацию, списки и резервные копии
  --keep-logs      сохранить логи
  --force          удалять даже если служба не остановилась
  --help

Удаляются только каталоги/файлы этого проекта:
  /opt/etc/forksmartdns
  /opt/share/forksmartdns
  /opt/var/lib/forksmartdns
  /opt/var/log/forksmartdns
  /opt/var/run/forksmartdns
  /opt/etc/init.d/forksmartdns, rc.d-ссылки, /opt/bin/forksmartdnsctl
Штатный hrdns (/opt/etc/HydraRoute/dns, пакет hrdns) не затрагивается.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--prefix) PREFIX=${2:?}; shift 2 ;;
		--keep-config) KEEP_CONFIG=1; shift ;;
		--keep-logs) KEEP_LOGS=1; shift ;;
		--force) FORCE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown option: $1" ;;
	esac
done

[ "$(id -u 2>/dev/null || echo 1)" = "0" ] || [ "${FORKSMDNS_ALLOW_NONROOT:-0}" = "1" ] || die "запускайте под root"
PREFIX=$(printf '%s' "$PREFIX" | tr '\\' '/')
case "$PREFIX" in *' '*|*"'"*) die "некорректный prefix" ;; esac

ETC="$PREFIX/etc/forksmartdns"
LIB="$PREFIX/share/forksmartdns"
VAR="$PREFIX/var/lib/forksmartdns"
LOG="$PREFIX/var/log/forksmartdns"
RUN="$PREFIX/var/run/forksmartdns"
INIT="$PREFIX/etc/init.d/forksmartdns"
CTL_LINK="$PREFIX/bin/forksmartdnsctl"

if [ ! -d "$ETC" ] && [ ! -d "$LIB" ] && [ ! -f "$INIT" ]; then
	echo "forksmartdns не установлен в $PREFIX — нечего удалять."
	exit 0
fi

if [ -x "$INIT" ]; then
	say "Остановка службы"
	"$INIT" stop >/dev/null 2>&1 || true
	"$INIT" disable >/dev/null 2>&1 || true
fi

# Stop anything that still holds our pid files.
for _pf in "$RUN/forksmartdns.pid" "$RUN/web.pid"; do
	[ -r "$_pf" ] || continue
	_p=$(cat "$_pf" 2>/dev/null | tr -dc '0-9')
	[ -n "$_p" ] || continue
	if kill -0 "$_p" 2>/dev/null; then
		if [ "$FORCE" = "1" ]; then
			kill -9 "$_p" 2>/dev/null || true
		else
			warn "процесс $_p всё ещё работает; повторите с --force, если это наш процесс"
		fi
	fi
done

say "Удаление файлов"
rm -f "$INIT" "$PREFIX/etc/rc.d/S99forksmartdns" "$PREFIX/etc/rc.d/K10forksmartdns" 2>/dev/null || true
if [ -L "$CTL_LINK" ]; then
	_target=$(readlink "$CTL_LINK" 2>/dev/null || true)
	case "$_target" in
		*share/forksmartdns*) rm -f "$CTL_LINK" ;;
		*) warn "симлинк $CTL_LINK указывает не на forksmartdns — оставлен" ;;
	esac
elif [ -f "$CTL_LINK" ]; then
	case "$(head -n 1 "$CTL_LINK" 2>/dev/null)" in
		*forksmartdns*) rm -f "$CTL_LINK" ;;
	esac
fi

_rclocal="$PREFIX/etc/rc.local"
if [ -f "$_rclocal" ] && grep -q 'init.d/forksmartdns' "$_rclocal" 2>/dev/null; then
	_tmp="$_rclocal.tmp.$$"
	grep -v 'init.d/forksmartdns' "$_rclocal" >"$_tmp" 2>/dev/null || true
	mv "$_tmp" "$_rclocal" 2>/dev/null || rm -f "$_tmp"
fi

rm -rf "$LIB" "$RUN" 2>/dev/null || true
if [ "$KEEP_CONFIG" = "1" ]; then
	say "Конфигурация и резервные копии сохранены: $ETC, $VAR"
	rm -rf "$RUN" 2>/dev/null || true
else
	rm -rf "$ETC" "$VAR" 2>/dev/null || true
fi
if [ "$KEEP_LOGS" = "1" ]; then
	say "Логи сохранены: $LOG"
else
	rm -rf "$LOG" 2>/dev/null || true
fi

say "Готово. Штатный hrdns и его службы не изменялись."
if [ "$KEEP_CONFIG" = "1" ]; then
	echo "Сохранено: $ETC (и $VAR)"
fi
echo "Если lighttpd ставился только для этого проекта, его можно удалить:"
echo "  opkg remove lighttpd lighttpd-mod-cgi"
