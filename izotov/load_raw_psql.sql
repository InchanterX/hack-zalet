-- Запасная загрузка raw без Python: CSV читаются psql внутри контейнера
-- из /data (папка data смонтирована в docker-compose.yml).
-- Штатный путь — scripts/setup.sh; этот нужен, если Python недоступен.
-- Вызывается из build.sh --load-raw.

\set ON_ERROR_STOP on

BEGIN;

TRUNCATE raw.orders, raw.order_items, raw.order_payments, raw.order_reviews,
         raw.products, raw.sellers, raw.customers, raw.product_category_translation;

\copy raw.orders(order_id,customer_id,order_status,order_purchase_timestamp,order_approved_at,order_delivered_carrier_date,order_delivered_customer_date,order_estimated_delivery_date) from '/data/olist_orders_dataset.csv' csv header
\copy raw.order_items(order_id,order_item_id,product_id,seller_id,shipping_limit_date,price,freight_value) from '/data/olist_order_items_dataset.csv' csv header
\copy raw.order_payments(order_id,payment_sequential,payment_type,payment_installments,payment_value) from '/data/olist_order_payments_dataset.csv' csv header
\copy raw.order_reviews(review_id,order_id,review_score,review_comment_title,review_comment_message,review_creation_date,review_answer_timestamp) from '/data/olist_order_reviews_dataset.csv' csv header
\copy raw.products(product_id,product_category_name,product_name_lenght,product_description_lenght,product_photos_qty,product_weight_g,product_length_cm,product_height_cm,product_width_cm) from '/data/olist_products_dataset.csv' csv header
\copy raw.sellers(seller_id,seller_zip_code_prefix,seller_city,seller_state) from '/data/olist_sellers_dataset.csv' csv header
\copy raw.customers(customer_id,customer_unique_id,customer_zip_code_prefix,customer_city,customer_state) from '/data/olist_customers_dataset.csv' csv header
\copy raw.product_category_translation(product_category_name,product_category_name_english) from '/data/product_category_name_translation.csv' csv header

UPDATE raw.orders                       SET _source_file = 'olist_orders_dataset.csv';
UPDATE raw.order_items                  SET _source_file = 'olist_order_items_dataset.csv';
UPDATE raw.order_payments               SET _source_file = 'olist_order_payments_dataset.csv';
UPDATE raw.order_reviews                SET _source_file = 'olist_order_reviews_dataset.csv';
UPDATE raw.products                     SET _source_file = 'olist_products_dataset.csv';
UPDATE raw.sellers                      SET _source_file = 'olist_sellers_dataset.csv';
UPDATE raw.customers                    SET _source_file = 'olist_customers_dataset.csv';
UPDATE raw.product_category_translation SET _source_file = 'product_category_name_translation.csv';

COMMIT;
