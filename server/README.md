# DawnPilot server

This is a dependency-free Python 3 cache/proxy for Open-Meteo. It remembers
locations requested by the app, refreshes them every 30 minutes, persists the
last good response, and serves stale data when the upstream service is briefly
unavailable.

## Debian 12 deployment

Run these commands as root on the VPS after copying this `server` directory:

```bash
useradd --system --home /opt/dawnpilot --shell /usr/sbin/nologin dawnpilot
install -d -o dawnpilot -g dawnpilot /opt/dawnpilot /var/lib/dawnpilot
install -m 0755 dawnpilot_server.py /opt/dawnpilot/dawnpilot_server.py
install -m 0644 dawnpilot.service /etc/systemd/system/dawnpilot.service
cp .env.example /etc/dawnpilot.env
chmod 0600 /etc/dawnpilot.env
```

Generate a token and put it in `/etc/dawnpilot.env`:

```bash
openssl rand -hex 32
systemctl daemon-reload
systemctl enable --now dawnpilot
systemctl status dawnpilot
```

The Python service intentionally listens on localhost. Put Caddy or nginx in
front of it and expose only HTTPS. `Caddyfile.example` shows how to mount the
service at `/dawnpilot` on an existing HTTPS site without disturbing its other
routes.

## Verification

```bash
curl https://example.com/dawnpilot/healthz
curl -H 'Authorization: Bearer YOUR_TOKEN' \
  'https://example.com/dawnpilot/v1/forecast?latitude=31.2304&longitude=121.4737&timezone=Asia%2FShanghai'
```

Use the same HTTPS base URL and token in the iOS app settings.

## Local development

```bash
export DAWNPILOT_TOKEN=development-token
export DAWNPILOT_CACHE_FILE=/tmp/dawnpilot-cache.json
python3 server/dawnpilot_server.py
python3 -m unittest discover -s server/tests -v
```
