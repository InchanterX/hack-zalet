#!/usr/bin/env bash
# Сборка модели одной командой: core -> mart -> проверки контрольных цифр.
#
#   bash izotov/build.sh              raw уже загружен (scripts/setup.sh)
#   bash izotov/build.sh --load-raw   сначала загрузить raw через psql, без Python
#
# Любая ошибка — расхождение сверки, «сирота» в связях, не та контрольная
# цифра — останавливает сборку с ненулевым кодом.

set -euo pipefail
cd "$(dirname "$0")/.."

psql_run() {
    docker compose exec -T postgres psql -U hack -d marketplace -v ON_ERROR_STOP=1 -q "$@"
}

step() { printf '\n==> %s\n' "$1"; }

if [[ "${1:-}" == "--load-raw" ]]; then
    step "Загружаю raw из data/*.csv"
    psql_run < izotov/load_raw_psql.sql
fi

rows=$(psql_run -tA -c "SELECT count(*) FROM raw.orders")
if [[ "$rows" == "0" ]]; then
    echo "raw пуст. Запустите scripts/setup.sh или bash izotov/build.sh --load-raw" >&2
    exit 1
fi

step "Собираю core"
psql_run < izotov/core.sql

step "Собираю mart"
psql_run < izotov/mart.sql

step "Проверяю контрольные цифры"
psql_run < izotov/checks.sql

step "Готово"
