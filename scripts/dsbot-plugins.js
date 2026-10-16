#!/usr/bin/env node
// =============================================================================
// dsbot-plugins — reconcile the dsh plugins declared by the deployment layer.
//
//   dsbot-plugins sync [--dry-run] [--force]   install what /etc/dsbot/overlay/
//                                              plugins.txt declares and the volume
//                                              profile does not have yet
//   dsbot-plugins list                         show what the volume profile has
//
// The entrypoint runs `sync` on every start. Anything already installed is
// skipped without touching the network; only missing plugins are installed.
//
// plugins.txt holds one spec per line; `#` starts a comment:
//   some-plugin@1.2.3            npm package, pinned: installed version differs -> install
//   some-plugin                  npm package, unpinned: install once, never touch again
//   @scope/pkg                   scoped names work the same way
//   my-plugin                    a directory next to plugins.txt (overlay/plugins/my-plugin)
//   /mnt/elsewhere/other         explicit path (relative paths resolve against plugins.txt)
//
// Local directories are staged into the volume (/data/.overlay-plugins/<name>,
// skipping node_modules and .git) and then linked, because pnpm cannot write
// into a read-only mount.
//
// Exit code 1 when a declared plugin cannot be installed, unless
// OVERLAY_PLUGINS_STRICT=0 downgrades that to a warning.
// =============================================================================
'use strict'
const fs = require('node:fs')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const DSH_HOME = process.env.DSH_HOME || '/data'
const OVERLAY_DIR = process.env.OVERLAY_DIR || '/etc/dsbot/overlay'
const SPEC_FILE = process.env.OVERLAY_PLUGINS_FILE || path.join(OVERLAY_DIR, 'plugins.txt')
const LOCAL_SPEC_DIR = path.dirname(SPEC_FILE)
const PROFILE = path.join(DSH_HOME, 'profiles', 'web')
const LOCAL_STORE = path.join(DSH_HOME, '.overlay-plugins')
const STRICT = process.env.OVERLAY_PLUGINS_STRICT !== '0'

const argv = process.argv.slice(2)
const cmd = argv.find((a) => !a.startsWith('-')) || 'sync'
const dryRun = argv.includes('--dry-run')
const force = argv.includes('--force')

const log = (...a) => console.log('dsbot-plugins:', ...a)
const warn = (...a) => console.warn('dsbot-plugins: WARNING', ...a)

function readProfile() {
  const p = path.join(PROFILE, 'package.json')
  if (!fs.existsSync(p)) return null
  return JSON.parse(fs.readFileSync(p, 'utf8'))
}

function installedNames(profile) {
  const deps = Object.keys(profile.dependencies || {})
  const bundles = (profile.dsh && profile.dsh.profile && profile.dsh.profile.bundles) || []
  return { deps, bundles, out: new Set([...deps, ...bundles]) }
}

// A bare name that matches a directory under overlay/plugins/ is a local plugin;
// anything else is an npm spec: name, or name@version.
function parseSpec(line) {
  if (line.startsWith('/') || line.startsWith('./') || line.startsWith('../')) {
    return { kind: 'dir', dir: path.resolve(LOCAL_SPEC_DIR, line), name: path.basename(line.replace(/\/+$/, '')) }
  }
  if (/^((?:@[^/]+\/)?[^@]+)$/.test(line)) {
    const cand = path.join(OVERLAY_DIR, 'plugins', line)
    if (fs.existsSync(cand) && fs.statSync(cand).isDirectory()) return { kind: 'dir', dir: cand, name: line }
  }
  const m = /^((?:@[^/]+\/)?[^@]+)(?:@(.+))?$/.exec(line)
  if (!m) return null
  return { kind: 'npm', name: m[1], version: m[2] }
}

function readSpecs() {
  if (!fs.existsSync(SPEC_FILE)) return []
  return fs
    .readFileSync(SPEC_FILE, 'utf8')
    .split('\n')
    .map((l) => l.replace(/(^|\s)#.*$/, '').trim())
    .filter(Boolean)
    .map((l) => ({ raw: l, spec: parseSpec(l) }))
    .filter((x) => x.spec)
}

function runDsh(args) {
  const dsh = process.env.DSH_BIN || 'dsh'
  if (dryRun) {
    log('[dry-run] would run:', dsh, args.join(' '))
    return 0
  }
  const r = spawnSync(dsh, args, { stdio: 'inherit', env: process.env })
  return r.status === null ? 1 : r.status
}

const norm = (v) => String(v || '').replace(/^[\^~=]/, '')

function stageAndAdd(entry, problems) {
  const { name, dir } = entry.spec
  if (!fs.existsSync(dir)) {
    problems.push(`${entry.raw}: directory does not exist (mount it at ${dir})`)
    return
  }
  const dst = path.join(LOCAL_STORE, name)
  if (!dryRun) {
    fs.mkdirSync(LOCAL_STORE, { recursive: true })
    fs.rmSync(dst, { recursive: true, force: true })
    fs.cpSync(dir, dst, {
      recursive: true,
      dereference: true,
      filter: (src) => !/(^|\/)(node_modules|\.git)$/.test(src),
    })
  }
  log(`staged local plugin ${name}: ${dir} -> ${dst}`)
  const rc = runDsh(['plugin', '--profile', 'web', 'add', dst])
  if (rc !== 0) problems.push(`${entry.raw}: dsh plugin add failed (exit ${rc})`)
}

function main() {
  const profile = readProfile()

  if (cmd === 'list') {
    if (!profile) return log('no profile at', PROFILE), 0
    const { deps, bundles } = installedNames(profile)
    log('profile:', PROFILE)
    log('dependencies:', deps.length ? deps.join(', ') : '(none)')
    log('bundles     :', bundles.length ? bundles.join(', ') : '(none)')
    return 0
  }
  if (cmd !== 'sync') {
    console.error('usage: dsbot-plugins [sync|list] [--dry-run] [--force]')
    return 2
  }
  if (!profile) {
    warn('no profile at', PROFILE, '- nothing to reconcile yet (the seed should have run first)')
    return 0
  }

  const specs = readSpecs()
  if (!specs.length) return log('nothing declared in', SPEC_FILE), 0

  const { out } = installedNames(profile)
  const problems = []
  let changed = 0

  for (const entry of specs) {
    const { kind, name, version } = entry.spec
    const have = profile.dependencies ? profile.dependencies[name] : undefined
    const present = out.has(name)

    if (kind === 'dir') {
      if (present && !force) {
        log(`ok    ${name} (local, already linked)`)
        continue
      }
      stageAndAdd(entry, problems)
      changed++
      continue
    }

    if (present && !force) {
      if (!version || norm(have) === norm(version)) {
        log(`ok    ${name} (${have || 'linked'})`)
        continue
      }
      log(`bump  ${name}: ${have} -> ${version}`)
    } else if (present) {
      log(`force ${name}`)
    } else {
      log(`add   ${entry.raw}`)
    }

    const rc = runDsh(['plugin', '--profile', 'web', 'add', entry.raw])
    if (rc !== 0) problems.push(`${entry.raw}: dsh plugin add failed (exit ${rc})`)
    else changed++
  }

  if (problems.length) {
    for (const p of problems) console.error('dsbot-plugins: FAILED', p)
    if (STRICT) {
      console.error(`dsbot-plugins: ${problems.length} declared plugin(s) could not be installed; refusing to start. Set OVERLAY_PLUGINS_STRICT=0 to downgrade to a warning.`)
      return 1
    }
    warn(`${problems.length} declared plugin(s) could not be installed (continuing, OVERLAY_PLUGINS_STRICT=0)`)
  }
  log(`done (${changed} change(s), ${specs.length} declared)`)
  return 0
}

process.exit(main())
