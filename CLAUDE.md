# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

LocalizationAI is a Godot 4.7 editor plugin that translates `.csv` and `.po` localization files via local Ollama or OpenRouter. The plugin lives at `addons/localization_ai/`; the rest of the project (`addons/godot_ai/`, `addons/kenyoni/`) is third-party tooling and should not be modified.

## Running the translation backend standalone

The translator is a stdlib-only Python script. It is normally invoked from inside the editor, but can be run directly for debugging:

```sh
python3 addons/localization_ai/scripts/translate.py \
    --input <file.csv|file.po> --output <out> --stopped-output <partial> \
    --provider local|openrouter --model <name> \
    --target-lang bg,da,tr [--source-lang en] \
    [--api-url http://localhost:11434] [--api-key <key>] \
    [--progress-file <path>] [--control-file <path>] [--prompts-file <path>] \
    [--min-free-mb 800]

python3 addons/localization_ai/scripts/manage_models.py \
    --action list|pull|delete --model <name> [--api-url ...]
```

There is no build step or linter configured. The one test file is stdlib-only
and covers the backend's failure paths — run it after touching `translate.py`:

```sh
python3 tests/test_translate_progress.py
```

GDScript has no test runner; syntax-check edits with
`godot --headless --check-only --script <file.gd>` and open `project.godot` to
exercise the UI.

## Architecture

### Two-process design with file-based IPC

The Godot side (GDScript, all `@tool`) drives a graph UI in an editor main-screen plugin. To do real work it shells out to Python via `OS.execute(_python(), args)` on a background `Thread`. The two processes communicate through three temp files in `user://` (one set per active translate node, suffixed with `Time.get_ticks_msec()`):

- **progress file** — Python writes `{current, total, source, translated, last_source, last_translated}` after each string; Godot polls it every 0.5 s via `_progress_timer` in `translate_node.gd`. The *partial output* file is a different thing and is throttled to one write per 5 s (`_due_for_partial()`) — it is rendered whole each time, and on a 17 MB CSV writing it per string produced tens of GB of churn and tripped the memory guard.
- **control file** — Godot writes `{"command": "run"|"pause"|"stop"}`; Python's `_check_control()` reads it between strings, sleeping in a loop on `pause`, raising `StopTranslation` on `stop`.
- **prompts file** — Godot serializes `{scope: [text, ...]}` (scope = `"global"` or an ISO code) for Python to splice into the system prompt.

When the user stops or memory runs low, Python writes a `_progress.<ext>` partial file and emits a `{"type": "stopped"}` JSON line on stdout; the GDScript side then routes that partial through any connected Export node so the run can be resumed later (CSV/PO writers skip rows/msgids that are already filled).

### Graph workflow (`addons/localization_ai/ui/`)

`main.gd` hosts a `GraphEdit` with five node kinds in `ui/elements/`: `file_source`, `directory_source`, `translate`, `export`, `prompt`. A "chain" is `<source> → translate (→ export…)`; the prompt node connects sideways into the translate node's secondary input port (port type `1`, slot 1).

`_build_chains()` enumerates all valid chains. A source that implements `get_files() -> Array[String]` (the Directory Source) is expanded into one chain per file; single-file sources fall back to `get_selected_file()`. Each chain is `[src, translate, file_path, export0, export1, ...]`. `_pump_chains()` runs them concurrently up to `ParallelSpin.value`, but skips queued chains whose translate node is already busy — so multiple files from one Directory Source run sequentially through the same translate node, which is the intended "translate until finished" behaviour. ETA is aggregated across all per-node progress dicts in `_node_progress` and refreshed once per second.

Port slot indices in `translate_node.gd` are load-bearing: slot 0 = file input, slot 1 = prompt input, slot 11 = file output. If you rearrange children of the GraphNode, update the `set_slot()` calls to match the new indices.

### Adding a new graph-node kind

Touch all of these in `main.gd`:

1. `NODE_KIND_*` constant.
2. `_node_kind()` — map script path → kind string.
3. `_do_load_workflow()` — `match kind:` branch that spawns the right script.
4. `_on_context_item()` — add a context-menu id.
5. `_context_menu.add_item(...)` in `_ready()`.

The node script itself must extend `GraphNode`, set `title` and slots in `_init()` / `_ready()`, and implement `save_state()` / `load_state()` for workflow persistence. If it does work, expose `run()` returning `""` on success or an error string. To participate in port-time file propagation, implement `get_selected_file()` / `get_output_file()` / `set_input_file()` / `set_pending_input()` — `_on_connection_request()` reads them when an edge is drawn.

### Failure handling

Three tiers, all in `translate.py`. Getting these confused is how a five-minute
provider hiccup used to cost an entire run:

1. **Retryable** — capacity, 429, 5xx, timeouts. `_is_retryable()` reads the
   status only from the `HTTP <code>:` prefix `_chat()` produces; matching bare
   codes anywhere in the body used to hit user ids and token counts. Backoff is
   `_RETRY_DELAYS` with jitter, slept via `_sleep_interruptible()` so Pause and
   Stop still respond mid-wait.
2. **Skippable** — a string that exhausts its retries, or comes back as a
   passthrough (`_is_passthrough()`: byte-identical to a source of 6+ words).
   `_skip()` records it and the run continues; the cell stays blank, and since
   both writers only fill empty cells, re-running the file retries exactly the
   failures. Never count these as translated — `translate_csv()` returns
   `len(tasks) - len(_SKIPPED)`.
3. **Fatal** — `_MAX_FAILURE_STREAK` (25) consecutive failures means the backend
   is down or the key/model is wrong, not that it is flaky.

`StopTranslation` must always propagate through all three; it is a stop, not a
failure.

### Not re-ingesting our own output

Every file the plugin writes is named `<stem>_progress.<ext>` or
`<stem>_translated.<ext>`, and those names feed straight back in when a run is
resumed. Two places have to strip them and one has to refuse them outright:

- `export_node.gd` — `_strip_generated_suffixes()` loops (including ISO
  timestamps from `backup/`), used by **both** `run()` and
  `_snapshot_project_name()`. A single `trim_suffix()` pass lets project names
  compound into a new folder tree per run.
- `directory_source_node.gd` — `_collect_files()` skips those stems entirely.
  Otherwise a source pointed at a folder that also receives exports treats last
  run's partial as this run's input.

`progress/` and `backup/` get a `.gdignore` (`_mark_ignored()`); the export
destination usually lives inside `res://`, and Godot will otherwise import every
intermediate CSV into a full set of `.translation` resources. `done/` stays
importable — that one is the deliverable.

### Translation prompts

`translate.py`'s system prompt is hardcoded for game localization (placeholder preservation, capitalization style, no chatty prefixes). `_clean_translation()` strips common LLM artifacts (`<<<TEXT>>>` echoes, `"Translation:"` prefixes, surrounding quotes the source didn't have). Custom prompts from prompt nodes are appended as `Additional Instructions:` — `global` always, then `<target_lang>`-scoped if present.

### Memory safety

`--min-free-mb` (default 800) makes `translate.py` abort cleanly when `/proc/meminfo` / `GlobalMemoryStatusEx` / `vm_stat` reports low available RAM. This is non-cosmetic: large local models can swap and freeze the desktop. The pre-flight check in `main()` aborts before model load; `_check_memory()` is called from `_check_control()` between every string — and from *inside* its pause loop, alongside `_check_parent_alive()`, so a run paused when the editor closes doesn't spin forever as an orphan.

### Workflows

Workflows are JSON files in `addons/localization_ai/workflows/` produced by `_do_save_workflow()` / `_do_load_workflow()`. Each entry has `kind`, `pos`, `state` (the node's `save_state()` dict), plus a connections list referencing the saved node names. On load, saved names are remapped to freshly-spawned node names via `name_map` before reconnecting.

## Conventions

- All GDScript files in `addons/localization_ai/` are `@tool` because they run in the editor.
- Logging from graph nodes goes through the `log_message(text)` signal — `main.gd` connects it to the BBCode log. Use BBCode color tags (`[color=red]…[/color]`) for severity.
- Python emits one JSON object per line on stdout; the GDScript `_on_done()` parses each line and matches on `type` (`done` / `stopped` / `error` / `progress`).
- Output files are written next to the input as `<stem>_translated.<ext>` (success) or `<stem>_progress.<ext>` (partial). The Export node strips both suffixes when deriving the project folder name.
