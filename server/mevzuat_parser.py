"""Pure, network-free parser for Turkish legislation text.

The parser deliberately keeps the source text intact.  It reports suspicious
or unsupported article markers instead of silently dropping them.
"""

from __future__ import annotations

import re

# Ayristirma mantigi degistiginde artirilir; snapshot_version hash'ine
# katilir ki ayni resmi metin yeni parser'la yeniden yayimlanabilsin
# (istemciler guncellemeyi gorur).
PARSER_VERSION = 2
from dataclasses import asdict, dataclass, field
from typing import Any


_ARTICLE_RE = re.compile(
    r"^\s*MADDE\s+(?P<number>(?:(?:Geçici|Gecici|Ek|Mükerrer|Mü̈lga|Mülga)\s+\d+|\d+\.?(?:/[A-Za-z]+)?))\s*[-–—:]", re.IGNORECASE
)
_ARTICLE_CANDIDATE_RE = re.compile(r"^\s*MADDE\b", re.IGNORECASE)
_PARAGRAPH_RE = re.compile(r"^\s*\(?(?P<number>\d+)\)?\s*[-.)]\s+(?P<text>.+)$")
_CHANGE_RE = re.compile(
    r"\((?P<kind>Değişik|Mülga|Ek|İptal|Yürürlükten kaldırıldı)\s*:\s*[^)]*\)",
    re.IGNORECASE,
)
_PART_RE = re.compile(r"^\s*(?P<title>(?:BİRİNCİ|İKİNCİ|ÜÇÜNCÜ|DÖRDÜNCÜ|BEŞİNCİ|ALTINCI|YEDİNCİ|SEKİZİNCİ|DOKUZUNCU|ONUNCU)\s+KISIM.*)$", re.IGNORECASE)
_SECTION_RE = re.compile(r"^\s*(?P<title>(?:BİRİNCİ|İKİNCİ|ÜÇÜNCÜ|DÖRDÜNCÜ|BEŞİNCİ|ALTINCI|YEDİNCİ|SEKİZİNCİ|DOKUZUNCU|ONUNCU)\s+BÖLÜM.*)$", re.IGNORECASE)


@dataclass
class Paragraph:
    number: int | None
    text: str


@dataclass
class Article:
    id: str
    number: str
    title: str
    text: str
    paragraphs: list[Paragraph] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)
    part: str | None = None
    section: str | None = None


@dataclass
class ParsedLegislation:
    articles: list[Article]
    warnings: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    def as_dict(self) -> dict[str, Any]:
        return {
            "articles": [asdict(article) for article in self.articles],
            "warnings": self.warnings,
            "errors": self.errors,
        }


def _clean_text(text: str) -> str:
    text = text.replace("\ufeff", "").replace("\u00a0", " ").replace("\u00ad", "")
    # Common UTF-8-as-Windows-1252 artefacts from HTML-to-Markdown conversion.
    text = text.replace("â€“", "–").replace("â€”", "—").replace("Â", "")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return "\n".join(line.rstrip() for line in text.split("\n")).strip()


def canonical_article_number(raw: str) -> str:
    """Return the stable article component used in ``<no>/m.<component>``."""
    value = raw.strip().lower().replace("–", "-").replace("—", "-")
    value = re.sub(r"\s+", "", value).rstrip(".,:;")
    value = value.replace("mükerrer", "mukerrer-")
    value = value.replace("mukerrer-", "mukerrer-")
    for prefix in ("geçici", "gecici", "ek", "mülga", "mulga"):
        if value.startswith(prefix) and value[len(prefix):].lstrip("- ").isdigit():
            value = prefix.replace("ç", "c").replace("ü", "u").replace("lga", "lga") + "-" + value[len(prefix):].lstrip("- ")
            break
    return value


def canonical_article_id(mevzuat_no: str, raw: str) -> str:
    return f"{mevzuat_no}/m.{canonical_article_number(raw)}"


def _article_parts(raw_number: str) -> tuple[str, str]:
    number = canonical_article_number(raw_number)
    return number, number


def parse_legislation(text: str, mevzuat_no: str) -> ParsedLegislation:
    text = _clean_text(text)
    raw_lines = text.splitlines()
    # Emsal-mcp's HTML-to-Markdown output occasionally puts ``Madde`` and its
    # number on adjacent lines.  Join only this unambiguous marker pair.
    lines: list[str] = []
    index = 0
    while index < len(raw_lines):
        same_line_special = re.match(
            r"^\s*(Geçici|Gecici|Ek|Mükerrer|Mülga)\s+Madde\s+(\d+)\s*([-–—:].*)$",
            raw_lines[index],
            re.IGNORECASE,
        )
        if same_line_special:
            lines.append(
                f"Madde {same_line_special.group(1)} {same_line_special.group(2)} {same_line_special.group(3)}"
            )
            index += 1
            continue
        # Official texts may put "Geçici"/"Ek" on the line before "Madde".
        if re.fullmatch(r"\s*(Geçici|Gecici|Ek|Mükerrer|Mülga)\s*", raw_lines[index], re.IGNORECASE) and index + 1 < len(raw_lines):
            next_index = index + 1
            while next_index < len(raw_lines) and not raw_lines[next_index].strip():
                next_index += 1
            if next_index + 1 < len(raw_lines) and re.fullmatch(r"\s*Madde\s*", raw_lines[next_index], re.IGNORECASE):
                number_index = next_index + 1
                while number_index < len(raw_lines) and not raw_lines[number_index].strip():
                    number_index += 1
                split_prefixed = re.match(r"^\s*(\d+)\s*([-–—:].*)$", raw_lines[number_index]) if number_index < len(raw_lines) else None
                if split_prefixed:
                    prefix = raw_lines[index].strip()
                    lines.append(f"Madde {prefix} {split_prefixed.group(1)} {split_prefixed.group(2)}")
                    index = number_index + 1
                    continue
            prefixed = re.match(r"^\s*Madde\s+(\d+)\s*([-–—:].*)$", raw_lines[next_index], re.IGNORECASE) if next_index < len(raw_lines) else None
            if prefixed:
                prefix = raw_lines[index].strip()
                lines.append(f"Madde {prefix} {prefixed.group(1)} {prefixed.group(2)}")
                index = next_index + 1
                continue
            # "Geçici" / "Madde 9" / "-" üç ayrı satıra bölünmüş olabilir (4857).
            bare = re.fullmatch(r"\s*Madde\s+(\d+)\s*", raw_lines[next_index], re.IGNORECASE) if next_index < len(raw_lines) else None
            if bare:
                sep_index = next_index + 1
                while sep_index < len(raw_lines) and not raw_lines[sep_index].strip():
                    sep_index += 1
                if sep_index < len(raw_lines) and re.match(r"^\s*[-–—:]", raw_lines[sep_index]):
                    prefix = raw_lines[index].strip()
                    lines.append(f"Madde {prefix} {bare.group(1)} {raw_lines[sep_index].strip()}")
                    index = sep_index + 1
                    continue
        # Some HTML conversions split 38/A as "Madde 38", "/A", "–".
        split_suffix = re.fullmatch(r"\s*Madde\s+(\d+)\s*", raw_lines[index], re.IGNORECASE)
        if split_suffix and index + 2 < len(raw_lines) and re.fullmatch(r"\s*/([A-Za-z]+)\s*", raw_lines[index + 1]) and re.match(r"^\s*[-–—:]", raw_lines[index + 2]):
            suffix = raw_lines[index + 1].strip()
            separator_tail = raw_lines[index + 2].strip()
            lines.append(f"Madde {split_suffix.group(1)}{suffix} {separator_tail}")
            index += 3
            continue
        # Or split only the separator onto the following line.
        split_separator = re.fullmatch(r"\s*Madde\s+((?:\d+\.?(?:/[A-Za-z]+)?)|(?:(?:Geçici|Gecici|Ek|Mükerrer|Mülga)\s+\d+))\s*", raw_lines[index], re.IGNORECASE)
        if split_separator and index + 1 < len(raw_lines) and re.match(r"^\s*[-–—:]", raw_lines[index + 1]):
            lines.append(f"Madde {split_separator.group(1)} {raw_lines[index + 1].strip()}")
            index += 2
            continue
        if re.fullmatch(r"\s*madde\s*", raw_lines[index], re.IGNORECASE) and index + 1 < len(raw_lines):
            number_index = index + 1
            while number_index < len(raw_lines) and not raw_lines[number_index].strip():
                number_index += 1
            if number_index < len(raw_lines) and re.match(r"^\s*(?:[0-9]+(?:/[A-Za-z]+)?|(?:Geçici|Gecici|Ek|Mükerrer|Mülga)\s+\S+)\s*[-–—:]", raw_lines[number_index], re.IGNORECASE):
                lines.append("Madde " + raw_lines[number_index].strip())
                index = number_index + 1
                continue
        # HTML donusumu "İKİNCİ" ve "BÖLÜM/KISIM" kelimelerini ayri satirlara
        # bolabiliyor; birlestir ki _PART_RE/_SECTION_RE yakalayabilsin.
        if (
            re.fullmatch(
                r"\s*(BİRİNCİ|İKİNCİ|ÜÇÜNCÜ|DÖRDÜNCÜ|BEŞİNCİ|ALTINCI|YEDİNCİ|SEKİZİNCİ|DOKUZUNCU|ONUNCU)\s*",
                raw_lines[index],
                re.IGNORECASE,
            )
            and index + 1 < len(raw_lines)
            and re.match(r"^\s*(KISIM|BÖLÜM)\b", raw_lines[index + 1], re.IGNORECASE)
        ):
            lines.append(raw_lines[index].strip() + " " + raw_lines[index + 1].strip())
            index += 2
            continue
        lines.append(raw_lines[index])
        index += 1
    result = ParsedLegislation(articles=[])
    current: Article | None = None
    current_part: str | None = None
    current_section: str | None = None
    pending_title: str | None = None
    outside_main_text = False
    preamble: list[str] = []

    def finish() -> None:
        nonlocal current
        if current is None:
            return
        current.text = "\n".join(line for line in current.text.splitlines()).strip()
        current.paragraphs = [
            Paragraph(number=p.number, text=p.text.strip())
            for p in current.paragraphs
            if p.text.strip()
        ]
        if not current.text:
            result.errors.append(f"Boş madde gövdesi: {current.number}")
        result.articles.append(current)
        current = None

    def next_nonempty(start: int) -> int:
        j = start
        while j < len(lines) and not lines[j].strip():
            j += 1
        return j

    def looks_like_heading(s: str) -> bool:
        # Madde basligi: kisa, cumle noktalamasiyla bitmeyen, fikra/bent
        # isaretiyle baslamayan serbest satir. Resmi metinlerde "Madde N -"
        # satirinin hemen ustunde durur.
        return (
            0 < len(s) <= 150
            and not _PARAGRAPH_RE.match(s)
            and not s.startswith("(")
            and not re.match(r"^[0-9A-Za-zÇĞİÖŞÜçğıöşü]\)", s)
            and s[-1] not in ".;:,)]»\"'"
            and any(ch.isalpha() for ch in s)
        )

    line_no = 0
    while line_no < len(lines):
        line = lines[line_no]
        line_no += 1
        stripped = line.strip()
        if not stripped:
            if current is not None:
                current.text += "\n"
            continue
        if not outside_main_text and "İŞLENEMEYEN HÜKÜMLER" in stripped.upper():
            finish()
            outside_main_text = True
            result.warnings.append("Kanuna işlenemeyen hükümler bölümü madde ağacına dahil edilmedi")
            continue
        if outside_main_text:
            continue
        if (part := _PART_RE.match(stripped)):
            current_part, current_section = part.group("title"), None
            continue
        if (section := _SECTION_RE.match(stripped)):
            current_section = section.group("title")
            # HTML donusumunde bolum adi ("Tutuklama" gibi) takip eden
            # satir(lar)a sarkabiliyor. Bir sonraki madde basligina veya
            # isaretcisine kadar (en fazla 3 satir) bolum adina kat.
            absorbed = 0
            while absorbed < 3:
                j = next_nonempty(line_no)
                if j >= len(lines):
                    break
                cand = lines[j].strip()
                after = next_nonempty(j + 1)
                if (
                    _ARTICLE_RE.match(lines[j])
                    or _ARTICLE_CANDIDATE_RE.match(cand)
                    or _PART_RE.match(cand)
                    or _SECTION_RE.match(cand)
                    or not looks_like_heading(cand)
                    or (after < len(lines) and _ARTICLE_RE.match(lines[after]))
                ):
                    break
                current_section = f"{current_section} {cand}".strip()
                line_no = j + 1
                absorbed += 1
            continue

        match = _ARTICLE_RE.match(line)
        if match:
            finish()
            raw_number = match.group("number")
            if not re.fullmatch(
                r"(?:\d+\.?(?:/[A-Za-z]+)?|(?:Geçici|Gecici|Ek|Mükerrer|Mülga)\s+\d+)",
                raw_number,
                re.IGNORECASE,
            ):
                result.errors.append(f"Geçersiz madde numarası ({line_no}. satır): {raw_number}")
                continue
            number = canonical_article_number(raw_number)
            current = Article(
                id=canonical_article_id(mevzuat_no, raw_number),
                number=number,
                title=pending_title or "",
                text="",
                metadata={"madde_no_raw": raw_number},
                part=current_part,
                section=current_section,
            )
            header_tail = line[match.end():].strip()
            if header_tail:
                if not pending_title:
                    current.title = header_tail
                current.text = header_tail
            pending_title = None
            continue
        # Bir sonraki dolu satir "Madde N -" ise bu satir o maddenin
        # basligidir; onceki maddenin govdesine EKLENMEZ (gruplama hatasi).
        j = next_nonempty(line_no)
        if j < len(lines) and _ARTICLE_RE.match(lines[j]) and looks_like_heading(stripped):
            pending_title = stripped
            continue
        if current is None:
            if re.match(r"^\s*[IVXLCDM]+\.\s+", stripped, re.IGNORECASE):
                pending_title = stripped
            preamble.append(stripped)
            continue

        changes = _CHANGE_RE.findall(stripped)
        if changes:
            current.metadata.setdefault("degisiklik_notlari", []).extend(
                match.group(0) for match in _CHANGE_RE.finditer(stripped)
            )
        paragraph = _PARAGRAPH_RE.match(line)
        current.text += "\n" + line
        if paragraph and (not current.paragraphs or current.paragraphs[-1].text.strip()):
            current.paragraphs.append(Paragraph(int(paragraph.group("number")), paragraph.group("text")))
        elif current.paragraphs:
            current.paragraphs[-1].text += "\n" + line

    finish()
    if preamble:
        result.warnings.append(f"Madde öncesi {len(preamble)} satır korunmadı; metadata dışı başlık olarak kaldı")
    if not result.articles:
        result.errors.append("Hiçbir MADDE başlığı bulunamadı")
    seen: set[str] = set()
    for article in result.articles:
        if article.id in seen:
            result.errors.append(f"Aynı kanonik madde ID'si birden fazla üretildi: {article.id}")
        seen.add(article.id)
    return result


def article_to_row(article: Article) -> dict[str, Any]:
    return {
        "id": article.id,
        "sira": None,
        "baslik": article.title,
        "madde_no_raw": article.metadata.get("madde_no_raw", article.number),
        "metin": article.text,
        "metadata_json": {
            **article.metadata,
            "fikralar": [asdict(p) for p in article.paragraphs],
            "part": article.part,
            "section": article.section,
        },
    }
