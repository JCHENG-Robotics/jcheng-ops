# License review — pending

This repository does **not** ship a `LICENSE` file. Copyright is reserved;
JCHENG-Robotics license review is in progress, consistent with the other
organization repositories.

## What is in this repository

- Original Python, bash and systemd unit files written for the ArmPi Ultra
  deployment.
- Operational facts (addresses, ports, token paths) measured from the live
  robot; no secrets are committed.
- Journal excerpts and command output in `evidence/`, sanitized: no tokens, no
  SSH keys, no personal data beyond the operator's own hostnames.

## Third-party runtime dependencies

| Dependency | Use | License note |
|---|---|---|
| Python 3 standard library | health checker | PSF-2.0 |
| systemd (system + user manager) | watchdog, timers, restart policies | LGPL-2.1-or-later |
| bash, coreutils, `ss`, `curl` | installers and Studio watchdog | GPL-3.0-or-later / MIT (curl) |

None of these are vendored. The repository contains no copied third-party
source, no model weights and no vendor SDK files.

## Secrets

The gateway token is never stored in this repository. The Studio installer
writes it to `~/.config/armpi-studio/studio.env` (0600) on the operator
machine; the health checker reads it from the robot's
`/home/pi/docker/tmp/armpi_gateway_deploy/token` (0600, owned by `pi`).
`scripts/check_repo_gate.sh` fails the build if a token-like value or a `*.env`
file appears in the tree.
