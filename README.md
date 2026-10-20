# dsbot

A reproducible container image for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(dsh) with [DS Bot](https://github.com/Fei2411/DeepSeek-Bot) — a team of long-lived Bots
with memory, group chats and a main Bot that runs the show.

```
ghcr.io/your-org/dsbot-containers:0.1.7
```

The image pins every version, keeps all state in one volume, and lets a deployment
customise dsh without ever editing the image. It ships two plugins that must be used
together: `dsh-authless` (serves the Web UI without the launch-token check, while the
Host/Origin fence stays) and `dsh-auth-gate` (a login gate that replaces the token gate
authless removes). See
[docs/security.md](docs/security.md) before exposing it to anything.

## Quick start

```sh
git clone <this repo> && cd dsbot
cp secrets.env.example secrets.env && chmod 600 secrets.env
mkdir -p data overlay && podman unshare chown -R 10001:10001 data

podman build -t dsbot-tools:bookworm -f tools/Dockerfile tools
# AUTHLESS_REPO defaults to the first-party repository, so this build needs no
# override. Pass AUTHLESS_REPO / AUTHLESS_COMMIT / AUTHLESS_SHA256 to build from
# your own fork of it instead.
podman build -t dsbot-containers:local --build-arg TOOLS_IMAGE=dsbot-tools:bookworm .

podman run -d --name dsbot --user 10001:10001 --read-only \
  --tmpfs /tmp:mode=1777 --tmpfs /run:mode=755 \
  --security-opt no-new-privileges --cap-drop ALL \
  --secret dsh_env,type=mount,source=./secrets.env,target=dsh.env \
  -v ./data:/data -v ./overlay:/etc/dsbot/overlay:ro dsbot-containers:local
podman logs dsbot | head            # prints the login token once
```

`podman compose up -d --build` does the same with the arguments in
[compose.yaml](compose.yaml); nothing there needs to be filled in for a default build.

## Layers

| | what | where |
|---|---|---|
| L1 | toolchain image (`dsbot-tools`) | `tools/Dockerfile` |
| L2 | dsh + ds-bot + bundled plugins | `Dockerfile` |
| L3 | deployment config: providers, models, plugins, any cordis patch | mounted at `/etc/dsbot/overlay`, read-only |
| L4 | all state: profiles, bot data, sessions, memory | the `/data` volume |

dsh applies the volume profile first, then the image base layer, the mounted overlay, the
Bot's own patches in the volume, and finally the bundled plugins' patches: the deployment
tunes the base, the Bot tunes both, and the plugins the image carries keep the last word.
[docs/architecture.md](docs/architecture.md) has the full order and the three ways a
plugin can reach a container.

The entrypoint imports secrets, seeds the volume on first start, reconciles the
plugins declared by the overlay, composes the patch order, then verifies at startup
that the login gate is really active before letting dsh bind.

## Docs

- [architecture.md](docs/architecture.md) — layer model, patch precedence, plugin mechanisms
- [configuration.md](docs/configuration.md) — overlay, providers, plugins, secrets, env vars
- [security.md](docs/security.md) — the authless + login gate pair, startup probes, caveats
- [operations.md](docs/operations.md) — first run, upgrades, backups, troubleshooting
- [development.md](docs/development.md) — build arguments, version matrix, how to publish
- [CHANGELOG.md](CHANGELOG.md)

## Credits and license

DeepSeek Harness and DS Bot are their authors' projects, under their own licenses.
`dsh-auth-gate` and `dsh-authless` are MIT; each is pinned by version or commit and
called out in [docs/security.md](docs/security.md). This repository's own license is not
decided yet — see [docs/development.md](docs/development.md).
