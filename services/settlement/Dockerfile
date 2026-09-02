FROM python:3.12-slim
RUN useradd --create-home --uid 10001 appuser
WORKDIR /app
COPY requirements.lock.txt requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY settle.py .
ARG APP_VERSION=0.1
ENV APP_VERSION=${APP_VERSION} PYTHONUNBUFFERED=1
USER appuser
CMD ["python", "settle.py"]
