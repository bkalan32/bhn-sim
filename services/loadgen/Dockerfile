# loadgen — stdlib Python, no dependencies, no shell access to anything. Day 21.
FROM python:3.12-slim
RUN useradd --create-home --uid 10003 appuser
WORKDIR /app
COPY loadgen.py ./
ARG APP_VERSION=0.1
ENV APP_VERSION=${APP_VERSION} \
    PYTHONUNBUFFERED=1
USER appuser
CMD ["python", "loadgen.py"]
