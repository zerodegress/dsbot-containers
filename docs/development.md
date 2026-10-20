# Development

## Version matrix

The image is only as reproducible as the four versions it pins. They are checked at
build time, not at runtime.

| component | version | pinned by | declared compatibility |
|---|---|---|---|
| dsh | `0.2.1-rc.2` | `DSH_VERSION` | `dsh-authless` declares `engines.dsh >=0.2.1-rc.2 <0.3.0`, and the build refuses a host outside it |
| ds-bot | `0.1.7` | `DS_BOT_VERSION` | peers are `*`; the package declares no `engines` and no `dsBot.verifiedDsh`, so the build has nothing to assert |
<!-- forge:dev-dsbot-pin -->
| dsh-auth-gate | `0.17.4` | `AUTH_GATE_VERSION` | `engines.dsh` and the `@deepseek-ai/dsh-storage-domain` peer both allow `>=0.2.0-rc.1`; the build re-checks the peer range |
| dsh-authless | commit `26fe680` | `AUTHLESS_COMMIT` + `AUTHLESS_SHA256` | `engines.dsh >=0.2.1-rc.2 <0.3.0`; the build parses that range and refuses a pin outside it |
<!-- forge:dev-authless-line -->

Since dsh 0.2.0-rc.2, a plugin whose `@deepseek-ai/dsh*` peer does not cover the running
host is **skipped silently** (`engines.dsh` is not consulted by the loader, which is why
the build checks it itself). Peer ranges are therefore
part of the contract, both for the build check and for the startup preflight.

## Build arguments

| argument | default | used by |
|---|---|---|
| `BASE_IMAGE` | `docker.io/library/node:22.22-bookworm-slim` | `tools/Dockerfile` |
| `WITH_PACK` | `core` | `tools/Dockerfile` — `full` adds the scientific/ML/vision/notebook/crawling half of the Python stack and the bundler/linter/test half of the Node CLIs (+~2.8GB) |
| `WITH_HEAVY` | `0` | `tools/Dockerfile` — adds JDK, TeX Live, Go, Rust (+~2.5GB) |
| `PIP_INDEX_URL` / `NPM_REGISTRY` | upstream | both, for mirrors |
| `DOCKER_CLI_VERSION` | `27.5.1` | tool image |
| `TOOLS_REVISION` | `dev` | tool image provenance stamp |
| `TOOLS_IMAGE` | plain node base | `Dockerfile` — point it at the tool image, or leave it for a tool-less build |
| `DSH_VERSION` | `0.2.1-rc.2` | `Dockerfile` |
| `DS_BOT_VERSION` | `0.1.7` | `Dockerfile` |
| `AUTH_GATE_VERSION` | `0.17.4` | `Dockerfile` — `engines.dsh` is `>=0.2.0-rc.1`, so it covers the pinned dsh |
| `NPM_VERSION` | `12` | `Dockerfile` — the base image ships npm 10.9.8, which has no `--allow-scripts`; the build upgrades npm first and refuses anything older than 11 |
<!-- forge:dev-npm -->
| `AUTHLESS_REPO` | `https://github.com/zerodegress/dsh-authless` | `Dockerfile` — the first-party repository; override it to build from your own fork |
| `AUTHLESS_COMMIT` / `AUTHLESS_SHA256` | commit `26fe680` | `Dockerfile` — the sha256 is checked against whatever `AUTHLESS_REPO` serves, so an override needs its own pair |
| `INSTALL_AUTHLESS` / `INSTALL_AUTH_GATE` | `1` / `1` | `Dockerfile` — should match; the build warns and goes on otherwise |
| `STRICT_VERSIONS` | `1` | `Dockerfile` — `0` downgrades the `verifiedDsh` mismatch to a warning |
| `IMAGE_SOURCE` | `https://github.com/your-org/dsbot-containers` | `Dockerfile` — the OCI `source` label; a deployment sets its own repository |

**The authless source has a working default** — the first-party repository at the pinned
commit. A deployment that builds from its own fork must pass `AUTHLESS_REPO` together with
that fork's `AUTHLESS_COMMIT` / `AUTHLESS_SHA256`: the pinned sha256 only verifies the tree
it came from.

## Building and publishing

```sh
# core pack by default; add --build-arg WITH_PACK=full for the scientific stack
podman build -t dsbot-tools:bookworm -f tools/Dockerfile tools
# forge:dev-build-cmd
podman build -t ghcr.io/your-org/dsbot-containers:0.1.7 \
  --build-arg TOOLS_IMAGE=dsbot-tools:bookworm \
  --build-arg DSH_VERSION=0.2.1-rc.2 \
  --build-arg DS_BOT_VERSION=0.1.7 .
podman push ghcr.io/your-org/dsbot-containers:0.1.7
```

A deployment that needs a different dsh line overrides the default at build time with
`--build-arg DSH_VERSION=…`; this repository keeps pinning `0.2.1-rc.2` as its default.

Tags follow the DS Bot version the image was built against, so `0.1.7` pairs with
`ds-bot@0.1.7`. Record the resulting dsh version and plugin versions in the release notes
(`/etc/dsbot-versions` inside the image prints them).
<!-- forge:dev-tag-line -->

When the dsh line moves, `dsh-authless` needs a matching release before the image can
follow: it replaces the connection service's browser-auth owner, and that field belongs to
`@deepseek-ai/dsh-client-connection`. Do that as a commit in the repository, then bump
`AUTHLESS_COMMIT` and `AUTHLESS_SHA256` here. Nothing is patched at build time, so the
image cannot drift from what the plugin says it supports.

<!-- forge:dev-carried-model -->
## The carried-package model

ds-bot is not installed into the profile. It is unpacked into the dsh
installation and registered in that package.json, and the base layer inserts the
row. dsh resolves a bundle from the **installation anchor first**, then the
profile (`resolveBundleDir` in `@deepseek-ai/dsh-app-boot`), so the carried copy
is the one that runs and a copy under `profiles/web/node_modules/ds-bot` is
shadowed. Consequences:

- `dsh plugin --profile web add ds-bot.tgz` cannot change the running version;
- a version drift cannot be repaired at runtime at all (the runtime is non-root
  on a read-only root) — bump `DS_BOT_VERSION` and rebuild;
- the entrypoint resolves ds-bot the way dsh does and reports the answer: the
  shadowed copy, and any drift. `STRICT_DS_BOT_VERSION=1` makes drift fatal.

docs/recipes.md has the line-by-line comparison with the upstream reference.

## Checks that run without a container

```sh
sh -n entrypoint.sh && shellcheck -s sh -S warning entrypoint.sh
node --check scripts/dsbot-plugins.js
python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]" \
  compose.yaml dsh-layers/base-layer.patch.yml examples/10-providers.example.patch.yml
```

`dsbot-plugins sync --dry-run` with `DSH_BIN` pointing at a stub exercises the reconcile
logic without dsh, and `DSH_HOME` pointing at a throwaway directory keeps it away from a
real profile.

## Conventions

- **Commit messages** follow [Conventional Commits](https://www.conventionalcommits.org/):
  `feat(scope): …`, `fix(scope): …`, `docs: …`, `chore: …`. The repository is managed with
  [Jujutsu](https://jj-vcs.github.io/jj/), so the change description carries the reasoning
  — prefer that over long historical comments in the files.
- **CHANGELOG.md** follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/): add
  entries under `## [Unreleased]`, and move them under a version heading when releasing.
- **Comments in files** explain what the code assumes and how it is meant to be used, not
  how it got that way.

## License status

The repository's own license is not decided yet. Upstream components keep their licenses:
DeepSeek Harness and DS Bot by their authors, and `dsh-auth-gate` and `dsh-authless` under
MIT. Decide and add a `LICENSE` file before publishing images.
