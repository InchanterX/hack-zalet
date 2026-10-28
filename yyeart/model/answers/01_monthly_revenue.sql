-- Orders count every status; revenue counts item prices only for delivered orders.
-- The calendar guarantees a row for November 2016 even though it has no orders.
WITH months AS (
    SELECT generate_series(
        date '2016-09-01', date '2018-08-01', interval '1 month'
    )::date AS month
), order_counts AS (
    SELECT date_trunc('month', purchased_at)::date AS month,
           count(*) AS order_count
    FROM core.orders
    WHERE purchased_at >= date '2016-09-01'
      AND purchased_at < date '2018-09-01'
    GROUP BY 1
), revenue AS (
    SELECT date_trunc('month', o.purchased_at)::date AS month,
           sum(i.price) AS revenue
    FROM core.orders o
    JOIN core.order_items i ON i.order_id = o.order_id
    WHERE o.order_status = 'delivered'
      AND o.purchased_at >= date '2016-09-01'
      AND o.purchased_at < date '2018-09-01'
    GROUP BY 1
)
SELECT to_char(m.month, 'YYYY-MM') AS month,
       coalesce(oc.order_count, 0) AS order_count,
       coalesce(r.revenue, 0)::numeric(14, 2) AS revenue
FROM months m
LEFT JOIN order_counts oc ON oc.month = m.month
LEFT JOIN revenue r ON r.month = m.month
ORDER BY m.month;
