FROM docker.io/library/ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG USER_ID=1000
ARG GROUP_ID=1000
ARG NODE_VERSION=24.19.0

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN apt-get update \
    && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository --yes ppa:bartbes/love-stable \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        curl \
        fd-find \
        git \
        jq \
        less \
        procps \
        python3 \
        python3-pil \
        python3-numpy \
        ripgrep \
        shellcheck \
        unzip \
        xz-utils \
        luajit \
        love \
        libgl1 \
        libegl1 \
        libgl1-mesa-dri \
        libegl-mesa0 \
        libglx-mesa0 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /home/dev \
    && chown "${USER_ID}" /home/dev

ENV HOME=/home/dev
ENV XDG_CACHE_HOME=/home/dev/.cache
ENV XDG_CONFIG_HOME=/home/dev/.config
ENV XDG_DATA_HOME=/home/dev/.local/share
ENV XDG_STATE_HOME=/home/dev/.local/state
# The sandbox has no display and no GPU device, so LÖVE renders through SDL's
# offscreen video driver against Mesa's llvmpipe software rasterizer. libgl1 and
# libegl1 are the libglvnd dispatch libraries SDL dlopens; the mesa packages are
# the vendor implementations behind them. Drop any of the five and SDL fails with
# "Could not initialize OpenGL / GLES library".
ENV SDL_VIDEODRIVER=offscreen
ENV LIBGL_ALWAYS_SOFTWARE=1
# There is no audio device either. OpenAL Soft (LÖVE's audio backend) otherwise
# spends the startup enumerating ALSA devices that cannot open.
ENV SDL_AUDIODRIVER=dummy
ENV ALSOFT_DRIVERS=null
# Versions are pinned to the ones CI installs (.github/workflows/ci.yml). A
# formatter or analyzer that differs from CI's makes the pre-commit hook
# disagree with the binding gate.
ARG LUALS_VERSION=3.19.0
ARG STYLUA_VERSION=2.5.2
RUN set -eux \
    && curl -fsSL "https://github.com/LuaLS/lua-language-server/releases/download/${LUALS_VERSION}/lua-language-server-${LUALS_VERSION}-linux-x64.tar.gz" \
        -o /tmp/lua-language-server.tar.gz \
    && mkdir -p /opt/lua-language-server \
    && tar -xzf /tmp/lua-language-server.tar.gz -C /opt/lua-language-server \
    && printf '#!/bin/sh\nexec /opt/lua-language-server/bin/lua-language-server --metapath="${HOME:-/tmp}/.cache/lua-language-server/meta" "$@"\n' > /usr/local/bin/lua-language-server \
    && chmod 0755 /usr/local/bin/lua-language-server \
    && rm -rf /tmp/lua-language-server.tar.gz
RUN set -eux \
    && curl -fsSL "https://github.com/JohnnyMorganz/StyLua/releases/download/v${STYLUA_VERSION}/stylua-linux-x86_64.zip" \
        -o /tmp/stylua.zip \
    && unzip -j /tmp/stylua.zip stylua -d /usr/local/bin \
    && chmod 0755 /usr/local/bin/stylua \
    && rm -rf /tmp/stylua.zip
USER 1000:1000

WORKDIR /workspace
CMD ["cmd"]

