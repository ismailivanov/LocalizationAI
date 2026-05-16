# LocalizationAI

A Godot 4.7 editor plugin that translates `.csv` and `.po` localization files with an LLM — either a local **Ollama** server (free, offline) or **OpenRouter** (paid, hosted). You drop your file into a node graph, pick the languages, hit Run, and watch the strings fill in.

![Godot 4.7+](https://img.shields.io/badge/Godot-4.7%2B-478CBF?logo=godot-engine&logoColor=white)
![Python 3](https://img.shields.io/badge/Python-3-3776AB?logo=python&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

<img width="2560" height="1367" alt="image" src="https://github.com/user-attachments/assets/42500718-282d-46df-af59-443f21b099fa" />

## What it does

You build a small graph — `Source → Translate → Export` — and the plugin handles the rest. CSV translation tables and gettext `.po` catalogs both work; existing translations stay put, only empty cells get filled. Pick 75+ target languages in one pass. Add a **Prompt** node to inject custom instructions (tone, terminology, formality) globally or per language. Point a **Directory Source** at a folder to batch a whole project's worth of files through the same translate node.

Speed comes from two knobs that stack: **parallel chains** (different files at once, top toolbar) and **parallel requests** (concurrent strings within one file, on the translate node). OpenRouter handles 8+ in flight comfortably; small local models usually want 1–2.

Long runs are safe to interrupt. Pause lets in-flight requests finish, then waits. Stop flushes a `*_progress.csv` / `*_progress.po` partial file you can feed back through the graph to resume exactly where you left off — already-filled cells are skipped. The same partial gets written if Godot crashes, the OS reboots, or memory runs out. Speaking of which: a built-in memory guard aborts cleanly when free RAM drops below 800 MB so a too-big local model can't swap your desktop into a freeze.

Translations are tuned for game text. The system prompt preserves `%s`, `{name}`, BBCode tags, line breaks, and capitalization style. A post-processing pass strips the usual LLM noise (`Translation:` prefixes, echoed source, surrounding quotes the source didn't have). Save the whole graph — nodes, connections, models, languages, parallel counts — to a JSON workflow under `addons/localization_ai/workflows/` and load it next session.

No Python packages to install. The translator is stdlib-only; you just need `python3` on `PATH`. Ollama models can be listed / pulled / deleted from the editor's **Models** tab. OpenRouter keys are kept in a local keyring under Godot's `user://` folder (`%APPDATA%\Godot\app_userdata\<project>\` on Windows, `~/Library/Application Support/Godot/app_userdata/<project>/` on macOS, `~/.local/share/godot/app_userdata/<project>/` on Linux) so workflow JSONs stay safe to share.

## Install

1. Copy `addons/localization_ai/` into your project's `addons/` folder.
2. **Project → Project Settings → Plugins** → enable **LocalizationAI**.
3. Make sure `python3` is on your `PATH`.
4. For local mode: install [Ollama](https://ollama.com/) and `ollama pull llama3.1:8b` (or whatever fits your RAM). For hosted: get a key at [openrouter.ai](https://openrouter.ai/).
5. Open the **LocalizationAI** main-screen tab.

## Quick start

1. Right-click the canvas → **Add File Source** → pick a `.csv` or `.po`.
2. **Add Translate** → choose provider, model, source + target languages.
3. **Add Export** → pick an output folder.
4. Connect `File Source → Translate → Export` (left-to-right green ports).
5. **▶ Run**.

A starter graph lives at `addons/localization_ai/workflows/basic_workflow.json`. The [Getting Started](docs/Getting-Started.md) page walks through each setting in more detail.

## Standalone CLI

The translator works without Godot:

```sh
python3 addons/localization_ai/scripts/translate.py \
    --input strings.csv --output strings_translated.csv \
    --stopped-output strings_progress.csv \
    --provider local --model llama3.1:8b \
    --target-lang bg,da,tr --source-lang en \
    --api-url http://localhost:11434 \
    --workers 4
```

Model management:

```sh
python3 addons/localization_ai/scripts/manage_models.py \
    --action list --api-url http://localhost:11434
```

## Architecture (one paragraph)

The editor side is `@tool` GDScript driving a `GraphEdit`. Real work happens in `addons/localization_ai/scripts/translate.py`, launched as a background process. The two sides talk through three temp files per run (progress / control / prompts), so pause / stop / live progress work without ever blocking the editor. [CLAUDE.md](CLAUDE.md) has the deep dive.

## License

MIT — see [LICENSE](LICENSE).

## Use at your own risk

Architecture and design are mine; AI did a lot of the typing. There's no test suite or CI, so back up your `.csv` / `.po` files before pointing this at anything important and spot-check the output — LLMs occasionally drop placeholders or translate things they shouldn't. OpenRouter / Ollama costs and rate limits are yours; API keys live in a plaintext keyring under Godot's `user://`.
