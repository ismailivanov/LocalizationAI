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
import threading
import time
import urllib.request
import urllib.error
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait


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

    # Reasoning models (grok, o-series, …) can return content=null and park the
    # text in `reasoning` — .strip() on None used to kill the whole run.
    msg = data["choices"][0].get("message") or {}
    content = msg.get("content") or msg.get("reasoning") or ""
    return content.strip()


_PROMPTS: dict = {}

# Map ISO codes → full language names so small local models understand.
_LANG_NAMES = {
    "af": "Afrikaans", "sq": "Albanian", "am": "Amharic", "ar": "Arabic",
    "hy": "Armenian", "az": "Azerbaijani", "eu": "Basque", "be": "Belarusian",
    "bn": "Bengali", "bs": "Bosnian", "bg": "Bulgarian", "my": "Burmese",
    "ca": "Catalan", "zh_CN": "Simplified Chinese", "zh_TW": "Traditional Chinese",
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
    "pt_BR": "Brazilian Portuguese", "pa": "Punjabi", "ro": "Romanian",
    "ru": "Russian", "sr": "Serbian", "si": "Sinhala", "sk": "Slovak",
    "sl": "Slovenian", "es": "Spanish", "es_419": "Latin American Spanish",
    "sw": "Swahili", "sv": "Swedish", "tl": "Tagalog", "ta": "Tamil",
    "te": "Telugu", "th": "Thai", "tr": "Turkish", "uk": "Ukrainian",
    "ur": "Urdu", "uz": "Uzbek", "vi": "Vietnamese", "cy": "Welsh",
}


def _lang_label(code: str) -> str:
    # Accept any separator style the user typed (Godot uses "_", many tools use
    # "-") and fall back to the bare language root, then the raw code itself.
    c = code.strip()
    for key in (c, c.replace("-", "_"), c.replace("_", "-")):
        if key in _LANG_NAMES:
            return _LANG_NAMES[key]
    root = c.replace("_", "-").split("-")[0]
    return _LANG_NAMES.get(root, c)


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
    # One retry: a transient 429/5xx on string 137 of 5157 shouldn't kill the run.
    for attempt in range(2):
        try:
            result = _chat(messages, provider, api_url, api_key, model)
            break
        except RuntimeError:
            if attempt == 1:
                raise
            time.sleep(2)
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
_LAST_DONE_TARGET_LANG: str = ""
_CONTROL_FILE: str = ""
# Guards _PROGRESS_*, _LAST_DONE_*, progress-file writes, and partial-file
# writes when workers > 1.
_PROGRESS_LOCK = threading.Lock()
_INITIAL_PPID: int = 0  # PID of the Godot editor that launched us; if this
                        # changes (Godot crashed/quit) we treat it as a stop so
                        # the progress file is written and the child exits.


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
    global _LAST_DONE_TARGET_LANG
    _PROGRESS_TOTAL = total
    _PROGRESS_CURRENT = 0
    _LAST_DONE_SOURCE = ""
    _LAST_DONE_TRANSLATED = ""
    _LAST_DONE_TARGET_LANG = ""
    _write_progress("", "", "")


def _progress_start(source: str, target_lang: str) -> None:
    """Called BEFORE the API call — translated is empty (in-progress)."""
    _write_progress(source, "", target_lang)


def _progress_done(source: str, translated: str, target_lang: str) -> None:
    """Called AFTER the API call — advances counter, records both."""
    global _PROGRESS_CURRENT, _LAST_DONE_SOURCE, _LAST_DONE_TRANSLATED
    global _LAST_DONE_TARGET_LANG
    _PROGRESS_CURRENT += 1
    _LAST_DONE_SOURCE = source
    _LAST_DONE_TRANSLATED = translated
    _LAST_DONE_TARGET_LANG = target_lang
    _write_progress(source, translated, target_lang)
    print(json.dumps({
        "type":       "progress",
        "current":    _PROGRESS_CURRENT,
        "total":      _PROGRESS_TOTAL,
        "source":     source[:80],
        "translated": translated[:80],
        "target_lang": target_lang,
    }), flush=True)


def _write_progress(source: str, translated: str, target_lang: str) -> None:
    if not _PROGRESS_FILE:
        return
    try:
        with open(_PROGRESS_FILE, "w", encoding="utf-8") as f:
            json.dump({
                "current":    _PROGRESS_CURRENT,
                "total":      _PROGRESS_TOTAL,
                "source":     source[:200],
                "translated": translated[:200],
                "target_lang": target_lang,
                "last_source":     _LAST_DONE_SOURCE[:200],
                "last_translated": _LAST_DONE_TRANSLATED[:200],
                "last_target_lang": _LAST_DONE_TARGET_LANG,
            }, f)
    except OSError:
        pass


_LAST_PARTIAL_WRITE = 0.0
_PARTIAL_MIN_INTERVAL = 5.0


def _due_for_partial() -> bool:
    """Rate-limit the partial rewrite.

    The partial is rendered whole and re-written after every completed string.
    On a 17 MB / 5000-row CSV × 3 languages that is tens of GB of disk churn per
    run, which starves the page cache and trips the low-memory abort. Every
    exit path (stop, error, finish) flushes unconditionally, so the worst case
    from throttling is losing the last few seconds of a hard crash.
    """
    global _LAST_PARTIAL_WRITE
    now = time.monotonic()
    if now - _LAST_PARTIAL_WRITE < _PARTIAL_MIN_INTERVAL:
        return False
    _LAST_PARTIAL_WRITE = now
    return True


def _check_parent_alive() -> None:
    """Raise StopTranslation if the parent process (Godot editor) is gone.

    On POSIX, an orphaned child gets reparented to init (PID 1) — if our
    parent PID changed from the one we recorded at startup, the editor died
    and we should flush progress and exit instead of running on as a zombie.
    On Windows we open the parent handle and check it; if that fails we
    assume the parent is gone.
    """
    if _INITIAL_PPID <= 1:
        return
    try:
        if os.name == "nt":
            import ctypes
            PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
            STILL_ACTIVE = 259
            h = ctypes.windll.kernel32.OpenProcess(
                PROCESS_QUERY_LIMITED_INFORMATION, False, _INITIAL_PPID
            )
            if not h:
                raise StopTranslation()
            exit_code = ctypes.c_ulong()
            ok = ctypes.windll.kernel32.GetExitCodeProcess(h, ctypes.byref(exit_code))
            ctypes.windll.kernel32.CloseHandle(h)
            if not ok or exit_code.value != STILL_ACTIVE:
                raise StopTranslation()
        else:
            if os.getppid() != _INITIAL_PPID:
                raise StopTranslation()
    except StopTranslation:
        raise
    except Exception:
        # Don't let a probe failure abort the run.
        pass


def _check_control() -> None:
    """Check the control file for pause/stop commands between translations.
    Also enforces the low-memory safety abort and detects parent death so we
    flush progress and exit if the editor that spawned us is gone."""
    _check_memory()
    _check_parent_alive()
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


# ── Parallel runner ─────────────────────────────────────────────────────────

def _run_translations(tasks: list, workers: int, provider: str, api_url: str,
                      api_key: str, model: str, on_done) -> None:
    """Translate `tasks` in parallel with bounded concurrency.

    Each task is a dict with at least `source` and `target_lang`. `on_done(task,
    translated)` is invoked exactly once per completed task, serialized under
    `_PROGRESS_LOCK`, before the partial file is written.

    Pause/stop are honored between dispatches via `_check_control()`; in-flight
    requests are allowed to finish (we can't abort an HTTP call mid-flight),
    after which the appropriate exception is re-raised.
    """
    if workers < 1:
        workers = 1

    if workers == 1:
        for t in tasks:
            _check_control()
            _progress_start(t["source"], t["target_lang"])
            tr = translate_text(t["source"], t["target_lang"], provider,
                                api_url, api_key, model)
            on_done(t, tr)
            _progress_done(t["source"], tr, t["target_lang"])
        return

    pending = list(tasks)
    in_flight: dict = {}
    stop_exc: BaseException = None

    def _submit(pool: ThreadPoolExecutor) -> None:
        t = pending.pop(0)
        fut = pool.submit(translate_text, t["source"], t["target_lang"],
                          provider, api_url, api_key, model)
        in_flight[fut] = t

    with ThreadPoolExecutor(max_workers=workers) as pool:
        # Prime the pool, honoring pause/stop between submissions.
        while pending and len(in_flight) < workers and stop_exc is None:
            try:
                _check_control()
            except StopTranslation as exc:
                stop_exc = exc
                break
            _submit(pool)

        while in_flight:
            done, _pending = wait(list(in_flight.keys()),
                                  return_when=FIRST_COMPLETED)
            for fut in done:
                t = in_flight.pop(fut)
                try:
                    tr = fut.result()
                except Exception as exc:  # noqa: BLE001
                    # Surface the first error; drain remaining in-flight then
                    # re-raise so main() can report it.
                    if stop_exc is None:
                        stop_exc = exc
                    continue
                with _PROGRESS_LOCK:
                    on_done(t, tr)
                    _progress_done(t["source"], tr, t["target_lang"])

            while pending and len(in_flight) < workers and stop_exc is None:
                try:
                    _check_control()
                except StopTranslation as exc:
                    stop_exc = exc
                    break
                _submit(pool)

    if stop_exc is not None:
        raise stop_exc


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
                 api_key: str, model: str, workers: int = 1) -> int:
    with open(input_path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    # Parse into blocks so we can render the partial file at any point during
    # parallel translation (completions arrive out of order).
    blocks: list = []  # ("raw", [str]) | ("entry", dict)
    pending_raw: list = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.startswith("msgid "):
            pending_raw.append(line)
            i += 1
            continue

        if pending_raw:
            blocks.append(("raw", pending_raw))
            pending_raw = []

        msgid_lines = [line]
        raw_id = line[6:].strip()
        i += 1
        while i < len(lines) and lines[i].startswith('"'):
            raw_id += "\n" + lines[i].strip()
            msgid_lines.append(lines[i])
            i += 1
        msgid = _unescape_po(raw_id.strip('"'))

        msgstr_lines: list = []
        existing = ""
        if i < len(lines) and lines[i].startswith("msgstr "):
            raw_str = lines[i][7:].strip()
            msgstr_lines.append(lines[i])
            i += 1
            while i < len(lines) and lines[i].startswith('"'):
                raw_str += "\n" + lines[i].strip()
                msgstr_lines.append(lines[i])
                i += 1
            existing = _unescape_po(raw_str.strip('"'))

        if msgid and not existing:
            blocks.append(("entry", {
                "msgid_lines": msgid_lines,
                "msgid": msgid,
                "msgstr_lines": msgstr_lines or ['msgstr ""\n'],
                "translated": False,
            }))
        else:
            blocks.append(("raw", msgid_lines + msgstr_lines))

    if pending_raw:
        blocks.append(("raw", pending_raw))

    tasks = [{
        "source": p["msgid"],
        "target_lang": target_lang,
        "_block": p,
    } for kind, p in blocks if kind == "entry"]

    _set_total(len(tasks))

    def _render() -> list:
        out: list = []
        for kind, payload in blocks:
            if kind == "raw":
                out.extend(payload)
            else:
                out.extend(payload["msgid_lines"])
                out.extend(payload["msgstr_lines"])
        return out

    def _on_done(t: dict, tr: str) -> None:
        block = t["_block"]
        block["msgstr_lines"] = [f'msgstr "{_escape_po(tr)}"\n']
        block["translated"] = True
        if _due_for_partial():
            _write_text_atomic(stopped_output, _render())

    try:
        _run_translations(tasks, workers, provider, api_url, api_key, model,
                          _on_done)
    except Exception:  # stop, low memory, or a hard failure — flush either way
        _write_text_atomic(stopped_output, _render())
        raise

    with open(output_path, "w", encoding="utf-8") as f:
        f.writelines(_render())
    _remove_quiet(stopped_output)
    return sum(1 for _, p in blocks if isinstance(p, dict) and p.get("translated"))


# ── CSV parser / writer ──────────────────────────────────────────────────────

def translate_csv(input_path: str, output_path: str, stopped_output: str,
                  target_langs: list, provider: str, api_url: str,
                  api_key: str, model: str, source_lang: str = "",
                  workers: int = 1) -> int:
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

    tasks: list = []
    for row_idx, row in enumerate(rows[1:], start=1):
        if len(row) <= src_col:
            continue
        source = row[src_col]
        if not source.strip():
            continue
        for tl in target_langs:
            target_col = header.index(tl)
            if row[target_col].strip():
                continue
            tasks.append({
                "source": source,
                "target_lang": tl,
                "_row": row_idx,
                "_col": target_col,
            })

    def _on_done(t: dict, tr: str) -> None:
        rows[t["_row"]][t["_col"]] = tr
        if _due_for_partial():
            _write_csv_atomic(stopped_output, rows)

    try:
        _run_translations(tasks, workers, provider, api_url, api_key, model,
                          _on_done)
    except Exception:  # stop, low memory, or a hard failure — flush either way
        _write_csv_atomic(stopped_output, rows)
        raise

    with open(output_path, "w", encoding="utf-8", newline="") as f:
        csv.writer(f).writerows(rows)
    # Final file written — the partial is now redundant.
    _remove_quiet(stopped_output)
    return len(tasks)


def _write_csv_atomic(path: str, rows: list) -> None:
    if not path:
        return
    try:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="") as f:
            csv.writer(f).writerows(rows)
        os.replace(tmp, path)
    except OSError:
        pass


def _write_text_atomic(path: str, lines: list) -> None:
    if not path:
        return
    try:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.writelines(lines)
        os.replace(tmp, path)
    except OSError:
        pass


def _remove_quiet(path: str) -> None:
    if not path:
        return
    try:
        if os.path.exists(path):
            os.remove(path)
    except OSError:
        pass


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
    parser.add_argument("--workers",       type=int, default=1,
                        help="Concurrent translation requests in flight. 1 = sequential.")
    args = parser.parse_args()

    global _PROGRESS_FILE, _CONTROL_FILE, _PROMPTS, _MIN_FREE_MB, _INITIAL_PPID
    _PROGRESS_FILE = args.progress_file
    _CONTROL_FILE = args.control_file
    _MIN_FREE_MB = max(0, args.min_free_mb)
    try:
        _INITIAL_PPID = os.getppid()
    except Exception:
        _INITIAL_PPID = 0

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
        workers = max(1, args.workers)
        if ext == ".po":
            # PO is single-language; use the first target
            count = translate_po(
                args.input, args.output, args.stopped_output, target_langs[0],
                args.provider, args.api_url, args.api_key, args.model,
                workers,
            )
        elif ext == ".csv":
            count = translate_csv(
                args.input, args.output, args.stopped_output, target_langs,
                args.provider, args.api_url, args.api_key, args.model,
                args.source_lang, workers,
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
        # Report the partial too — `_on_done` has been flushing it after every
        # string, so an error at 136/5157 still has 136 translations on disk.
        print(json.dumps({
            "type": "error",
            "message": str(exc),
            "output": args.stopped_output or args.output,
            "count": _PROGRESS_CURRENT,
        }), flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
