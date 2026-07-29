# Your own domain

Two hostnames, two DNS records, and certificates that look after themselves.

## The two hostnames

| Hostname | Serves | Required |
|---|---|---|
| `chat.yourorg.org` | The chat application | Yes |
| `chat-admin.yourorg.org` | The administration panel | No, but recommended |

They are separate so the admin panel can be restricted or taken offline without
touching the chat application. Authorization is the same either way — the panel is a
thin client over the application's own permissions, and a signed-in user without the
admin role gets nothing from it. The separation is about blast radius.

## DNS

Two `A` records at your DNS provider, both pointing at the machine's public IP:

| Type | Name | Value | TTL |
|---|---|---|---|
| A | `chat` | your public IP | 300 |
| A | `chat-admin` | the same | 300 |

```bash
dig +short chat.yourorg.org
```

Wait until that returns your address before deploying. Certificates are issued by
connecting to whatever the name currently resolves to, and repeated failures for the
same name get rate-limited.

## Tell the application

```bash
V=kv-librechat-prod
az keyvault secret set --vault-name $V --name CHAT-DOMAIN     --value "chat.yourorg.org"               --output none
az keyvault secret set --vault-name $V --name ADMIN-DOMAIN    --value "chat-admin.yourorg.org"         --output none
az keyvault secret set --vault-name $V --name DOMAIN-CLIENT   --value "https://chat.yourorg.org"       --output none
az keyvault secret set --vault-name $V --name DOMAIN-SERVER   --value "https://chat.yourorg.org"       --output none
az keyvault secret set --vault-name $V --name ADMIN-PANEL-URL --value "https://chat-admin.yourorg.org" --output none
az keyvault secret set --vault-name $V --name ACME-EMAIL      --value "it@yourorg.org"                 --output none
```

Note the difference: `CHAT_DOMAIN` and `ADMIN_DOMAIN` are bare hostnames for the
Caddyfile; the other three are full URLs. Getting these mixed up produces sign-in
loops rather than an error.

Then redeploy.

## Certificates

Handled entirely by Caddy. There is nothing to install, renew, or remember.

The first request for a new hostname takes ten or twenty seconds while the certificate
is issued. After that it is instant.

Two things must be true for issuance to work:

1. DNS resolves the name to this machine.
2. **Port 80 is open.** That is the only reason it is open — the ACME challenge uses
   it. All real traffic is redirected to HTTPS. Closing port 80 does not improve
   security meaningfully, and it does break certificate renewal about sixty days
   later, which is a memorable way to find out.

Certificates and account keys live at `${DATA_DIR}/caddy`, so they survive a redeploy
and are covered by Azure Backup.

## Restricting the admin panel

Three options, roughly in order of how much they cost you.

### By source address

Uncomment the matcher in `Caddyfile`:

```
{$ADMIN_DOMAIN} {
	@notoffice not remote_ip 203.0.113.0/24
	respond @notoffice 403

	reverse_proxy admin-panel:3000
}
```

Simple, and useless for remote staff on changing home addresses.

### No public DNS record at all

Do not create the `chat-admin` record. Reach the panel through an SSH tunnel when you
need it:

```bash
az ssh vm -g rg-librechat-prod -n vm-librechat-prod -- -L 3000:127.0.0.1:3000
# then open http://localhost:3000
```

The panel is bound to `127.0.0.1` on the machine, so this works without any firewall
change. Most secure, least convenient.

### Leave it public

The panel requires an authenticated administrator account. If you run single sign-on
with MFA, this is a reasonable position — it is what Maryland Legal Aid does.

## Changing hostnames later

Migrating from a staging name to a production one is exactly this page again: add DNS,
update the five secrets, redeploy. Caddy requests new certificates on demand and the
old ones expire quietly.

Lower the TTL on the old name at least 24 hours beforehand. A forgotten TTL is the
most common reason a cutover appears to work while half your users are still reaching
the old machine.
