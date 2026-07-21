#!/usr/bin/env python3
"""Self-check for translate.py's partial-file and API-response handling.

    python3 tests/test_translate_progress.py
"""
import csv
import importlib.util
import io
import json
import os
import sys
import tempfile
import urllib.request

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPT = os.path.join(_HERE, os.pardir, "addons", "localization_ai",
                       "scripts", "translate.py")


def _load():
    spec = importlib.util.spec_from_file_location("translate", _SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _FakeResp:
    def __init__(self, body):
        self._body = body.encode("utf-8")

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_null_content():
    """Reasoning models return content=null — must not raise on .strip()."""
    m = _load()
    urllib.request.urlopen = lambda *a, **k: _FakeResp(json.dumps(
        {"choices": [{"message": {"content": None, "reasoning": "Merhaba"}}]}))
    assert m._chat([], "openrouter", "", "k", "x") == "Merhaba"

    urllib.request.urlopen = lambda *a, **k: _FakeResp(json.dumps(
        {"choices": [{"message": {"content": None}}]}))
    assert m._chat([], "openrouter", "", "k", "x") == ""


def test_retry_on_transient_error():
    m = _load()
    m.translate_text.__globals__["time"].sleep = lambda s: None
    calls = []

    def flaky(messages, *a, **k):
        calls.append(1)
        if len(calls) == 1:
            raise RuntimeError("HTTP 429: rate limited")
        return "merhaba"

    m.translate_text.__globals__["_chat"] = flaky
    assert m.translate_text("hello", "tr", "openrouter", "", "k", "m") == "merhaba"
    assert len(calls) == 2


def test_partial_survives_failure():
    """Writes are throttled, but every completed string must still be on disk."""
    m = _load()
    m.translate_text.__globals__["time"].sleep = lambda s: None
    done = []

    def dies_after_six(messages, *a, **k):
        done.append(1)
        if len(done) > 6:
            raise RuntimeError("boom")
        return "merhaba"

    m.translate_text.__globals__["_chat"] = dies_after_six

    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "in.csv")
        out = os.path.join(tmp, "out.csv")
        partial = os.path.join(tmp, "partial.csv")
        with open(src, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["keys", "en", "tr"])
            for i in range(20):
                w.writerow(["k%d" % i, "hello %d" % i, ""])

        real_stdout, sys.stdout = sys.stdout, io.StringIO()
        try:
            m.translate_csv(src, out, partial, ["tr"], "openrouter", "", "k",
                            "model", "en", 1)
            raise AssertionError("expected the run to fail")
        except RuntimeError:
            pass
        finally:
            sys.stdout = real_stdout

        rows = list(csv.reader(open(partial, encoding="utf-8")))
        assert sum(1 for r in rows[1:] if r[2]) == 6
        assert not os.path.exists(out), "no final output on a failed run"


def test_throttle_window():
    m = _load()
    assert m._due_for_partial() is True
    assert m._due_for_partial() is False
    m._LAST_PARTIAL_WRITE -= m._PARTIAL_MIN_INTERVAL + 1
    assert m._due_for_partial() is True


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok  %s" % name)
    print("all passed")
