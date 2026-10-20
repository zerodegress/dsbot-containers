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
the image base layer — so it overrides both the settings UI and the base layer, but the
bundled plugins' own patches (authless, the login gate) are applied after it. Use numeric prefixes when the order between your own files matters.

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

## Where a patch can live

There is no layer owned by the Bot. Configuration has exactly three entry points:

| entry point | file | what belongs there |
| --- | --- | --- |
| settings UI | `$DSH_HOME/profiles/web/cordis.patch.yml` | anything the user tunes per instance |
| image base | `dsh-layers/base-layer.patch.yml` | rows that must exist for the instance to run |
| deployment | `/etc/dsbot/overlay.yml`, `/etc/dsbot/overlay/*.patch.yml` | providers, models, endpoints |

dsh composes the volume profile *before* every `--patch` layer, so a setting made in the
UI loses to the image base and to the deployment whenever both write the same row.

Earlier images also created `$DSH_HOME/patches/` and passed its files to dsh after the
deployment layer. That layer was removed: the agent's file sandbox grants only the
session workspace, never `$DSH_HOME`, so nothing running in the container could ever
write it — a layer nobody can write reads like an escape hatch but is a trap. If an
instance needs a patch that is not part of the image or the deployment, add it to the
deployment's `overlay/` directory and restart.

Patches are read at startup, so any of the three takes effect on the next restart.

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

## The sandbox's write set, and where the caches go

The agent shell does not run with the container's full write access. Every command goes
through dsh's local sandbox, and on Linux that is a Landlock profile whose writable roots
are hard-coded to exactly three paths:

- the session workspace (the Bot's working directory),
- `/tmp`,
- the process's private tmpdir.

There is **no policy setting that adds a root** — `writableRoots()` in
`@deepseek-ai/dsh-sandbox` returns that fixed list, and `landlockProfileArgs()` in
`@deepseek-ai/dsh-sandbox-local` turns it into the actual grant. Everything else, including
`/data` and the rest of the volume, is read-only to the agent even though the container
mounts it read-write and the files are owned by uid 10001.

Three consequences worth knowing before debugging anything:

1. **`test -w` and `os.access()` lie here.** They ask the kernel's DAC check, which Landlock
   does not participate in, so `/data/.cache` reports "writable" and then `mkdir` fails with
   `EACCES`. Any probe in this image has to *really write* something.
2. **The image's own cache variables are unreachable from the agent.** `HOME=/data`,
   `npm_config_cache=/data/.npmcache`, `PNPM_HOME=/data/.pnpm-home`, `XDG_CACHE_HOME=/data/.cache`
   are all outside the grant, so git, npm, pnpm, uv, pip and cargo fail — each with a
   different, usually misleading, error (npm suggests `sudo chown`, which cannot help).
3. **Two sizeable installs only need XDG, not HOME.** With `XDG_CONFIG_HOME` (and for
   LibreOffice also `XDG_CACHE_HOME`) pointed inside the workspace, the bundled Chromium
   renders and `soffice --headless --convert-to pdf` produces a real PDF. With the image
   defaults both fail: Chromium with "Failed to create headless user data directory
   container", LibreOffice with "User installation could not be completed". That is ~1.2 GB
   of image that was previously installed-but-unusable.

`/opt/dsbot/agent-env.sh` closes the gap: every non-interactive bash sources it through
`BASH_ENV` and, when it can create the directories, moves `HOME`, the XDG roots and every
cache into a `.home` tree on the volume (inside the grant, and it survives a restart).

**`HOME` moves with them, inside the agent shell only.** The image and the entrypoint keep
`HOME=/data`; in the agent shell `HOME` becomes the adopted root. That is what makes git and
jj work without extra variables, at the cost of one surprise: inside the agent shell `~` is
no longer `/data`. The container-level `HOME` is unchanged, so nothing outside the shell
sees the difference.

Which root it picks, most specific first:

| candidate | why |
|---|---|
| `DSBOT_AGENT_HOME` | sticky — a child shell that `cd`s elsewhere keeps the same caches |
| nearest existing `.home` walking up from `$PWD` | so a command run in `docs/` does not grow a second cache tree |
| `$PWD/.home` | first shell in a workspace |

A candidate is only accepted if its directories can really be created. The walk can leave the
session workspace and find *another Bot's* `.home`, which looks like a marker and is not
writable; sharing a cache tree across Bots would be worse than not adopting at all, so a
failing candidate is skipped and the next one is tried.

It never adopts a tmpfs: `$PWD` under `/tmp`, `/dev/shm` or `/run` is refused outright. Those
are 256 MB, noexec, or both — a cache tree there fills up and then breaks every later command
in the session, silently.

Two of the entries are identity files rather than caches, and both are the difference between
"installed" and "usable": `JJ_CONFIG` and `GIT_CONFIG_GLOBAL`. Neither falls back to
`XDG_CONFIG_HOME`, and without them `jj config set --user` and `git commit` both fail.

Go has three variables that have to move together, and they are the reason the overlay is
tested rather than assumed. `GOPATH` is not a cache: it is where `go install` writes its
binaries (`$GOPATH/bin`), while `GOMODCACHE` and `GOCACHE` hold the module and build caches.
Move the two caches into the workspace and leave `GOPATH` at `/data/.go`, and the split is
exactly wrong: `go build` works, `go install` fails with `permission denied` on its own
output directory, and the error reads like a broken toolchain. `agent-env.sh` sets all three
from the same root, and `doctor.sh` writes one file into each — the only check that survives
Landlock — plus a named warning when `GOPATH` sits outside `HOME`.

### Where `BASH_ENV` does not reach

The overlay is applied by bash's startup file, so it has two edges worth knowing:

- **`sh -c` does not read `BASH_ENV`.** dash reads `$ENV`, not this, so `sh -c 'npm config
  get cache'` still reports the image's `/data` path. Use bash, or source the file explicitly.
- **A child a program spawns with a hand-built environment never sees it.** If a tool
  constructs `env` from a few variables instead of inheriting, the overlay is absent for that
  child. That is not a bug to fix here; it is the boundary of this mechanism, and the reason
  the plugin (per-execution env injection) remains the fallback if bash is ever replaced.

`DSBOT_AGENT_ENV_ALWAYS=1` arms the overlay without a session marker, `DSBOT_NO_AGENT_ENV=1`
disables it, `DSBOT_AGENT_HOME` pins the root — all three exist so a broken assumption can be
recovered without rebuilding the image.

The variables in the table below stay as they are: those are what the entrypoint, dsh
itself and any unsandboxed child use, and they are the list `agent-env.sh` overrides.

The script is deliberately conservative, and its contract is checked at build time:

| behaviour | why |
|---|---|
| armed only when `DSH_SESSION_ID` is set | image builds and the entrypoint have no session, so they are unaffected |
| adopts a directory only after a real `mkdir -p` succeeds | `test -w` cannot see Landlock; a failed probe leaves the environment untouched |
| moves `HOME` only when the whole tree moved | git, jj, npm and Java all key off it; a half-move is what breaks tools |
| prints nothing | it runs before every command in the container |
| `DSBOT_NO_AGENT_ENV=1` disables it | escape hatch when a tool wants the image's `/data` paths |
| `DSH_AGENT_ROOT` overrides the anchor | for a shell started outside the workspace |

**Silent failures.** Four tools in this image fail while returning exit code 0 (or with a
message that looks harmless), so a check that only reads `$?` is worthless: `soffice
--version` prints nothing, `mtr` cannot open a raw socket without `CAP_NET_RAW`, and
`dsh --dump-config` prints a row for a module that will not load. Verify by *doing the
thing and inspecting the artifact* — a written PDF, a written config file, a rendered DOM.


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
| `BASH_ENV` | `/opt/dsbot/agent-env.sh` | sourced by every non-interactive bash; points `HOME`, XDG and the caches at `<cwd>/.home` |
| `DSBOT_NO_AGENT_ENV` | `0` | `1` disables the cache overlay for one shell |
| `DSH_AGENT_ROOT` | `$PWD/.home` | anchor `agent-env.sh` uses when it cannot trust the cwd |
| `DSBOT_AGENT_HOME` | – | the root the overlay adopted; exported so child shells reuse it |
| `JJ_CONFIG` | `/data/.config/jj/config.toml` | jj's user config; the overlay points it at `<cwd>/.home/.config/jj/` |
| `GIT_CONFIG_GLOBAL` | `/data/.config/git/config` | git's global config; the overlay points it at `<cwd>/.home/.config/git/` |
| `GOPATH` | `/data/.go` | Go workspace; the overlay points it at `<cwd>/.home/.go`, together with `GOMODCACHE` and `GOCACHE` |

Build-time arguments are listed in [development.md](development.md).

## Where the agent can write

The image puts the cache directories on the volume — `HOME=/data`,
`XDG_CACHE_HOME=/data/.cache`, `npm_config_cache=/data/.npmcache`,
`npm_config_prefix=/data/.npm-global`, `PNPM_HOME=/data/.pnpm-home` — so a process started
by the entrypoint has a writable home. The agent does not: dsh runs each Bot's shell under
a file sandbox (`workspace-write`), and in the instances we measured the sandbox allows
only that Bot's own workspace plus `/tmp`.

The permission bits do not show it. `/data` subdirectories owned by the runtime user are
reported as writable and are still denied:

| path | `test -w` | real `touch` |
|---|---|---|
| `/data/.cache` | true | `Permission denied` |
| `/data/bot/workspace` (parent of the Bot workspace) | true | `Permission denied` |
| `/data/bot/workspace/<bot>` | true | ok |
| `/tmp` | true | ok |

Consequences:

- do not gate a health check on `test -w` or `access(2)`; they report the permission bits,
  not the sandbox. Write a probe file and delete it.
- a tool that keeps its cache under `$HOME` fails until the path is redirected into the
  Bot's workspace: `HOME=… XDG_CACHE_HOME=… npm_config_cache=… pnpm --store-dir …
  UV_CACHE_DIR=…`. LibreOffice needs `-env:UserInstallation=file://…`, Chromium
  `--user-data-dir=…`.
- `pip install` into `/opt/venv` fails with `Read-only file system`: that is the read-only
  root, not the sandbox. Use a venv inside the workspace.
- Java tools do not follow `$HOME` for `user.home`; they read the passwd entry. Pass
  `-Duser.home=…` explicitly.

An image-side default (a `source`-able env file) can point those variables at a directory
the sandbox allows, but the allow-list itself belongs to the dsh deployment, not to this
image.
