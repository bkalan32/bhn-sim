FROM python:3.12-slim
RUN useradd --create-home --uid 10001 appuser
WORKDIR /app
COPY requirements.lock.txt requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
ARG APP_VERSION=0.1
ENV APP_VERSION=${APP_VERSION} \
    PYTHONUNBUFFERED=1
USER appuser
EXPOSE 8010
CMD ["opentelemetry-instrument", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8010", "--no-access-log"]
