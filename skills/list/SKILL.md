---
description: List the feedme sound sets and show which one is active
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/feedme.sh:*)
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/feedme.sh" list`

Relay the feedme output above to the user as it is, in a short code block. Do not run any other command.
