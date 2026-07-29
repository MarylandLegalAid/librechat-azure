# Modules

One page per optional capability. Each says what it does, what it costs, what it
takes to turn on, and — where relevant — why Maryland Legal Aid turned it on or
left it off.

Nothing here is required. A working instance is the [Quickstart](../quickstart/index.md)
and nothing else. Add these when you have a reason.

## How optional things are switched on

There is one code path, not a "core" and a "full" version. Optional services are
Docker Compose **profiles**, off unless you name them:

```
COMPOSE_PROFILES=mcp-legalserver,mcp-letterwriter
```

Optional features are environment variables that are inert until filled in.

That means the configuration you run is the configuration we run and test, with more
or less of it switched on. It also means there is no second, unvalidated
configuration quietly rotting in a corner of the repository.

## The pages

### Running it

| | |
|---|---|
| [How deploys work](deployment.md) | The one deploy path, its two triggers, and how rollback works. Read this before you change anything. |
| [Upgrading LibreChat](upgrading.md) | What to check before merging the Renovate pull request. |
| [Backup and restore](backups.md) | Two backups, what each protects, and how to prove they work. |
| [SSH with Entra ID](entra-ssh.md) | Signing in to the machine without managing key files. |

### Making it yours

| | |
|---|---|
| [Your branding](branding.md) | Name, logo, favicons, welcome message, terms of service. |
| [Your own domain](custom-domain.md) | Hostnames, certificates, and restricting the admin panel. |
| [Single sign-on (OIDC)](sso-oidc.md) | Entra ID, Google Workspace, Okta. What Maryland Legal Aid runs. |

### Models

| | |
|---|---|
| [Adding and retiring models](models.md) | The routine process, and the one part that is not routine. |
| [GPT-5.6 and the Responses API](models-gpt56-responses.md) | **The least obvious thing here.** Read before touching model configuration. |

### Extending it

| | |
|---|---|
| [Custom tools (MCP)](mcp-servers.md) | How tool servers work here, and how to write your own. |
| [LegalServer tools](mcp-legalserver.md) | Read-only matter, document and discovery tools. |
| [LetterWriter](mcp-letterwriter.md) | Letters on your own letterhead, returned as a document. |
| [Code interpreter](code-interpreter.md) | Running generated code in a sandbox. Needs a second machine. |

### Storage and migration

| | |
|---|---|
| [S3 and legacy file storage](storage-s3-legacy.md) | Why files live on disk, and how to keep serving files already in S3. |
| [Migrating an existing install](migrating-an-existing-install.md) | Moving a running LibreChat here without losing anything. |
