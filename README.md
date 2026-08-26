# Bible Widget for Omarchy

An [Omarchy](https://omarchy.org) shell plugin (Quickshell) that puts the
Catholic daily Mass readings in your menu bar: a liturgical month calendar,
the day's full readings, and the official Daily Mass Reading podcast — with
text and audio from the **same translation** (NAB-RE).

## Features

- **Liturgical month calendar** — every day colour-coded by liturgical colour
  (green, white, red, violet, rose), generated locally from the open-source
  [romcal](https://github.com/romcal/romcal) calendar (2026–2030 bundled;
  regenerate annually with the included script). Click any day to open its
  readings and podcast; months are browsable in both directions.
- **Daily Mass readings** — full text (Reading 1, Responsorial Psalm,
  Alleluia, Gospel, and Reading 2 on Sundays) from the official
  [USCCB Daily Readings feed](https://bible.usccb.org/bible/readings), grouped
  into tabs with a COPY button.
- **Podcast player** — the official [USCCB Daily Mass Reading
  Podcast](https://bible.usccb.org/podcasts/audio) (the same NAB-RE text,
  read aloud): play/pause, skip-to-start, back 10 seconds, download, and a
  draggable seek slider with live progress. The feed reaches ~14 months back
  and weeks ahead, so most calendar days are playable.
- **Passive "done" marks** — days you engage with (play the podcast, or click
  through every reading tab) get a faint green ring in the calendar. No
  scores, no streaks — just a quiet record of where you have been.
- **Daily reminder** — one notification per day after a configurable hour if
  today's readings are still waiting.
- **Rosary mysteries** — the day's mystery set with all five decades.
- **Saints & feasts** — saint/feast names and liturgical colours from the
  bundled calendar, including optional memorials from the USCCB feed.

## Text and audio always match

Both the readings text and the podcast audio come from the USCCB and are the
**New American Bible, Revised Edition**. No more following along in a
different translation.

## Install

On an Omarchy system, from any machine that can reach the repo:

```bash
omarchy plugin add <your-git-url>/BibleWidget.git --enable
```

Or clone/copy this folder somewhere on the machine and run the manual
installer:

```bash
./install.sh
```

Remove it again any time with `omarchy plugin remove peter.bible` (or
`./install.sh --remove`).

### Dependencies

`mpv`, `socat`, `curl` and `wl-copy` (all usually present on Omarchy;
`install.sh` checks and tells you the `omarchy pkg add` line for anything
missing).

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

Days are clickable as far as data actually reaches: full readings text for
the USCCB feed's ~10-day window, podcast playback across the podcast feed's
much larger range (roughly June 2025 onward, plus scheduled future episodes).
Everything you open is cached locally for offline use.

### IPC

```bash
omarchy-shell peter.bible toggle     # open/close
omarchy-shell peter.bible play       # play/pause podcast
omarchy-shell peter.bible stop
omarchy-shell peter.bible refresh
omarchy-shell peter.bible debug      # JSON state dump
```

### Settings

Widget settings live in the bar layout entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "peter.bible", "reminderEnabled": true, "reminderHour": 8,
  "refreshMinutes": 30 }
```

State (per-day activity, feed caches) lives under
`~/.local/state/omarchy/bible/`.

## Regenerating the liturgical calendar

The bundled `LectionaryCalendar.js` covers 2026–2030. To extend or rebuild it
(node + npm required, development machine only — the plugin itself needs
nothing):

```bash
cd tools && npm install && node generate-calendar.cjs
```

## Credits & Copyright

- **Readings text** — [bible.usccb.org](https://bible.usccb.org/bible/readings):
  New American Bible, Revised Edition. Lectionary for Mass for Use in the
  Dioceses of the United States, second typical edition, Copyright © 2001,
  1998, 1997, 1986, 1970 Confraternity of Christian Doctrine; Psalm refrain
  © 1968, 1981, 1997, International Committee on English in the Liturgy, Inc.
  All rights reserved. Fetched at runtime per user from the official USCCB
  RSS feed, whose display for free, non-gated services is permitted by the
  [USCCB RSS policy](https://www.usccb.org/subscribe/rss).
- **Readings audio** — [USCCB Daily Mass Reading
  Podcast](https://bible.usccb.org/podcasts/audio), © United States
  Conference of Catholic Bishops; unaltered episodes streamed from the
  official feed.
- **Liturgical calendar data** — [romcal](https://github.com/romcal/romcal)
  (MIT), regenerated into the bundled calendar by `tools/generate-calendar.cjs`.

This widget is an independent personal project. It is **not affiliated with,
endorsed by, or sponsored by** the USCCB or any Bible publisher. Scripture
text and audio remain © their respective publishers; the widget ships with no
text or audio embedded and retrieves everything from the sources above for
personal, non-commercial use. If you value the USCCB's work, consider
supporting the [Catholic Communication Campaign](https://www.usccb.org/committees/catholic-communication-campaign).

## License

[MIT](LICENSE) © Peter. The widget's *code* is freely reusable; the scripture
text and podcast audio it fetches remain under their publishers' copyright.
