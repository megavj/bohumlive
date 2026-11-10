"""Small local reference search for Bohumlive AI answers (read-only, standard library only).

The index (worker/kb/bl_kb.sqlite3, git-ignored) is built once by kb_build.py from public
insurer documents (terms, product summaries, business method papers) listed in the product
catalog and from the insurance wiki outline. Customer or personal folders are never indexed.

search(question) returns up to MAX_SOURCES short excerpts with insurer, product, kind,
edition and page. Any problem (missing or broken index, slow query) returns [] so the
worker answers exactly as before.
"""

from __future__ import annotations

import json
import math
import os
from pathlib import Path
import re
import sqlite3
import time
import zlib

KB_PATH = Path(os.environ.get("BL_KB_PATH") or Path(__file__).resolve().parent / "kb" / "bl_kb.sqlite3")
MAX_SOURCES = 3
EXCERPT_CHARS = 420
QUERY_SECONDS = 6.0
COMMON_SHARE = 0.25  # 이보다 흔한 조각(보험·니다 등)은 검색어에서 뺀다
MIN_COVERAGE = 0.55  # 질문 핵심어(드문 말일수록 무겁게)의 이 비율 이상이 들어 있는 발췌만 쓴다
SPECIAL_SINGLE = frozenset("암뇌")
PET = re.compile(r"반려|펫|강아지|고양이|애완|동물")
_RUN = re.compile(r"[가-힣]+|[A-Za-z]+|\d+")

# 질문에서 뜻 없는 말(조사·어미·인사)은 검색어에서 뺀다.
STOP_WORDS = frozenset("""
어떻게 어떤 어디 언제 무엇 뭔가 뭐가 무슨 누가 왜 혹시 그냥 이번 요즘 최근 지금 현재 정도 부분 내용 관련 경우 상황 문의 질문 답변 궁금
궁금합니다 궁금해요 알려 주세요 부탁 드립니다 감사 감사합니다 안녕하세요 안녕 여러분 선배님 선배 동료 설계사 설계사님 고객 고객님 우리 제가 저는 저희
있나요 있을까요 있는지 없나요 없을까요 되나요 될까요 되는지 하나요 할까요 하는지 인가요 일까요 건가요 맞나요 맞는지 같은데 같아요 해야 하나 해도 되나
많이 조금 너무 아주 정말 계속 다시 먼저 이미 아직 바로 보통 대부분 일반 일반적 경우에 때문 그리고 그런데 하지만 그래서 또는 혹은 이런 저런 그런
보험 보험사 상품 회사 가입 확인 방법 필요 가능 이유 차이 기준 처리 진행 받을 받는 받아 하면 하는 했는데 해서 하고 입니다 습니다 있어 없어 있는 없는
쓰고 있는데 받아서 다른 옮기 정리 부탁드립니다 드립니다 상담 설명 고민 고민합니다 좋을 좋을지 좋은 알고 싶습니다 싶어요 하려고 되고 다시 같이 함께 꼭 핵심
알려 안내 좋을까요 헷갈려 헷갈 예전 돌아갈 받는지 내야 하는지 처리되는지 확인할 있을까요 할지 무엇인지 뭔가요 뭐예요 어떤지 이후 전에 후에 때문에 동안 사이
주세 주시 말고 중인데 합니다 됩니다 있습니다 없습니다 경우가 정도로 가지 무엇을 어느 누구 얼마나 나오나요 나오는지 되는데 하는데 했더니 했어요 해야 할까 맞는 맞을 고객이 고객님이 고객분 분들 동료분 동료분들
""".split())
SUFFIXES = sorted("""
은 는 이 가 을 를 의 에 도 만 과 와 로 요 께 엔
으로 에서 에게 까지 부터 보다 처럼 이나 이랑 랑 이라 라고 하고 으로는 에서는 에는 으로도 에서도 이라도 라도 마다 조차 밖에 대로 이며 이고 이면
하면 하나요 되나요 인가요 있나요 없나요 할까요 될까요 합니다 됩니다 해요 돼요 하는 되는 했는데 는데 지만 려고 해서 되어 된 한 할 해야 하려면 받으려면 받을 받는 받아
하는데 되는데 인데 했어요 됐어요 했나요 됐나요 시키면 시키는 시켜야 하게 되게 되면 인지 는지 을지 할지 일지 하 할때 할 때
""".split(), key=len, reverse=True)
SYNONYMS = {"실비": "실손", "실손보험": "실손", "진단금": "진단비", "치매보험": "치매", "간병보험": "간병"}
INTENT = (
    (re.compile(r"서류|청구|구비|제출"), {"약관": 0.25, "상품요약서": 0.2}),
    (re.compile(r"전환|갱신|재가입"), {"약관": 0.3, "상품요약서": 0.1}),
    (re.compile(r"보장|얼마|금액|가입\s*나이|보험\s*기간|납입|특약|담보"), {"상품요약서": 0.3, "사업방법서": 0.1}),
)


def tokens(text: str) -> list[str]:
    """Hangul runs → overlapping two-letter pieces (+ 암·뇌 alone); Latin words and numbers as-is."""
    out: list[str] = []
    for m in _RUN.finditer(text or ""):
        w = m.group(0)
        if "가" <= w[0] <= "힣":
            out.extend(w[i:i + 2] for i in range(len(w) - 1))
            out.extend(ch for ch in w if ch in SPECIAL_SINGLE)
        else:
            out.append(w.lower())
    return out


def key_words(text: str, limit: int = 12) -> list[str]:
    """Meaningful words of a question, in order, without particles/endings or filler words."""
    words: list[str] = []
    for m in _RUN.finditer(text or ""):
        w = m.group(0)
        if "가" <= w[0] <= "힣":
            changed = True
            while changed and len(w) > 2:
                changed = False
                for s in SUFFIXES:
                    if w.endswith(s) and len(w) - len(s) >= 2:
                        w = w[: -len(s)]
                        changed = True
                        break
            w = SYNONYMS.get(w, w)
            if w in STOP_WORDS or (len(w) < 2 and w not in SPECIAL_SINGLE):
                continue
        else:
            if len(w) < 2 or w.isdigit():
                continue
            w = w.upper() if len(w) <= 4 else w.lower()
        if w not in words:
            words.append(w)
        if len(words) >= limit:
            break
    return words


def _squash(text: str) -> str:
    return re.sub(r"\s+", "", text or "")


def _shape(text: str) -> set[str]:
    flat = _squash(text)[:400]
    return {flat[i:i + 2] for i in range(len(flat) - 1)}


def _similar(a: set[str], b: set[str]) -> bool:
    return bool(a and b) and len(a & b) / len(a | b) > 0.6


def _edition(value: str) -> str:
    m = re.match(r"(\d{4})-(\d{2})", value or "")
    return f"{m.group(1)}.{int(m.group(2))}" if m else ""


def _excerpt(text: str, words: list[str]) -> str:
    flat = re.sub(r"\s+", " ", text).strip()
    if len(flat) <= EXCERPT_CHARS:
        return flat
    best, best_at = -1, 0
    for start in range(0, len(flat) - EXCERPT_CHARS + 1, 40):
        window = _squash(flat[start:start + EXCERPT_CHARS])
        score = sum(1 for w in words if _squash(w) in window)
        if score > best:
            best, best_at = score, start
    start = best_at
    # 문장·줄 경계에서 시작하도록 조금 앞으로 당긴다.
    back = max(flat.rfind(". ", max(0, start - 80), start), flat.rfind("다 ", max(0, start - 80), start))
    if back > 0:
        start = back + 2
    piece = flat[start:start + EXCERPT_CHARS].strip()
    return ("…" if start > 0 else "") + piece + ("…" if start + EXCERPT_CHARS < len(flat) else "")


# 줄인 이름은 헷갈리지 않는 것만(예: '하나'는 '설명하나요'와 겹쳐서 쓰지 않는다).
SHORT_NAMES = ("삼성", "한화", "교보", "신한", "농협", "NH", "KB", "DB", "메리츠", "현대해상", "흥국", "롯데", "라이나",
               "동양", "미래에셋", "메트라이프", "AIA", "ABL", "처브", "KDB", "IBK", "iM")


def _insurers(db: sqlite3.Connection, text: str) -> set[str]:
    """Insurer names mentioned in the question (full name, '○○손보', or an unambiguous short name)."""
    names = [r[0] for r in db.execute("select distinct insurer from docs where insurer<>''")]
    plain = _squash(text).upper()
    full = set()
    for name in names:
        stem = re.sub(r"(손해보험|생명|화재|라이프|연금보험)$", "", name)
        keys = {name.upper()}
        if name.endswith("손해보험"):
            keys |= {(stem + "손보").upper(), (stem + "손해").upper()}
        if name.endswith("생명") and stem.endswith("라이프"):
            keys.add(stem.upper())  # KB라이프·처브라이프·메트라이프
        if any(k in plain for k in keys):
            full.add(name)
    if full:
        return full
    found = set()
    for short in SHORT_NAMES:
        if short.upper() in plain:
            found |= {n for n in names if n.upper().startswith(short.upper())}
    return found


def search(title: str, body: str = "", path: Path | None = None) -> list[dict]:
    """Return up to MAX_SOURCES excerpts that match the question well, else []."""
    path = Path(path or KB_PATH)
    if not path.is_file():
        return []
    started = time.monotonic()
    # 머리 꼬리표([시험]·[질문]·【급】 등)는 검색어가 아니다.
    title = re.sub(r"^\s*(?:[\[【(（][^\]】)）]{1,8}[\]】)）]\s*)+", "", title or "")
    question = f"{title or ''}\n{body or ''}"[:1500]
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=2)
    except sqlite3.Error:
        return []
    try:
        db.set_progress_handler(lambda: 1 if time.monotonic() - started > QUERY_SECONDS else 0, 20000)
        info = dict(db.execute("select k, v from meta"))
        total = max(1, int(info.get("chunks", "1")))
        words = key_words(f"{title or ''} {title or ''} {body or ''}")
        if not words:
            return []
        toks: list[str] = []
        for w in words:
            for t in tokens(w):
                if t not in toks:
                    toks.append(t)
        # 흔한 조각은 빼되, 다 빠지면 덜 흔한 것 몇 개는 남긴다.
        df = {}
        for t in toks:
            row = db.execute("select doc from df where term=?", (t,)).fetchone()
            df[t] = row[0] if row else 0
        keep = [t for t in toks if 0 < df[t] <= total * COMMON_SHARE]
        if len(keep) < 3:
            keep = [t for t in sorted(toks, key=lambda t: df[t]) if df[t] > 0][:3]
        toks = keep
        if not toks:
            return []
        match = " OR ".join('"' + t.replace('"', "") + '"' for t in toks[:24])
        insurers = _insurers(db, question)
        sql = ("select c.id, c.doc_id, c.page, c.text, d.insurer, d.product, d.kind, d.edition, d.source, bm25(fts, 3.0, 1.0) r "
               "from fts join chunks c on c.id=fts.rowid join docs d on d.id=c.doc_id where fts match ?")
        args: list = [match]
        if insurers:
            sql += " and d.insurer in (%s)" % ",".join("?" * len(insurers))
            args.extend(sorted(insurers))
        sql += " order by r limit 300"
        rows = db.execute(sql, args).fetchall()
        if not rows:
            return []
        best_rank = rows[0][9]
        boost: dict[str, float] = {}
        for rx, kinds in INTENT:
            if rx.search(question):
                for k, v in kinds.items():
                    boost[k] = max(boost.get(k, 0.0), v)
        title_words = set(key_words(title or ""))
        weight = {}
        for w in words:
            pieces = [t for t in tokens(w)] or [w]
            rare = min((df.get(t) if t in df else (db.execute("select doc from df where term=?", (t,)).fetchone() or [0])[0]) for t in pieces)
            weight[w] = math.log(1 + total / (1 + rare)) * (1.5 if w in title_words else 1.0)
        weight_sum = sum(weight.values()) or 1
        need = 1 if len(words) <= 1 else 2
        scored = []
        pets = bool(PET.search(question))
        for cid, doc_id, page, blob, insurer, product, kind, edition, source, rank in rows:
            if not pets and PET.search(product or ""):
                continue  # 사람 보험 질문에 반려동물 보험 약관(같은 서식)을 근거로 대지 않는다
            text = zlib.decompress(blob).decode("utf-8")
            body_flat = _squash(text).upper()
            meta_flat = _squash(f"{insurer}{product}{kind}").upper()
            # '어느 상품' 말(보험사·상품명에 들어 있는 말)과 '무슨 내용' 말을 나눠, 내용 말이 본문에 있어야 쓴다.
            ident = [w for w in words if _squash(w).upper() in meta_flat]
            topic = [w for w in words if w not in ident]
            topic_hits = [w for w in topic if _squash(w).upper() in body_flat]
            # 말이 4개 이상이면 안 맞는 말 하나(가장 무거운 것)는 봐준다 — 질문 속 곁가지 한 단어로 근거를 놓치지 않게.
            missed = sorted((w for w in topic if w not in topic_hits), key=lambda w: -weight[w])
            spare = missed[0] if len(topic) >= 4 and missed else None
            topic_total = sum(weight[w] for w in topic if w != spare)
            topic_cov = (sum(weight[w] for w in topic_hits) / topic_total) if topic and topic_total else 1.0
            coverage = (sum(weight[w] for w in ident) + sum(weight[w] for w in topic_hits)) / ((weight_sum - (weight[spare] if spare else 0)) or 1)
            hits = ident + topic_hits
            title_hit = (len(title_words & set(hits)) / len(title_words)) if title_words else 0
            if len(hits) < need or coverage < MIN_COVERAGE or topic_cov < 0.5:
                continue
            score = (coverage + topic_cov * 2 + title_hit + 0.1 * len(topic_hits)
                     + (rank / best_rank if best_rank else 0) * 0.5 + boost.get(kind, 0))
            scored.append((score, cid, doc_id, page, text, insurer, product, kind, edition, source, hits))
        scored.sort(key=lambda x: -x[0])
        picked, docs, shapes = [], set(), []
        for item in scored:
            label = (item[5], item[6], item[7])
            gist = _squash(item[4])[:100]
            shape = _shape(item[4])
            # 같은 회사의 다른 상품에 똑같이 실린 표·문단은 하나만 쓴다.
            if item[2] in docs or label in docs or gist in docs or any(_similar(shape, x) for x in shapes):
                continue
            shapes.append(shape)
            if picked and item[0] < picked[0][0] * 0.8:
                break
            docs.add(item[2])
            docs.add(label)
            docs.add(gist)
            picked.append(item)
            if len(picked) >= MAX_SOURCES:
                break
        results = []
        for score, cid, doc_id, page, text, insurer, product, kind, edition, source, hits in picked:
            results.append({
                "자료": " ".join(x for x in (insurer, product, kind) if x),
                "보험사": insurer, "상품": product, "종류": kind,
                "기준": (_edition(edition) + " 기준") if _edition(edition) else "",
                "쪽": page, "발췌": _excerpt(text, hits),
                "_score": round(score, 3), "_source": source,
            })
        return results
    except (sqlite3.Error, ValueError, zlib.error, UnicodeError):
        return []
    finally:
        db.close()


if __name__ == "__main__":
    import sys
    q = " ".join(sys.argv[1:]) or "실손 전환"
    t0 = time.monotonic()
    found = search(q)
    print(json.dumps({"ms": round((time.monotonic() - t0) * 1000), "words": key_words(q), "results": found},
                     ensure_ascii=False, indent=1))
