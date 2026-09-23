# mission-control — Day 21 API + Day 22 UI. One image ships both (PDF stack section).

# ---- stage 1: the UI. React + Vite + TypeScript -> static files. `npm run build` type-checks
# first, so a type error fails the pipeline's Build stage, not the browser.
FROM node:24-slim AS ui
WORKDIR /ui
COPY ui/package.json ui/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY ui/ ./
RUN npm run build

# ---- stage 2: the API. FastAPI + kubectl (pinned to the cluster's minor, argv lists only).
FROM python:3.12-slim

# kubectl: the executors' hands. The ServiceAccount's Role (k8s/mission-control.yaml) is the
# boundary; actions.py's verb allow-list is the second one.
ARG KUBECTL_VERSION=v1.37.0
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && ARCH="$(dpkg --print-architecture)" \
 && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" -o /usr/local/bin/kubectl \
 && chmod 0755 /usr/local/bin/kubectl \
 && apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 10004 appuser
WORKDIR /app
COPY requirements.lock.txt requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py actions.py config.py db.py events.py ./
# The built UI only — no node, no node_modules in the running image.
COPY --from=ui /ui/dist /app/ui/dist

ARG APP_VERSION=0.1
ENV APP_VERSION=${APP_VERSION} \
    PYTHONUNBUFFERED=1 \
    DATA_DIR=/data \
    UI_DIR=/app/ui/dist
RUN mkdir -p /data && chown appuser:appuser /data
USER appuser
EXPOSE 8040
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8040", "--no-access-log"]
