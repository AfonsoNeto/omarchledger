/*
  Omarchledger test suite runner.

      node tests/run.mjs

  Runs three suites (see tests/README.md):
    - unit:    every pure-JS function, extracted verbatim from the QML
    - scripts: the embedded bash helpers against throwaway journals
    - static:  manifest/module contract + privacy hygiene + linters

  Exits non-zero if anything failed. hledger-dependent tests skip cleanly
  when hledger is not on PATH.
*/
import { Suite } from './harness.mjs'
import * as unit from './unit.test.mjs'
import * as scripts from './scripts.test.mjs'
import * as staticTests from './static.test.mjs'

const suites = [
  ['unit tests', unit],
  ['bash scripts', scripts],
  ['static checks', staticTests]
]

let failures = 0
for (const [name, mod] of suites) {
  const s = new Suite(name)
  await mod.run(s)
  failures += s.report()
}

console.log("")
if (failures > 0) {
  console.log(`✗ ${failures} test(s) FAILED`)
  process.exit(1)
}
console.log("✓ all tests passed")
