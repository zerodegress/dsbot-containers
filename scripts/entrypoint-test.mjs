#!/usr/bin/env node
// =============================================================================
// Container entrypoint regression, adapted from the upstream reference
// (github.com/Fei2411/DeepSeek-Bot, docker/test.mjs) to this image's shape.
//
//   node scripts/entrypoint-test.mjs dsbot-containers:local
//   DSBOT_TEST_RUNTIME=docker DSBOT_TEST_IMAGE=dsbot-containers:local node …
//
// Every container is temporary, gets its own named volumes, and runs with
// --network none. The image-local checks run through `--entrypoint /bin/sh`, so
// they need no server; only the last group starts one, detached, and polls it.
// When the image or the runtime is missing the container groups are reported as
// SKIPPED — never as PASS.
// =============================================================================
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { setTimeout as sleep } from 'node:timers/promises'

const IMAGE = process.env.DSBOT_TEST_IMAGE ?? 'dsbot-containers:local'
const RUNTIME = process.env.DSBOT_TEST_RUNTIME ?? 'podman'
const UID = process.env.DSBOT_TEST_UID ?? '10001'
const GID = process.env.DSBOT_TEST_GID ?? '10001'
const PORT = process.env.DSBOT_TEST_PORT ?? '3080'

const name = `dsbot-entrypoint-${randomUUID().slice(0, 8)}`
const dataVolume = `${name}-data`
const workspaceVolume = `${name}-workspace`
const volumes = [dataVolume, workspaceVolume]
const containers = new Set()

function cli(args, { allowFailure = false, timeout = 120_000 } = {}) {
  const result = spawnSync(RUNTIME, args, { encoding: 'utf8', timeout, maxBuffer: 8 * 1024 * 1024 })
  if (!allowFailure && (result.error || result.status !== 0)) {
    throw new Error(
      `${RUNTIME} ${args.join(' ')} failed: ${result.error?.message ?? result.stderr ?? `exit ${result.status}`}`,
    )
  }
  return result
}

function mounts() {
  return [
    '-v', `${dataVolume}:/data`,
    '-v', `${workspaceVolume}:/data/bot/workspace`,
  ]
}

// One throwaway container per invocation, never a name a deployment could own.
function run(args, opts = {}) {
  const container = `${name}-c${containers.size}`
  containers.add(container)
  return cli(['run', '--rm', '--name', container, '--network', 'none', ...mounts(), ...args], opts)
}

function shell(script, opts) {
  return run(['--entrypoint', '/bin/sh', IMAGE, '-eu', '-c', script], opts)
}

function log(r) {
  return `${r.stdout ?? ''}${r.stderr ?? ''}`
}

// The entrypoint's own run, with the gate probe disabled: `--help` is forwarded
// to dsh, which prints usage and exits instead of serving.
function startHelp(env = {}) {
  const envArgs = Object.entries({ SKIP_GATE_CHECK: '1', ...env }).flatMap(([k, v]) => ['-e', `${k}=${v}`])
  return run([...envArgs, IMAGE, '--help'])
}

const skipped = []
const skip = (reason) => {
  skipped.push(reason)
  console.log(`SKIP: ${reason}`)
}

try {
  if (cli(['image', 'inspect', IMAGE], { allowFailure: true }).status !== 0) {
    skip(`image ${IMAGE} is not present locally; build it first (container checks were not run)`)
  } else {
    // --- 1. ship hygiene ----------------------------------------------------
    shell(`
      test "$(stat -c %a /usr/local/bin/entrypoint.sh)" = 755
      test "$(stat -c %a /usr/local/bin/dsbot-plugins)" = 755
      /bin/sh -n /usr/local/bin/entrypoint.sh
      node --check /usr/local/bin/dsbot-plugins
      test -s /etc/dsbot-versions
      test -s /etc/dsbot/recipe
      grep -q "^dsh " /etc/dsbot/recipe
    `)
    console.log('PASS: entrypoint and helper scripts are executable and parse')

    // --- 2. first start seeds /data and owns it ------------------------------
    startHelp()
    shell(`
      test "$(stat -c %u:%g /data)" = ${UID}:${GID}
      test "$(stat -c %u:%g /data/profiles/web/package.json)" = ${UID}:${GID}
      test "$(stat -c %u:%g /data/bot/workspace)" = ${UID}:${GID}
      test -z "$(find -P /data -xdev \\( ! -uid ${UID} -o ! -gid ${GID} \\) -print -quit)"
    `)
    console.log(`PASS: first start seeds /data and hands it to ${UID}:${GID}`)

    // --- 3. the ownership repair spares a populated volume -------------------
    shell(`
      printf preserved > /data/review-state.txt
      chmod 600 /data/review-state.txt
      chown ${UID}:${GID} /data/review-state.txt
      mkdir -p /data/restored
      printf restored > /data/restored/private.txt
      chmod 700 /data/restored
      chmod 600 /data/restored/private.txt
      chown -R 3456:3457 /data/restored
      ln -s /data/bot/workspace /data/workspace-link
      printf untouched > /data/bot/workspace/keep.txt
    `)
    startHelp()
    shell(`
      test "$(cat /data/review-state.txt)" = preserved
      test "$(cat /data/restored/private.txt)" = restored
      test "$(cat /data/bot/workspace/keep.txt)" = untouched
      test "$(readlink /data/workspace-link)" = /data/bot/workspace
      test -z "$(find -P /data -xdev \\( ! -uid ${UID} -o ! -gid ${GID} \\) -print -quit)"
    `)
    console.log('PASS: an existing volume keeps its contents and ends up owned by the runtime uid')

    // --- 4. the carried ds-bot wins, and a shadowed copy is reported ---------
    // Plant a stale copy exactly where an older volume layout put one. dsh
    // resolves the carried copy first, so the entrypoint must name the shadow
    // and the resolved version must still be the image's own — no reinstalling.
    const planted = '0.0.1-shadowed'
    shell(`
      p=/data/profiles/web/node_modules/ds-bot
      mkdir -p "$p"
      printf '{"name":"ds-bot","version":"${planted}","type":"module"}\n' > "$p/package.json"
      chown -R ${UID}:${GID} "$p"
    `)
    const drift = log(startHelp({ STRICT_DS_BOT_VERSION: '0' }))
    assert.match(drift, /dead weight and ignored/, 'a shadowed profile copy must be reported')
    assert.doesNotMatch(drift, /ds-bot drift/, 'a shadowed copy is not the loaded copy, so it is not drift')
    shell(`
      root="$(dirname "$(dirname "$(readlink -f "$(command -v dsh)")")")"
      got="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' \
        "$root/node_modules/ds-bot/package.json" | head -1)"
      image="$(sed -n 's/^dsbot=//p' /etc/dsbot-versions | head -1)"
      test -n "$got"
      test "$got" = "$image"
      grep -q "^ds-bot $image$" /etc/dsbot/recipe
    `)
    console.log('PASS: a shadowed profile copy is reported; the carried ds-bot is the resolved one')

    // The carried copy missing entirely is what STRICT_DS_BOT_VERSION=1 is for.
    shell(`mv /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/ds-bot /data/held-ds-bot`)
    const strict = log(startHelp({ STRICT_DS_BOT_VERSION: '1' }))
    assert.match(strict, /ds-bot drift|not resolvable/, 'a missing carried ds-bot must be loud')
    assert.match(strict, /FATAL/, 'STRICT_DS_BOT_VERSION=1 must fail the start')
    console.log('PASS: an unresolvable ds-bot is fatal under STRICT_DS_BOT_VERSION=1')

    // --- 5. the server runs as the fixed uid --------------------------------
    const server = `${name}-web`
    containers.add(server)
    cli([
      'run', '--detach', '--rm', '--name', server, '--network', 'none', ...mounts(),
      '-e', `DSH_PORT=${PORT}`,
      '-e', 'DSH_BIND_HOST=127.0.0.1',
      '-e', 'SKIP_GATE_CHECK=1',
      IMAGE,
    ])
    const probe = `
      const r = await fetch('http://127.0.0.1:${PORT}/');
      if (![200, 401, 302].includes(r.status)) throw new Error('unexpected ' + r.status);
    `
    const deadline = Date.now() + 60_000
    let ready = false
    while (Date.now() < deadline) {
      if (cli(['exec', server, 'node', '--input-type=module', '-e', probe], { allowFailure: true }).status === 0) {
        ready = true
        break
      }
      await sleep(500)
    }
    assert.ok(ready, 'the web server must answer HTTP on loopback')
    const owner = cli(['exec', server, 'stat', '-c', '%u:%g', '/proc/1']).stdout.trim()
    assert.equal(owner, `${UID}:${GID}`, 'PID 1 must run as the fixed runtime uid')
    console.log(`PASS: the web server answers and runs as ${owner}`)
    cli(['rm', '--force', server], { allowFailure: true })
  }
} finally {
  for (const container of containers) cli(['rm', '--force', container], { allowFailure: true })
  for (const volume of volumes) cli(['volume', 'rm', volume], { allowFailure: true })
}

if (skipped.length) {
  console.log(`\n${skipped.length} check group(s) skipped:`)
  for (const reason of skipped) console.log(`  - ${reason}`)
  process.exit(2)
}
