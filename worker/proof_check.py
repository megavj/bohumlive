"""Bohumlive proof auto-check: read name / 14-digit agent ID / company from OCR lines.

Pure functions only (no network, no logging of personal data). The OCR lines come
from worker/ocr/bl_ocr (Apple Vision on this Mac). Decisions are conservative:
only a clear difference rejects; anything unreadable or borderline is held for
an administrator.
"""

from __future__ import annotations

import re
import unicodedata

# 같은 회사로 보는 이름들. 공백·(주)·주식회사·대소문자를 정리한 뒤 비교한다.
COMPANY_ALIASES = {
    "인카금융서비스": ["INCAR", "인카", "인카금융", "인카금융서비스", "INCARFINANCIALSERVICE", "INCAR금융서비스"],
    "프라임에셋": ["프라임에셋", "프라임", "PRIMEASSET", "PRIME"],
    "글로벌금융판매": ["글로벌금융판매", "글로벌금융", "GLOBALFINANCIALSALES"],
    "지에이코리아": ["지에이코리아", "GA코리아", "GAKOREA"],
    "에이플러스에셋": ["에이플러스에셋", "에이플러스에셋어드바이저", "A+에셋", "APLUSASSET", "A+ASSET"],
    "피플라이프": ["피플라이프", "PEOPLELIFE"],
    "한국보험금융": ["한국보험금융"],
    "리치앤코": ["리치앤코", "RICH&CO", "RICHANDCO", "굿리치"],
    "한화생명금융서비스": ["한화생명금융서비스", "한화생명금융", "HANWHALIFEFINANCIALSERVICES"],
    "삼성생명금융서비스": ["삼성생명금융서비스", "삼성생명금융서비스보험대리점"],
    "미래에셋금융서비스": ["미래에셋금융서비스"],
    "KB라이프파트너스": ["KB라이프파트너스", "케이비라이프파트너스"],
    "신한금융플러스": ["신한금융플러스"],
    "삼성생명": ["삼성생명", "삼성생명보험", "SAMSUNGLIFE", "SAMSUNGLIFEINSURANCE"],
    "삼성화재": ["삼성화재", "삼성화재해상보험", "삼성화재해상", "SAMSUNGFIRE", "SAMSUNGFIRE&MARINE"],
    "한화생명": ["한화생명", "한화생명보험", "HANWHALIFE"],
    "한화손해보험": ["한화손해보험", "한화손보", "한화손해", "HANWHAGENERAL", "HANWHAGENERALINSURANCE"],
    "교보생명": ["교보생명", "교보생명보험", "KYOBOLIFE", "KYOBO"],
    "신한라이프": ["신한라이프", "신한라이프생명", "신한라이프생명보험", "SHINHANLIFE"],
    "NH농협생명": ["NH농협생명", "농협생명", "농협생명보험", "엔에이치농협생명", "NHLIFE"],
    "NH농협손해보험": ["NH농협손해보험", "농협손해보험", "농협손보", "NH손보", "엔에이치농협손해보험"],
    "동양생명": ["동양생명", "동양생명보험", "TONGYANGLIFE"],
    "미래에셋생명": ["미래에셋생명", "미래에셋생명보험", "MIRAEASSETLIFE"],
    "흥국생명": ["흥국생명", "흥국생명보험", "HEUNGKUKLIFE"],
    "흥국화재": ["흥국화재", "흥국화재해상보험", "HEUNGKUKFIRE"],
    "KB라이프생명": ["KB라이프생명", "KB라이프", "KB라이프생명보험", "KBLIFE", "케이비라이프생명"],
    "KB손해보험": ["KB손해보험", "KB손보", "케이비손해보험", "KBINSURANCE"],
    "ABL생명": ["ABL생명", "ABL생명보험", "에이비엘생명", "ABLLIFE"],
    "DB손해보험": ["DB손해보험", "DB손보", "디비손해보험", "DBINSURANCE"],
    "DB생명": ["DB생명", "DB생명보험", "디비생명"],
    "메리츠화재": ["메리츠화재", "메리츠화재해상보험", "MERITZFIRE", "MERITZ"],
    "메트라이프생명": ["메트라이프생명", "메트라이프", "메트라이프생명보험", "METLIFE"],
    "라이나생명": ["라이나생명", "라이나생명보험", "LINALIFE", "LINA"],
    "롯데손해보험": ["롯데손해보험", "롯데손보", "LOTTEINSURANCE"],
    "하나손해보험": ["하나손해보험", "하나손보"],
    "하나생명": ["하나생명", "하나생명보험"],
    "현대해상": ["현대해상", "현대해상화재보험", "현대해상화재", "HYUNDAIMARINE", "HYUNDAIMARINE&FIRE"],
    "KDB생명": ["KDB생명", "KDB생명보험", "케이디비생명"],
    "AIA생명": ["AIA생명", "AIA생명보험", "에이아이에이생명", "AIA"],
    "처브라이프생명": ["처브라이프생명", "처브라이프", "CHUBBLIFE"],
    "푸본현대생명": ["푸본현대생명", "푸본현대생명보험", "FUBONHYUNDAILIFE"],
    "iM라이프생명": ["IM라이프생명", "IM라이프", "아이엠라이프생명"],
}

NAME_LABELS = {"성명", "이름", "모집종사자명", "설계사명", "모집종사자성명"}
COMPANY_LABELS = {"현재소속회사", "소속회사", "현재소속", "소속", "회사명", "소속기관", "소속기관명",
                  "소속대리점", "대리점명", "법인명", "보험회사", "소속보험회사", "소속회사명", "현재소속회사명"}
NUMBER_LABELS = {"설계사고유번호", "고유번호", "등록번호", "모집종사자등록번호", "설계사등록번호",
                 "설계사번호", "모집종사자고유번호", "등록번호(고유번호)"}
OTHER_LABELS = {"생년월일", "모집종사자구분", "구분", "등록일자", "등록일", "자격", "소속지점", "지점",
                "위촉일", "위촉일자", "성별", "연락처", "상태", "말소일", "기본정보"}
ALL_LABELS = NAME_LABELS | COMPANY_LABELS | NUMBER_LABELS | OTHER_LABELS


def compact(text: str) -> str:
    text = unicodedata.normalize("NFKC", str(text or ""))
    return re.sub(r"[\s:：·•.,\-_/]", "", text)


def norm_company(text: str) -> str:
    t = unicodedata.normalize("NFKC", str(text or "")).upper()
    t = re.sub(r"\([^)]{0,2}\)", "", t)  # (주) (유) 와 글자인식이 ㈜를 (9) 등으로 읽은 경우
    t = re.sub(r"주식회사|유한회사|(?<![A-Z])(CO\.?,?\s*LTD|CORP(ORATION)?|INC|LIMITED)(?![A-Z])\.?", "", t)
    t = re.sub(r"[\s()\[\]·•.,\-_/㈜]", "", t)
    return t


def _alias_index():
    index = []
    for canon, aliases in COMPANY_ALIASES.items():
        for a in set(aliases + [canon]):
            index.append((norm_company(a), canon))
    index.sort(key=lambda x: -len(x[0]))
    return index


ALIAS_INDEX = _alias_index()


def canonical_company(name: str):
    """Known company group for a name, or None. Longest alias prefix wins."""
    n = norm_company(name)
    if len(n) < 2:
        return None
    for alias, canon in ALIAS_INDEX:
        if n == alias or (len(alias) >= 2 and n.startswith(alias)):
            return canon
    return None


def same_company(a: str, b: str) -> bool:
    ca, cb = canonical_company(a), canonical_company(b)
    if ca and cb:
        return ca == cb
    na, nb = norm_company(a), norm_company(b)
    if len(na) < 2 or len(nb) < 2:
        return False
    return na == nb or na.startswith(nb) or nb.startswith(na)


def resolve_company_id(name: str, companies: list):
    """Match a company name to the server's company list (id, name). None if not listed."""
    for c in companies:
        if norm_company(c.get("name")) == norm_company(name):
            return c.get("id")
    canon = canonical_company(name)
    if canon:
        for c in companies:
            if canonical_company(c.get("name")) == canon:
                return c.get("id")
    return None


def levenshtein(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def _cy(line):
    return line["y"] + line["h"] / 2


def _label_of(text: str):
    c = compact(text)
    c = re.sub(r"[()]", "", c) if c not in ALL_LABELS else c
    return c if c in ALL_LABELS else None


def _value_for(lines, label_line, label_text):
    """Value next to a label: same line after the label, right neighbour, or the cell below."""
    raw = unicodedata.normalize("NFKC", label_line["text"])
    m = re.match(r"^\s*" + r"\s*".join(map(re.escape, label_text)) + r"\s*[:：]?\s*(.+)$", raw)
    if m and compact(m.group(1)):
        return m.group(1).strip(), label_line.get("conf", 0)
    right, below = None, None
    for other in lines:
        if other is label_line:
            continue
        tol = max(label_line["h"], other["h"]) * 0.7
        if abs(_cy(other) - _cy(label_line)) < tol and other["x"] > label_line["x"] + label_line["w"] * 0.6:
            d = other["x"] - (label_line["x"] + label_line["w"])
            if right is None or d < right[0]:
                right = (d, other)
        overlap = min(label_line["x"] + max(label_line["w"], 0.04), other["x"] + other["w"]) - max(label_line["x"], other["x"])
        if other["y"] > label_line["y"] + label_line["h"] * 0.5 and (overlap > 0 or abs(other["x"] - label_line["x"]) < 0.03):
            d = other["y"] - label_line["y"]
            if d < 0.15 and (below is None or d < below[0]):
                below = (d, other)
    for cand in (right, below):
        if cand and not _label_of(cand[1]["text"]):
            return cand[1]["text"].strip(), cand[1].get("conf", 0)
    return None, 0


def _find_labelled(lines, labels):
    found = []
    for line in lines:
        lab = _label_of(line["text"])
        if lab in labels:
            found.append((line, lab))
            continue
        c = compact(line["text"])
        for lab in labels:  # '성명 김가짜'처럼 한 줄에 함께 읽힌 경우
            if c.startswith(lab) and len(c) > len(lab) and not _label_of(c[: len(lab) + 2]):
                found.append((line, lab))
                break
    values = []
    for line, lab in found:
        v, conf = _value_for(lines, line, lab)
        if v:
            values.append((v, conf))
    return values


DIGITS14 = re.compile(r"(?<![0-9])([0-9](?:[\s-]?[0-9]){13})(?![0-9])")


def _numbers_in(text: str):
    return [re.sub(r"\D", "", m) for m in DIGITS14.findall(unicodedata.normalize("NFKC", text or ""))]


def _looks_like_datetime(d: str) -> bool:
    return bool(re.match(r"^(19|20)\d\d(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])([01]\d|2[0-3])[0-5]\d[0-5]\d$", d))


def _name_clean(v: str) -> str:
    v = unicodedata.normalize("NFKC", v or "")
    v = re.sub(r"(님|씨)$", "", v.strip())
    return re.sub(r"[^가-힣A-Za-z]", "", v).upper()


def check_name(lines, applicant: str):
    want = _name_clean(applicant)
    if len(want) < 2:
        return "unknown", ""
    vals = [(_name_clean(v), c) for v, c in _find_labelled(lines, NAME_LABELS)]
    vals = [(v, c) for v, c in vals if 2 <= len(v) <= 20]
    if any(v == want for v, _ in vals):
        return "match", want
    if not vals:
        if any(_name_clean(l["text"]) == want or want in _name_clean(l["text"]) and len(want) >= 3 for l in lines):
            return "match", want
        return "unknown", ""
    v, conf = vals[0]
    if conf >= 0.5 and len(want) >= 3 and len(v) >= 2 and levenshtein(v, want) >= 2:
        return "mismatch", v
    return "unclear", v


def check_number(lines, applicant: str):
    want = re.sub(r"\D", "", applicant or "")
    every = [d for l in lines for d in _numbers_in(l["text"])]
    if want and want in every:
        return "match", want
    labelled = [d for v, _ in _find_labelled(lines, NUMBER_LABELS) for d in _numbers_in(v)]
    pool = labelled or [d for d in every if not _looks_like_datetime(d)]
    if not pool or len(want) != 14:
        return "unknown", pool[0] if pool else ""
    diffs = [sum(a != b for a, b in zip(d, want)) for d in pool]
    if min(diffs) >= 2:
        return "mismatch", pool[0]
    return "unclear", pool[diffs.index(min(diffs))]


def check_company(lines, applicant: str, companies: list):
    vals = [v for v, c in _find_labelled(lines, COMPANY_LABELS) if norm_company(v)]
    if not vals:
        # 라벨을 못 찾으면 화면 전체에서 알려진 회사 이름을 찾는다.
        for l in lines:
            if canonical_company(l["text"]) or resolve_company_id(l["text"], companies):
                vals.append(l["text"])
    if not vals:
        return "unknown", ""
    for v in vals:
        if same_company(v, applicant):
            return "match", v
    v = vals[0]
    known = canonical_company(v) or resolve_company_id(v, companies)
    return ("mismatch" if known else "unclear"), v


REASON_TEXT = {
    "name": "증빙 사진의 이름이 신청한 이름과 달라요",
    "number": "증빙 사진의 설계사 고유번호가 신청한 번호와 달라요",
    "company": "증빙 사진의 소속 회사가 신청한 회사와 달라요",
}


def mask_name(v: str) -> str:
    return (v[:1] + "*" * (len(v) - 1)) if v else ""


def judge(ocr: dict, applicant: dict, companies: list) -> dict:
    """applicant: {name, registration_number, company_name, company_id}. companies: [{id,name}]."""
    lines = [l for l in (ocr or {}).get("lines", []) if isinstance(l, dict) and str(l.get("text", "")).strip()]
    name_s, name_v = check_name(lines, applicant.get("name", ""))
    num_s, num_v = check_number(lines, applicant.get("registration_number", ""))
    co_s, co_v = check_company(lines, applicant.get("company_name", ""), companies)
    fields = {"name": name_s, "number": num_s, "company": co_s}
    company_id = applicant.get("company_id") or resolve_company_id(applicant.get("company_name", ""), companies) \
        or (resolve_company_id(co_v, companies) if co_s == "match" else None)
    mismatched = [k for k, s in fields.items() if s == "mismatch"]
    if mismatched:
        decision, reasons = "reject", mismatched
    elif all(s == "match" for s in fields.values()) and company_id:
        decision, reasons = "approve", []
    else:
        decision = "hold"
        reasons = [k + "_" + s for k, s in fields.items() if s != "match"]
        if not lines:
            reasons = ["unreadable"]
        elif all(s == "match" for s in fields.values()):
            reasons = ["company_not_in_list"]
    return {
        "decision": decision,
        "reasons": reasons,
        "fields": fields,
        "company_id": company_id if decision == "approve" else None,
        "read": {
            "name": mask_name(name_v),
            "number_last4": (num_v or "")[-4:],
            "company": norm_company(co_v)[:40] if co_v else "",
            "lines": len(lines),
        },
    }
