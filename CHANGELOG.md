# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Image tags carry the DS Bot version the image was built against, so `0.1.6` is
`ds-bot@0.1.6`.

## [Unreleased]

### Changed

- The tool image defaults to a `core` pack: documents, PDF, images, browsers and
  data frames. The scientific/ML/vision/notebook/crawling Python stack and the
  bundler/linter/test Node CLIs moved behind `--build-arg WITH_PACK=full`
  (+~2.8GB), which takes the default tool image from 7.5GB to roughly 4.7GB.
- The tool image names its base image in full
  (`docker.io/library/node:22.19-bookworm-slim`) so podman's short-name
  resolution cannot reject it, and re-declares `BASE_IMAGE` inside the stage
  where the provenance stamp reads it.

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

[Unreleased]: https://github.com/zerodegress/dsbot-containers/compare/v0.1.6...HEAD
[0.1.6]: https://github.com/zerodegress/dsbot-containers/releases/tag/v0.1.6
