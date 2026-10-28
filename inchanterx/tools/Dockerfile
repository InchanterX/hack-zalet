# Образ стадий пайплайна (PLAN.md, 6.3): тот же postgres:16-alpine, что у базы,
# поэтому psql и pg_isready версии 16, а базовый слой уже скачан.
# git не нужен: всё, что связано с git, run.sh делает на хосте.
FROM postgres:16-alpine
RUN apk add --no-cache bash curl python3 py3-psycopg2 coreutils
# Точка входа образа postgres запускает сервер; нам нужна обычная команда.
ENTRYPOINT []
CMD ["bash"]
