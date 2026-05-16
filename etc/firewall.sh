#!/usr/bin/env bash
# capsule-firewall — restrict outbound traffic to a small set of allowlisted
# hosts. Opt-in via `capsule --firewall` or CAPSULE_FIREWALL=1.
#
# Originally adapted from Anthropic's devcontainer reference firewall.
# Trimmed VS Code endpoints, added Composer + GitHub Copilot endpoints.
#
# Requires NET_ADMIN + NET_RAW caps on the container; granted by the launcher
# only when the firewall is requested.
set -euo pipefail
IFS=$'\n\t'

# 1. Capture Docker's embedded DNS rules (127.0.0.11) BEFORE we flush.
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Restore Docker's internal DNS rules so name resolution keeps working.
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# DNS, SSH, loopback (allowed before any restrictions take effect).
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT  -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

ipset create allowed-domains hash:net

# 3. GitHub IP ranges (web/api/git) — for gh, copilot OAuth, git over HTTPS.
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"; exit 1
fi
if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"; exit 1
fi

echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"; exit 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add -exist allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

# 4. Allowlisted domains (resolved at startup; if their IPs change later,
#    re-run the firewall by restarting the container).
ALLOWED_DOMAINS=(
    # Anthropic / Claude Code
    "api.anthropic.com"
    "console.anthropic.com"
    "statsig.com"
    "sentry.io"

    # GitHub Copilot CLI
    "api.githubcopilot.com"
    "api.individual.githubcopilot.com"
    "proxy.individual.githubcopilot.com"

    # Package managers
    "registry.npmjs.org"
    "repo.packagist.org"
    "getcomposer.org"
)

for domain in "${ALLOWED_DOMAINS[@]}"; do
    echo "Resolving $domain..."
    ips=$(dig +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
    if [ -z "$ips" ]; then
        echo "  warn: $domain returned no A records, skipping"
        continue
    fi
    while read -r ip; do
        echo "  adding $ip for $domain"
        ipset add -exist allowed-domains "$ip"
    done < <(echo "$ips")
done

# 5. Allow the host LAN (so `git push` to a self-hosted server, talking to
#    your IDE on localhost, etc., still works).
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"; exit 1
fi
HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"
iptables -A INPUT  -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# 6. Default-deny + allowlist match.
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# REJECT (rather than DROP) so blocked tools see immediate feedback.
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# 7. Verification.
echo "Firewall configuration complete; verifying..."
if curl --connect-timeout 5 -s https://example.com >/dev/null 2>&1; then
    echo "ERROR: firewall verification failed — example.com was reachable"
    exit 1
fi
echo "  ✓ example.com blocked as expected"

if ! curl --connect-timeout 5 -s https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: firewall verification failed — api.github.com unreachable"
    exit 1
fi
echo "  ✓ api.github.com reachable as expected"
echo "Firewall active."
