# Deployment — nginx + React 18, active-active

Reference: [DigitalOcean — Deploy a React Application with Nginx on Ubuntu](https://www.digitalocean.com/community/tutorials/deploy-react-application-with-nginx-on-ubuntu).
This doc adapts that tutorial in two ways: the app is built with **Vite**
(Create React App is deprecated) and deployment is **containerised** —
Docker images + `docker compose` instead of `rsync` of `build/` into
`/var/www`. The nginx concepts (server blocks, gzip, caching, SPA fallback,
CI/CD via GitHub Actions) are the same.

## Stack

| Component | Version |
|---|---|
| React / react-dom | 18.3.x |
| Vite | 5.4.x |
| nginx | 1.30.5 (alpine image) |
| Node (build) | 20 |

## Architecture

```
                     ┌──────────────┐
                     │   clients    │
                     └──────┬───────┘
                            │ :80
                     ┌──────▼───────┐
                     │      lb      │  nginx 1.30, round-robin upstream
                     │  (lb.conf)   │  passive failover via max_fails
                     └──┬───────┬───┘
             ┌──────────▼─┐   ┌─▼──────────┐
             │   node-a   │   │   node-b   │  identical images, both active
             │ nginx 1.30 │   │ nginx 1.30 │  serve the same React build
             └────────────┘   └────────────┘
```

- Both nodes serve traffic simultaneously (active-active, not standby).
- `lb` uses nginx `upstream` round-robin by default; `least_conn` can be
  substituted in `nginx/lb.conf` for uneven load.
- `max_fails`/`fail_timeout` give passive health checks: a node that stops
  answering is skipped until it recovers. `proxy_next_upstream` retries a
  failed request on the peer, so a rolling restart is invisible to users.
- Every response carries `X-Node-Id`; `GET /healthz` returns the node id.
- The container entrypoint writes `config.js` with the node's `NODE_ID`,
  which the React UI displays.

## Local simulation (this VM)

```bash
docker compose up -d --build

# Round-robin — successive calls alternate node-a / node-b
for i in 1 2 3 4; do curl -s http://localhost:8080/healthz; done

# Response headers show the serving node
curl -sI http://localhost:8080/ | grep -i x-node-id

# Failover — stop a node, all traffic goes to the survivor
docker compose stop node-b
for i in 1 2 3 4; do curl -s http://localhost:8080/healthz; done  # all node-a
docker compose start node-b
```

App URL: `http://localhost:8080`

Verified on this VM (2026-10-06): round-robin alternates across both nodes,
and with `node-b` stopped all requests are answered by `node-a`.

## Production topology

- `deploy/docker-compose.node.yml` — runs on **each** app host; pulls the
  GHCR image built by CI. Set `NODE_ID` per host.
- `deploy/docker-compose.lb.yml` + `deploy/lb.conf.template` — runs on the
  LB host; `NODE_A_HOST`/`NODE_B_HOST` are envsubst'd into the upstream
  block at container start.
- On each app host, install to `/opt/nginx-react-app`: copy
  `deploy/docker-compose.node.yml` and `scripts/deploy-node.sh`.
- Put a TLS terminator in front of the LB (or add certbot to the LB host)
  for HTTPS — see the DigitalOcean tutorial's SSL step.

## CI/CD

`.github/workflows/deploy.yml` (mirrors step 8 of the tutorial, adapted):

1. **test-and-build** — `npm ci`, `npm test`, `npm run build` (Node 20).
2. **image** — builds the Dockerfile and pushes
   `ghcr.io/dianwinata88/nginx-react-app:{sha}` and `:latest` to GHCR.
3. **deploy-node-a → deploy-node-b** — *rolling*: SSH to each host and run
   `scripts/deploy-node.sh`, which pulls the new image, restarts the
   container, and health-checks `/healthz` before the pipeline moves on.
   Node B only deploys after node A is healthy — the peer node absorbs all
   traffic during each restart, so users never see downtime.
4. **verify** — hits `http://<LB_HOST>/healthz` and expects answers from
   both nodes.

### Required repo settings

| Type | Name | Purpose |
|---|---|---|
| secret | `DEPLOY_SSH_KEY` | private key for the deploy user on both node hosts |
| secret | `GHCR_READ_TOKEN` | token that can `docker pull` the image on the hosts (omit if the package is public) |
| variable | `DEPLOY_USER` | SSH user on the node hosts |
| variable | `NODE_A_HOST` / `NODE_B_HOST` | app host addresses |
| variable | `LB_HOST` | load balancer address for post-deploy verification |

## Rollback

Deploys are tagged by commit SHA, so rollback is a redeploy of the previous
SHA — or on each host:

```bash
IMAGE_TAG=<previous-sha> NODE_ID=node-a \
  docker compose -f /opt/nginx-react-app/docker-compose.node.yml up -d app
```

## Repo layout

```
app/                        Vite + React 18 source
nginx/templates/            per-node server block (envsubst template)
nginx/lb.conf               LB upstream + proxy config (simulation)
deploy/                     production compose files + LB template
docker/write-config.sh      entrypoint: writes config.js with NODE_ID
scripts/deploy-node.sh      per-host deploy step invoked by CI
.github/workflows/deploy.yml
Dockerfile                  node:20 build → nginx:1.30.5-alpine serve
docker-compose.yml          single-VM active-active simulation
```
