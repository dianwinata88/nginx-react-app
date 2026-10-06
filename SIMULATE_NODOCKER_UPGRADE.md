# No-Docker upgrade deployment — two Linux hosts, active-active

Step-by-step procedure for deploying the React build to **two bare-metal
nginx hosts** (no Docker, no Jenkins required) behind an nginx load
balancer, then rolling the upgrade out with zero downtime.

On this VM the two "hosts" are simulated as three nginx processes on one
machine — ports `9091` (host A), `9092` (host B), `9090` (LB). To run this
on real VMs, replace `127.0.0.1:909x` with the host IPs and run each step
on its own host over SSH — the commands are identical.

Companion file: `SIMULATE_NODOCKER_RESULTS.md` — captured output of this
exact run on this VM.

## Topology

```
                ┌──────────────┐
                │   clients    │
                └──────┬───────┘
                       │ :9090        (prod: :80 on the LB host)
                ┌──────▼───────┐
                │  nginx LB    │  upstream react_app, round-robin
                └─┬──────────┬─┘
       ┌──────────▼──┐     ┌─▼──────────┐
       │  host A     │     │  host B    │
       │ nginx :9091 │     │ nginx :9092│   each serves /opt app docroot
       └─────────────┘     └────────────┘
```

## Step 1 — Install nginx on each host

Ubuntu's repo ships 1.18; use the official nginx.org repo for 1.31.x:

```bash
curl -fsSL https://nginx.org/keys/nginx_signing.key \
  | sudo gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
  http://nginx.org/packages/mainline/ubuntu jammy nginx" \
  | sudo tee /etc/apt/sources.list.d/nginx.list
sudo apt-get update && sudo apt-get install -y nginx
nginx -v    # nginx/1.31.6
```

## Step 2 — Create the app layout on each host

Real host: `/opt/nginx-react-app/{html,conf,logs,tmp}`.
Simulation: `~/nodocker-sim/node-a`, `~/nodocker-sim/node-b`.

Per-host `conf/nginx.conf` (host A shown — change port/node id for B):

```nginx
pid /opt/nginx-react-app/nginx.pid;
error_log /opt/nginx-react-app/logs/error.log warn;
worker_processes 1;

events {}

http {
    include /etc/nginx/mime.types;
    access_log /opt/nginx-react-app/logs/access.log;
    client_body_temp_path /opt/nginx-react-app/tmp/body;
    proxy_temp_path     /opt/nginx-react-app/tmp/proxy;
    fastcgi_temp_path   /opt/nginx-react-app/tmp/fastcgi;
    uwsgi_temp_path     /opt/nginx-react-app/tmp/uwsgi;
    scgi_temp_path      /opt/nginx-react-app/tmp/scgi;

    gzip on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml;

    server {
        listen 9091;
        root /opt/nginx-react-app/html;
        index index.html;

        add_header X-Node-Id "node-a" always;

        location = /healthz {
            default_type text/plain;
            return 200 "node-a\n";
        }
        location /assets/ {
            expires 1y;
            add_header Cache-Control "public, immutable";
            add_header X-Node-Id "node-a" always;
            try_files $uri =404;
        }
        location / {
            add_header Cache-Control "no-cache";
            add_header X-Node-Id "node-a" always;
            try_files $uri $uri/ /index.html;
        }
    }
}
```

Notes:
- The `*_temp_path` lines are required when running unprivileged — the
  package's compiled-in defaults point at root-owned `/var/cache/nginx`.
- `X-Node-Id` + `/healthz` are what make active-active verifiable.

## Step 3 — Build the app artifact

```bash
cd app && npm ci && npm test && npm run build    # produces dist/
```

## Step 4 — Deploy v1 to BOTH hosts

```bash
# per host (sim: local rsync; prod: rsync over ssh)
rsync -a --delete app/dist/ <host>:/opt/nginx-react-app/html/
echo 'window.__NODE_ID__="node-a";' > <host>:/opt/nginx-react-app/html/config.js
echo 'v1 react-18' > <host>:/opt/nginx-react-app/html/version.txt

# start nginx on the host
nginx -p /opt/nginx-react-app -c conf/nginx.conf
```

## Step 5 — Start the load balancer

`~/nodocker-sim/lb/conf/nginx.conf` upstream block:

```nginx
upstream react_app {
    server 127.0.0.1:9091 max_fails=2 fail_timeout=10s;
    server 127.0.0.1:9092 max_fails=2 fail_timeout=10s;
}
# proxy_pass http://react_app;  + proxy_next_upstream error timeout http_502 http_503 http_504
```

```bash
nginx -p ~/nodocker-sim/lb -c conf/nginx.conf
for i in 1 2 3 4; do curl -s http://localhost:9090/healthz; done   # alternates
```

## Step 6 — Rolling upgrade (zero downtime)

Repeat per host — B first, then A:

```bash
# 1. drain host B: stop its nginx (LB's passive check + proxy_next_upstream
#    routes everything to host A; users see no downtime)
nginx -p /opt/nginx-react-app -c conf/nginx.conf -s quit   # on host B

# 2. verify LB still serves via host A
for i in 1 2 3 4; do curl -s http://localhost:9090/version.txt; done

# 3. push the new build to host B
rsync -a --delete app/dist-v2/ <host-b>:/opt/nginx-react-app/html/
echo 'v2 react-19' > <host-b>:/opt/nginx-react-app/html/version.txt

# 4. start host B; LB re-adds it after fail_timeout (~10s)
nginx -p /opt/nginx-react-app -c conf/nginx.conf           # on host B

# 5. confirm mixed versions through LB (v1 on A, v2 on B)
for i in $(seq 8); do curl -s http://localhost:9090/version.txt; done

# 6. repeat steps 1-5 for host A
```

## Step 7 — Verify the upgrade

```bash
for i in $(seq 10); do curl -s http://localhost:9090/version.txt; done | sort | uniq -c
# expect: all v2

for i in 1 2 3 4; do curl -s http://localhost:9090/healthz; done    # node-a/node-b
curl -s http://localhost:9090/ | grep -o 'index-[A-Za-z0-9_-]*\.js' # new bundle hash
nginx -v                                                          # nginx/1.31.6
```

Browser: `http://localhost:9090` (prod: `http://<lb>`) — shows the new UI
and which node served it.

## Rollback

Deploys swap only static files, so rollback = redeploy the previous
docroot, one host at a time (same zero-downtime pattern):

```bash
# per host, keep the prior build around or rebuild it
nginx -p /opt/nginx-react-app -c conf/nginx.conf -s quit   # on the host
rsync -a --delete dist-v1-backup/ <host>:/opt/nginx-react-app/html/
echo 'v1 react-18' > <host>:/opt/nginx-react-app/html/version.txt
nginx -p /opt/nginx-react-app -c conf/nginx.conf           # on the host
```

Keep a `html-v1` copy on each host (or rsync the old `dist/` again) — the
LB keeps the site up on the peer throughout.

## Mapping simulation → real hosts

| Simulation (this VM) | Real deployment |
|---|---|
| `~/nodocker-sim/node-a` port 9091 | Host A `/opt/nginx-react-app` port 80 |
| `~/nodocker-sim/node-b` port 9092 | Host B `/opt/nginx-react-app` port 80 |
| `~/nodocker-sim/lb` port 9090 | LB host, upstream `<ip-a>:80`, `<ip-b>:80` |
| local `rsync` | `rsync -az --delete dist/ user@host:/opt/nginx-react-app/html/` |
| `nginx -p <prefix>` | systemd `nginx` unit on each host |
