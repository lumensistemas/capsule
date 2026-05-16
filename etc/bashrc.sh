# capsule.sh — sourced for interactive shells inside the capsule container.
# Lives at /etc/profile.d/capsule.sh in the image.

# --- Persistent bash history (mounted at ~/.history) ----------------------
mkdir -p "$HOME/.history"
export HISTFILE="$HOME/.history/bash_history"
export HISTSIZE=50000
export HISTFILESIZE=100000
export HISTCONTROL=ignoredups:erasedups
shopt -s histappend
case "$PROMPT_COMMAND" in
    *"history -a"*) : ;;
    *) PROMPT_COMMAND="history -a; ${PROMPT_COMMAND:-}" ;;
esac

# --- Default editor -------------------------------------------------------
export EDITOR=nvim
export VISUAL=nvim

# --- PHP version switcher -------------------------------------------------
# `php83`, `php84`, `php85` flip the default `php` (and `phar`, `phpize`,
# `php-config`) via update-alternatives. Affects every shell on the system,
# which is the point — your editor, composer, and tooling all see the new
# default immediately. Delegates to a tiny root-side wrapper exposed
# through a narrow sudoers rule (the dev user otherwise has no root).
switch-php() { sudo /usr/local/bin/capsule-switch-php "$@"; }

# Defined as functions (not aliases) so they also work in non-interactive
# shells, scripts, and through `sudo -E`.
php83() { switch-php 8.3; }
php84() { switch-php 8.4; }
php85() { switch-php 8.5; }

# --- Quality of life ------------------------------------------------------
alias ll='ls -alFh'
alias la='ls -A'
alias l='ls -CF'
alias fd='fdfind'
alias artisan='php artisan'

# --- Prompt ---------------------------------------------------------------
# Tag the prompt so it's obvious you're inside a capsule.
PS1='\[\e[35m\](capsule)\[\e[0m\] \[\e[36m\]\w\[\e[0m\] $ '
