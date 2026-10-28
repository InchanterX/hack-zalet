"""Read-only dashboard queries over the source-aligned core model.

All date ranges are [start_month, end_exclusive), with month boundaries.
Seller and category filters apply only to item-level sales queries.
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal

from psycopg2.extras import RealDictCursor


ZERO = Decimal("0.00")


def _one(connection, sql: str, params: dict | None = None) -> dict:
    with connection.cursor(cursor_factory=RealDictCursor) as cursor:
        cursor.execute(sql, params)
        return dict(cursor.fetchone())


def _all(connection, sql: str, params: dict | None = None) -> list[dict]:
    with connection.cursor(cursor_factory=RealDictCursor) as cursor:
        cursor.execute(sql, params)
        return [dict(row) for row in cursor.fetchall()]


def core_is_ready(connection) -> bool:
    row = _one(
        connection,
        """SELECT to_regclass('core.orders') IS NOT NULL
                  AND to_regclass('core.order_items') IS NOT NULL
                  AND to_regclass('core.customer_records') IS NOT NULL
                  AND to_regclass('core.products') IS NOT NULL
                  AND to_regclass('core.sellers') IS NOT NULL
                  AND to_regclass('core.category_translations') IS NOT NULL AS ready""",
    )
    return row["ready"]


def month_bounds(connection) -> tuple[date, date] | None:
    row = _one(
        connection,
        """SELECT date_trunc('month', min(purchased_at))::date AS first_month,
                  date_trunc('month', max(purchased_at))::date AS last_month
           FROM core.orders""",
    )
    if row["first_month"] is None:
        return None
    return row["first_month"], row["last_month"]


def seller_states(connection) -> list[str]:
    return [
        row["state"]
        for row in _all(
            connection,
            "SELECT DISTINCT state FROM core.sellers WHERE state IS NOT NULL ORDER BY state",
        )
    ]


def sellers(connection, state: str | None) -> list[dict]:
    return _all(
        connection,
        """SELECT seller_id, city, state
           FROM core.sellers
           WHERE (%(state)s IS NULL OR state = %(state)s)
           ORDER BY state, city, seller_id""",
        {"state": state},
    )


def categories(connection) -> list[dict]:
    return _all(
        connection,
        """SELECT DISTINCT p.category_name AS category_code,
                  coalesce(t.category_name_english, p.category_name, 'Неизвестно') AS category
           FROM core.products p
           LEFT JOIN core.category_translations t ON t.category_name = p.category_name
           ORDER BY category, category_code NULLS FIRST""",
    )


def monthly(
    connection,
    start: date,
    end_exclusive: date,
    state: str | None = None,
    seller_id: str | None = None,
    category_selected: bool = False,
    category_code: str | None = None,
) -> list[dict]:
    """Calendar, all-status orders, and delivered item revenue by purchase month."""
    return _all(
        connection,
        """WITH months AS (
               SELECT generate_series(
                   %(start)s::date,
                   %(end)s::date - interval '1 month',
                   interval '1 month'
               )::date AS month
           ), order_counts AS (
               SELECT date_trunc('month', purchased_at)::date AS month,
                      count(*) AS order_count
               FROM core.orders
               WHERE purchased_at >= %(start)s AND purchased_at < %(end)s
               GROUP BY 1
           ), sales AS (
               SELECT date_trunc('month', o.purchased_at)::date AS month,
                      sum(i.price) AS revenue
               FROM core.orders o
               JOIN core.order_items i ON i.order_id = o.order_id
               JOIN core.sellers s ON s.seller_id = i.seller_id
               JOIN core.products p ON p.product_id = i.product_id
               WHERE o.order_status = 'delivered'
                 AND o.purchased_at >= %(start)s AND o.purchased_at < %(end)s
                 AND (%(state)s IS NULL OR s.state = %(state)s)
                 AND (%(seller_id)s IS NULL OR i.seller_id = %(seller_id)s)
                 AND (NOT %(category_selected)s
                      OR p.category_name IS NOT DISTINCT FROM %(category_code)s)
               GROUP BY 1
           )
           SELECT m.month,
                  coalesce(oc.order_count, 0) AS order_count,
                  coalesce(s.revenue, 0)::numeric(14, 2) AS revenue
           FROM months m
           LEFT JOIN order_counts oc ON oc.month = m.month
           LEFT JOIN sales s ON s.month = m.month
           ORDER BY m.month""",
        {
            "start": start,
            "end": end_exclusive,
            "state": state,
            "seller_id": seller_id,
            "category_selected": category_selected,
            "category_code": category_code,
        },
    )


def order_stats(connection, start: date, end_exclusive: date) -> dict:
    """Count every order; average complete delivered order totals including freight."""
    return _one(
        connection,
        """WITH selected_orders AS (
               SELECT order_id, order_status
               FROM core.orders
               WHERE purchased_at >= %(start)s AND purchased_at < %(end)s
           ), item_totals AS (
               SELECT i.order_id, sum(i.price + i.freight_value) AS check_amount
               FROM core.order_items i
               JOIN selected_orders o ON o.order_id = i.order_id
               WHERE o.order_status = 'delivered'
               GROUP BY i.order_id
           )
           SELECT count(*) AS order_count,
                  round(avg(coalesce(it.check_amount, 0))
                        FILTER (WHERE o.order_status = 'delivered'), 2) AS average_check
           FROM selected_orders o
           LEFT JOIN item_totals it ON it.order_id = o.order_id""",
        {"start": start, "end": end_exclusive},
    )


def repeat_stats(connection, start: date, end_exclusive: date) -> dict:
    """Repeat buyers have at least two orders of any status within the period."""
    return _one(
        connection,
        """WITH buyer_orders AS (
               SELECT cr.customer_unique_id, count(*) AS order_count
               FROM core.orders o
               JOIN core.customer_records cr ON cr.customer_id = o.customer_id
               WHERE o.purchased_at >= %(start)s AND o.purchased_at < %(end)s
               GROUP BY cr.customer_unique_id
           )
           SELECT count(*) AS buyer_count,
                  count(*) FILTER (WHERE order_count >= 2) AS repeat_buyer_count,
                  round(
                      100.0 * count(*) FILTER (WHERE order_count >= 2)
                      / nullif(count(*), 0), 2
                  ) AS repeat_share_pct
           FROM buyer_orders""",
        {"start": start, "end": end_exclusive},
    )


def top_sellers(
    connection,
    start: date,
    end_exclusive: date,
    state: str | None = None,
    seller_id: str | None = None,
    category_selected: bool = False,
    category_code: str | None = None,
) -> list[dict]:
    return _all(
        connection,
        """SELECT i.seller_id, s.city AS seller_city, s.state AS seller_state,
                  count(DISTINCT i.order_id) AS order_count,
                  count(*) AS item_units,
                  sum(i.price)::numeric(14, 2) AS revenue
           FROM core.order_items i
           JOIN core.orders o ON o.order_id = i.order_id
           JOIN core.sellers s ON s.seller_id = i.seller_id
           JOIN core.products p ON p.product_id = i.product_id
           WHERE o.order_status = 'delivered'
             AND o.purchased_at >= %(start)s AND o.purchased_at < %(end)s
             AND (%(state)s IS NULL OR s.state = %(state)s)
             AND (%(seller_id)s IS NULL OR i.seller_id = %(seller_id)s)
             AND (NOT %(category_selected)s
                  OR p.category_name IS NOT DISTINCT FROM %(category_code)s)
           GROUP BY i.seller_id, s.city, s.state
           ORDER BY revenue DESC, i.seller_id
           LIMIT 10""",
        {
            "start": start,
            "end": end_exclusive,
            "state": state,
            "seller_id": seller_id,
            "category_selected": category_selected,
            "category_code": category_code,
        },
    )


def category_revenue(
    connection,
    start: date,
    end_exclusive: date,
    state: str | None = None,
    seller_id: str | None = None,
) -> list[dict]:
    """Category shares use the whole seller-filtered revenue before category filtering."""
    return _all(
        connection,
        """WITH totals AS (
               SELECT p.category_name AS category_code,
                      coalesce(t.category_name_english, p.category_name, 'Неизвестно') AS category,
                      sum(i.price)::numeric(14, 2) AS revenue
               FROM core.order_items i
               JOIN core.orders o ON o.order_id = i.order_id
               JOIN core.sellers s ON s.seller_id = i.seller_id
               JOIN core.products p ON p.product_id = i.product_id
               LEFT JOIN core.category_translations t ON t.category_name = p.category_name
               WHERE o.order_status = 'delivered'
                 AND o.purchased_at >= %(start)s AND o.purchased_at < %(end)s
                 AND (%(state)s IS NULL OR s.state = %(state)s)
                 AND (%(seller_id)s IS NULL OR i.seller_id = %(seller_id)s)
               GROUP BY p.category_name, t.category_name_english
           )
           SELECT category_code, category, revenue,
                  round(100 * revenue / nullif(sum(revenue) OVER (), 0), 2)
                      AS revenue_share_pct
           FROM totals
           ORDER BY revenue DESC, category_code NULLS FIRST""",
        {"start": start, "end": end_exclusive, "state": state, "seller_id": seller_id},
    )
