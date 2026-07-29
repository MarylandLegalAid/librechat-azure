# 3. Point your domain at it

Five minutes of work, then up to an hour of waiting.

## Add two DNS records

Wherever your organization's DNS is managed — often the same place your website is
hosted — add two `A` records pointing at the address Azure gave you in step 1.

| Type | Name | Value | TTL |
|---|---|---|---|
| A | `chat` | your public IP, e.g. `203.0.113.10` | 300 |
| A | `chat-admin` | the same address | 300 |

The second one is the administration panel. It gets its own hostname so it can be
restricted or taken offline without touching the chat application.

If you do not want an admin panel on the public internet at all, you can skip that
record — see [Your own domain](../modules/custom-domain.md) for the alternatives.

## Wait, then check

DNS changes take anywhere from a minute to an hour to propagate, depending on what
your previous records' TTL was.

```bash
dig +short chat.yourorg.org
dig +short chat-admin.yourorg.org
```

Both should print your Azure public IP address. **Do not go to step 4 until they do.**

Why it matters: certificates are issued automatically by Let's Encrypt, which proves
you control the name by connecting to whatever that name currently resolves to. If
DNS is not ready, issuance fails, and Let's Encrypt rate-limits repeated failures for
the same name. Waiting ten minutes now is much better than waiting an hour later.

## While you wait

Confirm the machine finished setting itself up:

```bash
az vm run-command invoke \
  --resource-group rg-librechat-prod \
  --name vm-librechat-prod \
  --command-id RunShellScript \
  --scripts "cloud-init status --long" \
  --query "value[0].message" -o tsv
```

You want `status: done`. If it says `running`, wait a couple of minutes. If it says
`error`, see [When it breaks](../troubleshooting.md#the-machine-never-finished-setting-itself-up).

---

Next: **[First login](04-first-login.md)**
