# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

(Earshot for Mac is a native macOS app, SwiftUI on macOS 26. The schema has no macOS value; `ios` stands for "Apple native, follow the HIG". It is not an iPhone app.)

## Users

Developers who run several Claude Code sessions at once and step away from the screen: to another app, another window, a call, the kitchen. Their job is to keep many agent sessions moving without watching each one, and to answer the moment a session needs them.

## Product Purpose

Earshot speaks up when a Claude Code session needs you, might be stuck, or finishes, and says what it got done. It takes voice commands back: send a session a prompt, ask what everyone is doing, stop a session, start one, and answer a permission prompt with yes or no. Success is never missing a session that waits on you, and never having to look to know where things stand.

## Positioning

A voice companion that lives beside Claude Code on the Mac: it hears the sessions through Claude Code's own hooks and talks to them through their sockets and the `claude` command, so it can both report and act, by voice, hands free. The voice runs on the Mac by default (Kokoro), with ElevenLabs optional.

## Operating Context

- Two parts in one repo: the Claude Code plugin (hooks, the decision logic for what to say, roll call and setup skills, a fallback voice) and Earshot for Mac (menu bar app: playback, listening, commands, approvals, the orb, the panel, Activity, Settings). The app is the product; the plugin's playback is frozen.
- The app installs, turns on, and updates the plugin through `claude plugin` commands.
- Listening: hold-to-talk hotkey (Right Option by default), an opt-in "Hey Earshot" wake word, clicking the orb in Activity. Follow-up windows for "which one?" and permission prompts.
- Full screen apps keep Earshot silent by default; calls hold its lines until they end.
- History: what Earshot said and what you said, as text, kept 24 hours on the Mac by default (0600 file), or until quit, or off. Audio is never saved.

## Capabilities and Constraints

- macOS 26 or later; menu bar app with no Dock icon; a floating orb panel; a menu bar panel; Activity and Settings windows; onboarding.
- Commands: send, status (roll call), stop, start, yes/no answers. Unknown or empty commands are never sent.
- Privacy: audio stays in memory, a ring buffer of about 10 seconds; transcripts never go into logs or diagnostics.
- Plan: open source plus a paid signed build, one-time price, likely Paddle, after voice commands ship. Not decided: price, store, licensing details.

## Brand Commitments

- Name: Earshot. Spoken lines and UI copy are plain and short, no em dashes, no hype.
- The particle orb is the product's face: a turning sphere of points on dark glass that pulses with the mic while listening and with Earshot's voice while speaking. Blue while listening, violet while working, amber while speaking, unless the user picks one color. The orb is the hero wherever it appears.
- The menu bar icon is a small dotted sphere drawn like the orb.

## Evidence on Hand

- Real content shapes: session names from project folders ("billing service", "blog"), lines like "Billing service finished: the migration ran and all tests pass.", replies like "Sent to blog.", roll calls.
- No users, testimonials, metrics, or press yet. Do not invent any.

## Product Principles

1. Never make the user look: what matters must be hearable, and what is shown must be readable at a glance.
2. Act, don't just report: every surface leads to doing something (replay, answer, send, talk).
3. Quiet by default: Earshot interrupts only for what needs the user, and steps back during calls and full screen.
4. Local and private first: the user's voice and words stay on the Mac unless they choose otherwise.

## Accessibility & Inclusion

VoiceOver announcements for listening states, Reduce Motion honored by the orb (no turning, brightness only), captions for every spoken line in history, keyboard reachable controls.
