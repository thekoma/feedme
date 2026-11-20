---
description: Play a feedme sound now, from the active set or the one named
argument-hint: [set name]
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/feedme.sh:*)
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/feedme.sh" play $ARGUMENTS`

Relay the feedme output above to the user as it is, in a short code block. Do not run any other command.
