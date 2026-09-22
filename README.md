# Bible Widget for Omarchy

An [Omarchy](https://omarchy.org) menu-bar widget (built with Quickshell/QML) for the Catholic daily Mass: a liturgical month calendar, the full day's readings, and the official USCCB Daily Mass Reading podcast — with text and audio in the same translation (NAB-RE).

## Features

- **Liturgical month calendar** — every day colour-coded by liturgical colour, generated locally from the [romcal](https://github.com/romcal/romcal) calendar (2026–2030 bundled). Click any day to open its readings and podcast; browse months in either direction.
- **Daily readings** — Reading 1, Responsorial Psalm, Alleluia, Gospel, and Reading 2 on Sundays, grouped into tabs with a COPY button.
- **Podcast player** — the official USCCB Daily Mass Reading Podcast (same NAB-RE text, read aloud): play/pause, skip back 10 seconds, download, and a seek slider.
- **Done marks** — days you engage with (play the podcast or open every reading tab) get a faint green ring in the calendar.
- **Daily reminder** — one notification per day after a configurable hour if today's readings are still waiting.
- **Rosary mysteries** — the day's mystery set with all five decades.
- **Saints & feasts** — names and liturgical colours from the bundled calendar, including optional memorials from the USCCB feed.

## Install

On an Omarchy system:

```bash
omarchy plugin add https://github.com/petealeon/DailyBibleReadings.git --enable
```

Or clone this repository and run the manual installer:

```bash
./install.sh
```

Remove it any time with `omarchy plugin remove petealeon.dailybiblereadings` (or `./install.sh --remove`).

Dependencies: `mpv`, `socat`, `curl`, and `wl-copy` (usually already present; `install.sh` checks and prints the install command for anything missing).

Optional: a per-day fetch helper that backfills readings for days outside the feed window — set `fetchToolPath` in [Settings](#settings). The panel works without it, opening the public page instead.

## Usage

| Action | Result |
| --- | --- |
| Click the cross in the bar | Open/close the panel |
| Right-click the cross | Today's readings summary as a notification |
| Middle-click the cross | Force-refresh the feeds |
| Click a calendar day | Open that day's readings/podcast |
| ◀ / ▶ beside the month | Browse months (2026–2030) |
| TODAY | Jump back to today |
| Play a podcast / open every tab | Marks the day with a green ring |
| CREDITS | Sources, copyright, and links |

Full reading text is available for the USCCB feed's ~10-day window; podcast playback reaches much further (roughly June 2025 onward, plus scheduled future episodes). For days outside the feed window the panel offers a **FETCH TEXT** button — with the optional helper it pulls and caches that day's official page; without it, it opens the public page. Everything you open is cached locally for offline use.

## Settings

Widget settings live in the bar layout entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "petealeon.dailybiblereadings", "reminderEnabled": true, "reminderHour": 8,
  "refreshMinutes": 30, "tintLevel": 1.0 }
```

- `fetchToolPath` — path to a helper that fetches one day's readings text from the USCCB site for days outside the RSS feed window; defaults to `""` (disabled).
- `tintLevel` — 0–1 (default 1): how far liturgical accent colours are adjusted to stay legible on light themes.

State (per-day activity, feed caches) lives under `~/.local/state/omarchy/petealeon.dailybiblereadings/`.

## Development

The bundled `LectionaryCalendar.js` covers 2026–2030. To extend or rebuild it (node + npm required):

```bash
cd tools && npm install && node generate-calendar.cjs
```

## Credits & Copyright

- **Readings text** — [bible.usccb.org](https://bible.usccb.org/bible/readings): New American Bible, Revised Edition. Lectionary for Mass for Use in the Dioceses of the United States, second typical edition, Copyright © 2001, 1998, 1997, 1986, 1970 Confraternity of Christian Doctrine; Psalm refrain © 1968, 1981, 1997, International Committee on English in the Liturgy, Inc. All rights reserved. Fetched at runtime per user from the official USCCB RSS feed, whose display for free, non-gated services is permitted by the [USCCB RSS policy](https://www.usccb.org/subscribe/rss). Days the feed does not reach are fetched at runtime from their official per-day page — a few hundred words of scripture each, licensed by the NAB permissions guidelines for use in web formats — and never embedded in the widget.
- **Readings audio** — [USCCB Daily Mass Reading Podcast](https://bible.usccb.org/podcasts/audio), © United States Conference of Catholic Bishops; unaltered episodes streamed from the official feed.
- **Liturgical calendar data** — [romcal](https://github.com/romcal/romcal) (MIT), regenerated into the bundled calendar by `tools/generate-calendar.cjs`.

This widget is an independent personal project. It is **not affiliated with, endorsed by, or sponsored by** the USCCB or any Bible publisher. Scripture text and audio remain © their respective publishers; the widget ships with no text or audio embedded and retrieves everything from the sources above for personal, non-commercial use.

## License

[MIT](LICENSE) © petealeon. The widget's *code* is freely reusable; the scripture text and podcast audio it fetches remain under their publishers' copyright.