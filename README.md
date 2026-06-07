# Postfix Docker – Inbound MX + Outbound Relay for AI Agent

## Architecture

```
Internet → port 25 → Postfix (STARTTLS) → pipe → curl POST → Agent (agentia network)
Agent    → port 587 → Postfix (encrypted) → direct MX delivery → recipient
```

Nginx on the host VM handles HTTPS for web apps. Postfix handles raw SMTP
independently on ports 25 and 587 — Nginx cannot proxy SMTP.

---

## Prerequisites

### 1. DNS Records

Add these to your domain's DNS:

```
; MX record – route inbound mail to your server
@         MX  10  mail.example.com.

; A record for the mail host
mail      A       <YOUR_SERVER_IP>

; PTR record (reverse DNS) – set in your VPS control panel, not in DNS zone
<IP>  →  mail.example.com

; SPF – authorise your server to send mail
@         TXT     "v=spf1 mx ~all"
```

### 2. Let's Encrypt Certificate

On the host VM (Certbot + Nginx):

```bash
certbot certonly --nginx -d mail.example.com
```

The compose file mounts the cert read-only into the container.

### 3. Firewall

Open ports on the host:

```bash
ufw allow 25/tcp
ufw allow 587/tcp
```

Port 443 (HTTPS) is already open for Nginx.

---

## Setup

### Step 1 – Edit docker-compose.yml

Replace all occurrences of `example.com` and `mail.example.com` with your real domain.

Set `AGENT_WEBHOOK_URL` to the actual URL of your agent container
(use the Docker container name as hostname, e.g. `http://my-agent:8000/inbound-email`).

Verify the `agent` Docker network exists:

```bash
docker network inspect agent
# Note the Subnet under IPAM.Config – update POSTFIX_MYNETWORKS if it differs
# from 172.20.0.0/16
```

### Step 2 – Build and start

```bash
docker compose up -d --build
```

### Step 3 – Verify

```bash
# Check Postfix is running and listening
docker exec postfix postfix status
docker exec postfix postconf -n        # show all non-default settings

# Send a test email from outside (use mail-tester.com or swaks)
swaks --to you@example.com --server mail.example.com --port 25 --tls

# Check your agent received the webhook POST
docker logs <your-agent-container>
```

---

## How Mail Flows

### Inbound (someone emails your agent)

1. Remote MTA connects to port 25, STARTTLS negotiated.
2. Postfix accepts mail for `@example.com`.
3. `virtual_alias_maps` rewrites the address to `agent-sink@localhost`.
4. `transport_maps` routes `agent-sink@localhost` via the `agent` pipe.
5. The `agent` pipe in `master.cf` runs `curl` and POSTs the raw RFC 822
   message to `http://agent:8000/inbound-email`.
6. Headers `X-Postfix-Sender` and `X-Postfix-Recipient` are added for routing.

### Outbound (agent sends reply)

Your agent connects to `postfix:587` and sends a standard SMTP message.
Because the agent is on the `agentia` network (trusted in `mynetworks`),
no authentication is needed. Postfix resolves the recipient's MX and delivers.

---

## Customising the Catch-All

To route specific addresses differently, edit `config/virtual`:

```
# /etc/postfix/virtual
support@example.com    agent-sink@localhost    # → agent webhook
admin@example.com      you@gmail.com           # → forward to personal email
@example.com           agent-sink@localhost    # catch-all → agent
```

Then rebuild the hash map and reload:

```bash
docker exec postfix postmap /etc/postfix/virtual
docker exec postfix postfix reload
```

---

## Sending Email from Your Agent (Python example)

```python
import smtplib
from email.mime.text import MIMEText

msg = MIMEText("Hello from your AI agent!")
msg["Subject"] = "Re: your question"
msg["From"]    = "agent@example.com"
msg["To"]      = "user@example.com"

# Connect to postfix container on the agentia network (port 587)
with smtplib.SMTP("postfix", 587) as smtp:
    smtp.starttls()
    # No login needed – agent IP is in mynetworks
    smtp.send_message(msg)
```

---

## Troubleshooting

```bash
# Live log tail
docker logs -f postfix

# Mail queue
docker exec postfix postqueue -p

# Retry stuck queue
docker exec postfix postqueue -f

# Test TLS on port 25
openssl s_client -starttls smtp -connect mail.example.com:25

# Test submission port from inside agentia network
docker run --rm --network agentia alpine/curl \
  swaks --to test@example.com --server postfix --port 587
```

### Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| Agent not receiving mail | Wrong webhook URL | Check `AGENT_WEBHOOK_URL` and container name |
| `Relay access denied` on 587 | Agent IP not in `mynetworks` | Update `POSTFIX_MYNETWORKS` with correct subnet |
| TLS cert errors | Wrong cert path | Check volume mounts in `docker-compose.yml` |
| Mail flagged as spam | Missing PTR/SPF | Set reverse DNS, add SPF TXT record |
| Port 25 blocked | Cloud provider block | Check VPS firewall; some providers block 25 by default |
