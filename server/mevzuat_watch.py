"""Weekly, fail-safe legislation refresh runner.

All upstream access is delegated to Emsal-mcp; this module never scrapes a
public legislation site. The ingestor records article-level diffs.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
from pathlib import Path

from mevzuat_ingest import DEFAULT_LAWS, ingest_one


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Emsal-mcp mevzuat haftalık yenileme")
    parser.add_argument("--mevzuat-no", action="append", dest="numbers", help="İzlenecek mevzuat numarası; tekrarlanabilir")
    parser.add_argument("--db", type=Path, required=True, help="Profil SQLite DB")
    parser.add_argument("--emsal-command", default=os.environ.get("EMSAL_MCP", "emsal-mcp"))
    args = parser.parse_args(argv)
    numbers = args.numbers or list(DEFAULT_LAWS)
    unknown = [n for n in numbers if n not in DEFAULT_LAWS]
    if unknown:
        parser.error("Desteklenmeyen mevzuat numarası: " + ", ".join(unknown))
    conn = sqlite3.connect(args.db)
    conn.row_factory = sqlite3.Row
    results = []
    failures = []
    try:
        for number in numbers:
            try:
                with conn:
                    result = ingest_one(conn, number, emsal_command=args.emsal_command)
                results.append(result)
            except Exception as exc:
                failures.append({"mevzuat_no": number, "error": str(exc)})
    finally:
        conn.close()
    for result in results:
        print(json.dumps(result, ensure_ascii=True))
    for failure in failures:
        print(json.dumps(failure, ensure_ascii=True))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
