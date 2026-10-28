-- Ответы на вопросы аналитиков. Читают только core, никогда raw.
-- Запускать после izotov/core.sql:
--
--   docker compose exec -T postgres psql -U hack -d marketplace -v ON_ERROR_STOP=1 < izotov/mart.sql
--
-- Определения, общие для всех ответов:
--   выручка  — sum(price) по заказам со статусом is_revenue (delivered);
--              доставка в выручку не входит;
--   чек      — price + freight по заказу целиком.

\set ON_ERROR_STOP on

BEGIN;

DROP SCHEMA IF EXISTS mart CASCADE;
CREATE SCHEMA mart;


-- 1. Выручка и число заказов по месяцам, сентябрь 2016 — август 2018.
-- Месяцы берутся из календаря, поэтому месяц без заказов даёт строку с нулём.
-- orders_cnt — заказы, вошедшие в выручку; all_orders_cnt — все оформленные.
-- Контроль: 24 строки, одна с нулевой выручкой, итого 13 221 498.11
CREATE VIEW mart.q01_monthly_revenue AS
SELECT m.month_start                                            AS month,
       count(f.order_id) FILTER (WHERE s.is_revenue)            AS orders_cnt,
       COALESCE(sum(f.items_price_amt) FILTER (WHERE s.is_revenue), 0) AS revenue,
       count(f.order_id)                                        AS all_orders_cnt
FROM (SELECT DISTINCT month_start FROM core.dim_date
      WHERE month_start BETWEEN '2016-09-01' AND '2018-08-01') m
LEFT JOIN core.fact_order f
       ON date_trunc('month', f.purchase_date)::date = m.month_start
LEFT JOIN core.dim_order_status s ON s.status = f.status
GROUP BY m.month_start
ORDER BY m.month_start;


-- 2. Топ-10 продавцов по выручке. Считается на уровне позиции, поэтому
-- в заказе с несколькими продавцами каждому достаются только его товары.
-- Контроль: у первого продавца 226 987.93
CREATE VIEW mart.q02_top_sellers AS
SELECT i.seller_id,
       sl.city,
       sl.state,
       count(DISTINCT i.order_id) AS orders_cnt,
       count(*)                   AS units_cnt,
       sum(i.price_amt)               AS revenue
FROM core.fact_order_item i
JOIN core.fact_order f        USING (order_id)
JOIN core.dim_order_status s  ON s.status = f.status
JOIN core.dim_seller sl       USING (seller_id)
WHERE s.is_revenue
GROUP BY i.seller_id, sl.city, sl.state
ORDER BY revenue DESC
LIMIT 10;


-- 3. Средний чек. Считается на уровне заказа (fact_order), а не позиции.
-- Контроль: 159.88
CREATE VIEW mart.q03_avg_check AS
SELECT round(avg(f.items_price_amt + f.items_freight_amt), 2) AS avg_check,
       round(avg(f.lines_cnt), 2)                             AS avg_lines,
       round(avg(f.units_cnt), 2)                             AS avg_units
FROM core.fact_order f
JOIN core.dim_order_status s ON s.status = f.status
WHERE s.is_revenue AND f.has_items;


-- 4. Покупатели и повторные покупки. Покупатель — customer_unique_id;
-- вернувшийся — у кого больше одного заказа.
-- Контроль: 96 096 покупателей, вернулись 3,12%
CREATE VIEW mart.q04_repeat_customers AS
SELECT count(*)                                                  AS customers_cnt,
       count(*) FILTER (WHERE orders_cnt > 1)                    AS returned_cnt,
       round(100.0 * count(*) FILTER (WHERE orders_cnt > 1) / count(*), 2) AS returned_pct
FROM core.dim_customer;


-- 5. Выручка по категориям с долей. Товары без категории собраны
-- в 'unknown', поэтому сумма по категориям равна общей выручке.
-- Контроль: 74 категории, у крупнейшей 1 233 131.72, сумма 13 221 498.11
CREATE VIEW mart.q05_category_revenue AS
SELECT c.category_name_en                                       AS category,
       sum(i.price_amt)                                           AS revenue,
       round(100 * sum(i.price_amt) / sum(sum(i.price_amt)) OVER (), 2) AS share_pct
FROM core.fact_order_item i
JOIN core.fact_order f        USING (order_id)
JOIN core.dim_order_status s  ON s.status = f.status
JOIN core.dim_product p       USING (product_id)
JOIN core.dim_category c      USING (category_name)
WHERE s.is_revenue
GROUP BY c.category_name_en
ORDER BY revenue DESC;

COMMIT;
