# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Image tags carry the DS Bot version the image was built against, so `0.1.6` is
`ds-bot@0.1.6`.

## [Unreleased]

### Added

<!-- forge:changelog-added -->
- OCI image labels, so a registry listing describes the image on its own.
- `scripts/entrypoint-test.mjs`: the entrypoint regression runs on temporary
  volumes with `--network none`, including the ds-bot shadowing and drift cases.
- The image prints `/etc/dsbot-recipe` next to `/etc/dsbot-versions`: one line per
  artifact, and where it came from.

### Changed

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
- `DS_BOT_VERSION` moves to `0.1.7`.
- npm is upgraded to `NPM_VERSION` (default 12) before dsh is installed, and the
  dsh install passes `--allow-scripts` with the exact list the native modules
  need. The base image ships npm 10.9.3, which has no such option; the upstream
  reference gets it from node 24 without noticing.
- The entrypoint reports the ds-bot version dsh will actually load, resolving the
  installation anchor first the way `resolveBundleDir` does, and names a volume
  copy that can never win. It does not try to reinstall: on this model that would
  be a silent no-op. `STRICT_DS_BOT_VERSION=1` makes drift fatal.
- `compose.yaml` sets `stop_grace_period: 30s` and documents the podman-socket
  group instead of leaving the mount unexplained.

### Fixed

- `/etc/dsbot-versions` reported the tool layer as `tools=tools_revision=dev`:
  the step read `/opt/tools-version` with `head -1`, which is the key line. It now
  parses `tools_revision` and `pack` and reports `<revision> pack=<pack>`.

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
