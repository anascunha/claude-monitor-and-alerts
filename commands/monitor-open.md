---
description: Open the Claude Monitor floating window (Windows, WSL and macOS)
---

Open the Claude Monitor floating window by running this command, then report its output
verbatim:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/open-overlay.js"
```

If it prints an error, show it and stop. Do not retry or try to fix the installation.
Sessions that were already open before the plugin was installed only appear after they are reopened.
