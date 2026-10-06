# nginx-react-app

React 19 app served by nginx 1.31.x in an active-active pair behind an nginx
load balancer, with GitHub Actions CI/CD.

Quick start (app simulation):

```bash
docker compose up -d --build
curl http://localhost:8080/healthz   # alternates node-a / node-b
```

See [DEPLOYMENT.md](DEPLOYMENT.md) for the full architecture, production
topology, CI/CD setup, and rollback procedure.
