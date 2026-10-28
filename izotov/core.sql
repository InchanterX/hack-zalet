-- Сборка core-слоя из raw. Запускается целиком на чистой базе и повторно:
-- каждый запуск пересоздаёт схему core с нуля. Обычно вызывается из build.sh.
--
--   docker compose exec -T postgres psql -U hack -d marketplace -v ON_ERROR_STOP=1 < izotov/core.sql
--
-- Порядок: справочники -> факты -> ключи и связи -> журнал качества -> сверки.
-- Связи (FK) объявляются после загрузки одним проходом: так быстрее,
-- а «сирота» в данных всё равно уронит сборку на ALTER TABLE.
--
-- Соглашения об именах во всём слое:
--   *_at    timestamp          *_date  date
--   *_amt   деньги, numeric    *_cnt   количество
--   is_*    признак сущности   has_*   есть ли связанные строки
--   dq_*    флаг качества данных (подробности — в core.dq_issue)
--   dim_*   справочник         fact_*  факт; зерно — в COMMENT каждой таблицы

\set ON_ERROR_STOP on

BEGIN;

DROP SCHEMA IF EXISTS core CASCADE;
CREATE SCHEMA core;


-- =====================================================================
-- 10. Справочники
-- =====================================================================

-- Статусы заказа. Бизнес-правило «что считается выручкой» живёт здесь,
-- а не в каждом запросе: выручка — только доставленные заказы.
CREATE TABLE core.dim_order_status (
    status        text PRIMARY KEY,
    stage_no      int     NOT NULL,  -- порядок на пути заказа, 0 — выпал из пути
    is_revenue    boolean NOT NULL,
    is_cancelled  boolean NOT NULL,
    is_final      boolean NOT NULL,  -- дальше статус уже не изменится
    is_known      boolean NOT NULL   -- false — статус пришёл из источника, правил для него нет
);

INSERT INTO core.dim_order_status VALUES
    ('created',     1, false, false, false, true),
    ('approved',    2, false, false, false, true),
    ('invoiced',    3, false, false, false, true),
    ('processing',  4, false, false, false, true),
    ('shipped',     5, false, false, false, true),
    ('delivered',   6, true,  false, true,  true),
    ('canceled',    0, false, true,  true,  true),
    ('unavailable', 0, false, true,  true,  true);

-- Новый статус в источнике не роняет сборку: он попадает сюда без правил
-- и в журнал dq_issue, а в выручку не входит, пока ему не зададут флаги.
INSERT INTO core.dim_order_status
SELECT DISTINCT trim(order_status), 0, false, false, false, false
FROM raw.orders
WHERE trim(order_status) NOT IN (SELECT status FROM core.dim_order_status);


-- Способы оплаты. not_defined — реальное значение источника, оставлено
-- отдельной строкой, чтобы такие платежи не смешивались с остальными.
CREATE TABLE core.dim_payment_type (
    payment_type  text PRIMARY KEY,
    is_defined    boolean NOT NULL,
    is_known      boolean NOT NULL
);

INSERT INTO core.dim_payment_type VALUES
    ('credit_card', true,  true),
    ('debit_card',  true,  true),
    ('boleto',      true,  true),
    ('voucher',     true,  true),
    ('not_defined', false, true);

INSERT INTO core.dim_payment_type
SELECT DISTINCT trim(payment_type), true, false
FROM raw.order_payments
WHERE trim(payment_type) NOT IN (SELECT payment_type FROM core.dim_payment_type);


-- Календарь. Нужен, чтобы месяц без заказов всё равно попал в отчёт.
-- Диапазон — целые годы от первого заказа до последней обещанной даты.
CREATE TABLE core.dim_date (
    date         date PRIMARY KEY,
    month_start  date NOT NULL,
    year         int  NOT NULL,
    month        int  NOT NULL,
    quarter      int  NOT NULL,
    iso_dow      int  NOT NULL   -- 1 = понедельник
);

INSERT INTO core.dim_date
SELECT d::date,
       date_trunc('month', d)::date,
       extract(year    FROM d)::int,
       extract(month   FROM d)::int,
       extract(quarter FROM d)::int,
       extract(isodow  FROM d)::int
FROM generate_series(
        (SELECT date_trunc('year', min(NULLIF(order_purchase_timestamp, '')::timestamp)) FROM raw.orders),
        (SELECT date_trunc('year', max(NULLIF(order_estimated_delivery_date, '')::timestamp))
                + interval '1 year - 1 day' FROM raw.orders),
        interval '1 day') AS d;


-- Категории. Три источника названий: справочник перевода, категории из
-- карточек (двух в справочнике нет) и служебная 'unknown' для товаров
-- без категории — чтобы JOIN не терял строки.
CREATE TABLE core.dim_category (
    category_name     text PRIMARY KEY,   -- португальское, как в источнике
    category_name_en  text    NOT NULL,
    is_translated     boolean NOT NULL,
    is_unknown        boolean NOT NULL
);

INSERT INTO core.dim_category
SELECT trim(product_category_name), trim(product_category_name_english), true, false
FROM raw.product_category_translation;

INSERT INTO core.dim_category
SELECT DISTINCT trim(product_category_name), trim(product_category_name), false, false
FROM raw.products
WHERE NULLIF(trim(product_category_name), '') IS NOT NULL
  AND trim(product_category_name) NOT IN (SELECT category_name FROM core.dim_category);

INSERT INTO core.dim_category VALUES ('unknown', 'unknown', false, true);


CREATE TABLE core.dim_product (
    product_id          text PRIMARY KEY,
    category_name       text NOT NULL,
    name_length         int,
    description_length  int,
    photos_qty          int,
    weight_g            int,
    length_cm           int,
    height_cm           int,
    width_cm            int
);

INSERT INTO core.dim_product
SELECT product_id,
       COALESCE(NULLIF(trim(product_category_name), ''), 'unknown'),
       NULLIF(product_name_lenght, '')::numeric::int,
       NULLIF(product_description_lenght, '')::numeric::int,
       NULLIF(product_photos_qty, '')::numeric::int,
       NULLIF(product_weight_g, '')::numeric::int,
       NULLIF(product_length_cm, '')::numeric::int,
       NULLIF(product_height_cm, '')::numeric::int,
       NULLIF(product_width_cm, '')::numeric::int
FROM raw.products;


-- Индекс хранится текстом из 5 цифр: в источнике у части индексов
-- потерян ведущий ноль, а как число он теряется окончательно.
CREATE TABLE core.dim_seller (
    seller_id   text PRIMARY KEY,
    zip_prefix  text NOT NULL,
    city        text NOT NULL,
    state       text NOT NULL
);

INSERT INTO core.dim_seller
SELECT seller_id,
       lpad(trim(seller_zip_code_prefix), 5, '0'),
       lower(trim(seller_city)),
       upper(trim(seller_state))
FROM raw.sellers;


-- Покупатель — человек, customer_unique_id. Исходный customer_id выдаётся
-- на каждый заказ заново и хранится в fact_order. Адрес — из последнего
-- заказа покупателя.
CREATE TABLE core.dim_customer (
    customer_key    text PRIMARY KEY,   -- = customer_unique_id
    zip_prefix      text NOT NULL,
    city            text NOT NULL,
    state           text NOT NULL,
    first_order_at  timestamp NOT NULL,
    last_order_at   timestamp NOT NULL,
    orders_cnt      int NOT NULL
);

INSERT INTO core.dim_customer
SELECT DISTINCT ON (c.customer_unique_id)
       c.customer_unique_id,
       lpad(trim(c.customer_zip_code_prefix), 5, '0'),
       lower(trim(c.customer_city)),
       upper(trim(c.customer_state)),
       min(o.order_purchase_timestamp::timestamp) OVER w,
       max(o.order_purchase_timestamp::timestamp) OVER w,
       count(*) OVER w
FROM raw.customers c
JOIN raw.orders o USING (customer_id)
WINDOW w AS (PARTITION BY c.customer_unique_id)
ORDER BY c.customer_unique_id, o.order_purchase_timestamp::timestamp DESC, o.order_id;


-- =====================================================================
-- 20. Факты
-- =====================================================================

-- Позиция: одна строка — одна единица товара. order_item_id — порядковый
-- номер внутри заказа, поэтому ключ составной.
CREATE TABLE core.fact_order_item (
    order_id             text NOT NULL,
    order_item_id        int  NOT NULL,
    product_id           text NOT NULL,
    seller_id            text NOT NULL,
    shipping_limit_at    timestamp NOT NULL,
    price_amt            numeric(12,2) NOT NULL CHECK (price_amt >= 0),
    freight_amt          numeric(12,2) NOT NULL CHECK (freight_amt >= 0),
    seller_shipped_late  boolean,   -- передан в доставку позже крайнего срока; NULL — не передан
    PRIMARY KEY (order_id, order_item_id)
);

INSERT INTO core.fact_order_item
SELECT i.order_id,
       i.order_item_id::int,
       i.product_id,
       i.seller_id,
       i.shipping_limit_date::timestamp,
       i.price::numeric,
       i.freight_value::numeric,
       NULLIF(o.order_delivered_carrier_date, '')::timestamp > i.shipping_limit_date::timestamp
FROM raw.order_items i
LEFT JOIN raw.orders o USING (order_id);


-- Платёж: заказ можно оплатить несколькими способами.
CREATE TABLE core.fact_payment (
    order_id            text NOT NULL,
    payment_sequential  int  NOT NULL,
    payment_type        text NOT NULL,
    installments_cnt    int  NOT NULL CHECK (installments_cnt >= 0),  -- 0 встречается, см. dq_issue
    payment_amt         numeric(12,2) NOT NULL CHECK (payment_amt >= 0),
    PRIMARY KEY (order_id, payment_sequential)
);

INSERT INTO core.fact_payment
SELECT order_id,
       payment_sequential::int,
       trim(payment_type),
       payment_installments::int,
       payment_value::numeric
FROM raw.order_payments;


-- Отзыв. Уникальна только пара (review_id, order_id): один отзыв бывает
-- привязан к нескольким заказам, у заказа бывает несколько отзывов.
-- Для оценки заказа берите is_latest_for_order, иначе заказ посчитается дважды.
CREATE TABLE core.fact_review (
    review_id            text NOT NULL,
    order_id             text NOT NULL,
    score                int  NOT NULL CHECK (score BETWEEN 1 AND 5),
    has_comment          boolean NOT NULL,
    comment_title        text,
    comment_message      text,
    created_at           timestamp NOT NULL,
    answered_at          timestamp,
    is_latest_for_order  boolean NOT NULL,
    PRIMARY KEY (review_id, order_id)
);

INSERT INTO core.fact_review
SELECT review_id,
       order_id,
       review_score::int,
       NULLIF(trim(review_comment_message), '') IS NOT NULL
           OR NULLIF(trim(review_comment_title), '') IS NOT NULL,
       NULLIF(trim(review_comment_title), ''),
       NULLIF(trim(review_comment_message), ''),
       review_creation_date::timestamp,
       NULLIF(review_answer_timestamp, '')::timestamp,
       row_number() OVER (PARTITION BY order_id
                          ORDER BY NULLIF(review_answer_timestamp, '')::timestamp DESC NULLS LAST,
                                   review_creation_date::timestamp DESC, review_id) = 1
FROM raw.order_reviews;


-- Заказ: одна строка — один заказ. Агрегаты по позициям и платежам
-- посчитаны здесь один раз, чтобы отчёты не соединяли позиции с заказом
-- и не размножали строки.
CREATE TABLE core.fact_order (
    order_id               text PRIMARY KEY,
    customer_id_src        text NOT NULL UNIQUE,  -- исходный customer_id, свой на каждый заказ
    customer_key           text NOT NULL,
    status                 text NOT NULL,
    purchase_date          date NOT NULL,

    -- адрес доставки — свойство заказа, а не покупателя
    ship_zip_prefix        text NOT NULL,
    ship_city              text NOT NULL,
    ship_state             text NOT NULL,

    purchased_at           timestamp NOT NULL,
    approved_at            timestamp,
    delivered_carrier_at   timestamp,
    delivered_customer_at  timestamp,
    estimated_delivery_at  timestamp,

    units_cnt              int NOT NULL,   -- строк order_items: одна строка = одна единица
    lines_cnt              int NOT NULL,   -- разных пар товар x продавец
    sellers_cnt            int NOT NULL,
    items_price_amt        numeric(12,2) NOT NULL,
    items_freight_amt      numeric(12,2) NOT NULL,
    payments_cnt           int NOT NULL,
    payment_amt            numeric(12,2) NOT NULL,

    -- доставка; NULL — заказ не вручён, сравнивать не с чем
    delivery_days          int,   -- от оформления до вручения
    promised_days          int,   -- от оформления до обещанной даты
    delay_days             int,   -- вручение минус обещанная дата, > 0 — опоздание
    is_late                boolean,

    customer_order_seq     int NOT NULL,   -- какой по счёту это заказ покупателя
    is_repeat              boolean NOT NULL,

    has_items              boolean NOT NULL,
    has_payment            boolean NOT NULL,
    dq_dates_inconsistent  boolean NOT NULL,
    dq_amount_mismatch     boolean NOT NULL
);

INSERT INTO core.fact_order
WITH o AS (
    SELECT o.order_id,
           o.customer_id,
           c.customer_unique_id                                AS customer_key,
           trim(o.order_status)                                AS status,
           lpad(trim(c.customer_zip_code_prefix), 5, '0')      AS ship_zip_prefix,
           lower(trim(c.customer_city))                        AS ship_city,
           upper(trim(c.customer_state))                       AS ship_state,
           o.order_purchase_timestamp::timestamp               AS purchased_at,
           NULLIF(o.order_approved_at, '')::timestamp          AS approved_at,
           NULLIF(o.order_delivered_carrier_date, '')::timestamp  AS delivered_carrier_at,
           NULLIF(o.order_delivered_customer_date, '')::timestamp AS delivered_customer_at,
           NULLIF(o.order_estimated_delivery_date, '')::timestamp AS estimated_delivery_at
    FROM raw.orders o
    JOIN raw.customers c USING (customer_id)
),
items AS (
    SELECT order_id,
           count(*)                                 AS units_cnt,
           count(DISTINCT (product_id, seller_id))  AS lines_cnt,
           count(DISTINCT seller_id)                AS sellers_cnt,
           sum(price_amt)                           AS price_amt,
           sum(freight_amt)                         AS freight_amt
    FROM core.fact_order_item
    GROUP BY order_id
),
pays AS (
    SELECT order_id, count(*) AS payments_cnt, sum(payment_amt) AS payment_amt
    FROM core.fact_payment
    GROUP BY order_id
)
SELECT o.order_id,
       o.customer_id,
       o.customer_key,
       o.status,
       o.purchased_at::date,
       o.ship_zip_prefix,
       o.ship_city,
       o.ship_state,
       o.purchased_at,
       o.approved_at,
       o.delivered_carrier_at,
       o.delivered_customer_at,
       o.estimated_delivery_at,
       COALESCE(i.units_cnt, 0),
       COALESCE(i.lines_cnt, 0),
       COALESCE(i.sellers_cnt, 0),
       COALESCE(i.price_amt, 0),
       COALESCE(i.freight_amt, 0),
       COALESCE(p.payments_cnt, 0),
       COALESCE(p.payment_amt, 0),
       o.delivered_customer_at::date - o.purchased_at::date,
       o.estimated_delivery_at::date - o.purchased_at::date,
       o.delivered_customer_at::date - o.estimated_delivery_at::date,
       o.delivered_customer_at::date > o.estimated_delivery_at::date,
       row_number() OVER (PARTITION BY o.customer_key ORDER BY o.purchased_at, o.order_id),
       row_number() OVER (PARTITION BY o.customer_key ORDER BY o.purchased_at, o.order_id) > 1,
       i.order_id IS NOT NULL,
       p.order_id IS NOT NULL,
       COALESCE(o.approved_at           < o.purchased_at, false)
         OR COALESCE(o.delivered_carrier_at  < o.purchased_at, false)
         OR COALESCE(o.delivered_customer_at < o.purchased_at, false)
         OR COALESCE(o.delivered_customer_at < o.delivered_carrier_at, false),
       COALESCE(abs(i.price_amt + i.freight_amt - p.payment_amt) > 0.01, false)
FROM o
LEFT JOIN items i USING (order_id)
LEFT JOIN pays  p USING (order_id);


-- =====================================================================
-- 30. Связи и индексы
-- =====================================================================
-- Объявляются после загрузки: каждая связь проверяется одним проходом.
-- Если в raw появится позиция без заказа или товар без карточки,
-- сборка упадёт здесь с именем нарушенной связи.

ALTER TABLE core.dim_product     ADD FOREIGN KEY (category_name) REFERENCES core.dim_category;
ALTER TABLE core.fact_order      ADD FOREIGN KEY (customer_key)  REFERENCES core.dim_customer;
ALTER TABLE core.fact_order      ADD FOREIGN KEY (status)        REFERENCES core.dim_order_status;
ALTER TABLE core.fact_order      ADD FOREIGN KEY (purchase_date) REFERENCES core.dim_date;
ALTER TABLE core.fact_order_item ADD FOREIGN KEY (order_id)      REFERENCES core.fact_order;
ALTER TABLE core.fact_order_item ADD FOREIGN KEY (product_id)    REFERENCES core.dim_product;
ALTER TABLE core.fact_order_item ADD FOREIGN KEY (seller_id)     REFERENCES core.dim_seller;
ALTER TABLE core.fact_payment    ADD FOREIGN KEY (order_id)      REFERENCES core.fact_order;
ALTER TABLE core.fact_payment    ADD FOREIGN KEY (payment_type)  REFERENCES core.dim_payment_type;
ALTER TABLE core.fact_review     ADD FOREIGN KEY (order_id)      REFERENCES core.fact_order;

CREATE INDEX ON core.fact_order (customer_key);
CREATE INDEX ON core.fact_order (purchase_date);
CREATE INDEX ON core.fact_order (status);
CREATE INDEX ON core.fact_order_item (product_id);
CREATE INDEX ON core.fact_order_item (seller_id);
CREATE INDEX ON core.fact_review (order_id);
CREATE INDEX ON core.dim_product (category_name);


-- =====================================================================
-- 35. Описание модели в самой базе — видно в DBeaver и через \d+
-- =====================================================================

COMMENT ON SCHEMA core IS 'Модель Capibara. Собирается из raw скриптом izotov/core.sql';

COMMENT ON TABLE core.dim_order_status IS 'Справочник статусов заказа. Зерно: статус. is_revenue задаёт, какие заказы входят в выручку';
COMMENT ON TABLE core.dim_payment_type IS 'Справочник способов оплаты. Зерно: способ';
COMMENT ON TABLE core.dim_date         IS 'Календарь. Зерно: день. Нужен, чтобы пустые периоды попадали в отчёты';
COMMENT ON TABLE core.dim_category     IS 'Категории товаров. Зерно: категория. Содержит unknown для товаров без категории';
COMMENT ON TABLE core.dim_product      IS 'Карточки товаров. Зерно: товар';
COMMENT ON TABLE core.dim_seller       IS 'Продавцы. Зерно: продавец';
COMMENT ON TABLE core.dim_customer     IS 'Покупатели. Зерно: человек (customer_unique_id), а не customer_id заказа';
COMMENT ON TABLE core.fact_order       IS 'Заказы. Зерно: заказ. Суммы по позициям и платежам посчитаны заранее';
COMMENT ON TABLE core.fact_order_item  IS 'Позиции заказов. Зерно: одна единица товара (order_id, order_item_id)';
COMMENT ON TABLE core.fact_payment     IS 'Платежи. Зерно: платёж внутри заказа (order_id, payment_sequential)';
COMMENT ON TABLE core.fact_review      IS 'Отзывы. Зерно: пара (review_id, order_id); оценка заказа — строка с is_latest_for_order';

COMMENT ON COLUMN core.fact_order.customer_key    IS 'Ключ покупателя-человека = customer_unique_id';
COMMENT ON COLUMN core.fact_order.customer_id_src IS 'Исходный customer_id: выдаётся на каждый заказ, для подсчёта покупателей не годится';
COMMENT ON COLUMN core.fact_order.units_cnt       IS 'Единиц товара: каждая строка order_items — одна единица';
COMMENT ON COLUMN core.fact_order.lines_cnt       IS 'Строк заказа: разных пар товар x продавец';
COMMENT ON COLUMN core.fact_order.items_price_amt IS 'Сумма цен товаров без доставки — это выручка, если статус is_revenue';
COMMENT ON COLUMN core.fact_order.is_late         IS 'Вручён позже обещанной даты. NULL — заказ не вручён';
COMMENT ON COLUMN core.fact_order_item.seller_shipped_late IS
    'Передан в доставку позже крайнего срока. Дата передачи в источнике одна на заказ, поэтому в заказах с несколькими продавцами признак приблизительный';


-- =====================================================================
-- 40. Журнал качества данных
-- =====================================================================
-- Странные строки не выбрасываются, а помечаются: здесь видно, что
-- именно не так и сколько таких.

CREATE TABLE core.dq_issue (
    entity      text NOT NULL,
    entity_id   text NOT NULL,
    issue_code  text NOT NULL,
    details     text
);

COMMENT ON TABLE core.dq_issue IS 'Журнал найденных проблем в данных. Строки помечены, а не удалены';

INSERT INTO core.dq_issue
SELECT 'order', order_id, 'no_items', status FROM core.fact_order WHERE NOT has_items
UNION ALL
SELECT 'order', order_id, 'no_payment', status FROM core.fact_order WHERE NOT has_payment
UNION ALL
SELECT 'order', order_id, 'delivered_without_date', NULL
FROM core.fact_order WHERE status = 'delivered' AND delivered_customer_at IS NULL
UNION ALL
SELECT 'order', order_id, 'dates_inconsistent', NULL FROM core.fact_order WHERE dq_dates_inconsistent
UNION ALL
SELECT 'order', order_id, 'amount_mismatch',
       format('items %s, payments %s', items_price_amt + items_freight_amt, payment_amt)
FROM core.fact_order WHERE dq_amount_mismatch
UNION ALL
SELECT 'order_status', status, 'unknown_status', NULL FROM core.dim_order_status WHERE NOT is_known
UNION ALL
SELECT 'payment_type', payment_type, 'unknown_payment_type', NULL FROM core.dim_payment_type WHERE NOT is_known
UNION ALL
SELECT 'product', product_id, 'no_category', NULL FROM core.dim_product WHERE category_name = 'unknown'
UNION ALL
SELECT 'category', category_name, 'no_translation', NULL
FROM core.dim_category WHERE NOT is_translated AND NOT is_unknown
UNION ALL
SELECT 'payment', order_id || '/' || payment_sequential, 'type_not_defined', NULL
FROM core.fact_payment WHERE payment_type = 'not_defined'
UNION ALL
SELECT 'payment', order_id || '/' || payment_sequential, 'zero_installments', payment_type
FROM core.fact_payment WHERE installments_cnt = 0;


-- =====================================================================
-- 50. Самопроверки: ничего не потеряли, не размножили, зерно соблюдено
-- =====================================================================

DO $$
DECLARE
    r record;
BEGIN
    -- 1. Число строк: raw = core
    FOR r IN
        SELECT * FROM (VALUES
            ('orders',      (SELECT count(*) FROM raw.orders),         (SELECT count(*) FROM core.fact_order)),
            ('order_items', (SELECT count(*) FROM raw.order_items),    (SELECT count(*) FROM core.fact_order_item)),
            ('payments',    (SELECT count(*) FROM raw.order_payments), (SELECT count(*) FROM core.fact_payment)),
            ('reviews',     (SELECT count(*) FROM raw.order_reviews),  (SELECT count(*) FROM core.fact_review)),
            ('products',    (SELECT count(*) FROM raw.products),       (SELECT count(*) FROM core.dim_product)),
            ('sellers',     (SELECT count(*) FROM raw.sellers),        (SELECT count(*) FROM core.dim_seller)),
            ('customers',   (SELECT count(DISTINCT customer_unique_id) FROM raw.customers),
                            (SELECT count(*) FROM core.dim_customer))
        ) AS t(name, raw_cnt, core_cnt)
    LOOP
        IF r.raw_cnt <> r.core_cnt THEN
            RAISE EXCEPTION 'Сверка строк %: в raw %, в core %', r.name, r.raw_cnt, r.core_cnt;
        END IF;
    END LOOP;

    -- 2. Деньги: суммы в raw = суммам в агрегатах заказа
    IF (SELECT sum(price::numeric) FROM raw.order_items)
       <> (SELECT sum(items_price_amt) FROM core.fact_order) THEN
        RAISE EXCEPTION 'Сверка сумм: price в raw и в fact_order не совпадает';
    END IF;
    IF (SELECT sum(freight_value::numeric) FROM raw.order_items)
       <> (SELECT sum(items_freight_amt) FROM core.fact_order) THEN
        RAISE EXCEPTION 'Сверка сумм: freight в raw и в fact_order не совпадает';
    END IF;
    IF (SELECT sum(payment_value::numeric) FROM raw.order_payments)
       <> (SELECT sum(payment_amt) FROM core.fact_order) THEN
        RAISE EXCEPTION 'Сверка сумм: платежи в raw и в fact_order не совпадают';
    END IF;

    -- 3. Соединения со справочниками не теряют строк
    IF (SELECT count(*) FROM core.fact_order_item i
        JOIN core.dim_product p USING (product_id)
        JOIN core.dim_category c USING (category_name))
       <> (SELECT count(*) FROM core.fact_order_item) THEN
        RAISE EXCEPTION 'Сверка: позиции теряются при соединении с категориями';
    END IF;

    -- 4. Зерно покупателя: у каждого ровно один первый заказ,
    --    сумма заказов по покупателям = числу заказов
    IF (SELECT count(*) FROM core.fact_order WHERE customer_order_seq = 1)
       <> (SELECT count(*) FROM core.dim_customer)
       OR (SELECT sum(orders_cnt) FROM core.dim_customer)
       <> (SELECT count(*) FROM core.fact_order) THEN
        RAISE EXCEPTION 'Сверка: заказы и покупатели не сходятся';
    END IF;

    -- 5. Зерно отзыва: у каждого заказа с отзывами ровно один последний
    IF (SELECT count(*) FROM core.fact_review WHERE is_latest_for_order)
       <> (SELECT count(DISTINCT order_id) FROM core.fact_review) THEN
        RAISE EXCEPTION 'Сверка: у заказа не один последний отзыв';
    END IF;

    -- 6. Статусы: выручку дают только известные статусы
    IF EXISTS (SELECT 1 FROM core.dim_order_status WHERE is_revenue AND NOT is_known) THEN
        RAISE EXCEPTION 'Сверка: неизвестный статус помечен как выручка';
    END IF;
    -- 7. Заказ, дающий выручку, обязан иметь позиции, иначе он молча
    --    войдёт в отчёты с нулевой суммой
    IF EXISTS (SELECT 1 FROM core.fact_order f JOIN core.dim_order_status s USING (status)
               WHERE s.is_revenue AND NOT f.has_items) THEN
        RAISE EXCEPTION 'Сверка: есть заказы с выручкой без позиций, см. core.dq_issue (no_items)';
    END IF;

    IF EXISTS (SELECT 1 FROM core.dim_order_status WHERE NOT is_known) THEN
        RAISE WARNING 'В источнике есть статусы без правил, см. core.dq_issue (unknown_status)';
    END IF;
END $$;

COMMIT;

ANALYZE core.fact_order, core.fact_order_item, core.fact_payment, core.fact_review;

-- Итог сборки
SELECT 'fact_order' AS table_name, count(*) AS rows FROM core.fact_order
UNION ALL SELECT 'fact_order_item',  count(*) FROM core.fact_order_item
UNION ALL SELECT 'fact_payment',     count(*) FROM core.fact_payment
UNION ALL SELECT 'fact_review',      count(*) FROM core.fact_review
UNION ALL SELECT 'dim_customer',     count(*) FROM core.dim_customer
UNION ALL SELECT 'dim_product',      count(*) FROM core.dim_product
UNION ALL SELECT 'dim_seller',       count(*) FROM core.dim_seller
UNION ALL SELECT 'dim_category',     count(*) FROM core.dim_category
UNION ALL SELECT 'dim_payment_type', count(*) FROM core.dim_payment_type
UNION ALL SELECT 'dim_order_status', count(*) FROM core.dim_order_status
UNION ALL SELECT 'dim_date',         count(*) FROM core.dim_date;

SELECT issue_code, count(*) AS cnt FROM core.dq_issue GROUP BY 1 ORDER BY 2 DESC;
