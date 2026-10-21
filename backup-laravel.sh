#!/usr/bin/env bash
# Uso: bash backup-laravel.sh [/var/www] [/var/backups/laravel]
# Requiere Bash 4+, zip y mysqldump.
set -Eeuo pipefail
umask 077

ROOT=${1:-/var/www}
DEST=${2:-/var/backups/laravel}
command -v zip >/dev/null || { echo 'Falta zip.' >&2; exit 1; }
command -v mysqldump >/dev/null || { echo 'Falta mysqldump.' >&2; exit 1; }
ROOT=$(cd -- "$ROOT" && pwd -P)
mkdir -p -- "$DEST"
DEST=$(cd -- "$DEST" && pwd -P)
case "$DEST/" in "$ROOT/"*) echo 'Guarda los backups fuera de /var/www.' >&2; exit 1;; esac

# Leer valores literales del .env sin ejecutar su contenido.
trim() {
    REPLY=$1
    REPLY="${REPLY#"${REPLY%%[![:space:]]*}"}"
    REPLY="${REPLY%"${REPLY##*[![:space:]]}"}"
}
read_env() {
    local line key value quote rest
    declare -gA ENV=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        trim "$line"; line=$REPLY
        [[ -z "$line" || "$line" == \#* ]] && continue
        line=${line#export }
        [[ "$line" == *=* ]] || continue
        trim "${line%%=*}"; key=$REPLY
        case "$key" in DB_CONNECTION|DB_HOST|DB_PORT|DB_DATABASE|DB_USERNAME|DB_PASSWORD|DB_SOCKET|DB_URL|DATABASE_URL) ;; *) continue;; esac
        trim "${line#*=}"; value=$REPLY
        if [[ "$value" == \"* || "$value" == \'* ]]; then
            quote=${value:0:1}
            # Valores literales de una línea. Fallar en formatos ambiguos.
            rest=${value:1}
            [[ "$rest" == *"$quote"* ]] || { echo "Comillas inválidas en $key" >&2; return 1; }
            value=${rest%%"$quote"*}
            trim "${rest#*"$quote"}"
            [[ -z "$REPLY" || "$REPLY" == \#* ]] || { echo "Formato no compatible en $key" >&2; return 1; }
            [[ "$quote" != '"' || "$value" != *\\* ]] || { echo "Escapes no compatibles en $key; usa comillas simples para valores literales." >&2; return 1; }
        else
            if [[ "$value" =~ ^(.*[^[:space:]])[[:space:]]+# ]]; then value=${BASH_REMATCH[1]}; fi
            [[ "$value" != \#* ]] || value=''
            case "$value" in null|'(null)'|empty|'(empty)') value='';; esac
        fi
        [[ "$value" != *'${'* ]] || { echo "Variables interpoladas no compatibles en $key" >&2; return 1; }
        ENV["$key"]=$value
    done < "$1"
}
cnf_value() {
    local value=$2
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s="%s"\n' "$1" "$value"
}

backup_project() (
    set -Eeuo pipefail
    project=$1
    name=${project##*/}
    temp=$(mktemp -d "$DEST/.laravel-backup.XXXXXXXX")
    trap 'rm -rf -- "$temp"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    echo "Respaldando: $name"
    read_env "$project/.env"
    [[ -z ${ENV[DB_URL]:-}${ENV[DATABASE_URL]:-} ]] || { echo 'DB_URL/DATABASE_URL requiere adaptar el script.' >&2; exit 1; }
    case "${ENV[DB_CONNECTION]:-}" in mysql|mariadb) ;; *) echo 'Solo se admite MySQL/MariaDB.' >&2; exit 1;; esac
    [[ -n ${ENV[DB_DATABASE]:-} && -n ${ENV[DB_USERNAME]:-} ]] || { echo 'Falta DB_DATABASE o DB_USERNAME.' >&2; exit 1; }
    {
        printf '[client]\n'
        cnf_value host "${ENV[DB_HOST]:-127.0.0.1}"
        cnf_value port "${ENV[DB_PORT]:-3306}"
        cnf_value user "${ENV[DB_USERNAME]}"
        cnf_value password "${ENV[DB_PASSWORD]:-}"
        [[ -z ${ENV[DB_SOCKET]:-} ]] || cnf_value socket "${ENV[DB_SOCKET]}"
        :
    } > "$temp/client.cnf"
    mysqldump --defaults-extra-file="$temp/client.cnf" \
        --single-transaction --quick --routines --triggers --events \
        --databases "${ENV[DB_DATABASE]}" > "$temp/database.sql"
    rm -f -- "$temp/client.cnf"
    archive="$temp/backup.zip"
    # Comprimir directamente, sin copiar primero el proyecto.
    # Excluir carpetas vendor tanto en la raíz como en subdirectorios.
    (cd -- "$project" && zip -q -r -y "$archive" . \
        -x 'vendor/*' '*/vendor/*')
    (cd -- "$temp" && zip -q "$archive" database.sql)
    zip -T "$archive" >/dev/null
    final="$DEST/${name}_$(date +%Y%m%d_%H%M%S)_${temp##*.}.zip"
    mv -- "$archive" "$final"
    echo "OK: $final"
)

count=0
failed=0
shopt -s nullglob dotglob
for project in "$ROOT"/*; do
    [[ -d "$project" && -f "$project/artisan" && -f "$project/.env" ]] || continue
    count=$((count + 1))
    set +e
    (set -e; backup_project "$project")
    result=$?
    set -e
    if (( result != 0 )); then
        echo "ERROR: falló ${project##*/}; no se publicó su ZIP." >&2
        failed=$((failed + 1))
    fi
done
echo "Proyectos: $count | Correctos: $((count - failed)) | Fallidos: $failed"
(( count > 0 && failed == 0 ))
