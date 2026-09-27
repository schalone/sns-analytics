FROM python:3.12-slim
WORKDIR /app
COPY pyproject.toml README.md ./
COPY loaders ./loaders
COPY dbt ./dbt
COPY jobs/entrypoint.sh ./entrypoint.sh
RUN pip install --no-cache-dir -e . "dbt-bigquery>=1.12,<2" && cd dbt && dbt deps
ENV DBT_PROFILES_DIR=/app/dbt
ENTRYPOINT ["/app/entrypoint.sh"]
