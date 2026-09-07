FROM python:3.12-slim

RUN useradd --create-home --uid 10001 appuser
WORKDIR /app

COPY requirements.lock.txt requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py ai.py .

ARG APP_VERSION=0.1
ENV APP_VERSION=${APP_VERSION} \
    PYTHONUNBUFFERED=1 \
    DATA_DIR=/data

# The volume mount point must be writable by the non-root user. The PVC is mounted
# over /data at runtime and Kubernetes chowns it via fsGroup (see the manifest).
RUN mkdir -p /data && chown appuser:appuser /data

USER appuser
EXPOSE 8020
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8020", "--no-access-log"]
