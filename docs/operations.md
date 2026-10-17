# Operations

## First run

```sh
mkdir -p data overlay
podman unshare chown -R 10001:10001 data      # container runs as uid 10001
cp secrets.env.example secrets.env && chmod 600 secrets.env
podman compose up -d --build
podman logs dsbot | head -20
```

The log line `login token (save it now, it will not be printed again): …` is your way
in; the token is also at `/data/auth/token`. With `DSH_AUTH_TOKEN` in the secrets file,
no token is generated.

## Upgrading

Everything version-related is a build argument, so an upgrade is a rebuild:

```sh
podman build -t ghcr.io/your-org/dsbot-containers:0.1.7 \
  --build-arg TOOLS_IMAGE=dsbot-tools:bookworm \
  --build-arg DSH_VERSION=0.2.0-rc.2 \
  --build-arg DS_BOT_VERSION=0.1.7 .
podman compose up -d
```

The compose file takes the image from `DSBOT_IMAGE` (`dsbot-containers:0.1.7` by
default), so a deployment that builds under another name only sets that variable.

The tool image only needs rebuilding when the tools change; it is the expensive layer
(one to two hours cold, seconds from cache). Bumping dsh or ds-bot alone is a quick
rebuild of the second image.

An upgrade never touches the volume: the seed is only copied in when
`/data/profiles/web/package.json` does not exist. To start from a clean profile, back up
`data/` and remove that directory (plugins a Bot installed live there).

## Backups

Everything that matters is `/data`. It also contains credentials (login token, provider
state, plugin state), so encrypt the archive. Stop the container or snapshot the volume;
there is no need to export anything separately.

## Troubleshooting

**`EROFS: read-only file system` when a plugin writes somewhere.** Only `/data`, `/tmp`
and `/run` are writable. The image points pnpm, npm, dsh and the usual caches at `/data`;
a third-party plugin writing to a bare path needs an `ENV` redirect of its own.

**The volume is owned by the wrong uid.** `podman unshare chown -R 10001:10001 data` for
rootless podman, `chown -R 10001:10001 data` for rootful.

**Startup stops with "the login gate is not in the composed config".** Something removed
the gate from the tree — usually an overlay patch that replaced its insert row, or a dsh
version whose peer range the plugin does not cover. Run
`podman exec dsbot dsh --profile web --dump-config | grep dsh-auth-gate`, and check the
gate's `peerDependencies` against the pinned dsh version.

**Startup stops with "declares plugins that could not be installed".** The deployment
layer's `plugins.txt` names something that cannot be installed (offline, typo, private
registry). `podman exec dsbot dsbot-plugins sync --dry-run` shows what it would do;
`OVERLAY_PLUGINS_STRICT=0` lets the container start anyway.

**A setting changed in the UI has no effect.** An overlay patch is overriding it —
overlay is applied last. `dsh --profile web --dump-config` prints the composed tree with
the source file of each entry in a comment.

**A plugin I removed came back after a restart.** It is declared in `plugins.txt`. Remove
the line, or bake the plugin into the image if it must be permanent.

**The UI says "settings are unavailable in this browser".** A dsh-side effect of serving
the web UI from a non-loopback origin (dsh decides how to mirror settings from the
browser's view of the address). Editing `/data/profiles/web/cordis.patch.yml` directly —
or shipping the change as an overlay patch — is the reliable way around it.

**Login works but calls fail with 403.** That is dsh's Host/Origin fence, not the login
gate: name the public authority in `DSH_TRUSTED_HOST` and make sure the reverse proxy
forwards the real `Host` header.
