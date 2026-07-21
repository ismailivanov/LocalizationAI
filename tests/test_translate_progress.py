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
    m._RETRY_DELAYS = (0, 0)  # no real backoff in tests
    calls = []

    def flaky(messages, *a, **k):
        calls.append(1)
        if len(calls) == 1:
            raise RuntimeError("HTTP 429: rate limited")
        return "merhaba"

    m.translate_text.__globals__["_chat"] = flaky
    assert m.translate_text("hello", "tr", "openrouter", "", "k", "m") == "merhaba"
    assert len(calls) == 2


def _make_csv(path, n):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["keys", "en", "tr"])
        for i in range(n):
            w.writerow(["k%d" % i, "hello %d" % i, ""])


def _silence(fn, *a):
    real_out, real_err = sys.stdout, sys.stderr
    sys.stdout, sys.stderr = io.StringIO(), io.StringIO()
    try:
        return fn(*a)
    finally:
        sys.stdout, sys.stderr = real_out, real_err


def test_bad_strings_are_skipped_not_fatal():
    """A handful of dead strings must not sink the whole run."""
    m = _load()
    m._RETRY_DELAYS = (0, 0)  # no real backoff in tests
    # Two strings the backend never manages, however many times we retry.
    doomed = ("hello 5\n", "hello 12\n")

    def some_strings_never_work(messages, *a, **k):
        body = messages[-1]["content"]
        if any(d in body for d in doomed):
            raise RuntimeError("API error: model is currently at capacity")
        return "merhaba"

    m.translate_text.__globals__["_chat"] = some_strings_never_work

    with tempfile.TemporaryDirectory() as tmp:
        src, out = os.path.join(tmp, "in.csv"), os.path.join(tmp, "out.csv")
        _make_csv(src, 20)
        _silence(m.translate_csv, src, out, os.path.join(tmp, "p.csv"), ["tr"],
                 "openrouter", "", "k", "model", "en", 1)

        rows = list(csv.reader(open(out, encoding="utf-8")))
        translated = sum(1 for r in rows[1:] if r[2])
        assert translated == 18, translated
        assert len(m._SKIPPED) == 2
        # Skipped cells stay blank so a re-run retries exactly those.
        blank = [r[0] for r in rows[1:] if not r[2]]
        assert blank == ["k5", "k12"], blank


def test_dead_backend_aborts():
    """If nothing gets through it's a dead backend, not flakiness — stop."""
    m = _load()
    m._RETRY_DELAYS = (0, 0)  # no real backoff in tests

    def always_dies(messages, *a, **k):
        raise RuntimeError("API error: model is currently at capacity")

    m.translate_text.__globals__["_chat"] = always_dies

    with tempfile.TemporaryDirectory() as tmp:
        src, out = os.path.join(tmp, "in.csv"), os.path.join(tmp, "out.csv")
        partial = os.path.join(tmp, "p.csv")
        _make_csv(src, 200)
        try:
            _silence(m.translate_csv, src, out, partial, ["tr"], "openrouter",
                     "", "k", "model", "en", 1)
            raise AssertionError("expected the run to abort")
        except RuntimeError as exc:
            assert "in a row" in str(exc), exc
        # Gave up well before chewing through all 200 strings.
        assert len(m._SKIPPED) == m._MAX_FAILURE_STREAK
        assert not os.path.exists(out), "no final output on an aborted run"


def test_partial_survives_failure():
    """Writes are throttled, but every completed string must still be on disk."""
    m = _load()
    m._RETRY_DELAYS = (0, 0)  # no real backoff in tests
    done = []

    def dies_hard_after_six(messages, *a, **k):
        done.append(1)
        if len(done) > 6:
            raise ValueError("not retryable, not skippable")
        return "merhaba"

    m.translate_text.__globals__["_chat"] = dies_hard_after_six

    with tempfile.TemporaryDirectory() as tmp:
        src, out = os.path.join(tmp, "in.csv"), os.path.join(tmp, "out.csv")
        partial = os.path.join(tmp, "partial.csv")
        _make_csv(src, 200)

        try:
            _silence(m.translate_csv, src, out, partial, ["tr"], "openrouter",
                     "", "k", "model", "en", 1)
            raise AssertionError("expected the run to fail")
        except RuntimeError:
            pass

        rows = list(csv.reader(open(partial, encoding="utf-8")))
        assert sum(1 for r in rows[1:] if r[2]) == 6
        assert not os.path.exists(out), "no final output on a failed run"


def test_retryable_classification():
    m = _load()
    for msg in ("The model is currently at capacity due to high demand.",
                "HTTP 429: rate limited", "Connection error: timed out",
                "HTTP 503: upstream overloaded"):
        assert m._is_retryable(msg), msg
    for msg in ("HTTP 401: invalid api key", "HTTP 404: no such model",
                "Unsupported format: .txt",
                # Digits in the body must not read as a status code.
                'HTTP 404: {"message":"Grok 4.1 Fast is deprecated","code":404}',
                "HTTP 401: invalid key, user_id: user_500xKq",
                "HTTP 400: max_tokens 4290 exceeds limit"):
        assert not m._is_retryable(msg), msg


def test_passthrough_is_caught():
    """A model echoing the source must not be shipped as a translation."""
    m = _load()
    m._RETRY_DELAYS = (0, 0)
    m._sleep_interruptible = lambda s: None

    long_src = "this is a long line the model refuses to actually translate"
    short_src = "Diaz"          # a name — identical output is correct here
    calls = []

    def echoes(messages, *a, **k):
        calls.append(1)
        body = messages[-1]["content"]
        return long_src if long_src in body else short_src

    m.translate_text.__globals__["_chat"] = echoes

    # Short/untranslatable strings pass through untouched, as intended.
    assert m.translate_text(short_src, "tr", "openrouter", "", "k", "m") == short_src

    # A long line coming back verbatim is retried, then reported as a failure.
    calls.clear()
    try:
        m.translate_text(long_src, "tr", "openrouter", "", "k", "m")
        raise AssertionError("expected a PassthroughError")
    except m.PassthroughError as exc:
        msg = str(exc)
    assert "tr" in msg
    assert len(calls) == 2, calls      # one retry before giving up
    assert not m._is_retryable(msg)    # never worth a 90 s backoff


def test_skipped_not_counted_as_done():
    """The finished count must exclude strings that were never translated."""
    m = _load()
    m._RETRY_DELAYS = (0, 0)
    doomed = "hello 3\n"

    def one_never_works(messages, *a, **k):
        if doomed in messages[-1]["content"]:
            raise RuntimeError("API error: at capacity")
        return "merhaba"

    m.translate_text.__globals__["_chat"] = one_never_works

    with tempfile.TemporaryDirectory() as tmp:
        src, out = os.path.join(tmp, "in.csv"), os.path.join(tmp, "out.csv")
        _make_csv(src, 10)
        count = _silence(m.translate_csv, src, out, os.path.join(tmp, "p.csv"),
                         ["tr"], "openrouter", "", "k", "model", "en", 1)
        assert count == 9, count
        assert len(m._SKIPPED) == 1


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
