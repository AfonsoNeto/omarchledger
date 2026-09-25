# Omarchledger test suite

```
node tests/run.mjs
```

Runs three suites and exits non-zero on any failure. No dependencies beyond
Node (>= 18), bash and coreutils; everything is extracted **verbatim** from
the QML sources, so the tests always exercise the code that ships.

| Suite | What it covers | Needs hledger? |
| --- | --- | --- |
| `unit.test.mjs` (42) | Every pure-JS function: entry building + line-separator flattening (injection guard), balance-sheet/stats/print parsers, live auto-balancing, amount parsing, negative detection, regex escaping, stale-journal detection | no |
| `scripts.test.mjs` (28) | The embedded bash helpers: journal/binary resolution (overrides, FIFO/dangling-symlink rejection), validate-before-append (byte-exact writes, unbalanced rejection, symlinked journals, relative `include`s, special characters, stress postings), fingerprint-protected undo (size mismatch, same-size tamper, concurrent writer), input validation (`NLINES`/`TLEN`/empty query), temp-file hygiene | only for behavior tests; plumbing tests use a stub binary |
| `static.test.mjs` (12) | Manifest contract (id = directory name, namespaced, not reserved), `moduleName` agreement between BarWidget and Panel, bar-widget lifecycle contract, **privacy blacklist** over shipped files, helper-input validation markers, `omarchy plugin validate` and `qmllint` when installed | no |

Tests never touch the user's real journal: all fixtures are synthetic and
live in `mkdtemp` directories that are removed afterwards.

## Adding tests

- **Pure JS** goes into `unit.test.mjs`. If you add a function to the QML,
  list it in the `loadFunctions(...)` call so it gets extracted; functions
  that reference `root.` get a sandbox `root` with all loaded functions
  attached, mirroring the QML component scope.
- **Script behavior** goes into `scripts.test.mjs`: extract with
  `extractScript(name)`, run with `runScript(path, args, stdin)`, and assert
  on the `APPENDED:<pre>:<post>:<sha>` markers, exit codes and journal bytes.
- If a QML change makes extraction fail, the error names the file and the
  missing function/property — update the `loadFunctions` list or the regex.

## Manual end-to-end test

The live UI flow (summon the panel via IPC, type with `wtype`, screenshot
with `grim`) can't run headless; the checklist lives in `HANDOVER.md`
§ "Testing". Run it after any Panel.qml/KeyboardPanel-related change.
