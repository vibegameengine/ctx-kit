# Clean-project validation

Validated on Windows on 2026-10-13 with Node, PowerShell 5.1, Git, installed
Claude/Codex runtimes and the custom Godot 4.7.1-rc executable.

`clean-projects.mjs` created independent Git repositories under a new temporary
directory. The Godot project used `source/domain/counter.gd` and its own Node
scene; neither project contained game files, the game's tools or its settings.
The executable was built from a separate checkout of the GDScript fork; only
compiler/model caches were reused from the machine.

Observed output:

```text
[OK] Fresh gdscript repo: initial index, actual hooks/MCP, idempotent reinstall, non-destructive uninstall
[OK] Fresh typescript repo: initial index, actual hooks/MCP, idempotent reinstall, non-destructive uninstall
[OK] User-wide Claude/Codex configurations stayed byte-identical
```

Each installation tested six configured index hooks (Claude startup/prompt/write
and Codex startup/prompt/write), with PATH reduced to system directories, including
addition, direct-call graph and deletion. Actual stdio MCP exercised AST full and
compact output and language-filtered search. Initial index health and deep health
passed. The Godot project imported and printed `FRESH_GODOT_BOOT` in a real engine
run. Reinstall produced exactly nine Codex service/index hooks; unrelated hooks,
MCP transports, environment values and plugin flags survived uninstall.

Both new directories initially emitted one explicit warning: Codex project trust
had not been confirmed, so its CLI still selected the existing global transport.
The verifier did not claim that these hooks were automatically dispatched by a
model session. It executed the configured handlers directly and exercised the
actual native MCP. Normal first-open project trust remains required; the installer
does not write user trust metadata or bypass it.

`node --test tests/config.test.mjs`: five checks passed, covering conflicting
definitions, malformed JSON, independent Claude/Codex targets and preservation of
a user-edited transport on uninstall. The same suite is wired into CI on Windows
and Linux. Whole-session token savings are not part of these functional tests.
