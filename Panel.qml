import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "LectionaryCalendar.js" as Cal

Panel {
  id: root
  moduleName: "peter.bible"
  ipcTarget: "peter.bible"
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
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ------------------------------------------------------------ settings

  readonly property int refreshMinutes: Math.max(5, parseInt(setting("refreshMinutes", 30), 10) || 30)
  readonly property bool reminderEnabled: setting("reminderEnabled", true) !== false
  readonly property int reminderHour: Math.min(23, Math.max(0, parseInt(setting("reminderHour", 8), 10)))

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

  // Sections grouped into display tabs (acclamation folded into the Gospel).
  readonly property var readingTabs: currentReadings ? Model.buildReadingTabs(currentReadings.sections) : []
  readonly property int activeTab: Math.max(0, Math.min(selectedSection, readingTabs.length - 1))

  onViewingKeyChanged: {
    selectedSection = 0
    bibleScroll.contentY = 0
  }
  readonly property var currentReadings: {
    void root.dataRevision
    return root.readingsByDate[root.viewingKey] || null
  }
  readonly property string readingsPhase: {
    void root.dataRevision
    return root.readingsStatus[root.viewingKey] || ""
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

  readonly property color liturgicalColor: dayMeta ? Model.liturgicalColourHex(dayMeta.colour) : "transparent"

  // ---------------------------------------------------------------- utils

  function ensureAll() {
    ensureReadings(false)
    ensurePodcast(false)
  }

  function refreshAll() {
    ensureReadings(true)
    ensurePodcast(true)
  }

  // Cache round-trips through tiny bash helpers; payloads travel as argv so
  // unicode scripture text never touches shell quoting.
  function cacheWrite(fileName, json) {
    var target = Quickshell.env("HOME") + "/.local/state/omarchy/bible/cache/" + fileName
    cacheWriteProc.command = ["bash", "-c",
      "mkdir -p \"$(dirname \"$2\")\" && printf %s \"$1\" > \"$2\"", "bible-cache", json, target]
    cacheWriteProc.running = true
  }

  function cacheRead(purpose, fileName) {
    if (!fileName) return
    cacheReadProc.purpose = purpose
    cacheReadProc.command = ["bash", "-c",
      "cat \"$HOME/.local/state/omarchy/bible/cache/" + fileName + "\" 2>/dev/null"]
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
    command: ["curl", "-fsSL", "--max-time", "12", Model.usccbRss()]
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

  // --------------------------------------------------------------- podcast

  function ensurePodcast(force) {
    if (!force && podcastFeedFetched) return
    if (podcastProc.running) return
    podcastProc.running = true
  }

  // The SoundCloud feed carries every episode; one fetch maps them all by date.
  Process {
    id: podcastProc
    command: ["curl", "-fsS", "--max-time", "12", Model.podcastRss()]
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
  readonly property string mpvSocket: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/peter-bible-mpv.sock"

  function mpvCommand(json) {
    mpvCmdProc.command = ["bash", "-c",
      "printf '%s\\n' \"$1\" | timeout 3 socat - UNIX-CONNECT:\"$2\" >/dev/null 2>&1",
      "bible-mpv-cmd", JSON.stringify(json), mpvSocket]
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
      "dir=\"$(xdg-user-dir DOWNLOAD 2>/dev/null || echo \"$HOME/Downloads\")\"; "
      + "mkdir -p \"$dir\"; file=\"$dir/Daily-Mass-Reading-$2.mp3\"; "
      + "if curl -fsSL --max-time 300 -o \"$file\" \"$1\"; then "
      + "omarchy-notification-send \"Podcast saved: $file\"; "
      + "else omarchy-notification-send \"Podcast download failed\"; fi",
      "bible-dl", pod.url, viewingKey]
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
      "rm -f \"$1\"; exec mpv --no-video --no-terminal --really-quiet --keep-open=no --input-ipc-server=\"$1\" --title=peter-bible-widget \"$2\"",
      "bible-mpv", mpvSocket, pendingUrl]
    mpvProc.running = true
    console.log("[bible] mpv spawn issued")
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
      "bible-mpv-q", mpvSocket]
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
    path: Quickshell.env("HOME") + "/.local/state/omarchy/bible/activity.json"
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
    var target = Quickshell.env("HOME") + "/.local/state/omarchy/bible/activity.json"
    activitySaveProc.command = ["bash", "-c",
      "mkdir -p \"$(dirname \"$2\")\" && printf %s \"$1\" > \"$2\"", "bible-activity", JSON.stringify(state), target]
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
    if (!contentAvailable(key)) return
    viewingKey = key
    ensurePodcast(false)
    followPlayback()
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

  // A day is clickable when its readings text or its podcast is in hand.
  function contentAvailable(key) {
    return !!readingsByDate[key] || !!podcastByDate[key]
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
    running: true
    triggeredOnStart: false
    onTriggered: activityFile.reload()
  }

  Component.onCompleted: {
    activityFile.reload()
    Qt.callLater(checkReminder)
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refreshAll() }
    function play(): void { root.togglePlayback() }
    function stop(): void { root.stopPlayback() }

    function debug(): string {
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
    contentHeight: panel.fittedContentHeight(bibleColumn.implicitHeight)

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

      Flickable {
        id: bibleScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: bibleColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: bibleColumn
          width: bibleScroll.width
          spacing: Style.space(14)

          // ---- Month calendar: liturgical colours, done rings, day picker.
          Column {
            id: calBlock
            width: parent.width
            spacing: Style.space(6)

            readonly property int firstWeekday: new Date(calYear, calMonth, 1).getDay()
            readonly property int daysInMonth: new Date(calYear, calMonth + 1, 0).getDate()
            readonly property real cellWidth: (width - Style.space(32)) / 7

            Item {
              width: parent.width
              height: Style.space(22)

              NavButton {
                glyph: "<"
                active: root.calMonthIndex > root.calMinIndex
                tooltipText: "Previous month"
                onActivated: root.setCalMonthIndex(root.calMonthIndex - 1)
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
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
                anchors.rightMargin: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Item {
              x: Style.space(16)
              width: parent.width - Style.space(32)
              height: (numRows + 1) * Style.space(28)

              readonly property int numRows: Math.ceil((calBlock.firstWeekday + calBlock.daysInMonth) / 7)

              Repeater {
                model: 7
                Text {
                  required property int index
                  x: index * calBlock.cellWidth
                  y: 0
                  width: calBlock.cellWidth
                  height: Style.space(28)
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
                  y: (Math.floor(index / 7) + 1) * Style.space(28)
                  width: calBlock.cellWidth
                  height: Style.space(28)

                  readonly property int dayNumber: index + 1 - calBlock.firstWeekday
                  readonly property string dateKey: dayNumber >= 1
                    ? root.calYear + "-" + Model.pad2(root.calMonth + 1) + "-" + Model.pad2(dayNumber) : ""
                  readonly property var meta: dayNumber >= 1 ? Cal.get(dateKey) : null
                  readonly property bool isToday: dateKey === root.todayK
                  readonly property bool isSelected: dateKey === root.viewingKey
                  readonly property bool isDone: dateKey !== "" && root.isDone(dateKey)
                  readonly property bool available: dateKey !== "" && root.contentAvailable(dateKey)
                  readonly property color dayTint: meta ? Model.liturgicalColourHex(meta.colour) : root.bar.foreground

                  visible: dayNumber >= 1

                  Rectangle {
                    anchors.fill: parent
                    anchors.margins: Style.space(1)
                    radius: Style.cornerRadius
                    color: dayCell.isSelected ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                      : (dayCell.available && dayArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent")
                    border.width: dayCell.isDone ? 1 : 0
                    border.color: Qt.alpha("#6f996f", 0.55)
                  }

                  Rectangle {
                    anchors.fill: parent
                    anchors.margins: Style.space(1)
                    radius: Style.cornerRadius
                    color: "transparent"
                    border.width: dayCell.isToday && !dayCell.isSelected ? 1 : 0
                    border.color: Qt.alpha(root.bar.foreground, 0.5)
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: dayCell.dayNumber >= 1
                    text: dayCell.dayNumber >= 1 ? dayCell.dayNumber : ""
                    color: dayCell.dayTint
                    opacity: dayCell.available ? 1 : 0.4
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: dayCell.isToday || dayCell.isSelected
                  }

                  MouseArea {
                    id: dayArea
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: dayCell.available
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.selectDay(dayCell.dateKey)
                  }
                }
              }
            }
          }

          Hairline {}

          // ---- Liturgical day title and colour chip.
          Item {
            width: parent.width
            height: Style.space(20)

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.right: headerChips.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: root.dayTitle.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.letterSpacing: 1
              elide: Text.ElideRight
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
                color: visible ? Util.alpha(liturgicalColor, 0.18) : "transparent"
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  id: seasonLabel
                  anchors.centerIn: parent
                  text: (dayMeta ? dayMeta.colour : "").toUpperCase()
                  color: liturgicalColor
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

              Rectangle {
                id: todayJumpButton
                anchors.verticalCenter: parent.verticalCenter
                width: todayJumpLabel.implicitWidth + Style.space(14)
                height: Style.space(20)
                radius: Style.cornerRadius
                color: todayJumpArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
                border.width: 1
                border.color: Qt.alpha(root.bar.foreground, 0.35)

                Text {
                  id: todayJumpLabel
                  anchors.centerIn: parent
                  text: "TODAY"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }

                MouseArea {
                  id: todayJumpArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.setCalMonthFromKey(root.todayK)
                    root.selectDay(root.todayK)
                  }
                }
              }
            }
          }

          // ---- Active tab content.
          Repeater {
            model: root.readingTabs.length > 0 ? root.readingTabs[root.activeTab].sections : []

            Column {
              required property var modelData
              width: bibleColumn.width
              spacing: Style.space(6)

              Item {
                width: parent.width
                height: Style.space(16)

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(16)
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.label.toUpperCase()
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                Text {
                  visible: modelData.citation !== ""
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(16)
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.citation
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.italic: true
                }
              }

              Repeater {
                model: modelData.lines

                Text {
                  required property var modelData
                  x: Style.space(16)
                  width: bibleColumn.width - Style.space(32)
                  text: modelData.text
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.italic: modelData.italic === true
                  wrapMode: Text.WordWrap
                }
              }
            }
          }

          // ---- Loading / unavailable states for readings text.
          Column {
            x: Style.space(16)
            width: parent.width - Style.space(32)
            visible: !currentReadings
            spacing: Style.space(4)

            Text {
              visible: readingsProc.running
              text: "Fetching readings\u2026"
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }

            Text {
              visible: !readingsProc.running
              text: "Readings text not available for this date.\nFull readings are available for the most recent days at bible.usccb.org"
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.italic: true
              wrapMode: Text.WordWrap
              width: parent.width
            }
          }

          // ---- Saint / feast of the day (from the bundled calendar).
          Row {
            x: Style.space(16)
            visible: dayMeta && dayMeta.saint !== ""
            spacing: Style.space(8)

            Text {
              text: "\uDB81\uDD79"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: dayMeta ? dayMeta.saint : ""
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
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

          // ---- Podcast row: transport controls, title, progress, download.
          Column {
            width: parent.width
            spacing: Style.space(6)

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
                  text: currentPodcast ? currentPodcast.title
                    : (podcastPhase === "loading" ? "Finding today's podcast\u2026"
                    : podcastPhase === "error" ? "No podcast found for this date" : "Daily Mass Reading Podcast")
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
                text: "For personal devotion. Not affiliated with or endorsed by the USCCB; text shown per the USCCB RSS policy and \u00A9 its publishers."
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }
    }
  }

  // --------------------------------------------------------- ui helpers

  property bool rosaryExpanded: false
  property bool creditsExpanded: false

  readonly property string rosarySummary: {
    var r = Model.rosaryMysteries(viewingKey)
    return r.name + " \u2014 begins with " + r.decades[0]
  }
}
