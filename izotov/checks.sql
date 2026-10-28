-- Регрессионные проверки ответов: контрольные цифры из docs/tasks.md.
-- Запускать после core.sql и mart.sql. Печатает таблицу проверок
-- и падает с ошибкой, если хоть одна не прошла.

\set ON_ERROR_STOP on

CREATE TEMP TABLE check_result (
    check_name  text,
    expected    text,
    actual      text
);

INSERT INTO check_result VALUES
    ('q01: строк за период',          '24',
        (SELECT count(*)::text FROM mart.q01_monthly_revenue)),
    ('q01: месяцев с нулевой выручкой', '1',
        (SELECT count(*)::text FROM mart.q01_monthly_revenue WHERE revenue = 0)),
    ('q01: итого выручка',            '13221498.11',
        (SELECT sum(revenue)::text FROM mart.q01_monthly_revenue)),
    ('q02: выручка первого продавца', '226987.93',
        (SELECT max(revenue)::text FROM mart.q02_top_sellers)),
    ('q02: продавцов в топе',         '10',
        (SELECT count(*)::text FROM mart.q02_top_sellers)),
    ('q03: средний чек',              '159.88',
        (SELECT avg_check::text FROM mart.q03_avg_check)),
    ('q04: покупателей',              '96096',
        (SELECT customers_cnt::text FROM mart.q04_repeat_customers)),
    ('q04: доля вернувшихся, %',      '3.12',
        (SELECT returned_pct::text FROM mart.q04_repeat_customers)),
    ('q05: категорий',                '74',
        (SELECT count(*)::text FROM mart.q05_category_revenue)),
    ('q05: крупнейшая категория',     '1233131.72',
        (SELECT max(revenue)::text FROM mart.q05_category_revenue)),
    ('q05: сумма = общей выручке',    '13221498.11',
        (SELECT sum(revenue)::text FROM mart.q05_category_revenue));

SELECT check_name, expected, actual,
       CASE WHEN expected = actual THEN 'ok' ELSE 'FAIL' END AS result
FROM check_result;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM check_result WHERE expected IS DISTINCT FROM actual) THEN
        RAISE EXCEPTION 'Есть непройденные проверки, см. таблицу выше';
    END IF;
END $$;
