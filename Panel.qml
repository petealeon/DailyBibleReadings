import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "LectionaryCalendar.js" as Cal

Panel {
  id: root
  moduleName: "petealeon.dailybiblereadings"
  ipcTarget: "petealeon.dailybiblereadings"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.ensureAll()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.ensureAll()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function") {
      root.bar.setCenterHoverRevealSuppressed(value)
      return
    }
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ------------------------------------------------------------ settings

  readonly property int refreshMinutes: Math.max(5, parseInt(setting("refreshMinutes", 30), 10) || 30)
  readonly property bool reminderEnabled: setting("reminderEnabled", true) !== false
  readonly property int reminderHour: Math.min(23, Math.max(0, parseInt(setting("reminderHour", 8), 10)))
  // Optional helper that fetches a single day's readings text from
  // bible.usccb.org (days outside the ~10-day RSS feed window). Disabled by
  // default; set fetchToolPath to a helper that prints the widget's JSON
  // schema with `--json` to backfill out-of-window days locally.
  readonly property string fetchToolPath: String(setting("fetchToolPath", ""))

  // --------------------------------------------------------------- state

  property string todayK: Model.todayKey() // updated by the rollover timer

  // Pill: simple cross outline.
  readonly property string label: "\uDB83\uDCF6"

  // Per-day interaction state: green rings + the simplified daily reminder.
  property var activityData: Model.emptyActivity()
  property bool activityLoaded: false

  // Plain JS objects don't emit change notifications, so every mutation
  // bumps dataRevision and downstream bindings reference it explicitly.
  property int dataRevision: 0

  property var readingsByDate: ({})  // dateKey -> parsed USCCB RSS day
  property var readingsStatus: ({})  // dateKey -> "ok" | "error" ("" = unknown)
  property bool readingsFeedFetched: false
  property string viewingKey: Model.todayKey()
  property int selectedSection: 0

  // Days whose text was already requested from the fetch tool (one attempt per
  // key unless forced), plus which keys are in flight right now.
  property var readingsFetchAttempted: ({})
  property var readingsFetching: ({})  // dateKey -> true while a fetch runs

  // Sections grouped into display tabs (acclamation folded into the Gospel).
  readonly property var readingTabs: currentReadings ? Model.buildReadingTabs(currentReadings.sections) : []
  readonly property int activeTab: Math.max(0, Math.min(selectedSection, readingTabs.length - 1))

  onSelectedSectionChanged: Qt.callLater(recomputeWrapped)
  onViewingKeyChanged: {
    selectedSection = 0
    bibleScroll.contentY = 0
    Qt.callLater(recomputeWrapped)
  }
  onDataRevisionChanged: Qt.callLater(recomputeWrapped)
  readonly property var currentReadings: {
    void root.dataRevision
    return root.readingsByDate[root.viewingKey] || null
  }
  readonly property string readingsPhase: {
    void root.dataRevision
    return root.readingsStatus[root.viewingKey] || ""
  }

  // The fetch tool can backfill text for any day in the calendar range, so a
  // missing day is only terminal when the tool itself is unavailable.
  readonly property bool readingsFetchable: {
    void root.dataRevision
    return fetchToolPath !== ""
  }
  readonly property bool readingsInFlight: {
    void root.dataRevision
    return root.readingsFetching[root.viewingKey] === true
  }

  // Whole-feed podcast map: one fetch covers every day the feed reaches.
  property var podcastByDate: ({})
  property bool podcastFeedFetched: false
  readonly property var currentPodcast: {
    void root.dataRevision
    return root.podcastByDate[root.viewingKey] || null
  }
  readonly property string podcastPhase: {
    void root.dataRevision
    if (podcastProc.running && !root.podcastByDate[root.viewingKey]) return "loading"
    if (root.podcastFeedFetched && !root.podcastByDate[root.viewingKey]) return "error"
    return ""
  }

  // Bundled liturgical calendar entry for the viewed day.
  readonly property var dayMeta: Cal.get(viewingKey)
  readonly property string dayTitle: (currentReadings && currentReadings.title) ||
    (dayMeta ? dayMeta.title : Model.longDate(viewingKey))

  // Header title. Ferias read "[Weekday] of the Nth week of ..."; the weekday
  // already appears in the date row below ("Thursday 10 September"), so drop
  // the redundant prefix. Sundays and other titles are left untouched.
  readonly property string headerTitle: {
    var m = dayTitle.match(/^(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\s+of\s+the\s+(.+)$/i)
    return m ? m[2] : dayTitle
  }

  // Saint shown on the date row only when the title does not already name it.
  readonly property string headerSaint: {
    var s = dayMeta && dayMeta.saint ? dayMeta.saint.trim() : ""
    if (s === "") return ""
    if (dayTitle.toLocaleLowerCase().indexOf(s.toLocaleLowerCase()) === -1) return s
    return ""
  }

  // Playback (mpv driven over its JSON IPC socket via socat).
  property bool playing: false
  property bool paused: false
  property string playingKey: "" // date key of the episode loaded in mpv
  property int elapsedSeconds: 0
  property int liveDurationSeconds: 0
  property int progressFailures: 0
  readonly property real playbackRatio: liveDurationSeconds > 0
    ? Math.min(1, elapsedSeconds / liveDurationSeconds) : 0

  // Right-click pill notification (quote-stripped so bar.run quoting holds).
  readonly property string notificationText: {
    var parts = []
    var meta = Cal.get(root.todayK)
    parts.push(meta ? meta.title : Model.longDate(root.todayK))
    if (currentReadings && currentReadings.sections) {
      var cites = []
      for (var i = 0; i < currentReadings.sections.length; i++)
        if (currentReadings.sections[i].citation) cites.push(currentReadings.sections[i].citation)
      if (cites.length) parts.push(cites.join(" \u00B7 "))
    }
    return String(parts.join(" \u2014 ")).replace(/[$`"\\]/g, "'")
  }

  // Contrast target: the keyboard-popup card paints Color.popups.background.
  readonly property color surfaceBackground: Color.popups.background

  // 0..1: 1 guarantees liturgical text clears WCAG AA on this surface; lower
  // values interpolate back toward the raw tint (richer colour, weaker
  // guarantee). Dark themes pass untouched either way.
  readonly property real tintLevel: parseFloat(setting("tintLevel", 1.0) || 1.0)

  // Theme-safe variant of the header chip's accent — the pill fill stays a
  // translucent wash of the raw tint; the label uses this so it stays legible
  // on light surfaces.
  readonly property color liturgicalTextColor: dayMeta
    ? Model.liturgicalTintFor(surfaceBackground, Model.liturgicalColourHex(dayMeta.colour), tintLevel) : "transparent"

  // Fixed-height podcast transport bar pinned below the scrolling content.
  readonly property real playerBarHeight: Style.space(38) + Style.spacing.hairline
  readonly property string playerBarContext: Model.longDate(viewingKey).toUpperCase()

  // ---------------------------------------------------------------- utils

  function ensureAll() {
    ensureReadings(false)
    ensurePodcast(false)
  }

  function refreshAll() {
    ensureReadings(true)
    ensurePodcast(true)
    // Let failed per-day backfills retry on the next manual refresh.
    readingsFetchAttempted = {}
    readingsFetching = {}
  }

  // Cache round-trips through tiny bash helpers; payloads travel as argv so
  // unicode scripture text never touches shell quoting.
  function cacheWrite(fileName, json) {
    var target = Quickshell.env("HOME") + "/.local/state/omarchy/petealeon.dailybiblereadings/cache/" + fileName
    cacheWriteProc.command = ["bash", "-c",
      "mkdir -p \"$(dirname \"$2\")\" && printf %s \"$1\" > \"$2\"", "dailybiblereadings-cache", json, target]
    cacheWriteProc.running = true
  }

  function cacheRead(purpose, fileName) {
    if (!fileName) return
    cacheReadProc.purpose = purpose
    cacheReadProc.command = ["bash", "-c",
      "cat \"$HOME/.local/state/omarchy/petealeon.dailybiblereadings/cache/" + fileName + "\" 2>/dev/null"]
    cacheReadProc.running = true
  }

  Process {
    id: cacheWriteProc
  }

  Process {
    id: cacheReadProc
    property string purpose: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyCache(cacheReadProc.purpose, String(text || "").trim())
    }
  }

  function applyCache(purpose, raw) {
    if (!raw) return
    var data = null
    try {
      data = JSON.parse(raw)
    } catch (e) {
      return
    }
    if (!data) return
    var kind = purpose.split(":")[0]
    var key = purpose.split(":")[1]
    if (kind === "readings" && key && !readingsByDate[key]) {
      if (data.readings && data.readings.ok) {
        readingsByDate[key] = data.readings
        readingsStatus[key] = "ok"
      }
    } else if (kind === "podcastFeed" && !podcastFeedFetched) {
      if (data.feed) {
        podcastByDate = data.feed
        podcastFeedFetched = true
      }
    }
    dataRevision++
  }

  // -------------------------------------------------------------- readings

  // One RSS fetch populates the whole ~10-day window; per-day caches keep it
  // available offline afterwards.
  function ensureReadings(force) {
    if (!force && readingsFeedFetched) return
    if (readingsProc.running) return
    readingsProc.running = true
  }

  Process {
    id: readingsProc
    // Cap the feed at 2 MiB (real size ~57 KB): reject anything larger rather
    // than buffering an unbounded response for parsing.
    command: ["bash", "-c",
      "set -o pipefail; cap=2097152; d=$(curl -fsSL --max-time 12 \"$1\" | head -c $((cap+1))); "
      + "rc=$?; [ $rc -eq 0 ] && [ ${#d} -le $cap ] || exit 63; printf '%s' \"$d\"",
      "dailybiblereadings-rss", Model.usccbRss()]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var feed = Model.parseUsccbRss(String(text || ""))
        var count = 0
        for (var key in feed.byDate) {
          root.readingsByDate[key] = feed.byDate[key]
          root.readingsStatus[key] = "ok"
          root.cacheWrite("readings-" + key + ".json", JSON.stringify({ readings: feed.byDate[key] }))
          count++
        }
        readingsFeedFetched = count > 0
        if (!readingsFeedFetched) {
          readingsStatus[root.viewingKey] = "error"
          root.cacheRead("readings:" + root.viewingKey, "readings-" + root.viewingKey + ".json")
        }
        root.dataRevision++
      }
    }
    onExited: root.dataRevision++
  }

  // Backfill one day's readings text via the fetch tool when the RSS feed
  // window cannot reach it (podcast episodes run well past today). The tool
  // prints the same widget schema the feed parser produces.
  function ensureReadingsForKey(key, force) {
    if (!key) return
    if (readingsByDate[key] || readingsStatus[key] === "ok") return
    if (!force && readingsFetchAttempted[key]) return
    if (readingsFetching[key] || key === readingsFetchKey) return
    fetchReadingsKey = key
    readingsFetchAttempted[key] = true
    readingsFetching[key] = true
    fetchReadingsProc.command = ["bash", "-c",
      "set -o pipefail; cap=2097152; d=$(\"$1\" --json \"$2\" | head -c $((cap+1))); "
      + "rc=$?; [ $rc -eq 0 ] && [ ${#d} -le $cap ] || exit 63; printf '%s' \"$d\"",
      "dailybiblereadings-fetch", fetchToolPath, key]
    fetchReadingsProc.running = true
    root.dataRevision++
  }

  property string fetchReadingsKey: ""
  property string fetchReadingsLog: ""

  Process {
    id: fetchReadingsProc
    onExited: {
      root.readingsFetching[root.fetchReadingsKey] = false
      root.fetchReadingsKey = ""
      root.dataRevision++
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var key = root.fetchReadingsKey
        if (!key) return
        var raw = String(text || "").trim()
        var data = null
        try { data = JSON.parse(raw) } catch (e) { data = null }
        if (data && data.readings && data.readings.ok) {
          root.readingsByDate[key] = data.readings
          root.readingsStatus[key] = "ok"
          root.cacheWrite("readings-" + key + ".json", JSON.stringify({ readings: data.readings }))
        } else {
          root.readingsStatus[key] = "error"
          root.fetchReadingsLog = (key + ": " + raw.slice(0, 120)) || ""
          root.cacheRead("readings:" + key, "readings-" + key + ".json")
        }
        root.dataRevision++
      }
    }
  }

  // --------------------------------------------------------------- podcast

  function ensurePodcast(force) {
    if (!force && podcastFeedFetched) return
    if (podcastProc.running) return
    podcastProc.running = true
  }

  // The SoundCloud feed carries every episode; one fetch maps them all by date.
  Process {
    id: podcastProc
    // Cap the feed at 8 MiB (real size ~0.5 MB and grows with episodes): reject
    // anything larger rather than buffering an unbounded response for parsing.
    command: ["bash", "-c",
      "set -o pipefail; cap=8388608; d=$(curl -fsS --max-time 12 \"$1\" | head -c $((cap+1))); "
      + "rc=$?; [ $rc -eq 0 ] && [ ${#d} -le $cap ] || exit 63; printf '%s' \"$d\"",
      "dailybiblereadings-podcast", Model.podcastRss()]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var feed = Model.matchAllPodcasts(String(text || ""))
        if (feed) {
          root.podcastByDate = feed
          root.podcastFeedFetched = true
          root.cacheWrite("podcast-feed.json", JSON.stringify({ feed: feed }))
        } else {
          root.cacheRead("podcastFeed", "podcast-feed.json")
        }
        root.dataRevision++
      }
    }
  }

  function stopPlayback() {
    mpvCommand({ command: ["quit"] })
    playing = false
    paused = false
    elapsedSeconds = 0
    playingKey = ""
  }

  // Talk to mpv over its JSON IPC socket; socat pipes one request per call.
  readonly property string mpvSocket: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/dailybiblereadings-mpv.sock"

  function mpvCommand(json) {
    mpvCmdProc.command = ["bash", "-c",
      "printf '%s\\n' \"$1\" | timeout 3 socat - UNIX-CONNECT:\"$2\" >/dev/null 2>&1",
      "dailybiblereadings-mpv-cmd", JSON.stringify(json), mpvSocket]
    mpvCmdProc.running = true
  }

  Process {
    id: mpvCmdProc
  }

  function togglePlayback() {
    var pod = currentPodcast
    if (!pod || !pod.url) return
    if (!playing || playingKey !== viewingKey) {
      startPlayback(pod.url) // starts, or switches to, the selected day's episode
    } else {
      var pausing = !paused
      mpvCommand({ command: ["set_property", "pause", pausing] })
      paused = pausing
    }
  }

  function seekToStart() {
    if (!playing || playingKey !== viewingKey) return
    mpvCommand({ command: ["set_property", "time-pos", 0] })
    elapsedSeconds = 0
  }

  function seekBack10() {
    if (!playing || playingKey !== viewingKey) return
    mpvCommand({ command: ["seek", -10] })
    elapsedSeconds = Math.max(0, elapsedSeconds - 10) // socket query corrects shortly
  }

  function seekToRatio(ratio) {
    if (!playing || playingKey !== viewingKey || displayTotalSeconds <= 0) return
    var target = Math.max(0, Math.min(displayTotalSeconds, Math.round(ratio * displayTotalSeconds)))
    mpvCommand({ command: ["set_property", "time-pos", target] })
    elapsedSeconds = target
  }

  // Stream the episode to the user's Downloads folder.
  property bool downloading: false

  Process {
    id: downloadProc
    onExited: root.downloading = false
  }

  function downloadPodcast() {
    var pod = currentPodcast
    if (!pod || !pod.url || downloading) return
    downloading = true
    downloadProc.command = ["bash", "-c",
      "set -o pipefail; dir=\"$(xdg-user-dir DOWNLOAD 2>/dev/null || echo \"$HOME/Downloads\")\"; "
      + "mkdir -p \"$dir\"; file=\"$dir/Daily-Mass-Reading-$2.mp3\"; "
      + "tmp=$(mktemp \"$dir/.Daily-Mass-Reading-$2.mp3.part.XXXXXX\") || tmp=\"\"; "
      + "if [ -n \"$tmp\" ] && curl -fsSL --max-time 300 --max-filesize 104857600 \"$1\" | head -c 104857600 > \"$tmp\" "
      + "&& [ -s \"$tmp\" ]; then mv -T \"$tmp\" \"$file\"; "
      + "omarchy-notification-send \"Podcast saved: $file\"; "
      + "else [ -n \"$tmp\" ] && rm -f \"$tmp\"; omarchy-notification-send \"Podcast download failed\"; fi",
      "dailybiblereadings-dl", pod.url, viewingKey]
    downloadProc.running = true
  }

  readonly property int displayTotalSeconds: liveDurationSeconds > 0
    ? liveDurationSeconds : (currentPodcast ? currentPodcast.durationSeconds : 0)

  property string pendingUrl: ""

  function startPlayback(url) {
    pendingUrl = url
    elapsedSeconds = 0
    liveDurationSeconds = currentPodcast ? currentPodcast.durationSeconds : 0
    progressFailures = 0
    paused = false
    playingKey = viewingKey
    markDayDone(viewingKey)
    if (playing) {
      // An episode is already rolling: hot-swap the stream in place rather
      // than respawning mpv (the old process would hold the socket and the
      // respawned state would race its exit handler).
      mpvCommand({ command: ["loadfile", url] })
      mpvCommand({ command: ["set_property", "pause", false] })
      return
    }
    playing = true
    mpvProc.command = ["bash", "-c",
      "rm -f \"$1\"; exec mpv --no-video --no-terminal --really-quiet --keep-open=no --input-ipc-server=\"$1\" --title=DailyBibleReadings \"$2\"",
      "dailybiblereadings-mpv", mpvSocket, pendingUrl]
    mpvProc.running = true
    console.log("[dailybiblereadings] mpv spawn issued")
  }

  Process {
    id: mpvProc
    onExited: resetPlayback()
  }

  function resetPlayback() {
    playing = false
    paused = false
    elapsedSeconds = 0
    liveDurationSeconds = 0
    progressFailures = 0
    pendingUrl = ""
    playingKey = ""
  }

  // Real position/duration from the socket beats wall-clock estimates.
  // Runs while paused too, so the readout stays truthful.
  Timer {
    interval: 1000
    running: root.playing
    repeat: true
    triggeredOnStart: true
    onTriggered: root.queryProgress()
  }

  function queryProgress() {
    // mpv property names are dash-form: playback_time is simply not found.
    mpvQueryProc.command = ["bash", "-c",
      "printf '%s\\n%s\\n' '{\"command\":[\"get_property\",\"playback-time\"],\"request_id\":1}' '{\"command\":[\"get_property\",\"duration\"],\"request_id\":2}' | timeout 3 socat - UNIX-CONNECT:\"$1\" 2>/dev/null",
      "dailybiblereadings-mpv-q", mpvSocket]
    mpvQueryProc.running = true
  }

  Process {
    id: mpvQueryProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyProgress(String(text || ""))
    }
  }

  function applyProgress(raw) {
    if (!raw.trim()) {
      // Socket unreachable: either a hiccup or mpv died unreaped.
      progressFailures++
      if (progressFailures >= 2) resetPlayback()
      return
    }
    // request_id correlation: a buffering stream answers duration but not
    // position, so order-based parsing would misread duration as position.
    var pos = null, dur = null
    var lines = raw.split("\n")
    for (var i = 0; i < lines.length; i++) {
      try {
        var msg = JSON.parse(lines[i])
        if (!msg || msg.error !== "success" || msg.data === undefined) continue
        if (msg.request_id === 1) pos = msg.data
        else if (msg.request_id === 2) dur = msg.data
      } catch (e) {}
    }
    progressFailures = 0
    if (dur > 0) liveDurationSeconds = Math.round(dur)
    if (pos !== null && pos >= 0) elapsedSeconds = Math.round(pos)
  }

  // ------------------------------------------------------------ activity

  property FileView activityFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/petealeon.dailybiblereadings/activity.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.activityData = Model.parseActivityFile(text())
      root.activityLoaded = true
    }
    onFileChanged: reload()
    onLoadFailed: root.activityLoaded = true
  }

  function setActivity(mutate) {
    var next = JSON.parse(JSON.stringify(activityData))
    mutate(next)
    activityData = next
    persistActivity(next)
  }

  function isDone(key) {
    return activityData.done[key] === true
  }

  function markDayDone(key) {
    if (isDone(key)) return
    setActivity(function(a) { a.done[key] = true })
  }

  // A day counts as engaged once its podcast has been played or every one of
  // its reading tabs has been opened.
  function noteTabViewed(label) {
    var key = viewingKey
    var seen = activityData.viewedTabs[key] || []
    if (seen.indexOf(label) >= 0) return
    var next = seen.concat([label])
    var allSeen = readingTabs.length > 0
    for (var i = 0; i < readingTabs.length; i++)
      if (next.indexOf(readingTabs[i].label) < 0) allSeen = false
    setActivity(function(a) {
      a.viewedTabs[key] = next
      if (allSeen) a.done[key] = true
    })
  }

  function persistActivity(state) {
    var target = Quickshell.env("HOME") + "/.local/state/omarchy/petealeon.dailybiblereadings/activity.json"
    activitySaveProc.command = ["bash", "-c",
      "mkdir -p \"$(dirname \"$2\")\" && printf %s \"$1\" > \"$2\"", "dailybiblereadings-activity", JSON.stringify(state), target]
    activitySaveProc.running = true
  }

  Process {
    id: activitySaveProc
  }

  // ------------------------------------------------------------- reminders

  Timer {
    interval: 60000
    running: root.reminderEnabled
    repeat: true
    triggeredOnStart: false
    onTriggered: root.checkReminder()
  }

  function checkReminder() {
    if (!reminderEnabled || !activityLoaded) return
    var now = new Date()
    if (now.getHours() < reminderHour) return
    if (isDone(todayK)) return
    if (activityData.lastNotified === todayK) return
    var meta = Cal.get(todayK)
    var msg = "Today's readings are waiting"
    if (meta && meta.title) msg += " \u2014 " + meta.title
    sendNotification(msg)
    setActivity(function(a) { a.lastNotified = todayK })
  }

  function sendNotification(message) {
    if (!bar) return
    var safe = String(message).replace(/[$`"\\]/g, "'")
    bar.run("omarchy-notification-send \"" + safe + "\"")
  }

  // Copy readings to the clipboard, with brief feedback.
  Process {
    id: copyProc
  }

  property bool readingsCopied: false

  Timer {
    id: copyFeedbackTimer
    interval: 1500
    onTriggered: root.readingsCopied = false
  }

  function copyReadings() {
    var group = readingTabs[activeTab]
    if (!group || !currentReadings) return
    copyProc.command = ["wl-copy", Model.readingsToText(currentReadings.title, group.sections)]
    copyProc.running = true
    readingsCopied = true
    copyFeedbackTimer.restart()
  }

  // ------------------------------------------------------- day navigation

  function selectDay(key) {
    if (!key || key === viewingKey) return
    if (key < Cal.minDate() || key > Cal.maxDate()) return
    viewingKey = key
    ensurePodcast(false)
    followPlayback()
    // Text for days outside the ~10-day feed window comes from the fetch tool.
    if (!readingsByDate[key]) ensureReadingsForKey(key, false)
  }

  // Playback follows the selected day: a live episode hot-swaps to the new
  // day's podcast; a paused one (or a day whose episode is not loaded yet)
  // stops, so Play starts fresh on whatever day is selected.
  function followPlayback() {
    if (!playing || playingKey === viewingKey) return
    var pod = currentPodcast
    if (!paused && pod && pod.url) startPlayback(pod.url)
    else stopPlayback()
  }

  // Bitmask of the day's available content: 2 = reading text, 1 = podcast
  // episode. Liturgical info exists for every day in the bundled range, so
  // this governs what a calendar click can deliver: text+audio, audio only,
  // or liturgy plus an "open in browser" affordance.
  function dayContentKind(key) {
    var kind = 0
    if (readingsByDate[key]) kind += 2
    if (podcastByDate[key]) kind += 1
    return kind
  }

  // Open the day's public readings page. History and scheduled days live
  // outside the ~10-day feed window, so the browser is the honest way to
  // read them.
  function openDayReadings(key) {
    var url = Model.usccbDayUrl(key)
    if (!Qt.openUrlExternally(url) && root.bar)
      root.bar.run("xdg-open \"" + url + "\"")
  }

  // Calendar month being viewed.
  property int calMonth: new Date().getMonth()
  property int calYear: new Date().getFullYear()
  readonly property int calMonthIndex: calYear * 12 + calMonth
  readonly property int calMinIndex: {
    var p = Cal.minDate().split("-")
    return (parseInt(p[0], 10)) * 12 + (parseInt(p[1], 10) - 1)
  }
  readonly property int calMaxIndex: {
    var p = Cal.maxDate().split("-")
    return (parseInt(p[0], 10)) * 12 + (parseInt(p[1], 10) - 1)
  }

  function setCalMonthIndex(idx) {
    idx = Math.max(calMinIndex, Math.min(calMaxIndex, idx))
    calYear = Math.floor(idx / 12)
    calMonth = idx % 12
  }

  function setCalMonthFromKey(key) {
    var p = String(key).split("-")
    setCalMonthIndex((parseInt(p[0], 10)) * 12 + (parseInt(p[1], 10) - 1))
  }

  // ------------------------------------------------------- refresh cycles

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshAll()
  }

  // Maintained by the rollover timer — a plain binding would freeze at the
  // value from shell startup and never notice midnight passing.
  property string sessionDay: Model.todayKey()

  Timer {
    interval: 10000
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: {
      var now = Model.todayKey()
      if (root.todayK !== now) {
        root.todayK = now
        root.sessionDay = now
        root.viewingKey = now
        root.selectedSection = 0
        root.setCalMonthFromKey(now)
        root.refreshAll()
      }
    }
  }

  Timer {
    interval: 1500
    running: root.opened
    triggeredOnStart: false
    onTriggered: activityFile.reload()
  }

  Component.onCompleted: {
    activityFile.reload()
    Qt.callLater(checkReminder)
    Qt.callLater(recomputeWrapped)
  }

  function debugText() {
    return JSON.stringify({
      viewing: viewingKey,
      today: todayK,
      dayTitle: root.dayTitle,
      readingsKeys: Object.keys(readingsByDate),
      readingsPhase: root.readingsPhase,
      podcastDays: Object.keys(podcastByDate).length,
      podcastProcRunning: podcastProc.running,
      playing: playing,
      paused: paused,
      playingKey: playingKey,
      elapsed: elapsedSeconds,
      duration: liveDurationSeconds,
      ratio: Math.round(root.playbackRatio * 1000) / 1000
    })
  }

  // ================================================================= UI

  component Hairline: Rectangle {
    width: parent.width
    height: Style.spacing.hairline
    color: root.bar.foreground
    opacity: 0.12
  }

  component NavButton: Rectangle {
    id: navBtn
    required property string glyph
    required property bool active
    property string tooltipText: ""
    signal activated()
    width: Style.space(22)
    height: Style.space(22)
    radius: Style.cornerRadius
    color: navBtn.active && navArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

    Text {
      anchors.centerIn: parent
      text: navBtn.glyph
      color: navBtn.active ? root.bar.foreground : Qt.darker(root.bar.foreground, 2)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: navArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: navBtn.active
      cursorShape: navBtn.active ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: navBtn.activated()
    }

    PanelToolTip {
      visible: navBtn.tooltipText !== "" && navArea.containsMouse
      text: navBtn.tooltipText
      fontFamily: root.bar.fontFamily
    }
  }

  component TransportButton: Rectangle {
    id: tbtn
    required property string glyph
    property string tooltipText: ""
    signal activated()
    width: Style.space(30)
    height: Style.space(30)
    radius: height / 2
    color: tbtn.enabled && tArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : (tbtn.enabled ? Style.normalFillFor(root.bar.foreground, Color.accent) : "transparent")

    Text {
      anchors.centerIn: parent
      text: tbtn.glyph
      color: tbtn.enabled ? root.bar.foreground : Qt.darker(root.bar.foreground, 2)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.iconLarge
    }

    MouseArea {
      id: tArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: tbtn.enabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: tbtn.activated()
    }

    PanelToolTip {
      visible: tbtn.tooltipText !== "" && tArea.containsMouse
      text: tbtn.tooltipText
      fontFamily: root.bar.fontFamily
    }
  }

  // One credits row: dim prefix, clickable source link, dim suffix.
  component CreditLine: Row {
    id: creditLine
    required property string prefix
    required property string linkText
    required property string url
    required property string suffix
    spacing: 0

    Text {
      text: creditLine.prefix
      color: Qt.darker(root.bar.foreground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      id: creditLink
      text: creditLine.linkText
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.underline: creditLinkArea.containsMouse

      MouseArea {
        id: creditLinkArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          if (!Qt.openUrlExternally(creditLine.url) && root.bar)
            root.bar.run("xdg-open \"" + creditLine.url + "\"")
        }
      }
    }

    Text {
      visible: creditLine.suffix !== ""
      text: creditLine.suffix
      color: Qt.darker(root.bar.foreground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(500))
    contentHeight: panel.fittedContentHeight(bibleColumn.implicitHeight + root.playerBarHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onReturnRequested: root.selectDay(root.todayK)
      onMoveRequested: function(dx, dy) {
        if (dx !== 0 && root.readingTabs.length > 1) {
          var next = root.activeTab + dx
          if (next >= 0 && next < root.readingTabs.length) {
            root.selectedSection = next
            root.noteTabViewed(root.readingTabs[next].label)
          }
          return
        }
        if (dy !== 0) {
          bibleScroll.contentY = Math.max(0, Math.min(bibleScroll.contentHeight - bibleScroll.height,
            bibleScroll.contentY + dy * Style.space(40)))
        }
      }

      Column {
        id: contentStack
        anchors.fill: parent

      Flickable {
        id: bibleScroll
        width: parent.width
        height: Math.max(0, parent.height - root.playerBarHeight)
        contentWidth: width
        contentHeight: bibleColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: bibleColumn
          width: bibleScroll.width
          spacing: Style.space(10)
          onWidthChanged: Qt.callLater(recomputeWrapped)

          // ---- Month calendar: liturgical colours, done rings, day picker.
          Column {
            id: calBlock
            width: parent.width
            spacing: Style.space(2)

            readonly property int firstWeekday: new Date(calYear, calMonth, 1).getDay()
            readonly property int daysInMonth: new Date(calYear, calMonth + 1, 0).getDate()
            readonly property real cellWidth: (width - Style.space(24)) / 7

            Item {
              width: parent.width
              height: Style.space(18)

              NavButton {
                glyph: "<"
                active: root.calMonthIndex > root.calMinIndex
                tooltipText: "Previous month"
                onActivated: root.setCalMonthIndex(root.calMonthIndex - 1)
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                anchors.centerIn: parent
                text: (Model.MONTHS[root.calMonth] + " " + root.calYear).toUpperCase()
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
              }

              NavButton {
                glyph: ">"
                active: root.calMonthIndex < root.calMaxIndex
                tooltipText: "Next month"
                onActivated: root.setCalMonthIndex(root.calMonthIndex + 1)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
              }

              Row {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(46)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                Row {
                  spacing: Style.space(3)
                  Text {
                    text: "\uDB81\uDC0A"
                    color: Qt.darker(root.bar.foreground, 1.2)
                    opacity: 0.8
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    text: "Podcast only"
                    color: Qt.darker(root.bar.foreground, 1.5)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            Item {
              x: Style.space(12)
              width: parent.width - Style.space(24)
              height: (numRows + 1) * Style.space(24)

              readonly property int numRows: Math.ceil((calBlock.firstWeekday + calBlock.daysInMonth) / 7)

              Repeater {
                model: 7
                Text {
                  required property int index
                  x: index * calBlock.cellWidth
                  y: 0
                  width: calBlock.cellWidth
                  height: Style.space(24)
                  verticalAlignment: Text.AlignVCenter
                  horizontalAlignment: Text.AlignHCenter
                  text: ["S", "M", "T", "W", "T", "F", "S"][index]
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Repeater {
                model: calBlock.firstWeekday + calBlock.daysInMonth

                Item {
                  id: dayCell
                  required property int index
                  x: (index % 7) * calBlock.cellWidth
                  y: (Math.floor(index / 7) + 1) * Style.space(24)
                  width: calBlock.cellWidth
                  height: Style.space(24)

                  readonly property int dayNumber: index + 1 - calBlock.firstWeekday
                  readonly property string dateKey: dayNumber >= 1
                    ? root.calYear + "-" + Model.pad2(root.calMonth + 1) + "-" + Model.pad2(dayNumber) : ""
                  readonly property var meta: dayNumber >= 1 ? Cal.get(dateKey) : null
                  readonly property bool isToday: dateKey === root.todayK
                  readonly property bool isSelected: dateKey === root.viewingKey
                  readonly property bool isDone: dateKey !== "" && root.isDone(dateKey)
                  readonly property int contentKind: dateKey !== "" ? root.dayContentKind(dateKey) : 0
                  readonly property bool hasContent: dayCell.contentKind > 0
                  readonly property color dayTint: meta
                    ? Model.liturgicalTintFor(root.surfaceBackground, Model.liturgicalColourHex(meta.colour), root.tintLevel)
                    : root.bar.foreground

                  visible: dayNumber >= 1

                  Rectangle {
                    anchors.fill: parent
                    anchors.margins: 0
                    radius: Style.cornerRadius
                    color: dayCell.isSelected ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                      : (dayCell.hasContent && dayArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent")
                  }

                  Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 2
                    radius: 1
                    visible: dayCell.isDone
                    color: Qt.alpha(Model.liturgicalTintFor(root.surfaceBackground, "#6f996f", root.tintLevel), 0.9)
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: dayCell.dayNumber >= 1
                    text: dayCell.dayNumber >= 1 ? dayCell.dayNumber : ""
                    color: dayCell.dayTint
                    opacity: dayCell.hasContent ? 1 : 0.4
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: dayCell.isToday || dayCell.isSelected
                  }

                  Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: parent.height - Style.space(10)
                    spacing: Style.space(2)
                    height: Style.space(11)

                    Text {
                      visible: dayCell.contentKind === 1 && !dayCell.isDone && !dayCell.isToday
                      text: "\uDB81\uDC0A"
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      opacity: 0.8
                    }
                  }

                  Rectangle {
                    anchors.centerIn: parent
                    width: Style.space(20)
                    height: Style.space(20)
                    radius: height / 2
                    visible: dayCell.isToday
                    color: "transparent"
                    border.width: 1
                    border.color: Qt.alpha(root.bar.foreground, 0.45)
                  }

                  MouseArea {
                    id: dayArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectDay(dayCell.dateKey)
                  }
                }
              }
            }
          }

          Hairline {}

          // ---- Liturgical day title, date, saint, and colour chip.
          Item {
            width: parent.width
            height: Style.space(54)

            Column {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.right: headerChips.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                width: parent.width
                text: root.headerTitle.toUpperCase()
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: root.headerSaint === ""
                  ? Model.longDate(viewingKey)
                  : Model.longDate(viewingKey) + "  \u00B7  " + root.headerSaint
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Row {
              id: headerChips
              anchors.right: parent.right
              anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Rectangle {
                visible: dayMeta && dayMeta.colour !== ""
                width: seasonLabel.implicitWidth + Style.space(14)
                height: Style.space(18)
                radius: height / 2
                color: visible ? Util.alpha(root.liturgicalTextColor, 0.18) : "transparent"
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  id: seasonLabel
                  anchors.centerIn: parent
                  text: (dayMeta ? dayMeta.colour : "").toUpperCase()
                  color: root.liturgicalTextColor
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
              }
            }
          }

          // ---- Tabs, readings COPY, day navigation.
          Item {
            width: parent.width
            height: Style.space(24)

            Row {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Repeater {
                model: root.readingTabs

                Rectangle {
                  required property var modelData
                  required property int index
                  width: tabLabel.implicitWidth + Style.space(16)
                  height: Style.space(22)
                  radius: Style.cornerRadius
                  color: index === root.activeTab ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                    : (tabArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent")

                  Text {
                    id: tabLabel
                    anchors.centerIn: parent
                    text: modelData.label
                    color: root.bar.foreground
                    opacity: index === root.activeTab ? 1 : 0.65
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                  }

                  MouseArea {
                    id: tabArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.selectedSection = index
                      root.noteTabViewed(modelData.label)
                    }
                  }
                }
              }
            }

            Row {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              Rectangle {
                id: copyReadingsButton
                anchors.verticalCenter: parent.verticalCenter
                width: copyReadingsLabel.implicitWidth + Style.space(16)
                height: Style.space(20)
                radius: Style.cornerRadius
                color: readingsCopied ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                  : (copyReadingsArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent")
                border.width: readingsCopied ? 0 : 1
                border.color: Qt.alpha(root.bar.foreground, 0.35)

                Text {
                  id: copyReadingsLabel
                  anchors.centerIn: parent
                  text: readingsCopied ? "COPIED" : "COPY"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }

                MouseArea {
                  id: copyReadingsArea
                  anchors.fill: parent
                  hoverEnabled: true
                  enabled: !!currentReadings
                  cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.copyReadings()
                }
              }
            }
          }

          // ---- Active tab content. Layout data (header fit + wrapped verse
          // lines) is precomputed in recomputeWrapped() so the rendering
          // bindings stay read-only — writing TextMetrics from a binding
          // causes QML binding loops that hang the shell.
          Repeater {
            model: root.wrappedSections

            Column {
              required property var modelData
              width: bibleColumn.width
              spacing: 0

              Item {
                id: sectionHeader
                width: parent.width

                readonly property bool fits: modelData.fits
                readonly property string headerCite: modelData.citation
                readonly property real avail: width - Style.space(32)
                height: fits ? Style.space(22) : Style.space(36)

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(16)
                  anchors.top: parent.top
                  anchors.topMargin: sectionHeader.fits ? Style.space(5) : Style.space(2)
                  width: sectionHeader.fits
                    ? Math.max(0, sectionHeader.avail - (sectionHeader.headerCite ? modelData.citeW + Style.space(6) : 0))
                    : sectionHeader.avail
                  text: modelData.label
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                  elide: Text.ElideRight
                }

                Text {
                  visible: sectionHeader.headerCite !== ""
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(16)
                  anchors.top: parent.top
                  anchors.topMargin: sectionHeader.fits ? Style.space(4) : Style.space(24)
                  width: sectionHeader.fits
                    ? Math.min(modelData.citeW, sectionHeader.avail - modelData.labelW - Style.space(6))
                    : sectionHeader.avail
                  horizontalAlignment: sectionHeader.fits ? Text.AlignRight : Text.AlignLeft
                  text: sectionHeader.headerCite
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.italic: true
                  elide: Text.ElideRight
                }
              }

              Item { width: parent.width; height: Style.space(4) }

              Repeater {
                model: modelData.lines

                Column {
                  id: verseLine
                  required property var modelData
                  required property int index
                  width: bibleColumn.width
                  spacing: 0

                  Item {
                    width: parent.width
                    height: verseLine.modelData.paraGap === true ? Style.space(6) : 0
                  }

                  Repeater {
                    model: verseLine.modelData.parts

                    Text {
                      x: Style.space(16) + (verseLine.modelData.rich === true ? 0 : (index > 0 ? root.verseIndent : 0))
                      width: bibleColumn.width - Style.space(32) - (verseLine.modelData.rich === true ? 0 : (index > 0 ? root.verseIndent : 0))
                      text: modelData
                      textFormat: verseLine.modelData.rich === true ? Text.RichText : Text.AutoText
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      font.italic: verseLine.modelData.rich === true ? false : (verseLine.modelData.italic === true)
                      wrapMode: Text.WordWrap
                    }
                  }
                }
              }
            }
          }

          // ---- Loading / unavailable states for readings text. Days inside
          // the ~10-day feed window load via RSS; other days can be backfilled
          // by the fetch tool. Without the tool, the public page is offered.
          Column {
            x: Style.space(16)
            width: parent.width - Style.space(32)
            visible: !currentReadings
            spacing: Style.space(8)

            Text {
              visible: readingsProc.running || root.readingsInFlight
              text: "Fetching readings\u2026"
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }

            Text {
              visible: !readingsProc.running && !root.readingsInFlight && !root.readingsFetchable
              text: "Reading text for this day is on the public site at bible.usccb.org"
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.italic: true
              wrapMode: Text.WordWrap
              width: parent.width
            }

            Rectangle {
              visible: !readingsProc.running && !root.readingsInFlight && !root.readingsFetchable
              width: readOnlineLabel.implicitWidth + Style.space(16)
              height: Style.space(20)
              radius: Style.cornerRadius
              color: readOnlineArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
              border.width: 1
              border.color: Qt.alpha(root.bar.foreground, 0.35)

              Text {
                id: readOnlineLabel
                anchors.centerIn: parent
                text: "READ ONLINE"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              MouseArea {
                id: readOnlineArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openDayReadings(root.viewingKey)
              }
            }

            Rectangle {
              visible: !readingsProc.running && !root.readingsInFlight && root.readingsFetchable
              width: fetchLabel.implicitWidth + Style.space(16)
              height: Style.space(20)
              radius: Style.cornerRadius
              color: fetchArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
              border.width: 1
              border.color: Qt.alpha(root.bar.foreground, 0.35)

              Text {
                id: fetchLabel
                anchors.centerIn: parent
                text: "FETCH TEXT"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              MouseArea {
                id: fetchArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.ensureReadingsForKey(root.viewingKey, true)
              }
            }
          }

          // ---- Rosary mysteries of the day (tap to toggle the decades).
          Column {
            x: Style.space(16)
            spacing: Style.space(3)

            Item {
              width: rosaryHeaderRow.implicitWidth
              height: rosaryHeaderRow.implicitHeight

              Text {
                id: rosaryHeaderRow
                text: rosarySummary
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                id: rosaryArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.rosaryExpanded = !root.rosaryExpanded
              }

              Rectangle {
                anchors.fill: parent
                color: rosaryArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
                z: -1
              }
            }

            Column {
              visible: root.rosaryExpanded
              x: Style.space(22)
              spacing: Style.space(2)

              Repeater {
                model: {
                  var r = Model.rosaryMysteries(root.viewingKey)
                  return r.decades
                }

                Text {
                  required property string modelData
                  text: "\u2022 " + modelData
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          Hairline {}

          // ---- Credits: data sources, copyright, and links.
          Column {
            width: parent.width
            spacing: Style.space(4)

            Item {
              width: creditsToggleLabel.implicitWidth
              height: creditsToggleLabel.implicitHeight
              x: Style.space(16)

              Text {
                id: creditsToggleLabel
                text: "CREDITS"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              MouseArea {
                id: creditsToggleArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.creditsExpanded = !root.creditsExpanded
              }

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: creditsToggleArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
                z: -1
              }
            }

            Column {
              visible: root.creditsExpanded
              x: Style.space(16)
              width: parent.width - Style.space(16)
              spacing: Style.space(3)

              CreditLine {
                prefix: "Readings text: "
                linkText: "bible.usccb.org"
                url: "https://bible.usccb.org/bible/readings"
                suffix: " \u2014 NAB-RE \u00A9 Confraternity of Christian Doctrine; refrains \u00A9 ICEL"
              }

              CreditLine {
                prefix: "Readings audio: "
                linkText: "USCCB Daily Mass Reading Podcast"
                url: "https://bible.usccb.org/podcasts/audio"
                suffix: " \u2014 \u00A9 USCCB, official feed"
              }

              CreditLine {
                prefix: "Liturgical calendar: "
                linkText: "romcal"
                url: "https://github.com/romcal/romcal"
                suffix: " (MIT)"
              }

              Text {
                width: parent.width
                text: "For personal devotion. Not affiliated with or endorsed by the USCCB. Text and audio \u00A9 their publishers: RSS feed per the USCCB RSS policy; days outside the feed window fetched per the NAB permissions guidelines (under 5,000 words, web formats)."
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }

      Column {
        id: playerBar
        width: parent.width
        height: root.playerBarHeight

        Hairline {}

        Item {
          width: parent.width
          height: Style.space(38)

          Row {
            id: transportRow
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            TransportButton {
              glyph: "\uDB81\uDCAE"
              enabled: root.playing
              tooltipText: "Back to start"
              onActivated: root.seekToStart()
              anchors.verticalCenter: parent.verticalCenter
            }

            TransportButton {
              glyph: "\uDB83\uDD2A"
              enabled: root.playing
              tooltipText: "Back 10 seconds"
              onActivated: root.seekBack10()
              anchors.verticalCenter: parent.verticalCenter
            }

            Rectangle {
              id: playButton
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(34)
              height: Style.space(34)
              radius: height / 2
              color: playArea.containsMouse && playArea.enabled ? Style.hoverFillFor(root.bar.foreground, Color.accent) : Style.normalFillFor(root.bar.foreground, Color.accent)
              border.width: 1
              border.color: Qt.alpha(root.bar.foreground, 0.3)

              Text {
                anchors.centerIn: parent
                text: root.playing && !root.paused ? "\uDB80\uDFE4" : "\uDB81\uDC0A"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.iconLarge
              }

              MouseArea {
                id: playArea
                anchors.fill: parent
                hoverEnabled: true
                enabled: !!root.currentPodcast
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.togglePlayback()
              }

              PanelToolTip {
                visible: playArea.containsMouse && playArea.enabled
                text: root.playing && !root.paused ? "Pause podcast" : (root.paused ? "Resume podcast" : "Listen to this day's readings")
                fontFamily: root.bar.fontFamily
              }
            }
          }

          TransportButton {
            id: downloadButton
            anchors.right: parent.right
            anchors.rightMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            glyph: "\u2193"
            enabled: !!root.currentPodcast && !root.downloading
            tooltipText: "Download episode"
            onActivated: root.downloadPodcast()
          }

          Column {
            anchors.left: transportRow.right
            anchors.leftMargin: Style.space(10)
            anchors.right: durationLabel.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Text {
              width: parent.width
              text: podcastPhase === "loading" ? "Finding today's podcast\u2026"
                : podcastPhase === "error" ? "No podcast found for this date"
                : root.playerBarContext
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            PanelSlider {
              id: seekSlider
              width: parent.width
              visible: !!currentPodcast
              height: Style.space(14)
              bar: root.bar
              enabled: root.playing
              opacity: root.playing ? 1 : 0.45
              value: root.playbackRatio

              onReleased: function(v) { root.seekToRatio(v) }

              Connections {
                target: root
                function onPlaybackRatioChanged() {
                  if (!seekSlider.dragging) seekSlider.value = root.playbackRatio
                }
              }
            }
          }

          Text {
            id: durationLabel
            anchors.right: downloadButton.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: currentPodcast
              ? Model.formatDuration(root.elapsedSeconds) + " / " + Model.formatDuration(root.displayTotalSeconds)
              : ""
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }
  }

  // --------------------------------------------------------- ui helpers

  // Measurement primitive for reading-column layout. It is written ONLY
  // from recomputeWrapped() (a signal handler), never from a property
  // binding — writing text/font inside a binding evaluation makes the QML
  // engine report a binding loop and hang the shell.
  TextMetrics {
    id: readingMetrics
  }

  // 1em hanging indent for wrapped verse lines.
  readonly property real verseIndent: Style.space(12)

  // Plain-text wrapper around TextMetrics.advanceWidth. The font scratch
  // state lives entirely in JS so no QML binding depends on it. The family is
  // matched to the bar font so the measured width matches the rendered Text
  // (mismatch starves layout boxes and triggers elision).
  function measureWidth(text, pixelSize, italic, letterSpacing) {
    var family = root.bar && root.bar.fontFamily ? root.bar.fontFamily : ""
    if (readingMetrics.font.family !== family)
      readingMetrics.font.family = family
    readingMetrics.font.pixelSize = pixelSize
    readingMetrics.font.italic = italic === true
    readingMetrics.font.letterSpacing = letterSpacing === true ? 1 : 0
    readingMetrics.text = String(text || "")
    return readingMetrics.advanceWidth
  }

  // Greedy-word-wrap a feed line into visual sub-lines. Continuation lines
  // after the first are budgeted at `width - verseIndent` (the caller
  // offsets them by that much) → true hanging indent. A single word wider
  // than the whole line is left to WordWrap in the rendered Text.
  //
  // Orphan control: unless this is the section's true final line, a greedy
  // wrap that would strand 1-2 words on the last sub-line (e.g. "...heaven
  // and" / "on earth") is re-wrapped with a smaller continuation budget so
  // words flow back and the tail carries at least three words.
  function wrapReadingLine(text, italic, width, isFinal) {
    var words = String(text || "").split(/\s+/)
    var out = root.greedyWrapReadingLine(words, italic, width)
    if (out.length > 1 && !(isFinal === true) && out[out.length - 1].split(/\s+/).length <= 2) {
      var first = width - root.styleStep
      var guard = 0
      while (guard++ < 50) {
        var attempt = root.greedyWrapReadingLine(words, italic, first)
        if (attempt.length > out.length) break
        out = attempt
        if (out[out.length - 1].split(/\s+/).length >= 3) break
        first -= root.styleStep
      }
    }
    return out
  }

  // px subtracted per orphan-reduction step. Moving the wrap point earlier
  // (via a tighter first line) pushes the stranded words back into the tail.
  readonly property real styleStep: Math.max(2, Style.space(2))

  function greedyWrapReadingLine(words, italic, firstBudget) {
    var out = []
    var cur = ""
    var budget = firstBudget
    for (var i = 0; i < words.length; i++) {
      var probe = cur ? cur + " " + words[i] : words[i]
      if (cur && root.measureWidth(probe, Style.font.body, italic, false) > budget) {
        out.push(cur)
        budget = firstBudget - root.verseIndent
        cur = words[i]
      } else {
        cur = probe
      }
    }
    if (cur) out.push(cur)
    return out
  }

  // Escape plain text for the RichText paragraphs below (line.rich parts).
  function escapeHtml(text) {
    return String(text || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  // Build one rich-HTML paragraph string per <p> group: the section's lines
  // are joined with single spaces (source <br> breaks are dropped), italic
  // runs get <i>, and paragraph boundaries come from line.par. Returns one
  // HTML string per paragraph, in feed order.
  function proseParagraphsHtml(sec) {
    var paras = []
    for (var l = 0; l < sec.lines.length; l++) {
      var line = sec.lines[l]
      var par = (line.par !== undefined && line.par !== null) ? (line.par | 0) : 0
      if (paras.length === 0 || paras[paras.length - 1].par !== par) paras.push({ par: par, html: "" })
      var runs = line.runs && line.runs.length ? line.runs : [{ text: line.text, italic: line.italic === true }]
      for (var r = 0; r < runs.length; r++) {
        var bits = String(runs[r].text || "").split(/\s+/)
        for (var b = 0; b < bits.length; b++) {
          if (!bits[b]) continue
          var last = paras[paras.length - 1]
          if (last.html) last.html += " "
          var esc = root.escapeHtml(bits[b])
          last.html += runs[r].italic === true ? "<i>" + esc + "</i>" : esc
        }
      }
    }
    return paras.map(function(p) { return p.html })
  }

  // Recompute the per-section display data (header fit decision + wrapped
  // verse lines / reflowed prose paragraphs). Called from signal handlers and
  // dataRevision bumps, not from bindings, so the TextMetrics writes below
  // cannot form a loop.
  property var wrappedSections: []
  function recomputeWrapped() {
    var tab = root.readingTabs.length > 0 ? root.readingTabs[root.activeTab] : null
    var out = []
    if (tab) {
      var avail = bibleColumn.width - Style.space(32)
      for (var s = 0; s < tab.sections.length; s++) {
        var sec = tab.sections[s]
        var label = String(sec.label || "").toUpperCase()
        var cite = sec.citation || ""
        var labelW = root.measureWidth(label, Style.font.bodySmall, false, true)
        var citeW = cite ? root.measureWidth(cite, Style.font.bodySmall, true, false) : 0
        var fits = labelW + (cite ? Style.space(16) + citeW : 0) <= avail
        var lines = []
        var verse = /responsorial|psalm|alleluia|acclamation/i.test(String(sec.label || ""))
        if (verse) {
          // Poetry keeps its feed lines as-is (wrap with hanging indent).
          for (var l = 0; l < sec.lines.length; l++) {
            lines.push({
              italic: sec.lines[l].italic === true,
              parts: root.wrapReadingLine(sec.lines[l].text, sec.lines[l].italic === true, avail, l === sec.lines.length - 1)
            })
          }
        } else {
          // Prose reflows to flowing paragraphs: each <p> group is one RichText
          // blob that Qt's text engine wraps naturally (source <br> breaks are
          // dropped), with a small gap between paragraphs (set on non-first).
          var htmls = root.proseParagraphsHtml(sec)
          for (var q = 0; q < htmls.length; q++) {
            if (!htmls[q]) continue
            lines.push({
              rich: true,
              paraGap: q > 0,
              parts: [htmls[q]]
            })
          }
        }
        out.push({ label: label, citation: cite, labelW: labelW, citeW: citeW, fits: fits, lines: lines })
      }
    }
    root.wrappedSections = out
  }

  property bool rosaryExpanded: false
  property bool creditsExpanded: false

  readonly property string rosarySummary: {
    var r = Model.rosaryMysteries(viewingKey)
    return r.name + " \u2014 begins with " + r.decades[0]
  }
}
