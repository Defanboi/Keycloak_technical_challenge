#!/usr/bin/env bash
# Восстановление базы PostgreSQL Keycloak из бэкапа через pg_restore.
# ВНИМАНИЕ: перезаписывает данные целевой базы. Для проверки бэкапа восстанавливайте
# в отдельную тестовую базу (см. README).
#
#   scripts/restore.sh -f <файл> [-n namespace] [-c cluster] [-d database] [-m kubectl|direct]
#                      [--confirm cluster/database] [--app deployment/keycloak|none] [--no-safety-backup]

# Скрипт использует возможности bash. При запуске через "sh script" (dash) выходим с понятной ошибкой.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "Запускайте через bash: bash $0 ... или ./$0 ..." >&2
  exit 3
fi
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

FILE=""
CONFIRM=""
APP="deployment/keycloak"
SAFETY_BACKUP=1

usage() {
  cat <<EOF
Использование: $(basename "$0") -f FILE [опции]
  -f, --file        файл бэкапа (.dump)                                       [обязательно]
  -n, --namespace   namespace кластера PostgreSQL     (по умолчанию keycloak)
  -c, --cluster     имя CNPG Cluster                    (по умолчанию pg-keycloak)
  -d, --database    целевая база                        (по умолчанию keycloak)
  -m, --mode        kubectl или direct                  (по умолчанию kubectl)
      --confirm     подтверждение без вопроса, строка "кластер/база"
      --app         что остановить на время restore     (по умолчанию deployment/keycloak, none: ничего)
      --no-safety-backup  не делать страховочный бэкап перед restore
      --log-file    дополнительно писать лог в файл
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)          FILE="$2"; shift 2 ;;
    -n|--namespace)     NAMESPACE="$2"; shift 2 ;;
    -c|--cluster)       CLUSTER="$2"; shift 2 ;;
    -d|--database)      DATABASE="$2"; shift 2 ;;
    -m|--mode)          MODE="$2"; shift 2 ;;
    --confirm)          CONFIRM="$2"; shift 2 ;;
    --app)              APP="$2"; shift 2 ;;
    --no-safety-backup) SAFETY_BACKUP=0; shift ;;
    --log-file)         LOG_FILE="$2"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *) usage >&2; die 2 "неизвестная опция $1" ;;
  esac
done
[[ -n "$FILE" ]] || { usage >&2; die 2 "не указан файл: -f"; }
[[ -s "$FILE" ]] || die 2 "файл $FILE не найден или пустой"
prepare

target="$CLUSTER/$DATABASE"
ctx="" env_label="" have_kubectl=0
command -v kubectl >/dev/null 2>&1 && have_kubectl=1
[[ $have_kubectl -eq 1 || "$APP" == none ]] || die 3 "нужен kubectl, чтобы остановить $APP (или --app none)"

# 1. Защита от production
if [[ $have_kubectl -eq 1 ]]; then
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  env_label="$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.environment}' 2>/dev/null || true)"
fi
if [[ "$env_label" == production || "$ctx" == *prod* || "${TARGET_ENV:-}" == production || "${PGHOST:-}" == *prod* ]]; then
  [[ "${ALLOW_PRODUCTION_RESTORE:-}" == yes ]] \
    || die 8 "похоже на production (context=$ctx, environment=$env_label). Для запуска нужно ALLOW_PRODUCTION_RESTORE=yes"
  log WARN "restore на production разрешён через ALLOW_PRODUCTION_RESTORE=yes"
fi

# 2. Проверка файла до любых изменений
if [[ -f "$FILE.sha256" ]]; then
  [[ "$(awk '{print $1}' "$FILE.sha256")" == "$(sha256 "$FILE")" ]] || die 6 "контрольная сумма $FILE не совпадает"
  log INFO "контрольная сумма совпадает"
else
  log WARN "нет файла $FILE.sha256, контрольная сумма не проверена"
fi
pg pg_restore --list < "$FILE" >/dev/null || die 6 "файл не читается pg_restore"
check_db

# 3. Подтверждение
if [[ -z "$CONFIRM" ]]; then
  [[ -t 0 ]] || die 8 "запуск без терминала: добавьте --confirm $target"
  printf 'Restore ПЕРЕЗАПИШЕТ базу %s (context=%s). Введите "%s": ' "$DATABASE" "$ctx" "$target" >&2
  read -r CONFIRM
fi
[[ "$CONFIRM" == "$target" ]] || die 8 "подтверждение '$CONFIRM' не совпадает с '$target'"

# 4. Страховочный бэкап текущей базы
if [[ $SAFETY_BACKUP -eq 1 ]]; then
  log INFO "страховочный бэкап перед restore"
  safety_dir="$(dirname "$FILE")/pre-restore"
  "$SCRIPT_DIR/backup.sh" -n "$NAMESPACE" -c "$CLUSTER" -d "$DATABASE" -m "$MODE" -o "$safety_dir" >/dev/null \
    || die 5 "страховочный бэкап не получился, restore отменён"
  log INFO "страховочный бэкап в $safety_dir"
fi

# 5. Остановка Keycloak, чтобы он не писал в базу и не держал старые данные в кэше
replicas=""
scale_back() {
  if [[ -n "$replicas" ]]; then
    log INFO "возвращаю $APP: $replicas реплик"
    kubectl -n "$NAMESPACE" scale "$APP" --replicas="$replicas" >/dev/null || log ERROR "верните реплики $APP вручную!"
  fi
}
if [[ "$APP" != none ]] && kubectl -n "$NAMESPACE" get "$APP" >/dev/null 2>&1; then
  replicas="$(kubectl -n "$NAMESPACE" get "$APP" -o jsonpath='{.spec.replicas}')"
  trap scale_back EXIT
  log INFO "останавливаю $APP"
  kubectl -n "$NAMESPACE" scale "$APP" --replicas=0 >/dev/null
  kubectl -n "$NAMESPACE" wait --for=delete pod -l app=keycloak --timeout=180s >/dev/null 2>&1 || true
elif [[ "$APP" == none ]]; then
  log WARN "--app none: убедитесь, что приложение не пишет в базу"
fi

# 6. Восстановление одной транзакцией: при ошибке база остаётся как была
opts=(--clean --if-exists --single-transaction --exit-on-error --no-password -d "$DATABASE")
[[ "$MODE" == direct ]] && opts+=(--no-owner --no-privileges)
start=$(date +%s)
log INFO "pg_restore в базу $DATABASE"
pg pg_restore "${opts[@]}" < "$FILE" || die 7 "pg_restore завершился с ошибкой, транзакция отменена, данные не изменены"

# jgroups_ping: служебная таблица Keycloak со списком живых подов его кластера.
# В бэкапе она лежит целиком, но после restore эти записи указывают на давно удалённые поды:
# Keycloak 20 секунд пытался бы к ним подключиться и ловил split-brain. Очищаем, пока Keycloak остановлен.
# Таблицу ищем в любой схеме; если её нет (не база Keycloak или другая версия), шаг пропускается.
jg_tables="$(pg psql -XAtqw -d "$DATABASE" -c \
  "select format('%I.%I', schemaname, tablename) from pg_tables where lower(tablename) = 'jgroups_ping'" </dev/null)" \
  || { log WARN "не удалось найти jgroups_ping, очистка пропущена"; jg_tables=""; }
if [[ -z "$jg_tables" ]]; then
  log INFO "таблицы jgroups_ping нет, очищать нечего"
else
  while read -r jg_table; do
    if pg psql -XAtqw -v ON_ERROR_STOP=1 -d "$DATABASE" -c "TRUNCATE TABLE $jg_table" </dev/null >/dev/null; then
      log INFO "TRUNCATE TABLE $jg_table выполнен"
    else
      log WARN "не удалось очистить $jg_table, Keycloak может стартовать дольше обычного"
    fi
  done <<< "$jg_tables"
fi

pg env PGOPTIONS="-c client_min_messages=error" vacuumdb --analyze-only -q -w -d "$DATABASE" </dev/null || log WARN "ANALYZE не выполнен"
log INFO "restore занял $(( $(date +%s) - start )) с"

# 7. Запуск Keycloak
if [[ -n "$replicas" ]]; then
  scale_back; replicas=""; trap - EXIT
  kubectl -n "$NAMESPACE" rollout status "$APP" --timeout=600s >/dev/null || die 1 "$APP не поднялся после restore"
fi
log INFO "готово: $target восстановлена из $FILE"
