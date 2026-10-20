// Build-time assertions for the dsh-auth-gate carried package.
//
//   D=<dsh install dir> DSH_VERSION=<pinned dsh version> node check-dsh-auth-gate.js
//
// Three fatal checks:
//   1. every module the gate imports resolves from inside dsh's own tree;
//   2. none of those resolutions lands on a second copy of a framework package
//      (a second @deepseek-ai/cordis would mean a second service registry);
//   3. the host-version peer ranges the dsh loader consults ("@deepseek-ai/dsh*")
//      cover the pinned dsh version. A bundle whose peers do not cover the host
//      is skipped silently, and a skipped login gate means an open door once
//      authless has removed dsh's own token gate.
'use strict'
const path = require('node:path')
const fs = require('node:fs')

const dshDir = process.env.D
const host = process.env.DSH_VERSION
if (!dshDir || !host) {
  console.error('D and DSH_VERSION are required')
  process.exit(1)
}
const gateDir = path.join(dshDir, 'node_modules', 'dsh-auth-gate')

const need = [
  'dsh-auth-gate',
  'yaml',
  'zod',
  '@deepseek-ai/schemastery',
  '@deepseek-ai/cordis',
  '@deepseek-ai/dsh-storage-domain',
]
let bad = 0
for (const m of need) {
  try {
    console.log('ok   ', m, '->', require.resolve(m, { paths: [gateDir] }))
  } catch (e) {
    bad++
    console.error('MISS ', m, e.code || e.message)
  }
}

for (const m of ['@deepseek-ai/cordis', '@deepseek-ai/schemastery', '@deepseek-ai/dsh-storage-domain']) {
  try {
    const got = fs.realpathSync(require.resolve(m, { paths: [gateDir] }))
    const want = fs.realpathSync(require.resolve(path.join(dshDir, 'node_modules', m)))
    if (got !== want) {
      bad++
      console.error('DUP  ', m, 'resolves to', got, 'but the host copy is', want)
    }
  } catch {
    /* reported above */
  }
}

// Minimal semver compare, enough for the range shapes dsh plugins declare.
function parse(v) {
  const core = v.replace(/^[^0-9]*/, '').split('+')[0]
  const [nums, ...rest] = core.split('-')
  const [a, b, c] = nums.split('.').map((n) => Number(n) || 0)
  return { a, b, c, pre: rest.join('-') ? rest.join('-').split('.') : [] }
}
function cmp(x, y) {
  for (const k of ['a', 'b', 'c']) if (x[k] !== y[k]) return x[k] < y[k] ? -1 : 1
  if (!x.pre.length && !y.pre.length) return 0
  if (!x.pre.length) return 1
  if (!y.pre.length) return -1
  for (let i = 0; i < Math.max(x.pre.length, y.pre.length); i++) {
    const l = x.pre[i]
    const r = y.pre[i]
    if (l === undefined) return -1
    if (r === undefined) return 1
    const ln = /^\d+$/.test(l)
    const rn = /^\d+$/.test(r)
    if (ln && rn && Number(l) !== Number(r)) return Number(l) < Number(r) ? -1 : 1
    if (ln !== rn) return ln ? -1 : 1
    if (l !== r) return l < r ? -1 : 1
  }
  return 0
}
function satisfies(range, v) {
  const ver = parse(v)
  return range.split('||').some((alt) => {
    const m = /^(>=|<=|>|<|\^|~|=)?\s*(.+)$/.exec(alt.trim())
    if (!m) return false
    const [, op = '=', raw] = m
    const base = parse(raw.trim())
    const c = cmp(ver, base)
    switch (op) {
      case '>=': return c >= 0
      case '<=': return c <= 0
      case '>': return c > 0
      case '<': return c < 0
      case '=': return c === 0
      case '~': return c >= 0 && ver.a === base.a && ver.b === base.b
      case '^': {
        if (c < 0) return false
        if (base.a !== 0) return ver.a === base.a
        if (base.b !== 0) return ver.a === 0 && ver.b === base.b
        return ver.a === 0 && ver.b === 0 && ver.c === base.c
      }
      default: return false
    }
  })
}

let gate
try {
  gate = require(path.join(gateDir, 'package.json'))
} catch (e) {
  console.error('cannot read dsh-auth-gate/package.json:', e.message)
  process.exit(1)
}
const peers = Object.keys(gate.peerDependencies || {}).filter((k) => k.startsWith('@deepseek-ai/dsh'))
if (!peers.length) {
  console.log('note: dsh-auth-gate declares no @deepseek-ai/dsh* peer; the loader has nothing to consult')
} else {
  for (const k of peers) {
    const r = gate.peerDependencies[k]
    const ok = satisfies(r, host)
    console.log(ok ? 'peer ok  ' : 'peer BAD ', k, r, 'vs host', host)
    if (!ok) bad++
  }
}

if (bad) {
  console.error(`dsh-auth-gate is not loadable as built (${bad} problem(s)) — refusing to bake it in`)
  process.exit(1)
}
console.log('dsh-auth-gate dependency and peer checks passed')
