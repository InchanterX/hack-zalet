-- =====================================================================
--  Сборка модели из raw с нуля (PLAN.md, 6.8).
--
--  Работает в текущей базе и не содержит её имени. Запуск без пайплайна:
--      psql -v ON_ERROR_STOP=1 -d marketplace -f inchanterx/model/build.sql
--
--  Вся сборка — одна транзакция: при любой ошибке остаётся предыдущая
--  версия модели целиком. psql-команды — только в этом файле, номерные
--  файлы содержат чистый SQL и читают параметры через current_setting().
-- =====================================================================

\set ON_ERROR_STOP 1
\set QUIET on

-- Параметры необязательны: значения по умолчанию для запуска руками.
\if :{?git_commit}
\else
  \set git_commit unknown
\endif
\if :{?raw_fingerprint}
\else
  \set raw_fingerprint unknown
\endif
\if :{?analyst_password}
\else
  \set analyst_password ''
\endif

SET client_min_messages = warning;

BEGIN;

-- Если кто-то держит блокировку на наших схемах (открытая транзакция
-- в DBeaver), сборка падает через 10 с, а не висит молча (PLAN 6.8).
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '5min';

-- Параметры для номерных файлов: настройки сессии живут до конца транзакции.
SELECT set_config('capibara.git_commit', :'git_commit', true) AS _git_commit,
       set_config('capibara.raw_fingerprint', :'raw_fingerprint', true) AS _raw_fingerprint
\gset

\ir 00_reset.sql

COMMIT;

\echo 'Сборка завершена. Коммит:' :git_commit ' Отпечаток raw:' :raw_fingerprint
