-- Repeat order means at least two orders of any status by one stable buyer.
WITH buyer_orders AS (
    SELECT cr.customer_unique_id, count(*) AS order_count
    FROM core.orders o
    JOIN core.customer_records cr ON cr.customer_id = o.customer_id
    GROUP BY cr.customer_unique_id
)
SELECT count(*) AS buyer_count,
       count(*) FILTER (WHERE coalesce(bo.order_count, 0) >= 2) AS repeat_buyer_count,
       round(
           100.0 * count(*) FILTER (WHERE coalesce(bo.order_count, 0) >= 2)
           / nullif(count(*), 0),
           2
       ) AS repeat_share_pct
FROM core.buyers b
LEFT JOIN buyer_orders bo ON bo.customer_unique_id = b.customer_unique_id;
