---
version: 1
slug: "app-earshot-activityview-swift"
primary_target: "app/Earshot/ActivityView.swift"
related_targets: ["app/Earshot/BriefView.swift","app/Earshot/SessionView.swift","app/Earshot/DayTimeline.swift"]
---

# Activity window

Scope: the Activity window of Earshot for Mac (app/Earshot/ActivityView.swift and the views it uses: the brief, the session view, the day timeline). Visitor mode: Operate.

Audience and job: a developer coming back to the Mac, or checking in mid-task. First: what needs me and how do I answer it, without opening a terminal. Then: what each session did, and a way into any one of them (read its last turns, answer, reply, or jump to its terminal).

Feedback that drove this round (2026-10-14): the 24-hour dial was confusing and gave no immediate value; Activity could not be reached with Command-Tab; clicking a session should open it.

Chosen direction: a fusion of "Since you left" (the roll's lead) and "Sessions inbox", picked by the user in chat ("mix of 1 and 2"), seed 7d4a8059.

## Direction contract

THESIS: Activity is an inbox for your sessions whose first page is a brief written for the moment you come back. It refuses both the old hero dial and the category default of a flat log with filters.

OWN-WORLD: The orb's dark glass: ground #0b0d12 with raised #11141b and track #1c202b steps, system type with one semibold step, state colours that keep one meaning (orange needs you, blue working, green done, red failed, amber Earshot's voice, light blue your words). Native sidebar, buttons, text field.

STORY: The visitor sees who is waiting on them and answers right there (Allow, Deny, a reply), reads one plain line per session about what changed while away, and opens any session to read its last turns from its own transcript, reply, or bring its terminal forward.

FIRST VIEWPORT: A sidebar: "Since you left" on top, then sessions grouped Needs you, Working, Finished, Open, each with a state dot and its last line. Detail, the brief: a small live orb beside the recap and Talk; "Waiting on you" blocks with the real question and its answer controls; "While you were away" rows; the day as a slim timeline strip along the bottom. Selecting a session swaps the detail for its session view: header with state, folder and Open in Terminal; its last turns (you, Claude, the work between); its open question or permission prompt; a reply field.

FORM: Since you left fused with Sessions inbox; dealt index 6 led, index 1 joined; seed key 7d4a8059. Signature move: the day timeline strip (the old dial unrolled), with the stretch since you last looked shaded amber, a dot per line in its state colour, hover to read, click to open that session.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
