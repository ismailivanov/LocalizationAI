# Getting Started

This walks you from a fresh clone to a finished translation. About 10 minutes if you already have a Godot project and an Ollama install; 20 if you're setting both up from scratch.

## 1. Requirements

- **Godot 4.7+** — the plugin uses `@tool` scripts and `GraphEdit` features that aren't in 4.3.
- **Python 3** on your `PATH`. The translator script is stdlib-only (no `pip install`).
- **One of**:
  - [Ollama](https://ollama.com/) running locally — free, offline, but slower and uses 4–16 GB RAM depending on the model.
  - An [OpenRouter](https://openrouter.ai/) API key — faster, multilingual quality is generally better, pay-per-token.

Verify Python is reachable:

```sh
python3 --version    # Linux / macOS
python --version     # Windows
```

If the command isn't found, install Python and make sure the installer's "Add to PATH" option is checked (Windows) or that the binary is in `/usr/bin` / `/usr/local/bin` (macOS / Linux).

## 2. Install the plugin

1. Copy the `addons/localization_ai/` folder into your Godot project's `addons/` directory.
2. Open the project in Godot.
3. **Project → Project Settings → Plugins** → enable **LocalizationAI**.
4. A new **LocalizationAI** tab appears in the main editor area (next to 2D / 3D / Script). Click it.

If the tab doesn't appear, check the Output panel for plugin errors — usually a missing `python3` or a Godot version mismatch.

## 3. Pick a backend

### Option A — Ollama (local, free)

1. Install Ollama from [ollama.com](https://ollama.com/).
2. Start the daemon (`ollama serve`, or it auto-runs on most installers).
3. Pull a model. Good starting points:
   - `ollama pull llama3.1:8b` — solid quality, ~5 GB RAM.
   - `ollama pull qwen2.5:7b` — strong multilingual for its size.
   - `ollama pull gemma2:9b` — Google's model, decent quality.
4. In LocalizationAI, you can also use the **Models** tab to pull / list / delete models without leaving the editor.

Model size rule of thumb: pick something your machine can run *with headroom*. The plugin's memory guard aborts at 800 MB free by default to keep the OS responsive, so a model that *barely* fits will fail before it finishes a long file.

### Option B — OpenRouter (hosted, paid)

1. Sign up at [openrouter.ai](https://openrouter.ai/) and grab an API key.
2. Pick a model on their [models page](https://openrouter.ai/models). For game localization, the usual suspects are:
   - `openai/gpt-4o-mini` — cheap, very fast, good quality.
   - `anthropic/claude-3.5-sonnet` — higher quality, more expensive.
   - `google/gemini-2.0-flash-exp` — fast and cheap.
3. Keep your key somewhere safe — the plugin stores it in the workflow JSON if you save the graph, so don't commit those workflows to a public repo.

## 4. Build your first graph

Right-click the canvas to add nodes. The minimum viable graph is three nodes:

```
[File Source] ──► [Translate] ──► [Export]
```

### File Source

- Click the **…** button and pick a `.csv` or `.po` file.
- For CSV, the file should have a header row with ISO language codes (`keys, en, bg, tr, …`). The first non-`keys` column is treated as the source by default.
- For PO, the source is always the `msgid`.

### Translate

- **Provider** — Local AI or OpenRouter.
- **API URL** — `http://localhost:11434` for Ollama, or your API key for OpenRouter.
- **Model** — for Ollama, hit the ↻ button to populate the dropdown with installed models. For OpenRouter, type the model slug (e.g. `openai/gpt-4o-mini`).
- **Source language** — auto-populated from the CSV header. Ignored for PO.
- **Select Languages** — pick one or more target languages. Each is requested separately, so a failure on one doesn't kill the others.
- **⚡ Parallel requests** — how many strings to translate concurrently *within this file*. Default 4. Bump to 8–16 for OpenRouter; keep at 1–2 for small local models that can't handle concurrent requests.

### Export

- Click the **…** button and pick a folder. The output filename is derived from the input (`game_ui.csv` → `game_ui_translated.csv`).
- Optionally override the filename with the **File name** field.

Connect the green ports left-to-right: File Source's right port → Translate's left port → Translate's right port → Export's left port.

## 5. Run it

- Press **▶ Run** in the top toolbar.
- Watch the **Translating N/M…** counter and the live source / translated preview inside the Translate node.
- The aggregate **ETA** in the toolbar updates once per second based on completed strings.

**Pause** stops new requests but lets in-flight ones finish. **Stop** does the same and writes a `*_progress.csv` / `*_progress.po` partial file in the export folder. You can feed that partial back through a Source node later to resume — already-filled cells are skipped.

## 6. (Optional) Custom prompts

Add a **Prompt** node, type instructions like *"Translate as a medieval fantasy game. Use thee/thou for formal address."*, and connect its right port to the Translate node's orange port (top-left, beneath the file input).

- **Global** scope applies to every target language.
- A specific language scope (e.g. `tr`) only applies when translating into that language.

Multiple Prompt nodes can connect to the same Translate node; they're concatenated.

## 7. (Optional) Batch many files

Replace **File Source** with **Directory Source**:

- Point it at a folder.
- Pick `.csv only`, `.po only`, or both.
- Enable **Recursive** to walk subfolders.

Every matching file is queued through the same Translate node sequentially. The top-toolbar **Parallel** spin controls how many *chains* (different translate nodes / different sources) run at once — leave it at 1 if your graph has a single Translate node.

## 8. Save the workflow

**Save Workflow** writes the full graph (nodes, connections, model settings, target languages, parallel counts) to `addons/localization_ai/workflows/<name>.json`. **Load Workflow** restores it.

These JSON files contain your API key in plaintext when using OpenRouter. Don't commit them to a public repo, or strip the key before sharing.

## When things go wrong

- **"python3: command not found"** — Python isn't on `PATH`. On Windows, reinstall Python with the "Add to PATH" box checked. On macOS, `brew install python`.
- **"Connection error"** with Ollama — the daemon isn't running. Try `ollama serve` in a terminal and watch for errors.
- **Translation stops with "Low memory"** — your model is too big. Pick a smaller one, or close other apps, or lower `--min-free-mb` in the source if you really know what you're doing.
- **Output has `<<<TEXT>>>` or `Translation:` in it** — the cleanup pass missed an LLM artifact. Open an issue with the offending model + sample.
- **Placeholders like `%s` got mangled** — common with small local models. Try a bigger model or switch to OpenRouter. The system prompt asks the model to preserve them, but small models don't always listen.

## Next steps

Now that the basics work, the things worth learning next:

- How **partial / resume** lets you safely interrupt a 6-hour translation job and continue tomorrow.
- How **parallel requests** vs **parallel chains** stack (multiplicative).
- How to chain multiple Translate nodes for two-pass workflows (e.g. cheap model first, expensive model on the failures).

Those pages aren't written yet — they're the next wiki entries on the list.
