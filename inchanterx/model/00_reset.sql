-- Пересоздание схем модели (PLAN.md, 2).
-- core, mart и meta целиком строятся сборкой и пересоздаются каждый раз.
-- ops хранит состояние пайплайна (отпечаток raw, история сборок) и
-- сборкой не пересоздаётся. raw не трогаем никогда.

DROP SCHEMA IF EXISTS mart CASCADE;
DROP SCHEMA IF EXISTS core CASCADE;
DROP SCHEMA IF EXISTS meta CASCADE;

CREATE SCHEMA core;
CREATE SCHEMA mart;
CREATE SCHEMA meta;
CREATE SCHEMA IF NOT EXISTS ops;

COMMENT ON SCHEMA core IS 'Нормализованная модель: справочники, сущности и факты на своих зёрнах. Строится из raw сборкой model/build.sql.';
COMMENT ON SCHEMA mart IS 'Витрины и ответы на вопросы. Читает только core и mart, никогда raw.';
COMMENT ON SCHEMA meta IS 'Наблюдаемость сборки: журнал, отбракованные строки, проблемы качества, самопроверки. Пересоздаётся каждой сборкой.';
COMMENT ON SCHEMA ops IS 'Состояние пайплайна run.sh (отпечаток загруженного raw, история сборок). Сборкой не пересоздаётся.';
