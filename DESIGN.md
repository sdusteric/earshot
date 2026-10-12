---
name: Earshot
description: A voice that tells you which Claude Code session needs you, shown as a 24-hour dial around a particle orb on cool near-black glass.
colors:
  ground: "#0b0d12"
  raised: "#11141b"
  track: "#1c202b"
  tick: "#3b4152"
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
  headline:
    fontFamily: "SF Pro (system)"
    fontSize: "headline text style"
    fontWeight: 600
  body:
    fontFamily: "SF Pro (system)"
    fontSize: "body text style"
    fontWeight: 400
  callout:
    fontFamily: "SF Pro (system)"
    fontSize: "callout text style"
    fontWeight: 400
  label:
    fontFamily: "SF Pro (system)"
    fontSize: "caption2 text style"
    fontWeight: 500
rounded:
  row: "6px"
  callout: "10px"
  orb: "50%"
spacing:
  dial-padding: "16px"
  detail-gutter: "24px"
  ring-gap-max: "30px"
components:
  dial-callout:
    backgroundColor: "{colors.raised}"
    rounded: "{rounded.callout}"
    padding: "8px 10px"
    width: "230px"
  history-row:
    rounded: "{rounded.row}"
  orb-disc:
    backgroundColor: "#000000"
    rounded: "{rounded.orb}"
---

# Design System: Earshot

## Overview

**Creative North Star: "The Orb's Glass"**

Earshot is a menu bar app whose face is a particle orb on dark glass. The rest of the interface takes its ground and its colors from the orb: a cool near-black, and a small set of state hues that mean the same thing everywhere (blue for you, violet for working, amber for Earshot's voice). The Activity window always renders dark, whatever the system appearance, because the light points need a dark backing.

The Activity window is built around one idea: History keeps one day, so the day wraps around the orb as a 24-hour dial. It is not a sidebar of filters over a plain list. The dial fills the window height on the left. The right side is plain text on the same ground: the recap, two buttons, a strip where the newest line types in, and the list for the selected stretch. Everything outside the dial uses system type and system controls (grouped forms in Settings, native buttons, native list rows), so the app reads as a Mac app that has one custom object.

**Key Characteristics:**
- Cool near-black ground with a faint blue tint, never pure black except behind the orb disc.
- Color is state, not decoration. Each hue has one meaning and appears only where that state is shown.
- Dots, thin tracks, and hairline ticks. No cards around the dial, no icons on it.
- System type with one weight step for headlines (semibold).
- Motion is slow and tied to state: the orb turns while idle, the newest line types in letter by letter.

## Colors

A dark, cool ground with one bright blue, one amber, and the macOS system status hues. Saturated color is rare and always means something.

### Primary
- **You Blue** (#63c4ff): what you said, the outer "You" ring, and the orb while listening. Source: `DialPalette.you`, `OrbMode.listening`.
- **Voice Amber** (#ffbd6b): Earshot's own voice. The orb while speaking, the "now" tick and label, the shaded stretch since you last looked, and the dots for ordinary spoken lines. Source: `DialPalette.voice`, `OrbMode.speaking`.

### Secondary
- **Working Violet** (#ab8fff): the orb while it transcribes or works on a command. Source: `OrbMode.working`.

### Session state (system colors, adaptive)
- **Needs Orange** (system orange, shown approximately #ff9f0a): a session that needs you or waits on your answer; dots for need and reply lines. Need dots are larger (6pt against 4.5pt).
- **Failed Red** (system red, #ff453a): failed or stuck sessions, alert lines.
- **Done Green** (system green, #32d74b): finished sessions and done lines.
- **Session Working Blue** (system blue, #0a84ff): a session that is working. Closed or open sessions use the secondary label color.

### Neutral
- **Ground** (#0b0d12): the Activity window and the dial's dot halos.
- **Raised** (#11141b): the dial's hover callout.
- **Track** (#1c202b): ring tracks, dividers in the Activity window.
- **Tick** (#3b4152): hour ticks, the orb disc outline, the callout border (at 60%), and the hairline ring of a lane with no lines.
- **Orb White** (#f2f5ff, the orb's "white" choice): the orb's resting color in the Activity window while idle.

The orb's color can be set by the user (blue, purple, orange, green, pink, white) or left to follow state. The state mapping above is the default.

### Named Rules
**The One Meaning Rule.** A hue has one job. Blue is you, amber is Earshot, violet is working, and orange, red, green are session states. Do not use them as accents.

**The Amber Is Earshot Rule.** Amber marks Earshot's own voice and the stretch since you last looked. It does not mark warnings; orange does.

## Typography

**Display Font:** SF Pro, the system font (no custom face).
**Body Font:** SF Pro, the system font.
**Label/Mono Font:** SF Pro with monospaced digits for clock labels and counts.

**Character:** Plain system type. Hierarchy comes from size and a single step to semibold, not from a second family.

### Hierarchy
- **Recap** (semibold, 24pt, line spacing 2): the one line that says who needs you ("Blog needs you. Billing service finished.").
- **Headline** (system `headline`, semibold): the list title for the selected stretch, window and section titles.
- **Body** (system `body`, medium for session names): session names in the status panel.
- **Callout** (system `callout`): line text in lists and the dial callout; secondary color for replies and detail.
- **Label** (system `caption2`, medium, monospaced digits for time): ring names, clock labels every 6 hours, "now", callout metadata (tertiary color).

### Named Rules
**The One Weight Step Rule.** Headlines are semibold, ring names and "now" are medium or semibold at caption size, everything else is regular. No other weights.

**The System Type Rule.** Use the system font and text styles so Dynamic Type settings and macOS defaults apply. The one fixed size is the 24pt recap.

## Layout

The Activity window is two columns. Left: a square dial sized to the smaller of the window height minus 32pt and 56% of the window width, with 16pt padding. A divider in Track color separates it from the detail column. Right: the detail column with 24pt horizontal gutters, a recap block (22pt top, 18pt bottom), the list title row, a divider, then the scrolling list.

Inside the dial: the orb takes 30% of the dial size. The outer ring (You) sits 52pt in from the edge. Session rings step inward from it by up to 30pt each, newest session first, with at least 30pt between the innermost ring and the orb edge. Hour ticks sit outside the outer ring (20 to 25pt, 30pt for 6-hour marks) with labels at 33pt.

Settings uses SwiftUI grouped forms. The status panel is a compact list with 6pt-radius hover rows.

## Elevation & Depth

Mostly flat. Depth comes from tonal steps of the same cool ground (Ground, Raised, Track, Tick) and from the orb's own glass. The floating orb panel uses Liquid Glass forced to the dark appearance, with a circular corner radius and no system window shadow, because the glass draws its own. The only drop shadow in the Activity window is under the dial's hover callout (black 40%, radius 12, y offset 4). Dots carry a 2pt Ground halo so they stay separate from the ring beneath them.

### Named Rules
**The Tonal Depth Rule.** Raise a surface by stepping to the next neutral (Ground to Raised), not by adding a shadow. The callout is the one exception, since it floats over the dial.

## Shapes

Circles and arcs for everything on the dial: the orb disc, rings (14pt track, 6pt round-capped arcs), dots (4.5pt radius, 6pt for need lines, 1.4 times larger when matching a search). The orb disc is black, clipped to a circle, with a 1pt Tick outline. Rectangles are small: 10pt radius for the callout with a 1pt Tick border at 60%, 6pt for list row hover backgrounds. The menu bar icon is a small dotted sphere, the orb's shape, in black template pixels with depth shown by dot size and alpha (a center dot with a gap when the wake word listens).

## Components

### Day Dial (signature)
A 24-hour dial. Now is at the top and the past runs counterclockwise, a full turn back being one day. The outer ring is what you said; inside it, one ring per session, newest first, named just clockwise of now in the session's color. Each ring is a Track stroke with arcs from a session's first line to its last in its state color at 55% opacity. A gap of more than 30 minutes between lines breaks the arc, and an active session's last arc runs on to now. A single line still shows a 5-minute arc. Dots sit at each line's time, fade with age (down to 45% at a day old), and lines within 8pt of each other on one ring draw as one dot. The stretch since you last looked is shaded Voice Amber at 9% with a 2pt amber arc outside the ticks. A selected stretch is shaded white at 6%.

Interactions:
- Hover a dot (within 12pt) to read its line in the callout (230pt wide, up to 3 lines, reply under it, session and time below).
- Click a dot to select its moment; click elsewhere on the dial face to pick a stretch of the day. The list on the right follows the selection, and "Show the Whole Day" clears it.
- Click the orb in the center to talk. It listens for one command.
- The orb turns slowly while idle and rests in white.
- VoiceOver gets a summary of the dial and the orb is a button with the hint "Listens for one command".

### Orb
A particle sphere that changes color over 0.25 seconds between states (blue listening, violet working, amber speaking), with a soft radial glow and breathing. Floating panel: full size on dark glass. Activity window: smaller, on a black disc, resting white.

### Now strip
A callout-size line under the buttons. A line newer than 45 seconds sits here and the newest 20 seconds type in letter by letter (not when Reduce Motion is on). Afterwards it reads "Quiet since" plus the time, in secondary color, and the line joins the list.

### Buttons
System buttons at regular control size: "Say the Recap" and "Talk". "Show the Whole Day" is a link-style button. No custom button styling.

### History row and session row
Session name in body medium, state description in callout, last line in secondary callout (2 lines max). A state dot in the session's state color. Hover fills with primary at 6% in a 6pt rounded rectangle.

### Empty states
System `ContentUnavailableView` with a system symbol, a short title, and one sentence on what to do.

## Do's and Don'ts

### Do:
- **Do** start from Ground (#0b0d12) and its neutral steps for any new dark surface in the Activity window.
- **Do** take state colors from `DialPalette`, `OrbMode.rgb`, and `SessionStyle.color`, and keep their meanings.
- **Do** use system type styles and system controls; add one semibold step for headlines.
- **Do** keep motion tied to state (orb color change, idle turn, typing in) and honor Reduce Motion.
- **Do** give every dial element a VoiceOver summary or label, since the dial draws its dots in a canvas.

### Don't:
- **Don't** use amber, blue, or violet as general accents or button fills.
- **Don't** add a sidebar of filters or a card around the dial.
- **Don't** use a second type family or weights beyond regular, medium, and semibold.
- **Don't** add drop shadows to surfaces other than the hover callout.
- **Don't** let a ring arc claim work across a gap of more than 30 minutes between lines.

## Not canonized

The build carries two things that should not be copied to new surfaces: the dial's 6pt and 4.5pt dot sizes and several opacity values (0.09, 0.55, 0.2, 0.45) are tuned by eye in one file rather than shared tokens, and the status panel and dial use SwiftUI system colors that shift between appearances while the dial's own palette is fixed. Treat these as drift to consolidate, not as rules.
