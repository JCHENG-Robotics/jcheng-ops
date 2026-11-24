# Evidence — 2026-11-24 outage

Collected from the robot's journal and from live probes on the operator laptop
during the incident and the recovery. Sanitized: no tokens, no keys.

| File | Content |
|---|---|
| `journal-excerpts.txt` | Kernel OOM lines, sshd throttling, the failed camera unit, the fstab-generator error, the `__vm_enough_memory` cascade |
| `verification.txt` | Post-install command output for the guards |

Context and analysis: [`../../docs/INCIDENT-2026-11-24.md`](../../docs/INCIDENT-2026-11-24.md)
and [`../../docs/VERIFICATION.md`](../../docs/VERIFICATION.md).

## Observed connectivity during the outage (laptop → robot)

```text
ping 10.42.0.218               2/2 replies, 0.155–0.183 ms, ttl=64
ip neigh                       98:fe:54:01:ef:08 REACHABLE
nc -zv 10.42.0.218 22          succeeded (TCP established)
ssh pi@…                       Connection timed out during banner exchange
ssh -6 pi@fe80::…%<if>         Connection timed out during banner exchange
nc -zv 10.42.0.218 8765        accepted the SYN, no HTTP response (timeout)
nc -zv 10.42.0.218 8766        Connection refused
```

That combination — network stack alive, no user-space response — is the
signature this repository monitors for.
