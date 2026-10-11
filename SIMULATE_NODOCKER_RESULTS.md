# No-Docker simulation results — 2026-10-06, this VM

Captured output of the procedure in `SIMULATE_NODOCKER_UPGRADE.md`.
Two "hosts" = native nginx 1.31.6 processes on ports 9091/9092, native LB
on 9090. Upgrade path: **v1 (React 18 build) → v2 (React 19 build)**,
rolling, zero downtime.

## Setup

```text
$ nginx -v
nginx version: nginx/1.31.6          # installed via nginx.org mainline repo

$ ls ~/nodocker-sim
lb/  node-a/  node-b/               # each: conf/ html/ logs/ tmp/
```

v1 artifact = build of pre-upgrade commit `049a732` (`index-Dy7nzrm0.js`,
143 KB, React 18). v2 = `index-BJcBtwwr.js` (223 KB, React 19).

## Phase 1 — v1 deployed to both hosts

```text
=== LB healthz x6 ===          (strict alternation — worker_processes 1)
node-a
node-b
node-a
node-b
node-a
node-b

=== versions via LB ===
      6 v1 react-18 nginx-1.30        ← both hosts on old version

$ curl -s localhost:9090/ | grep -o 'index-[A-Za-z0-9_-]*\.js'
index-Dy7nzrm0.js                     ← React 18 bundle
```

## Phase 2 — upgrade host B (site stays up on A)

```text
$ nginx -p node-b -s quit            # host B down for maintenance

=== LB with node-b down ===
      4 node-a                        ← all traffic absorbed by host A

$ rsync -a --delete dist-v2/ node-b/html/ && nginx -p node-b
$ curl -s localhost:9092/version.txt  # direct host check
v2 react-19 nginx-1.31

=== LB immediately after (fail_timeout window) ===
      8 v1 react-18 nginx-1.30        ← node-b still penalised ~10s

=== LB after fail_timeout ===
      4 v1 react-18 nginx-1.30        ← host A, still v1
      4 v2 react-19 nginx-1.31        ← host B, upgraded
```

## Phase 3 — upgrade host A

```text
$ nginx -p node-a -s quit            # host A down

=== LB with node-a down ===
      4 v2 react-19 nginx-1.31        ← users now get the NEW version via B

$ rsync + restart node-a ...
```

## Final state

```text
=== versions via LB ===
     10 v2 react-19 nginx-1.31        ← all requests on v2

=== LB healthz x6 ===
node-b
node-a
node-b
node-a
node-b
node-a

$ curl -s localhost:9090/ | grep -o 'index-[A-Za-z0-9_-]*\.js'
index-BJcBtwwr.js                     ← React 19 bundle (223 KB)
```

Browser check: `http://localhost:9090` renders "nginx + React 19 —
active-active", served by node-b, `/healthz` answered by node-a.

## Verdicts

| Check | Result |
|---|---|
| Active-active v1 | pass — strict a/b alternation, all v1 |
| Zero-downtime rolling upgrade | pass — peer absorbed all traffic during each stop |
| Passive failover | pass — `max_fails`/`proxy_next_upstream` routed around each stopped host; ~10s `fail_timeout` re-add delay observed |
| Final state | pass — 10/10 v2, both hosts active, new bundle hash |
| nginx version | pass — 1.31.6 on all three instances |

## Operational notes seen in this run

- `fail_timeout` delay is real: a host that rejoins is skipped for ~10s —
  verify distribution *after* the window closes, not immediately.
- Unprivileged nginx needs `client_body_temp_path`/`proxy_temp_path`/etc.
  pointed at writable dirs; the package defaults are root-owned `/var/cache`.
- `worker_processes 1` gives deterministic alternation for demos; at the
  default (auto) each worker keeps its own round-robin pointer, so short
  bursts can stick to one host (still evenly distributed overall).
- Static docroot swaps need no `nginx -s reload` — files are read per
  request; stopping/starting the process is only to simulate host
  maintenance.

---

## Jenkins-driven run — build #6 (DEPLOY_MODE=native-hosts)

The same upgrade, executed by the Jenkins pipeline instead of by hand.
The Jenkins container SSHes to each host (`ubuntu@host.docker.internal`,
key `~/.ssh/sim_deploy_key`), drains the old nginx via `kill -QUIT` on the
host's `nginx.pid`, rsyncs the freshly-built `app/dist`, then starts the
host's `nginx-1.31.6` binary and health-checks the host port — node A,
then node B, exactly like production `ssh` mode.

Setup prerequisites (one-time, on the docker host):

```bash
# per-host nginx binaries (old + new) from nginx.org debs
apt download nginx=1.31.5-1~jammy nginx=1.31.6-1~jammy
dpkg -x nginx_1.31.5-1~jammy_amd64.deb ~/nodocker-sim/nginx-1.31.5
dpkg -x nginx_1.31.6-1~jammy_amd64.deb ~/nodocker-sim/nginx-1.31.6

# let Jenkins SSH to the hosts (this VM: host.docker.internal = the host)
ssh-keygen -t ed25519 -N '' -f ~/.ssh/sim_deploy_key
cat ~/.ssh/sim_deploy_key.pub >> ~/.ssh/authorized_keys
# docker-compose.jenkins.yml mounts ~/.ssh -> /keys:ro and adds
# extra_hosts: host.docker.internal:host-gateway
```

Build #6 result: **SUCCESS** (22 s). Console evidence per host —

```
Deploy node A:
  readlink /proc/$(cat node-a/nginx.pid)/exe  -> .../nginx-1.31.5/usr/sbin/nginx
  kill -QUIT $(cat node-a/nginx.pid); drain wait (pidfile removed)
  rsync app/dist -> node-a/html/ ; config.js + version.txt written
  nginx version: nginx/1.31.6 ; start -p node-a
  readlink /proc/$(cat node-a/nginx.pid)/exe  -> .../nginx-1.31.6/usr/sbin/nginx
  curl http://host.docker.internal:9091/healthz -> ok

Deploy node B: identical sequence on :9092

Verify: 4x /healthz via :9090 alternates node-a/node-b ; version.txt -> v2
```

| Check | Result |
|---|---|
| Jenkins rolling upgrade, host-by-host | pass — each stage drained, deployed, restarted, health-checked its host |
| Per-host nginx upgrade | pass — pid exe readlink shows 1.31.5 → 1.31.6 on both hosts |
| Per-host react upgrade | pass — version.txt `v2 react-19 nginx-1.31.6` on :9091 and :9092 |
| No downtime via LB | pass — LB kept alternating onto the peer during each stop |

### Re-run — build #7 (before-state nginx 1.30.5)

Same pipeline re-run with the hosts seeded on **nginx 1.30.5** (stable-pool
deb: `apt`/`dpkg -x` from `nginx.org/packages/ubuntu/pool` — the mainline
pool no longer carries 1.30.x) + React 18. Build #7: **SUCCESS** (18 s).

Per host: running binary `nginx-1.30.5` → drain → rsync → `nginx-1.31.6`
(console `readlink` shows each swap); version.txt
`v1 react-18 nginx-1.30.5` → `v2 react-19 nginx-1.31.6`; `/healthz` via
:9090 alternates before and after; page renders React 18 → React 19.
