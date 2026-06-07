FROM debian:bookworm-slim

LABEL maintainer="silvio.netto@gmail.com"
LABEL description="Postfix MTA – inbound MX + outbound relay for AI agent"

# ── System packages ──────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        postfix \
        libsasl2-modules \
        ca-certificates \
        openssl \
        rsyslog \
        mailutils \
    && rm -rf /var/lib/apt/lists/*

# ── Copy Postfix configuration files ─────────────────────────────────────────
COPY config/main.cf     /etc/postfix/main.cf
COPY config/master.cf   /etc/postfix/master.cf

# ── Copy entrypoint ───────────────────────────────────────────────────────────
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ── Postfix spool & state dirs ─────────────────────────────────────────────
RUN mkdir -p /var/spool/postfix /var/lib/postfix \
    && postfix set-permissions 2>/dev/null || true

# ── Ports ──────────────────────────────────────────────────────────────────
# 25  – SMTP inbound (external mail from internet)
# 587 – Submission (agent on agentia network sends outbound replies)
EXPOSE 25 587

ENTRYPOINT ["/entrypoint.sh"]
