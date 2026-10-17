# Security

## The pair

The image bundles two plugins that are useless — and dangerous — apart:

| plugin | behaviour | side effect |
|---|---|---|
| `dsh-shutup` | quiet web start, inverted `--no-open`, `--host 0.0.0.0` allowed | **removes dsh's own `?token=` gate** and the refusal to bind a wildcard address |
| `dsh-auth-gate` | login required for every page, API call and WebSocket (password or shared token, optional TOTP); a missing or broken configuration blocks access instead of allowing it | – |

Shutup alone means: reachable binding, no authentication. That is why the two are
installed as a pair and the build refuses to produce an image with only one of them
(`INSTALL_SHUTUP` and `INSTALL_AUTH_GATE` must match).

If you install `dsh-shutup` on its own, outside this image, you own the consequences:
put it behind your own gate (an authenticating reverse proxy, an access-controlled
tunnel), or keep it inside a trusted network or a tailnet.

## Startup verification

dsh 0.2.0-rc.2 and later **skip a bundle silently** when its `@deepseek-ai/dsh*` peer
range does not cover the running host version. A skipped login gate would leave an open
door, so the entrypoint checks, in order:

1. **Before starting** — `dsh --dump-config` must contain the login gate (and the
   entrypoint logs any `skipped` lines the loader reported).
2. **After starting** — an unauthenticated `GET /` must not contain the dsh app shell
   marker (`window.__DSH_BOOT__`); a login page, a redirect or a 401 is fine.
3. **Binding** — if the app shell *is* served without credentials and `DSH_BIND_HOST` is
   not a loopback address, dsh is stopped and the container exits. On loopback it is a
   warning, because the only way in is a sidecar sharing the network namespace.

The build checks the same thing statically: the login gate's dependencies are resolved
and its peer ranges are compared against the pinned dsh version
(`scripts/check-dsh-auth-gate.js`), and a second copy of any framework package fails the
build.

`SKIP_GATE_CHECK=1` turns both runtime checks off. Do not ship a deployment with it.

Building with `INSTALL_SHUTUP=1` and `INSTALL_AUTH_GATE=0` is **allowed**: it
produces an image with no gate of its own (shutup removes dsh's token gate and no
login gate replaces it). The build warns and goes on — the operator owns that
risk: front it with an authenticated proxy (Cloudflare Access, a reverse proxy
with auth) or keep it on a private network.


## Token mode

The login gate defaults to a shared token. With no `DSH_AUTH_TOKEN` in the secrets file,
the first start generates 32 random bytes into `/data/auth/token` (0600) and prints it
once in the container log. Anyone who reads the log or the volume has the token, so treat
the volume as a secret. For per-user accounts, TOTP, session revocation and a login page,
override the plugin's config in the overlay (`mode: "password"`, plus
`pnpm --dir /data/profiles/web exec dsh-auth user add <name> --password-stdin`); see the
upstream plugin documentation.

`cookieSecure` must match how you serve the site: `true` behind TLS termination, `false`
for plain HTTP (browsers refuse secure cookies over HTTP).

## Exposure model

The default binding is loopback and nothing is published on the host. Two supported
shapes:

- a sidecar that shares the container's network namespace (for example a Cloudflare
  tunnel) reaching `http://127.0.0.1:3080`, with the ingress or the tunnel's access
  rules in front;
- your own reverse proxy, which must forward the real `Host` header and be named in
  `DSH_TRUSTED_HOST`.

Setting `DSH_BIND_HOST=0.0.0.0` or publishing the port makes the login gate the only
door. That is a supported configuration — the startup probe exists precisely to make it
a safe one — but it is a decision, not a default.

## Caveats

- **Licensing.** `dsh-shutup`'s upstream repository carries no license and is no longer
  maintained, so this image builds it from a pinned commit of our own fork. Publishing
  prebuilt images redistributes it: give the fork an explicit license (and keep the
  provenance note) before doing that, or build with
  `--build-arg INSTALL_SHUTUP=0 INSTALL_AUTH_GATE=0`, which keeps dsh's own token gate
  and drops the `0.0.0.0` allowance.
- **No host socket by default.** The tool image contains a docker CLI, but nothing mounts
  the host's container socket. Doing so hands host root to whatever runs inside the
  container; if a deployment really wants it, that is a deliberate, documented change.
- **The volume holds credentials**, including the login token and whatever the Bots
  stored. Encrypt backups.
- **Read-only root** is not a sandbox for the agent: a Bot runs arbitrary commands
  inside the container with write access to `/data` by design. It keeps the image and the
  deployment layer immutable, nothing more.
