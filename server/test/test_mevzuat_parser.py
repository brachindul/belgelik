import json
import hashlib
import collections
from pathlib import Path

import pytest

from mevzuat_parser import canonical_article_id, parse_legislation


FIXTURES = Path(__file__).parent / "fixtures" / "mevzuat"
LAWS = ["2709", "4721", "6098", "6102", "6100", "5237", "5271", "2577", "2004"]


@pytest.mark.parametrize("law", LAWS)
def test_each_starting_law_has_golden_parser_fixture(law):
    text = (FIXTURES / f"{law}.txt").read_text(encoding="utf-8")
    golden = json.loads((FIXTURES / f"{law}.json").read_text(encoding="utf-8"))
    parsed = parse_legislation(text, law)
    assert parsed.errors == []
    assert hashlib.sha256(text.strip().encode("utf-8")).hexdigest() == golden["text_sha256"]
    assert len(text.strip()) == golden["text_length"]
    assert len(parsed.articles) == golden["article_count"]
    assert parsed.articles[0].id == golden["first_id"]
    assert parsed.articles[-1].id == golden["last_id"]
    by_id = {article.id: article for article in parsed.articles}
    assert len(by_id) == len(parsed.articles), "duplicate canonical article ID"
    numeric = [int(a.id.split('/m.', 1)[1]) for a in parsed.articles if a.id.split('/m.', 1)[1].isdigit()]
    assert max(numeric) == golden["official_final_article"]
    for sample in golden["samples"]:
        assert by_id[sample["id"]].text == sample["text"]
    kinds = collections.Counter()
    for article in parsed.articles:
        component = article.id.split('/m.', 1)[1]
        for kind in ("gecici", "ek", "mukerrer", "mulga"):
            if component.startswith(kind + '-'):
                kinds[kind] += 1
    assert dict(kinds) == golden["special_counts"]


def test_special_article_ids_and_change_notes_are_preserved():
    parsed = parse_legislation(
        """MADDE Geçici 1 - Başlık\n(Değişik: 1/1/2020-1 md.)\n1 - İlk fıkra\n\nMADDE Ek 3 - Ek hüküm\nMetin\n\nMADDE Mükerrer 5 - Mükerrer hüküm\nMetin""",
        "6098",
    )
    assert parsed.errors == []
    assert [a.id for a in parsed.articles] == [
        "6098/m.gecici-1",
        "6098/m.ek-3",
        "6098/m.mukerrer-5",
    ]
    assert parsed.articles[0].metadata["degisiklik_notlari"] == ["(Değişik: 1/1/2020-1 md.)"]
    assert parsed.articles[0].paragraphs[0].number == 1


def test_unparseable_article_marker_is_an_error_not_silently_skipped():
    parsed = parse_legislation("MADDE 12 ??? - başlık\nHüküm", "6098")
    assert parsed.errors
    assert "MADDE" in parsed.errors[0]


def test_canonical_id_helper():
    assert canonical_article_id("2709", "36") == "2709/m.36"
