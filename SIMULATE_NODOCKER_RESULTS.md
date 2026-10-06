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
