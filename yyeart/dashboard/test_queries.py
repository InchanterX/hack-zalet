"""Integration checks against the documented local Capibara data load.

Run with CAPIBARA_DATABASE_URL set after building core.
"""

from __future__ import annotations

import os
import unittest
from datetime import date
from decimal import Decimal

import psycopg2

from queries import category_revenue, monthly, order_stats, repeat_stats, top_sellers


START = date(2016, 9, 1)
END_24 = date(2018, 9, 1)
END_ALL = date(2018, 11, 1)


@unittest.skipUnless(os.getenv("CAPIBARA_DATABASE_URL"), "CAPIBARA_DATABASE_URL is required")
class DashboardQueriesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.connection = psycopg2.connect(os.environ["CAPIBARA_DATABASE_URL"])
        cls.connection.set_session(readonly=True)

    @classmethod
    def tearDownClass(cls):
        cls.connection.close()

    def test_documented_period_and_full_history(self):
        months = monthly(self.connection, START, END_24)
        self.assertEqual(24, len(months))
        self.assertEqual(0, months[2]["order_count"])
        self.assertEqual(Decimal("0.00"), months[2]["revenue"])
        self.assertEqual(Decimal("13221498.11"), sum(row["revenue"] for row in months))
        self.assertEqual(99421, sum(row["order_count"] for row in months))

        orders = order_stats(self.connection, START, END_24)
        self.assertEqual(99421, orders["order_count"])
        self.assertEqual(Decimal("159.88"), orders["average_check"])

        repeats = repeat_stats(self.connection, START, END_24)
        self.assertEqual((96090, 2987, Decimal("3.11")), (
            repeats["buyer_count"], repeats["repeat_buyer_count"], repeats["repeat_share_pct"]
        ))
        full = repeat_stats(self.connection, START, END_ALL)
        self.assertEqual((96096, 2997, Decimal("3.12")), (
            full["buyer_count"], full["repeat_buyer_count"], full["repeat_share_pct"]
        ))

    def test_sellers_and_categories_reconcile_to_revenue(self):
        months = monthly(self.connection, START, END_24)
        revenue = sum(row["revenue"] for row in months)
        leaders = top_sellers(self.connection, START, END_24)
        self.assertEqual(Decimal("226987.93"), leaders[0]["revenue"])
        categories = category_revenue(self.connection, START, END_24)
        self.assertEqual(74, len(categories))
        self.assertEqual(revenue, sum(row["revenue"] for row in categories))
        unknown = next(row for row in categories if row["category_code"] is None)
        self.assertEqual("Неизвестно", unknown["category"])
        self.assertEqual(Decimal("170726.63"), unknown["revenue"])

        unknown_monthly = monthly(
            self.connection, START, END_24,
            category_selected=True, category_code=None,
        )
        self.assertEqual(
            unknown["revenue"], sum(row["revenue"] for row in unknown_monthly)
        )

    def test_seller_filter_does_not_change_order_grain(self):
        with self.connection.cursor() as cursor:
            cursor.execute(
                """SELECT min(i.seller_id)
                   FROM core.order_items i
                   JOIN core.orders o ON o.order_id = i.order_id
                   WHERE o.order_status = 'delivered'
                     AND o.purchased_at >= %s AND o.purchased_at < %s
                     AND i.order_id IN (
                         SELECT order_id FROM core.order_items
                         GROUP BY order_id HAVING count(DISTINCT seller_id) > 1
                     )""",
                (START, END_24),
            )
            seller_id = cursor.fetchone()[0]
            self.assertIsNotNone(seller_id)
            cursor.execute(
                """SELECT sum(i.price)
                   FROM core.order_items i
                   JOIN core.orders o ON o.order_id = i.order_id
                   WHERE o.order_status = 'delivered'
                     AND o.purchased_at >= %s AND o.purchased_at < %s
                     AND i.seller_id = %s""",
                (START, END_24, seller_id),
            )
            expected_revenue = cursor.fetchone()[0]

        selected_months = monthly(self.connection, START, END_24, seller_id=seller_id)
        self.assertEqual(expected_revenue, sum(row["revenue"] for row in selected_months))
        self.assertEqual(99421, sum(row["order_count"] for row in selected_months))
        self.assertEqual(Decimal("159.88"), order_stats(self.connection, START, END_24)["average_check"])

    def test_combined_seller_category_filter_keeps_category_denominator(self):
        leader = top_sellers(self.connection, START, END_24)[0]
        seller_id = leader["seller_id"]
        state = leader["seller_state"]
        seller_categories = category_revenue(
            self.connection, START, END_24, state, seller_id
        )
        selected = seller_categories[0]
        months = monthly(
            self.connection, START, END_24, state, seller_id,
            category_selected=True, category_code=selected["category_code"],
        )
        self.assertEqual(selected["revenue"], sum(row["revenue"] for row in months))
        self.assertEqual(99421, sum(row["order_count"] for row in months))
        self.assertEqual(
            selected["revenue_share_pct"],
            round(100 * selected["revenue"] / sum(row["revenue"] for row in seller_categories), 2),
        )
        self.assertEqual(
            selected["revenue"],
            top_sellers(
                self.connection, START, END_24, state, seller_id,
                True, selected["category_code"],
            )[0]["revenue"],
        )

    def test_empty_month_and_combined_filters(self):
        empty_month = monthly(self.connection, date(2016, 11, 1), date(2016, 12, 1))
        self.assertEqual(1, len(empty_month))
        self.assertEqual((0, Decimal("0.00")), (
            empty_month[0]["order_count"], empty_month[0]["revenue"]
        ))
        self.assertIsNone(order_stats(self.connection, date(2016, 11, 1), date(2016, 12, 1))["average_check"])
        self.assertIsNone(repeat_stats(self.connection, date(2016, 11, 1), date(2016, 12, 1))["repeat_share_pct"])

        selected = monthly(
            self.connection, START, END_24,
            state="SP", seller_id="not-a-seller", category_selected=True,
            category_code=None,
        )
        self.assertTrue(all(row["revenue"] == 0 for row in selected))
        self.assertEqual(99421, sum(row["order_count"] for row in selected))
        self.assertEqual([], top_sellers(
            self.connection, START, END_24, "SP", "not-a-seller", True, None
        ))
        self.assertEqual([], category_revenue(
            self.connection, START, END_24, "SP", "not-a-seller"
        ))


if __name__ == "__main__":
    unittest.main()
