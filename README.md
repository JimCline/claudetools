# claudetools

This project and its plugins have moved to **[agentic-tool-labs/agent-tools](https://github.com/agentic-tool-labs/agent-tools)**. This repository is archived and no longer updated.

## Switching an existing install

In Claude Code, uninstall the plugins you have from the old marketplace, remove it, and install them from the new one. Skip the lines for plugins you don't use.

```
/plugin uninstall ah@claudetools
/plugin uninstall task-gopher@claudetools
/plugin uninstall output-discipline@claudetools
/plugin uninstall comment-discipline@claudetools
/plugin uninstall review-guide@claudetools
/plugin marketplace remove claudetools

/plugin marketplace add agentic-tool-labs/agent-tools
/plugin install ah@agent-tools
/plugin install task-gopher@agent-tools
/plugin install output-discipline@agent-tools
/plugin install comment-discipline@agent-tools
/plugin install review-guide@agent-tools
```

If you already switched to `JimCline/agent-tools`, follow the steps at [JimCline/agent-tools](https://github.com/JimCline/agent-tools) instead.
