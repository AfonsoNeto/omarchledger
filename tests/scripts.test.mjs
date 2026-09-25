/*
  Tests for the embedded bash scripts (resolve/add/undo + the similar
  lookup), extracted verbatim from HledgerService.qml.

  Two layers:
  - Plumbing tests use a stub hledger binary, so they run everywhere.
  - Behavior tests need a real hledger on PATH and are skipped otherwise.

  Every test works on throwaway journals inside a mkdtemp sandbox — the
  user's real journal is never touched.
*/
import { spawnSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, readFileSync, statSync, existsSync, rmSync, readdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'
import { extractScript, extractSimilarCommand } from './extract.mjs'
import { Suite, assert, eq, matches } from './harness.mjs'

const bin = (name) => spawnSync(name, ['--version'], { encoding: 'utf8' }).status === 0
const hasHledger = bin('hledger')

function runScript(scriptPath, args, input, env) {
  const r = spawnSync('bash', [scriptPath, ...args], {
    input: input || '',
    encoding: 'utf8',
    env: env || cleanEnv()
  })
  return { code: r.status, stdout: r.stdout || '', stderr: r.stderr || '' }
}

/* Isolate from the user's LEDGER_FILE so tests are deterministic. */
function cleanEnv(extra) {
  const e = { ...process.env }
  delete e.LEDGER_FILE
  return Object.assign(e, extra || {})
}

function sha256(s) {
  return crypto.createHash('sha256').update(s, 'utf8').digest('hex')
}

function writeFile(dir, name, content) {
  const p = path.join(dir, name)
  writeFileSync(p, content)
  return p
}

function leftovers(dir) {
  return readdirSync(dir).filter(f => f.includes('.omarchledger-'))
}

function parseAppended(stdout) {
  const m = stdout.match(/APPENDED:(\d+):(\d+):([0-9a-f]{64})/)
  assert(m, "expected APPENDED:<pre>:<post>:<sha> marker, got: " + JSON.stringify(stdout))
  return { pre: +m[1], post: +m[2], sha: m[3] }
}

const ENTRY = "\n2026-09-25 Script test\n    expenses:food    £7.00\n    assets:cash\n"
const ENTRY_LINES = 4

export async function run(s) {
  const root = mkdtempSync(path.join(tmpdir(), 'omarchledger-tests-'))
  const scripts = path.join(root, 'scripts')
  mkdirSync(scripts)
  for (const name of ['resolveScript', 'addScript', 'undoScript'])
    writeFileSync(path.join(scripts, name + '.sh'), extractScript(name))
  const resolve = path.join(scripts, 'resolveScript.sh')
  const add = path.join(scripts, 'addScript.sh')
  const undo = path.join(scripts, 'undoScript.sh')

  try {
    /* ---------- resolveScript: plumbing with a stub binary ---------- */
    const stubBin = path.join(root, 'stub-hledger')
    writeFileSync(stubBin, '#!/bin/sh\nif [ "$1" = files ]; then cat "$STUB_FILES" 2>/dev/null; fi\n')
    const filesList = path.join(root, 'files.txt')

    await s.test('resolve: override binary wins and its files output is used', async () => {
      writeFileSync(filesList, path.join(root, 'fake.journal') + "\n")
      const r = runScript(resolve, [stubBin, ""], "", { ...cleanEnv(), STUB_FILES: filesList })
      eq(r.code, 0)
      matches(r.stdout, /^BIN:/m)
      matches(r.stdout, /^JF:.*fake\.journal$/m)
    })

    await s.test('resolve: nonexistent override binary -> ERR:hledger-not-found', async () => {
      const r = runScript(resolve, [path.join(root, 'nope'), ""], "")
      eq(r.code, 0)
      matches(r.stdout, /ERR:hledger-not-found/)
    })

    await s.test('resolve: non-executable override binary -> ERR:hledger-not-found', async () => {
      const f = writeFile(root, 'notexec', '#!/bin/sh\n')
      const r = runScript(resolve, [f, ""], "")
      matches(r.stdout, /ERR:hledger-not-found/)
    })

    await s.test('resolve: no journal anywhere -> ERR:no-journal', async () => {
      writeFileSync(filesList, "\n")
      const r = runScript(resolve, [stubBin, ""], "", { ...cleanEnv(), STUB_FILES: filesList })
      matches(r.stdout, /ERR:no-journal/)
    })

    await s.test('resolve: FIFO journal -> ERR:journal-unreadable (no hang)', async () => {
      const dir = path.join(root, 'fifo')
      mkdirSync(dir)
      spawnSync('mkfifo', [path.join(dir, 'j.journal')])
      writeFileSync(filesList, path.join(dir, 'j.journal') + "\n")
      const r = runScript(resolve, [stubBin, ""], "", { ...cleanEnv(), STUB_FILES: filesList })
      matches(r.stdout, /ERR:journal-unreadable/)
    })

    await s.test('resolve: dangling symlink -> ERR:journal-unreadable', async () => {
      const dir = path.join(root, 'dangling')
      mkdirSync(dir)
      symlinkSync(path.join(dir, 'missing.journal'), path.join(dir, 'link.journal'))
      writeFileSync(filesList, path.join(dir, 'link.journal') + "\n")
      const r = runScript(resolve, [stubBin, ""], "", { ...cleanEnv(), STUB_FILES: filesList })
      matches(r.stdout, /ERR:journal-unreadable/)
    })

    await s.test('resolve: good symlink resolves', async () => {
      const dir = path.join(root, 'goodlink')
      mkdirSync(dir)
      const real = writeFile(dir, 'real.journal', "2026-01-01 t\n    a  1\n    b\n")
      symlinkSync(real, path.join(dir, 'link.journal'))
      writeFileSync(filesList, path.join(dir, 'link.journal') + "\n")
      const r = runScript(resolve, [stubBin, ""], "", { ...cleanEnv(), STUB_FILES: filesList })
      matches(r.stdout, new RegExp("^JF:" + real + "$", "m"))
    })

    await s.test('resolve: real hledger honors LEDGER_FILE', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const j = writeFile(root, 'env.journal', "2026-01-01 t\n    a  1\n    b\n")
      const r = runScript(resolve, ["", ""], "", { ...cleanEnv(), LEDGER_FILE: j })
      matches(r.stdout, /^BIN:/m)
      matches(r.stdout, new RegExp("^JF:" + j + "$", "m"))
    })

    await s.test('resolve: real hledger found via PATH', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const r = runScript(resolve, ["", ""])
      matches(r.stdout, /^BIN:/m)
      matches(r.stdout, /^JF:\S/m)
    })

    /* ---------- similar lookup: plumbing via stub ---------- */
    const similar = extractSimilarCommand()
    const similarSh = writeFile(scripts, 'similar.sh', similar + "\n")
    const stubEcho = path.join(root, 'stub-echo')
    writeFileSync(stubEcho, '#!/bin/sh\nprintf \'CALLED:%s|%s\\n\' "$2" "$4"\n')

    await s.test('similar: empty stdin query is a guarded no-op', async () => {
      const r = runScript(similarSh, [stubEcho, path.join(root, 'x.journal'), "1"], "")
      eq(r.code, 0)
      eq(r.stdout, "")
    })
    await s.test('similar: query travels via stdin to hledger print', async () => {
      const r = runScript(similarSh, [stubEcho, path.join(root, 'x.journal'), "1"], "desc:Supermarket\n")
      matches(r.stdout, /CALLED:print\|desc:Supermarket/)
    })

    /* ---------- addScript: needs a real hledger ---------- */
    await s.test('add: balanced entry appended byte-exactly with fingerprint', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'add-basic')
      mkdirSync(dir)
      const j = writeFile(dir, 'j.journal', "2026-01-01 Opening\n    assets:cash    100.00\n    incomes:salary\n")
      const before = readFileSync(j)
      const r = runScript(add, ['hledger', j, String(ENTRY_LINES)], ENTRY)
      eq(r.code, 0, r.stderr)
      const a = parseAppended(r.stdout)
      eq(a.pre, before.length)
      const after = readFileSync(j)
      eq(a.post, after.length)
      eq(after.subarray(before.length).toString('utf8'), ENTRY, "appended bytes identical to piped entry")
      eq(a.sha, sha256(ENTRY), "reported fingerprint is the entry sha256")
      eq(leftovers(dir).length, 0, "no temp leftovers")
    })

    await s.test('add: unbalanced entry rejected, nothing written, no leftovers', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'add-bad')
      mkdirSync(dir)
      const j = writeFile(dir, 'j.journal', "2026-01-01 Opening\n    assets:cash    100.00\n    incomes:salary\n")
      const before = readFileSync(j)
      const bad = "\n2026-09-25 Bad\n    expenses:food    1.00\n    assets:cash    2.00\n"
      const r = runScript(add, ['hledger', j, "4"], bad)
      eq(r.code, 1, "must fail")
      assert(r.stderr.includes("unbalanced"), "hledger error surfaced: " + r.stderr)
      eq(readFileSync(j).length, before.length, "journal untouched")
      eq(leftovers(dir).length, 0)
    })

    await s.test('add: malformed NLINES refused (0, negative, injection)', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'add-nlines')
      mkdirSync(dir)
      const j = writeFile(dir, 'j.journal', "2026-01-01 Opening\n    assets:cash    100.00\n    incomes:salary\n")
      const size = statSync(j).size
      for (const n of ["0", "-1", "4; rm -rf /", "", "four"]) {
        const r = runScript(add, ['hledger', j, n], ENTRY)
        eq(r.code, 5, "NLINES=" + JSON.stringify(n) + " must be refused")
        eq(statSync(j).size, size, "journal untouched for NLINES=" + JSON.stringify(n))
      }
      eq(leftovers(dir).length, 0)
    })

    await s.test('add: symlinked journal gets dereferenced sizes', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'add-symlink')
      mkdirSync(dir, { recursive: true })
      const real = writeFile(path.join(dir, '.real'), 'j.journal', "2026-01-01 Opening\n    assets:cash    100.00\n    incomes:salary\n")
      const link = path.join(dir, 'j.journal')
      symlinkSync(real, link)
      const r = runScript(add, ['hledger', link, String(ENTRY_LINES)], ENTRY)
      eq(r.code, 0, r.stderr)
      const a = parseAppended(r.stdout)
      eq(a.pre, statSync(real).size, "size is of the target, not the symlink")
      const undoR = runScript(undo, [link, String(a.pre), String(a.post), a.sha])
      eq(undoR.code, 0, undoR.stderr)
      eq(readFileSync(real).toString(), "2026-01-01 Opening\n    assets:cash    100.00\n    incomes:salary\n")
    })

    await s.test('add: relative includes resolve from the journal directory', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'add-include')
      mkdirSync(dir)
      writeFile(dir, 'sub.journal', "2026-01-02 Sub\n    expenses:food    12.50\n    assets:cash\n")
      const j = writeFile(dir, 'main.journal', "include sub.journal\n\n2026-01-01 Opening\n    assets:cash    100.00\n    incomes:salary\n")
      const r = runScript(add, ['hledger', j, String(ENTRY_LINES)], ENTRY)
      eq(r.code, 0, r.stderr)
      eq(leftovers(dir).length, 0)
    })

    await s.test('add: special characters survive the pipe byte-exactly', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'add-chars')
      mkdirSync(dir)
      const j = writeFile(dir, 'j.journal', "2026-01-01 Opening\n    assets:cash    100.00\n    incomes:salary\n")
      const entry = "\n2026-09-25 O'Brien & \"Sons\" 🧾 double  spaces ; tag:one two\n    expenses:food    £-1.23\n    assets:cash\n"
      const r = runScript(add, ['hledger', j, "4"], entry)
      eq(r.code, 0, r.stderr)
      const a = parseAppended(r.stdout)
      const after = readFileSync(j).subarray(a.pre).toString('utf8')
      eq(after, entry)
    })

    await s.test('add: 50-posting stress entry', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'add-stress')
      mkdirSync(dir)
      const j = writeFile(dir, 'j.journal', "2026-01-01 Opening\n    assets:cash    100.00\n    incomes:salary\n")
      let entry = "\n2026-09-25 Big split\n"
      const lines = [entry]
      for (let i = 0; i < 50; i++) lines.push("    expenses:cat" + i + "    1.00\n")
      lines.push("    assets:cash\n")
      entry = lines.join("")
      const r = runScript(add, ['hledger', j, "52"], entry)
      eq(r.code, 0, r.stderr)
      const a = parseAppended(r.stdout)
      eq(readFileSync(j).subarray(a.pre).toString('utf8'), entry)
    })

    await s.test('add: FIFO journal refused fast instead of hanging', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'add-fifo')
      mkdirSync(dir)
      spawnSync('mkfifo', [path.join(dir, 'j.journal')])
      const r = runScript(add, ['hledger', path.join(dir, 'j.journal'), String(ENTRY_LINES)], ENTRY)
      eq(r.code, 5, "clean refusal, not a hang")
      assert(r.stderr.includes("not a regular file"))
    })

    /* ---------- undoScript ---------- */
    async function addForUndo(dir) {
      const j = writeFile(dir, 'j.journal', "2026-01-01 Opening\n    assets:cash    100.00\n    incomes:salary\n")
      const before = readFileSync(j)
      const r = runScript(add, ['hledger', j, String(ENTRY_LINES)], ENTRY)
      eq(r.code, 0, r.stderr)
      const a = parseAppended(r.stdout)
      return { j, before, a }
    }

    await s.test('undo: correct fingerprint restores the journal byte-identically', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'undo-ok')
      mkdirSync(dir)
      const { j, before, a } = await addForUndo(dir)
      const r = runScript(undo, [j, String(a.pre), String(a.post), a.sha])
      eq(r.code, 0, r.stderr)
      eq(readFileSync(j).equals(before), true, "byte-identical restore")
      eq(leftovers(dir).length, 0)
    })

    await s.test('undo: wrong size refused', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'undo-size')
      mkdirSync(dir)
      const { j, a } = await addForUndo(dir)
      const r = runScript(undo, [j, String(a.pre), String(a.post + 5), a.sha])
      eq(r.code, 1)
      assert(r.stderr.includes("changed"))
    })

    await s.test('undo: same-size tampered tail refused (size-only guard hole)', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'undo-tamper')
      mkdirSync(dir)
      const { j, a } = await addForUndo(dir)
      const data = readFileSync(j)
      const tlen = data.length - a.pre
      let evil = Buffer.from("\n2026-09-25 EVIL same-size\n    expenses:x    1.00\n    assets:cash")
      // pad/truncate the evil tail to exactly the same byte length
      if (evil.length > tlen) evil = evil.subarray(0, tlen)
      else evil = Buffer.concat([evil, Buffer.alloc(tlen - evil.length, 0x20)])
      writeFileSync(j, Buffer.concat([data.subarray(0, a.pre), evil]))
      const r = runScript(undo, [j, String(a.pre), String(a.post), a.sha])
      eq(r.code, 1, "must refuse")
      assert(r.stderr.includes("does not match"), r.stderr)
      assert(readFileSync(j).includes("EVIL"), "tampered content must not be truncated")
    })

    await s.test('undo: concurrent append by another writer is preserved', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'undo-concurrent')
      mkdirSync(dir)
      const { j, a } = await addForUndo(dir)
      const other = "\n2026-09-25 other-writer\n    expenses:y    2.00\n    assets:cash\n"
      const { appendFileSync } = await import('node:fs')
      appendFileSync(j, other)
      const r = runScript(undo, [j, String(a.pre), String(a.post), a.sha])
      eq(r.code, 1, "must refuse")
      assert(readFileSync(j).includes("other-writer"), "other writer preserved")
    })

    await s.test('undo: empty/missing fingerprint refused', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'undo-nosha')
      mkdirSync(dir)
      const { j, a } = await addForUndo(dir)
      const r = runScript(undo, [j, String(a.pre), String(a.post), ""])
      eq(r.code, 1)
      assert(r.stderr.includes("fingerprint"))
      assert(readFileSync(j).includes("Script test"), "entry preserved")
    })

    await s.test('undo: TLEN guard refuses post==pre', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'undo-tlen')
      mkdirSync(dir)
      const { j, a } = await addForUndo(dir)
      const r = runScript(undo, [j, String(a.post), String(a.post), a.sha])
      eq(r.code, 1)
    })

    await s.test('undo: double undo refused (second sees size mismatch)', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'undo-twice')
      mkdirSync(dir)
      const { j, a } = await addForUndo(dir)
      eq(run(undo, [j, String(a.pre), String(a.post), a.sha]).code, 0)
      const r = runScript(undo, [j, String(a.pre), String(a.post), a.sha])
      eq(r.code, 1)
    })

    /* ---------- static behavior anchors ---------- */
    await s.test('static: add script never takes the entry from argv', () => {
      const script = extractScript('addScript')
      assert(!script.includes('ENTRY="$3"'), "entry must not come from argv")
      assert(script.includes('read -r LINE'), "entry must be read from stdin")
      assert(script.includes('stat -L'), "sizes must dereference symlinks")
      assert(script.includes('mktemp'), "temp file must be mktemp")
    })
    await s.test('static: undo script verifies content, not just size', () => {
      const script = extractScript('undoScript')
      assert(script.includes('truncate -s'))
      assert(script.includes('sha256sum'), "tail fingerprint check required")
      assert(script.includes('stat -L'))
    })
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
}
