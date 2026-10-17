# Recipes, and where they came from

This file records what was taken from the upstream reference deployment
(`github.com/Fei2411/DeepSeek-Bot`, `docker/`) and how it had to be changed for
this image. It is written for the next person who compares the two again.

| upstream file | here | what changed |
|---|---|---|
| `docker/Dockerfile` | `Dockerfile` | version pins, OCI `LABEL`s, an npm new enough for `--allow-scripts` |
| `docker/entrypoint.sh` | `entrypoint.sh` | the ds-bot reinstall became a resolved-version check |
| `docker/test.mjs` | `scripts/entrypoint-test.mjs` | `PUID`/`PGID`/`gosu` became the fixed uid, plus `--read-only` |
| `docker/docker.patch.yml` | `overlay/*.patch.yml` | this image already has a deployment layer; the permission and workspace rows belong there, not in a second overlay |

## The two ds-bot installation models

The upstream image installs ds-bot **into the profile**:

```sh
# upstream docker/Dockerfile:24-27
npm pack --pack-destination /tmp && mv /tmp/ds-bot-*.tgz /tmp/ds-bot.tgz
DSH_HOME=/opt/dsh-template dsh plugin --profile web add /tmp/ds-bot.tgz
```

so at start it compares the profile's copy against the image's copy and
reinstalls when they differ:

```sh
# upstream docker/entrypoint.sh:30-36
installed_ver=$(jq -r .version /data/profiles/web/node_modules/ds-bot/package.json …)
image_ver=$(jq -r .version /opt/dsh-template/profiles/web/node_modules/ds-bot/package.json)
if [ "$installed_ver" != "$image_ver" ]; then
  HOME=/home/node gosu node dsh plugin --profile web add /opt/ds-bot/ds-bot.tgz …
fi
```

This image installs ds-bot as a **carried package of the dsh installation**
(`Dockerfile` step 4: unpack into
`/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/ds-bot` and register it
in that package.json), and the base layer patch inserts the row. The difference
matters because of how dsh resolves a bundle:

```js
// @deepseek-ai/dsh-app-boot, resolveBundleDir()
for (const anchor of [installAnchor, join(profileDir, "package.json")]) {
  const dir = packageDirFromAnchor(anchor, packageName)   // Node node_modules lookup
  if (dir !== undefined) return dir
}
```

`installAnchor` is the dsh installation's own package.json, and the comment above
it states the installation-first order is the contract. So:

1. **The carried copy is always the one that runs.** A copy under
   `profiles/web/node_modules/ds-bot` — from an older volume, or from a
   `dsh plugin add` — is shadowed and never imported.
2. **On this image the upstream reinstall would be a silent no-op.** It writes to
   the profile, which loses. Copying that block would look like a fix and change
   nothing.
3. **A real version drift cannot be repaired at runtime at all**: the runtime is
   non-root on a read-only root, so the carried package is not writable. The only
   lever is `DS_BOT_VERSION` at build time.

That is why `entrypoint.sh` does not reinstall. It resolves ds-bot the way dsh
does — walking up from the dsh binary, checking `<dir>/node_modules/<pkg>` and
`<dir>/<pkg>` at each level, installation anchor before profile — and then:

- logs the directory and version dsh will load;
- names a profile copy that exists but can never win, so nobody spends an
  afternoon on it;
- reports drift between what the image carries and what would be loaded;
  `STRICT_DS_BOT_VERSION=1` turns that into a refusal to start.

`scripts/entrypoint-test.mjs` plants a stale profile copy and asserts the first
two lines of that behaviour, and removes the carried copy to assert the third.

## Running the entrypoint test

```sh
npm run test:entrypoint                                     # default image, podman
DSBOT_TEST_IMAGE=dsbot-containers:local node scripts/entrypoint-test.mjs
DSBOT_TEST_RUNTIME=docker node scripts/entrypoint-test.mjs
```

It only ever creates containers named `dsbot-entrypoint-<random>`, bulk volumes
of its own, and starts them with `--network none`. It never addresses an existing
container, volume or network by name, and it removes all of them in a `finally`.
When the image or the runtime is absent it reports `SKIP` and exits 2.

## The podman socket

This image runs as the fixed uid `10001` on a read-only root. If a deployment
mounts a container runtime's socket — `/run/podman/podman.sock` — the container
does not need `--privileged`, a capability, or a wider uid: the socket is a unix
socket with a `0660` mode, so group membership is the whole requirement.

```sh
# on the host
stat -c '%u:%g %a' /run/user/$(id -u)/podman/podman.sock
```

Then put that gid in `compose.yaml`:

```yaml
    user: "10001:10001"
    group_add:
      - "1000"
    userns_mode: keep-id
```

Two ways this goes wrong:

- the socket is mounted **read-only** (`:ro`): connecting needs write permission
  on the socket file, so `:ro` breaks it even with the right group;
- the gid is added but the runtime drops supplementary groups: `keep-id` (podman)
  is what keeps them. Verify from inside with
  `id` and `test -w /run/podman/podman.sock`.

If the socket cannot be shared that way, the honest fallback is to leave the
mount out; nothing else in the image depends on it.
