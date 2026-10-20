---
name: dsbot-self-config
description: How this ds-bot instance's configuration is layered, which layers exist, what is pinned by the image or the deployment, and how to verify a change.
whenToUse: When the user asks to change a provider, a model, a plugin's settings, or any other behavior that comes from configuration rather than code.
---

# Configuring this instance

This instance composes its configuration from a stack of cordis patch files. **Later
wins**, so the list below is ordered lowest to highest:

1. bundle layer — the bundles in `profiles/web/package.json` plus each plugin's own
   `cordis.patch.yml`
2. the volume profile — `profiles/web/cordis.patch.yml`, the file the DSH settings UI
   writes to
3. the image base layer — `/opt/dsh-layers/base-layer.patch.yml`
4. the deployment layer — `/etc/dsbot/overlay.yml` and `/etc/dsbot/overlay/*.patch.yml`
   (mounted read-only; providers, models and other deployment decisions live here)
5. the bundled plugins' patches — shutup and the login gate; nothing below can change
   what they set

**There is no layer of your own.** Configuration has exactly three entry points: the
settings UI (layer 2), the image base (layer 3) and the deployment (layer 4). Writing a
patch file yourself does not work — the file sandbox only grants the session workspace,
never `$DSH_HOME`, and no directory under `$DSH_HOME` is read as a patch layer. Earlier
versions of this image created `$DSH_HOME/patches/` and loaded it; that layer was removed
because nothing running in the container could ever write it.

So when a change is needed, say which of the three entry points it belongs to, and hand
it to the person who controls that layer:

- a setting the user can tune → the settings UI;
- a row that must exist for the instance to run, or a default nobody is expected to
  change → the image base (an image change);
- a deployment decision (providers, models, endpoints) → the deployment layer, i.e. a
  file under the deployment's `overlay/` directory, then restart.

## Patch format

A patch is a YAML list, the same format the settings UI writes:

```yaml
# Change one row: it must already exist at this point in the stack, or the patch is
# dropped with `patch: entry "…" not found`.
- id: agent-default-model
  config:
    provider: my-gateway
    model: some-model
```

- `id` is required for a normal patch, and the row must already exist — that is why the
  image base layer is applied early: it inserts the rows ds-bot needs (`bot`,
  `web-search-auto`), so the layers above can configure them.
- `name` in a normal patch is a **guard**, not an assignment: if it does not match the
  target row's name, the whole entry is skipped.
- Everything else is assigned onto the row key by key, so `config:` **replaces that
  row's whole config object** — restate every key you still rely on.
- `insert:` adds entries instead: `- insert: [ {id, name, config} ]` at the top level
  appends them to the tree; with an extra `id:` on the insert entry it appends into that
  group's `config` list instead. Inserted rows are indexed immediately, so a later entry
  in the same file can patch them.
- Files are applied in name order, so use numeric prefixes (`10-`, `20-`) when the order
  between files matters.

Patches are read at startup: after a change, restart the container (on the host,
`podman-compose up -d --force-recreate`) before expecting it to take effect. There is no
hot reload in this instance.

## What you cannot change from here

- Anything the deployment decided: `/etc/dsbot/overlay/*` is mounted read-only, and a
  patch cannot remove a row the deployment set either.
- shutup and the login gate: their patches are applied last (layer 5). You can neither
  reconfigure nor remove the plugins themselves.
- The root filesystem: it is read-only. Writable paths are the session workspace and the
  tmpfs mounts (`/tmp`, `/run`). There is no container runtime inside: no docker or
  podman socket.

## Verifying

`dsh --profile web --dump-config` prints the composed tree, and each entry carries a
comment naming the file it came from:

```sh
dsh --profile web --dump-config | grep -n -B3 -A6 'id: agent-default-model'
```

That command cannot run inside the agent sandbox (it rewrites
`profiles/web/cordis.yml`, which is outside the writable grant), so run it on the host or
against a copy of the profile.

If a row still shows a higher layer's value, or the log says `patch: entry "…" not
found`, that layer won. Change the layer that owns the row, or ask the operator to change
the image or the deployment.
