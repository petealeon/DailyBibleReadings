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

// Per-day readings page on the bishops' site, in the MMDDYY.cfm form the
// RSS items already embed (see dateKeyFromItem). History and scheduled days
// outside the ~10-day feed window stay reachable through this public page.
function usccbDayUrl(key) {
  var parts = String(key || "").split("-")
  if (parts.length !== 3) return "https://bible.usccb.org/bible/readings"
  return "https://bible.usccb.org/bible/readings/"
    + pad2(parseInt(parts[1], 10)) + pad2(parseInt(parts[2], 10)) + parts[0].slice(2) + ".cfm"
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

// Split an HTML line into styled runs [{text, italic}] preserving <em>
// boundaries, so prose reflow can keep word-level italics. Runs outside any
// <em> keep italic=false; a run's text is the tag-stripped, whitespace-
// collapsed text (joining runs with a single space reproduces textOf(line)).
function lineRunsOf(html) {
  var runs = []
  var italic = false
  var parts = String(html || "").split(/(<em\b[^>]*>|<\/em>)/gi)
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    if (/^<em\b/i.test(part)) { italic = true; continue }
    if (part === "</em>") { italic = false; continue }
    var text = textOf(part)
    if (!text) continue
    runs.push({ text: text, italic: italic })
  }
  return runs
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
// { title, sections: [{label, citation, lines: [{text, italic, par, runs}]}],
//   memorials }. lines[].runs carries word-level italics for prose reflow;
// lines[].par is the <p> paragraph index the line belongs to.
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
        var runs = lineRunsOf(rawLines[l])
        if (runs.length === 0) continue
        var line = runs.map(function(r) { return r.text }).join(" ")
        // Collapse consecutive identical responses (psalm/alleluia refrains).
        var prev = section.lines[section.lines.length - 1]
        if (prev && prev.text === line) continue
        var italic = false
        for (var r = 0; r < runs.length; r++) if (runs[r].italic) { italic = true; break }
        section.lines.push({ text: line, italic: italic, par: p, runs: runs })
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

// ----------------------------------------------------------- contrast

// sRGB → linear for WCAG relative luminance. `c` is a 0..255 channel value.
function _linearChannel(c) {
  c /= 255
  return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
}

// Parse any string QML hands a colour property: "#rgb", "#rrggbb", "#aarrggbb"
// (Qt prepends the alpha octet), and "rgb()"/"rgba()". Alpha is ignored —
// contrast math compares composite swatches, not transparency.
function _parseColour(col) {
  var s = String(col || "").replace(/^\s+|\s+$/g, "")
  var m
  if ((m = s.match(/^#([0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/))) {
    var hex = m[1]
    if (hex.length === 3) hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2]
    else if (hex.length === 4) hex = hex[1] + hex[1] + hex[2] + hex[2] + hex[3] + hex[3]
    else if (hex.length === 8) hex = hex.substr(2) // drop leading alpha octet
    var rgb = []
    for (var i = 0; i < 3; i++) rgb.push(parseInt(hex.substr(i * 2, 2), 16))
    return isNaN(rgb[0]) || isNaN(rgb[1]) || isNaN(rgb[2]) ? null : rgb
  }
  if ((m = s.match(/^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,[^)]*)?\)$/i))) {
    return [parseInt(m[1], 10), parseInt(m[2], 10), parseInt(m[3], 10)]
  }
  return null
}

function _luminance(rgb) {
  return 0.2126 * _linearChannel(rgb[0]) + 0.7152 * _linearChannel(rgb[1]) + 0.0722 * _linearChannel(rgb[2])
}

// WCAG 2.2 contrast ratio between two parsed RGB triples.
function _contrast(a, b) {
  var la = _luminance(a), lb = _luminance(b)
  var hi = Math.max(la, lb), lo = Math.min(la, lb)
  return (hi + 0.05) / (lo + 0.05)
}

function _toHex(rgb) {
  function h(n) {
    n = Math.max(0, Math.min(255, Math.round(n)))
    return (n < 16 ? "0" : "") + n.toString(16)
  }
  return "#" + h(rgb[0]) + h(rgb[1]) + h(rgb[2])
}

function _toHsl(rgb) {
  var r = rgb[0] / 255, g = rgb[1] / 255, b = rgb[2] / 255
  var max = Math.max(r, g, b), min = Math.min(r, g, b)
  var l = (max + min) / 2
  var h = 0, s = 0
  if (max !== min) {
    var d = max - min
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
    if (max === r) h = (g - b) / d + (g < b ? 6 : 0)
    else if (max === g) h = (b - r) / d + 2
    else h = (r - g) / d + 4
    h /= 6
  }
  return [h, s, l]
}

function _fromHsl(hsl) {
  var h = hsl[0], s = hsl[1], l = hsl[2]
  var r, g, b
  if (s === 0) { r = g = b = l }
  else {
    function hue2rgb(p, q, t) {
      if (t < 0) t += 1
      if (t > 1) t -= 1
      if (t < 1 / 6) return p + (q - p) * 6 * t
      if (t < 1 / 2) return q
      if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6
      return p
    }
    var q = l < 0.5 ? l * (1 + s) : l + s - l * s
    var p = 2 * l - q
    r = hue2rgb(p, q, h + 1 / 3)
    g = hue2rgb(p, q, h)
    b = hue2rgb(p, q, h - 1 / 3)
  }
  return [r * 255, g * 255, b * 255]
}

// Shift a liturgical accent toward black (light surface) or white (dark
// surface) — preserving its hue and saturation — just far enough to hit the
// WCAG AA text threshold on `surface`. Passes any colour that already clears
// it through unchanged, so dark themes keep the full-strength liturgical tint.
// `tintLevel` (0..1) interpolates between the original colour and the fully
// corrected one; 1.0 guarantees the threshold, lower values trade legibility
// for a more saturated tint.
function liturgicalTintFor(surface, tint, tintLevel) {
  var bg = _parseColour(surface)
  var fg = _parseColour(tint)
  if (!bg || !fg) return String(tint || "")
  var level = isNaN(parseFloat(tintLevel)) ? 1.0 : Math.max(0, Math.min(1, parseFloat(tintLevel)))
  // Search with a small margin so rounding can't land the result a tick under
  // the 4.5 WCAG AA floor.
  var target = 4.6
  if (_contrast(fg, bg) >= target) return String(tint || "")

  var hsl = _toHsl(fg)
  // On a light surface contrast only improves as lightness drops, so the
  // pass region is [0, L]. On a dark surface it improves as lightness rises,
  // so the pass region is [L, 1]. Find the boundary — the correction
  // closest to the original colour that still clears the threshold.
  var darkSide = _luminance(bg) > 0.5
  var lo = 0.0, hi = 1.0
  var best = darkSide ? 0.0 : 1.0
  for (var iter = 0; iter < 32; iter++) {
    var l = (lo + hi) / 2
    var cand = _fromHsl([hsl[0], hsl[1], l])
    if (_contrast(cand, bg) >= target) {
      best = l
      if (darkSide) lo = l   // passing → may move closer to original (higher l)
      else hi = l            // passing → may move closer to original (lower l)
    } else {
      if (darkSide) hi = l
      else lo = l
    }
  }
  var lSafe = best
  // Reduce the shift according to `level`: blend between HSL(original) and
  // HSL(corrected) on the lightness axis so hue/saturation stay intact.
  var lFinal = hsl[2] + (lSafe - hsl[2]) * level
  var corrected = _fromHsl([hsl[0], hsl[1], lFinal])
  return _toHex(corrected)
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
