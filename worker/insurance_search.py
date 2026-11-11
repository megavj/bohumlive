"""Read-only 5111 insurance search; standard library, no credentials or query logs.

The entire insurance document collection is eligible, including training material,
newsletters, commission tables and incentive notices. Customer/message sources are
rejected using their original metadata before excerpts are selected. Only the seven
allow-listed evidence fields leave this module; local paths and URLs never do.
"""
from __future__ import annotations

from functools import lru_cache
import html
import json
from pathlib import Path
import re
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

SEARCH_URL = "http://127.0.0.1:5111/search"
MAX_SOURCES = 8
EXCERPT_CHARS = 1600
SEARCH_SECONDS = 45.0
REQUEST_SECONDS = 20.0
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
PRODUCT_CATALOG_JSON = Path.home() / "Library/Application Support/AskQueue/product-catalog.json"

# Explicit deny-list for original document titles and provenance. Section/table
# headings describe public insurance content, not its provenance.
FORBIDDEN_SOURCE_MARKERS = (
    "고객", "계약자", "피보험자", "보험노트", "카톡", "카카오톡", "메일", "이메일",
    "문자메시지", "문자대화", "텔레그램", "개인정보", "상담일지", "상담기록",
    "customer", "client", "policyholder", "kakao", "mail", "inbox", "outbox",
    "message", "messenger", "telegram", "whatsapp", "intake", "pendingoriginals",
)
SOURCE_MARKER_FIELDS = frozenset((
    "title", "document_title", "doc", "name", "filename", "file_name", "file",
    "path", "file_path", "filepath", "source_path", "folder", "directory",
    "source", "source_file", "source_name", "url", "uri", "label",
    "doc_type", "doc_type_canonical", "category", "collection", "channel",
    "자료", "경로", "제목", "종류",
))
CONTENT_HEADING_FIELDS = frozenset(("section_title", "table_title", "sectiontitle", "tabletitle"))
# Only whole, generic public titles qualify. Never remove a customer phrase
# from an otherwise private filename such as '고객 안내_김철수.pdf'.
PUBLIC_CUSTOMER_TITLES = re.compile(
    r"(?:고객\s*(?:응대(?:\s*화법)?|상담\s*화법)\s*(?:사내\s*)?교육\s*(?:자료|교재)"
    r"|계약자\s*변경\s*(?:안내\s*약관|업무\s*안내)"
    r"|(?:계약자|피보험자)\s*(?:의\s*)?(?:의무|범위|정의|권리와\s*의무)\s*(?:안내|약관)"
    r"|계약자\s*및\s*피보험자의\s*의무\s*약관)"
)
DOCUMENT_EXTENSION = re.compile(r"\.(?:pdf|hwpx?|docx?|pptx?|xlsx?|txt|png|jpe?g)$", re.I)
SYN = (
    (r"실비", "실손"), (r"진단금", "진단비"), (r"당뇨(?!병)", "당뇨병"),
    (r"입원비", "입원일당"), (r"수술금", "수술비"), (r"유병자", "간편고지"),
    (r"간병비", "간병인"), (r"치매(?!진단)", "치매진단"), (r"뇌졸중", "뇌졸중 뇌혈관질환"),
)
INSURER_ALIASES = {
    "농협손보": "NH농협손해보험", "농협손해": "NH농협손해보험", "nh손보": "NH농협손해보험",
    "농협생명": "NH농협생명", "농협화재": "NH농협손해보험", "삼성화재": "삼성화재",
    "현대해상": "현대해상", "db손보": "DB손해보험", "kb손보": "KB손해보험",
    "메리츠": "메리츠화재", "한화손보": "한화손해보험", "롯데손보": "롯데손해보험",
    "흥국화재": "흥국화재", "하나손보": "하나손해보험", "mg손보": "MG손해보험",
    "예별": "예별손해보험", "캐롯": "캐롯손해보험", "악사": "AXA손해보험", "axa": "AXA손해보험",
}
PRODUCT_KINDS = (
    ("유병자", ("간편", "유병")), ("간편", ("간편",)),
    ("어린이", ("어린이", "자녀", "아이", "키즈", "주니어", "태아", "맘")),
    ("자녀", ("어린이", "자녀", "아이", "키즈", "주니어")), ("태아", ("태아", "어린이", "맘")),
    ("실손", ("실손",)), ("실비", ("실손",)), ("운전자", ("운전자", "운전")),
    ("치아", ("치아",)), ("간병", ("간병",)), ("치매", ("치매",)), ("암", ("암",)),
    ("종신", ("종신",)), ("연금", ("연금",)), ("저축", ("저축",)),
    ("화재", ("화재", "주택", "재물")), ("펫", ("펫", "반려")), ("반려", ("펫", "반려")),
    ("여행", ("여행",)), ("골프", ("골프",)), ("상해", ("상해",)), ("건강", ("건강",)),
    ("정기", ("정기",)),
    ("뇌", ("뇌",)), ("심장", ("심장", "심혈관")), ("수술", ("수술",)), ("입원", ("입원",)),
)
SEARCH_CONCEPTS = (
    (r"실손|실비", "실손"), (r"통원|외래", "통원"), (r"청구", "보험금 청구"),
    (r"서류", "청구서류"), (r"암보험|암\s*(?:진단|보장)|(?<![가-힣])암(?![가-힣])", "암보험 진단비"),
    (r"간편|유병", "간편고지"), (r"고혈압", "고혈압 투약"), (r"당뇨", "당뇨병"),
    (r"고지|알릴\s*의무", "계약 전 알릴 의무"), (r"건강보험", "건강보험"),
    (r"종신", "종신보험"), (r"해지환급|환급금|원금", "해지환급금"),
    (r"보험료|비싸|부담", "보험료"), (r"해지", "해지"),
    (r"화법|말씀|설득", "상담 화법 계약유지"), (r"시책", "시책"), (r"수수료", "수수료"),
    (r"펫|반려|강아지|고양이", "펫보험"), (r"슬개골", "슬개골 탈구"),
    (r"가입\s*전.*(?:진단|병력)|기왕증", "가입 전 질병"),
    (r"직업\s*변경", "직업 변경 배서"), (r"어린이|자녀", "어린이보험"),
    (r"태아", "태아보험"), (r"운전자", "운전자보험"), (r"치아", "치아보험"),
    (r"간병", "간병인"), (r"치매", "치매진단"), (r"뇌졸중|뇌혈관", "뇌혈관질환"),
    (r"심장|심혈관", "심혈관질환"), (r"수술", "수술비"), (r"입원", "입원일당"),
    (r"연금", "연금보험"), (r"요약|주요\s*내용|보장\s*내용", "보장내용"),
)


def _text(value: object) -> str:
    if not isinstance(value, (str, int, float)):
        return ""
    value = unicodedata.normalize("NFKC", html.unescape(str(value)))
    value = re.sub(r"[\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]", "", value)
    return re.sub(r"<[^>]*>", " ", value).strip()


def compact(value: object) -> str:
    return re.sub(r"[^가-힣a-z0-9]", "", _text(value).lower())


def _source_values(value: object, mode: str = ""):
    """Inspect nested original metadata, including all alternative filenames."""
    if isinstance(value, dict):
        for key, child in value.items():
            key = str(key).lower()
            if key in CONTENT_HEADING_FIELDS:
                continue
            is_marker = key in SOURCE_MARKER_FIELDS or key.endswith(("path", "title", "filename", "folder", "directory"))
            child_mode = mode
            if mode in {"folder", "strict"}:
                child_mode = mode
            elif key.endswith(("folder", "directory")):
                child_mode = "folder"
            elif is_marker:
                if key.endswith("title") or key in {"doc", "name", "source_name", "label", "자료", "제목"}:
                    child_mode = "title"
                elif key.endswith(("path", "filename")) or key in {"file", "file_name", "source_file", "source", "url", "uri", "경로"}:
                    child_mode = "path"
                else:
                    child_mode = "strict"
            yield from _source_values(child, child_mode)
    elif isinstance(value, (list, tuple)):
        for child in value:
            yield from _source_values(child, mode)
    elif mode and isinstance(value, str):
        yield value, mode


def allowed_source(hit: object) -> bool:
    if not isinstance(hit, dict):
        return False
    for value, mode in _source_values(hit):
        # Decode encoded filenames too; normalise decomposed macOS Korean names.
        for _ in range(3):
            decoded = urllib.parse.unquote(value)
            if decoded == value:
                break
            value = decoded
        # Inspect each folder separately so a public-looking filename cannot
        # neutralise a private parent directory such as /고객/ or /계약자/.
        value = unicodedata.normalize("NFKC", html.unescape(value))
        value = re.sub(r"[\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]", "", value)
        # Preserve literal markup-like filename text while checking provenance;
        # stripping '<고객>' would hide a forbidden source marker.
        parts = re.split(r"[/\\]", value)
        for index, part in enumerate(parts):
            public_title = DOCUMENT_EXTENSION.sub("", part.strip())
            has_extension = public_title != part.strip()
            if (index == len(parts) - 1 and (mode == "title" or (mode == "path" and has_extension))
                    and PUBLIC_CUSTOMER_TITLES.fullmatch(public_title)):
                continue
            marker = re.sub(r"[^가-힣a-z0-9]", "", part.lower())
            if any(word in marker for word in FORBIDDEN_SOURCE_MARKERS):
                return False
    return True


def keyword_query(question: str) -> str:
    """Use insurance nouns before a long conversational query reaches 5111."""
    question = _text(question)
    matched = [term for pattern, term in SEARCH_CONCEPTS if re.search(pattern, question)]
    if not matched:
        return ""
    lower = compact(question)
    companies = [company for alias, company in INSURER_ALIASES.items() if alias in lower]
    return " ".join(dict.fromkeys(companies + matched))[:240]


def search_queries(question: str) -> list[str]:
    """Insurance nouns first, with original/formal wording as fallbacks."""
    original = _text(question)[:1800]
    focused = re.sub(r"(변경|가입|청구|접수|해지|전환)(?:시에는|시의|시에|시)(?=\s|$)", r"\1", original)
    focused = re.sub(r"알려\s*주세요|알려줘|궁금합니다|어떻게\s*(?:하나요|해요)|(?:방법|절차)(?:는|가|을|를)?|문의합니다", " ", focused)
    if re.search(r"직업\s*변경", focused):
        focused = re.sub(r"직업\s*변경", "직업 변경", focused)
        if "배서" not in focused:
            focused += " 배서"
    focused = re.sub(r"\s+", " ", focused).strip(" ?？!.")
    formal = focused
    for pattern, replacement in SYN:
        formal = re.sub(pattern, replacement, formal)
    return list(dict.fromkeys(q for q in (keyword_query(original), original, focused, formal) if q))


@lru_cache(maxsize=1)
def product_catalog() -> tuple[tuple[str, str, str], ...]:
    """Use AskQueue's JSON copy; no external-drive SQLite access in launchd."""
    rows = []
    try:
        with PRODUCT_CATALOG_JSON.open(encoding="utf-8") as handle:
            value = json.load(handle)
        if isinstance(value, list):
            rows = value
    except (OSError, ValueError, UnicodeError):
        pass
    return tuple(tuple(row) for row in rows if isinstance(row, (list, tuple)) and len(row) == 3
                 and all(isinstance(item, str) for item in row)
                 and allowed_source({"title": " ".join(row)}))


def _insurer_stem(name: str) -> str:
    return re.sub(r"^(NH|KB|DB|MG|AXA|IBK|DGB|BNP)", "", name)


def resolve_products(question: str) -> tuple[str, list[str]]:
    """Resolve a company and product category to at most two actual names."""
    catalog = product_catalog()
    q = compact(question)
    insurers = sorted({a for a, _, _ in catalog}, key=lambda name: (-len(name), name))
    insurer = next((name for name in insurers if compact(name) in q or compact(_insurer_stem(name)) in q), "")
    if not insurer:
        insurer = next((v for k, v in INSURER_ALIASES.items() if k in q), "")
    if not insurer:
        return "", []
    aliases = {compact(insurer), compact(_insurer_stem(insurer))} | {k for k, v in INSURER_ALIASES.items() if v == insurer}
    for alias in sorted(aliases, key=len, reverse=True):
        q = q.replace(alias, " ")
    names = []
    for company, product, edition in catalog:
        if company != insurer:
            continue
        whole = compact(product)
        base = compact(re.sub(r"(?:Q|\d{4})$", "", (re.sub(r"\(무\)|무배당", "", product).split() or [""])[0]))
        if (len(whole) >= 4 and whole in q) or (len(base) >= 5 and base in q):
            names.append((3, edition, product))
    if not names:
        for word, keys in PRODUCT_KINDS:
            if word in q:
                names = [(2 if word in compact(product) else 1, edition, product)
                         for company, product, edition in catalog
                         if company == insurer and any(key in compact(product) for key in keys)]
                if names:
                    break
    names.sort(key=lambda row: (-row[0], -int(re.sub(r"\D", "", row[1]) or "0"), row[2]))
    best, seen = [], set()
    for _, _, product in names:
        key = compact(re.sub(r"\(무\)|무배당|\d{4}$", "", product))
        if key not in seen:
            seen.add(key)
            best.append(product)
        if len(best) >= 2:
            break
    return insurer, best


def query_terms(question: str) -> list[str]:
    ignore = {"방법", "절차", "알려주세요", "알려줘", "궁금합니다", "어떻게", "하나요", "해요", "주세요", "보험", "보험사"}
    words = re.findall(r"[가-힣A-Za-z0-9]{2,}|(?<![가-힣])[암뇌](?![가-힣])", " ".join(search_queries(question)))
    return list(dict.fromkeys(compact(word) for word in words if word not in ignore))[:32]


def relevance(title: str, text: str, terms: list[str]) -> int:
    a, b = compact(title), compact(text)
    return sum((5 if term in a else 0) + (2 if term in b else 0) for term in terms)


def excerpt(text: str, terms: list[str]) -> str:
    text = _text(text)
    if len(text) <= EXCERPT_CHARS:
        return text
    positions = []
    for term in terms:
        positions.extend(match.start() for match in re.finditer(r"\s*".join(re.escape(c) for c in term), text, re.I))
    starts = {0, len(text) - EXCERPT_CHARS}
    starts.update(max(0, min(position - 250, len(text) - EXCERPT_CHARS)) for position in positions)
    start = max(starts, key=lambda at: (relevance("", text[at:at + EXCERPT_CHARS], terms),
                                      sum(at <= p < at + EXCERPT_CHARS for p in positions), -at))
    return ("…" if start else "") + text[start:start + EXCERPT_CHARS - 2] + ("…" if start + EXCERPT_CHARS < len(text) else "")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if fp is not None:
            fp.close()
        raise urllib.error.URLError("search_redirect_rejected")


def _request(query: str, timeout: float) -> list[dict]:
    body = json.dumps({"query": query, "top_k": 12}, ensure_ascii=False).encode()
    request = urllib.request.Request(SEARCH_URL, data=body, headers={"Content-Type": "application/json"}, method="POST")
    # Never forward a question to a proxy or a redirect target.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    with opener.open(request, timeout=timeout) as response:
        payload = response.read(MAX_RESPONSE_BYTES + 1)
    if len(payload) > MAX_RESPONSE_BYTES:
        raise ValueError("search_response_too_large")
    parsed = json.loads(payload)
    if not isinstance(parsed, dict) or not isinstance(parsed.get("results"), list):
        raise ValueError("search_response_invalid")
    return [hit for hit in parsed["results"][:100] if isinstance(hit, dict)]


def _kind(title: str, declared: str) -> str:
    kinds = (
        (r"상품\s*요약|summary", "상품요약서"), (r"사업\s*방법|business.method", "사업방법서"),
        (r"약관|terms", "약관"), (r"수수료|commission", "수수료표"), (r"시책|incentive", "시책자료"),
        (r"교육|training", "사내교육자료"), (r"소식지|뉴스레터|newsletter", "소식지"),
        (r"상품\s*설명", "상품설명서"),
    )
    for value in (declared, title):
        kind = next((kind for pattern, kind in kinds if re.search(pattern, value, re.I)), "")
        if kind:
            return kind
    return "보험자료"


def _normalise(hit: dict) -> dict | None:
    if not allowed_source(hit):
        return None
    meta = hit.get("metadata") if isinstance(hit.get("metadata"), dict) else {}
    citation = hit.get("citation") if isinstance(hit.get("citation"), dict) else {}
    title = _text(citation.get("document_title") or hit.get("title") or meta.get("title") or hit.get("doc"))
    title = re.split(r"[/\\]", title)[-1][:300] or "보험자료"
    text = _text(hit.get("document") or hit.get("text") or hit.get("content"))[:16000]
    if len(text) < 40:
        return None
    page = _text(citation.get("page") or hit.get("page") or meta.get("page_number") or meta.get("page"))
    page = page if re.fullmatch(r"\d{1,5}(?:\s*[-~–,]\s*\d{1,5})?", page) else ""
    edition = _text(hit.get("edition") or meta.get("edition") or meta.get("basis_month") or hit.get("basis_month"))
    edition = edition if re.fullmatch(r"\d{4}(?:[-./]\d{1,2}){0,2}", edition) else ""
    return {"자료": title, "보험사": _text(hit.get("insurer_canonical") or hit.get("insurer") or meta.get("insurer"))[:80],
            "상품": _text(hit.get("product") or meta.get("product"))[:200],
            "종류": _kind(title, _text(hit.get("doc_type_canonical") or hit.get("doc_type") or meta.get("doc_type"))),
            "기준": edition, "쪽": page, "발췌": text}


def _select_evidence(raw: list[dict], terms: list[str], insurer: str,
                     products: list[str], summary: bool, limit: int) -> list[dict]:
    candidates = []
    for hit in raw:
        item = _normalise(hit)
        if item is None:
            continue
        score = relevance(item["자료"], item["발췌"], terms)
        if products:
            heading = compact(item["자료"] + item["상품"])
            if any(compact(re.sub(r"\(무\)|무배당|\d{4}$", "", product))[:8] in heading for product in products):
                score += 40 + (10 if summary and item["종류"] == "상품요약서" else 0)
            elif insurer and compact(insurer) not in heading and compact(_insurer_stem(insurer)) not in heading:
                score -= 15
        if score > 0:
            item["발췌"] = excerpt(item["발췌"], terms)
            candidates.append((score, item))
    evidence, seen = [], set()
    for _, item in sorted(candidates, key=lambda row: -row[0]):
        key = compact(item["발췌"])
        if key in seen or sum(other["자료"] == item["자료"] for other in evidence) >= 4:
            continue
        seen.add(key)
        evidence.append(item)
        if len(evidence) >= limit:
            break
    return evidence


def search(title: str, body: str = "", limit: int = MAX_SOURCES) -> list[dict]:
    """Bound search time and stop once enough safe, relevant excerpts exist."""
    limit = max(0, min(MAX_SOURCES, limit))
    if not limit:
        return []
    question = (_text(title)[:300] + "\n" + _text(body)[:1500]).strip()
    if not question:
        return []
    deadline = time.monotonic() + SEARCH_SECONDS
    insurer, products = resolve_products(question)
    # A comparison must not apply the first company's product boost/penalty to
    # all results. The focused query carries each named company instead.
    companies = {company for alias, company in INSURER_ALIASES.items() if alias in compact(question)}
    if len(companies) > 1:
        insurer, products = "", []
    summary = bool(re.search(r"요약|주요\s*내용|보장\s*내용|개요|특징", question))
    extra = [f"{insurer} {product}" + (" 상품요약서" if summary else "") for product in products]
    if summary and products:
        extra.append(f"{insurer} {products[0]} 보장내용 보험금 지급사유")
    queries = search_queries(question)
    keyword = keyword_query(question)
    # Exact product requests benefit from their resolved product names; generic
    # questions use insurance nouns before expensive conversational fallbacks.
    queries = list(dict.fromkeys(extra + ([keyword] if keyword else []) + queries))[:6]
    terms = query_terms(question) + (["보장내용", "지급사유", "보험금", "주요", "특약"] if summary else [])
    raw, evidence = [], []
    for query in queries:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            raw.extend(_request(query, min(REQUEST_SECONDS, remaining)))
        except urllib.error.HTTPError as error:
            error.close()
        except (OSError, urllib.error.URLError, ValueError, UnicodeError):
            # No source text, query, path, response body, or error details are logged.
            continue
        evidence = _select_evidence(raw, terms, insurer, products, summary, limit)
        if len(evidence) >= limit:
            break
    return evidence
