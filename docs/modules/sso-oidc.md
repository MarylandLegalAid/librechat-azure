# Single sign-on (OIDC)

Staff sign in with the account they already have. Nobody manages another password, and
removing someone from your directory removes their access here.

This is what Maryland Legal Aid runs, with Microsoft Entra ID. It is **not** the
default for this blueprint, because requiring an identity provider before anyone can
see a working instance is the single highest-friction step there is.

Entra ID, Google Workspace and Okta all speak OIDC. The setup is the same shape for
each; the screens differ.

## Worth doing when

- You have more than a handful of users
- Offboarding needs to actually remove access
- Your security policy requires MFA, which your identity provider already enforces

## Entra ID

### 1. Register an application

Azure Portal → **Microsoft Entra ID** → **App registrations** → **New registration**.

- Name: something recognizable, e.g. `LibreChat`
- Supported account types: **Accounts in this organizational directory only**
- Redirect URI: **Web**, `https://chat.yourorg.org/oauth/openid/callback`

Note the **Application (client) ID** and **Directory (tenant) ID**.

### 2. Create a client secret

**Certificates & secrets** → **New client secret**. Copy the **Value** immediately —
it is shown once.

Set an expiry you will remember. A secret quietly expiring 24 months from now, locking
every user out on a Tuesday morning, is a genuinely common outcome. Put the date in a
calendar now.

### 3. Add the redirect URIs you will need later

Add them all now, while you are here:

```
https://chat.yourorg.org/oauth/openid/callback
https://chat-admin.yourorg.org/oauth/openid/callback
```

If you are migrating and have a staging hostname, add that too. Discovering a missing
redirect URI mid-cutover is avoidable and annoying.

### 4. Configure it

```bash
V=kv-librechat-prod
TENANT=$(az account show --query tenantId -o tsv)

az keyvault secret set --vault-name $V --name OPENID-CLIENT-ID     --value "<application id>" --output none
az keyvault secret set --vault-name $V --name OPENID-CLIENT-SECRET --value "<secret value>"   --output none
az keyvault secret set --vault-name $V --name OPENID-ISSUER \
  --value "https://login.microsoftonline.com/${TENANT}/v2.0/" --output none
az keyvault secret set --vault-name $V --name OPENID-SESSION-SECRET --value "$(openssl rand -hex 32)" --output none
az keyvault secret set --vault-name $V --name OPENID-BUTTON-LABEL   --value "Sign in with Microsoft" --output none

# Turn social login on, and password signup off
az keyvault secret set --vault-name $V --name ALLOW-SOCIAL-LOGIN        --value "true"  --output none
az keyvault secret set --vault-name $V --name ALLOW-SOCIAL-REGISTRATION --value "true"  --output none
az keyvault secret set --vault-name $V --name ALLOW-REGISTRATION        --value "false" --output none
az keyvault secret set --vault-name $V --name ALLOW-EMAIL-LOGIN         --value "false" --output none
```

Then redeploy.

!!! warning "Keep one password account until you have tested SSO"
    Setting `ALLOW_EMAIL_LOGIN=false` before confirming single sign-on works locks
    everyone out, including you.

    Test the SSO login in a private browser window first, and only then turn password
    login off.

### 5. Who is an administrator

Gate the admin role on an Entra group rather than assigning it by hand:

```bash
az keyvault secret set --vault-name $V --name OPENID-ADMIN-ROLE \
  --value "<the group's object id>" --output none
az keyvault secret set --vault-name $V --name OPENID-ADMIN-ROLE-PARAMETER-PATH \
  --value "groups" --output none
```

You will need the app registration to emit group claims: **Token configuration** →
**Add groups claim**.

Now administrator access is managed where the rest of your access is managed.

### 6. Optional: search for colleagues when sharing

Lets users share an agent by typing a colleague's name instead of their full address:

```bash
az keyvault secret set --vault-name $V --name USE-ENTRA-ID-FOR-PEOPLE-SEARCH --value "true" --output none
az keyvault secret set --vault-name $V --name OPENID-GRAPH-SCOPES \
  --value "User.Read,People.Read,GroupMember.Read.All,User.ReadBasic.All" --output none
```

Those Graph permissions need admin consent on the app registration.

## Google Workspace and Okta

The same variables, different values:

| | Google Workspace | Okta |
|---|---|---|
| `OPENID_ISSUER` | `https://accounts.google.com` | `https://yourorg.okta.com/oauth2/default` |
| Where to register | Google Cloud Console → Credentials → OAuth client ID | Okta Admin → Applications → Create App Integration → OIDC Web |
| Redirect URI | `https://chat.yourorg.org/oauth/openid/callback` | the same |

`OPENID_ADMIN_ROLE_PARAMETER_PATH` is whatever claim your provider puts groups in —
for Okta that is usually `groups`, once you have added a groups claim to the
authorization server.

## The admin panel

The admin panel delegates authentication to the chat application, which is why
`ADMIN_PANEL_URL` has to be set correctly. If it is wrong or missing, admin sign-in
fails in a way that does not point at this as the cause.

The panel's callback goes through the app's own domain:

```
https://chat.yourorg.org/api/admin/oauth/openid/callback
```

## When it does not work

| Symptom | Usually |
|---|---|
| `redirect_uri_mismatch` | The URI registered does not match byte for byte. Check `https` and the trailing path. |
| Signs in, immediately signed out | `DOMAIN_CLIENT` / `DOMAIN_SERVER` do not match the URL in the browser. |
| Works, but nobody is an admin | Group claims are not in the token. Check Token configuration. |
| Worked for months, then stopped | The client secret expired. |
