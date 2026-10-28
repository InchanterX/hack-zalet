-- Group on the source category code so two codes cannot merge because of a shared label.
-- Missing category and missing translation remain visible.
WITH category_revenue AS (
    SELECT p.category_name AS category_code,
           coalesce(t.category_name_english, p.category_name, 'Неизвестно') AS category,
           sum(i.price) AS revenue
    FROM core.order_items i
    JOIN core.orders o ON o.order_id = i.order_id
    JOIN core.products p ON p.product_id = i.product_id
    LEFT JOIN core.category_translations t ON t.category_name = p.category_name
    WHERE o.order_status = 'delivered'
    GROUP BY p.category_name, t.category_name_english
)
SELECT category,
       revenue::numeric(14, 2) AS revenue,
       round(100 * revenue / sum(revenue) OVER (), 2) AS revenue_share_pct
FROM category_revenue
ORDER BY revenue DESC, category;
