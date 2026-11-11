"""Privacy filters with separate input and publication boundaries.

Member identifiers are removed by the DB before jobs leave it.  Callers that
already have exact names/nicknames may also pass them to ``redact``; they must
never send that metadata to the model.  Unlabelled Korean words before customer
or policyholder roles are deliberately not guessed to be names.
"""

from __future__ import annotations

import html
import re
import unicodedata


PRIVATE = "[개인정보 삭제]"
PERSON = "[인명 삭제]"

DIRECT_IDENTIFIERS = tuple(re.compile(pattern, re.I) for pattern in (
    r"https?://[^\s<>]+|www\.[^\s<>]+",
    r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}",
    r"(?<!\d)0\d{1,2}[-.\s]?\d{3,4}[-.\s]?\d{4}(?!\d)",
    r"(?<!\d)\d{6}\s*[- ]\s*[1-8]\d{6}(?!\d)",
    r"(?<!\d)\d{13,16}(?!\d)",
    r"(?:계좌|등록번호|증권번호|계약번호)\s*[:：]?\s*[\d -]{6,}",
    r"[가-힣]+(?:시|도)\s+[가-힣]+(?:구|군)\s+[가-힣0-9]+(?:로|길|동)\s*\d+[\d -]*",
))

# A title alone is not a name: 고객님, 계약자님, 설계사님, etc.  The
# surname + 2–4 syllable rule below is only a last input-side precaution.
NON_PERSON_WORDS = frozenset({
    "고객", "계약자", "피보험자", "수익자", "설계사", "팀장", "담당자",
    "선생", "상담사", "회원", "가입자", "이사", "회장", "부장", "과장",
    "사장", "교수", "조교", "강사", "신입", "대리", "총무", "주임",
    "대표", "원장", "부원장", "지점장", "실장", "소장", "박사", "선배", "선임",
    "이모", "고모", "누님", "어머", "아버", "장모", "장인", "사모",
    "배우자", "주치의", "임산부",
})
SURNAMES = "김이박최정강조윤장임한오서신권황안송전홍유고문양손배백허남심노하곽성차주우구민류나진지엄채원천방공현함변염여추도소석선설마길연위표명기반왕금옥육인맹제모탁국어은편용예경"
DOUBLE_SURNAMES = "남궁|황보|제갈|선우|독고|서문|동방|사공"
NAME_HONORIFIC = re.compile(
    r"(?<![\w])((?:(?:" + DOUBLE_SURNAMES + r")[가-힣]{1,2}|[" + SURNAMES +
    r"][가-힣]{1,3}))\s*(님|씨)"
    r"(?=$|[^\w]|(?:께서는|께서|에게|께|으로|이라|라고|라는|이|가|은|는|을|를|의|도|만|과|와))"
)
KNOWN_ROLES = (
    r"고객님|계약자님|피보험자님|수익자님|설계사님|팀장님|담당자님|"
    r"고객|계약자|피보험자|수익자|설계사|팀장|담당자|님|씨"
)


def normalize(value: object) -> str:
    text = unicodedata.normalize("NFKC", html.unescape(str(value or "")))
    text = re.sub(r"[\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]", "", text)
    return re.sub(r"<[^>]*>", "", text)


def redact_output(value: object) -> str:
    """Remove format-based identifiers without ever guessing person names."""
    text = normalize(value)
    for pattern in DIRECT_IDENTIFIERS:
        text = pattern.sub(PRIVATE, text)
    return text.strip()


def redact(value: object, known_names=()) -> str:
    """Remove direct identifiers and exact input-side member names/nicknames.

    Exact values follow the same literal replacement policy as DB bl_ai_redact.
    Heuristics require a common surname and an immediate 님/씨 honorific; a word
    preceding 고객/계약자/설계사 is never treated as a name on that basis alone.
    """
    text = redact_output(value)
    if isinstance(known_names, str):
        known_names = (known_names,)
    names = {normalize(name).strip() for name in (known_names or ()) if isinstance(name, str)}
    for name in sorted((name for name in names if 2 <= len(name) <= 80), key=len, reverse=True):
        text = re.sub(re.escape(name) + r"(?:\s*(?:" + KNOWN_ROLES + r"))?", PERSON, text)
    text = NAME_HONORIFIC.sub(
        lambda match: match.group(0) if match.group(1) in NON_PERSON_WORDS else PERSON, text
    )
    text = re.sub(r"(?:성명|이름|닉네임|소속회사)\s*[:：]\s*[^\s,;]+", PRIVATE, text)
    return text.strip()
