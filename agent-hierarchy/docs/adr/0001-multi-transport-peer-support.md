# Support tmux/background terminals as a second peer transport

`/agent-roster create` needs to instantiate peer-routed roster members even outside a Herdr context. Rather than falling back to subagents-only (which would silently override any member's configured `peer` route whenever Herdr isn't running), we're building tmux panes / backgrounded terminals as a second real transport for spawning and addressing peer sessions. This costs more to build and maintain than a subagent-only fallback, but keeps a member's `peer` route meaningful regardless of terminal environment.
