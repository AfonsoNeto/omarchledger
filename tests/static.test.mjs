/*
  Static consistency and hygiene checks: manifest contract, id/moduleName
  agreement, privacy blacklist over shipped files, and — when the tools are
  installed locally — omarchy plugin validate and qmllint.
*/
import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import {
  ROOT, MANIFEST, SERVICE_QML, PANEL_QML, BARWIDGET_QML,
  serviceSource, panelSource, barWidgetSource
} from './extract.mjs'
import { Suite, assert, eq } from './harness.mjs'

const SHIPPED_TEXT_FILES = [
  'manifest.json', 'README.md', 'LICENSE', 'Panel.qml',
  'HledgerService.qml', 'BarWidget.qml'
]

/* Strings from the author's real setup that must never ship again. */
const PRIVACY_BLACKLIST = /monzo|revolut|tesco|asda|nubank|4valleyfield|\/home\/[a-z0-9_]/i

export async function run(s) {
  const manifest = JSON.parse(readFileSync(MANIFEST, 'utf8'))
  const pluginId = path.basename(ROOT)

  await s.test('manifest: schemaVersion is 1', () => {
    eq(manifest.schemaVersion, 1)
  })
  await s.test('manifest: id matches the directory name', () => {
    eq(manifest.id, pluginId)
  })
  await s.test('manifest: id is namespaced and not reserved', () => {
    assert(/^[a-z0-9_.-]+\.[a-z0-9_-]+/.test(manifest.id), "id must be namespaced")
    assert(!manifest.id.startsWith('omarchy.'), "omarchy.* is reserved")
  })
  await s.test('manifest: required fields present and non-empty', () => {
    for (const f of ['id', 'name', 'version', 'author', 'license', 'description', 'kinds', 'entryPoints'])
      assert(manifest[f] !== undefined && manifest[f] !== "" && manifest[f] !== null, "missing " + f)
    assert(Array.isArray(manifest.kinds) && manifest.kinds.length > 0)
  })
  await s.test('manifest: kind bar-widget has an existing entry point', () => {
    assert(manifest.kinds.includes('bar-widget'))
    const ep = manifest.entryPoints.barWidget
    assert(typeof ep === 'string' && ep.length > 0)
    assert(existsSync(path.join(ROOT, ep)), "entry point missing on disk: " + ep)
  })
  await s.test('manifest: name is the user-facing Omarchledger', () => {
    eq(manifest.name, 'Omarchledger')
    eq(manifest.barWidget.displayName, 'Omarchledger')
  })

  await s.test('QML: moduleName identical in BarWidget and Panel and equals id', () => {
    const bw = barWidgetSource().match(/moduleName: "([^"]+)"/)
    const pn = panelSource().match(/moduleName: "([^"]+)"/)
    eq(bw[1], pluginId)
    eq(pn[1], pluginId)
  })
  await s.test('QML: bar widget exposes the full panel lifecycle contract', () => {
    const src = barWidgetSource()
    for (const member of ['readonly property bool opened', 'popoutSwitchClosing',
      'function open()', 'function close()', 'function togglePanel()',
      'function closeForPopoutSwitch()', 'function injectPanel()'])
      assert(src.includes(member), "BarWidget.qml missing: " + member)
  })

  await s.test('privacy: no real account/description strings in shipped files', () => {
    for (const f of SHIPPED_TEXT_FILES) {
      const content = readFileSync(path.join(ROOT, f), 'utf8')
      const m = content.match(PRIVACY_BLACKLIST)
      assert(!m, `${f} contains private string: ${m && m[0]}`)
    }
  })

  await s.test('scripts: helper inputs are validated', () => {
    const svc = serviceSource()
    assert(svc.includes("case \"$NLINES\""), "addScript must validate NLINES")
    assert(svc.includes("case \"$TLEN\""), "undoScript must validate TLEN")
    assert(svc.includes('[ -n "$QUERY" ] || exit 0'), "similar query must reject empty")
    assert(svc.includes('flattenLine'), "entry building must flatten line separators")
  })

  await s.test('omarchy plugin validate', async () => {
    const which = spawnSync('sh', ['-c', 'command -v omarchy'])
    if (which.status !== 0) return s.skip('omarchy CLI not found')
    const r = spawnSync('omarchy', ['plugin', 'validate', ROOT], { encoding: 'utf8' })
    eq(r.status, 0, (r.stdout || '') + (r.stderr || ''))
  })

  await s.test('qmllint on Panel.qml and HledgerService.qml', async () => {
    const which = spawnSync('sh', ['-c', 'command -v qmllint'])
    if (which.status !== 0) return s.skip('qmllint not found')
    // BarWidget.qml is expected to fail on legacy qmllint builds (typed
    // `void` functions); only assert the two files that must pass.
    for (const f of [PANEL_QML, SERVICE_QML]) {
      const r = spawnSync('qmllint', [f], { encoding: 'utf8' })
      eq(r.status, 0, `qmllint ${path.basename(f)}: ${r.stderr || r.stdout || 'exit ' + r.status}`)
    }
  })
}
