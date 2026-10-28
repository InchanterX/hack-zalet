-- Diagnostic checks. Reading raw here is allowed for reconciliation;
-- the five analyst answers in answers/ read only core.

-- Every atomic core table must have exactly one row per source row.
WITH counts AS (
    SELECT 'customers' AS source, (SELECT count(*) FROM raw.customers) AS raw_rows,
           (SELECT count(*) FROM core.customer_records) AS core_rows
    UNION ALL SELECT 'orders', (SELECT count(*) FROM raw.orders),
           (SELECT count(*) FROM core.orders)
    UNION ALL SELECT 'order_items', (SELECT count(*) FROM raw.order_items),
           (SELECT count(*) FROM core.order_items)
    UNION ALL SELECT 'order_payments', (SELECT count(*) FROM raw.order_payments),
           (SELECT count(*) FROM core.payments)
    UNION ALL SELECT 'order_reviews', (SELECT count(*) FROM raw.order_reviews),
           (SELECT count(*) FROM core.reviews)
    UNION ALL SELECT 'products', (SELECT count(*) FROM raw.products),
           (SELECT count(*) FROM core.products)
    UNION ALL SELECT 'sellers', (SELECT count(*) FROM raw.sellers),
           (SELECT count(*) FROM core.sellers)
    UNION ALL SELECT 'product_category_translation',
           (SELECT count(*) FROM raw.product_category_translation),
           (SELECT count(*) FROM core.category_translations)
)
SELECT source, raw_rows, core_rows, raw_rows = core_rows AS passed
FROM counts
ORDER BY source;

-- Derived buyer count must equal the number of stable source IDs.
SELECT (SELECT count(DISTINCT customer_unique_id) FROM raw.customers) AS raw_buyers,
       (SELECT count(*) FROM core.buyers) AS core_buyers;

-- Explicitly expose incomplete source relationships and empty categories.
SELECT
    (SELECT count(*) FROM core.orders o
     WHERE NOT EXISTS (SELECT 1 FROM core.order_items i WHERE i.order_id = o.order_id))
       AS orders_without_items,
    (SELECT count(*) FROM core.orders o
     WHERE NOT EXISTS (SELECT 1 FROM core.payments p WHERE p.order_id = o.order_id))
       AS orders_without_payments,
    (SELECT count(*) FROM core.orders o
     WHERE NOT EXISTS (SELECT 1 FROM core.reviews r WHERE r.order_id = o.order_id))
       AS orders_without_reviews,
    (SELECT count(*) FROM core.products WHERE category_name IS NULL)
       AS products_without_category,
    (SELECT count(*) FROM core.products p
     WHERE p.category_name IS NOT NULL
       AND NOT EXISTS (
           SELECT 1 FROM core.category_translations t
           WHERE t.category_name = p.category_name
       )) AS products_without_translation;

-- Payment discrepancy is reported; source amounts are never adjusted.
WITH item_totals AS (
    SELECT order_id, sum(price + freight_value) AS amount
    FROM core.order_items GROUP BY order_id
), payment_totals AS (
    SELECT order_id, sum(payment_value) AS amount
    FROM core.payments GROUP BY order_id
)
SELECT count(*) AS orders_with_different_item_and_payment_totals
FROM item_totals i
JOIN payment_totals p ON p.order_id = i.order_id
WHERE i.amount <> p.amount;

-- Core money values must reconcile with raw after type conversion.
SELECT (SELECT sum(price::numeric) FROM raw.order_items) AS raw_item_price_sum,
       (SELECT sum(price) FROM core.order_items) AS core_item_price_sum,
       (SELECT sum(payment_value::numeric) FROM raw.order_payments) AS raw_payment_sum,
       (SELECT sum(payment_value) FROM core.payments) AS core_payment_sum;
