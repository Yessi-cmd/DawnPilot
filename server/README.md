# DawnPilot server

This is a dependency-free Python 3.11 cache/proxy for Open-Meteo. It remembers a
bounded set of locations requested by the app, refreshes them periodically,
persists validated forecasts, and serves the last known good forecast
immediately while an expired entry refreshes in the background.

Only a semantically valid Forecast v1 response can replace cached data. Hourly
arrays must be non-empty and equal in length, timestamps must be unique,
strictly ordered and hour-aligned, and all weather values must be finite and in
their supported ranges. The upstream request uses GMT Unix epochs and converts
them to offset-bearing local ISO-8601 values, preserving both hours during a DST
fall-back transition.

## Security defaults

- Production startup is restricted to `127.0.0.1:8787`.
- `DAWNPILOT_TOKEN` must contain at least 32 non-whitespace characters, adequate
  character diversity, no short repeated pattern, and no known placeholder.
- `GET /healthz` is public and returns only `{"status":"ok"}` or a minimal
  degraded status.
- `GET /v1/forecast` requires `Authorization: Bearer <token>`.
- Request logs omit query strings so fixed coordinates do not enter journald.
- Cache files are atomically replaced with mode `0600`. The systemd unit also
  applies `UMask=0077` and creates `/var/lib/dawnpilot` with mode `0700`.

The bind and port are hard safety boundaries. Any value other than
`127.0.0.1:8787` makes startup fail, including in development.

## Debian 12 deployment

Run these commands as root after copying this `server` directory to a staging
location:

```bash
useradd --system --home /opt/dawnpilot --shell /usr/sbin/nologin dawnpilot
install -d -m 0755 -o root -g root /opt/dawnpilot
install -m 0755 dawnpilot_server.py /opt/dawnpilot/dawnpilot_server.py
install -m 0644 dawnpilot.service /etc/systemd/system/dawnpilot.service
install -m 0600 /dev/null /etc/dawnpilot.env
```

Generate the token directly into the protected environment file without
printing it:

```bash
umask 077
dawnpilot_token="$(openssl rand -hex 32)"
{
  printf 'DAWNPILOT_BIND=127.0.0.1\n'
  printf 'DAWNPILOT_PORT=8787\n'
  printf 'DAWNPILOT_TOKEN=%s\n' "$dawnpilot_token"
  printf 'DAWNPILOT_CACHE_TTL=900\n'
  printf 'DAWNPILOT_REFRESH_INTERVAL=1800\n'
  printf 'DAWNPILOT_UPSTREAM_TIMEOUT=15\n'
  printf 'DAWNPILOT_CACHE_FILE=/var/lib/dawnpilot/cache.json\n'
  printf 'DAWNPILOT_CACHE_MAX_ENTRIES=32\n'
  printf 'DAWNPILOT_CACHE_RETENTION=604800\n'
  printf 'DAWNPILOT_MAX_UPSTREAM_CONCURRENCY=2\n'
  printf 'DAWNPILOT_FAILURE_BACKOFF=60\n'
  printf 'DAWNPILOT_FAILURE_BACKOFF_MAX=900\n'
} > /etc/dawnpilot.env
unset dawnpilot_token
chmod 0600 /etc/dawnpilot.env
```

Validate the staged Python service before enabling it:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s server/tests -v
python3 -c 'from pathlib import Path; p=Path("/opt/dawnpilot/dawnpilot_server.py"); compile(p.read_text(), str(p), "exec")'
systemd-analyze verify /etc/systemd/system/dawnpilot.service
systemctl daemon-reload
systemctl enable --now dawnpilot
```

The service intentionally speaks HTTP only on loopback. Caddy or nginx must be
the sole public HTTPS entry point.

## Safe Caddy rollout

`Caddyfile.example` is a route fragment in a complete example site block. Merge
the `handle_path /dawnpilot/*` block into the existing domain block; do not
replace unrelated routes.

Before editing, record an unrelated route's expected response and create a
rollback copy:

```bash
curl -fsS https://example.com/existing-route > /tmp/existing-route.before
caddy_backup="/etc/caddy/Caddyfile.pre-dawnpilot.$(date +%Y%m%d%H%M%S)"
cp -a /etc/caddy/Caddyfile "$caddy_backup"
cp -a /etc/caddy/Caddyfile /etc/caddy/Caddyfile.dawnpilot.candidate
```

Edit `/etc/caddy/Caddyfile.dawnpilot.candidate`, merge the DawnPilot route, then
validate the candidate before installing or reloading it:

```bash
caddy fmt --overwrite /etc/caddy/Caddyfile.dawnpilot.candidate
caddy validate --config /etc/caddy/Caddyfile.dawnpilot.candidate --adapter caddyfile
install -m 0644 /etc/caddy/Caddyfile.dawnpilot.candidate /etc/caddy/Caddyfile
systemctl reload caddy
```

If validation or post-deployment verification fails, restore and validate the
saved file before reloading:

```bash
install -m 0644 "$caddy_backup" /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy
```

## Required deployment verification

Run every check after deployment. Do not paste the token into shell history or
print it. Read it silently for the authenticated check:

```bash
systemctl is-active --quiet dawnpilot
systemctl is-active --quiet caddy
systemctl show dawnpilot -p ActiveState -p SubState -p NRestarts
ss -ltnp '( sport = :8787 )'
curl -fsS https://example.com/dawnpilot/healthz
curl -sS -o /dev/null -w '%{http_code}\n' \
  'https://example.com/dawnpilot/v1/forecast?latitude=31.2304&longitude=121.4737&timezone=Asia%2FShanghai'
read -rsp 'DawnPilot bearer token: ' dawnpilot_token
printf '\n'
printf 'Authorization: Bearer %s\n' "$dawnpilot_token" \
  | curl -fsS -H @- \
  'https://example.com/dawnpilot/v1/forecast?latitude=31.2304&longitude=121.4737&timezone=Asia%2FShanghai' \
  | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["schema_version"] == 1; assert p["timezone"] == "Asia/Shanghai"; assert p["hourly"]'
unset dawnpilot_token
test "$(stat -c '%a' /var/lib/dawnpilot/cache.json)" = 600
curl -fsS https://example.com/existing-route > /tmp/existing-route.after
cmp /tmp/existing-route.before /tmp/existing-route.after
journalctl -u dawnpilot --since '-10 minutes' --no-pager
```

Confirm explicitly that:

- `ss` shows only `127.0.0.1:8787`, never `0.0.0.0:8787`;
- the unauthenticated forecast status is `401`;
- the authenticated command exits successfully without placing the token in
  shell history, curl arguments, or output;
- `NRestarts` is stable and the journal has no restart loop;
- the cache mode is exactly `0600`;
- the unrelated route is unchanged.

## Cache and failure behavior

- At most `DAWNPILOT_CACHE_MAX_ENTRIES` locations are retained using LRU order.
- Entries unused for `DAWNPILOT_CACHE_RETENTION` seconds are removed.
- Concurrent cold requests for one location share a single upstream fetch.
- Total upstream concurrency is capped by
  `DAWNPILOT_MAX_UPSTREAM_CONCURRENCY`.
- Expired known-good data is returned immediately with `stale: true`; refresh
  happens in the background.
- Failed refreshes use exponential backoff between
  `DAWNPILOT_FAILURE_BACKOFF` and `DAWNPILOT_FAILURE_BACKOFF_MAX`.
- One bad persisted entry is isolated instead of discarding other valid
  entries. Cache schema 1 is read for migration; new writes use internal cache
  schema 2. The public forecast schema remains version 1.
- A persistence failure changes `/healthz` to HTTP 503 with
  `{"status":"degraded"}` while in-memory forecasts remain available.

## Local development

Use the safe production bind defaults even locally:

```bash
export DAWNPILOT_TOKEN="$(openssl rand -hex 32)"
export DAWNPILOT_CACHE_FILE=/tmp/dawnpilot-cache.json
python3 server/dawnpilot_server.py
```

In another terminal:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s server/tests -v
```
