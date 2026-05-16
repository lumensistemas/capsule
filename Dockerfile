FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG PHP_VERSIONS="8.3 8.4 8.5"
ARG USER_NAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
ARG NODE_MAJOR=22

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    TZ=Etc/UTC

# --- Base packages ---------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg gnupg2 software-properties-common \
        sudo locales tzdata \
        git tmux bash bash-completion less \
        sqlite3 \
        openssh-client pinentry-curses \
        unzip zip xz-utils \
        ripgrep fd-find jq \
        iptables ipset dnsutils aggregate iproute2 \
        build-essential pkg-config \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# --- PHP (8.3, 8.4, 8.5) via Ondrej PPA -----------------------------------
RUN add-apt-repository -y ppa:ondrej/php \
    && apt-get update \
    && for v in ${PHP_VERSIONS}; do \
         apt-get install -y --no-install-recommends \
            php${v}-cli php${v}-common php${v}-readline \
            php${v}-curl php${v}-mbstring php${v}-xml php${v}-zip \
            php${v}-sqlite3 php${v}-intl php${v}-bcmath php${v}-gd; \
         apt-get install -y --no-install-recommends php${v}-opcache 2>/dev/null \
            || echo "note: php${v}-opcache not available, skipping (likely bundled in -cli)"; \
       done \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --set php /usr/bin/php8.3

# --- Composer --------------------------------------------------------------
RUN curl -fsSL https://getcomposer.org/installer \
      | php -- --install-dir=/usr/local/bin --filename=composer

# --- Node.js (for Claude Code CLI + GitHub Copilot CLI) -------------------
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm config set update-notifier false

# --- GitHub CLI (gh) ------------------------------------------------------
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# --- Claude Code CLI + GitHub Copilot CLI ---------------------------------
RUN npm install -g @anthropic-ai/claude-code @github/copilot

# --- Neovim (latest stable release) ---------------------------------------
RUN ARCH="$(uname -m)" \
    && case "$ARCH" in \
         x86_64)  NVIM_ASSET=nvim-linux-x86_64.tar.gz ;; \
         aarch64) NVIM_ASSET=nvim-linux-arm64.tar.gz ;; \
         *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
       esac \
    && curl -fsSL -o /tmp/nvim.tar.gz \
        "https://github.com/neovim/neovim/releases/latest/download/${NVIM_ASSET}" \
    && tar -C /opt -xzf /tmp/nvim.tar.gz \
    && mv /opt/nvim-linux-* /opt/nvim \
    && ln -s /opt/nvim/bin/nvim /usr/local/bin/nvim \
    && rm /tmp/nvim.tar.gz

# --- Create dev user (replace stock ubuntu user that ships at UID 1000) ---
# Sudo is locked down to a small allowlist of capsule-* helper scripts.
# Anything else requires rebuilding the image — no ad-hoc `sudo apt install`.
RUN if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu 2>/dev/null || true; fi \
    && groupadd -g ${USER_GID} ${USER_NAME} \
    && useradd -m -u ${USER_UID} -g ${USER_GID} -s /bin/bash ${USER_NAME} \
    && printf '%s\n' \
        "${USER_NAME} ALL=(root) NOPASSWD: /usr/local/bin/capsule-firewall" \
        "${USER_NAME} ALL=(root) NOPASSWD: /usr/local/bin/capsule-switch-php" \
        > /etc/sudoers.d/${USER_NAME} \
    && chmod 0440 /etc/sudoers.d/${USER_NAME} \
    && visudo -cf /etc/sudoers.d/${USER_NAME}

# --- LazyVim starter (seeded into nvim config volume on first run) --------
RUN sudo -u ${USER_NAME} git clone --depth 1 https://github.com/LazyVim/starter \
        /home/${USER_NAME}/.config/nvim \
    && rm -rf /home/${USER_NAME}/.config/nvim/.git \
    && install -d -o ${USER_UID} -g ${USER_GID} \
        /home/${USER_NAME}/.local/share/nvim \
        /home/${USER_NAME}/.local/state/nvim \
        /home/${USER_NAME}/.claude \
        /home/${USER_NAME}/.config/gh \
        /home/${USER_NAME}/.config/github-copilot \
        /home/${USER_NAME}/.history \
    && install -d -o ${USER_UID} -g ${USER_GID} -m 0700 \
        /home/${USER_NAME}/.gnupg \
        /home/${USER_NAME}/.ssh \
    # Persist Claude Code's top-level state file by parking it inside the
    # capsule-claude volume via a symlink. Writes go to the volume; the
    # symlink itself is baked into the image.
    && ln -s /home/${USER_NAME}/.claude/.claude.json /home/${USER_NAME}/.claude.json \
    && chown -h ${USER_UID}:${USER_GID} /home/${USER_NAME}/.claude.json

# --- Bash setup -----------------------------------------------------------
COPY etc/bashrc.sh /etc/profile.d/capsule.sh
RUN echo '[ -f /etc/profile.d/capsule.sh ] && . /etc/profile.d/capsule.sh' \
        >> /home/${USER_NAME}/.bashrc \
    && chown ${USER_UID}:${USER_GID} /home/${USER_NAME}/.bashrc

# --- Entrypoint + helper scripts -----------------------------------------
COPY etc/entrypoint.sh /usr/local/bin/capsule-entrypoint
COPY etc/firewall.sh   /usr/local/bin/capsule-firewall
COPY etc/switch-php.sh /usr/local/bin/capsule-switch-php
RUN chmod +x /usr/local/bin/capsule-entrypoint \
            /usr/local/bin/capsule-firewall \
            /usr/local/bin/capsule-switch-php

USER ${USER_NAME}
WORKDIR /workspace
ENV HOME=/home/${USER_NAME} \
    SHELL=/bin/bash
ENTRYPOINT ["/usr/local/bin/capsule-entrypoint"]
CMD ["bash", "-l"]
