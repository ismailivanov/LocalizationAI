# Node Reference

Five node kinds make up a LocalizationAI graph. A valid pipeline always has at least one **Source** feeding a **Translate** node; **Export** writes the result somewhere, and **Prompt** optionally biases the translation. This page covers each one in detail — what its ports carry, what every setting does, and the behaviour you should expect when you press Run.

Port colours:

- 🟢 **Green** (`PORT_TYPE 0`) — carries file paths (`.csv` / `.po`). Sources output green; Translate and Export accept green on their left port and Translate outputs green on its right port.
- 🟠 **Orange** (`PORT_TYPE_PROMPT 1`) — carries custom prompt scopes. Only the Prompt node outputs orange; only the Translate node accepts orange on its secondary input port.

You cannot cross types — Godot's GraphEdit blocks a green-to-orange connection at draw time.

---

## File Source

**Purpose** — Pick a single `.csv` / `.po` file from your project as the input to a chain.

**Ports**

| Side | Slot | Type | Carries |
|------|------|------|---------|
| Right | 0 | 🟢 Green | The selected file path. |

**Settings**

- **File dropdown** — Auto-populated by recursively scanning `res://` for `.csv` and `.po` files. The list refreshes automatically when Godot's filesystem changes; the project's preview pane is also kept in sync.
- **🔄 Refresh** — Manual rescan. Handy if a new file was added by an external tool and Godot hasn't picked it up yet.

**Behaviour** — A File Source contributes exactly one file to its chain. If the dropdown is empty (no `.csv` / `.po` found) the node is disabled and the chain won't build. Saved selection persists in workflow JSON as the file's `res://` path; on load the dropdown is matched against that path and re-selected if found.

---

## Directory Source

**Purpose** — Walk a directory and queue every matching file through one Translate node. The intended pattern for batch-translating a whole project at once.

**Ports**

| Side | Slot | Type | Carries |
|------|------|------|---------|
| Right | 0 | 🟢 Green | The *first* file in the resolved list (used for the live preview / source-lang autodetect). All files are produced from `get_files()` at chain-build time. |

**Settings**

- **Directory** — Absolute path, or `res://` / `user://` paths (Godot localises them). The **…** button opens a directory picker.
- **Recursive** — When on, subfolders are walked too. On by default.
- **Filter** — `CSV + PO` / `CSV only` / `PO only`. Anything else (images, scripts, …) is ignored regardless.
- **🔄 Refresh** — Re-scan the directory. Also triggered automatically when you change the directory, filter, or recursive toggle.
- **Start from** — Resume-style picker. The first option, **(all files)**, is the default and translates everything found. Picking a specific file *skips every file alphabetically before it* and starts at that one. Use this when a long batch crashed halfway and you want to resume without re-doing the finished files.

**Behaviour** — At Run time, `get_files()` returns the resolved list (in sort order, optionally sliced by Start from). The pipeline builds one chain per file, all sharing the same Translate node. `_pump_chains` notices that the Translate node is already busy and serialises the chains through it — exactly what you want for "translate this whole folder, one file at a time."

The status label always shows the *unsliced* file count (`2 file(s) found`) so you can see what the directory contains; the slicing only affects what gets queued.

---

## Translate

**Purpose** — The core node. Takes a file, sends each empty cell / `msgstr` to an LLM, writes the result.

**Ports**

| Side | Slot | Type | Carries |
|------|------|------|---------|
| Left | 0 | 🟢 Green | The file to translate. |
| Left | 1 | 🟠 Orange | Custom prompt(s). |
| Right | 12 | 🟢 Green | Path to the translated output (`*_translated.csv` / `_translated.po` on success, `*_progress.*` on stop). |

**Settings**

- **Provider** — `Local AI (Ollama)` or `OpenRouter`. Switching providers reshuffles the rest of the panel — Ollama shows a model dropdown + refresh, OpenRouter hides it (you type the model slug) and treats the API field as a secret.
- **✍️ Custom Prompts** field — The API URL for Ollama (default `http://localhost:11434`) or the OpenRouter API key. For OpenRouter the field is `secret`-styled; the key is auto-saved to a `user://localization_ai/keys.cfg` keyring on focus-out so it doesn't have to be re-entered next session.
- **Model picker** — Ollama only. Dropdown lists installed models with their on-disk size. The ↻ button calls `manage_models.py --action list` over HTTP to refresh.
- **Model field** — Free text. For Ollama, picking from the dropdown writes into this field; you can also type a model name directly (handy if Ollama isn't reachable at refresh time). For OpenRouter, type the slug (`openai/gpt-4o-mini`, `anthropic/claude-3.5-sonnet`, …).
- **Source language** — Auto-populated from the CSV header. PO files always use `msgid` as the source so this field is disabled. Selection survives across files in a Directory Source as long as the next file has the same column.
- **🌍 Select Languages** — Multi-select popup of 75+ ISO codes. Each picked language is requested as a separate model call; one language failing doesn't poison the rest.
- **⚡ Parallel requests** — How many translation requests are in flight at once *within this single file*. Default 4. Bump to 8–16 for OpenRouter (it parallelises well); keep at 1–2 for small local models that can't handle concurrent requests. This stacks multiplicatively with the toolbar's **Parallel chains** setting.
- **⏸ Pause / ⏹ Stop** — Per-node flow control. These stay clickable even while the rest of the graph is locked during a Run. Pause sends a `pause` command to the Python worker, which sleeps between strings. Stop tears the run down and flushes a partial file.

**Behaviour** — At Run time the node spawns a Python subprocess (`translate.py`) on a background thread. Three temp files in `user://localization_ai/runs/` carry progress, control and prompts between the two sides. The status label and live source/translated previews are populated from the progress file every 0.5 s. On completion the node emits `translation_done` with the output path so connected Export nodes can pick it up.

If a connected Export node is reachable, the live partial is written straight into its destination (`<dest>/<project>/progress/<project>_progress.<ext>`). Otherwise it falls back to `user://localization_ai/out/` — still recoverable, just not in your project tree.

---

## Prompt

**Purpose** — Inject custom instructions into the system prompt. Use it for tone ("translate as a medieval fantasy game"), terminology ("Hero stays as 'Hero', do not localise"), formality, or character-voice rules.

**Ports**

| Side | Slot | Type | Carries |
|------|------|------|---------|
| Right | 1 | 🟠 Orange | The prompt scope + text. |

**Settings**

- **Scope** — `🌍 Global` or one of 75+ language codes. Global prompts apply to every translation; scoped prompts only apply when translating into that language. Multiple Prompt nodes with different scopes can connect to the same Translate node — they're concatenated.
- **Prompt text area** — Free-form instructions. Empty prompts are silently dropped (no harm in having an unused Prompt node hanging around). The node is resizable; drag its bottom-right corner.

**Behaviour** — At Run start the Translate node walks every connection into its orange port, calls `get_scope()` + `get_prompt_text()` on the upstream Prompt node, and writes a JSON map (`{"global": [...], "tr": [...]}`) into `user://localization_ai/runs/prompts_*.json` for the Python side to splice into the system prompt as `Additional Instructions:`.

---

## Export

**Purpose** — Write the translated file into a chosen folder, with a tidy per-project subtree that keeps in-progress partials, final outputs, and backups separate.

**Ports**

| Side | Slot | Type | Carries |
|------|------|------|---------|
| Left | 0 | 🟢 Green | The translated (or partial) file from the Translate node. |
| Right | 3 | 🟢 Green | The final exported path (for chaining further nodes; usually unused). |

**Settings**

- **Export directory** — Where outputs land. The **…** button opens an `EditorFileDialog`. Pre-flight validation aborts the Run if the path doesn't exist when you press Run, so you don't lose work to a typo.
- **File name** — Optional. Leave blank to inherit the source filename (`dialogues.csv` → `dialogues/done/dialogues.csv`). If you set this the project subfolder uses your name instead.

**Output tree**

```
<export_dir>/
  <project>/
    done/<project>.<ext>                  ← final translation
    progress/<project>_progress.<ext>     ← live partial during a Run
    backup/<project>_<ts>.<ext>           ← rotating snapshots:
                                           • prior done/ versions before overwrite
                                           • periodic partial snapshots (last 2 kept)
```

**Behaviour** — When the Translate node emits `translation_done`, Export figures out whether the file is finished or partial by looking at the filename suffix (`_translated.*` vs `_progress.*`). Finished files land in `done/`; partials land in `progress/`. If there's already a file in `done/` it's copied to `backup/<project>_<timestamp>.<ext>` before being overwritten so you never lose the last good version.

Mid-Run, the Translate node calls `prepare_partial_path()` so the Python worker writes its live partial *directly* into `progress/`. A 60-second snapshot timer also copies the live partial into `backup/` (keeping the two newest) as insurance against a corrupt mid-write.

If the export folder vanishes between Run-start and the export step (user deleted it, drive unmounted, …), Export falls back to the source file's folder rather than silently losing the result in `user://`.

After a successful export, Godot's resource filesystem is rescanned so the new files appear in the FileSystem dock without a manual refresh.

---

## Common patterns

**Single file, single language** — `File Source → Translate → Export`. Pick one target language in the multi-select. Three-node graph.

**Single file, many languages in parallel** — Same three nodes; tick every target language you want. Each language is a separate model call.

**Whole folder, one model** — `Directory Source → Translate → Export`. Files queue through the Translate node sequentially (the default behaviour — see [`_pump_chains`](https://github.com/ismailivanov/LocalizationAI/blob/main/addons/localization_ai/ui/main.gd) if you want the details). Leave "Start from" at "(all files)".

**Two-pass: cheap-then-expensive** — Two Translate nodes side by side: the first uses a fast cheap model, the second uses a stronger one only on whatever the first left empty (resume semantics). Connect Source → Translate-A → Translate-B → Export. Not heavily tested, but the partial-resume pipeline supports it.

**Per-language tone** — One Global Prompt node plus one Prompt node per language with localised tone instructions. All connect to the same Translate node's orange port.
