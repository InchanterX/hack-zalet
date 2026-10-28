-- The check includes freight and is averaged at order level.
-- A line groups identical product and seller within an order; units are source item rows.
WITH item_totals AS (
    SELECT order_id,
           sum(price + freight_value) AS check_amount,
           count(*) AS item_units
    FROM core.order_items
    GROUP BY order_id
), line_totals AS (
    SELECT order_id, count(*) AS item_lines
    FROM (
        SELECT DISTINCT order_id, product_id, seller_id
        FROM core.order_items
    ) grouped_lines
    GROUP BY order_id
)
SELECT round(avg(coalesce(it.check_amount, 0)), 2) AS average_check,
       round(avg(coalesce(lt.item_lines, 0)), 2) AS average_lines,
       round(avg(coalesce(it.item_units, 0)), 2) AS average_units
FROM core.orders o
LEFT JOIN item_totals it ON it.order_id = o.order_id
LEFT JOIN line_totals lt ON lt.order_id = o.order_id
WHERE o.order_status = 'delivered';
