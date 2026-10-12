---
version: 1
slug: "app-earshot-activityview-swift"
primary_target: "app/Earshot/ActivityView.swift"
related_targets: ["app/Earshot/DayDial.swift"]
---

# Activity window

Scope: the Activity window of Earshot for Mac (app/Earshot/ActivityView.swift and DayDial.swift). Visitor mode: Operate.

Audience and job: a developer coming back to the Mac after time away, or checking in mid-task. They need what they missed, what is happening now, what they told Earshot and what it did, and a searchable log, in one screen, without a chat look.

Chosen direction: Day Dial (seed 1a5c349f, dealt index 6, locked by the user in chat on 2026-10-12).

## Direction contract

THESIS: History keeps one day, so the day wraps around the orb as a 24-hour dial. It refuses the category default: a sidebar of filters over a plain list.

OWN-WORLD: The orb's dark glass ground, near black with a cool tint; the orb's state colors (blue listening and your words, violet working, amber Earshot's voice) plus session state colors (orange needs you, red failed, green done, blue working). System type, one weight step for headlines.

STORY: The visitor sees at a glance who needs them (the recap line), how the day went (dots around the dial, the shaded stretch since they last looked), and can hear any line again or talk by clicking the orb.

FIRST VIEWPORT: Left, a square dial filling the window height: now at the top, the past running counterclockwise, hour ticks with clock labels every 6 hours, one ring per session plus an outer ring for what you said, a dot per line, the stretch since you last looked shaded amber, the live orb at the center. Right, the recap ("Blog needs you. Billing service finished."), Say the Recap and Talk buttons, a now strip where the newest line types itself in, then the lines for the selected stretch.

FORM: Day Dial, rank 6 of 7 on the grounded list, seed 1a5c349f. Signature interaction: hover a dot to read its line; click the dial to pick a stretch of the day; click the orb to talk. Raise from the split-flap board: the newest line types in letter by letter.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
