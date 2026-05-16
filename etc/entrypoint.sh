#!/usr/bin/env bash
# capsule entrypoint. Runs as the unprivileged `dev` user. The firewall
# (when enabled) is invoked via passwordless sudo.
set -e

if [ "${CAPSULE_FIREWALL:-1}" = "1" ]; then
    sudo /usr/local/bin/capsule-firewall
fi

if [ -d "$HOME/.gnupg" ]; then
    chmod 700 "$HOME/.gnupg" 2>/dev/null || true
fi

# Symlink the host's forwarded gpg/keyboxd sockets into ~/.gnupg so the
# container's gpg (whose compiled-in socketdir is the homedir) finds them.
host_sockdir="/run/user/$(id -u)/gnupg"
if [ -d "$host_sockdir" ]; then
    for s in S.gpg-agent S.gpg-agent.extra S.gpg-agent.ssh S.keyboxd S.dirmngr; do
        if [ -S "$host_sockdir/$s" ] && [ ! -e "$HOME/.gnupg/$s" ]; then
            ln -s "$host_sockdir/$s" "$HOME/.gnupg/$s"
        fi
    done
fi

exec "$@"
