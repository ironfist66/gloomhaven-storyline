# syntax=docker/dockerfile:1

FROM node:16.14.2-bullseye AS build

ARG MIX_MAIN_GAME=fh
ARG MIX_WEB_URL=
ARG MIX_APP_URL=
ARG MIX_API_URL=
ARG MIX_CDN_URL=
ARG MIX_SENTRY_DSN=
ARG MIX_STRIPE_KEY=
ARG MIX_PUSHER_KEY=
ARG MIX_PUSHER_APP_CLUSTER=
ARG MIX_VIRTUAL_BOARD_URL=
ARG MIX_GA_ID=

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

# Laravel Mix reads .env at build time; every MIX_* value below is inlined
# into the compiled JS bundle by webpack. Changing any of them requires a
# rebuild, not a container restart.
RUN printf '%s\n' \
      "MIX_MAIN_GAME=${MIX_MAIN_GAME}" \
      "MIX_WEB_URL=${MIX_WEB_URL}" \
      "MIX_APP_URL=${MIX_APP_URL}" \
      "MIX_API_URL=${MIX_API_URL}" \
      "MIX_CDN_URL=${MIX_CDN_URL}" \
      "MIX_SENTRY_DSN=${MIX_SENTRY_DSN}" \
      "MIX_STRIPE_KEY=${MIX_STRIPE_KEY}" \
      "MIX_PUSHER_KEY=${MIX_PUSHER_KEY}" \
      "MIX_PUSHER_APP_CLUSTER=${MIX_PUSHER_APP_CLUSTER}" \
      "MIX_VIRTUAL_BOARD_URL=${MIX_VIRTUAL_BOARD_URL}" \
      "MIX_GA_ID=${MIX_GA_ID}" \
      > .env

ENV NODE_OPTIONS=--max-old-space-size=4096
RUN npm run production

FROM nginx:1.27-alpine
COPY docker/nginx/default.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/public /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD wget -q --spider http://127.0.0.1/ || exit 1
