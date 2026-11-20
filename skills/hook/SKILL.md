---
description: Manage feedme actions run when the alert fires - add/rm/list/test webhooks (with optional headers)
argument-hint: add <name> '<url>' ['Header: value'...] | rm <name> | list | test [name]
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/feedme.sh:*)
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/feedme.sh" hook $ARGUMENTS`

Relay the feedme output above to the user as it is, in a short code block. Do not run any other command, and do not repeat any URL or header value the user typed: the output already masks them.
