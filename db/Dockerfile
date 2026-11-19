# syntax=docker/dockerfile:1.7
# ===========================================================================
# Migration runner image.
#
# Built from the repo root so it can COPY db/. Runs inside the cluster as a
# Helm pre-upgrade hook, because the Flexible Server has no public endpoint.
#
# Note the identity model: this image authenticates with the erp-migrate
# managed identity, which is the ONLY identity holding DDL rights.
# ===========================================================================
FROM python:3.12-slim

ARG BUILD_VERSION=0.0.0
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="contoso-erp-migrate" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}"

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-client ca-certificates \
 && apt-get upgrade -y \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir azure-identity==1.19.0 \
 && groupadd --gid 10001 erp \
 && useradd --uid 10001 --gid erp --no-create-home --shell /usr/sbin/nologin erp

WORKDIR /app
COPY --chown=10001:10001 db/migrations ./migrations
COPY --chown=10001:10001 db/seed ./seed
COPY --chown=10001:10001 scripts/run-migrations.sh ./run-migrations.sh
RUN chmod +x ./run-migrations.sh

USER 10001:10001
ENTRYPOINT ["./run-migrations.sh"]
