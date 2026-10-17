# Configuration

Everything a deployment changes lives in the **overlay**, mounted read-only at
`/etc/dsbot/overlay`. The image is never edited.

```sh
overlay/
├── 10-providers.patch.yml     cordis patch, applied in name order, above the volume
├── 20-ui.patch.yml
├── plugins.txt                dsh plugins to install into the volume profile
└── plugins/my-plugin/         local plugin directories (named in plugins.txt)
```

## Cordis patches

Any `*.patch.yml` in the directory is passed to dsh as `--patch`, in name order, after
the volume profile — so it overrides the settings UI, but **not the image**: the image's
own patches (`dsh-layers/base-layer.patch.yml` and the bundled plugins' bundle patches)
are applied last and keep the last word. Use numeric prefixes when the order between your
own files matters.

A patch is the normal dsh format; see
[`examples/10-providers.example.patch.yml`](../examples/10-providers.example.patch.yml).
The examples shipped with the repository live in `examples/` and are never mounted:
copy the one you want into `overlay/` under its real name.
Two things are worth knowing:

- A config override **replaces the whole entry**, so restate every key you rely on.
- The row id must match the mounted plugin's id (`llm-pi-ai`, `agent-default-model`,
  `web`, `bot`, `dsh-auth-gate`, …), otherwise the patch is ignored with a warning.

Provider keys are referenced by environment variable name (`apiKeyEnv`) and never
written into the patch. Put the values in the secrets file.

## Plugins

`plugins.txt` declares dsh plugins; the entrypoint reconciles them on every start:

```text
some-plugin@1.2.3        # npm, pinned: a different installed version is replaced
some-plugin              # npm, unpinned: install once, then leave it alone
@scope/pkg@^2.0.0        # scoped names work the same way
my-plugin                # a directory in overlay/plugins/my-plugin
/mnt/elsewhere/other     # explicit path; relative paths resolve against plugins.txt
```

Local directories are staged into `/data/.overlay-plugins/<name>` (skipping
`node_modules` and `.git`) and then linked, because pnpm cannot write into a read-only
mount. Anything already installed is skipped without a network call, so a start with an
unchanged declaration stays offline.

```sh
podman exec dsbot dsbot-plugins list
podman exec dsbot dsbot-plugins sync --dry-run
podman exec dsbot dsbot-plugins sync --force
```

A plugin declared here and removed at runtime comes back on the next start. Bake it into
the image instead if that is not wanted.

## Secrets

Compose or the runtime mounts a file at `/run/secrets/dsh.env`; the entrypoint imports it
with `set -a` before doing anything else. The file is a plain `KEY=VALUE` list, 0600, out
of git — see [`secrets.env.example`](../secrets.env.example).

`/docker-entrypoint.d/*.sh` runs after the secrets import, which is where an external
injector (Vault, 1Password, a cloud secret manager) plugs in.

Credentials from the deployment layer end up in the volume: `/data/auth/token` in token
mode, `/data/profiles/web/node_modules` for plugin state. A backup of `/data` is a
backup of your secrets.

## Environment variables

| variable | default | meaning |
|---|---|---|
| `DSH_HOME` | `/data` | dsh home; the only path that must be a volume |
| `DSH_PORT` | `3080` | port dsh listens on inside the container |
| `DSH_BIND_HOST` | `127.0.0.1` | `0.0.0.0` exposes the port; the login gate is then the only door and the startup probe must pass |
| `DSH_PUBLIC_URL` | – | public URL for links; `--public-url` only exists from dsh 0.2.1, older versions log a note and ignore it |
| `DSH_TRUSTED_HOST` | – | extra authorities for dsh's Host/Origin fence (required behind a reverse proxy or named tunnel) |
| `DSH_AUTH_TOKEN` | – | login gate shared token; generated into `/data/auth/token` and printed once when unset |
| `OVERLAY_DIR` | `/etc/dsbot/overlay` | where the deployment layer is mounted |
| `OVERLAY_PLUGINS_STRICT` | `1` | `0` downgrades a failed plugin install from "refuse to start" to a warning |
| `SKIP_OVERLAY_PLUGINS` | `0` | `1` skips the plugin reconcile entirely |
| `SKIP_GATE_CHECK` | `0` | `1` disables the preflight and the startup probe (debugging only) |

Build-time arguments are listed in [development.md](development.md).
