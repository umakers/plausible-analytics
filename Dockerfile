# we can not use the pre-built tar because the distribution is
# platform specific, it makes sense to build it in the docker

#### Builder
FROM hexpm/elixir:1.16.0-erlang-26.2.1-alpine-3.18.4 as buildcontainer

ARG MIX_ENV=small

# preparation
ENV MIX_ENV=$MIX_ENV
ENV NODE_ENV=production
ENV NODE_OPTIONS=--openssl-legacy-provider

# custom ERL_FLAGS are passed for (public) multi-platform builds
# to fix qemu segfault, more info: https://github.com/erlang/otp/pull/6340
ARG ERL_FLAGS
ENV ERL_FLAGS=$ERL_FLAGS

RUN mkdir /app
WORKDIR /app

# install build dependencies
RUN apk add --no-cache git nodejs yarn python3 npm ca-certificates wget gnupg make gcc libc-dev && \
  npm install npm@latest -g

COPY mix.exs ./
COPY mix.lock ./
COPY config ./config
RUN mix local.hex --force && \
  mix local.rebar --force && \
  mix deps.get --only prod && \
  mix deps.compile

COPY assets/package.json assets/package-lock.json ./assets/
COPY tracker/package.json tracker/package-lock.json ./tracker/

RUN npm install --prefix ./assets && \
  npm install --prefix ./tracker

COPY assets ./assets
COPY tracker ./tracker
COPY priv ./priv
COPY lib ./lib
COPY extra ./extra

RUN npm run deploy --prefix ./tracker && \
  mix assets.deploy && \
  mix phx.digest priv/static && \
  mix download_country_database && \
  mix sentry.package_source_code

WORKDIR /app
COPY rel rel
RUN mix release plausible

# Main Docker Image
FROM alpine:3.18.4
LABEL maintainer="plausible.io <hello@plausible.io>"

ARG BUILD_METADATA={}
ENV BUILD_METADATA=$BUILD_METADATA
ENV LANG=C.UTF-8
ARG MIX_ENV=small
ENV MIX_ENV=$MIX_ENV

RUN apk upgrade --no-cache

RUN apk add --no-cache openssl ncurses libstdc++ libgcc ca-certificates

COPY ./rel/docker-entrypoint.sh /entrypoint.sh

RUN chmod a+x /entrypoint.sh && \
  adduser -h /app -u 1000 -s /bin/sh -D plausibleuser

COPY --from=buildcontainer /app/_build/${MIX_ENV}/rel/plausible /app
RUN chown -R plausibleuser:plausibleuser /app
USER plausibleuser
WORKDIR /app
ENV LISTEN_IP=0.0.0.0
ENTRYPOINT ["/entrypoint.sh"]
EXPOSE 8000
CMD ["run"]
