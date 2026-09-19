# Single-VPS observability: Prometheus + Grafana behind automatic HTTPS, in one command

[![validate](https://github.com/Fractal-Techware/vps-observability-stack/actions/workflows/test.yml/badge.svg)](https://github.com/Fractal-Techware/vps-observability-stack/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Prometheus 3.14](https://img.shields.io/badge/Prometheus-3.14.0-e6522c?logo=prometheus&logoColor=white)
![Grafana 13.2](https://img.shields.io/badge/Grafana-13.2.2-f46800?logo=grafana&logoColor=white)
![Caddy 2.11](https://img.shields.io/badge/Caddy-2.11.4-1f88c0?logo=caddy&logoColor=white)
![alerts: 6 tested](https://img.shields.io/badge/alerts-6%20tested-brightgreen)

Monitoring for one server — behind HTTPS, with **no default password anywhere** — in about
five minutes. Caddy gets a Let's Encrypt certificate on its own (or issues a local one with
`--tls internal`), `setup.sh` generates every credential, and `docker compose up -d` starts
the whole thing.

```bash
./setup.sh --domain monitoring.example.com --tls you@example.com --up
```

Every container runs non-root with a read-only root filesystem, all capabilities dropped,
`no-new-privileges` and a memory limit. Only Caddy publishes ports; Prometheus and
node_exporter sit on a Docker network with `internal: true` and no route to the internet.

By [Fractal Techware](https://fractaltechware.gumroad.com/?utm_source=github&utm_medium=readme&utm_campaign=free-repo). MIT licensed.

## What's included

| | What you get |
|---|---|
| Services | Caddy 2.11.4 (HTTPS), Prometheus 3.14.0, Grafana 13.2.2, node_exporter 1.12.1 — all pinned |
| Access | `https://your-domain/` → Grafana (own login); `/prometheus/` behind bcrypt basic auth |
| TLS | Automatic Let's Encrypt/ZeroSSL certificates, or `--tls internal` for a local CA (tests, private networks) |
| Dashboard | **1** provisioned: *VPS Host* — CPU, load, memory, swap and OOM kills, filesystems, inodes, disk I/O, network |
| Alerts | **6** essential rules, each with promtool unit tests: `TargetDown`, `HostHighCpuUsage`, `HostOutOfMemory`, `HostDiskSpaceLow`, `HostDiskWillFillIn24Hours`, `PrometheusConfigReloadFailed` |
| Secrets | `setup.sh` generates a 40-character Grafana admin password and a separate Prometheus UI password (+ its bcrypt hash for Caddy) into `stack/secrets/` (mode 0700, git-ignored). No default credentials exist in this repo. |
| Data | Named volumes; retention by time **and** size (`PROMETHEUS_RETENTION_TIME`, `PROMETHEUS_RETENTION_SIZE`) |
| Hardening | non-root, read-only root filesystems, `no-new-privileges`, all capabilities dropped, CPU/memory limits, healthchecks, log rotation, TSDB admin API blocked at the proxy, Grafana `/metrics` not reachable from outside |
| Scripts | `setup.sh` (POSIX sh, idempotent), `scripts/check-config.sh` (validates everything with the real tools, in Docker) |
| CI | `./run-tests.sh` — shell syntax, YAML, `promtool check config/rules`, `promtool test rules`, `caddy validate`, `docker compose config` |

## 60-second quick start

Requirements: a Linux VPS (2 GB RAM is enough), Docker Engine with the Compose v2 plugin, and a
DNS A/AAAA record pointing at it. Ports 80 and 443 must be reachable.

```bash
git clone https://github.com/Fractal-Techware/vps-observability-stack.git
cd vps-observability-stack/stack

./setup.sh --domain monitoring.example.com --tls you@example.com --up

cat secrets/grafana_admin_password      # user: admin
open https://monitoring.example.com/
```

`--up` starts the stack and waits until every container reports healthy. Without it, run
`docker compose up -d` yourself.

Trying it on your laptop first? `./setup.sh --domain monitoring.localhost --tls internal --up`
makes Caddy issue a certificate from its own local CA instead of talking to Let's Encrypt.
(Set `BIND_ADDRESS=127.0.0.1` and non-privileged `HTTP_PORT` / `HTTPS_PORT` in `.env` if you
do not want to bind 80/443.)

### What you get once it is up

| URL | What | Credentials |
|---|---|---|
| `https://your-domain/` | Grafana + the *VPS Host* dashboard | `admin` / `secrets/grafana_admin_password` |
| `https://your-domain/prometheus/` | Prometheus UI, targets, **Alerts** | `admin` / `secrets/admin_ui_password` |

## Day-2 operations

```bash
docker compose ps                     # health of every service
docker compose logs -f prometheus     # logs
scripts/check-config.sh               # validate after ANY change, before restarting
./setup.sh                            # re-render config after editing .env (idempotent)
docker compose pull && docker compose up -d   # only after changing the pinned versions
```

Adding your own alerts: drop a file in `stack/prometheus/rules/`, add unit tests in
`stack/prometheus/tests/`, run `scripts/check-config.sh`, then
`docker compose kill -s HUP prometheus`.
Adding dashboards: copy the JSON into `stack/grafana/dashboards/` — provisioning picks it up
within a minute.

## Validate it yourself

```bash
./run-tests.sh
```

```
==> shell syntax
  SUCCESS
==> YAML syntax
  SUCCESS (7 files)
==> promtool check config
 SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax
==> promtool check rules
  SUCCESS: 6 rules found
==> promtool test rules (6 alerts)
  SUCCESS
==> caddy validate
Valid configuration
==> docker compose config
  SUCCESS
All checks passed.
```

Every alert has a case that must fire and a case that must stay quiet — a healthy host, a
filesystem that is excluded on purpose (`tmpfs`), or a moment before the `for:` duration has
elapsed. `HostDiskWillFillIn24Hours` is tested against a disk losing 100 MB/minute and against
a stable one. CI runs exactly this script on every push.

## Security model

- **No default credentials.** `setup.sh` generates a 40-character Grafana admin password and a
  separate password for the Prometheus UI from `/dev/urandom`, stores them in `secrets/`
  (0700 directory), and gives Caddy only the bcrypt hash. Re-running never overwrites a secret.
- Secrets are **files**, not environment variables: Grafana reads
  `GF_SECURITY_ADMIN_PASSWORD__FILE`. `stack/secrets/` and `stack/.env` are git-ignored.
- Only Caddy publishes ports (80, 443/tcp+udp). Prometheus and node_exporter live on an
  `internal: true` network with no outbound route.
- HSTS, `X-Content-Type-Options`, `Referrer-Policy` and a stripped `Server` header on every
  response. Grafana sign-up, org creation, anonymous access and phone-home are all disabled.
- The Prometheus TSDB admin API returns 403 at the proxy; Grafana's `/metrics` returns 404
  from outside.

## Repository layout

```
stack/
├── compose.yaml              # the whole stack, hardened and pinned
├── .env.example              # domain, TLS mode, ports, retention, memory limits
├── setup.sh                  # prerequisites, .env, secrets, rendered config, validation
├── Caddyfile, caddy/routes.d # HTTPS, basic auth, blocked admin API
├── prometheus/               # prometheus.yml, scrape.d/, rules/, tests/ (promtool unit tests)
├── grafana/                  # provisioning (data source, dashboards) + the VPS Host dashboard
└── scripts/                  # lib.sh, check-config.sh, volume-init.sh
run-tests.sh                  # everything CI runs, on your machine
```

## Want the full pack?

This repository is a free, fully working subset of the
**[Single-VPS Observability Stack](https://fractaltechware.gumroad.com/l/vps-observability-stack?utm_source=github&utm_medium=readme&utm_campaign=free-repo)**
— same compose project, same hardening, same test standard. The paid tiers add the parts that
turn a monitoring stack into something you can be on call with:

| | **Free** (this repo) | **Starter** $19 | **Pro** $49 | **Studio** $99 |
|---|:---:|:---:|:---:|:---:|
| Caddy HTTPS, Prometheus, Grafana, node_exporter, generated passwords, hardened containers | yes | yes | yes | yes |
| Dashboards | 1 | 3 | 5 | 5 |
| Tested alerts | 6 | 19 | 29 | 29 |
| Alertmanager + webhook delivery, cAdvisor container metrics | – | yes | yes | yes |
| Loki (logs), Tempo (traces), Alloy, uptime & TLS-expiry checks, e-mail/Slack/Telegram alerting, tested backup **and restore**, agent for your other servers, hardening + upgrade guides | – | – | yes | yes |
| Grafana SSO, multi-host inventory, public status page, off-host backup rotation, disaster-recovery runbook, sizing guide, cloud-init bootstrap | – | – | – | yes |
| License | MIT | own organization | own organization | client / agency use |

Alerts in this repository fire in Prometheus and are visible at `/prometheus/alerts`; routing
them to a webhook, e-mail, Slack or Telegram needs Alertmanager, which ships from Starter up.

[See the full stack on Gumroad →](https://fractaltechware.gumroad.com/l/vps-observability-stack?utm_source=github&utm_medium=readme&utm_campaign=free-repo)

## More free repos

Other MIT-licensed samples from Fractal Techware — tested Prometheus alert rules and runbooks,
SLO-as-code with burn-rate alerts, OpenTelemetry Collector recipes, Kubernetes hardening
baselines: **[github.com/Fractal-Techware](https://github.com/Fractal-Techware)**

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
Every alert change needs a promtool test.

## License

[MIT](LICENSE) © 2026 Fractal Techware SRL
