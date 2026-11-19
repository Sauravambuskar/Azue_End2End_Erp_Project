# syntax=docker/dockerfile:1.7
FROM python:3.12-slim AS build
WORKDIR /build
COPY requirements.txt .
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
 && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim AS final
ARG BUILD_VERSION=0.0.0
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="contoso-erp-worker" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}"
ENV PATH="/opt/venv/bin:$PATH" PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
RUN groupadd --gid 10001 erp \
 && useradd --uid 10001 --gid erp --no-create-home --shell /usr/sbin/nologin erp \
 && apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/venv /opt/venv
WORKDIR /app
COPY --chown=10001:10001 app ./app
USER 10001:10001
ENTRYPOINT ["python", "-m", "app.main"]
