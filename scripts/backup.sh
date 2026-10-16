#!/usr/bin/env bash
# Логический бэкап базы PostgreSQL Keycloak через pg_dump (сжатый формат custom).
# Путь к готовому файлу печатается в stdout, лог пишется в stderr.
#
#   scripts/backup.sh [-n namespace] [-c cluster] [-d database] [-o dir] [-m kubectl|direct] [--log-file file]

# Скрипт использует возможности bash. При запуске через "sh script" (dash) выходим с понятной ошибкой.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "Запускайте через bash: bash $0 ... или ./$0 ..." >&2
  exit 3
fi
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

OUT_DIR="${BACKUP_DIR:-./backups}"

usage() {
  cat <<EOF
Использование: $(basename "$0") [опции]
  -n, --namespace   namespace кластера PostgreSQL   (по умолчанию keycloak)
  -c, --cluster     имя CNPG Cluster                  (по умолчанию pg-keycloak)
  -d, --database    база данных                       (по умолчанию keycloak)
  -o, --output-dir  куда сохранять бэкапы             (по умолчанию ./backups)
  -m, --mode        kubectl или direct                (по умолчанию kubectl)
      --log-file    дополнительно писать лог в файл
Результат: <dir>/<cluster>_<db>_<время UTC>.dump и рядом .sha256
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)  NAMESPACE="$2"; shift 2 ;;
    -c|--cluster)    CLUSTER="$2"; shift 2 ;;
    -d|--database)   DATABASE="$2"; shift 2 ;;
    -o|--output-dir) OUT_DIR="$2"; shift 2 ;;
    -m|--mode)       MODE="$2"; shift 2 ;;
    --log-file)      LOG_FILE="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) usage >&2; die 2 "неизвестная опция $1" ;;
  esac
done
prepare

mkdir -p "$OUT_DIR" || die 1 "не удалось создать $OUT_DIR"
umask 077   # в дампе хэши паролей и секреты клиентов
file="$OUT_DIR/${CLUSTER}_${DATABASE}_$(date -u +%Y%m%dT%H%M%SZ).dump"
tmp="$file.partial"
trap 'rm -f "$tmp"' EXIT
start=$(date +%s)

log INFO "бэкап $NAMESPACE/$CLUSTER база $DATABASE в $file"
check_db
# Полный бэкап базы, включая служебные таблицы Keycloak
pg pg_dump -Fc -w -d "$DATABASE" </dev/null > "$tmp" || die 5 "pg_dump завершился с ошибкой"
[[ -s "$tmp" ]] || die 5 "дамп пустой"

# Проверка: файл читается pg_restore и в нём есть таблицы.
# Строки вида "5163; 1259 16409 TABLE public user_entity keycloak", без "TABLE DATA"
tables="$(pg pg_restore --list < "$tmp" | awk '$4 == "TABLE" && $5 != "DATA"' | wc -l | tr -d ' ')"
[[ "${tables:-0}" -gt 0 ]] || die 6 "в дампе нет ни одной таблицы или он не читается pg_restore"

mv "$tmp" "$file"
trap - EXIT
printf '%s  %s\n' "$(sha256 "$file")" "$(basename "$file")" > "$file.sha256"
log INFO "готово: $(wc -c < "$file" | tr -d ' ') байт, таблиц $tables, за $(( $(date +%s) - start )) с"
printf '%s\n' "$file"
