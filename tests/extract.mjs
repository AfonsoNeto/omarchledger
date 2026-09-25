/*
  extract.mjs — pulls testable units out of the QML sources, verbatim.

  Two kinds of extraction:

  1. Functions (pure JS): extracted by name and evaluated inside a vm
     sandbox, so tests run the exact code that ships — no copy-paste drift.
  2. Bash scripts: the `property string *Script` literals are QML
     single-quoted strings, so escape sequences must be unescaped first
     (`\\n` in the source is `\n` at runtime, `\'` is `'`). Getting this
     wrong silently tests a different script than the one that ships.
*/
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
export const SERVICE_QML = path.join(ROOT, 'HledgerService.qml')
export const PANEL_QML = path.join(ROOT, 'Panel.qml')
export const BARWIDGET_QML = path.join(ROOT, 'BarWidget.qml')
export const MANIFEST = path.join(ROOT, 'manifest.json')

export function serviceSource() { return readFileSync(SERVICE_QML, 'utf8') }
export function panelSource() { return readFileSync(PANEL_QML, 'utf8') }
export function barWidgetSource() { return readFileSync(BARWIDGET_QML, 'utf8') }

/*
  Unescape a QML single-quoted string body: `\\x` -> `x` for every escape
  pair, which turns `\\n` into a literal backslash-n (what bash receives
  from QML) and `\\'` into `'`.
*/
export function unescapeQml(raw) {
  return raw.replace(/\\(.)/g, (_, c) => c)
}

function extractAndUnescape(source, kind, name, file) {
  let re
  if (kind === 'script')
    re = new RegExp("property string " + name + ": '\\n(.*?)\\n  '", 's')
  else
    re = new RegExp("function " + name + "\\(.*?\\n  }", 's')
  const m = source.match(re)
  if (!m) throw new Error(`cannot extract ${kind} "${name}" from ${path.basename(file)}`)
  return kind === 'script' ? unescapeQml(m[1]) + "\n" : m[0]
}

/*
  Returns a vm sandbox holding the named functions as globals. Functions
  that reference `root.` (e.g. parseBsText writing root.bsReportDate) work
  against sandbox.root, which tests can read and prime.
*/
export function loadFunctions(file, names) {
  const source = readFileSync(file, 'utf8')
  const ctx = vm.createContext({ root: {}, console })
  for (const name of names) {
    const code = extractAndUnescape(source, 'function', name, file)
    vm.runInContext(code, ctx, { filename: `${path.basename(file)}#${name}` })
  }
  return ctx
}

import vm from 'node:vm'

/* Extract one bash script (runtime text) from HledgerService.qml. */
export function extractScript(name) {
  return extractAndUnescape(serviceSource(), 'script', name, SERVICE_QML)
}

/*
  Extract the inline similar-transaction lookup command (a double-quoted
  QML string with \n escapes) and return the runtime bash text.
*/
export function extractSimilarCommand() {
  const m = serviceSource().match(
    /similarProc\.command = \["bash", "-c",\s*\n\s*'((?:[^'\\]|\\.)*)'/)
  if (!m) throw new Error('cannot extract similarProc.command from HledgerService.qml')
  return unescapeQml(m[1])
}
