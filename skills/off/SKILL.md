---
description: Turn the feedme alert off
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/feedme.sh:*)
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/feedme.sh" off`

Relay the feedme output above to the user as it is, in a short code block. Do not run any other command.
