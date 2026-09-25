/*
  Unit tests for every pure-JS function that ships in the plugin. The
  functions are extracted verbatim from the QML sources (see extract.mjs)
  and evaluated in a vm sandbox, so what is tested is exactly what runs.
*/
import { loadFunctions, SERVICE_QML, PANEL_QML } from './extract.mjs'
import { Suite, assert, eq, matches } from './harness.mjs'

const service = loadFunctions(SERVICE_QML, [
  'flattenLine', 'buildEntry', 'isNegativeAmount', 'regexEscape',
  'parseBsText', 'parseStatsText', 'parsePrint', 'resolveErrorText'])
const panel = loadFunctions(PANEL_QML, ['parseSimpleAmount', 'balancingAmountFor', 'isStale'])

export async function run(s) {
  /* ---------------- flattenLine / buildEntry ---------------- */
  await s.test('flattenLine: CR/LF becomes a space', () => {
    eq(service.flattenLine("a\r\nb"), "a b")
  })
  await s.test('flattenLine: U+2028/U+2029 become spaces', () => {
    eq(service.flattenLine("a\u2028b\u2029c"), "a b c")
  })
  await s.test('flattenLine: separator runs collapse', () => {
    eq(service.flattenLine("a\n\n\r\nb"), "a b")
  })
  await s.test('flattenLine: null/undefined/number safe', () => {
    eq(service.flattenLine(null), "")
    eq(service.flattenLine(undefined), "")
    eq(service.flattenLine(5), "5")
  })

  await s.test('buildEntry: exact journal format with comment', () => {
    eq(service.buildEntry("2026-09-13", "Coffee", "fixed:monthly", [
      { account: "expenses:food", amount: "£3.50" },
      { account: "assets:bank:checking", amount: "" }]),
      "\n2026-09-13 Coffee  ; fixed:monthly\n    expenses:food  £3.50\n    assets:bank:checking\n")
  })
  await s.test('buildEntry: no comment when empty', () => {
    const e = service.buildEntry("2026-09-13", "X", "  ", [
      { account: "a", amount: "1" }, { account: "b", amount: "1" }])
    eq(e.includes(";"), false, "no semicolon expected")
  })
  await s.test('buildEntry: injection via description is flattened', () => {
    const e = service.buildEntry("2026-09-25",
      "Coffee\n2020-01-01 Fake\n    expenses:x  999\n    assets:y", "", [
        { account: "expenses:food", amount: "£1" },
        { account: "assets:cash", amount: "" }])
    eq(e.includes("\n2020-01-01"), false, "forged txn must not appear")
    eq(e.split("\n").length - 1, 4, "exactly header + 2 postings")
  })
  await s.test('buildEntry: injection via comment/account/amount flattened', () => {
    const e = service.buildEntry("2026-09-25", "X", "tag\rone", [
      { account: "expen\nses:food", amount: "£1\n.00" },
      { account: "assets:cash", amount: "" }])
    assert(e.includes("tag one"), "comment flattened")
    assert(e.includes("expen ses:food"), "account flattened")
    assert(e.includes("£1 .00"), "amount flattened")
    eq(e.split("\n").length - 1, 4)
  })
  await s.test('buildEntry: legit quotes and ampersands untouched', () => {
    const e = service.buildEntry("2026-09-25", "O'Brien & Sons \"test\"", "fixed:monthly", [
      { account: "expenses:food", amount: "£3.50" },
      { account: "assets:cash", amount: "" }])
    assert(e.includes("O'Brien & Sons \"test\""))
    assert(e.includes("; fixed:monthly"))
  })
  await s.test('buildEntry: many postings keep their lines', () => {
    const postings = []
    for (let i = 0; i < 30; i++) postings.push({ account: "acc" + i, amount: "1" })
    const e = service.buildEntry("2026-09-25", "Split", "", postings)
    eq(e.split("\n").length - 1, 32) // blank + header + 30 postings
  })

  /* ---------------- isNegativeAmount ---------------- */
  await s.test('isNegativeAmount: table of amounts', () => {
    eq(service.isNegativeAmount("£-69.00"), true)
    eq(service.isNegativeAmount("-£69.00"), true)
    eq(service.isNegativeAmount("£5293.99"), false)
    eq(service.isNegativeAmount("BTC 0.00257597"), false)
    eq(service.isNegativeAmount("R$-6.16, £389.01"), true)
    eq(service.isNegativeAmount(""), false)
    eq(service.isNegativeAmount(null), false)
  })

  /* ---------------- regexEscape ---------------- */
  await s.test('regexEscape: metacharacters escaped', () => {
    eq(service.regexEscape("Tesco (Main)"), "Tesco \\(Main\\)")
    eq(service.regexEscape("A.B*C"), "A\\.B\\*C")
    eq(service.regexEscape("a|b$c?d[e]f(g)h\\i"), "a\\|b\\$c\\?d\\[e\\]f\\(g\\)h\\\\i")
  })
  await s.test('regexEscape: plain text and unicode preserved', () => {
    eq(service.regexEscape("Café & Aldi"), "Café & Aldi")
  })

  /* ---------------- parseSimpleAmount ---------------- */
  await s.test('parseSimpleAmount: plain amounts with commodities', () => {
    const a = panel.parseSimpleAmount("£-15.94")
    eq(a.value, -15.94); eq(a.commodity, "£"); eq(a.decimals, 2)
    const b = panel.parseSimpleAmount("R$-6.16")
    eq(b.commodity, "R$")
    const c = panel.parseSimpleAmount("10")
    eq(c.value, 10); eq(c.commodity, ""); eq(c.decimals, 0)
  })
  await s.test('parseSimpleAmount: rejects non-plain amounts', () => {
    eq(panel.parseSimpleAmount(""), null)
    eq(panel.parseSimpleAmount("   "), null)
    eq(panel.parseSimpleAmount("1 BTC @ £45500.25"), null)
    eq(panel.parseSimpleAmount("£1.00 = £1.00"), null)
    eq(panel.parseSimpleAmount("what?!"), null)
    eq(panel.parseSimpleAmount("R$-6.16, £389.01"), null) // two commodities
  })
  await s.test('parseSimpleAmount: comma decimals and signs', () => {
    eq(panel.parseSimpleAmount("£-15,94").value, -15.94)
    eq(panel.parseSimpleAmount("+5").value, 5)
  })

  /* ---------------- balancingAmountFor ---------------- */
  const bal = (amounts, i) => panel.balancingAmountFor(amounts, i)
  await s.test('balancing: the Asda scenario (edit row 0 rebalances row 1)', () => {
    eq(bal(["£-15.94", "£30.14", "£-0.86", "£0.86"], 0), "£15.94")
  })
  await s.test('balancing: editing a middle row rebalances the next', () => {
    eq(bal(["£-15.94", "£15.94", "£-1.20", "£0.86"], 2), "£1.20")
  })
  await s.test('balancing: already-balanced prefill is a no-op', () => {
    eq(bal(["£-30.14", "£30.14", "£-0.86", "£0.86"], 0), "£30.14")
  })
  await s.test('balancing: simple two-posting flips', () => {
    eq(bal(["£-3.50", "£3.50"], 0), "£3.50")
    eq(bal(["£-3.50", ""], 0), "£3.50")
    eq(bal(["£10", "£-10"], 0), "£-10")
  })
  await s.test('balancing: commodity inheritance (edited wins, then next)', () => {
    eq(bal(["-15.94", "£30.14"], 0), "£15.94")
    eq(bal(["R$-15.94", "£30.14"], 0), "R$15.94")
  })
  await s.test('balancing: last row has no next -> no change', () => {
    eq(bal(["£-3.50", "£3.50"], 1), null)
    eq(bal(["£-3.50"], 0), null)
  })
  await s.test('balancing: unparseable amounts abort the update', () => {
    eq(bal(["1 BTC @ £45500.25", "£45500.25"], 0), null)
    eq(bal(["what?!", "£3.50"], 0), null)
    eq(bal(["", "£3.50"], 0), null)
  })
  await s.test('balancing: empty amounts count as zero', () => {
    eq(bal(["£-15.94", "£15.94", ""], 0), "£15.94")
    eq(bal(["£-5", "", ""], 0), "£5")
  })
  await s.test('balancing: precision mirrors the widest input', () => {
    eq(bal(["£10", "£0.25"], 0), "£-10.00")
    eq(bal(["£10", "£5"], 0), "£-10")
    eq(bal(["£0.001", "£5"], 0), "£-0.001")
  })
  await s.test('balancing: negative zero normalized', () => {
    eq(bal(["£5", "£-5", "£-5"], 0), "£0")
  })
  await s.test('balancing: multi-commodity tail cancels', () => {
    eq(bal(["R$-6.16", "£30.14", "R$6.16", "£-30.14"], 0), "R$30.14")
  })

  /* ---------------- isStale ---------------- */
  await s.test('isStale: Last txn older than 7 days is stale', () => {
    eq(panel.isStale("Last txn", "2026-08-30 (14 days ago)"), true)
    eq(panel.isStale("Last txn", "2026-09-12 (8 days ago)"), true)
  })
  await s.test('isStale: fresh and non-txn keys are not stale', () => {
    eq(panel.isStale("Last txn", "2026-09-12 (7 days ago)"), false)
    eq(panel.isStale("Last txn", "2026-09-12 (1 days ago)"), false)
    eq(panel.isStale("Txns", "477 (3.4 per day)"), false)
    eq(panel.isStale("Payees/descriptions", "161"), false)
  })

  /* ---------------- parseBsText ---------------- */
  const BS_FIXTURE = [
    "Balance Sheet 2026-08-30",
    "",
    "                          ||     2026-08-30 ",
    "==========================++=============",
    " Assets                   ||             ",
    "--------------------------++-------------",
    " assets:cash              ||      £90.00 ",
    " assets:bank:checking     ||   £13227.60 ",
    " assets:crypto:bitcoin    || BTC 0.025   ",
    " assets:receivable        ||      £-45.00 ",
    "--------------------------++-------------",
    "                          || BTC 0.025, £13272.60 ",
    "==========================++=============",
    " Liabilities              ||             ",
    "--------------------------++-------------",
    " liabilities:cards:visa   ||    £2041.25 ",
    "--------------------------++-------------",
    "                          ||    £2041.25 ",
    "==========================++=============",
    " Net:                     || BTC 0.025, £11231.35 ",
    ""
  ].join("\n")

  await s.test('parseBsText: sections, rows, totals, net', () => {
    service.root.bsReportDate = ""
    const secs = service.parseBsText(BS_FIXTURE)
    eq(secs.length, 3)
    eq(secs[0].name, "Assets")
    eq(secs[1].name, "Liabilities")
    eq(secs[2].name, "Net")
    eq(service.root.bsReportDate, "2026-08-30")
    assert(secs[0].rows.some(r => r.account === "assets:cash" && r.balance === "£90.00"))
    const rec = secs[0].rows.find(r => r.account === "assets:receivable")
    assert(rec && rec.isNegative === true, "negative row flagged")
    const cash = secs[0].rows.find(r => r.account === "assets:cash")
    assert(cash && cash.isNegative === false, "positive row not flagged")
    assert(secs[0].total.includes("£13272.60"))
    assert(secs[2].total.includes("£11231.35"))
  })
  await s.test('parseBsText: garbage and empty input are safe', () => {
    service.root.bsReportDate = ""
    eq(service.parseBsText("no table here").length, 0)
    eq(service.parseBsText("").length, 0)
    eq(service.parseBsText(null).length, 0)
    eq(service.root.bsReportDate, "")
  })

  /* ---------------- parseStatsText ---------------- */
  const STATS_FIXTURE = [
    "Main file           : ~/ledger.journal",
    "Included files      : 2",
    "Txns span           : 2026-04-11 to 2026-08-31 (142 days)",
    "Last txn            : 2026-08-30 (14 days ago)",
    "Txns                : 477 (3.4 per day)",
    "Payees/descriptions : 161",
    ""
  ].join("\n")
  await s.test('parseStatsText: key/value extraction', () => {
    const st = service.parseStatsText(STATS_FIXTURE)
    eq(st.length, 6)
    eq(st[0].key, "Main file")
    eq(st[0].value, "~/ledger.journal")
    assert(st.some(e => e.key === "Txns" && e.value === "477 (3.4 per day)"))
  })
  await s.test('parseStatsText: skips lines without the separator', () => {
    eq(service.parseStatsText("no separator here\nalso not").length, 0)
    eq(service.parseStatsText("").length, 0)
  })

  /* ---------------- parsePrint ---------------- */
  await s.test('parsePrint: single transaction with amounts', () => {
    const p = service.parsePrint(
      "2026-05-19 Supermarket\n    liabilities:cards:visa         £-70.08\n    expenses:groceries              £70.08\n")
    eq(p.found, true)
    eq(p.date, "2026-05-19")
    eq(p.description, "Supermarket")
    eq(p.postings.length, 2)
    eq(p.postings[1].amount, "£70.08")
  })
  await s.test('parsePrint: LAST transaction wins (most recent similar)', () => {
    const p = service.parsePrint(
      "2026-01-01 Alpha\n    expenses:a    1.00\n    assets:cash\n\n2026-01-02 * Beta ; note here\n    expenses:b    2.00\n    assets:cash\n")
    eq(p.description, "Beta")
    eq(p.comment, "note here")
  })
  await s.test('parsePrint: amountless posting captured as empty', () => {
    const p = service.parsePrint("2026-01-05 Synth\n    expenses:a    5.00\n    assets:cash\n")
    eq(p.postings[1].amount, "")
  })
  await s.test('parsePrint: cost expressions kept whole', () => {
    const p = service.parsePrint("2026-01-03 Buy BTC\n    assets:crypto    1 BTC @ £45500.25\n    assets:cash    £-45500.25\n")
    eq(p.postings[0].amount, "1 BTC @ £45500.25")
    eq(p.postings[1].amount, "£-45500.25")
  })
  await s.test('parsePrint: posting comments stripped', () => {
    const p = service.parsePrint("2026-01-07 T\n    expenses:a    1.00  ; note\n    assets:cash\n")
    eq(p.postings[0].amount, "1.00")
  })
  await s.test('parsePrint: no match and empty input', () => {
    eq(service.parsePrint("nothing here").found, false)
    eq(service.parsePrint("").found, false)
    eq(service.parsePrint(null).found, false)
  })
  await s.test('parsePrint: equation-style date accepted', () => {
    const p = service.parsePrint("2026-03-01=2026-03-05 Paid\n    expenses:a    1.00\n    assets:cash\n")
    eq(p.date, "2026-03-01=2026-03-05")
  })

  /* ---------------- resolveErrorText ---------------- */
  await s.test('resolveErrorText: known codes map to actionable messages', () => {
    assert(service.resolveErrorText("hledger-not-found").includes("hledger was not found"))
    assert(service.resolveErrorText("no-journal").includes("No journal file found"))
    assert(service.resolveErrorText("journal-unreadable").includes("not a regular file"))
  })
  await s.test('resolveErrorText: unknown code passes through', () => {
    eq(service.resolveErrorText("weird-code"), "weird-code")
  })
}
