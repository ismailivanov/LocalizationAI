# LocalizationAI

A Godot 4.7 editor plugin that translates `.csv` and `.po` localization files using a **local LLM (Ollama)** or **OpenRouter**. Drag your source file into a node-based graph, pick target languages, and let the model do the rest — with live progress, pause/resume, and partial-output recovery.

![Godot 4.7+](https://img.shields.io/badge/Godot-4.7%2B-478CBF?logo=godot-engine&logoColor=white)
![Python 3](https://img.shields.io/badge/Python-3-3776AB?logo=python&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
<img width="2560" height="1364" alt="image" src="https://github.com/user-attachments/assets/f4be4c91-21d9-4c38-a578-e6831f525d02" />

## Features

- **Two backends** — point it at a local **Ollama** server for offline / free translation, or at **OpenRouter** for hosted models (GPT, Claude, Gemini, Llama, etc.) via your own API key.
- **CSV and PO** — auto-detects Godot CSV translation tables and gettext `.po` catalogs. Existing translations are preserved; only empty cells / `msgstr` are filled.
- **Node-based workflow** — a `GraphEdit` canvas with five node kinds:
  - **File Source** — single `.csv` / `.po` file.
  - **Directory Source** — recursive scan; queues every matching file through the same translate node.
  - **Translate** — provider, model, source language, and one or more target languages.
  - **Prompt** — custom instructions injected into the system prompt, either globally or per target language (e.g. tone, terminology, formality).
  - **Export** — writes the result into a chosen project folder, deriving the output name from the input.
- **Multiple target languages in one pass** — pick any combination from 75+ ISO codes; each language is requested as a separate model call so failures don't poison the rest.
- **Live progress and ETA** — per-node progress bars plus an aggregate ETA across every chain running in parallel.
- **Pause, resume, stop** — pause mid-run, resume later. Stopping (or running out of memory) flushes a `*_progress.csv` / `*_progress.po` partial file, which can be fed back through the graph to continue exactly where it stopped.
- **Memory guard** — `--min-free-mb` (default 800 MB) aborts cleanly before a large local model swaps the desktop. Checked before model load and between every string.
- **Parallel chains** — adjustable concurrency: translate multiple files at once, or queue many files through one translate node sequentially.
- **Workflow save / load** — the whole graph (nodes, connections, settings) serializes to JSON under `addons/localization_ai/workflows/`.
- **Game-localization-tuned prompts** — built-in system prompt preserves `%s`, `{name}`, BBCode tags, line breaks, and capitalization style. A post-processing pass strips common LLM artifacts (`"Translation:"` prefixes, surrounding quotes, echoed source).
- **Model manager** — list, pull, and delete Ollama models from inside the editor.
- **No Python dependencies** — `translate.py` is stdlib-only. Just `python3` on `PATH`.

## Installation

1. Copy `addons/localization_ai/` into your project's `addons/` folder.
2. Enable **LocalizationAI** in **Project → Project Settings → Plugins**.
3. Make sure `python3` is available on your `PATH`.
4. For local mode, install [Ollama](https://ollama.com/) and pull a model (e.g. `ollama pull llama3.1:8b`). For OpenRouter, grab a key at [openrouter.ai](https://openrouter.ai/).
5. Open the **LocalizationAI** main-screen tab in the editor.

## Quick start

1. Right-click the canvas → **Add File Source** → pick a `.csv` or `.po`.
2. Right-click → **Add Translate** → choose provider, model, and target languages.
3. Right-click → **Add Export** → pick an output folder.
4. Connect: `File Source → Translate → Export`.
5. Press **Run**.

An example file is included at `addons/localization_ai/example/game_ui.csv`, and a starter graph at `addons/localization_ai/workflows/basic_workflow.json`.

## Architecture (short version)

The editor side is `@tool` GDScript driving a `GraphEdit`. Real translation is done by `addons/localization_ai/scripts/translate.py`, launched as a background process. The two sides talk through three temp files per run (progress / control / prompts), so pause / stop / live progress all work without blocking the editor. See [CLAUDE.md](CLAUDE.md) for a deeper walkthrough.

## Standalone CLI

The translator works without Godot:

```sh
python3 addons/localization_ai/scripts/translate.py \
    --input strings.csv --output strings_translated.csv \
    --stopped-output strings_progress.csv \
    --provider local --model llama3.1:8b \
    --target-lang bg,da,tr --source-lang en \
    --api-url http://localhost:11434
```

Model management:

```sh
python3 addons/localization_ai/scripts/manage_models.py \
    --action list \
    --api-url http://localhost:11434
```

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer — use at your own risk

I built this for myself. It works for my use case, but it was developed with heavy AI assistance and has **no test suite, no CI, and no formal review**. Before you point it at a real project:

- Back up your `.csv` / `.po` files. The plugin overwrites translation cells; a bad model output is still a write.
- Spot-check the output. LLMs occasionally drop placeholders (`%s`, `{name}`), invent line breaks, or "translate" things that shouldn't be translated (proper nouns, format tokens).
- Watch your memory if you run local models — the guard helps but isn't a guarantee.
- Treat OpenRouter / Ollama costs and rate limits as your responsibility.

Issues and PRs are welcome, but this is a personal tool published as-is, not a maintained product.
