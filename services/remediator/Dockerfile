FROM python:3.12-slim

# kubectl, pinned. The remediator's "hands" are kubectl argv lists run as the pod's
# ServiceAccount — the Role in k8s/remediator.yaml is the permission boundary, not this
# binary. One minor version either side of the cluster is supported.
# Day 21: the cluster minor (was v1.32 — five minors outside the support window).
ARG KUBECTL_VERSION=v1.37.0
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && ARCH="$(dpkg --print-architecture)" \
 && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" -o /usr/local/bin/kubectl \
 && chmod 0755 /usr/local/bin/kubectl \
 && apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 10002 appuser
WORKDIR /app

COPY requirements.lock.txt requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py signatures.py state.py ./

ARG APP_VERSION=0.1
ENV APP_VERSION=${APP_VERSION} \
    PYTHONUNBUFFERED=1 \
    DATA_DIR=/data

# Day 21: proposals and cooldowns persist in /data/remediator.db. The PVC is mounted over
# /data at runtime; fsGroup 10002 in the manifest makes it writable by this user.
RUN mkdir -p /data && chown appuser:appuser /data

USER appuser
EXPOSE 8030
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8030", "--no-access-log"]
