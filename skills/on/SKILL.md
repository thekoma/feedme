---
description: Turn the feedme alert on
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/feedme.sh:*)
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/feedme.sh" on`

Relay the feedme output above to the user as it is, in a short code block. Do not run any other command.
