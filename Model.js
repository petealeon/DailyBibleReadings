// Data helpers for peter.bible: date math, USCCB Daily Readings RSS parsing
// (full NAB-RE text), USCCB/SoundCloud podcast RSS matching, rosary mysteries,
// and per-day activity state.

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
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
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

// ------------------------------------------------------- USCCB readings RSS

// Official USCCB Daily Readings feed: full NAB-RE text, ~10-day rolling window.
// Display of this feed is permitted by the USCCB RSS policy for free,
// non-gated services; text is fetched per-user at runtime and cached locally.
function usccbRss() {
  return "https://bible.usccb.org/readings.rss"
}

// Parse the feed into { byDate: {key: parsed}, order: [keys] } where parsed is
// { title, sections: [{label, citation, lines: [{text, italic}]}], memorials }.
function parseUsccbRss(xml) {
  var out = { byDate: {}, order: [] }
  xml = String(xml || "")
  var items = xml.match(/<item>[\s\S]*?<\/item>/gi) || []

  for (var i = 0; i < items.length; i++) {
    var item = items[i]
    var parsed = parseUsccbItem(item)
    if (parsed && parsed.key && parsed.ok && !out.byDate[parsed.key]) {
      out.byDate[parsed.key] = parsed
      out.order.push(parsed.key)
    }
  }
  out.order.sort()
  return out
}

function parseUsccbItem(item) {
  var titleM = item.match(/<title>([\s\S]*?)<\/title>/i)
  var descM = item.match(/<description>([\s\S]*?)<\/description>/i)
  if (!descM) return null

  var key = dateKeyFromItem(item)
  if (!key) return null

  var html = decodeEntities(descM[1])

  // Optional memorials are listed as nested links before the readings.
  var memorials = []
  var nested = html.match(/<ul class="nested">([\s\S]*?)<\/ul>/i)
  if (nested) {
    var links = nested[1].match(/<a[^>]*>([\s\S]*?)<\/a>/gi) || []
    for (var n = 0; n < links.length; n++) {
      var name = textOf(links[n])
      if (name) memorials.push(name.replace(/^Readings for the /i, ""))
    }
    html = html.replace(/<ul class="nested">[\s\S]*?<\/ul>/i, "")
  }

  // Everything after the "- - -" separator is the copyright block; drop it.
  var cut = html.indexOf("- - -")
  if (cut >= 0) html = html.slice(0, cut)

  var sections = []
  var chunks = html.split(/<h4[^>]*>/i)
  for (var c = 1; c < chunks.length; c++) {
    var close = chunks[c].indexOf("</h4>")
    if (close < 0) continue
    var header = chunks[c].slice(0, close)
    var body = chunks[c].slice(close + 5)

    var citeM = header.match(/<a[^>]*>([\s\S]*?)<\/a>/i)
    var label = textOf(header.replace(/<a[^>]*>[\s\S]*?<\/a>/i, ""))
    var citation = citeM ? textOf(citeM[1]) : ""
    if (!label) continue

    var section = { label: label, citation: citation, lines: [] }
    var paras = body.match(/<p[^>]*>([\s\S]*?)<\/p>/gi) || []
    for (var p = 0; p < paras.length; p++) {
      var inner = paras[p].replace(/<\/?p[^>]*>/gi, "")
      var rawLines = inner.split(/<br\s*\/?>/i)
      for (var l = 0; l < rawLines.length; l++) {
        var line = textOf(rawLines[l])
        if (!line) continue
        // Collapse consecutive identical responses (psalm/alleluia refrains).
        var prev = section.lines[section.lines.length - 1]
        if (prev && prev.text === line) continue
        var italic = /<em[\s>]/i.test(rawLines[l])
        section.lines.push({ text: line, italic: italic })
      }
    }
    if (section.lines.length > 0) sections.push(section)
  }

  return {
    key: key,
    title: titleM ? textOf(titleM[1]) : "",
    sections: sections,
    memorials: memorials,
    ok: sections.length > 0
  }
}

// Prefer the MMDDYY.cfm pattern in the link/guid (no timezone ambiguity);
// fall back to the item's pubDate interpreted as a local date.
function dateKeyFromItem(item) {
  var m = item.match(/(\d{2})(\d{2})(\d{2})\.cfm/)
  if (m) return "20" + m[3] + "-" + m[1] + "-" + m[2]
  var pub = item.match(/<pubDate>([\s\S]*?)<\/pubDate>/i)
  if (pub) {
    var d = new Date(pub[1])
    if (!isNaN(d.getTime()))
      return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
  }
  return ""
}

// Group parsed sections into three display tabs. The Alleluia/Gospel
// Acclamation is merged ahead of the Gospel text; empty groups are dropped so
// a Gospel-only day renders a single tab.
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
    else if (/reading/i.test(label)) key = "reading"
    else if (/alleluia|acclamation|gospel/i.test(label)) key = "gospel"
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

// Liturgical colour name (from the bundled calendar) → muted accent hex that
// sits comfortably inside any theme.
function liturgicalColourHex(name) {
  var c = String(name || "").toLowerCase()
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

// Parse the whole podcast feed into { dateKey: {title, url, durationSeconds} }.
// Episode titles carry the date: "Daily Mass Reading Podcast for August 26, 2026".
function matchAllPodcasts(xml) {
  xml = String(xml || "")
  if (!xml) return null
  var items = xml.match(/<item>[\s\S]*?<\/item>/gi) || []
  var out = {}
  for (var i = 0; i < items.length; i++) {
    var item = items[i]
    var titleM = item.match(/<title>([\s\S]*?)<\/title>/i)
    var title = titleM ? textOf(titleM[1]) : ""
    var dateM = title.match(/for\s+([A-Za-z]+\s+\d{1,2},\s*\d{4})/i)
    if (!dateM) continue
    var d = new Date(dateM[1])
    if (isNaN(d.getTime())) continue
    var key = d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
    var encM = item.match(/<enclosure[^>]*url="([^"]+)"/i)
    if (!encM) continue
    var durM = item.match(/<itunes:duration>([\s\S]*?)<\/itunes:duration>/i)
    out[key] = {
      title: title,
      url: encM[1],
      durationSeconds: durationToSeconds(durM ? textOf(durM[1]) : "")
    }
  }
  return Object.keys(out).length > 0 ? out : null
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
  glorious: ["The Resurrection", "The Ascension", "The Descent of the Holy Spirit", "The Assumption of Mary", "The Coronation of Mary"],
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

// --------------------------------------------------------------- activity

// Per-day interaction state: { done: {key: true}, viewedTabs: {key: [labels]},
// lastNotified: key }. A day becomes done when its podcast is played or all of
// its reading tabs have been opened.
function emptyActivity() {
  return { done: {}, viewedTabs: {}, lastNotified: "" }
}

function parseActivityFile(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return emptyActivity()
    return {
      done: data.done && typeof data.done === "object" ? data.done : {},
      viewedTabs: data.viewedTabs && typeof data.viewedTabs === "object" ? data.viewedTabs : {},
      lastNotified: typeof data.lastNotified === "string" ? data.lastNotified : ""
    }
  } catch (e) {
    return emptyActivity()
  }
}
