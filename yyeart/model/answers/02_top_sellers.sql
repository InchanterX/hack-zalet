-- Revenue is attributed to the seller of each delivered item, not to the whole order.
SELECT i.seller_id,
       s.city AS seller_city,
       s.state AS seller_state,
       count(DISTINCT i.order_id) AS order_count,
       count(*) AS item_units,
       sum(i.price)::numeric(14, 2) AS revenue
FROM core.order_items i
JOIN core.orders o ON o.order_id = i.order_id
JOIN core.sellers s ON s.seller_id = i.seller_id
WHERE o.order_status = 'delivered'
GROUP BY i.seller_id, s.city, s.state
ORDER BY revenue DESC, i.seller_id
LIMIT 10;
