# Repository Instructions

Before planning or making changes, read and follow [CLAUDE.md](CLAUDE.md).

Before a non-trivial change, a technical tradeoff, or decision-note work, load and follow the vendored [write-notes-like-deepseek skill](.claude/skills/write-notes-like-deepseek/SKILL.md), then consult the relevant existing notes. The skill defines when notes are required and how to write, update, verify, and archive them; do not maintain a separate set of note rules here.

Codex discovers this same skill through `.agents/skills/write-notes-like-deepseek`, a relative symlink to the vendored directory. Keep one source of truth; no separate global installation is required.
