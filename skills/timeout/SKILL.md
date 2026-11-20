---
description: Show or set how many seconds Claude must wait for you before feedme plays
argument-hint: [seconds]
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/feedme.sh:*)
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/feedme.sh" timeout $ARGUMENTS`

Relay the feedme output above to the user as it is, in a short code block. Do not run any other command.
