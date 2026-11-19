# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------- build stage
FROM python:3.12-slim AS build

ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /build

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --upgrade pip \
 && /opt/venv/bin/pip install -r requirements.txt

# --------------------------------------------------------------- final stage
FROM python:3.12-slim AS final

# OCI labels - Defender for Cloud and ACR use these for traceability
ARG BUILD_VERSION=0.0.0
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="contoso-erp-api" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="https://dev.azure.com/contoso/erp" \
      org.opencontainers.image.vendor="Contoso Platform Engineering"

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    ERP_BUILD_VERSION=${BUILD_VERSION}

# Non-root user - enforced by the Azure Policy / Gatekeeper constraint
RUN groupadd --gid 10001 erp \
 && useradd --uid 10001 --gid erp --no-create-home --shell /usr/sbin/nologin erp \
 && apt-get update && apt-get upgrade -y \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/venv /opt/venv
WORKDIR /app
COPY --chown=10001:10001 app ./app

USER 10001:10001
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz/live',timeout=2).status==200 else 1)"

ENTRYPOINT ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips", "*"]
