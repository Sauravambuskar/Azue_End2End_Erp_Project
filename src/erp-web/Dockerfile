# syntax=docker/dockerfile:1.7
FROM node:20-alpine AS deps
WORKDIR /build
COPY package*.json ./
RUN npm ci --omit=dev --ignore-scripts

FROM node:20-alpine AS final
ARG BUILD_VERSION=0.0.0
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="contoso-erp-web" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}"
ENV NODE_ENV=production ERP_BUILD_VERSION=${BUILD_VERSION}
RUN apk upgrade --no-cache && apk add --no-cache dumb-init
WORKDIR /app
COPY --from=deps --chown=node:node /build/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node src ./src
COPY --chown=node:node public ./public
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000/healthz/live').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
ENTRYPOINT ["dumb-init", "node", "src/server.js"]
