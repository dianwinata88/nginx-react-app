# Upgrade deployment — nginx 1.30.x → 1.31.x, React 18 → 19

Step-by-step migration for this repo, executed and verified on this VM
(2026-10-06) via the Jenkins pipeline (`nginx-react-app`, build #3).
See DEPLOYMENT.md for the base architecture — this file only covers the
upgrade and its rollback.

## Version changes

| Component | Before | After |
|---|---|---|
| nginx (Dockerfile, lb, deploy images) | `nginx:1.30.5-alpine` | `nginx:1.31.6-alpine` |
| react / react-dom (`app/package.json`) | `^18.3.1` | `^19.3.0` |

Vite 5 / @vitejs/plugin-react 4 / vitest 2 are unchanged — they already
support React 19, so no bundler changes were needed. React 19 notes: the
app uses only `createRoot`, `useState`, `useEffect` — all compatible; no
`defaultProps`, legacy context, or string refs to migrate.

## Migration steps

### 1 — Update dependencies and configs

```bash
cd app
# package.json: "react": "^19.3.0", "react-dom": "^19.3.0"
npm install            # regenerates package-lock.json
```

```bash
cd ..
# pin the new nginx tag everywhere it appears
sed -i 's/nginx:1\.30\.5-alpine/nginx:1.31.6-alpine/g' \
    Dockerfile docker-compose.yml deploy/docker-compose.lb.yml
```

### 2 — Verify locally before deploying

```bash
cd app
npm test               # vitest — must pass
npm run build          # produces dist/ — must succeed
```

### 3 — Commit and push

```bash
git add -A
git commit -m "Upgrade nginx to 1.31.6 and React to 19.3"
git push
```

### 4 — Deploy through Jenkins (rolling)

```
Jenkins UI (or API) -> job "nginx-react-app" -> Build with Parameters
  DEPLOY_MODE = compose-local   (simulation) or ssh (production)
  IMAGE_TAG   = 1.31-r19        (descriptive tag; do not reuse 'latest')
```

The pipeline rebuilds the image, then redeploys `node-a` and `node-b` one at
a time — the peer node keeps serving traffic during each restart, so the
upgrade is zero-downtime.

Equivalent manual command for the local simulation:

```bash
docker compose up -d --build node-a && sleep 5 && \
docker compose up -d node-b        # one node at a time keeps the site up
```

### 5 — Verify

```bash
# even distribution across both nodes
for i in $(seq 10); do curl -s http://localhost:8080/healthz; done | sort | uniq -c

# new versions actually serving
docker exec nginx-react-app-node-a-1 nginx -v          # nginx/1.31.x
curl -s http://localhost:8080/assets/*.js | head -c 0  # page loads (React 19 bundle)
curl -sI http://localhost:8080/ | grep -i x-node-id
```

In the browser, `http://localhost:8080` should render the app and show a
serving node id (not `unknown`).

## Rollback

Fastest rollback is redeploying the previous image/config — no rebuild
needed if the old image tag is still present:

### A — Pipeline rollback (preferred)

```
Jenkins -> "nginx-react-app" -> Build with Parameters
  IMAGE_TAG = <previous-tag>     # e.g. latest built before the upgrade
```

Or replay the pre-upgrade commit's pipeline run (job history -> Replay).

### B — Manual rollback (local simulation)

```bash
# 1. restore the old image tag
docker image ls | grep nginx-react-app          # confirm old tag exists
docker tag nginx-react-app:local nginx-react-app:broken
docker tag <old-image-id> nginx-react-app:local  # or rebuild from the old commit

# 2. roll nodes back one at a time (keeps the site up)
docker compose up -d --no-deps --force-recreate node-a
docker compose up -d --no-deps --force-recreate node-b

# 3. verify
for i in $(seq 6); do curl -s http://localhost:8080/healthz; done
```

### C — Git revert (source-level rollback)

```bash
git revert <upgrade-commit-sha>   # restores React 18.3 + nginx 1.30.5 pins
git push
# re-run the Jenkins pipeline — it rebuilds and rolls the old versions out
```

### Production (ssh mode)

On each node host, one at a time:

```bash
IMAGE_TAG=<previous-tag> NODE_ID=node-a \
  docker compose -f /opt/nginx-react-app/docker-compose.node.yml up -d app
```

## Verification record (this VM, 2026-10-06)

- `npm test` + `npm run build` passed on React 19.3.0.
- Jenkins build #3: all stages green — image rebuilt on nginx:1.31.6-alpine,
  rolling redeploy of node-a then node-b, LB `/healthz` distributing across
  both nodes afterward.
- Page renders React 19 build (`nginx + React 19 — active-active`).
