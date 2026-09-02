FROM python:3.12-slim

# Non-root by default. Production clusters reject root containers, and finding that
# out on the day you deploy to a real cluster is a bad day.
RUN useradd --create-home --uid 10001 appuser

WORKDIR /app

# requirements first, so a code change does not re-run pip install on every build
COPY requirements.lock.txt requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

ARG APP_VERSION=0.3
ENV APP_VERSION=${APP_VERSION} \
    PYTHONUNBUFFERED=1

USER appuser
EXPOSE 8000
# --no-access-log: uvicorn's access log is plain text, not JSON, so it pollutes the
# log stream Fluent Bit ships and roughly DOUBLES your Splunk ingest volume for zero
# diagnostic value — the app already logs every outcome with more fields.
# Splunk trial AND free are both 500 MB/day, so this matters. (CORRECTIONS-DAY3.md B5)
# Day 4: `opentelemetry-instrument` wraps the process and auto-instruments FastAPI and
# outgoing HTTP calls. No tracing code in the app beyond reading the current span.
CMD ["opentelemetry-instrument", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
