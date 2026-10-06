# Deployment — nginx + React 18, active-active

Reference: [DigitalOcean — Deploy a React Application with Nginx on Ubuntu](https://www.digitalocean.com/community/tutorials/deploy-react-application-with-nginx-on-ubuntu).
This doc adapts that tutorial in three ways: the app is built with **Vite**
(Create React App is deprecated), deployment is **containerised** —
Docker images + `docker compose` instead of `rsync` of `build/` into
`/var/www` — and CI/CD runs on self-hosted **Jenkins** instead of GitHub
Actions. The nginx concepts (server blocks, gzip, caching, SPA fallback)
are the same.

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

Two operational nuances, both confirmed by end-to-end testing:

- The UI's "served by" comes from `config.js`, a *separate* upstream request
  from the one that served `index.html`. Page loads issue several upstream
  requests, so the displayed node can hold steady across reloads even though
  round-robin is alternating strictly per request. Watch `X-Node-Id` or
  `/healthz` for the authoritative picture.
- Passive failover is not instant: when a node is stopped, requests routed
  to it wait out the connect timeout (~3s) before `proxy_next_upstream`
  retries the peer. Expect brief latency on the first request(s) after a
  node dies; `max_fails` then marks it down for `fail_timeout`.

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

## CI/CD — Jenkins

The pipeline is a declarative `Jenkinsfile` at the repo root (mirrors step 8
of the tutorial, adapted). Stages:

1. **Checkout** — clone the repo into the job workspace.
2. **Test & Build** — inside a `node:20-alpine` agent container:
   `npm ci`, `npm test`, `npm run build`.
3. **Docker image** — `docker build` → `ghcr.io/dianwinata88/nginx-react-app:<tag>`.
4. **Push image** — optional (`PUSH_IMAGE`), pushes to GHCR with the
   `ghcr-creds` credential.
5. **Deploy node A → Deploy node B** — *rolling*: deploys one node, waits
   for `/healthz`, then the other; the peer absorbs traffic so there is no
   downtime. Two modes via the `DEPLOY_MODE` parameter:
   - `ssh` (production) — SSH to `NODE_A_HOST` / `NODE_B_HOST` and run
     `scripts/deploy-node.sh` (uses the `deploy-ssh-key` credential).
   - `compose-local` (simulation) — `docker compose up -d --force-recreate
     <node>` on the Jenkins host's docker, for the single-VM setup below.
6. **Verify** — curls the load balancer's `/healthz` and expects answers
   from both nodes.

### Running Jenkins locally (this VM)

`docker-compose.jenkins.yml` starts a pre-configured Jenkins
(`jenkins/Dockerfile` + `jenkins/casc.yaml`):

```bash
docker compose -f docker-compose.jenkins.yml up -d --build
# open http://localhost:8090 — login admin / admin
# run job "nginx-react-app" with defaults (DEPLOY_MODE=compose-local)
```

It comes with: the setup wizard disabled, an `admin` user, a seeded
`nginx-react-app` pipeline job (Pipeline-from-SCM pointing at `/repo-src`,
a read-only bind-mount of this checkout — switch it to the GitHub URL for
production), the plugins the pipeline needs (workflow-aggregator, git,
docker-workflow, ssh-agent, credentials-binding, configuration-as-code,
job-dsl, github), and the docker CLI + compose plugin driving the host
daemon via `/var/run/docker.sock`.

Two host-parity tricks make docker work from inside the container:
`JENKINS_HOME` and this repo are bind-mounted at the **same absolute paths**
as on the host (so agent workspace mounts and compose relative volumes
resolve), and `group_add` adds the host's docker gid (`DOCKER_GID`, default
998 — check `stat -c %g /var/run/docker.sock`).

Set `GIT_BRANCH` when starting to pick the ref the seed job builds
(default `main`; this session ran it on the feature branch).

Verified on this VM (2026-10-06): build #2 ran all stages green — tests
passed, image built, node-a then node-b redeployed, and the LB's `/healthz`
alternated `node-b/node-a` after the rolling deploy.

### Production Jenkins

- Any Jenkins LTS with the same plugin list; create a *Pipeline* job →
  *Pipeline script from SCM* → the GitHub repo URL, script path
  `Jenkinsfile`.
- Trigger on push: GitHub repo webhook → `http://<jenkins>/github-webhook/`
  (github plugin is already installed by the image).
- Drop `-Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=true` — it exists
  only for the `file:///repo-src` simulation remote.

### Jenkins credentials to configure

| ID | Type | Purpose |
|---|---|---|
| `deploy-ssh-key` | SSH Username with private key | `sshagent` in ssh deploy mode |
| `ghcr-creds` | Username with password | `docker login ghcr.io` for `PUSH_IMAGE` |

Job parameters (`DEPLOY_MODE`, `PUSH_IMAGE`, `IMAGE_TAG`, `DEPLOY_USER`,
`NODE_A_HOST`, `NODE_B_HOST`, `LB_HOST`) are defined in the Jenkinsfile.

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
scripts/deploy-node.sh      per-host deploy step invoked by Jenkins (ssh mode)
jenkins/                    Jenkins image (plugins, docker CLI) + JCasC config
docker-compose.jenkins.yml  self-hosted Jenkins for the pipeline
Jenkinsfile                 CI/CD pipeline (declarative)
Dockerfile                  node:20 build → nginx:1.30.5-alpine serve
docker-compose.yml          single-VM active-active simulation
```
