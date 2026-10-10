---
name: rollcall
description: Say what every open Claude Code session is doing, the sessions that need you first. Runs when the user types /earshot:rollcall.
disable-model-invocation: true
---

Earshot is reading this roll call aloud:

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/speak.sh" rollcall --print`

Show the roll call above to the user exactly as written, as one short paragraph, and add nothing else. Do not end with a 🗣 line.
