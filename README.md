# Bible Widget for Omarchy

An [Omarchy](https://omarchy.org) shell plugin (Quickshell) that puts your daily
prayer routine in the menu bar: the verse of the day, the day's Catholic Mass
readings, the official Daily Mass Reading podcast with a full player, a rosary
reminder, and a reading-streak tracker.

![widget](https://img.shields.io/badge/omarchy-shell%20plugin-blue)

## Features

- **Verse of the day** — from OurManna, with a deterministic bible-api fallback
  so there is always a verse, even offline (cached per day).
- **Daily Mass readings** — full text (First Reading, Psalm, Gospel) parsed
  from universalis.com, grouped into tabs, with a COPY button for each tab.
- **Liturgical info** — day title, rank, saint of the day, and the day's
  liturgical colour as a tinted chip (green, white, red, violet, rose).
- **Rosary mysteries** — the day's mystery set with all five decades.
- **Podcast player** — the USCCB Daily Mass Reading podcast, streamed via mpv:
  play/pause, skip-to-start, back 10 seconds, download to `~/Downloads`, and a
  draggable seek slider with live progress.
- **Reading streak** — mark the day as done and keep the chain going; the
  widget tracks current and best streak, and can remind you via a
  notification once per day.
- **Day navigation** — browse readings and podcasts up to 7 days back or
  forward (e.g. for a Sunday vigil). Playback follows the selected day.

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

The installer copies the plugin into `~/.config/omarchy/plugins/peter.bible/`,
enables and places the widget in the centre bar section, and restarts the
shell. Remove it again any time with:

```bash
omarchy plugin remove peter.bible
# or, if it was installed manually:
./install.sh --remove
```

### Dependencies

`mpv`, `socat`, `curl` and `wl-copy` (all usually present on Omarchy;
`install.sh` checks and tells you the `omarchy pkg add` line for anything
missing).

## Usage

| Action | Result |
| --- | --- |
| Click the cross in the bar | Open/close the panel |
| Right-click the cross | Verse of the day as a notification |
| Middle-click the cross | Force-refresh today's data |
| `MARK AS DONE` / `DONE` | Mark today read (streak) and close the panel |
| `<` / `TODAY` / `>` | Navigate between days; live playback follows |

### IPC

Every action is scriptable through the shell IPC:

```bash
omarchy-shell peter.bible toggle     # open/close
omarchy-shell peter.bible verse      # verse notification
omarchy-shell peter.bible play       # play/pause podcast
omarchy-shell peter.bible stop
omarchy-shell peter.bible markRead
omarchy-shell peter.bible refresh
omarchy-shell peter.bible debug      # JSON state dump
```

### Settings

Widget settings live in the bar layout entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "peter.bible", "reminderEnabled": true, "reminderHour": 8,
  "refreshMinutes": 30, "fallbackTranslation": "web" }
```

- `reminderEnabled` / `reminderHour` — one daily notification after this hour
  when the day is not yet marked read.
- `refreshMinutes` — background refresh cadence (minimum 5).
- `fallbackTranslation` — bible-api.com translation used by the offline verse
  fallback (default `web`).

State (streak, per-day caches) lives under `~/.local/state/omarchy/bible/`.
