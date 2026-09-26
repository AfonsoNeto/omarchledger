/*
  Tests for the embedded bash scripts (resolve/add/undo + the similar
  lookup), extracted verbatim from HledgerService.qml.

  Two layers:
  - Plumbing tests use a stub hledger binary, so they run everywhere.
  - Behavior tests need a real hledger on PATH and are skipped otherwise.

  Every test works on throwaway journals inside a mkdtemp sandbox — the
  user's real journal is never touched.
*/
import { spawnSync, spawn } from 'node:child_process'
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, readFileSync, statSync, existsSync, rmSync, readdirSync, chmodSync } from 'node:fs'
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
    chmodSync(stubBin, 0o755)
    const filesList = path.join(root, 'files.txt')

    await s.test('resolve: override binary wins and its files output is used', async () => {
      const fakeJournal = writeFile(root, 'fake.journal', "2026-01-01 t\n    a  1\n    b\n")
      writeFileSync(filesList, fakeJournal + "\n")
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
      matches(r.stdout, new RegExp("^JF:" + path.join(dir, "link.journal") + "$", "m"))
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
    chmodSync(stubEcho, 0o755)

    await s.test('similar: empty stdin query is a guarded no-op', async () => {
      const r = runScript(similarSh, [stubEcho, path.join(root, 'x.journal'), "1"], "")
      eq(r.code, 0)
      eq(r.stdout, "")
    })
    await s.test('similar: query travels via stdin to hledger print', async () => {
      const r = runScript(similarSh, [stubEcho, path.join(root, 'x.journal'), "1"], "desc:Supermarket\n")
      // stub argv: $1=-f $2=<journal> $3=print $4=<query from stdin>
      matches(r.stdout, /CALLED:[^|]*\.journal\|desc:Supermarket/)
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
      mkdirSync(dir)
      mkdirSync(path.join(dir, '.real'))
      const real = writeFile(path.join(dir, '.real'), 'j.journal', "2026-01-01 Opening\n    assets:cash    100.00\n    incomes:salary\n")
      const before = readFileSync(real)
      const link = path.join(dir, 'j.journal')
      symlinkSync(real, link)
      const r = runScript(add, ['hledger', link, String(ENTRY_LINES)], ENTRY)
      eq(r.code, 0, r.stderr)
      const a = parseAppended(r.stdout)
      eq(a.pre, before.length, "size is of the target, not the symlink")
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
      const r = runScript(add, ['hledger', j, "53"], entry)
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

    await s.test('undo: waits for a concurrent lock holder, then succeeds', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'undo-lockwait')
      mkdirSync(dir)
      const { j, before, a } = await addForUndo(dir)
      const h = spawn('flock', [j, '-c', 'sleep 2'])
      const t0 = Date.now()
      const r = runScript(undo, [j, String(a.pre), String(a.post), a.sha])
      const elapsed = Date.now() - t0
      h.kill()
      eq(r.code, 0, r.stderr)
      assert(elapsed >= 1000, "undo must have waited for the lock, took " + elapsed + "ms")
      eq(readFileSync(j).equals(before), true, "byte-identical restore")
    })

    await s.test('undo: refuses cleanly when the lock cannot be acquired', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'undo-lockbusy')
      mkdirSync(dir)
      const { j, a } = await addForUndo(dir)
      const h = spawn('flock', [j, '-c', 'sleep 6'])
      const r = runScript(undo, [j, String(a.pre), String(a.post), a.sha])
      h.kill()
      eq(r.code, 1, "lock timeout must refuse")
      assert(r.stderr.includes("busy"), r.stderr)
      assert(readFileSync(j).includes("Script test"), "entry preserved")
    })

    await s.test('undo: symlink retarget mid-flight cannot redirect the truncation', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'undo-retarget')
      mkdirSync(dir)
      const realA = writeFile(dir, 'a.journal', "2026-01-01 A\n    assets:cash    100.00\n    incomes:salary\n")
      writeFile(dir, 'b.journal', "2026-02-02 B\n    assets:cash    200.00\n    incomes:salary\n")
      const link = path.join(dir, 'j.journal')
      symlinkSync(realA, link)
      const r = runScript(add, ['hledger', link, String(ENTRY_LINES)], ENTRY)
      eq(r.code, 0, r.stderr)
      const a = parseAppended(r.stdout)
      // Block the undo on the lock, then retarget the symlink while it
      // waits: by the time the undo runs its checks, the path points to
      // b.journal, but its fd is bound to the a.journal inode it opened.
      const h = spawn('flock', [link, '-c', 'sleep 2'])
      const proc = spawn('bash', [undo, link, String(a.pre), String(a.post), a.sha], { encoding: 'utf8' })
      await new Promise(res => setTimeout(res, 500))
      rmSync(link)
      symlinkSync(path.join(dir, 'b.journal'), link)
      const r2 = await new Promise(res => {
        proc.on('close', (code) => res({ code, stdout: proc.stdout.read() || '', stderr: proc.stderr.read() || '' }))
      })
      h.kill()
      eq(r2.code, 0, r2.stderr)
      // the locked inode (a.journal) is restored, b.journal untouched
      eq(readFileSync(realA).toString(), "2026-01-01 A\n    assets:cash    100.00\n    incomes:salary\n")
      assert(readFileSync(path.join(dir, 'b.journal')).includes("2026-02-02 B"), "retargeted file untouched")
    })

    await s.test('undo: double undo refused (second sees size mismatch)', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'undo-twice')
      mkdirSync(dir)
      const { j, a } = await addForUndo(dir)
      eq(runScript(undo, [j, String(a.pre), String(a.post), a.sha]).code, 0)
      const r = runScript(undo, [j, String(a.pre), String(a.post), a.sha])
      eq(r.code, 1)
    })

    /* ---------- static behavior anchors ---------- */
    await s.test('add: waits for a concurrent lock holder, then succeeds', async () => {
      if (!hasHledger) return s.skip('hledger not on PATH')
      const dir = path.join(root, 'add-lockwait')
      mkdirSync(dir)
      const j = writeFile(dir, 'j.journal', "2026-01-01 Opening\n    assets:cash    100.00\n    incomes:salary\n")
      const h = spawn('flock', [j, '-c', 'sleep 2'])
      const t0 = Date.now()
      const r = runScript(add, ['hledger', j, String(ENTRY_LINES)], ENTRY)
      const elapsed = Date.now() - t0
      h.kill()
      eq(r.code, 0, r.stderr)
      assert(elapsed >= 1000, "add must have waited for the lock, took " + elapsed + "ms")
      assert(readFileSync(j).includes("Script test"), "entry appended after the wait")
      eq(leftovers(dir).length, 0)
    })

    await s.test('static: add script never takes the entry from argv', () => {
      const script = extractScript('addScript')
      assert(!script.includes('ENTRY="$3"'), "entry must not come from argv")
      assert(script.includes('read -r LINE'), "entry must be read from stdin")
      assert(script.includes('stat -L'), "sizes must dereference symlinks")
      assert(script.includes('mktemp'), "temp file must be mktemp")
      assert(script.includes('flock -w'), "append must hold the journal lock")
      assert(!script.includes('>> "$HLF"'), "append must target the locked inode, not the path")
    })
    await s.test('static: undo script verifies content, not just size', () => {
      const script = extractScript('undoScript')
      assert(script.includes('truncate -s'))
      assert(script.includes('sha256sum'), "tail fingerprint check required")
      assert(script.includes('stat -L'))
      assert(script.includes('flock -w'), "undo must hold the journal lock")
      assert(script.includes('/proc/self/fd/9'), "operations must target the locked inode")
    })
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
}
