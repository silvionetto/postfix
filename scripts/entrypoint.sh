#!/bin/bash
# entrypoint.sh – Configure and start Postfix inside the container
set -e

# ── 1. Apply environment-variable overrides to main.cf ───────────────────────
# These let you inject runtime values via docker-compose without rebuilding.

if [[ -n "$POSTFIX_HOSTNAME" ]]; then
    postconf -e "myhostname = ${POSTFIX_HOSTNAME}"
fi

if [[ -n "$POSTFIX_DOMAIN" ]]; then
    postconf -e "mydomain = ${POSTFIX_DOMAIN}"
    postconf -e "virtual_alias_domains = ${POSTFIX_DOMAIN}"
fi

if [[ -n "$POSTFIX_MYNETWORKS" ]]; then
    postconf -e "mynetworks = ${POSTFIX_MYNETWORKS}"
fi

if [[ -n "$AGENT_WEBHOOK_URL" ]]; then
    # Patch the agent pipe URL in master.cf at runtime
    sed -i "s|http://agent:8000/inbound-email|${AGENT_WEBHOOK_URL}|g" \
        /etc/postfix/master.cf
fi

# ── 2. Build virtual alias map ────────────────────────────────────────────────
# By default, catch all mail for $mydomain and route it to the agent transport.
DOMAIN="${POSTFIX_DOMAIN:-example.com}"
VIRTUAL_FILE="/etc/postfix/virtual"
TRANSPORT_FILE="/etc/postfix/transport"

# Forward every address @domain to a local sink, then transport map takes over.
if [[ ! -f "$VIRTUAL_FILE" ]]; then
    cat > "$VIRTUAL_FILE" <<EOF
# Catch-all: forward all mail for the domain to the agent transport sink.
@${DOMAIN}    agent-sink@localhost
EOF
fi

# Route the sink address via the 'agent' pipe transport defined in master.cf.
if [[ ! -f "$TRANSPORT_FILE" ]]; then
    cat > "$TRANSPORT_FILE" <<EOF
agent-sink@localhost    agent:
EOF
fi

postmap "$VIRTUAL_FILE"
postmap "$TRANSPORT_FILE"

# ── 3. Check TLS certificates ─────────────────────────────────────────────────
CERT="/etc/postfix/tls/fullchain.pem"
KEY="/etc/postfix/tls/privkey.pem"

if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
    echo "⚠  WARNING: TLS cert/key not found at /etc/postfix/tls/."
    echo "   Generating a self-signed cert for testing. Replace with your real cert."
    mkdir -p /etc/postfix/tls
    openssl req -x509 -newkey rsa:4096 -nodes \
        -keyout "$KEY" -out "$CERT" -days 365 \
        -subj "/CN=${POSTFIX_HOSTNAME:-mail.example.com}"
fi

# ── 4. Fix permissions ────────────────────────────────────────────────────────
chown root:postfix /etc/postfix/tls/privkey.pem
chmod 640 /etc/postfix/tls/privkey.pem

# ── 5. Start Postfix ─────────────────────────────────────────────────────────
echo "✅  Starting Postfix (hostname: $(postconf -h myhostname))"
postfix check

# Postfix forks into background, so we tail the log to keep the container alive
# and surface logs to `docker logs`.
postfix start

echo "✅  Postfix started. Tailing mail log..."
exec tail -f /dev/null   # Replaced by maillog_file=/dev/stdout in main.cf
