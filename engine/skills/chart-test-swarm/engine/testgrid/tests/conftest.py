"""Shared pytest configuration.

Several CLI tests assert on Typer's `--help` output (e.g. that `--category` is
listed). Typer renders that through rich, which emits ANSI colour when
FORCE_COLOR is set — and colour codes land *between* the two dashes, so
`"--category" in result.stdout` becomes false. CI sets FORCE_COLOR; a plain
local shell does not, which is why the suite passed locally and failed on the
runner. Pin the rendering environment so help output is plain text everywhere.
"""

from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def _plain_cli_output(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("FORCE_COLOR", raising=False)
    monkeypatch.setenv("NO_COLOR", "1")
    monkeypatch.setenv("TERM", "dumb")
