# SSH with Entra ID

Sign in to the machine with your organizational account instead of managing key files.

## Why bother

- **No key files to distribute, protect or collect back** when someone leaves.
- **Access is managed where the rest of your access is managed.** Removing someone
  from your directory removes their access to the machine.
- **MFA applies**, because your identity provider enforces it.
- Every session is attributable to a person rather than to whoever holds a key.

The `AADSSHLoginForLinux` extension is installed by `infra/main.bicep`, so the machine
side is already done.

## Grant someone access

Two roles, and the difference matters:

| Role | Gives |
|---|---|
| **Virtual Machine User Login** | Sign in as an ordinary user |
| **Virtual Machine Administrator Login** | Sign in with `sudo` |

```bash
VM_ID=$(az vm show -g rg-librechat-prod -n vm-librechat-prod --query id -o tsv)

az role assignment create \
  --role "Virtual Machine Administrator Login" \
  --assignee "person@yourorg.org" \
  --scope "$VM_ID"
```

Keep the administrator list to the people who actually need it. Everyone who has it
can read every secret the machine can read.

## Sign in

```bash
az login
az ssh vm -g rg-librechat-prod -n vm-librechat-prod
```

That is the whole thing. No key file, no `authorized_keys`, no `-i`.

## ⚠️ Certificates expire

Entra SSH works by issuing a short-lived certificate. **When it expires, the failure
looks like a broken key, not an expired credential:**

```
Permission denied (publickey).
```

Nothing says "expired". This has cost real time in real investigations.

The fix:

```bash
az ssh config --file ~/.ssh/config -g rg-librechat-prod -n vm-librechat-prod
```

Or just run `az ssh vm` again, which refreshes it.

**If you get `Permission denied (publickey)` on a machine you know you have access
to, refresh the certificate before investigating anything else.**

## The break-glass key

The SSH key pair from `infra/main.bicep` still works and does not depend on Entra ID
being reachable:

```bash
ssh -i ~/.ssh/librechat azureuser@<public ip>
```

Keep it somewhere you can get to when your identity provider is the thing that is
broken. That is the scenario it exists for.

## Locked out

If your public address changed, SSH is refused at the network before it reaches the
machine and no key or certificate helps. See
[When it breaks](../troubleshooting.md#locked-out-of-ssh) — the fix is a one-minute
firewall edit in the portal and needs no SSH.

## Doing things without SSH at all

Most operational tasks do not need a shell. `az vm run-command` runs a command on the
machine through the Azure control plane, which works even when SSH does not:

```bash
az vm run-command invoke -g rg-librechat-prod -n vm-librechat-prod \
  --command-id RunShellScript \
  --scripts "docker compose -f /srv/librechat/app/compose.yaml ps" \
  --query "value[0].message" -o tsv
```

It needs `Virtual Machine Contributor`, not the SSH login roles. That is also how the
deploy pipeline works.

!!! warning "Its output is wrapped, and its exit code lies"
    `run-command` returns:

    ```
    Enable succeeded:
    [stdout]
    ...
    [stderr]
    ...
    ```

    and exits zero as long as it managed to run *something* — the script's own exit
    status is buried in that text. If you build automation on it, parse the output.
    A failed command otherwise reports success.
