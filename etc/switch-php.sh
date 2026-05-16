#!/usr/bin/env bash
# capsule-switch-php — flip the system-wide default PHP via
# update-alternatives. Invoked through a narrow sudoers rule so the dev
# user can switch PHP versions without otherwise having root.
set -euo pipefail

v="${1:-}"
case "$v" in
    8.3|8.4|8.5) ;;
    *) echo "usage: $(basename "$0") <8.3|8.4|8.5>" >&2; exit 2 ;;
esac

if [ ! -x "/usr/bin/php${v}" ]; then
    echo "capsule: PHP ${v} is not installed in this image" >&2
    exit 1
fi

update-alternatives --set php "/usr/bin/php${v}" >/dev/null
for tool in phar phar.phar phpize php-config; do
    if [ -x "/usr/bin/${tool}${v}" ]; then
        update-alternatives --set "$tool" "/usr/bin/${tool}${v}" >/dev/null 2>&1 || true
    fi
done

echo "capsule: default PHP set to $(php -r 'echo PHP_VERSION;')"
