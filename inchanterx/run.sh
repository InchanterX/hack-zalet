#!/usr/bin/env bash
# =====================================================================
#  Единая точка входа решения (PLAN.md, 6.4, 6.5, 6.15).
#
#      ./run.sh                  полный прогон: up → data → raw → build
#      ./run.sh --reset          то же с чистой базы (DROP DATABASE только нашей)
#      ./run.sh <стадия> [...]   только перечисленные стадии: up data raw build
#      ./run.sh --force-raw      перезалить raw, даже если отпечаток не изменился
#      ./run.sh psql [аргументы] psql в нашу базу
#      ./run.sh preflight        только проверить окружение
#
#  На хосте выполняются preflight и up. Остальные стадии — в контейнере
#  pipeline: тот же скрипт перезапускает себя с --inside <стадия>.
#  Имя решения и базы вычисляется из имени папки (и .env), не хардкодится.
# =====================================================================

set -Eeuo pipefail

SOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SOL_DIR")"
SOLUTION="$(basename "$SOL_DIR")"

# Коды выхода — только из таблицы PLAN.md, 6.15.
readonly E_USAGE=2 E_ENV=10 E_UP=20 E_DATA=30 E_RAW=40 E_BUILD=50 E_CHECK=55 E_INT=130

# Имена баз, которые решение не имеет права занять или удалить.
readonly RESERVED_DBS=" postgres template0 template1 marketplace hack "

STAGE=init          # имя текущей стадии — для сообщений об ошибках
STAGE_CODE=$E_ENV   # код выхода при неожиданном сбое внутри стадии
LOG=""
RUN_NAME=""         # имя контейнера текущей стадии (для остановки по Ctrl+C)

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> [%s] %s\n' "$STAGE" "$*"; }

# die <код> <что случилось> [<строки: где / что делать>...]
die() {
  local code=$1 what=$2 line
  shift 2
  {
    printf '\nОШИБКА [%s]: %s\n' "$STAGE" "$what"
    for line in "$@"; do printf '  %s\n' "$line"; done
  } >&2
  exit "$code"
}

# Сбой команды, который скрипт не обработал явно, — ошибка обвязки.
on_err() {
  local rc=$1 line=$2
  trap - ERR
  printf '\nОШИБКА [%s]: неожиданный сбой команды (код %s) в run.sh, строка %s.\n' "$STAGE" "$rc" "$line" >&2
  printf '  Это ошибка обвязки, а не данных. Полный лог: %s\n' "${LOG:-нет (лог не вёлся)}" >&2
  exit "$STAGE_CODE"
}
trap 'on_err $? $LINENO' ERR

usage() {
  sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^#  \{0,1\}//'
}

# ---------------------------------------------------------------------
#  Хост: журнал, окружение, compose
# ---------------------------------------------------------------------

# Весь вывод — в logs/run-<время>.log; в конце копия в logs/latest.log
# (не симлинк: в Git Bash симлинк по умолчанию создаётся копией, PLAN 6.3).
start_log() {
  mkdir -p "$SOL_DIR/logs"
  LOG="$SOL_DIR/logs/run-$(date +%Y%m%d-%H%M%S).log"
  exec 3>&1 4>&2
  exec > >(tee -a "$LOG") 2>&1
  TEE_PID=$!
  trap finish_log EXIT
}

finish_log() {
  local rc=$?
  set +e
  # Закрываем трубу в tee и ждём, пока он допишет файл, иначе копия обрежется.
  exec 1>&3 2>&4 3>&- 4>&-
  wait "$TEE_PID"
  cp "$LOG" "$SOL_DIR/logs/latest.log"
  exit "$rc"
}

# Ctrl+C / SIGTERM на хосте. На Windows сигнал может не дойти через docker.exe
# до контейнера, поэтому контейнер стадии останавливаем явно (PLAN 6.15).
on_interrupt() {
  trap - INT TERM
  printf '\nПрервано на стадии %s.\n' "$STAGE" >&2
  if [ -n "$RUN_NAME" ]; then
    if docker stop -t 10 "$RUN_NAME" >/dev/null; then
      printf '  Контейнер стадии %s остановлен, транзакция в базе откатывается.\n' "$RUN_NAME" >&2
    else
      printf '  Контейнер стадии %s уже завершился.\n' "$RUN_NAME" >&2
    fi
  fi
  exit "$E_INT"
}

load_env() {
  local env_file="$SOL_DIR/.env" key value
  if [ ! -f "$env_file" ]; then
    cp "$SOL_DIR/.env.example" "$env_file"
    say "    создан .env из .env.example"
  fi
  # .env читаем, а не исполняем: в нём только известные ключи.
  while IFS='=' read -r key value || [ -n "$key" ]; do
    key="${key//[[:space:]]/}"
    value="${value%$'\r'}"
    case "$key" in
      ''|\#*) continue ;;
      SOLUTION_DB|ANALYST_PASSWORD|UPSTREAM_URL) printf -v "$key" '%s' "$value" ;;
      *) die "$E_ENV" "неизвестный ключ «$key» в .env" \
             "Где: $env_file" \
             "Что делать: допустимы SOLUTION_DB, ANALYST_PASSWORD, UPSTREAM_URL (см. .env.example)." ;;
    esac
  done < "$env_file"
  SOLUTION_DB="${SOLUTION_DB:-$SOLUTION}"
  ANALYST_PASSWORD="${ANALYST_PASSWORD:-}"
}

preflight() {
  STAGE=preflight STAGE_CODE=$E_ENV
  step "проверяю окружение"

  command -v docker >/dev/null \
    || die "$E_ENV" "команда docker не найдена" "Что делать: установите Docker Desktop или Docker Engine с плагином compose."
  local out
  out=$(docker info --format '{{.ServerVersion}}' 2>&1) \
    || die "$E_ENV" "Docker установлен, но демон не отвечает" "$out" "Что делать: запустите Docker Desktop и дождитесь готовности."
  local compose_ver
  compose_ver=$(docker compose version --short 2>&1) \
    || die "$E_ENV" "нет плагина docker compose v2" "$compose_ver" "Что делать: обновите Docker Desktop / установите docker-compose-plugin."
  case "$compose_ver" in
    v2.*|2.*) ;;
    *) die "$E_ENV" "нужен docker compose v2, найден $compose_ver" "Что делать: обновите Docker." ;;
  esac
  command -v git >/dev/null || die "$E_ENV" "команда git не найдена" "Что делать: установите git."
  say "    docker $out, compose $compose_ver"

  local f
  for f in docker-compose.yml scripts/load_raw.py scripts/download_data.sh scripts/init/02_raw_ddl.sql; do
    [ -f "$ROOT/$f" ] || die "$E_ENV" "не найден файл организаторов ../$f" \
      "Где: корень форка $ROOT" \
      "Что делать: папка решения должна лежать прямо в корне форка организаторов."
  done

  # CRLF в скриптах организаторов ломает bash в Linux-контейнере (PLAN 6.3).
  # Символ CR ищет tr: литерал $'\r' внутри $(...) Git Bash превращает
  # в пустой шаблон, и grep совпадает с любым файлом.
  local crlf=""
  for f in "$ROOT"/scripts/*.sh "$ROOT"/scripts/*.py; do
    [ "$(tr -cd '\r' < "$f" | wc -c)" -eq 0 ] || crlf="$crlf ../scripts/$(basename "$f")"
  done
  if [ -n "$crlf" ]; then
    die "$E_ENV" "скрипты организаторов выгружены с окончаниями строк CRLF" \
      "Где:$crlf" \
      "Что делать (из корня форка; файлы организаторов при этом не меняются):" \
      "  git config core.autocrlf input" \
      "  rm scripts/*.sh scripts/load_raw.py scripts/init/*.sql && git checkout -- scripts"
  fi

  # Имя папки — это имя базы, префикс роли и часть тега образа (PLAN 6.1 п. 5).
  [[ "$SOLUTION" =~ ^[a-z][a-z0-9_]*$ ]] \
    || die "$E_ENV" "недопустимое имя папки решения: «$SOLUTION»" \
           "Что делать: имя должно соответствовать ^[a-z][a-z0-9_]*\$ (латиница в нижнем регистре, цифры, _)."

  load_env
  [[ "$SOLUTION_DB" =~ ^[a-z][a-z0-9_]*$ ]] \
    || die "$E_ENV" "недопустимое имя базы SOLUTION_DB=«$SOLUTION_DB»" "Где: $SOL_DIR/.env"
  case "$RESERVED_DBS" in
    *" $SOLUTION_DB "*) die "$E_ENV" "база «$SOLUTION_DB» зарезервирована, решение не может её занимать" \
                          "Где: $SOL_DIR/.env" "Что делать: оставьте SOLUTION_DB пустым (= имя папки)." ;;
  esac

  # Коммит считаем на хосте: git в контейнере споткнулся бы о safe.directory
  # и на Windows видел бы все файлы изменёнными из-за CRLF (PLAN 6.8).
  GIT_COMMIT=unknown
  if GIT_COMMIT=$(git -C "$SOL_DIR" rev-parse --short HEAD 2>/dev/null); then
    [ -z "$(git -C "$SOL_DIR" status --porcelain -- .)" ] || GIT_COMMIT="$GIT_COMMIT-dirty"
  else
    GIT_COMMIT=unknown
  fi

  # Docker Desktop (Windows) не понимает пути MSYS вида /d/...: корень передаём
  # в смешанной форме D:/..., а автоконвертацию аргументов отключаем (PLAN 6.3).
  ROOT_HOST="$ROOT"
  if command -v cygpath >/dev/null; then
    ROOT_HOST="$(cygpath -m "$ROOT")"
    export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
  fi
  # uid хоста нужен только на Linux; на Docker Desktop владелец файлов не важен.
  if [ "$(uname -s)" = Linux ]; then
    HOST_UID=$(id -u) HOST_GID=$(id -g)
    export HOST_UID HOST_GID
  fi

  export SOLUTION SOLUTION_DB GIT_COMMIT ANALYST_PASSWORD
  export SOLUTION_DIR="$SOLUTION"
  say "    решение: $SOLUTION, база: $SOLUTION_DB, коммит: $GIT_COMMIT"
}

compose() {
  docker compose --project-directory "$ROOT_HOST" \
    -f "$ROOT_HOST/docker-compose.yml" -f "$ROOT_HOST/$SOLUTION/compose.pipeline.yml" "$@"
}

stage_up() {
  STAGE=up STAGE_CODE=$E_UP
  step "образ pipeline (capibara-pipeline-$SOLUTION)"
  compose build -q pipeline \
    || die "$E_UP" "не удалось собрать образ pipeline" \
           "Где: $SOL_DIR/tools/Dockerfile" "Что делать: смотрите вывод сборки выше; частая причина — нет сети для apk."

  step "PostgreSQL организаторов (сервис postgres, конфигурация не меняется)"
  local cid health=""
  cid=$(compose ps -q postgres)
  [ -z "$cid" ] || health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid")
  if [ "$health" = healthy ]; then
    say "    контейнер уже работает (healthy), пропуск"
    return 0
  fi
  compose up -d --wait --wait-timeout 60 postgres \
    || die "$E_UP" "PostgreSQL не поднялся за 60 с" \
           "Где: сервис postgres из ../docker-compose.yml (контейнер hack_postgres)" \
           "Что делать: посмотрите логи (из корня форка): docker compose logs postgres" \
           "Если имя hack_postgres занято контейнером из другой папки — остановите его или работайте из той папки."
  say "    контейнер поднят и healthy"
}

# psql в нашу базу. TTY — только если и stdin, и stdout — терминал
# (в mintty без winpty docker TTY не работает, PLAN 6.3).
stage_psql() {
  local tty=(-T)
  if [ -t 0 ] && [ -t 1 ]; then tty=(); fi
  export PGAPPNAME="run.sh:psql:${USER:-${USERNAME:-user}}@$(hostname)"
  compose run --rm "${tty[@]}" pipeline psql -X "${PSQL_ARGS[@]}"
}

# Запуск стадии в контейнере pipeline. Код выхода — код стадии.
pipeline_run() {
  local st=$1 rc=0
  shift
  RUN_NAME="$SOLUTION-run-$st-$$"
  export PGAPPNAME="run.sh:$st:${USER:-${USERNAME:-user}}@$(hostname)"
  compose run --rm -T --name "$RUN_NAME" pipeline bash ./run.sh --inside "$st" "$@" || rc=$?
  RUN_NAME=""
  return "$rc"
}

run_host_stage() {
  local st=$1 rc=0 started=$SECONDS
  case "$st" in
    up) stage_up ;;
    data|raw|build)
      STAGE=$st
      pipeline_run "$st" || rc=$?
      case "$rc" in
        0) ;;
        "$E_USAGE"|"$E_UP"|"$E_DATA"|"$E_RAW"|"$E_BUILD"|"$E_CHECK"|"$E_INT")
          printf '\nСтадия %s завершилась с кодом %s. Полный лог: %s\n' "$st" "$rc" "$LOG" >&2
          exit "$rc" ;;
        *)
          die "$E_UP" "контейнер pipeline не запустился или завершился аварийно (код $rc)" \
              "Где: docker compose run pipeline, стадия $st" \
              "Что делать: смотрите вывод выше; проверьте, что Docker работает и образ собирается (./run.sh up)." ;;
      esac ;;
  esac
  say "    стадия $st: $((SECONDS - started)) с"
}

# ---------------------------------------------------------------------
#  Контейнер pipeline: стадии data, raw, build
# ---------------------------------------------------------------------

inside() {
  STAGE=${1:?}
  shift
  trap 'die "$E_INT" "прервано сигналом"' INT TERM
  case "$STAGE" in
    data)  STAGE_CODE=$E_DATA ;;
    raw)   STAGE_CODE=$E_RAW ;;
    build) STAGE_CODE=$E_BUILD ;;
    *) die "$E_USAGE" "неизвестная стадия для контейнера: $STAGE" ;;
  esac
  declare -F "stage_$STAGE" >/dev/null \
    || die "$E_USAGE" "стадия $STAGE ещё не реализована" "Что делать: см. PLAN.md, раздел 9."
  "stage_$STAGE" "$@"
}

# data: CSV в общей ../data скачивает скрипт организаторов; наша забота —
# знать, на каких именно файлах собрана модель (PLAN 6.6).
stage_data() {
  local sums="$SOL_DIR/data.sha256" dir="$ROOT/data" report bad
  # Быстрая проба для пропуска стадии; при неудаче ниже идёт полная проверка
  # с выводом всех расхождений, поэтому вывод пробы не нужен.
  if [ -d "$dir" ] && (cd "$dir" && sha256sum --status -c "$sums" 2>/dev/null); then
    step "все файлы совпали с data.sha256, скачивание не нужно"
    return 0
  fi

  step "скачиваю недостающие файлы скриптом организаторов (../scripts/download_data.sh)"
  bash "$ROOT/scripts/download_data.sh" \
    || die "$E_DATA" "скрипт скачивания организаторов завершился с ошибкой" \
           "Где: ../scripts/download_data.sh, источник raw.githubusercontent.com/olist" \
           "Что делать: проверьте сеть и повторите ./run.sh data."

  step "сверяю хэши с data.sha256"
  if ! report=$(cd "$dir" && sha256sum -c "$sums" 2>&1); then
    bad=$(printf '%s\n' "$report" | grep -v ': OK$')
    die "$E_DATA" "файлы в ../data не совпадают с data.sha256" \
      "$bad" \
      "Где: ../data (относительно папки решения)" \
      "Что делать: недокачанный файл удалите и повторите ./run.sh data (скрипт организаторов пропускает любой непустой файл)." \
      "Если организаторы сознательно заменили данные, решение принимает команда (PLAN 6.6, --accept-new — этап A2)."
  fi
  printf '%s\n' "$report" | sed 's/^/    /'
}

# Ожидание базы в соседнем контейнере (до 60 с).
wait_db() {
  local i
  for i in $(seq 60); do
    pg_isready -q && return 0
    sleep 1
  done
  die "$E_UP" "база $PGHOST:$PGPORT не отвечает 60 с" \
    "Что делать: проверьте контейнер (из корня форка): docker compose ps; docker compose logs postgres"
}

# psql_or_die <код> <что делаем> <аргументы psql...>
# Код psql 2 (потеряно соединение) → 20, остальные ошибки → <код> (PLAN 6.15).
psql_or_die() {
  local code=$1 what=$2 rc=0
  shift 2
  psql -X -q -v ON_ERROR_STOP=1 "$@" || rc=$?
  case "$rc" in
    0) ;;
    2) die "$E_UP" "соединение с базой потеряно: $what" \
           "Что делать: проверьте контейнер (из корня форка): docker compose ps" ;;
    *) die "$code" "$what: ошибка psql (код $rc), сообщение выше" ;;
  esac
}

# Отпечаток raw = хэш эталонных хэшей CSV, загрузчика и DDL организаторов
# и наших патчей inject/ (PLAN 6.6). Пути — относительно папки решения.
raw_fingerprint() {
  (
    cd "$SOL_DIR"
    files=(data.sha256 ../scripts/load_raw.py)
    for f in ../scripts/init/*.sql inject/*.sql; do
      if [ -f "$f" ]; then files+=("$f"); fi
    done
    sha256sum "${files[@]}"
  ) | sha256sum | cut -c1-64
}

inject_files() {
  local f
  for f in "$SOL_DIR"/inject/*.sql; do
    if [ -f "$f" ]; then printf '%s\n' "${f#"$SOL_DIR"/}"; fi
  done
}

# Состояние raw переживает сборку (ops не пересоздаётся) и перезагрузку raw
# (загрузчик пересоздаёт только таблицы raw).
readonly RAW_STATE_DDL="
SET client_min_messages = warning;
CREATE SCHEMA IF NOT EXISTS ops;
CREATE TABLE IF NOT EXISTS ops.raw_state (
    id          boolean PRIMARY KEY DEFAULT true CHECK (id),
    fingerprint text        NOT NULL,
    loaded_at   timestamptz NOT NULL DEFAULT now(),
    row_counts  jsonb       NOT NULL,
    inject      text[]      NOT NULL
);
COMMENT ON TABLE ops.raw_state IS 'Состояние raw (одна строка): отпечаток входа последней успешной загрузки, пишет стадия raw в run.sh. Нет строки — raw не готов и будет перезалит.';
COMMENT ON COLUMN ops.raw_state.fingerprint IS 'sha256 от data.sha256, ../scripts/load_raw.py, ../scripts/init/*.sql и inject/*.sql (PLAN 6.6).';
COMMENT ON COLUMN ops.raw_state.row_counts IS 'Число строк по таблицам raw после загрузки и патчей inject/.';
COMMENT ON COLUMN ops.raw_state.inject IS 'Применённые патчи inject/ по порядку.';
"

stage_raw() {
  local db=$SOLUTION_DB fp state
  case "$RESERVED_DBS" in
    *" $db "*) die "$E_RAW" "база «$db» зарезервирована, стадия raw её не трогает" ;;
  esac
  wait_db

  if [ "${RESET_DB:-0}" = 1 ]; then
    step "удаляю базу $db (--reset; другие базы и контейнер не трогаются)"
    psql_or_die "$E_RAW" "удаление базы $db" -d postgres -v db="$db" <<'SQL'
SELECT format('DROP DATABASE IF EXISTS %I WITH (FORCE)', :'db') \gexec
SQL
  fi

  step "база $db"
  psql_or_die "$E_RAW" "создание базы $db" -d postgres -v db="$db" <<'SQL'
SELECT format('CREATE DATABASE %I', :'db')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
SELECT format('ALTER DATABASE %I SET search_path TO core, public', :'db') \gexec
SQL

  fp=$(raw_fingerprint)
  if [ "${FORCE_RAW:-0}" != 1 ]; then
    state=$(psql -X -At -v ON_ERROR_STOP=1 -c "SELECT to_regclass('ops.raw_state') IS NOT NULL AND to_regclass('raw.orders') IS NOT NULL") || exit "$E_RAW"
    if [ "$state" = t ]; then
      state=$(psql -X -At -v ON_ERROR_STOP=1 -c "SELECT (SELECT fingerprint FROM ops.raw_state) || ':' || EXISTS (SELECT FROM raw.orders)") || exit "$E_RAW"
      if [ "$state" = "$fp:true" ]; then
        say "    отпечаток не изменился (${fp:0:12}…), raw загружен — пропуск"
        return 0
      fi
    fi
  fi

  step "сбрасываю отпечаток: прерванная загрузка не будет принята за готовую"
  psql_or_die "$E_RAW" "подготовка ops.raw_state" -c "$RAW_STATE_DDL DELETE FROM ops.raw_state;"

  step "загрузчик организаторов (../scripts/load_raw.py)"
  python3 "$ROOT/scripts/load_raw.py" --host "$PGHOST" --port "$PGPORT" --db "$db" \
    || die "$E_RAW" "загрузчик организаторов завершился с ошибкой" \
           "Где: ../scripts/load_raw.py, база $db; сообщение загрузчика — выше" \
           "Что делать: загрузчик не правим (PLAN 6.15). Проверьте ../data (./run.sh data) и изменения в ../scripts после sync."

  # Патчи, сверка строк и отпечаток — одна транзакция, отпечаток последним.
  local sql=/tmp/raw_finish.sql inject=() expected tbl n f
  mapfile -t inject < <(inject_files)
  expected=$(awk 'NF == 2 {printf "%s\"%s\":%s", (NR > 1 ? "," : ""), $1, $2}' "$SOL_DIR/data.rows")
  {
    printf 'BEGIN;\n'
    for f in "${inject[@]}"; do
      printf '\\echo применяю %s\n\\i %s\n' "$f" "$SOL_DIR/$f"
    done
    printf "SELECT set_config('capibara.raw_expected', :'expected', true) AS _e, set_config('capibara.has_inject', :'has_inject', true) AS _i \\\\gset\n"
    printf 'CREATE TEMP TABLE raw_count (table_name text PRIMARY KEY, n bigint NOT NULL) ON COMMIT DROP;\n'
    while read -r tbl n; do
      [ -n "$tbl" ] || continue
      printf "INSERT INTO raw_count SELECT '%s', count(*) FROM %s;\n" "$tbl" "$tbl"
    done < "$SOL_DIR/data.rows"
    cat <<'SQL'
DO $$
DECLARE
    expected   jsonb   := current_setting('capibara.raw_expected')::jsonb;
    has_inject boolean := current_setting('capibara.has_inject')::boolean;
    diff       text;
BEGIN
    SELECT string_agg(format('%s: ожидалось %s, загружено %s', c.table_name, expected ->> c.table_name, c.n),
                      '; ' ORDER BY c.table_name)
      INTO diff
      FROM raw_count c
     WHERE c.n IS DISTINCT FROM (expected ->> c.table_name)::bigint;
    IF diff IS NULL THEN
        RETURN;
    ELSIF has_inject THEN
        RAISE WARNING 'Число строк raw отличается от data.rows из-за патчей inject/: %', diff;
    ELSE
        RAISE EXCEPTION 'Число строк raw не совпало с data.rows'
            USING DETAIL = diff,
                  HINT = 'Хэши CSV совпали, патчей нет: загрузчик прочитал файлы иначе, чем ожидалось. Проверьте изменения ../scripts/load_raw.py (sync) и data.rows (PLAN 6.6).';
    END IF;
END $$;
\pset footer off
SELECT table_name AS "таблица", n AS "строк" FROM raw_count
UNION ALL SELECT 'итого', sum(n) FROM raw_count;
INSERT INTO ops.raw_state (fingerprint, row_counts, inject)
SELECT :'fp', jsonb_object_agg(table_name, n ORDER BY table_name), string_to_array(:'inject_list', ' ')
  FROM raw_count;
COMMIT;
SQL
  } > "$sql"

  step "патчи inject/ (${#inject[@]} шт.), сверка строк с data.rows, запись отпечатка"
  psql_or_die "$E_RAW" "патчи inject/ и сверка строк raw (отпечаток не записан, следующий запуск перезальёт raw)" \
    -v expected="{$expected}" -v has_inject="$([ ${#inject[@]} -gt 0 ] && echo true || echo false)" \
    -v fp="$fp" -v inject_list="${inject[*]}" -f "$sql"
  say "    отпечаток raw: ${fp:0:12}…"
}

# build: model/build.sql сам открывает и закрывает транзакцию, поэтому
# --single-transaction не передаём (PLAN 6.8).
stage_build() {
  local fp=none state out=/tmp/build.out rc=0
  wait_db
  state=$(psql -X -At -v ON_ERROR_STOP=1 -c "SELECT to_regclass('ops.raw_state') IS NOT NULL") || exit "$E_BUILD"
  if [ "$state" = t ]; then
    fp=$(psql -X -At -v ON_ERROR_STOP=1 -c "SELECT coalesce((SELECT fingerprint FROM ops.raw_state), 'none')") || exit "$E_BUILD"
  fi
  [ "$fp" != none ] || say "    внимание: raw не загружен или загрузка не завершена (ops.raw_state пуст)"

  local args=(-v git_commit="$GIT_COMMIT" -v raw_fingerprint="$fp")
  if [ -n "${ANALYST_PASSWORD:-}" ]; then args+=(-v analyst_password="$ANALYST_PASSWORD"); fi

  step "model/build.sql (коммит $GIT_COMMIT, отпечаток raw ${fp:0:12})"
  psql -X -v ON_ERROR_STOP=1 "${args[@]}" -f "$SOL_DIR/model/build.sql" 2>&1 | tee "$out" || rc=$?
  case "$rc" in
    0) ;;
    2) die "$E_UP" "соединение с базой потеряно во время сборки" \
           "Сборка — одна транзакция: на сервере она откатится, прежняя модель останется." \
           "Что делать: проверьте контейнер (из корня форка): docker compose ps" ;;
    *)
      if grep -q 'CHECK FAILED:' "$out"; then
        die "$E_CHECK" "самопроверки сборки не прошли" \
          "Где: model/90_checks.sql, список упавших проверок — выше" \
          "Сборка откатена целиком, прежняя версия модели осталась." \
          "Что делать: найти причину в данных или коде; пороги без решения команды не ослаблять."
      fi
      die "$E_BUILD" "ошибка в сборке модели (psql, код $rc)" \
        "Где: файл и строка — в сообщении psql выше" \
        "Сборка откатена целиком, прежняя версия модели осталась." \
        "Если это lock timeout — кто-то держит блокировку на схемах базы $SOLUTION_DB (открытая транзакция в клиенте): закройте её и повторите." ;;
  esac
}

# ---------------------------------------------------------------------
#  main
# ---------------------------------------------------------------------

main() {
  if [ "${1:-}" = --inside ]; then
    shift
    inside "$@"
    return
  fi

  local stages=() reset=0 mode=run args="$*"
  FORCE_RAW=0
  PSQL_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --reset)     reset=1 ;;
      --force-raw) FORCE_RAW=1 ;;
      preflight)   mode=preflight ;;
      up|data|raw|build) stages+=("$1") ;;
      psql)        mode=psql; shift; PSQL_ARGS=("$@"); break ;;
      test)        die "$E_USAGE" "стадия test появится на этапе B (PLAN.md, 9)" ;;
      answers)     die "$E_USAGE" "стадия answers появится на этапе C (PLAN.md, 9)" ;;
      status|sync|bundle|fault)
                   die "$E_USAGE" "команда $1 ещё не реализована (PLAN.md, 9.0: этапы A2, A3, B)" ;;
      -h|--help)   usage; exit 0 ;;
      *)           die "$E_USAGE" "неизвестный аргумент: $1" "Что делать: ./run.sh --help" ;;
    esac
    shift
  done
  if [ "$reset" = 1 ] && [ ${#stages[@]} -gt 0 ]; then
    die "$E_USAGE" "--reset работает только с полным прогоном" "Что делать: ./run.sh --reset"
  fi
  [ ${#stages[@]} -gt 0 ] || stages=(up data raw build)

  if [ "$mode" = psql ]; then
    # Утилита для человека: код выхода — код самого psql.
    local rc=0
    preflight >/dev/null
    stage_psql || rc=$?
    exit "$rc"
  fi

  start_log
  trap on_interrupt INT TERM
  say "run.sh $args — $(date '+%Y-%m-%d %H:%M:%S')"
  preflight
  [ "$mode" = run ] || return 0

  export RESET_DB=$reset FORCE_RAW
  local st
  for st in "${stages[@]}"; do
    run_host_stage "$st"
  done
  printf '\nГотово: %s за %s с. Лог: %s\n' "${stages[*]}" "$SECONDS" "$LOG"
}

main "$@"
