# LocalizationAI Wiki

LocalizationAI is a Godot 4.7 editor plugin that translates `.csv` and `.po` localization files using a local LLM (Ollama) or OpenRouter. You build a small node graph — Source → Translate → Export — and let the model fill in the empty cells.

This wiki is the long-form companion to the [README](https://github.com/ismailivanov/LocalizationAI/blob/main/README.md). Use the README for the elevator pitch and install steps; come here when you want to actually understand the moving parts.

## Pages

- **[Getting Started](Getting-Started.md)** — install the plugin, pick a backend, translate your first file.
- **[Node Reference](Node-Reference.md)** — every node, every port, every setting.

More pages will land here as the plugin grows. Likely next: custom prompts deep dive, parallel settings, partial/resume, troubleshooting.

## What this plugin is (and isn't)

**Is**

- A node-graph UI inside the Godot editor for batch-translating localization files.
- A thin GDScript wrapper around a stdlib-only Python script (`translate.py`) that does the real work.
- Two-process by design: the editor never blocks on the model, and crashes on either side leave a recoverable partial file behind.

**Isn't**

- A replacement for human review. LLMs drop placeholders, invent line breaks, and occasionally translate proper nouns. Spot-check the output, especially for languages you don't speak.
- A production-hardened tool. There's no test suite, no CI, and the author uses it for personal projects. Back up your files before pointing it at anything you care about.
- Free in the OpenRouter mode. You pay per token to whichever provider you pick. Local mode (Ollama) is free but slower and memory-hungry.

## Where to ask things

- **Bugs / feature requests** — [GitHub issues](https://github.com/ismailivanov/LocalizationAI/issues).
- **Plugin internals** — see [CLAUDE.md](https://github.com/ismailivanov/LocalizationAI/blob/main/CLAUDE.md) in the repo; it's the architecture overview originally written for AI assistants but readable as a design doc.

## License

MIT. Do whatever you want with it; just don't blame anyone if it eats your strings file.
