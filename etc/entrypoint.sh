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

# Match the default PHP to composer.json's require.php constraint — picks
# the lowest installed version that satisfies it, so `composer install` and
# `php artisan` line up with what the project actually targets. Composer's
# bundled Semver handles ^, ~, >=, ranges, and `||` alternatives.
if [ -f /workspace/composer.json ]; then
    constraint="$(jq -r '.require.php // empty' /workspace/composer.json 2>/dev/null || true)"
    if [ -n "$constraint" ]; then
        target="$(php -r '
            Phar::loadPhar("/usr/local/bin/composer", "composer.phar");
            require "phar://composer.phar/vendor/autoload.php";
            foreach (["8.3.0", "8.4.0", "8.5.0"] as $v) {
                if (Composer\Semver\Semver::satisfies($v, $argv[1])) {
                    echo substr($v, 0, 3);
                    exit;
                }
            }
        ' -- "$constraint" 2>/dev/null || true)"
        current="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || true)"
        if [ -n "$target" ] && [ "$target" != "$current" ]; then
            sudo /usr/local/bin/capsule-switch-php "$target" >/dev/null
            echo "capsule: composer.json requires php $constraint — default PHP set to $target"
        elif [ -z "$target" ]; then
            echo "capsule: warning — composer.json requires php $constraint, no installed PHP (8.3/8.4/8.5) satisfies it" >&2
        fi
    fi
fi

exec "$@"
