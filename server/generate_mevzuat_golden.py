"""Generate pinned real-text parser fixtures from Emsal-mcp.

Generated files are review artifacts. Run intentionally when the official
source snapshot changes; never update them implicitly from the test suite.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
from pathlib import Path

from mevzuat_ingest import (
    DEFAULT_LAWS,
    OFFICIAL_FINAL_ARTICLE,
    _add_emsal_python_paths,
    _search_document_id,
    fetch_full_text,
)
from mevzuat_parser import parse_legislation


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=Path(__file__).parent / "test" / "fixtures" / "mevzuat")
    parser.add_argument("--emsal-command", default="emsal-mcp")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    _add_emsal_python_paths(args.emsal_command)
    manifest = {}
    for law_no in DEFAULT_LAWS:
        document_id, _ = _search_document_id(law_no, args.emsal_command)
        document = fetch_full_text(document_id)
        text = document["text"].strip()
        parsed = parse_legislation(text, law_no)
        if parsed.errors:
            raise RuntimeError(f"{law_no}: " + " | ".join(parsed.errors))
        numeric = [int(a.id.split("/m.", 1)[1]) for a in parsed.articles if a.id.split("/m.", 1)[1].isdigit()]
        if max(numeric) < OFFICIAL_FINAL_ARTICLE[law_no]:
            raise RuntimeError(f"{law_no}: source incomplete, last numeric article {max(numeric)}")
        sample_indexes = sorted({0, len(parsed.articles) // 4, len(parsed.articles) // 2, (3 * len(parsed.articles)) // 4, len(parsed.articles) - 1})
        kinds = collections.Counter()
        for article in parsed.articles:
            component = article.id.split("/m.", 1)[1]
            for kind in ("gecici", "ek", "mukerrer", "mulga"):
                if component.startswith(kind + "-"):
                    kinds[kind] += 1
        golden = {
            "mevzuat_no": law_no,
            "document_id": document_id,
            "text_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
            "text_length": len(text),
            "official_final_article": OFFICIAL_FINAL_ARTICLE[law_no],
            "article_count": len(parsed.articles),
            "first_id": parsed.articles[0].id,
            "last_id": parsed.articles[-1].id,
            "special_counts": dict(kinds),
            "warnings": parsed.warnings,
            "samples": [
                {"id": parsed.articles[i].id, "text": parsed.articles[i].text}
                for i in sample_indexes
            ],
        }
        (args.out / f"{law_no}.txt").write_text(text + "\n", encoding="utf-8")
        (args.out / f"{law_no}.json").write_text(json.dumps(golden, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        manifest[law_no] = {k: golden[k] for k in ("document_id", "text_sha256", "text_length", "official_final_article", "article_count", "first_id", "last_id", "special_counts")}
        print(json.dumps({"mevzuat_no": law_no, "article_count": len(parsed.articles), "sha256": golden["text_sha256"]}, ensure_ascii=True), flush=True)
    (args.out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
