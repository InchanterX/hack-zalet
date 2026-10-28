# Личное решение: модель `core`

Это самостоятельное решение задания [Capibara](docs/handout.md). В [ADR-0001](docs/adr/0001-normalized-core.md) объяснён выбор нормализованной модели; исходный запрос, ответы и основания отдельных решений сохранены в [рабочих заметках](docs/core/working-notes.md) и [журнале](docs/core/decision-log.md).

## Запуск

Работать из корня `hack-zalet`. Для первой загрузки `raw` использовать `bash scripts/setup.sh`, как указано в [README проекта](../README.md). Скрипт ниже пересобирает только принадлежащие решению объекты `core` в транзакции; исходный `raw` не меняется.

```bash
docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U hack -d marketplace -f /dev/stdin < yyeart/model/build_core.sql
docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U hack -d marketplace -f /dev/stdin < yyeart/model/validate_core.sql
```

Пять самостоятельных SQL-запросов находятся в [`model/answers/`](model/answers/). Их можно запускать так же, передавая нужный файл в `psql -f /dev/stdin`. Полные результаты текущего снимка сохранены в [`model/results/`](model/results/); сводка с числами — в [ответах](docs/core/answers.md).

## Локальный дашборд продаж

После загрузки `raw` и сборки `core` запустите [дашборд](dashboard/app.py). Ему нужен Python 3.11 или новее. Из корня `hack-zalet`:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r yyeart/dashboard/requirements.txt
export CAPIBARA_DATABASE_URL='postgresql://hack:hack@localhost:5432/marketplace'
.venv/bin/python -m streamlit run yyeart/dashboard/app.py --server.address 127.0.0.1
```

Если порт PostgreSQL изменён в `docker-compose.yml`, измените его и в `CAPIBARA_DATABASE_URL`. Приложение читает только `core`; значения обновляются при изменении фильтра или нажатии «Обновить данные». По умолчанию открыт период сентябрь 2016 — август 2018; доступные месяцы можно выбрать в боковой панели. Штат продавца, продавец и категория меняют только товарную выручку и её разрезы. Число заказов, средний чек и повторность считаются по всем заказам выбранного периода.

Проверка запросов на текущей локальной выгрузке:

```bash
.venv/bin/python -m unittest discover -s yyeart/dashboard -p test_queries.py -v
```

Тесты используют ту же переменную `CAPIBARA_DATABASE_URL` и сверяют опубликованные контрольные ответы. Выбранные по умолчанию 24 месяца дают 96 090 покупателей и 3,11% повторных; опубликованные 96 096 и 3,12% относятся ко всей выгрузке, включая заказы после августа 2018 года.

## Документы для сдачи

- [Ответы и проверка](docs/core/answers.md) — пять опубликованных вопросов и результаты из `core`.
- [Краткая записка](docs/core/decision-note.md) — выбор, альтернатива и сверка.
- [Дашборд продаж](dashboard/app.py) и [его концепция](docs/core/dashboard.md) — интерактивные показатели, формулы, уровни и аддитивность.
- [Стратегия развития](docs/core/growth.md) — новые сущности, история и масштабирование.
- [Глоссарий](GLOSSARY.md), [требования](docs/core/requirements.md), [сравнение вариантов](docs/core/comparison.md), [ADR-0001](docs/adr/0001-normalized-core.md) — основания для последующего объединения решений команды.
- [Схема базы данных](docs/core/README.md#схема-базы-данных) — рисунок таблиц `core` и их связей.

Пять будущих вопросов ещё не опубликованы в [tasks.md](docs/tasks.md); текущие ответы покрывают только доступную часть задания.
