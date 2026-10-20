// Build-time assertions for the dsh-authless carried package.
//
//   D=<dsh install dir> DSH_VERSION=<pinned dsh version> node check-dsh-authless.js
//
// Four fatal checks:
//   1. the package resolves from inside dsh's own tree, and that resolution is
//      the copy the build just placed there (not a second install);
//   2. it declares no runtime dependency the dsh tree would have to supply —
//      anything it imported would be resolved from dsh's tree, so an undeclared
//      dependency lands on whatever happens to be there;
//   3. its `engines.dsh` range covers the pinned dsh version. dsh skips such a
//      bundle silently, and a skipped authless leaves the token gate in place —
//      the visible symptom is a `?token=` URL, not an error;
//   4. its bundle patch inserts exactly one row and names this package — the
//      entrypoint greps the composed tree for that row id, so a rename here
//      would turn a working gate into a startup warning.
'use strict'
const path = require('node:path')
const fs = require('node:fs')

const dshDir = process.env.D
const host = process.env.DSH_VERSION
if (!dshDir || !host) {
  console.error('D and DSH_VERSION are required')
  process.exit(1)
}
const pkgDir = path.join(dshDir, 'node_modules', 'dsh-authless')

let bad = 0

// 1. resolution
try {
  const got = fs.realpathSync(require.resolve('dsh-authless', { paths: [pkgDir] }))
  const want = fs.realpathSync(path.join(pkgDir, 'src/index.js'))
  if (got !== want) {
    bad++
    console.error('DUP  dsh-authless resolves to', got, 'but the build placed', want)
  } else {
    console.log('ok    dsh-authless ->', got)
  }
} catch (e) {
  bad++
  console.error('MISS dsh-authless', e.code || e.message)
}

// 2. declared dependencies
let pkg = {}
try {
  pkg = require(path.join(pkgDir, 'package.json'))
} catch (e) {
  bad++
  console.error('cannot read dsh-authless/package.json:', e.message)
}
const deps = Object.keys(pkg.dependencies || {})
if (deps.length) {
  bad++
  console.error('DEPS dsh-authless declares runtime dependencies the image does not unpack:', deps.join(', '))
} else {
  console.log('ok    no runtime dependencies to unpack')
}

// Minimal semver compare, enough for the range shapes dsh plugins declare.
// A range is one or more space-separated comparators; `||` joins alternatives.
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
function test(ver, comparator) {
  const m = /^(>=|<=|>|<|\^|~|=)?\s*(.+)$/.exec(comparator.trim())
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
}
function satisfies(range, v) {
  const ver = parse(v)
  return range.split('||').some((alt) => {
    const parts = alt.trim().split(/\s+/).filter(Boolean)
    if (!parts.length) return false
    return parts.every((p) => test(ver, p))
  })
}

// 3. engines.dsh
const range = pkg.engines && pkg.engines.dsh
if (!range) {
  bad++
  console.error('ENGINES dsh-authless declares no engines.dsh; the loader consults nothing')
} else if (satisfies(range, host)) {
  console.log('ok    engines.dsh', range, 'covers host', host)
} else {
  bad++
  console.error('ENGINES dsh-authless declares engines.dsh', range, 'which does not cover host', host)
}

// 4. bundle patch
try {
  const patch = fs.readFileSync(path.join(pkgDir, 'cordis.patch.yml'), 'utf8')
  const rows = patch.split('\n').filter((l) => /^\s*-\s+id:/.test(l))
  const named = /name:\s*dsh-authless\b/.test(patch)
  if (rows.length !== 1 || !named) {
    bad++
    console.error('PATCH cordis.patch.yml must insert exactly one row named dsh-authless; got', rows.length, 'id line(s), named =', named)
  } else {
    console.log('ok    bundle patch inserts one row:', rows[0].trim())
  }
} catch (e) {
  bad++
  console.error('PATCH cannot read cordis.patch.yml:', e.message)
}

if (bad) {
  console.error(`dsh-authless is not loadable as built (${bad} problem(s)) — refusing to bake it in`)
  process.exit(1)
}
console.log('dsh-authless dependency, engine range and bundle-patch checks passed')
