# Contributing

Thanks for helping improve this stack.

- **Bug reports** (the stack does not come up, an alert fires when it should not, a check
  fails): open an issue with the output of `stack/scripts/check-config.sh`,
  `docker compose ps` and the logs of the failing service.
- **Pull requests**:
  - Every alert rule change needs a matching promtool test in
    `stack/prometheus/tests/ftwvps-essentials.test.yml`: one case that must fire and one
    that must stay quiet.
  - Run `./run-tests.sh` before opening the PR; CI runs exactly the same checks.
  - Keep image tags pinned to an exact version in `compose.yaml`, `stack/setup.sh`,
    `stack/scripts/check-config.sh` and `run-tests.sh` — and update the README table.
  - Scripts are POSIX `sh` (not bash) and must stay idempotent: running `setup.sh` twice
    must never change a generated secret.
- No default credentials, ever. Anything secret is generated into `stack/secrets/`, which
  is git-ignored.

Container hardening is part of the contract: non-root, read-only root filesystem,
`no-new-privileges`, all capabilities dropped, a memory limit, and only Caddy publishing ports.

By contributing you agree that your contribution is licensed under the MIT License.
