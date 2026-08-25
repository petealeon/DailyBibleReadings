// Data helpers for peter.bible: date math, OurManna VOTD parsing, Universalis
// readings HTML parsing, USCCB/SoundCloud podcast RSS matching, rosary
// mysteries, and streak state transitions.

// ---------------------------------------------------------------- dates

var MONTHS = ["January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"]

function keyToDate(key) {
  var parts = String(key || "").split("-")
  if (parts.length !== 3) return new Date()
  var d = new Date(parseInt(parts[0], 10), parseInt(parts[1], 10) - 1, parseInt(parts[2], 10))
  return isNaN(d.getTime()) ? new Date() : d
}

function todayKey() {
  var d = new Date()
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
}

function pad2(n) { return (n < 10 ? "0" : "") + n }

function shiftKey(key, days) {
  var d = keyToDate(key)
  d.setDate(d.getDate() + parseInt(days, 10) || 0)
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
}

// "Monday 24 August"
function longDate(key) {
  var d = keyToDate(key)
  var names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
  return names[d.getDay()] + " " + d.getDate() + " " + MONTHS[d.getMonth()]
}

// "24-08" — compact nav label for non-today days.
function shortDate(key) {
  var d = keyToDate(key)
  return pad2(d.getDate()) + "-" + pad2(d.getMonth() + 1)
}

// "August 24, 2026" — matches USCCB podcast item titles.
function monthDayYear(key) {
  var d = keyToDate(key)
  return MONTHS[d.getMonth()] + " " + d.getDate() + ", " + d.getFullYear()
}

// ------------------------------------------------------------- entities/text

function decodeEntities(s) {
  return String(s || "")
    .replace(/&#x([0-9a-fA-F]+);/g, function(m, h) { return String.fromCodePoint(parseInt(h, 16)) })
    .replace(/&#(\d+);/g, function(m, d) { return String.fromCodePoint(parseInt(d, 10)) })
    .replace(/&nbsp;/g, " ")
    .replace(/&middot;/g, "·")
    .replace(/&quot;/g, "\"")
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&")
}

function textOf(html) {
  return decodeEntities(String(html || "").replace(/<[^>]*>/g, "")).replace(/\s+/g, " ").trim()
}

// Trim at a word boundary so notifications never cut scripture mid-word.
function trimWords(s, max) {
  s = String(s || "")
  if (s.length <= max) return s
  var cut = s.lastIndexOf(" ", max)
  return (cut > max / 3 ? s.slice(0, cut) : s.slice(0, max)) + "\u2026"
}

// ------------------------------------------------------------ verse of day

// beta.ourmanna.com/api/v1/get/?format=json
function parseManna(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    var details = data && data.verse && data.verse.details
    if (!details || !details.text) return null
    return {
      text: String(details.text).replace(/\s+/g, " ").trim(),
      reference: String(details.reference || "").trim(),
      version: String(details.version || "NIV").trim()
    }
  } catch (e) {
    return null
  }
}

// Offline fallback pool: deterministic pick by day-of-year keeps the verse
// stable for the whole day without any network dependency. References are
// resolved through bible-api.com when the manna API is unreachable.
var FALLBACK_VERSES = [
  "John 3:16", "Psalm 23:1", "Romans 8:28", "Philippians 4:13", "Proverbs 3:5",
  "Isaiah 40:31", "Jeremiah 29:11", "Matthew 6:33", "Psalm 46:1", "1 Corinthians 13:4",
  "Hebrews 11:1", "James 1:5", "Psalm 119:105", "Ephesians 2:8", "Galatians 5:22",
  "Isaiah 41:10", "Joshua 1:9", "Psalm 27:1", "Matthew 11:28", "Romans 12:2",
  "Zephaniah 3:17", "Psalm 34:8", "Lamentations 3:22", "Micah 6:8", "Psalm 121:1",
  "John 14:27", "1 Peter 5:7", "Colossians 3:23", "Psalm 139:14", "Proverbs 16:3",
  "Isaiah 26:3", "Matthew 5:16", "Romans 15:13", "Psalm 91:1", "1 John 4:19",
  "Philippians 4:6", "Psalm 37:4", "2 Corinthians 5:17", "Psalm 100:4", "John 15:5",
  "Psalm 63:1", "Deuteronomy 31:6", "Psalm 51:10", "Mark 12:30", "Luke 1:46",
  "Acts 1:8", "Psalm 84:11", "Nahum 1:7", "Exodus 14:14", "Psalm 118:24",
  "1 Corinthians 16:14", "Psalm 145:8", "Isaiah 43:1", "Matthew 28:19", "Psalm 62:1",
  "Romans 8:38", "Psalm 19:8", "John 8:12", "Psalm 133:1", "1 Samuel 16:7",
  "Hosea 6:3", "Psalm 147:3", "Amos 5:24", "Revelation 21:4"
]

function fallbackReference(key) {
  var d = keyToDate(key)
  var start = new Date(d.getFullYear(), 0, 0)
  var dayOfYear = Math.floor((d - start) / 86400000)
  return FALLBACK_VERSES[dayOfYear % FALLBACK_VERSES.length]
}

function bibleApiUrl(reference, translation) {
  return "https://bible-api.com/" + encodeURIComponent(reference)
    + "?translation=" + encodeURIComponent(translation || "web")
}

function parseBibleApi(raw, referenceHint) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || !data.text) return null
    return {
      text: String(data.text).replace(/\s+/g, " ").trim(),
      reference: String(data.reference || referenceHint || "").trim(),
      version: String((data.translation_name || "WEB")).trim()
    }
  } catch (e) {
    return null
  }
}

// ------------------------------------------------------- universalis readings

function universalisUrl(key) {
  var d = keyToDate(key)
  return "https://universalis.com/" + d.getFullYear() + pad2(d.getMonth() + 1) + pad2(d.getDate()) + "/mass.htm"
}

function parseUniversalis(html) {
  var out = { ok: false, dateLine: "", title: "", rank: "", colour: "", year: "", saint: "", sections: [] }
  html = String(html || "")
  if (html.length < 200) return out

  var m = html.match(/<tt>([\s\S]*?)<\/tt>/i)
  out.dateLine = m ? textOf(m[1]) : ""

  var h1idx = html.search(/<h1[^>]*>\s*Readings at Mass/i)
  var head = h1idx > 0 ? html.slice(0, h1idx) : ""
  m = head.match(/<strong[^>]*>([\s\S]*?)<\/strong>/i)
  out.title = m ? textOf(m[1]) : ""
  m = head.match(/<br\s*\/?>\s*<span[^>]*>([\s\S]*?)<\/span>/i)
  out.rank = m ? textOf(m[1]) : ""

  m = html.match(/Liturgical Colour:\s*([A-Za-z ]+?)\.\s*Year:\s*([A-Za-z0-9() ]+?)\./i)
  if (!m) m = html.match(/Liturgical Colour:\s*([A-Za-z ]+)/i)
  out.colour = m ? m[1].trim() : ""
  if (m && m.length > 2) out.year = m[2].trim()

  // Saint of the day only when the feast honours one.
  out.saint = /^saint|st\.?\s/i.test(out.title) ? out.title.replace(/\s*\([^)]*\)\s*$/, "") : ""

  var startIdx = 0
  if (h1idx >= 0) {
    var close = html.indexOf("</h1>", h1idx)
    startIdx = close >= 0 ? close + 5 : h1idx
  }
  var rest = html.slice(startIdx)
  var endMatch = rest.search(/<h2[\s>]|<!--\s*Delta/i)
  var body = endMatch >= 0 ? rest.slice(0, endMatch) : rest
  var chunks = body.split(/<hr[^>]*>/i)

  for (var i = 0; i < chunks.length; i++) {
    var chunk = chunks[i]
    var labelM = chunk.match(/<th[^>]*align="left"[^>]*>([\s\S]*?)<\/th>/i)
    if (!labelM) continue
    var section = { label: textOf(labelM[1]), citation: "", lines: [] }
    var citeM = chunk.match(/<th[^>]*align="right"[^>]*>([\s\S]*?)<\/th>/i)
    if (citeM) section.citation = textOf(citeM[1])

    var headingM = chunk.match(/<h4[^>]*>([\s\S]*?)<\/h4>/i)
    if (headingM) section.lines.push({ text: textOf(headingM[1]), kind: "heading" })

    var divRe = /<(div)\s+class="([^"]*)"([^>]*)>([\s\S]*?)<\/div>/gi
    var dm
    while ((dm = divRe.exec(chunk)) !== null) {
      var cls = dm[2]
      if (/audioclip/.test(cls)) continue
      var inner = dm[4]
      var italic = /^\s*<i[\s>][\s\S]*<\/i>\s*$/.test(inner)
      var text = textOf(inner)
      if (!text) continue
      var kind = /(^|\s)vi(\s|$)/.test(cls) ? "verse-indent" : ((/(^|\s)v(\s|$)/.test(cls)) ? "verse" : "prose")
      // Collapse consecutive identical responses (psalms repeat them).
      var prev = section.lines[section.lines.length - 1]
      if (prev && prev.text === text) continue
      section.lines.push({ text: text, kind: kind, italic: italic })
    }

    if (section.label.toLowerCase().indexOf("copyright") < 0)
      out.sections.push(section)
  }

  out.ok = out.sections.length > 0
  return out
}

// Group parsed sections into three display tabs. The Gospel Acclamation is
// merged ahead of the Gospel text; empty groups are dropped so, e.g., a
// Gospel-only day renders a single tab.
function buildReadingTabs(sections) {
  var groups = [
    { key: "reading", label: "READING", sections: [] },
    { key: "psalm", label: "PSALM", sections: [] },
    { key: "gospel", label: "GOSPEL", sections: [] }
  ]
  var byKey = {}
  for (var i = 0; i < groups.length; i++) byKey[groups[i].key] = groups[i]

  for (var j = 0; j < sections.length; j++) {
    var label = String(sections[j].label || "")
    var key
    if (/responsorial|psalm/i.test(label)) key = "psalm"
    else if (/acclamation|alleluia|sequence|tract/i.test(label)) key = "gospel"
    else if (/gospel/i.test(label)) key = "gospel"
    else key = "reading"
    byKey[key].sections.push(sections[j])
  }

  return groups.filter(function(g) { return g.sections.length > 0 })
}

// Plain-text rendering of one tab group for the clipboard.
function readingsToText(title, sections) {
  var out = [String(title || "Readings")]
  for (var i = 0; i < sections.length; i++) {
    var s = sections[i]
    var header = s.label + (s.citation ? " \u2014 " + s.citation : "")
    out.push("", header.toUpperCase())
    for (var j = 0; j < s.lines.length; j++) {
      out.push(s.lines[j].text)
    }
  }
  return out.join("\n")
}

// Liturgical colour → accent chip colors (kept muted to sit inside any theme).
function seasonColor(colourName) {
  var c = String(colourName || "").toLowerCase()
  if (c.indexOf("red") >= 0) return "#b05252"
  if (c.indexOf("green") >= 0) return "#6f996f"
  if (c.indexOf("violet") >= 0 || c.indexOf("purple") >= 0) return "#9678b0"
  if (c.indexOf("rose") >= 0) return "#c98a9a"
  if (c.indexOf("white") >= 0 || c.indexOf("gold") >= 0) return "#d8d4bc"
  return ""
}

// ---------------------------------------------------------------- podcast

// Official USCCB Daily Readings podcast (SoundCloud-hosted RSS).
function podcastRss() {
  return "https://feeds.soundcloud.com/users/soundcloud:users:838970026/sounds.rss"
}

function matchPodcast(xml, key) {
  xml = String(xml || "")
  if (!xml) return null
  var want = ("for " + monthDayYear(key)).toLowerCase()
  var items = xml.match(/<item>[\s\S]*?<\/item>/gi) || []
  for (var i = 0; i < items.length; i++) {
    var item = items[i]
    var titleM = item.match(/<title>([\s\S]*?)<\/title>/i)
    var title = titleM ? textOf(titleM[1]) : ""
    if (title.toLowerCase().indexOf(want) < 0) continue
    var encM = item.match(/<enclosure[^>]*url="([^"]+)"/i)
    if (!encM) continue
    var durM = item.match(/<itunes:duration>([\s\S]*?)<\/itunes:duration>/i)
    return {
      title: title,
      url: encM[1],
      durationSeconds: durationToSeconds(durM ? textOf(durM[1]) : "")
    }
  }
  return null
}

function durationToSeconds(s) {
  var parts = String(s || "").split(":").map(function(p) { return parseInt(p, 10) || 0 })
  if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2]
  if (parts.length === 2) return parts[0] * 60 + parts[1]
  return parts.length === 1 ? parts[0] : 0
}

function formatDuration(totalSeconds) {
  var s = Math.max(0, Math.round(totalSeconds))
  var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60
  if (h > 0) return h + ":" + pad2(m) + ":" + pad2(sec)
  return m + ":" + pad2(sec)
}

// ------------------------------------------------------------------ rosary

var MYSTERY_SETS = {
  joyful: ["The Annunciation", "The Visitation", "The Nativity", "The Presentation", "The Finding in the Temple"],
  sorrowful: ["The Agony in the Garden", "The Scourging at the Pillar", "The Crowning with Thorns", "The Carrying of the Cross", "The Crucifixion"],
  glorious: ["The Resurrection", "The Ascension", "The Descent of the Holy Spirit", "The Assumption", "The Coronation of Mary"],
  luminous: ["The Baptism of the Lord", "The Wedding at Cana", "The Proclamation of the Kingdom", "The Transfiguration", "The Institution of the Eucharist"]
}

function rosaryMysteries(key) {
  var day = keyToDate(key).getDay()
  var setKey = (day === 0 || day === 3) ? "glorious"
    : (day === 2 || day === 5) ? "sorrowful"
    : (day === 4) ? "luminous"
    : "joyful"
  return {
    name: setKey.charAt(0).toUpperCase() + setKey.slice(1) + " Mysteries",
    decades: MYSTERY_SETS[setKey],
    days: "Prayed " + ({ 0: "Sundays & Wednesdays", 1: "Mondays & Saturdays", 2: "Tuesdays & Fridays", 3: "Sundays & Wednesdays", 4: "Thursdays", 5: "Tuesdays & Fridays", 6: "Mondays & Saturdays" }[day])
  }
}

// ------------------------------------------------------------------ streak

function emptyStreak() {
  return { count: 0, best: 0, lastMarked: "", lastReminder: "" }
}

function parseStreakFile(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return emptyStreak()
    return {
      count: parseInt(data.count, 10) || 0,
      best: parseInt(data.best, 10) || 0,
      lastMarked: typeof data.lastMarked === "string" ? data.lastMarked : "",
      lastReminder: typeof data.lastReminder === "string" ? data.lastReminder : ""
    }
  } catch (e) {
    return emptyStreak()
  }
}

// Marking read on a fresh day extends an unbroken chain; anything else
// restarts at 1. Returns the full next state to persist.
function markRead(state, todayK) {
  var s = state || emptyStreak()
  if (s.lastMarked === todayK) return s
  var yesterday = shiftKey(todayK, -1)
  var count = (s.lastMarked === yesterday) ? s.count + 1 : 1
  return {
    count: count,
    best: Math.max(s.best || 0, count),
    lastMarked: todayK,
    lastReminder: s.lastReminder || ""
  }
}
