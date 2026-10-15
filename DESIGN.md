---
name: Earshot
description: A voice that tells you which Claude Code session needs you, with an Activity window that works as an inbox of sessions on the orb's cool near-black glass and shows the day as a slim timeline strip.
colors:
  ground: "#0b0d12"
  raised: "#11141b"
  track: "#1c202b"
  tick: "#3b4152"
  hour-label: "#8f8f8f"
  you-blue: "#63c4ff"
  voice-amber: "#ffbd6b"
  working-violet: "#ab8fff"
  needs-orange: "#ff9f0a"
  failed-red: "#ff453a"
  done-green: "#32d74b"
  session-working-blue: "#0a84ff"
  orb-white: "#f2f5ff"
typography:
  recap:
    fontFamily: "SF Pro (system)"
    fontSize: "24px"
    fontWeight: 600
    lineHeight: 1.2
  title:
    fontFamily: "SF Pro (system)"
    fontSize: "title2 / title3 text styles"
    fontWeight: 600
  headline:
    fontFamily: "SF Pro (system)"
    fontSize: "headline text style"
    fontWeight: 600
  body:
    fontFamily: "SF Pro (system)"
    fontSize: "body text style"
    fontWeight: 400
    lineHeight: "+2pt line spacing"
  callout:
    fontFamily: "SF Pro (system)"
    fontSize: "callout text style"
    fontWeight: 400
  label:
    fontFamily: "SF Pro (system)"
    fontSize: "caption / caption2 text styles"
    fontWeight: 600
  code:
    fontFamily: "SF Mono (system monospaced)"
    fontSize: "callout text style"
    fontWeight: 400
rounded:
  row: "6px"
  code: "8px"
  field: "9px"
  callout: "10px"
  card: "12px"
  pill: "8px"
  orb: "50%"
spacing:
  brief-gutter: "36px"
  session-gutter: "28px"
  section-gap: "30px"
  card-padding: "16px"
  pending-padding: "14px"
  text-measure: "520px"
  brief-max-width: "900px"
  conversation-max-width: "860px"
  sidebar-ideal: "270px"
  timeline-track: "16px"
components:
  waiting-card:
    backgroundColor: "{colors.raised}"
    rounded: "{rounded.card}"
    padding: "16px"
  pending-box:
    backgroundColor: "{colors.raised}"
    rounded: "{rounded.card}"
    padding: "14px"
  timeline-track:
    backgroundColor: "{colors.track}"
    rounded: "{rounded.pill}"
    height: "16px"
  timeline-callout:
    backgroundColor: "{colors.raised}"
    rounded: "{rounded.callout}"
    padding: "8px 10px"
    width: "260px"
  code-block:
    backgroundColor: "{colors.raised}"
    typography: "{typography.code}"
    rounded: "{rounded.code}"
    padding: "8px 10px"
  table-block:
    backgroundColor: "{colors.raised}"
    typography: "{typography.callout}"
    rounded: "{rounded.code}"
    padding: "12px"
  reply-field:
    backgroundColor: "{colors.raised}"
    rounded: "{rounded.field}"
    padding: "8px 12px"
  away-row:
    rounded: "{rounded.row}"
    padding: "10px 8px"
  orb-disc:
    backgroundColor: "#000000"
    rounded: "{rounded.orb}"
    size: "96px"
---

# Design System: Earshot

## Overview

**Creative North Star: "The Orb's Glass"**

Earshot is a menu bar app whose face is a particle orb on dark glass. The rest of the interface takes its ground and its colors from the orb: a cool near-black, and a small set of state hues that mean the same thing everywhere (light blue for your words, violet for working, amber for Earshot's voice, orange for what needs you). The Activity window always renders dark, whatever the system appearance, because the light points need a dark backing.

The Activity window is an inbox for your sessions. A native sidebar lists the brief ("Since You Left"), today's history, and every session grouped by what it needs from you. The first page is the brief, written for the moment you come back: who is waiting on you, with the question and the answer controls right there, one line per session about what changed, and what you asked. Selecting a session swaps the detail for that session's own view: its last turns from its transcript, what it waits on you for, and a reply field. The day runs along the bottom of the brief as a slim timeline strip, the one custom drawn object besides the orb.

Everything else uses system type and system controls (the sidebar, buttons, text fields, grouped forms in Settings, `ContentUnavailableView` for empty states), so the app reads as a Mac app with two custom objects: the orb and the strip.

**Key Characteristics:**
- Cool near-black ground with a faint blue tint, never pure black except behind the orb disc.
- Color marks state only. Each hue has one meaning and appears only where that state is shown.
- Dots, thin tracks, and hairline rules in Track. Cards appear only around things that wait on you.
- System type with one weight step for headlines (semibold).
- Motion is slow and tied to state: the orb changes color with state and turns while idle.

## Colors

A dark, cool ground with one bright blue, one amber, and the macOS system status hues. Saturated color is rare and always means something.

### Primary
- **You Blue** (#63c4ff): what you said. The "You" label on your turns in a session, timeline dots for lines you spoke, and the orb while listening. Source: `ActivityPalette.you`, `OrbMode.listening`.
- **Voice Amber** (#ffbd6b): Earshot's own voice. The orb while speaking, the "now" label at the right end of the timeline, the shaded stretch since you last looked, and dots and session-view lines for Earshot's ordinary spoken lines. Source: `ActivityPalette.voice`, `OrbMode.speaking`.

### Secondary
- **Working Violet** (#ab8fff): the orb while it transcribes or works on a command. Source: `OrbMode.working`.

### Session state (system colors, adaptive)
- **Needs Orange** (system orange, shown approximately #ff9f0a): a session that needs you or waits on your answer. State dots, the state word in the session header and waiting cards, the count beside "Since You Left", the 1pt border on waiting cards and pending boxes (at 35%), and timeline dots for lines that ask you something. Those dots are larger (5pt radius against 3.5pt).
- **Failed Red** (system red, #ff453a): stuck or failed sessions, alert lines.
- **Done Green** (system green, #32d74b): finished sessions and done lines.
- **Session Working Blue** (system blue, #0a84ff): a session that is working. Open or closed sessions use the secondary label color.

### Neutral
- **Ground** (#0b0d12): the Activity detail pane, the window toolbar band on every page, and the timeline's bottom bar.
- **Raised** (#11141b): waiting cards, pending boxes, code and table blocks, the reply field, and the timeline hover callout.
- **Track** (#1c202b): the timeline track and its dot halos, the 1pt rules between header, conversation and composer, list dividers, the reply field's resting border.
- **Tick** (#3b4152): the orb disc outline, and the timeline callout border (at 60%).
- **Hour Label** (#8f8f8f, white at 56%): the 6-hour clock labels under the timeline, chosen to clear 4.5:1 on Ground.
- **Orb White** (#f2f5ff, the orb's "white" choice): the orb's resting color in the brief masthead while idle.

Text uses the system label colors: primary for content, secondary for everything informative but quieter (times, folders, state words, hints, replies, metadata).

The orb's color can be set by the user (blue, purple, orange, green, pink, white) or left to follow state. The state mapping above is the default.

### Named Rules
**The One Meaning Rule.** A hue has one job. Light blue is you, amber is Earshot, violet is working, and orange, red, green, system blue are session states. Do not use them as accents.

**The Amber Is Earshot Rule.** Amber marks Earshot's own voice and the stretch since you last looked. It does not mark warnings; orange does.

**The Secondary Floor Rule.** Text that carries information on Ground uses the secondary label color or brighter. Tertiary text measures about 2.2:1 on #0b0d12 and is too faint to read.

## Typography

**Display Font:** SF Pro, the system font (no custom face).
**Body Font:** SF Pro, the system font.
**Label/Mono Font:** SF Pro with monospaced digits for times and counts; the system monospaced face for code blocks.

**Character:** Plain system type. Hierarchy comes from size and a single step to semibold, not from a second family.

### Hierarchy
- **Recap** (semibold, 24pt, line spacing 2): the brief's one line that says who needs you ("Wedding needs you.").
- **Title** (system `title2` semibold for the session header name, `title3` semibold for names on waiting cards).
- **Headline** (system `headline`, semibold): section heads in the brief ("Waiting on You", "While You Were Away", "What You Asked"), "Progress Notes" in a session, and headings inside Claude's messages.
- **Body** (system `body`, line spacing 2): Claude's and your turns, questions on waiting cards. Session names use medium in the sidebar and semibold in away rows.
- **Callout** (system `callout`): sidebar second lines, away-row times, job notes, Earshot's lines in a session, table cells, the subline under the recap.
- **Label** (system `caption` and `caption2`): "You" and "Claude" in caption semibold, turn times and sidebar ages in caption with monospaced digits, the composer hint, the timeline's hour labels (caption2, monospaced digits) and "now" (caption2 semibold).
- **Code** (system monospaced at callout size): fenced code in Claude's messages, in secondary color.

A turn in a session is capped at a 520pt measure, about 70 characters a line.

### Named Rules
**The One Weight Step Rule.** Headlines and titles are semibold, names are medium or semibold, everything else is regular. No other weights.

**The System Type Rule.** Use the system font and text styles so Dynamic Type settings and macOS defaults apply. The one fixed size is the 24pt recap.

## Layout

The Activity window is a `NavigationSplitView`, at least 900 by 600pt. The sidebar column runs 240 to 340pt (270 ideal) on the system sidebar material, with the search field ("Search what was said") at its top. The detail pane sits on Ground, and the toolbar band above it is filled with Ground on every page so the window has one ground.

Sidebar order: "Since You Left" (with an orange count of sessions waiting on you) and "Today's History" first, then session groups in the order you would act on them: Needs You, Stuck or Failed, Working, Finished, Open. Empty groups are left out. Open is collapsible, collapsed by default, and its header shows its count ("Open · 11").

The brief scrolls in a column with 36pt side gutters, 28pt top and 24pt bottom padding, a 900pt maximum width aligned left, and 30pt between sections. The day timeline is pinned to the bottom of the brief under a 1pt Track rule, with the same 36pt gutters, 12pt above and 16pt below.

The session view stacks header, conversation and composer, separated by 1pt Track rules. Header and composer use 28pt side gutters (16pt and 14pt vertical). The conversation uses 28pt gutters and 20pt vertical padding, a maximum width of 860pt, 14pt between items, and opens scrolled to the bottom. Each turn, its code and tables included, stops at the 520pt measure.

Today's History is a single column of rows with 28pt gutters, 9pt vertical padding and inset Track dividers, up to 900pt wide.

The menu bar panel is 360pt wide on Ground: a header with the state-tinted menu icon (26pt), status line, Talk and mute; up to three waiting cards; the five highest-ranked other sessions; the last four lines (two while something waits); and a footer of buttons. Sections are separated by 1pt Track rules with 14pt gutters. Settings uses SwiftUI grouped forms.

## Elevation & Depth

Mostly flat. Depth comes from tonal steps of the same cool ground (Ground, Raised, Track, Tick) and from the orb's own glass. The menu bar panel is forced dark on Ground, like Activity. The floating orb panel uses Liquid Glass forced to the dark appearance, with a circular corner radius and no system window shadow, because the glass draws its own. The only drop shadow in the Activity window is under the timeline's hover callout (black 40%, radius 12, y offset 4), since it floats over the brief. Timeline dots carry a 1.5pt Track halo so close neighbours stay separate.

### Named Rules
**The Tonal Depth Rule.** Raise a surface by stepping to the next neutral (Ground to Raised), not by adding a shadow. The timeline callout is the one exception.

## Shapes

Circles for state: 8pt state dots in the sidebar, away rows and waiting cards, 9pt in the session header; timeline dots at 3.5pt radius (5pt for lines that ask you). The orb disc is black, clipped to a circle, with a 1pt Tick outline. The timeline track is a 16pt pill.

Rectangles have small, graded radii: 6pt for row hover fills, 8pt for code and table blocks, 9pt for the reply field, 10pt for the timeline callout (1pt Tick border at 60%), and 12pt for waiting cards and pending boxes. Anything that waits on you gets a 1pt orange border at 35%; nothing else carries a colored border.

The menu bar icon is a small dotted sphere, the orb's shape, in black template pixels with depth shown by dot size and alpha (a center dot with a gap when the wake word listens).

## Components

### Day Timeline (signature)
The last 24 hours as a slim strip along the bottom of the brief: the old dial unrolled, with now at the right end. A 16pt Track pill holds a dot per line at its time, in the line's color (light blue for what you said, orange for lines that ask you, red for alerts, green for done, amber for the rest of Earshot's voice). Lines within 14pt of each other draw as one dot, the newest standing for the rest. The stretch since you last looked (when longer than a minute) is shaded Voice Amber at 13%, starting at a 1.5pt amber line at 70%. Clock labels sit every 6 hours below the track in Hour Label, dropped within 3 hours of now, and "now" sits at the right end in amber.

Interactions:
- Hover within 10pt of a dot to read its line in the callout: 260pt wide, up to 3 lines of callout text, then session, time and "+N more" in caption secondary.
- Click a dot to open its session, or Today's History for a line with no session.
- VoiceOver reads one summary of the day (how often Earshot spoke and you asked), since the strip draws in a canvas.

### Orb
A particle sphere that changes color over 0.25 seconds between states (blue listening, violet working, amber speaking), with a soft radial glow and breathing. Floating panel: 112pt on dark glass. Brief masthead: 96pt on a black disc, resting white, turning slowly while idle. Clicking it listens for one command (VoiceOver: a button named "Talk" with the hint "Listens for one command").

### Brief masthead
The orb, 22pt of space, then the recap (24pt semibold), a callout secondary subline ("You were away 8 hours. 2 sessions are still working."), and the system buttons "Talk" and "Say the Recap". When Talk cannot be heard, the reason sits beside the buttons in callout secondary.

### Waiting cards
One card per thing waiting on you, under the "Waiting on You" headline. Raised fill, 12pt radius, 16pt padding, 1pt orange border at 35%. The top line: an 8pt orange dot, the session name in title3 semibold, the state in orange, "waiting N minutes" in callout secondary, and an "Open Session" link button at the right. Below it, the answer in place:
- **Permission prompt:** "Deny" and "Allow" system buttons; Allow is the default action when it is the only one.
- **Open question:** the question in body, then an inline rounded-border text field ("Answer <session>"), "Send", and "Open in <app>". A question with fixed choices lists them in callout secondary and offers "Pick an Answer in <app>" instead of the field, since the choices wait on a picker in the session's own window.
- When nothing waits, a secondary "Nothing is waiting on you." label with a checkmark replaces the section.

### While You Were Away rows
One row per session that changed since you looked, under "While You Were Away" ("Right Now" when you have only just left). An 8pt state dot, the name in semibold in a 150pt column, a lead in primary ("Finished.", "Working, 12 minutes in.", "Might be stuck.", "Hit an error.") followed by the newest line or transcript turn in secondary (2 lines max), and the time in callout secondary with monospaced digits. 10pt vertical and 8pt horizontal padding, Track dividers between rows, hover fill of primary at 5% in a 6pt rounded rectangle. Clicking opens the session.

### What You Asked
The last three things you said since you left, as history rows: a symbol, your words in quotes, Earshot's reply in callout secondary, session and time, and a replay button.

### Session view
- **Header:** a 9pt state dot, the name in title2 semibold, the state word (orange when it needs you, secondary otherwise), the folder in callout secondary truncated at the head, and at the right a system button with the window symbol: "Show in <app>" for a session in a terminal window, "Open in Terminal" for a background session.
- **Turns:** read from the session's own transcript and refreshed every few seconds. Each turn has "You" (caption semibold, You Blue) or "Claude" (caption semibold, secondary) with its time, then the message. Claude's markdown is rendered: `#` lines as headlines, inline bold, code and links styled, fenced code in a Raised block (monospaced callout, secondary, 8pt radius), and tables as a grid (header row semibold primary, cells secondary, a Track divider under the header, Raised fill, 8pt radius, 12pt padding). Text is selectable.
- **Job notes:** a background job's notes read as one log under a single "Progress Notes" headline: a 72pt time column in monospaced callout secondary, then the note in callout secondary. No speaker label.
- **Work lines:** a hammer symbol and the summary in callout secondary.
- **Earshot's lines:** in time order among the turns, with a waveform symbol and the text in the line's color, plus a replay button.
- **Pending box:** what the session waits on you for, at the end of the conversation. Raised, 12pt radius, 14pt padding, full width, 1pt orange border at 35%. A permission prompt shows its sentence in medium with Deny and Allow; a question shows it in medium with "Type your answer below" or its choices and "Pick an Answer in <app>".
- **Reply field:** a plain, growing text field (1 to 6 lines) on Raised with a 9pt radius and 1pt Track border that turns to the accent color at 60% while focused, then "Send" (Command-Return). Under it, a caption secondary hint or the result of the last send.

### Sidebar session row
An 8pt state dot, the name in medium, the age at the right in caption monospaced secondary ("now", "4m", "2h"), and one line under it in callout secondary: the last thing Earshot said about it, or Claude Code's title for it. Two sessions with the same name add "Started <time>" to tell them apart.

### Menu bar panel
A compact panel that always renders dark on Ground, whatever the system appearance, so its waiting cards and state colors read exactly as they do in Activity, and opening Activity from it never changes the ground.

- **Header:** the menu icon tinted by the orb's state color (blue listening, violet working, amber speaking or holding lines, secondary when muted), "Earshot" in headline, the status line in callout secondary, then a Talk button (mic symbol) and the mute menu.
- **Waiting on You** comes first whenever anything waits, with its count in orange. Up to three compact waiting cards (Raised, 12pt radius, 12pt padding, 1pt orange border at 35%), then "N more waiting in Activity". Each card's top line is an 8pt orange dot, the name in body semibold, and the wait in callout secondary ("4m"). A permission prompt says what it wants in callout ("Wants to run the migration") above "Open Session", Deny and Allow; Return allows only when that prompt is the only thing waiting. A question shows itself in callout and a one-line rounded-border field ("Answer <session>") with Send; a question with fixed choices lists them in callout secondary and offers "Pick an Answer in <app>" instead.
- **Sessions:** ranked (needs you, then stuck or failed, then working, then the rest), leaving out the ones in waiting cards; only the first five show, followed by an "N more in Activity" link. Each row: an 8pt state dot, name in body medium, state in callout (orange when it needs you), last line in callout secondary (2 lines max), and a hover fill of primary at 5% in a 6pt rounded rectangle. Clicking a row opens that session in Activity.
- Section titles are subheadline semibold secondary; counts beside them are secondary, or orange for what waits on you.

### Buttons
System buttons at regular control size. "Open Session" and "N more in Activity" are link-style buttons. No custom button styling.

### Empty states
System `ContentUnavailableView` with a system symbol, a short title, and one sentence on what to do ("This session has closed", "Nothing to show yet", "History is off").

## Do's and Don'ts

### Do:
- **Do** start from Ground (#0b0d12) and its neutral steps for any new dark surface in the Activity window, including the toolbar band.
- **Do** take state colors from `ActivityPalette.color`, `OrbMode.rgb`, and `SessionStyle.color`, and keep their meanings.
- **Do** use system type styles and system controls; add one semibold step for headlines and titles.
- **Do** use secondary text, never tertiary, for anything informative on Ground.
- **Do** cap a turn at the 520pt measure, its code and tables included.
- **Do** put anything that waits on you in a Raised card with a 12pt radius and a 1pt orange border at 35%, with its answer controls inside it.
- **Do** keep motion tied to state (orb color change, idle turn) and honor Reduce Motion.
- **Do** give canvas-drawn elements, such as the timeline, a VoiceOver summary.

### Don't:
- **Don't** use amber, blue, or violet as general accents or button fills.
- **Don't** put the day back as a hero object or add a sidebar of filters; the day stays a slim strip at the bottom of the brief.
- **Don't** use a second type family or weights beyond regular, medium, and semibold.
- **Don't** add drop shadows to surfaces other than the timeline callout.
- **Don't** give a colored border to anything that does not wait on you.
- **Don't** label background-job notes with a speaker; they are a log.
- **Don't** show Claude's markdown as raw syntax (pipes, asterisks, backticks).
- **Don't** let timeline dots closer than 14pt draw separately; their halos cut into each other.

## Not canonized

The build carries a few things that should not be copied to new surfaces. `NowStrip` in ActivityStyle.swift is no longer used by any view. Several opacities are tuned by eye in single files rather than shared (0.13 and 0.7 on the timeline, 0.35 on the orange border, 0.05 for row hover fills). The sidebar uses adaptive system colors while the Activity palette is fixed. Treat these as drift to consolidate, not as rules.
