# 4. First login

Ten minutes. This is where it becomes a running system.

## Start it

```bash
az vm run-command invoke \
  --resource-group rg-librechat-prod \
  --name vm-librechat-prod \
  --command-id RunShellScript \
  --scripts "/srv/librechat/app/scripts/deploy.sh --force" \
  --query "value[0].message" -o tsv
```

This takes three to five minutes. It downloads the container images, builds the
configuration, starts everything, and waits for the application to report itself
healthy. The output tells you what it did at each stage.

You are looking for the last line:

```
[deploy 14:32:07] deployed a3f9c21b4e77 successfully
```

If it fails, it rolls itself back and says so loudly. See
[When it breaks](../troubleshooting.md).

This is the only time you run this by hand. From now on the machine checks this
repository every five minutes and deploys anything new on its own.

## Open it

Go to `https://chat.yourorg.org`.

The first request for a hostname is slow — ten or twenty seconds — because that is
when the certificate is being issued. Afterwards it is instant. If you get a
certificate warning, the name is not resolving to this machine yet; go back to
[step 3](03-dns.md).

## Create your account

Click **Sign up** and create an account with your work email address.

**The first account created becomes the administrator automatically.** Make sure it
is yours.

## ⚠️ Close registration

Right now, anyone who finds your URL can create an account. Fix that before you tell
anyone the address.

Choose one:

=== "Restrict to your email domains (recommended)"

    Keeps self-service signup for your colleagues, and refuses everyone else.

    Edit `librechat.yaml` in your fork of this repository, find the `registration:`
    block, and uncomment `allowedDomains`:

    ```yaml
    registration:
      socialLogins: ['openid']
      allowedDomains:
        - "yourorg.org"
    ```

    Commit and push. The machine picks it up within five minutes.

=== "Close it entirely"

    No self-service signup at all; you create every account in the admin panel.

    ```bash
    az keyvault secret set --vault-name kv-librechat-prod \
      --name ALLOW-REGISTRATION --value "false" --output none
    ```

    Then redeploy so the change takes effect:

    ```bash
    az vm run-command invoke -g rg-librechat-prod -n vm-librechat-prod \
      --command-id RunShellScript \
      --scripts "/srv/librechat/app/scripts/deploy.sh --force" \
      --query "value[0].message" -o tsv
    ```

=== "Use your existing single sign-on"

    The best option if you have Entra ID, Google Workspace or Okta — nobody gets a
    separate password, and removing someone from your directory removes their
    access here.

    See **[Single sign-on](../modules/sso-oidc.md)**. It takes about twenty minutes.

!!! note "Changing a secret does not deploy anything on its own"
    The five-minute timer watches this git repository, not your key vault. After
    changing a secret, run `deploy.sh --force` as above.

## Check the admin panel

Go to `https://chat-admin.yourorg.org` and sign in with the same account. You should
be able to list users.

Sign in as a non-administrator later and confirm you are refused — the panel is a
thin client over the application's own permissions, so a signed-in user without the
admin role gets nothing from it, but it is worth seeing that for yourself.

## Send a message

Pick a model from the dropdown and say hello. If you get an answer, everything works:
the application, the database, the certificate, your API key, and the model.

If the model list is empty or a message returns an error, see
[When it breaks](../troubleshooting.md#i-cannot-send-a-message).

---

Next: **[Make it yours](05-make-it-yours.md)**
