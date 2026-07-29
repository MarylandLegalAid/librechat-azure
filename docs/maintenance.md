# Running it day to day

What you actually have to do once it is live. Less than you would think, but not
nothing.

## The rhythm

| When | What | How long |
|---|---|---|
| Whenever Renovate opens one | Review and merge the upgrade pull request | 15–30 min |
| Monthly | Glance at cost and alert history | 10 min |
| Quarterly | **Test a restore** | 5 min |
| Quarterly | Review who has administrator access | 10 min |
| Annually | Check when your OIDC client secret expires | 5 min |
| As needed | Add or retire a model | 10 min |

That is the whole job. Everything else — deploys, certificates, backups, security
patches — happens on its own.

## What is automatic

- **Deploys.** Every five minutes, or on push if you use the pipeline.
- **Rollback** on a failed health check.
- **TLS certificates**, issued and renewed by Caddy.
- **Security updates** to the operating system, unattended. Deliberately **without**
  automatic reboots — a reboot the machine chose at 6am is a reboot nobody is
  watching.
- **Backups**, nightly database dump and daily whole-machine.
- **Monitoring**, emailing you when something breaks.

## Reboots

Unattended upgrades install security patches but never reboot. Check occasionally:

```bash
az vm run-command invoke -g rg-librechat-prod -n vm-librechat-prod \
  --command-id RunShellScript \
  --scripts "test -f /var/run/reboot-required && cat /var/run/reboot-required-pkgs || echo 'no reboot needed'" \
  --query "value[0].message" -o tsv
```

If one is needed, do it at a quiet moment. Everything restarts on boot; expect two or
three minutes of downtime.

## Upgrading LibreChat

Renovate opens a pull request per release. **Do not merge it without reading**
[Upgrading LibreChat](modules/upgrading.md) — the checks that matter are new required
environment variables and renamed config keys, and neither is reliably in the
changelog.

MongoDB and Meilisearch **major** version bumps are disabled in `renovate.json`
deliberately. Both hold state a major version can refuse to read, and neither belongs
in an automated pull request. Minor and patch updates still come through.

## Monitoring

Alerts go to `alertEmail` from the deployment.

| Alert | Means |
|---|---|
| `health-unavailable` | **The site is down.** Act now. |
| `cpu-high`, `memory-low` | Usually load growth, occasionally a runaway container. |
| `os-disk-iops-high`, `data-disk-iops-high` | At the disk's throughput limit; everything is slow. |
| `network-out-high` | Worth a look — unusual outbound traffic. |
| `vm-unavailable` | Azure reports the machine itself as unavailable. |

`health-unavailable` is the one that matters. Every other alert can be green while the
application is completely broken — a crash-looping container uses almost no CPU and
almost no memory, and the machine hosting it is genuinely available.

### Prove the alert works

An alert nobody has seen fire is an assumption. Once:

```bash
az vm run-command invoke -g rg-librechat-prod -n vm-librechat-prod \
  --command-id RunShellScript \
  --scripts "docker compose -f /srv/librechat/app/compose.yaml stop api && sleep 420 && docker compose -f /srv/librechat/app/compose.yaml start api" \
  --query "value[0].message" -o tsv
```

You should get an email within about ten minutes. Do this outside working hours.

## Users

Day-to-day user administration is the admin panel at `chat-admin.yourorg.org`.

There is **no database GUI** in this stack, deliberately. For the rare thing the panel
cannot do:

```bash
docker compose exec mongodb mongosh LibreChat
```

Useful queries:

```javascript
db.users.countDocuments()
db.users.find({ role: "ADMIN" }, { email: 1, name: 1 })
db.conversations.countDocuments({ createdAt: { $gte: new Date(Date.now() - 30*86400000) } })
db.agents.aggregate([{ $group: { _id: "$model", n: { $sum: 1 } } }])
```

If you use single sign-on, removing someone from your directory removes their access.
Their conversations remain, which is usually what a records policy wants.

## Rotating a secret

```bash
az keyvault secret set --vault-name kv-librechat-prod \
  --name ANTHROPIC-API-KEY --value "sk-ant-new..." --output none

az vm run-command invoke -g rg-librechat-prod -n vm-librechat-prod \
  --command-id RunShellScript \
  --scripts "/srv/librechat/app/scripts/deploy.sh --force" \
  --query "value[0].message" -o tsv
```

Changing a secret does not deploy anything on its own — the timer watches git, not the
vault.

!!! danger "Two secrets must never be rotated"
    **`CREDS_KEY` and `CREDS_IV`.** They encrypt every API key your users have saved.
    Changing them makes all of those permanently undecryptable, with no error and no
    recovery.

    Every other secret here is safe to rotate. These two are not.

## Costs

```bash
az consumption usage list \
  --start-date 2026-08-01 --end-date 2026-08-31 \
  --query "[?contains(instanceName, 'librechat')].{name:instanceName, cost:pretaxCost}" \
  --output table
```

Your AI provider bill is separate and usually larger. Set spending limits in their
console — an agent in a loop is a real way to spend real money.

See [What it costs](cost-model.md).

## Things worth doing that nobody schedules

- **Test a restore.** Quarterly. Five minutes. It is the only way to find out whether
  you have a backup or a hopeful assumption. [How](modules/backups.md#test-your-restore).
- **Check who is an administrator.** People change roles.
- **Check when your OIDC client secret expires.** An Entra secret quietly reaching its
  expiry and locking everyone out on a Tuesday morning is a genuinely common outcome.
- **Read your own terms of service** once a year, and ask whether it still describes
  what the system does. Enabling web search or a code interpreter changes the answer.

## Keeping up with upstream

If you forked this repository, pull improvements periodically:

```bash
git remote add upstream https://github.com/MarylandLegalAid/librechat-azure.git
git fetch upstream
git merge upstream/main
```

Conflicts should be confined to `librechat.yaml` and `env.defaults` — the two files
you were expected to change. That is why per-deployment values live in Key Vault
rather than in files: there is nothing to conflict.
