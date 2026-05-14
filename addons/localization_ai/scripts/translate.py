#!/usr/bin/env python3
"""
Localization AI - Translation Script
Translates .po or .csv files using Local AI (Ollama) or OpenRouter API.
No external dependencies required (uses only stdlib).
"""

import argparse
import csv
import json
import os
import sys
import time
import urllib.request
import urllib.error


# ── API helpers ─────────────────────────────────────────────────────────────

def _chat(messages: list, provider: str, api_url: str, api_key: str, model: str) -> str:
    if provider == "openrouter":
        url = "https://openrouter.ai/api/v1/chat/completions"
        headers = {
            "Authorization": f"Bearer {api_key.strip()}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://github.com/godot/godot",
            "X-Title": "Godot LocalizationAI",
        }
    else:  # local  (Ollama OpenAI-compatible endpoint)
        url = f"{api_url.rstrip('/')}/v1/chat/completions"
        headers = {"Content-Type": "application/json"}

    payload = json.dumps({
        "model": model,
        "messages": messages,
        "stream": False,
    }).encode("utf-8")

    req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode("utf-8")
            data = json.loads(raw)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {e.code}: {body}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"Connection error: {e.reason}") from e

    # API returned 200 but with an error payload (common for OpenRouter)
    if "error" in data:
        err = data["error"]
        msg = err.get("message", str(err)) if isinstance(err, dict) else str(err)
        raise RuntimeError(f"API error: {msg}")

    if "choices" not in data or not data["choices"]:
        raise RuntimeError(f"Unexpected API response: {raw[:300]}")

    return data["choices"][0]["message"]["content"].strip()


_PROMPTS: dict = {}

# Map ISO codes → full language names so small local models understand.
_LANG_NAMES = {
    "af": "Afrikaans", "sq": "Albanian", "am": "Amharic", "ar": "Arabic",
    "hy": "Armenian", "az": "Azerbaijani", "eu": "Basque", "be": "Belarusian",
    "bn": "Bengali", "bs": "Bosnian", "bg": "Bulgarian", "my": "Burmese",
    "ca": "Catalan", "zh-CN": "Simplified Chinese", "zh-TW": "Traditional Chinese",
    "hr": "Croatian", "cs": "Czech", "da": "Danish", "nl": "Dutch",
    "en": "English", "et": "Estonian", "fi": "Finnish", "fr": "French",
    "gl": "Galician", "ka": "Georgian", "de": "German", "el": "Greek",
    "gu": "Gujarati", "he": "Hebrew", "hi": "Hindi", "hu": "Hungarian",
    "is": "Icelandic", "id": "Indonesian", "ga": "Irish", "it": "Italian",
    "ja": "Japanese", "kn": "Kannada", "kk": "Kazakh", "km": "Khmer",
    "ko": "Korean", "ku": "Kurdish", "lo": "Lao", "lv": "Latvian",
    "lt": "Lithuanian", "mk": "Macedonian", "ms": "Malay", "ml": "Malayalam",
    "mt": "Maltese", "mr": "Marathi", "mn": "Mongolian", "ne": "Nepali",
    "no": "Norwegian", "fa": "Persian", "pl": "Polish", "pt": "Portuguese",
    "pt-BR": "Brazilian Portuguese", "pa": "Punjabi", "ro": "Romanian",
    "ru": "Russian", "sr": "Serbian", "si": "Sinhala", "sk": "Slovak",
    "sl": "Slovenian", "es": "Spanish", "es-419": "Latin American Spanish",
    "sw": "Swahili", "sv": "Swedish", "tl": "Tagalog", "ta": "Tamil",
    "te": "Telugu", "th": "Thai", "tr": "Turkish", "uk": "Ukrainian",
    "ur": "Urdu", "uz": "Uzbek", "vi": "Vietnamese", "cy": "Welsh",
}


def _lang_label(code: str) -> str:
    return _LANG_NAMES.get(code, _LANG_NAMES.get(code.split("-")[0], code))


def translate_text(text: str, target_lang: str, provider: str,
                   api_url: str, api_key: str, model: str) -> str:
    if not text.strip():
        return text

    lang_name = _lang_label(target_lang)

    sys_content = (
        f"You are a professional video game localizer. Your only task is to translate "
        f"the user's text into {lang_name}.\n"
        "Strict rules:\n"
        "- Translate ANY input, even a single word or UI label (e.g. 'Continue', 'OK', 'Back'). "
        "Never ask for more context, never refuse, never reply in English unless the target is English.\n"
        "- Output ONLY the translation. No quotes, no explanations, no notes, no greetings, "
        "no 'Here is the translation:' prefix.\n"
        "- Preserve placeholders exactly: %s, %d, {0}, {name}, [color], \\n, \\t, HTML/BBCode tags.\n"
        "- Preserve capitalization style (Title Case stays Title Case, ALL CAPS stays ALL CAPS).\n"
        "- If the input is a proper noun, brand, or untranslatable token, return it unchanged."
    )

    # Inject custom prompts
    custom_prompts = []
    if "global" in _PROMPTS:
        custom_prompts.extend(_PROMPTS["global"])
    if target_lang in _PROMPTS:
        custom_prompts.extend(_PROMPTS[target_lang])

    if custom_prompts:
        sys_content += "\n\nAdditional Instructions:\n" + "\n".join(f"- {p}" for p in custom_prompts)

    user_content = (
        f"Translate the following text into {lang_name}. "
        f"Return ONLY the translation, nothing else.\n"
        f"<<<TEXT>>>\n{text}\n<<<END>>>"
    )

    messages = [
        {"role": "system", "content": sys_content},
        {"role": "user", "content": user_content},
    ]
    result = _chat(messages, provider, api_url, api_key, model)
    return _clean_translation(result, text)


def _clean_translation(out: str, original: str) -> str:
    """Strip common LLM artifacts: delimiters, surrounding quotes, prefix labels."""
    s = out.strip()
    # Remove delimiter echoes
    for tag in ("<<<TEXT>>>", "<<<END>>>", "<<<TRANSLATION>>>"):
        s = s.replace(tag, "")
    s = s.strip()
    # Strip leading label like "Translation:" / "Bulgarian:" / "Here is the translation:"
    low = s.lower()
    for prefix in ("translation:", "translated text:", "here is the translation:",
                   "here's the translation:", "result:"):
        if low.startswith(prefix):
            s = s[len(prefix):].lstrip()
            break
    # Strip matching surrounding quotes if the original didn't have them
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ('"', "'", "“", "”", "«", "»"):
        if not (original.startswith(s[0]) and original.endswith(s[-1])):
            s = s[1:-1].strip()
    return s if s else out.strip()


# ── Progress + Control ──────────────────────────────────────────────────────

_PROGRESS_FILE: str = ""
_PROGRESS_TOTAL: int = 0
_PROGRESS_CURRENT: int = 0
_LAST_DONE_SOURCE: str = ""
_LAST_DONE_TRANSLATED: str = ""
_CONTROL_FILE: str = ""


class StopTranslation(Exception):
    """Raised when the user requests a stop via the control file."""
    pass


class LowMemoryAbort(StopTranslation):
    """Raised when available system memory falls below the safety threshold."""
    def __init__(self, free_mb: int, threshold_mb: int):
        super().__init__(f"Low memory: {free_mb} MB free (< {threshold_mb} MB threshold)")
        self.free_mb = free_mb
        self.threshold_mb = threshold_mb


# Safety threshold (overridden by --min-free-mb). When available RAM drops
# below this, we abort translation to keep the OS responsive (large local
# models can starve the system and trigger swap / hard freeze).
_MIN_FREE_MB: int = 800


def _available_memory_mb() -> int:
    """Return available memory in MB. -1 if unknown on this platform."""
    try:
        if sys.platform.startswith("linux"):
            with open("/proc/meminfo", "r", encoding="utf-8") as f:
                for line in f:
                    if line.startswith("MemAvailable:"):
                        # MemAvailable: <kB> kB
                        return int(line.split()[1]) // 1024
        elif sys.platform == "win32":
            import ctypes

            class _MEMSTAT(ctypes.Structure):
                _fields_ = [
                    ("dwLength", ctypes.c_ulong),
                    ("dwMemoryLoad", ctypes.c_ulong),
                    ("ullTotalPhys", ctypes.c_ulonglong),
                    ("ullAvailPhys", ctypes.c_ulonglong),
                    ("ullTotalPageFile", ctypes.c_ulonglong),
                    ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong),
                    ("ullAvailVirtual", ctypes.c_ulonglong),
                    ("sullAvailExtendedVirtual", ctypes.c_ulonglong),
                ]
            stat = _MEMSTAT()
            stat.dwLength = ctypes.sizeof(_MEMSTAT)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat)):
                return int(stat.ullAvailPhys // (1024 * 1024))
        elif sys.platform == "darwin":
            import subprocess
            out = subprocess.check_output(
                ["vm_stat"], text=True, timeout=2,
            )
            page_size = 4096
            free_pages = 0
            for line in out.splitlines():
                if line.startswith("Mach Virtual Memory Statistics") and "page size of" in line:
                    page_size = int(line.split("page size of")[1].split()[0])
                for key in ("Pages free:", "Pages speculative:", "Pages inactive:"):
                    if line.startswith(key):
                        free_pages += int(line.split()[-1].rstrip("."))
            return (free_pages * page_size) // (1024 * 1024)
    except Exception:
        pass
    return -1


def _check_memory() -> None:
    free = _available_memory_mb()
    if free < 0:
        return  # platform unsupported — skip check
    if free < _MIN_FREE_MB:
        raise LowMemoryAbort(free, _MIN_FREE_MB)


def _set_total(total: int) -> None:
    global _PROGRESS_TOTAL, _PROGRESS_CURRENT, _LAST_DONE_SOURCE, _LAST_DONE_TRANSLATED
    _PROGRESS_TOTAL = total
    _PROGRESS_CURRENT = 0
    _LAST_DONE_SOURCE = ""
    _LAST_DONE_TRANSLATED = ""
    _write_progress("", "")


def _progress_start(source: str) -> None:
    """Called BEFORE the API call — translated is empty (in-progress)."""
    _write_progress(source, "")


def _progress_done(source: str, translated: str) -> None:
    """Called AFTER the API call — advances counter, records both."""
    global _PROGRESS_CURRENT, _LAST_DONE_SOURCE, _LAST_DONE_TRANSLATED
    _PROGRESS_CURRENT += 1
    _LAST_DONE_SOURCE = source
    _LAST_DONE_TRANSLATED = translated
    _write_progress(source, translated)
    print(json.dumps({
        "type":       "progress",
        "current":    _PROGRESS_CURRENT,
        "total":      _PROGRESS_TOTAL,
        "source":     source[:80],
        "translated": translated[:80],
    }), flush=True)


def _write_progress(source: str, translated: str) -> None:
    if not _PROGRESS_FILE:
        return
    try:
        with open(_PROGRESS_FILE, "w", encoding="utf-8") as f:
            json.dump({
                "current":    _PROGRESS_CURRENT,
                "total":      _PROGRESS_TOTAL,
                "source":     source[:200],
                "translated": translated[:200],
                "last_source":     _LAST_DONE_SOURCE[:200],
                "last_translated": _LAST_DONE_TRANSLATED[:200],
            }, f)
    except OSError:
        pass


def _check_control() -> None:
    """Check the control file for pause/stop commands between translations.
    Also enforces the low-memory safety abort."""
    _check_memory()
    if not _CONTROL_FILE:
        return
    while True:
        try:
            with open(_CONTROL_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
            command = data.get("command", "run")
        except (OSError, json.JSONDecodeError, ValueError):
            return  # Can't read → assume run

        if command == "stop":
            raise StopTranslation()
        elif command == "pause":
            time.sleep(0.5)
            continue
        else:  # "run"
            return


# ── PO parser / writer ───────────────────────────────────────────────────────

def _unescape_po(s: str) -> str:
    return s.replace("\\n", "\n").replace("\\t", "\t").replace('\\"', '"').replace("\\\\", "\\")


def _escape_po(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def _count_po_strings(lines: list) -> int:
    count = 0
    for i, line in enumerate(lines):
        if line.startswith("msgid ") and i + 1 < len(lines):
            raw_id = line[6:].strip().strip('"')
            if raw_id:
                count += 1
    return count


def _count_po_missing(lines: list) -> int:
    """Count msgid entries whose msgstr is empty (i.e. need translation)."""
    count = 0
    i = 0
    while i < len(lines):
        if not lines[i].startswith("msgid "):
            i += 1
            continue
        raw_id = lines[i][6:].strip()
        i += 1
        while i < len(lines) and lines[i].startswith('"'):
            raw_id += lines[i].strip()
            i += 1
        msgid = _unescape_po(raw_id.strip('"'))
        if i < len(lines) and lines[i].startswith("msgstr "):
            raw_str = lines[i][7:].strip()
            i += 1
            while i < len(lines) and lines[i].startswith('"'):
                raw_str += lines[i].strip()
                i += 1
            msgstr = _unescape_po(raw_str.strip('"'))
            if msgid and not msgstr:
                count += 1
    return count


def translate_po(input_path: str, output_path: str, stopped_output: str,
                 target_lang: str, provider: str, api_url: str,
                 api_key: str, model: str) -> int:
    with open(input_path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    _set_total(_count_po_missing(lines))

    out = []
    i = 0
    count = 0

    def _flush_remaining(start: int) -> None:
        for k in range(start, len(lines)):
            out.append(lines[k])

    try:
        while i < len(lines):
            line = lines[i]

            if not line.startswith("msgid "):
                out.append(line)
                i += 1
                continue

            # Collect full msgid (may span multiple lines)
            raw_id = line[6:].strip()
            out.append(line)
            i += 1
            while i < len(lines) and lines[i].startswith('"'):
                raw_id += "\n" + lines[i].strip()
                out.append(lines[i])
                i += 1
            msgid = _unescape_po(raw_id.strip('"'))

            # Collect existing msgstr
            if i < len(lines) and lines[i].startswith("msgstr "):
                raw_str = lines[i][7:].strip()
                msgstr_start = i
                i += 1
                while i < len(lines) and lines[i].startswith('"'):
                    raw_str += "\n" + lines[i].strip()
                    i += 1
                existing = _unescape_po(raw_str.strip('"'))

                if msgid and not existing:
                    _check_control()
                    _progress_start(msgid)
                    translated = translate_text(msgid, target_lang, provider,
                                                api_url, api_key, model)
                    out.append(f'msgstr "{_escape_po(translated)}"\n')
                    count += 1
                    _progress_done(msgid, translated)
                else:
                    # Keep original msgstr lines as-is (resume / header / pre-filled)
                    for k in range(msgstr_start, i):
                        out.append(lines[k])
    except StopTranslation:
        _flush_remaining(i)
        if stopped_output:
            with open(stopped_output, "w", encoding="utf-8") as f:
                f.writelines(out)
        raise

    with open(output_path, "w", encoding="utf-8") as f:
        f.writelines(out)
    return count


# ── CSV parser / writer ──────────────────────────────────────────────────────

def translate_csv(input_path: str, output_path: str, stopped_output: str,
                  target_langs: list, provider: str, api_url: str,
                  api_key: str, model: str, source_lang: str = "") -> int:
    with open(input_path, "r", encoding="utf-8", newline="") as f:
        rows = list(csv.reader(f))

    if not rows:
        return 0

    header = rows[0]

    # Source column: use --source-lang if given, else first non-"keys" column
    _KEY_HEADERS = {"keys", "key", "id"}
    if source_lang and source_lang in header:
        src_col = header.index(source_lang)
    else:
        src_col = next(
            (i for i, h in enumerate(header) if h.strip().lower() not in _KEY_HEADERS),
            None,
        )
        if src_col is None:
            raise ValueError("CSV has no language columns to translate from")

    # Add target language columns if missing, and pad existing rows.
    for tl in target_langs:
        if tl not in header:
            header.append(tl)
    for row in rows[1:]:
        while len(row) < len(header):
            row.append("")

    # Count missing cells only (skip already-translated → resume support).
    missing = 0
    for row in rows[1:]:
        if len(row) <= src_col or not row[src_col].strip():
            continue
        for tl in target_langs:
            tc = header.index(tl)
            if not row[tc].strip():
                missing += 1
    _set_total(missing)

    count = 0

    try:
        for row in rows[1:]:
            if len(row) <= src_col:
                continue
            source = row[src_col]
            if not source.strip():
                continue
            for tl in target_langs:
                target_col = header.index(tl)
                if row[target_col].strip():
                    continue  # already translated — skip (resume)
                _check_control()
                _progress_start(source)
                translated = translate_text(source, tl, provider,
                                            api_url, api_key, model)
                row[target_col] = translated
                count += 1
                _progress_done(source, translated)
    except StopTranslation:
        if stopped_output:
            with open(stopped_output, "w", encoding="utf-8", newline="") as f:
                csv.writer(f).writerows(rows)
        raise

    with open(output_path, "w", encoding="utf-8", newline="") as f:
        csv.writer(f).writerows(rows)
    return count


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Translate PO/CSV with AI")
    parser.add_argument("--input",       required=True,  help="Input file path")
    parser.add_argument("--output",      required=True,  help="Output file path")
    parser.add_argument("--stopped-output", default="",
                        help="Path to write partial output when stopped/aborted.")
    parser.add_argument("--provider",    required=True,  choices=["local", "openrouter"])
    parser.add_argument("--api-url",     default="http://localhost:11434")
    parser.add_argument("--api-key",     default="")
    parser.add_argument("--model",       required=True)
    parser.add_argument("--target-lang",   required=True)
    parser.add_argument("--source-lang",   default="")
    parser.add_argument("--progress-file", default="")
    parser.add_argument("--control-file",  default="")
    parser.add_argument("--prompts-file",  default="")
    parser.add_argument("--min-free-mb",   type=int, default=800,
                        help="Abort if available system RAM drops below this (MB). 0 disables.")
    args = parser.parse_args()

    global _PROGRESS_FILE, _CONTROL_FILE, _PROMPTS, _MIN_FREE_MB
    _PROGRESS_FILE = args.progress_file
    _CONTROL_FILE = args.control_file
    _MIN_FREE_MB = max(0, args.min_free_mb)

    # Pre-flight: if we already start in trouble, fail loud before model load.
    if _MIN_FREE_MB > 0:
        free = _available_memory_mb()
        if 0 <= free < _MIN_FREE_MB:
            print(json.dumps({
                "type": "error",
                "message": (
                    f"Aborted before start: only {free} MB RAM free "
                    f"(< {_MIN_FREE_MB} MB threshold). Close other apps or pick a smaller model."
                ),
            }), flush=True)
            sys.exit(1)

    if args.prompts_file and os.path.exists(args.prompts_file):
        try:
            with open(args.prompts_file, "r", encoding="utf-8") as f:
                _PROMPTS = json.load(f)
        except Exception:
            _PROMPTS = {}

    ext = os.path.splitext(args.input)[1].lower()

    # Parse target languages (comma-separated)
    target_langs = [t.strip() for t in args.target_lang.split(",") if t.strip()]
    if not target_langs:
        print(json.dumps({"type": "error", "message": "No target languages specified"}), flush=True)
        sys.exit(1)

    try:
        if ext == ".po":
            # PO is single-language; use the first target
            count = translate_po(
                args.input, args.output, args.stopped_output, target_langs[0],
                args.provider, args.api_url, args.api_key, args.model,
            )
        elif ext == ".csv":
            count = translate_csv(
                args.input, args.output, args.stopped_output, target_langs,
                args.provider, args.api_url, args.api_key, args.model,
                args.source_lang,
            )
        else:
            print(json.dumps({"type": "error", "message": f"Unsupported format: {ext}"}), flush=True)
            sys.exit(1)

        print(json.dumps({"type": "done", "output": args.output, "count": count}), flush=True)

    except LowMemoryAbort as exc:
        print(json.dumps({
            "type": "stopped",
            "output": args.stopped_output or args.output,
            "count": _PROGRESS_CURRENT,
            "reason": "low_memory",
            "free_mb": exc.free_mb,
            "threshold_mb": exc.threshold_mb,
            "message": (
                f"⚠ Stopped to protect your system: only {exc.free_mb} MB RAM free "
                f"(threshold {exc.threshold_mb} MB). Pick a smaller model or close other apps."
            ),
        }), flush=True)
        sys.exit(0)

    except StopTranslation:
        print(json.dumps({
            "type": "stopped",
            "output": args.stopped_output or args.output,
            "count": _PROGRESS_CURRENT,
            "message": "Translation stopped by user",
        }), flush=True)
        sys.exit(0)

    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"type": "error", "message": str(exc)}), flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
