import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

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
  readonly property string fallbackTranslation: String(setting("fallbackTranslation", "web"))

  // --------------------------------------------------------------- state

  property string todayK: Model.todayKey() // updated by the rollover timer

  // Pill: simple cross outline, always.
  readonly property bool markedToday: streakState.lastMarked === root.todayK
  readonly property string label: "\uDB83\uDCF6"

  // An unbroken chain survives until yesterday is missed.
  readonly property int streakDays: {
    if (streakState.lastMarked === root.todayK) return streakState.count
    if (streakState.lastMarked === Model.shiftKey(root.todayK, -1)) return streakState.count
    return 0
  }
  property var streakState: Model.emptyStreak()
  property bool streakLoaded: false

  // Plain JS objects don't emit change notifications, so every mutation
  // bumps dataRevision and downstream bindings reference it explicitly.
  property int dataRevision: 0

  property var votd: null            // {text, reference, version}
  property bool votdLoading: false

  property var readingsByDate: ({})  // dateKey -> parsed universalis result
  property var readingsStatus: ({})  // dateKey -> "loading" | "ok" | "error"
  property string viewingKey: Model.todayKey()
  property int selectedSection: 0

  // Sections grouped into display tabs (acclamation folded into the Gospel).
  readonly property var readingTabs: currentReadings ? Model.buildReadingTabs(currentReadings.sections) : []
  readonly property int activeTab: Math.max(0, Math.min(selectedSection, readingTabs.length - 1))

  onViewingKeyChanged: selectedSection = 0
  readonly property var currentReadings: {
    void root.dataRevision
    return root.readingsByDate[root.viewingKey] || null
  }
  readonly property string readingsPhase: {
    void root.dataRevision
    return root.readingsStatus[root.viewingKey] || ""
  }

  property var podcastByKey: ({})    // dateKey -> {title,url,durationSeconds}
  property var podcastStatus: ({})
  readonly property var currentPodcast: {
    void root.dataRevision
    return root.podcastByKey[root.viewingKey] || null
  }
  readonly property string podcastPhase: {
    void root.dataRevision
    return root.podcastStatus[root.viewingKey] || ""
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
    if (votd) parts.push(votd.reference + " (" + votd.version + ") \u2014 " + Model.trimWords(votd.text, 160))
    else parts.push("Verse of the day not fetched yet")
    if (currentReadings && currentReadings.title) parts.push(currentReadings.title)
    if (streakDays > 0) parts.push("\uD83D\uDD25 " + streakDays + "-day streak")
    return String(parts.join(" \u2022 ")).replace(/[$`"\\]/g, "'")
  }

  readonly property color liturgicalColor: currentReadings ? Model.seasonColor(currentReadings.colour) : "transparent"

  // ---------------------------------------------------------------- utils

  function ensureAll() {
    ensureVotd(false)
    ensureReadings(false)
    ensurePodcast(false)
  }

  function refreshAll() {
    ensureVotd(false) // verse is per-day; refetches only after rollover clears it
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
    if (kind === "votd" && !votd && data.votd) {
      votd = data.votd
    } else if (kind === "readings" && key && !readingsByDate[key]) {
      if (data.readings && data.readings.ok) {
        readingsByDate[key] = data.readings
        readingsStatus[key] = "ok"
      }
    } else if (kind === "podcast" && key && !podcastByKey[key]) {
      if (data.podcast) {
        podcastByKey[key] = data.podcast
        podcastStatus[key] = "ok"
      }
    }
    dataRevision++
  }

  // ---------------------------------------------------------- verse of day

  function ensureVotd(force) {
    if (votdLoading) return
    if (!force && votd) return
    votdLoading = true
    votdProc.running = true
  }

  Process {
    id: votdProc
    command: ["curl", "-fsS", "--max-time", "8", "https://beta.ourmanna.com/api/v1/get/?format=json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        votdLoading = false
        var parsed = Model.parseManna(String(text || ""))
        if (parsed) {
          root.votd = parsed
          root.cacheWrite("votd-" + root.todayK + ".json", JSON.stringify({ votd: parsed }))
        } else {
          votdFallbackProc.restartIfNeeded()
        }
      }
    }
  }

  // OurManna down/offline → deterministic reference of the day via bible-api.
  Process {
    id: votdFallbackProc

    function restartIfNeeded() {
      command = ["curl", "-fsS", "--max-time", "8",
        Model.bibleApiUrl(Model.fallbackReference(root.todayK), root.fallbackTranslation)]
      running = true
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseBibleApi(String(text || ""), Model.fallbackReference(root.todayK))
        if (parsed) {
          root.votd = parsed
          root.cacheWrite("votd-" + root.todayK + ".json", JSON.stringify({ votd: parsed }))
        } else {
          root.cacheRead("votd:" + root.todayK, "votd-" + root.todayK + ".json")
        }
      }
    }
  }

  // -------------------------------------------------------------- readings

  function ensureReadings(force) {
    var key = viewingKey
    if (!force && (readingsByDate[key] || readingsStatus[key] === "loading")) return
    if (readingsProc.running) return
    readingsStatus[key] = "loading"
    dataRevision++
    readingsProc.targetKey = key
    readingsProc.command = ["curl", "-fsSL", "--max-time", "12", "-A", "Mozilla/5.0",
      Model.universalisUrl(key)]
    readingsProc.running = true
  }

  Process {
    id: readingsProc
    property string targetKey: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var key = readingsProc.targetKey
        var parsed = Model.parseUniversalis(String(text || ""))
        if (parsed.ok) {
          root.readingsByDate[key] = parsed
          root.readingsStatus[key] = "ok"
          root.cacheWrite("readings-" + key + ".json", JSON.stringify({ readings: parsed }))
        } else {
          root.readingsStatus[key] = "error"
        }
        root.dataRevision++
      }
    }
    onExited: {
      if (!root.readingsByDate[targetKey])
        root.cacheRead("readings:" + targetKey, "readings-" + targetKey + ".json")
      // A navigate() during this fetch was dropped by the in-flight guard;
      // pick up whatever day is on screen now (never re-fires for the same
      // day, so a failing network cannot loop).
      if (targetKey !== root.viewingKey)
        Qt.callLater(function() { root.ensureReadings(false) })
    }
  }

  // --------------------------------------------------------------- podcast

  function ensurePodcast(force) {
    var key = viewingKey
    if (!force && (podcastByKey[key] || podcastStatus[key] === "loading")) return
    if (podcastProc.running) return
    podcastStatus[key] = "loading"
    dataRevision++
    podcastProc.targetKey = key
    podcastProc.running = true
  }

  // Official USCCB Daily Readings podcast feed (SoundCloud-hosted).
  Process {
    id: podcastProc
    property string targetKey: ""
    command: ["curl", "-fsS", "--max-time", "12", Model.podcastRss()]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var key = podcastProc.targetKey
        var matched = Model.matchPodcast(String(text || ""), key)
        if (matched) {
          root.podcastByKey[key] = matched
          root.podcastStatus[key] = "ok"
          root.cacheWrite("podcast-" + key + ".json", JSON.stringify({ podcast: matched }))
        } else {
          root.podcastStatus[key] = "error"
        }
        root.dataRevision++
      }
    }
    onExited: {
      if (!root.podcastByKey[targetKey])
        root.cacheRead("podcast:" + targetKey, "podcast-" + targetKey + ".json")
      if (targetKey !== root.viewingKey)
        Qt.callLater(function() { root.ensurePodcast(false) })
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

  // ---------------------------------------------------------------- streak

  property FileView streakFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/bible/streak.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.applyStreakState(Model.parseStreakFile(text()))
      root.streakLoaded = true
    }
    onFileChanged: reload()
    onLoadFailed: root.streakLoaded = true
  }

  function applyStreakState(state) {
    streakState = state
  }

  function markRead() {
    if (markedToday) return
    var next = Model.markRead(streakState, todayK)
    streakState = next
    persistStreak(next)
  }

  function persistStreak(state) {
    var target = Quickshell.env("HOME") + "/.local/state/omarchy/bible/streak.json"
    streakSaveProc.command = ["bash", "-c",
      "mkdir -p \"$(dirname \"$2\")\" && printf %s \"$1\" > \"$2\"", "bible-streak", JSON.stringify(state), target]
    streakSaveProc.running = true
  }

  Process {
    id: streakSaveProc
  }

  function recordReminderSent() {
    var next = Object.assign({}, streakState, { lastReminder: todayK })
    streakState = next
    persistStreak(next)
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
    if (!reminderEnabled || !streakLoaded) return
    var now = new Date()
    if (now.getHours() < reminderHour) return
    if (markedToday) return
    if (streakState.lastReminder === todayK) return
    var msg = "Today's readings are waiting"
    if (currentReadings && currentReadings.title) msg += " \u2014 " + currentReadings.title
    if (streakDays > 0) msg += " (\uD83D\uDD25 " + streakDays + "-day streak)"
    sendNotification(msg)
    recordReminderSent()
  }

  function sendNotification(message) {
    if (!bar) return
    var safe = String(message).replace(/[$`"\\]/g, "'")
    bar.run("omarchy-notification-send \"" + safe + "\"")
  }

  // Copy verse of the day / readings to the clipboard, with brief feedback.
  Process {
    id: copyProc
  }

  property bool votdCopied: false
  property bool readingsCopied: false

  Timer {
    id: copyFeedbackTimer
    interval: 1500
    onTriggered: {
      root.votdCopied = false
      root.readingsCopied = false
    }
  }

  function copyVotd() {
    if (!votd) return
    var text = "\u201C" + votd.text + "\u201D \u2014 " + votd.reference + " (" + votd.version + ")"
    copyProc.command = ["wl-copy", text]
    copyProc.running = true
    votdCopied = true
    copyFeedbackTimer.restart()
  }

  function copyReadings() {
    var group = readingTabs[activeTab]
    if (!group || !currentReadings) return
    copyProc.command = ["wl-copy", Model.readingsToText(currentReadings.title, group.sections)]
    copyProc.running = true
    readingsCopied = true
    copyFeedbackTimer.restart()
  }

  // -------------------------------------------------------- day navigation

  function navigate(delta) {
    var next = Model.shiftKey(viewingKey, delta)
    var earliest = Model.shiftKey(todayK, -7)
    var latest = Model.shiftKey(todayK, 7) // read/listen ahead (e.g. Sunday vigil)
    if (next < earliest || next > latest) return
    viewingKey = next
    ensureReadings(false)
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

  readonly property bool canGoBack: Model.shiftKey(viewingKey, -1) >= Model.shiftKey(todayK, -7)
  readonly property bool canGoForward: viewingKey < Model.shiftKey(todayK, 7)

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
        root.votd = null // fresh verse for the new day
        root.refreshAll()
      }
    }
  }

  Timer {
    interval: 1500
    running: true
    triggeredOnStart: false
    onTriggered: streakFile.reload()
  }

  Component.onCompleted: {
    streakFile.reload()
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
    function verse(): void { root.sendNotification(root.notificationText) }
    function play(): void { root.togglePlayback() }
    function stop(): void { root.stopPlayback() }
    function markRead(): void { root.markRead() }

    function debug(): string {
      return JSON.stringify({
        viewing: viewingKey,
        today: todayK,
        votd: !!votd,
        readingsKeys: Object.keys(readingsByDate),
        readingsPhase: root.readingsPhase,
        podKeys: Object.keys(podcastByKey),
        podStatus: podcastStatus,
        podProcRunning: podcastProc.running,
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
      onReturnRequested: root.markRead()
      onMoveRequested: function(dx, dy) {
        if (dx !== 0 && root.readingTabs.length > 1) {
          var next = root.activeTab + dx
          if (next >= 0 && next < root.readingTabs.length) root.selectedSection = next
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

          // ---- Header: section caption.
          Item {
            width: parent.width
            height: Style.space(18)

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              text: "VERSE OF THE DAY"
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 1
            }
          }

          // ---- Hero: verse of the day.
          Column {
            width: parent.width
            spacing: Style.space(10)

            Text {
              x: Style.space(16)
              width: parent.width - Style.space(32)
              text: votd ? votd.text : (votdLoading ? "Fetching verse\u2026" : "Verse of the day unavailable offline")
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.heading
              font.italic: true
              wrapMode: Text.WordWrap
            }

            Item {
              x: Style.space(16)
              width: parent.width - Style.space(32)
              height: Style.space(22)

              Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  text: votd ? votd.reference.toUpperCase() : ""
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                Text {
                  visible: votd && votd.version !== ""
                  text: votd ? votd.version : ""
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              Rectangle {
                id: copyVotdButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: copyVotdLabel.implicitWidth + Style.space(16)
                height: Style.space(20)
                radius: Style.cornerRadius
                color: votdCopied ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                  : (copyVotdArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent")
                border.width: votdCopied ? 0 : 1
                border.color: Qt.alpha(root.bar.foreground, 0.35)

                Text {
                  id: copyVotdLabel
                  anchors.centerIn: parent
                  text: votdCopied ? "COPIED" : "COPY"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }

                MouseArea {
                  id: copyVotdArea
                  anchors.fill: parent
                  hoverEnabled: true
                  enabled: !!votd
                  cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.copyVotd()
                }
              }
            }
          }

          Hairline {}

          // ---- Liturgical day, colour chip, rank.
          Item {
            width: parent.width
            height: Style.space(20)

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.right: headerChips.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: (currentReadings && currentReadings.title ? currentReadings.title : Model.longDate(viewingKey)).toUpperCase()
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
                visible: currentReadings && currentReadings.colour !== ""
                width: seasonLabel.implicitWidth + Style.space(14)
                height: Style.space(18)
                radius: height / 2
                color: visible ? Util.alpha(liturgicalColor, 0.18) : "transparent"
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  id: seasonLabel
                  anchors.centerIn: parent
                  text: (currentReadings ? currentReadings.colour : "").toUpperCase()
                  color: liturgicalColor
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
              }

              Text {
                visible: currentReadings && currentReadings.rank !== ""
                text: currentReadings ? currentReadings.rank : ""
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
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
                    onClicked: root.selectedSection = index
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

              NavButton {
                glyph: "<"
                active: root.canGoBack
                tooltipText: "Previous day"
                onActivated: root.navigate(-1)
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: (viewingKey === root.todayK ? "TODAY" : Model.shortDate(viewingKey))
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                anchors.verticalCenter: parent.verticalCenter
              }

              NavButton {
                glyph: ">"
                active: root.canGoForward
                tooltipText: "Next day"
                onActivated: root.navigate(1)
                anchors.verticalCenter: parent.verticalCenter
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
                  opacity: modelData.kind === "heading" ? 0.85 : 1
                  font.family: root.bar.fontFamily
                  font.pixelSize: modelData.kind === "heading" ? Style.font.subtitle : Style.font.body
                  font.italic: modelData.italic === true || modelData.kind === "heading"
                  wrapMode: Text.WordWrap
                  leftPadding: modelData.kind === "verse-indent" ? Style.space(18) : 0
                }
              }
            }
          }

          Text {
            x: Style.space(16)
            visible: readingsPhase === "loading"
            text: "Fetching readings\u2026"
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          Text {
            x: Style.space(16)
            visible: readingsPhase === "error"
            text: "Readings unavailable \u2014 check connection"
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          // ---- Saint of the day.
          Row {
            x: Style.space(16)
            visible: currentReadings && currentReadings.saint !== ""
            spacing: Style.space(8)

            Text {
              text: "\uDB81\uDD79"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: (currentReadings ? currentReadings.saint : "") + (currentReadings && currentReadings.rank !== "" ? " \u00B7 " + currentReadings.rank : "")
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

          // ---- Streak footer.
          Item {
            width: parent.width
            height: Style.space(44)

            Row {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(36)

              Column {
                spacing: Style.space(3)

                Item {
                  width: Style.space(70)
                  height: Style.font.icon

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "STREAK"
                    color: Qt.darker(root.bar.foreground, 1.5)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.letterSpacing: 1
                  }
                }

                Text {
                  text: streakDays + (streakDays === 1 ? " day" : " days")
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                }
              }

              Column {
                spacing: Style.space(3)

                Item {
                  width: Style.space(70)
                  height: Style.font.icon

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "BEST"
                    color: Qt.darker(root.bar.foreground, 1.5)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.letterSpacing: 1
                  }
                }

                Text {
                  text: streakState.best + (streakState.best === 1 ? " day" : " days")
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                }
              }
            }

            Rectangle {
              id: markButton
              anchors.right: parent.right
              anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              width: markRow.implicitWidth + Style.space(24)
              height: Style.space(30)
              radius: Style.cornerRadius
              color: markedToday ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                : (markArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent")
              border.width: markedToday ? 0 : 1
              border.color: Qt.alpha(root.bar.foreground, 0.35)

              Row {
                id: markRow
                anchors.centerIn: parent
                spacing: Style.space(6)

                Text {
                  text: markedToday ? "\uDB81\uDDE0" : "\uDB81\uDDE1"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: markedToday ? "DONE" : "MARK AS DONE"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                id: markArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.markRead() // no-op once today is already marked
                  root.close() // clicking DONE also tidies the widget away
                }
              }
            }
          }
        }
      }
    }
  }

  // --------------------------------------------------------- ui helpers

  property bool rosaryExpanded: false

  readonly property string rosarySummary: {
    var r = Model.rosaryMysteries(viewingKey)
    return r.name + " \u2014 begins with " + r.decades[0]
  }
}
