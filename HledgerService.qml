/*
  HledgerService.qml — business logic for the Omarchledger plugin.

  Owns every hledger invocation:

    - Binary + journal resolution with zero hardcoded paths. The binary comes
      from `command -v hledger` (or the user's hledgerBin override); the
      journal comes from `hledger files` line 1, so hledger's own resolution
      (LEDGER_FILE → ~/.hledger.journal) is honored on any machine.
    - Data fetchers for autocomplete and the Balance/Summary tabs.
    - "Use similar" lookup: parses the most recent transaction matching a
      description via `hledger print`.
    - Validate-then-append submission. A proposed entry is checked on a
      temporary copy of the journal placed in the journal's own directory
      (a stdin pipe would break relative `include` directives), and the real
      journal is only appended to when the check passes. Undo truncates back
      to the remembered pre-append size and refuses if the file changed.

  Every command runs through `bash -c` with the binary/journal passed as
  positional arguments, so paths are never word-split or shell-interpreted.
*/
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root
  visible: false

  /* ---- optional overrides (shell.json layout entry) --------------------- */
  property string hledgerBinOverride: ""
  property string journalFileOverride: ""

  /* ---- resolution ------------------------------------------------------- */
  property bool resolved: false
  property string hledgerBin: ""
  property string journalFile: ""
  property string resolveError: ""
  // Overrides as they were when the current resolution ran, so Panel can
  // detect a settings change that invalidates it.
  property string resolvedBinOverride: ""
  property string resolvedJournalOverride: ""

  /*
    Drop everything tied to the current resolution — data caches and,
    critically, the add/undo state: its sizes and entry fingerprint belong
    to the journal that was resolved when the transaction was added and
    must never be carried over to a different file.
  */
  function resetResolution() {
    root.resolved = false
    root.resolveError = ""
    root.hledgerBin = ""
    root.journalFile = ""
    root.accountList = []
    root.descriptionList = []
    root.commodityList = []
    root.bsSections = []
    root.bsReportDate = ""
    root.statsEntries = []
    root.busyAccounts = false
    root.busyBs = false
    root.busyStats = false
    root.busyAdd = false
    root.canUndo = false
    root.preAddSize = -1
    root.postAddSize = -1
    root.entrySha256 = ""
    root.entryLen = -1
  }

  /* ---- data stores ------------------------------------------------------ */
  property var accountList: []
  property var descriptionList: []
  property var commodityList: []
  property var bsSections: []          // [{name, rows: [{account, balance, isNegative}], total, isNegative}]
  property string bsReportDate: ""
  property string bsError: ""
  property var statsEntries: []        // [{key, value}]
  property string statsError: ""

  /* ---- "use similar" prefill -------------------------------------------- */
  property bool busySimilar: false
  property bool similarFound: false
  property string similarDate: ""
  property string similarDescription: ""
  property string similarComment: ""
  property var similarPostings: []     // [{account, amount}]

  /* ---- add / undo ------------------------------------------------------- */
  property bool busyAdd: false
  property string addMessage: ""
  property bool addOk: false
  property int preAddSize: -1
  property int postAddSize: -1
  property string entrySha256: ""
  property int entryLen: -1
  property bool canUndo: false

  /* ---- busy flags ------------------------------------------------------- */
  property bool busyAccounts: false
  property bool busyBs: false
  property bool busyStats: false

  signal resolvedOk()
  signal accountsReady()
  signal descriptionsReady()
  signal balanceReady()
  signal statsReady()
  signal similarReady(bool found)
  signal addFinished(bool ok)
  signal undoFinished(bool ok)

  /* ---- lifecycle -------------------------------------------------------- */

  function resolve() {
    if (root.resolved) {
      if (root.resolveError === "") root.resolvedOk()
      return
    }
    resolveProc.command = ["bash", "-c", resolveScript, "omarchledger",
      root.hledgerBinOverride, root.journalFileOverride]
    resolveProc.running = true
  }

  property string resolveScript: '
    BIN=""
    if [ -n "$1" ]; then BIN="$1"; else BIN="$(command -v hledger 2>/dev/null)"; fi
    if [ -z "$BIN" ]; then echo "ERR:hledger-not-found"; exit 0; fi
    if [ ! -x "$BIN" ] && ! command -v "$BIN" >/dev/null 2>&1; then
      echo "ERR:hledger-not-found"
      exit 0
    fi
    echo "BIN:$BIN"
    JF=""
    if [ -n "$2" ]; then
      JF="$2"
    else
      JF="$("$BIN" files 2>/dev/null | head -n 1)"
    fi
    if [ -z "$JF" ]; then echo "ERR:no-journal"; exit 0; fi
    # -f follows symlinks and only accepts regular files: a FIFO or device
    # node would hang or misbehave in the later read/write helpers.
    if [ ! -f "$JF" ]; then echo "ERR:journal-unreadable"; exit 0; fi
    echo "JF:$JF"
  '

  function resolveErrorText(code) {
    if (code === "hledger-not-found")
      return "hledger was not found on PATH. Install it (e.g. your package manager, hledger.org, or via mise) or set the \"hledgerBin\" option on the Omarchledger bar widget."
    if (code === "no-journal")
      return "No journal file found. Set LEDGER_FILE, create ~/.hledger.journal, or set the \"journalFile\" option on the Omarchledger bar widget."
    if (code === "journal-unreadable")
      return "The journal file was not found or is not a regular file. Check the \"journalFile\" option on the Omarchledger bar widget or your hledger configuration."
    return code
  }

  /* ---- fetchers --------------------------------------------------------- */

  function fetchAccounts() {
    if (!root.resolved || root.resolveError !== "" || root.busyAccounts) return
    root.busyAccounts = true
    accountsProc.command = ["bash", "-c", '"$1" -f "$2" accounts 2>/dev/null', "omarchledger", root.hledgerBin, root.journalFile]
    accountsProc.running = true
  }

  function fetchDescriptions() {
    if (!root.resolved || root.resolveError !== "") return
    descriptionsProc.command = ["bash", "-c", '"$1" -f "$2" descriptions 2>/dev/null', "omarchledger", root.hledgerBin, root.journalFile]
    descriptionsProc.running = true
  }

  function fetchCommodities() {
    if (!root.resolved || root.resolveError !== "") return
    commoditiesProc.command = ["bash", "-c", '"$1" -f "$2" commodities 2>/dev/null', "omarchledger", root.hledgerBin, root.journalFile]
    commoditiesProc.running = true
  }

  function fetchBalanceSheet() {
    if (!root.resolved || root.resolveError !== "" || root.busyBs) return
    root.busyBs = true
    root.bsError = ""
    bsProc.command = ["bash", "-c", '"$1" -f "$2" bs --flat', "omarchledger", root.hledgerBin, root.journalFile]
    bsProc.running = true
  }

  function fetchStats() {
    if (!root.resolved || root.resolveError !== "" || root.busyStats) return
    root.busyStats = true
    root.statsError = ""
    statsProc.command = ["bash", "-c", '"$1" -f "$2" stats', "omarchledger", root.hledgerBin, root.journalFile]
    statsProc.running = true
  }

  function fetchSimilar(description) {
    if (!root.resolved || root.resolveError !== "" || root.busySimilar) return
    var d = (description || "").trim()
    if (d === "") return
    root.busySimilar = true
    root.similarFound = false
    root.similarDate = ""
    root.similarDescription = ""
    root.similarComment = ""
    root.similarPostings = []
    // desc: matches as a regex; escape metacharacters so a plain description
    // behaves like a literal substring match.
    var query = "desc:" + regexEscape(d)
    // The query is piped over stdin (single line) — never placed on the
    // command line, where it would be readable by other local users.
    similarProc.command = ["bash", "-c",
      'IFS= read -r QUERY\n[ -n "$QUERY" ] || exit 0\n"$1" -f "$2" print "$QUERY" 2>/dev/null',
      "omarchledger", root.hledgerBin, root.journalFile, "1"]
    similarProc.pendingQuery = query + "\n"
    similarProc.running = true
  }

  /* ---- add / undo ------------------------------------------------------- */

  function addTransaction(entryText) {
    if (!root.resolved || root.resolveError !== "" || root.busyAdd) return
    root.busyAdd = true
    root.addOk = false
    root.addMessage = ""
    // The entry is piped to the helper's stdin; argv only carries the number
    // of lines to read. Journal entries hold financial data and must never
    // appear on the command line (/proc/<pid>/cmdline is world-readable).
    var lineCount = entryText.split("\n").length - 1
    addProc.pendingEntry = entryText
    addProc.command = ["bash", "-c", addScript, "omarchledger", root.hledgerBin, root.journalFile, String(lineCount)]
    addProc.running = true
  }

  property string addScript: '
    HL="$1"
    HLF="$2"
    NLINES="$3"
    case "$NLINES" in \'\'|*[!0-9]*|0)
      echo "omarchledger: malformed entry size" >&2
      exit 5
    ;;
    esac
    ENTRY=""
    i=0
    while [ "$i" -lt "$NLINES" ]; do
      IFS= read -r LINE
      printf -v ENTRY "%s%s\\n" "$ENTRY" "$LINE"
      i=$((i + 1))
    done
    JDIR="$(cd "$(dirname "$HLF")" 2>/dev/null && pwd)"
    if [ -z "$JDIR" ]; then
      echo "omarchledger: cannot access the journal directory" >&2
      exit 5
    fi
    if [ ! -f "$HLF" ]; then
      echo "omarchledger: journal is not a regular file; refusing to write" >&2
      exit 5
    fi
    TMP=""
    cleanup() { [ -n "$TMP" ] && rm -f -- "$TMP"; }
    trap cleanup EXIT INT TERM HUP
    ORIG_UMASK="$(umask)"
    umask 077
    TMP="$(mktemp -p "$JDIR" .omarchledger-check.XXXXXXXXXX.tmp 2>/dev/null)"
    umask "$ORIG_UMASK"
    if [ -z "$TMP" ] || [ ! -f "$TMP" ] || [ -L "$TMP" ] || [ ! -O "$TMP" ]; then
      cleanup
      echo "omarchledger: cannot create secure temporary validation file" >&2
      exit 5
    fi
    if ! cat "$HLF" > "$TMP" 2>/dev/null; then
      cleanup
      echo "omarchledger: cannot read the journal file" >&2
      exit 5
    fi
    printf "%s" "$ENTRY" >> "$TMP"
    CHECK="$(cd "$JDIR" && "$HL" -f "$TMP" check 2>&1)"
    RC=$?
    cleanup
    trap - EXIT INT TERM HUP
    if [ $RC -ne 0 ]; then
      printf "%s\n" "$CHECK" >&2
      exit 1
    fi
    # Serialize the mutation window with undo and other plugin instances
    # (two monitors = two live panels): an undo truncating during this
    # append would otherwise interleave, and a concurrent append would be
    # captured into the recorded sizes.
    # Read-write fd: the append goes through /proc/self/fd/9, re-opening
    # the LOCKED inode, so a symlink retarget between the size capture and
    # the append can never redirect the write to a different file.
    exec 9<>"$HLF" || { echo "omarchledger: cannot open the journal" >&2; exit 5; }
    if ! flock -w 3 9; then
      echo "omarchledger: the journal is busy; try again" >&2
      exit 1
    fi
    JF="/proc/self/fd/9"
    SIZE="$(stat -L -c %s "$JF" 2>/dev/null)"
    if [ -z "$SIZE" ]; then SIZE=0; fi
    if ! printf "%s" "$ENTRY" >> "$JF" 2>/dev/null; then
      echo "omarchledger: cannot write to the journal file" >&2
      exit 5
    fi
    NEWSIZE="$(stat -L -c %s "$JF" 2>/dev/null)"
    ESHA="$(printf "%s" "$ENTRY" | sha256sum | cut -d" " -f1)"
    ELEN="$(printf "%s" "$ENTRY" | wc -c)"
    echo "APPENDED:$SIZE:$NEWSIZE:$ESHA:$ELEN"
  '

  function undoLastAdd() {
    if (!root.canUndo || root.busyAdd) return
    root.busyAdd = true
    undoProc.command = ["bash", "-c", undoScript, "omarchledger", root.journalFile,
      String(root.preAddSize), String(root.postAddSize), root.entrySha256,
      String(root.entryLen)]
    undoProc.running = true
  }

  property string undoScript: '
    HLF="$1"
    PRESIZE="$2"
    POSTSIZE="$3"
    ESHA="$4"
    TLEN="$5"
    if [ ! -f "$HLF" ]; then
      echo "omarchledger: journal is not a regular file; refusing to write" >&2
      exit 5
    fi
    if [ ! -r "$HLF" ] || [ ! -w "$HLF" ]; then
      echo "omarchledger: journal is not readable/writable" >&2
      exit 5
    fi
    # Undo is NON-DESTRUCTIVE by construction: it never removes bytes. The
    # byte range of the transaction is rewritten IN PLACE, at constant length,
    # with comment lines hledger ignores. A concurrent writer appending
    # without our lock can therefore never lose data - appends land at EOF,
    # outside the rewritten range, no matter how they interleave. flock
    # only serializes instances of this plugin itself.
    exec 9<>"$HLF" || { echo "omarchledger: cannot open the journal" >&2; exit 5; }
    if ! flock -w 3 9; then
      echo "omarchledger: the journal is busy; try again" >&2
      exit 1
    fi
    JF="/proc/self/fd/9"
    CUR="$(stat -L -c %s "$JF" 2>/dev/null)"
    if [ -z "$CUR" ]; then
      echo "omarchledger: cannot read the journal file" >&2
      exit 5
    fi
    # The entry may no longer be the last thing in the journal (other
    # transactions may have been added after it), so only a shrinking file
    # means our region is gone.
    if [ "$CUR" -lt "$POSTSIZE" ]; then
      echo "omarchledger: the journal changed since the transaction was added; refusing to undo" >&2
      exit 1
    fi
    if [ -z "$ESHA" ]; then
      echo "omarchledger: no transaction fingerprint recorded; refusing to undo" >&2
      exit 1
    fi
    case "$TLEN" in \'\'|*[!0-9]*|0)
      echo "omarchledger: the journal changed since the transaction was added; refusing to undo" >&2
      exit 1
    ;;
    esac
    TMP=""
    cleanup() { [ -n "$TMP" ] && rm -f -- "$TMP"; }
    trap cleanup EXIT INT TERM HUP
    ORIG_UMASK="$(umask)"
    umask 077
    TMP="$(mktemp -p "$(dirname "$HLF")" .omarchledger-undo.XXXXXXXXXX.tmp 2>/dev/null)"
    umask "$ORIG_UMASK"
    if [ -z "$TMP" ]; then
      echo "omarchledger: cannot create a secure temporary file" >&2
      exit 5
    fi
    # Verify the region is still exactly what this plugin appended. The
    # read is by offset: content after the entry (other transactions) does
    # not affect it. If an external writer interleaved an append between
    # size capture of the add and its append, our entry sits at the END of
    # the recorded span instead of its start (POSTSIZE - TLEN) - try that
    # offset too before giving up, so undo is not permanently bricked for
    # the entry.
    dd if="$JF" bs=1 skip="$PRESIZE" count="$TLEN" of="$TMP" 2>/dev/null
    RSHA="$(sha256sum "$TMP" | cut -d" " -f1)"
    OFFSET="$PRESIZE"
    if [ "$RSHA" != "$ESHA" ]; then
      ALT=$((POSTSIZE - TLEN))
      if [ "$ALT" -gt "$PRESIZE" ]; then
        dd if="$JF" bs=1 skip="$ALT" count="$TLEN" of="$TMP" 2>/dev/null
        RSHA="$(sha256sum "$TMP" | cut -d" " -f1)"
        if [ "$RSHA" = "$ESHA" ]; then
          OFFSET="$ALT"
        fi
      fi
    fi
    if [ "$RSHA" != "$ESHA" ]; then
      echo "omarchledger: the journal region does not match the added transaction; refusing to undo" >&2
      exit 1
    fi
    # Build the same-length tombstone: comment lines only, padded to the
    # exact byte length so nothing outside the region moves.
    SHA8="$(printf "%s" "$ESHA" | cut -c1-8)"
    TOMB=""
    BUDGET=$TLEN
    HEAD="; undone by omarchledger $SHA8"
    if [ "$BUDGET" -gt $(( ${#HEAD} + 1 )) ]; then
      TOMB="$HEAD
"
      BUDGET=$(( BUDGET - ${#HEAD} - 1 ))
    fi
    if [ "$BUDGET" -ge 3 ]; then
      PAD="$(printf "%${BUDGET}s" "")"
      TOMB="$TOMB; ${PAD%???}
"
      BUDGET=0
    fi
    while [ "$BUDGET" -ge 2 ]; do
      TOMB="$TOMB;
"
      BUDGET=$(( BUDGET - 2 ))
    done
    if [ "$BUDGET" -eq 1 ]; then
      TOMB="$TOMB
"
    fi
    if [ "$(printf "%s" "$TOMB" | wc -c)" -ne "$TLEN" ]; then
      echo "omarchledger: internal error building the tombstone" >&2
      exit 5
    fi
    # Final verification immediately before the write: the build took a
    # moment, so re-read the region and confirm it is still the transaction
    # this undo was recorded for. Verify-then-write is now two adjacent
    # steps with nothing in between.
    dd if="$JF" bs=1 skip="$OFFSET" count="$TLEN" of="$TMP" 2>/dev/null
    RSHA2="$(sha256sum "$TMP" | cut -d" " -f1)"
    cleanup
    trap - EXIT INT TERM HUP
    if [ "$RSHA2" != "$ESHA" ]; then
      echo "omarchledger: the journal region changed while preparing the undo; refusing to undo" >&2
      exit 1
    fi
    # In-place same-length write: nothing outside the verified region is
    # touched, so no concurrent append can ever be affected.
    printf "%s" "$TOMB" | dd of="$JF" bs=1 seek="$OFFSET" conv=notrunc 2>/dev/null
    echo "UNDONE"
  ' 


  /* ---- entry building ---------------------------------------------------- */

  /*
    Journal lines are the injection boundary: a CR/LF inside any field would
    let pasted or prefilled content forge additional postings or whole
    transactions (hledger would happily balance-check them). Line separators
    can reach a single-line TextInput via clipboard paste, so every field is
    flattened here — the one choke point all journal writes pass through.
  */
  function flattenLine(s) {
    return String(s === undefined || s === null ? "" : s)
      .replace(/[\r\n\u2028\u2029]+/g, " ")
  }

  function buildEntry(date, description, comment, postings) {
    var entry = "\n" + flattenLine(date) + " " + flattenLine(description)
    var c = flattenLine(comment).trim()
    if (c !== "") entry += "  ; " + c
    entry += "\n"
    for (var i = 0; i < postings.length; i++) {
      var p = postings[i]
      var line = "    " + flattenLine(p.account)
      var a = flattenLine(p.amount).trim()
      if (a !== "") line += "  " + a
      entry += line + "\n"
    }
    return entry
  }

  /* ---- parsing ----------------------------------------------------------- */

  function regexEscape(s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  }

  function isNegativeAmount(s) {
    var str = String(s || "").trim()
    // hledger prints the minus either before the digits (£-69.00) or before
    // the commodity (-£69.00), depending on the journal's amount style.
    return str.indexOf("-") === 0 || /-[0-9]/.test(str)
  }

  /*
    Parse `hledger bs --flat` output. Rows use "||" as the column delimiter:
      - Section headers have text left of || and nothing right
      - Data rows have account left and amount right
      - Total rows have nothing left but amount right
      - "Net:" is the final summary row
      - The column-header row (before any section) carries the report date
  */
  function parseBsText(text) {
    var lines = String(text || "").split("\n")
    var sections = []
    var current = null
    var reportDate = ""

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line.indexOf("||") === -1) continue
      if (/^[\s=+\-]+$/.test(line)) continue

      var parts = line.split("||")
      if (parts.length < 2) continue

      var left = parts[0].trim()
      var right = parts[1].trim()

      if (left === "" && right !== "" && current === null && sections.length === 0) {
        reportDate = right
        continue
      }

      if (left.indexOf("Net:") !== -1 || left === "Net") {
        sections.push({ name: "Net", rows: [], total: right, isNegative: root.isNegativeAmount(right) })
        current = null
      } else if (right === "" && left !== "") {
        current = { name: left, rows: [], total: "", isNegative: false }
        sections.push(current)
      } else if (left === "" && right !== "") {
        if (current) current.total = right
      } else if (left !== "" && right !== "") {
        if (current) current.rows.push({ account: left, balance: right, isNegative: root.isNegativeAmount(right) })
      }
    }

    root.bsReportDate = reportDate
    return sections
  }

  /*
    Parse `hledger stats` output. Each line has the format "Key <pad> : value".
  */
  function parseStatsText(text) {
    var lines = String(text || "").split("\n")
    var entries = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var colonIdx = line.indexOf(" : ")
      if (colonIdx > 0) {
        var key = line.substring(0, colonIdx).trim()
        var value = line.substring(colonIdx + 3).trim()
        if (key) entries.push({ key: key, value: value || "—" })
      }
    }
    return entries
  }

  /*
    Parse `hledger print` output (journal format) and return the LAST
    transaction found — the most recent one matching the query:
      2026-08-12 * Supermarket
          expenses:groceries          £23.45
          assets:bank:checking
    The final posting may carry no amount (auto-balanced).
  */
  function parsePrint(text) {
    var lines = String(text || "").split("\n")
    var last = { found: false, date: "", description: "", comment: "", postings: [] }
    var out = null

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]

      if (!out) {
        var m = line.match(/^(\d{4}-\d{2}-\d{2}(?:=\d{4}-\d{2}-\d{2})?)\s+(?:[*!]\s+)?(.*)$/)
        if (m) {
          out = { found: true, date: m[1], description: "", comment: "", postings: [] }
          var rest = m[2]
          var ci = rest.indexOf(";")
          if (ci !== -1) {
            out.comment = rest.substring(ci + 1).trim()
            rest = rest.substring(0, ci).trim()
          }
          out.description = rest
        }
        continue
      }

      if (/^\s+\S/.test(line)) {
        var body = line
        var pc = body.indexOf(";")
        if (pc !== -1) body = body.substring(0, pc)
        body = body.replace(/\s+$/, "")
        if (!body.trim() || body.trim().charAt(0) === ";") continue
        var pm = body.match(/^\s+(.+?)(?:\s{2,}(.*))?$/)
        if (pm) out.postings.push({ account: pm[1].trim(), amount: pm[2] ? pm[2].trim() : "" })
      } else if (line.trim() === "") {
        // End of a transaction block: remember it and keep scanning for later
        // ones, so `print` output with several matches yields the most recent.
        if (out.postings.length > 0) last = out
        out = null
      }
    }

    if (out && out.postings.length > 0) last = out
    if (last.postings.length === 0) last.found = false
    return last
  }

  /* ---- processes ---------------------------------------------------------- */

  Process {
    id: resolveProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i]
          if (line.indexOf("BIN:") === 0) root.hledgerBin = line.substring(4)
          else if (line.indexOf("JF:") === 0) root.journalFile = line.substring(3)
          else if (line.indexOf("ERR:") === 0) root.resolveError = root.resolveErrorText(line.substring(4))
        }
        root.resolved = true
        if (root.resolveError === "") root.resolvedOk()
      }
    }
  }

  Process {
    id: accountsProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        var list = raw.split("\n").filter(function(a) { return a.trim() !== "" })
        if (list.length > 0) root.accountList = list
        root.busyAccounts = false
        root.accountsReady()
      }
    }
    onExited: function(code) {
      root.busyAccounts = false
    }
  }

  Process {
    id: descriptionsProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        var list = raw.split("\n").filter(function(d) { return d.trim() !== "" })
        if (list.length > 0) root.descriptionList = list
        root.descriptionsReady()
      }
    }
  }

  Process {
    id: commoditiesProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        var list = raw.split("\n").filter(function(c) { return c.trim() !== "" })
        if (list.length > 0) root.commodityList = list
      }
    }
  }

  Process {
    id: bsProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.bsSections = root.parseBsText(String(text || ""))
        root.busyBs = false
        root.balanceReady()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err !== "") root.bsError = err
      }
    }
    onExited: function(code) {
      if (code !== 0 && root.bsError === "") root.bsError = "hledger bs failed (exit " + code + ")"
      root.busyBs = false
    }
  }

  Process {
    id: statsProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.statsEntries = root.parseStatsText(String(text || ""))
        root.busyStats = false
        root.statsReady()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err !== "") root.statsError = err
      }
    }
    onExited: function(code) {
      if (code !== 0 && root.statsError === "") root.statsError = "hledger stats failed (exit " + code + ")"
      root.busyStats = false
    }
  }

  Process {
    id: similarProc
    stdinEnabled: true
    property string pendingQuery: ""
    onStarted: similarProc.write(similarProc.pendingQuery)

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = root.parsePrint(String(text || ""))
        root.similarFound = parsed.found
        root.similarDate = parsed.date
        root.similarDescription = parsed.description
        root.similarComment = parsed.comment
        root.similarPostings = parsed.postings
        root.busySimilar = false
        root.similarReady(parsed.found)
      }
    }
    onExited: function(code) {
      root.busySimilar = false
    }
  }

  Process {
    id: addProc
    stdinEnabled: true
    property string pendingEntry: ""
    onStarted: addProc.write(addProc.pendingEntry)

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].indexOf("APPENDED:") === 0) {
            var parts = lines[i].substring(9).split(":")
            root.preAddSize = parseInt(parts[0], 10)
            root.postAddSize = parts.length > 1 ? parseInt(parts[1], 10) : -1
            root.entrySha256 = parts.length > 2 ? parts[2] : ""
            root.entryLen = parts.length > 3 ? parseInt(parts[3], 10) : -1
            root.canUndo = !isNaN(root.preAddSize) && root.preAddSize >= 0
              && !isNaN(root.postAddSize) && root.postAddSize >= 0
              && root.entrySha256 !== "" && root.entryLen > 0
          }
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err !== "") root.addMessage = err
      }
    }
    onExited: function(code) {
      root.busyAdd = false
      root.addOk = code === 0
      if (code === 0) {
        if (root.addMessage === "") root.addMessage = "Transaction added."
      } else if (root.addMessage === "") {
        root.addMessage = "hledger rejected the transaction (exit " + code + ")."
      }
      root.addFinished(code === 0)
    }
  }

  Process {
    id: undoProc

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err !== "") root.addMessage = err
      }
    }
    onExited: function(code) {
      root.busyAdd = false
      if (code === 0) {
        root.canUndo = false
        root.preAddSize = -1
        root.postAddSize = -1
        root.entrySha256 = ""
        root.entryLen = -1
        root.addOk = true
        root.addMessage = "Transaction undone (commented out)."
      }
      root.undoFinished(code === 0)
    }
  }
}
