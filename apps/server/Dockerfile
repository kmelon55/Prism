# syntax=docker/dockerfile:1
ARG PRISM_BUILD_DNS=default
FROM node:24-bookworm-slim AS dependencies
WORKDIR /app
COPY package*.json ./

FROM dependencies AS dependencies-default
RUN npm ci

# Optional resolver override for hosts whose LAN DNS cannot be reached from the build bridge.
# This read-only mount exists only during dependency installation.
FROM dependencies AS dependencies-public
RUN --mount=type=bind,source=build-resolv.conf,target=/etc/resolv.conf npm ci

FROM dependencies-${PRISM_BUILD_DNS} AS build
COPY . .
RUN npm run build

FROM node:24-bookworm-slim
ENV NODE_ENV=production HOST=0.0.0.0 PORT=3000
WORKDIR /app
COPY --from=build --chown=node:node /app/.output ./.output
USER node
EXPOSE 3000
CMD ["node", ".output/server/index.mjs"]
