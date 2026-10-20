# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Image tags carry the DS Bot version the image was built against, so `0.1.7` is
`ds-bot@0.1.7`.

## [Unreleased]

### Removed

- The `dsh-shutup` pin: the image no longer fetches that unlicensed fork at build time.
- The Bot's own configuration layer (`$DSH_HOME/patches/*.patch.yml`). Nothing running
  in the container could write it — the file sandbox grants only the session workspace —
  so it was dead weight that read like an escape hatch. Configuration has three entry
  points now: the settings UI, the image base and the deployment layer.

### Added

<!-- forge:changelog-added -->
- OCI image labels, so a registry listing describes the image on its own.
- A skill the image ships, `dsbot-self-config` (`/opt/dsh-skills/`): the layer stack,
  the three places a patch can live, the patch format's rules, and how to verify a
  change with `--dump-config`.
- `scripts/entrypoint-test.mjs`: the entrypoint regression runs on temporary
  volumes with `--network none`, including the ds-bot shadowing and drift cases.
- The image prints `/etc/dsbot-recipe` next to `/etc/dsbot-versions`: one line per
  artifact, and where it came from.
- The build asserts that `ds-bot` exposes its `web-search` subpath and that the base
  layer's `web-search-auto` row lands in the composed tree, so a version bump that
  renames or drops that bundle fails the build instead of leaving a row that points
  nowhere.
- `scripts/check-dsh-authless.js`: the build parses the plugin's `engines.dsh` range,
  refuses a pin outside it, and checks that its bundle patch inserts exactly one row
  named `dsh-authless`.

### Changed

- The build-time base sanity check follows the base this repository pins: it requires
  node `>= 22.22.2` (what the default `NPM_VERSION=12` needs) instead of `>= 22.19`, so a
  base that cannot install npm 12 fails at step 0 instead of at the npm upgrade.
- Patch order is now, lowest first: image base layer → deployment layer → the bundled
  plugins' patches. The base layer moves below the deployment layer, so a deployment can
  tune the rows the image inserts; authless and the login gate stay pinned at the top, so
  the layer below cannot undo them. The web search provider row stays out of the base
  layer: it is deployment config. `docs/architecture.md`, `docs/configuration.md`,
  `docs/security.md` and the base layer's header state the order.
- The authless / login-gate pairing is a build-time **warning** instead of a refusal: `INSTALL_AUTHLESS=1` with `INSTALL_AUTH_GATE=0` now builds an image with no gate of its own, which is a legitimate choice when an authenticated proxy fronts it. The default pair is unchanged, and `docs/security.md` states the operator's responsibility.
- The tool image defaults to a `core` pack: documents, PDF, images, browsers and
  data frames. The scientific/ML/vision/notebook/crawling Python stack and the
  bundler/linter/test Node CLIs moved behind `--build-arg WITH_PACK=full`
  (+~2.8GB), which takes the default tool image from 7.5GB to 5.9GB. The
  scientific Python stack hides some of the saving, because `onnxruntime` comes
  back as a dependency of `markitdown`'s `magika`.
- The tool image names its base image in full
  (`docker.io/library/node:22.19-bookworm-slim`) so podman's short-name
  resolution cannot reject it, and re-declares `BASE_IMAGE` inside the stage
  where the provenance stamp reads it.
<!-- forge:changelog-changed -->
- `DSH_VERSION` moves to `0.2.1-rc.2` and `DS_BOT_VERSION` to `0.1.7`.
- `dsh-shutup` is replaced by `dsh-authless` (MIT, commit `26fe680`): it removes the
  launch-token gate by replacing the connection service's browser-auth owner, and leaves
  the Host/Origin fence in place, so a foreign authority still gets 403 and
  `--host 0.0.0.0` stays refused. `INSTALL_SHUTUP` / `SHUTUP_REPO` / `SHUTUP_COMMIT` /
  `SHUTUP_SHA256` become `INSTALL_AUTHLESS` / `AUTHLESS_REPO` / `AUTHLESS_COMMIT` /
  `AUTHLESS_SHA256`, and `/etc/dsbot-versions` reports `authless=` and
  `authless_commit=`.
- npm is upgraded to `NPM_VERSION` (default 12) before dsh is installed, and the
  dsh install passes `--allow-scripts` with the exact list the native modules
  need. The base image ships npm 10.9.8, which has no such option; the upstream
  reference gets it from node 24 without noticing.
- The entrypoint reports the ds-bot version dsh will actually load, resolving the
  installation anchor first the way `resolveBundleDir` does, and names a volume
  copy that can never win. It does not try to reinstall: on this model that would
  be a silent no-op. `STRICT_DS_BOT_VERSION=1` makes drift fatal.
- `compose.yaml` sets `stop_grace_period: 30s` and documents the podman-socket
  group instead of leaving the mount unexplained.
- The OCI `licenses` label is gone until the repository has a `LICENSE` file. It
  claimed Apache-2.0; the tree does not back that claim.

### Fixed

- The default combination did not build: `NPM_VERSION=12` needs node `^22.22.2`,
  while the pinned base was node 22.19.0, so the npm upgrade step stopped with
  `EBADENGINE` before dsh was installed. Both layers now start from
  `docker.io/library/node:22.22-bookworm-slim`.
- The image ran as 10001 but `/data/bot` belonged to root: `WORKDIR` created
  `/data/bot/workspace` after the `chown -R /data`, so ds-bot could not write its
  state or its workspace (`EACCES … '~/bot/state.json.tmp'`). The directory is now
  created before the chown.
- `/etc/dsbot-versions` reported the tool layer as `tools=tools_revision=dev`:
  the step read `/opt/tools-version` with `head -1`, which is the key line. It now
  parses `tools_revision` and `pack` and reports `<revision> pack=<pack>`.
- The gate checks in the entrypoint never ran: `auth_gate=` carried the gate's
  version while the entrypoint compares that field with `1` (token seeding, the
  startup preflight and the refusal to serve a gated port). The field now carries
  the install flag, and `auth_gate_version=` holds the version.
- The shipped examples sat inside the deployment layer, so a checkout that mounted
  `./overlay` had `10-providers.example.patch.yml` applied as a live patch — it
  points the agent default model at a gateway that does not exist. The examples
  moved to `examples/`; `overlay/` is again only what a deployment puts there.

## [0.1.6] - 2026-10-16

### Added

- Two-image build: an L1 toolchain image (`dsbot-tools`) and the L2 dsbot image
  (`dsh` + `ds-bot` + bundled plugins) on top of it. Both start from the same
  `docker.io/library/node:22.19-bookworm-slim` base, so the dsbot image can also be built against a
  bare base for a tool-less variant.
- Deployment layer mounted at `/etc/dsbot/overlay`: any number of cordis patch
  files, applied last and therefore authoritative, plus `plugins.txt` to declare
  dsh plugins that are installed into the volume profile at startup.
- `dsbot-plugins` reconcile tool (`sync`, `list`, `--dry-run`, `--force`):
  already-installed plugins are skipped without touching the network, local plugin
  directories are staged into the volume and linked, and a declared plugin that
  cannot be installed stops the container unless the operator downgrades it.
- Login gate (`dsh-auth-gate`) installed as an image-carried package, so nothing
  in the volume can remove it. Default token mode is zero-config: the first start
  generates a token in `/data/auth/token` and prints it once.
- Startup verification in the entrypoint: `--dump-config` must contain the login
  gate, an unauthenticated request must not receive the dsh app shell, and a
  non-loopback bind is refused when that check fails.
- Build-time verification: ds-bot's own dsh pin is asserted when declared, the
  login gate's dependencies and peer ranges are resolved and checked, the
  bundled plugins' commit is pinned by sha256, and the image base layer is
  composed once during the build.
- Non-root runtime (uid 10001) with a read-only root; every writable path is
  either the `/data` volume or a tmpfs.
- Reference compose file and a documented `secrets.env` mechanism for tokens and
  provider keys.
- Tool image smoke test (`tools/doctor.sh`).

[Unreleased]: ../../compare/v0.1.6...HEAD
[0.1.6]: ../../releases/tag/v0.1.6
