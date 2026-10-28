"""Local sales dashboard for the Capibara core model."""

from __future__ import annotations

import os
import sys
from contextlib import closing
from datetime import date
from decimal import Decimal
from pathlib import Path

import pandas as pd
import psycopg2
import streamlit as st

sys.path.insert(0, str(Path(__file__).resolve().parent))
from queries import (
    ZERO,
    categories,
    category_revenue,
    core_is_ready,
    month_bounds,
    monthly,
    order_stats,
    repeat_stats,
    seller_states,
    sellers,
    top_sellers,
)


st.set_page_config(page_title="Продажи Capibara", layout="wide")


def next_month(month: date) -> date:
    return date(month.year + (month.month == 12), month.month % 12 + 1, 1)


def months_between(first: date, last: date) -> list[date]:
    result = []
    current = first
    while current <= last:
        result.append(current)
        current = next_month(current)
    return result


def decimal_text(value: Decimal | None) -> str:
    if value is None:
        return "нет данных"
    return f"{value:,.2f}".replace(",", " ").replace(".", ",")


def integer_text(value: int) -> str:
    return f"{value:,}".replace(",", " ")


def percent_text(value: Decimal | None) -> str:
    return "нет данных" if value is None else f"{decimal_text(value)} %"


st.title("Продажи Capibara")
st.caption(
    "Выручка — цены товаров вручённых заказов без доставки. "
    "Число заказов и повторность включают все статусы; средний чек "
    "считает товары с доставкой на уровне вручённого заказа."
)

dsn = os.getenv("CAPIBARA_DATABASE_URL")
if not dsn:
    st.error(
        "Не задана CAPIBARA_DATABASE_URL. Укажите строку подключения к локальному "
        "PostgreSQL и запустите приложение снова; команда есть в yyeart/README.md."
    )
    st.stop()

try:
    with closing(psycopg2.connect(dsn, connect_timeout=5)) as connection:
        connection.set_session(readonly=True)
        if not core_is_ready(connection):
            st.error(
                "Схема core не собрана. Запустите yyeart/model/build_core.sql "
                "по инструкции в yyeart/README.md."
            )
            st.stop()

        bounds = month_bounds(connection)
        if bounds is None:
            st.info("В core.orders нет заказов. После загрузки данных обновите страницу.")
            st.stop()

        available_months = months_between(*bounds)
        default_first = date(2016, 9, 1)
        default_last = date(2018, 8, 1)
        first_index = available_months.index(default_first) if default_first in available_months else 0
        last_index = (
            available_months.index(default_last)
            if default_last in available_months
            else len(available_months) - 1
        )

        st.sidebar.header("Период")
        start = st.sidebar.selectbox(
            "С месяца", available_months, index=first_index,
            format_func=lambda value: value.strftime("%Y-%m"),
        )
        last = st.sidebar.selectbox(
            "По месяц", available_months, index=last_index,
            format_func=lambda value: value.strftime("%Y-%m"),
        )
        if start > last:
            st.warning("Месяц начала должен быть не позже месяца окончания.")
            st.stop()
        end_exclusive = next_month(last)

        st.sidebar.header("Товарные срезы")
        st.sidebar.caption("Влияют только на выручку, продавцов и категории.")
        state = st.sidebar.selectbox(
            "Штат продавца", [None, *seller_states(connection)],
            format_func=lambda value: "Все штаты" if value is None else value,
        )
        seller_rows = sellers(connection, state)
        seller_labels = {
            row["seller_id"]: f"{row['seller_id']} · {row['city'] or '—'}, {row['state'] or '—'}"
            for row in seller_rows
        }
        seller_id = st.sidebar.selectbox(
            "Продавец", [None, *seller_labels],
            format_func=lambda value: "Все продавцы" if value is None else seller_labels[value],
        )

        category_rows = categories(connection)
        category_choices = [("all", None)] + [
            ("category", row["category_code"]) for row in category_rows
        ]
        category_labels = {
            ("category", row["category_code"]): (
                f"{row['category']} · {row['category_code']}"
                if row["category_code"] is not None else "Неизвестно"
            )
            for row in category_rows
        }
        category_choice = st.sidebar.selectbox(
            "Категория", category_choices,
            format_func=lambda value: (
                "Все категории" if value[0] == "all" else category_labels[value]
            ),
        )
        category_selected = category_choice[0] == "category"
        category_code = category_choice[1]
        st.sidebar.button("Обновить данные")

        month_rows = monthly(
            connection, start, end_exclusive, state, seller_id,
            category_selected, category_code,
        )
        orders = order_stats(connection, start, end_exclusive)
        repeats = repeat_stats(connection, start, end_exclusive)
        leading_sellers = top_sellers(
            connection, start, end_exclusive, state, seller_id,
            category_selected, category_code,
        )
        all_category_sales = category_revenue(
            connection, start, end_exclusive, state, seller_id,
        )
except psycopg2.OperationalError:
    st.error(
        "Не удалось подключиться к PostgreSQL. Проверьте, что контейнер запущен "
        "и CAPIBARA_DATABASE_URL указывает на правильный порт."
    )
    st.stop()
except psycopg2.Error:
    st.error(
        "Не удалось прочитать core. Проверьте сборку модели и повторите запрос. "
        "При пересборке во время чтения обновите страницу после её завершения."
    )
    st.stop()

visible_categories = (
    [row for row in all_category_sales if row["category_code"] == category_code]
    if category_selected else all_category_sales
)
revenue = sum((row["revenue"] for row in month_rows), ZERO)

st.caption(
    f"Месяцы оформления: {start:%Y-%m} — {last:%Y-%m}. "
    "Товарные срезы меняют только выручку и её разрезы; "
    "число заказов, чек и повторность относятся ко всем заказам периода."
)

metric_revenue, metric_orders = st.columns(2)
metric_revenue.metric("Выручка товаров", decimal_text(revenue))
metric_orders.metric("Заказов, все статусы", integer_text(orders["order_count"]))
metric_check, metric_repeat = st.columns(2)
metric_check.metric("Средний чек вручённого заказа", decimal_text(orders["average_check"]))
metric_repeat.metric("Повторных покупателей", percent_text(repeats["repeat_share_pct"]))
st.caption(
    f"Покупателей за период: {integer_text(repeats['buyer_count'])}; "
    f"с двумя и более заказами: {integer_text(repeats['repeat_buyer_count'])}. "
    "Повторность пересчитывается после выбора периода."
)

st.subheader("Динамика по месяцам")
revenue_chart, orders_chart = st.columns(2)
with revenue_chart:
    st.caption("Выручка по выбранным товарным срезам")
    st.line_chart(pd.DataFrame([
        {"Месяц": row["month"].strftime("%Y-%m"), "Выручка": float(row["revenue"])}
        for row in month_rows
    ]), x="Месяц", y="Выручка")
with orders_chart:
    st.caption("Все заказы периода, независимо от товарных срезов")
    st.line_chart(pd.DataFrame([
        {"Месяц": row["month"].strftime("%Y-%m"), "Заказы": row["order_count"]}
        for row in month_rows
    ]), x="Месяц", y="Заказы")

st.subheader("Топ-10 продавцов по выручке")
st.caption("Заказы продавца считаются как различные order_id; единицы — строки order_items.")
if leading_sellers:
    st.dataframe(pd.DataFrame([
        {
            "Продавец": row["seller_id"],
            "Город": row["seller_city"],
            "Штат": row["seller_state"],
            "Заказов": row["order_count"],
            "Единиц": row["item_units"],
            "Выручка": decimal_text(row["revenue"]),
        }
        for row in leading_sellers
    ]), hide_index=True)
else:
    st.info("В выбранном срезе нет выручки вручённых заказов.")

st.subheader("Выручка по категориям")
st.caption(
    "Доля категории рассчитана от выручки за выбранный период и выбранных "
    "продавцов до фильтра категории. Категории сгруппированы по исходному коду."
)
if visible_categories:
    st.bar_chart(pd.DataFrame([
        {
            "Категория": (
                f"{row['category']} · {row['category_code']}"
                if row["category_code"] is not None else "Неизвестно"
            ),
            "Выручка": float(row["revenue"]),
        }
        for row in visible_categories[:10]
    ]), x="Категория", y="Выручка")
    st.dataframe(pd.DataFrame([
        {
            "Код": row["category_code"] or "—",
            "Категория": row["category"],
            "Выручка": decimal_text(row["revenue"]),
            "Доля": percent_text(row["revenue_share_pct"]),
        }
        for row in visible_categories
    ]), hide_index=True)
else:
    st.info("В выбранном срезе нет выручки по категориям.")

st.caption(
    "Выручку можно складывать по непересекающимся месяцам, продавцам и кодам "
    "категорий. Уникальные заказы, средний чек и доли по срезам складывать нельзя."
)
