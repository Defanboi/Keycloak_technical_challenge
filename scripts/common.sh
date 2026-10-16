# shellcheck shell=bash
# Общие функции для backup.sh и restore.sh. Отдельно не запускается.
#
# Подключение к PostgreSQL:
#   kubectl (по умолчанию)  pg_dump и pg_restore запускаются внутри основного Pod PostgreSQL
#                           через kubectl exec. Пароль не нужен (локальный сокет).
#   direct                  локальные pg_dump и pg_restore. Адрес и логин из PGHOST, PGPORT,
#                           PGUSER, PGSSLMODE, пароль только из ~/.pgpass или PGPASSWORD.
# Паролей в скриптах нет.
#
# Коды выхода:
#   0 успех             4 база или кластер не найдены
#   1 общая ошибка      5 ошибка pg_dump
#   2 неверные опции    6 файл бэкапа повреждён
#   3 нет утилиты       7 ошибка pg_restore
#                       8 отказ: production или нет подтверждения

NAMESPACE="${PG_NAMESPACE:-keycloak}"
CLUSTER="${PG_CLUSTER:-pg-keycloak}"
DATABASE="${PG_DATABASE:-keycloak}"
MODE="${PG_MODE:-kubectl}"
LOG_FILE="${LOG_FILE:-}"
POD=""

log() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [$1] $2"
  printf '%s\n' "$line" >&2
  if [[ -n "$LOG_FILE" ]]; then printf '%s\n' "$line" >> "$LOG_FILE"; fi
}
die() { log ERROR "$2"; exit "$1"; }
need() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die 3 "не найдена утилита $c"; done; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# Проверка общих параметров и поиск основного сервера кластера
prepare() {
  [[ "$MODE" == kubectl || "$MODE" == direct ]] || die 2 "--mode только kubectl или direct"
  [[ "$DATABASE" =~ ^[A-Za-z0-9_]+$ ]] || die 2 "недопустимое имя базы $DATABASE"
  if [[ "$MODE" == kubectl ]]; then
    need kubectl
    kubectl -n "$NAMESPACE" get cluster.postgresql.cnpg.io "$CLUSTER" >/dev/null 2>&1 \
      || die 4 "кластер $NAMESPACE/$CLUSTER не найден"
    POD="$(kubectl -n "$NAMESPACE" get cluster.postgresql.cnpg.io "$CLUSTER" -o jsonpath='{.status.currentPrimary}')"
    [[ -n "$POD" ]] || die 4 "у кластера $CLUSTER нет основного сервера"
  else
    need pg_dump pg_restore psql vacuumdb
  fi
}

# Выполнить команду в основном Pod (kubectl) или локально (direct)
pg() {
  if [[ "$MODE" == kubectl ]]; then kubectl -n "$NAMESPACE" exec -i "$POD" -c postgres -- "$@"
  else "$@"; fi
}

check_db() {
  pg psql -XAtqw -d "$DATABASE" -c 'select 1' </dev/null >/dev/null 2>&1 \
    || die 4 "нет подключения к базе $DATABASE"
}
