-- Rebuild the personal, source-aligned core model from raw.
-- Run: docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U hack -d marketplace -f /dev/stdin < yyeart/model/build_core.sql
-- PostgreSQL DDL is transactional: a failed cast, key, or reference leaves the previous core model intact.

BEGIN ISOLATION LEVEL REPEATABLE READ;

CREATE SCHEMA IF NOT EXISTS core;

DROP VIEW IF EXISTS core.source_map;
DROP TABLE IF EXISTS
    core.order_items,
    core.payments,
    core.reviews,
    core.orders,
    core.customer_records,
    core.buyers,
    core.products,
    core.sellers,
    core.category_translations;

CREATE TABLE core.buyers (
    customer_unique_id text PRIMARY KEY
);

CREATE TABLE core.customer_records (
    customer_id text PRIMARY KEY,
    customer_unique_id text NOT NULL REFERENCES core.buyers (customer_unique_id),
    zip_code_prefix text,
    city text,
    state text
);

CREATE TABLE core.orders (
    order_id text PRIMARY KEY,
    customer_id text NOT NULL REFERENCES core.customer_records (customer_id),
    order_status text NOT NULL,
    purchased_at timestamp NOT NULL,
    approved_at timestamp,
    delivered_to_carrier_at timestamp,
    delivered_to_customer_at timestamp,
    estimated_delivery_at timestamp
);

CREATE TABLE core.products (
    product_id text PRIMARY KEY,
    category_name text,
    name_length integer,
    description_length integer,
    photos_qty integer,
    weight_g integer,
    length_cm integer,
    height_cm integer,
    width_cm integer
);

CREATE TABLE core.sellers (
    seller_id text PRIMARY KEY,
    zip_code_prefix text,
    city text,
    state text
);

CREATE TABLE core.category_translations (
    category_name text PRIMARY KEY,
    category_name_english text
);

CREATE TABLE core.order_items (
    order_id text NOT NULL REFERENCES core.orders (order_id),
    order_item_id text NOT NULL,
    item_ordinal integer NOT NULL,
    product_id text NOT NULL REFERENCES core.products (product_id),
    seller_id text NOT NULL REFERENCES core.sellers (seller_id),
    shipping_limit_at timestamp,
    price numeric(12, 2) NOT NULL,
    freight_value numeric(12, 2) NOT NULL,
    PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE core.payments (
    order_id text NOT NULL REFERENCES core.orders (order_id),
    payment_sequential text NOT NULL,
    payment_ordinal integer NOT NULL,
    payment_type text NOT NULL,
    payment_installments integer,
    payment_value numeric(12, 2) NOT NULL,
    PRIMARY KEY (order_id, payment_sequential)
);

CREATE TABLE core.reviews (
    review_id text NOT NULL,
    order_id text NOT NULL REFERENCES core.orders (order_id),
    review_score smallint NOT NULL CHECK (review_score BETWEEN 1 AND 5),
    comment_title text,
    comment_message text,
    created_at timestamp,
    answered_at timestamp,
    PRIMARY KEY (review_id, order_id)
);

INSERT INTO core.buyers (customer_unique_id)
SELECT DISTINCT nullif(btrim(customer_unique_id), '')
FROM raw.customers;

INSERT INTO core.customer_records (
    customer_id, customer_unique_id, zip_code_prefix, city, state
)
SELECT
    nullif(btrim(customer_id), ''),
    nullif(btrim(customer_unique_id), ''),
    nullif(btrim(customer_zip_code_prefix), ''),
    nullif(btrim(customer_city), ''),
    nullif(btrim(customer_state), '')
FROM raw.customers;

INSERT INTO core.orders (
    order_id, customer_id, order_status, purchased_at, approved_at,
    delivered_to_carrier_at, delivered_to_customer_at, estimated_delivery_at
)
SELECT
    nullif(btrim(order_id), ''),
    nullif(btrim(customer_id), ''),
    nullif(btrim(order_status), ''),
    nullif(btrim(order_purchase_timestamp), '')::timestamp,
    nullif(btrim(order_approved_at), '')::timestamp,
    nullif(btrim(order_delivered_carrier_date), '')::timestamp,
    nullif(btrim(order_delivered_customer_date), '')::timestamp,
    nullif(btrim(order_estimated_delivery_date), '')::timestamp
FROM raw.orders;

INSERT INTO core.products (
    product_id, category_name, name_length, description_length,
    photos_qty, weight_g, length_cm, height_cm, width_cm
)
SELECT
    nullif(btrim(product_id), ''),
    nullif(btrim(product_category_name), ''),
    nullif(btrim(product_name_lenght), '')::integer,
    nullif(btrim(product_description_lenght), '')::integer,
    nullif(btrim(product_photos_qty), '')::integer,
    nullif(btrim(product_weight_g), '')::integer,
    nullif(btrim(product_length_cm), '')::integer,
    nullif(btrim(product_height_cm), '')::integer,
    nullif(btrim(product_width_cm), '')::integer
FROM raw.products;

INSERT INTO core.sellers (seller_id, zip_code_prefix, city, state)
SELECT
    nullif(btrim(seller_id), ''),
    nullif(btrim(seller_zip_code_prefix), ''),
    nullif(btrim(seller_city), ''),
    nullif(btrim(seller_state), '')
FROM raw.sellers;

INSERT INTO core.category_translations (category_name, category_name_english)
SELECT
    nullif(btrim(product_category_name), ''),
    nullif(btrim(product_category_name_english), '')
FROM raw.product_category_translation;

INSERT INTO core.order_items (
    order_id, order_item_id, item_ordinal, product_id, seller_id,
    shipping_limit_at, price, freight_value
)
SELECT
    nullif(btrim(order_id), ''),
    nullif(btrim(order_item_id), ''),
    nullif(btrim(order_item_id), '')::integer,
    nullif(btrim(product_id), ''),
    nullif(btrim(seller_id), ''),
    nullif(btrim(shipping_limit_date), '')::timestamp,
    nullif(btrim(price), '')::numeric(12, 2),
    nullif(btrim(freight_value), '')::numeric(12, 2)
FROM raw.order_items;

INSERT INTO core.payments (
    order_id, payment_sequential, payment_ordinal,
    payment_type, payment_installments, payment_value
)
SELECT
    nullif(btrim(order_id), ''),
    nullif(btrim(payment_sequential), ''),
    nullif(btrim(payment_sequential), '')::integer,
    nullif(btrim(payment_type), ''),
    nullif(btrim(payment_installments), '')::integer,
    nullif(btrim(payment_value), '')::numeric(12, 2)
FROM raw.order_payments;

INSERT INTO core.reviews (
    review_id, order_id, review_score, comment_title,
    comment_message, created_at, answered_at
)
SELECT
    nullif(btrim(review_id), ''),
    nullif(btrim(order_id), ''),
    nullif(btrim(review_score), '')::smallint,
    nullif(btrim(review_comment_title), ''),
    nullif(btrim(review_comment_message), ''),
    nullif(btrim(review_creation_date), '')::timestamp,
    nullif(btrim(review_answer_timestamp), '')::timestamp
FROM raw.order_reviews;

CREATE INDEX customer_records_buyer_idx ON core.customer_records (customer_unique_id);
CREATE INDEX orders_purchase_idx ON core.orders (purchased_at);
CREATE INDEX orders_status_idx ON core.orders (order_status);
CREATE INDEX order_items_product_idx ON core.order_items (product_id);
CREATE INDEX order_items_seller_idx ON core.order_items (seller_id);
CREATE INDEX reviews_order_idx ON core.reviews (order_id);

CREATE VIEW core.source_map AS
SELECT core_table, raw_table, source_key
FROM (VALUES
    ('buyers', 'raw.customers', 'customer_unique_id (derived DISTINCT)'),
    ('customer_records', 'raw.customers', 'customer_id'),
    ('orders', 'raw.orders', 'order_id'),
    ('order_items', 'raw.order_items', 'order_id, order_item_id'),
    ('payments', 'raw.order_payments', 'order_id, payment_sequential'),
    ('reviews', 'raw.order_reviews', 'review_id, order_id'),
    ('products', 'raw.products', 'product_id'),
    ('sellers', 'raw.sellers', 'seller_id'),
    ('category_translations', 'raw.product_category_translation', 'product_category_name')
) AS mapping(core_table, raw_table, source_key);

COMMIT;
