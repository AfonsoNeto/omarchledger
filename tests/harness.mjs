/* Minimal test harness: sequential suites, PASS/SKIP/FAIL lines, summary. */

export function assert(cond, msg) {
  if (!cond) throw new Error(msg || "assertion failed")
}

export function eq(actual, expected, msg) {
  if (actual !== expected) {
    throw new Error((msg || "not equal")
      + "\n   actual:   " + JSON.stringify(actual)
      + "\n   expected: " + JSON.stringify(expected))
  }
}

export function matches(actual, regex, msg) {
  if (!regex.test(actual)) {
    throw new Error((msg || "regex mismatch")
      + "\n   actual: " + JSON.stringify(actual)
      + "\n   regex:  " + String(regex))
  }
}

export class Suite {
  constructor(name) {
    this.name = name
    this.results = []
  }

  async test(desc, fn) {
    try {
      await fn()
      this.results.push({ desc, ok: true })
    } catch (e) {
      this.results.push({ desc, ok: false, error: e })
    }
  }

  /* Record a test that cannot run in this environment. */
  skip(desc, reason) {
    this.results.push({ desc, ok: true, skipped: true, reason })
  }

  report() {
    let pass = 0, fail = 0, skipped = 0
    console.log(`\n=== ${this.name} ===`)
    for (const r of this.results) {
      if (r.skipped) {
        skipped++
        console.log(`SKIP  ${r.desc}  (${r.reason})`)
      } else if (r.ok) {
        pass++
        console.log(`PASS  ${r.desc}`)
      } else {
        fail++
        console.log(`FAIL  ${r.desc}`)
        console.log("      " + String(r.error && r.error.message || r.error).split("\n").join("\n      "))
      }
    }
    console.log(`--- ${this.name}: ${pass} passed, ${fail} failed, ${skipped} skipped`)
    return fail
  }
}
