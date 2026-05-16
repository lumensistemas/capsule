# capsule

Portable PHP dev container. Drop into any project directory, run `capsule`,
and you get a shell with PHP 8.3/8.4/8.5, your AI tooling, and your git
identity — without polluting the host.

## What's inside

| | |
|---|---|
| Base | Ubuntu 24.04 |
| PHP | 8.3, 8.4, 8.5 (Ondrej PPA) — switch via `php83` / `php84` / `php85` |
| Composer | latest |
| DB | sqlite3 |
| Shell | bash + tmux + neovim (latest) + LazyVim starter |
| AI CLIs | `claude` (Claude Code), `copilot` (GitHub Copilot CLI) |
| Git | `gh` (GitHub CLI), system `git`, signs commits via host GPG |
| Extras | ripgrep, fd, jq, build-essential |

## Install

```bash
git clone <this repo> ~/capsule
~/capsule/capsule --install        # symlinks ~/.local/bin/capsule
```

The repo can live anywhere — `--install` resolves the symlink back to the
clone, so `--build`, the first-run auto-build, and edits to `Dockerfile`
all keep working from any project directory.

First run from any project dir will build the image (`capsule:latest`).
Remove later with `capsule --uninstall`.

## Use

```bash
cd ~/projects/some-php-app
capsule                  # interactive shell, $PWD mounted at /workspace
capsule php artisan test # one-off command
capsule nvim .           # open the project in nvim
```

Flags:

- `--no-firewall` — disable the outbound allowlist (see below)
- `--voice` — forward host PulseAudio/PipeWire socket (see below)
- `--install` / `--uninstall` — manage the `~/.local/bin/capsule` symlink
- `--build` — force rebuild the image
- `--rm-volumes` — wipe persisted configs (Claude, gh, copilot, nvim, history)
- `--help`

Env overrides:

```bash
CAPSULE_NAME=mything capsule       # custom container name
CAPSULE_IMAGE=capsule:dev capsule  # use a different tag
CAPSULE_FIREWALL=0 capsule         # same as --no-firewall
CAPSULE_VOICE=1 capsule            # same as --voice
```

## Firewall (default ON)

The container starts with a default-deny outbound iptables policy and a
small allowlist:

- GitHub (web/api/git ranges from `api.github.com/meta`)
- Anthropic: `api.anthropic.com`, `console.anthropic.com`,
  `statsig.anthropic.com`, `statsig.com`, `sentry.io`
- GitHub Copilot: `api.githubcopilot.com`,
  `api.individual.githubcopilot.com`, `proxy.individual.githubcopilot.com`
- Package managers: `registry.npmjs.org`, `repo.packagist.org`, `getcomposer.org`
- DNS, SSH (port 22), loopback, your host LAN

The firewall script (`/usr/local/bin/capsule-firewall`) runs at container
start via passwordless `sudo` from the unprivileged `dev` user. The
launcher grants `NET_ADMIN` + `NET_RAW` capabilities only when the
firewall is enabled.

To extend the allowlist, edit `etc/firewall.sh` and rebuild
(`capsule --build`). To disable for a session, run `capsule --no-firewall`
(useful when grabbing a Composer dep from a non-allowlisted mirror, or
hitting a private registry).

If a tool inside the capsule fails to reach a host, it'll see ICMP
"administratively prohibited" — i.e. immediate `Connection refused` rather
than a hang.

## Switching PHP

Inside the capsule:

```
php83   # default PHP becomes 8.3 (alias for: switch-php 8.3)
php84
php85
php -v
```

The switch is system-wide via `update-alternatives` — composer, your editor,
and any tool calling `php` immediately see the new default.

## What persists across runs

Named volumes (`docker volume ls | grep capsule`):

| Volume | Mount | What |
|---|---|---|
| `capsule-claude` | `~/.claude` | Claude Code credentials & state |
| `capsule-gh` | `~/.config/gh` | gh auth token |
| `capsule-copilot` | `~/.config/github-copilot` | Copilot CLI auth |
| `capsule-nvim` | `~/.config/nvim` | LazyVim config (seeded from starter on first run) |
| `capsule-nvim-data` | `~/.local/share/nvim` | LazyVim plugins |
| `capsule-nvim-state` | `~/.local/state/nvim` | sessions, undo, swap |
| `capsule-history` | `~/.history` | persistent bash history |

Everything else (composer cache, npm cache, /tmp) is ephemeral by design —
the container is disposable.

## Voice / audio (opt-in)

`capsule --voice` forwards the host's PulseAudio/PipeWire socket into the
container so AI agents (or any tool inside) can use the mic and speakers.
The image ships `pulseaudio-utils`, `alsa-utils`, `sox`, and
`libsox-fmt-all`; the launcher mounts `$XDG_RUNTIME_DIR/pulse` and sets
`PULSE_SERVER`. Unix socket only, so the firewall is unaffected.

Quick test inside the capsule:

```bash
pactl info             # should show your host's audio server
parecord test.wav      # records from default input
paplay test.wav
```

If you see no pulse socket on the host (headless server, etc.), `--voice`
prints a warning and skips the mount.

## How git signing works

The launcher wires the host's identity into the container without touching
host state:

- `~/.gitconfig` — read-only mount, so commits use your name, email, and
  `user.signingkey`.
- `~/.ssh` — read-only mount, plus `$SSH_AUTH_SOCK` forwarded if present.
- **GPG via socket forwarding** — the host's `/run/user/$UID/gnupg/`
  directory (containing `S.gpg-agent`, `S.keyboxd`, etc.) is mounted into
  the container at the same path. The entrypoint symlinks each socket into
  `~/.gnupg/` so the container's `gpg` finds them. `~/.gnupg/common.conf`
  and `gpg.conf` are mounted read-only so the container uses the same
  backend (keyboxd vs legacy) as the host.

The container does **not** bind-mount `~/.gnupg` itself — that causes
keyring-lock contention with the running host `gpg-agent`, and
(historically) caused mount overlays to dump root-owned stub files into
the host's gnupg dir. All cryptographic operations happen on the host
agent; the container just talks to it.

`git commit -S`, `git push`, `gh auth login` work out of the box. Pinentry
is whatever your host has configured (GUI prompt, etc.) — you never see
pinentry inside the container.

**Requirement:** host UID must be 1000 (default for single-user Linux
desktops). If yours is different, override with `--build-arg USER_UID=…
USER_GID=…` when building, otherwise the forwarded sockets won't be
accessible due to UNIX permissions.

## Notes

- Runs as `dev` (UID 1000). Files created in `/workspace` come back owned
  by your host user (assuming host UID is 1000).
- `dev` has passwordless sudo for **one command only**:
  `/usr/local/bin/capsule-firewall`. There is no general-purpose root
  inside the container — to add packages, edit the `Dockerfile` and
  `capsule --build`.
- The container has no MariaDB/Redis/etc. — bring your own with
  `docker compose` alongside, or run a second `--network=host` container.
