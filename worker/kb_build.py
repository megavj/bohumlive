#!/usr/bin/env python3
"""Build the small local reference index for AI answers (run once; read-only on sources).

Sources (all read-only; nothing is modified, moved or copied as files):
  --catalog  product catalog JSON (latest editions of public insurer documents)
  --evidence folder of already-extracted product evidence JSON (reused, optional)
  --pages    folder of already-extracted page text JSON by file hash (reused, optional)
  --wiki     insurance wiki folder (outline and data text, optional)
Only files under the allowed document roots are read; customer/personal folders
(mail, messenger, customer files, intake inboxes) are skipped by path rules.

Output: one SQLite file (default worker/kb/bl_kb.sqlite3, git-ignored), written to a
temporary name first and swapped in at the end so the worker never sees a half index.
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
from kb_search import tokens  # noqa: E402

ALLOW_ROOTS = ("/Volumes/MacWorkSSD/원본자료/", "/Volumes/MacWorkSSD/데이터화작업/", str(Path.home() / "Downloads") + "/")
EXCLUDE = re.compile(r"(메일|mail|카톡|kakao|고객|보험노트|customer|inbox|intake|pending_originals|messages|telegram|텔레그램|_애매)", re.I)
KINDS = ("상품요약서", "약관", "사업방법서", "상품설명서")
PHONE = re.compile(r"01[016789][-. ]?\d{3,4}[-. ]?\d{4}")
CHUNK = 700


def page_limit(f: dict) -> int:
    pages = int(f.get("pages") or 0) or 400
    if f["kind"] == "약관":
        return pages if f.get("category") == "silson" else min(pages, 40)
    if f["kind"] == "사업방법서":
        return min(pages, 20)
    return min(pages, 120)


def allowed_path(f: dict) -> str | None:
    for p in [f.get("path")] + list(f.get("also") or []):
        if p and p.startswith(ALLOW_ROOTS) and not EXCLUDE.search(p) and os.path.isfile(p):
            return p
    return None


def clean(text: str) -> str:
    text = re.sub(r"\(cid:\d+\)", " ", text)
    text = re.sub(r"[​-‏﻿­]", "", text)
    return text


def hangul_ratio(text: str) -> float:
    s = re.sub(r"\s", "", text)
    return (len(re.findall(r"[가-힣]", s)) / len(s)) if s else 0.0


def chunk_page(text: str) -> list[str]:
    paras, cur = [], []
    for line in clean(text).splitlines():
        line = re.sub(r"[ \t]+", " ", line).strip()
        if not line:
            if cur:
                paras.append(" ".join(cur))
                cur = []
            continue
        cur.append(line)
    if cur:
        paras.append(" ".join(cur))
    out, buf = [], ""
    for p in paras:
        while len(p) > CHUNK + 200:
            cut = max(p.rfind("다. ", 0, CHUNK), p.rfind(". ", 0, CHUNK), p.rfind(" ", 0, CHUNK))
            cut = cut + 2 if cut > CHUNK // 2 else CHUNK
            if buf:
                out.append(buf)
                buf = ""
            out.append(p[:cut].strip())
            p = p[cut:].strip()
        if len(buf) + len(p) + 1 > CHUNK and buf:
            out.append(buf)
            buf = p
        else:
            buf = (buf + " " + p).strip()
    if buf:
        out.append(buf)
    return [c for c in out if len(re.findall(r"[가-힣]", c)) >= 40 and hangul_ratio(c) >= 0.3 and not PHONE.search(c)]


def pdf_pages(path: str, limit: int) -> list[str]:
    try:
        r = subprocess.run(["pdftotext", "-q", "-enc", "UTF-8", "-l", str(limit), path, "-"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=240, check=False)
        return r.stdout.decode("utf-8", "replace").split("\f")
    except (OSError, subprocess.TimeoutExpired):
        return []


def cached_pages(pages_dir: Path | None, sha: str, limit: int) -> list[str] | None:
    if not pages_dir:
        return None
    f = pages_dir / f"{sha}.json"
    if not f.is_file():
        return None
    try:
        rows = json.loads(f.read_text(encoding="utf-8"))
        rows = sorted(rows, key=lambda r: r.get("page", 0))
        return [r.get("raw") or r.get("layout") or "" for r in rows][:limit]
    except (OSError, ValueError):
        return None


class Index:
    def __init__(self, path: Path):
        self.db = sqlite3.connect(str(path))
        self.db.executescript("""
            pragma journal_mode=off; pragma synchronous=off;
            create table docs(id integer primary key, sha text, insurer text, product text, kind text, edition text,
                              category text, category_name text, pages int, source text);
            create table chunks(id integer primary key, doc_id int, page int, text blob);
            create virtual table fts using fts5(meta, body, content='', tokenize='unicode61 remove_diacritics 0');
            create table meta(k text primary key, v text);
        """)
        self.seen: set[str] = set()
        self.n_chunks = 0

    def add_doc(self, sha, insurer, product, kind, edition, category, category_name, pages, source) -> int:
        cur = self.db.execute("insert into docs(sha,insurer,product,kind,edition,category,category_name,pages,source) values(?,?,?,?,?,?,?,?,?)",
                              (sha, insurer or "", product or "", kind or "", edition or "", category or "", category_name or "", pages, source))
        return cur.lastrowid

    def add_chunk(self, doc_id: int, page: int, text: str, meta: str) -> bool:
        key = hashlib.sha1(re.sub(r"\s+", "", text).encode("utf-8")).hexdigest()
        if key in self.seen:
            return False
        self.seen.add(key)
        cid = self.db.execute("insert into chunks(doc_id,page,text) values(?,?,?)",
                              (doc_id, page, zlib.compress(text.encode("utf-8"), 6))).lastrowid
        self.db.execute("insert into fts(rowid, meta, body) values(?,?,?)", (cid, meta, " ".join(tokens(text))))
        self.n_chunks += 1
        return True


def evidence_chunks(e: dict) -> list[tuple[int, str]]:
    out = []
    t = e.get("terms") or {}
    if t:
        bits = [f"{label}: {t[k]}" for k, label in (("period", "보험기간"), ("pay_period", "납입기간"), ("pay_cycle", "납입주기"), ("ages", "가입나이")) if t.get(k)]
        if bits:
            out.append((int(t.get("page") or 0), "가입 조건 — " + " / ".join(bits)))
    covs = [c for c in (e.get("coverages") or []) if isinstance(c, dict) and c.get("name")]
    for i in range(0, len(covs), 4):
        part = covs[i:i + 4]
        text = "보장 내용 — " + " / ".join(f"{c['name']}: {c.get('amount', '')} ({c.get('when', '')})".replace(" ()", "") for c in part)
        out.append((int(part[0].get("page") or 0), text))
    for key, label in (("exclusions", "보장 제외·보장개시"), ("renewal", "갱신"), ("underwriting", "가입 심사")):
        v = e.get(key)
        if isinstance(v, list) and v:
            items = [x.get("text") or x.get("desc") or x.get("name") or "" for x in v if isinstance(x, dict)]
            page = next((int(x.get("page") or 0) for x in v if isinstance(x, dict) and x.get("page")), 0)
            items = [x for x in items if x]
            if items:
                out.append((page, f"{label} — " + " / ".join(items)[:900]))
        elif isinstance(v, dict) and (v.get("text") or v.get("summary")):
            out.append((int(v.get("page") or 0), f"{label} — " + str(v.get("text") or v.get("summary"))[:900]))
    return [(p, x) for p, x in out if not PHONE.search(x)]


def wiki_chunks(wiki: Path) -> list[tuple[str, str]]:
    """(section, text) from the wiki page data (strings only) — phone numbers dropped."""
    out = []
    f = wiki / "site_v2" / "index.html"
    if not f.is_file():
        return out
    html = f.read_text(encoding="utf-8")
    m = re.search(r"/\*\s*=+\s*DATA\s*=+\s*\*/(.*?)/\*\s*=+\s*STATE", html, re.S)
    data = m.group(1) if m else ""
    strings = [s.encode("utf-8").decode("unicode_escape", "ignore") if "\\u" in s else s
               for s in re.findall(r"'((?:[^'\\]|\\.)*)'", data)]
    strings = [re.sub(r"<[^>]+>", " ", s).replace("\\'", "'").strip() for s in strings]
    strings = [s for s in strings if re.search(r"[가-힣]", s) and not PHONE.search(s)]
    buf, head = "", ""
    for s in strings:
        if len(s) <= 14 and not buf:
            head = s
        if len(buf) + len(s) + 1 > CHUNK and buf:
            out.append((head, buf))
            buf, head = "", s if len(s) <= 14 else head
        buf = (buf + " " + s).strip()
    if buf:
        out.append((head, buf))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--catalog", required=True)
    ap.add_argument("--evidence")
    ap.add_argument("--pages")
    ap.add_argument("--wiki")
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent / "kb" / "bl_kb.sqlite3"))
    ap.add_argument("--limit-files", type=int, default=0, help="시험용: 앞에서 몇 개 파일만")
    ap.add_argument("--workers", type=int, default=4)
    args = ap.parse_args()
    started = time.time()
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".building")
    if tmp.exists():
        tmp.unlink()
    idx = Index(tmp)
    catalog = json.loads(Path(args.catalog).read_text(encoding="utf-8"))
    cat_names = {p.get("category"): p.get("category_name") for p in catalog.get("products", []) if isinstance(p, dict)}
    files = [f for f in catalog["files"].values() if f.get("latest") and f.get("text") and f.get("kind") in KINDS]
    jobs = []
    skipped_path = 0
    for f in files:
        p = allowed_path(f)
        if not p:
            skipped_path += 1
            continue
        jobs.append((f, p))
    order = {k: i for i, k in enumerate(KINDS)}
    jobs.sort(key=lambda x: (order[x[0]["kind"]], x[0].get("insurer") or "", x[0].get("product") or ""))
    if args.limit_files:
        jobs = jobs[: args.limit_files]
    pages_dir = Path(args.pages) if args.pages else None
    reused = 0

    def load(job):
        f, p = job
        lim = page_limit(f)
        cached = cached_pages(pages_dir, f.get("sha256", ""), lim)
        return job, (cached if cached is not None else pdf_pages(p, lim)), cached is not None

    done = 0
    with cf.ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
        for (f, p), pages, was_cached in pool.map(load, jobs):
            reused += int(was_cached)
            doc = idx.add_doc(f.get("sha256"), f.get("insurer"), f.get("product"), f["kind"], f.get("edition"),
                              f.get("category"), cat_names.get(f.get("category"), ""), f.get("pages"), "catalog")
            meta = " ".join(tokens(f"{f.get('insurer', '')} {f.get('product', '')} {f['kind']} {cat_names.get(f.get('category'), '')}"))
            for no, text in enumerate(pages, start=1):
                for c in chunk_page(text):
                    idx.add_chunk(doc, no, c, meta)
            done += 1
            if done % 50 == 0:
                idx.db.commit()
                print(json.dumps({"files": done, "of": len(jobs), "chunks": idx.n_chunks, "secs": round(time.time() - started)}), flush=True)
    ev_docs = 0
    if args.evidence and Path(args.evidence).is_dir():
        for ef in sorted(Path(args.evidence).glob("p-*.json")):
            try:
                e = json.loads(ef.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if e.get("status") != "ok":
                continue
            src = (e.get("sources") or [{}])[0]
            if src.get("path") and EXCLUDE.search(src["path"]):
                continue
            doc = idx.add_doc(src.get("sha256"), e.get("insurer"), e.get("product"), src.get("kind") or "상품요약서", e.get("edition"),
                              e.get("category"), e.get("category_name"), src.get("pages"), "evidence")
            meta = " ".join(tokens(f"{e.get('insurer', '')} {e.get('product', '')} {src.get('kind', '')} {e.get('category_name', '')}"))
            for page, text in evidence_chunks(e):
                idx.add_chunk(doc, page, text, meta)
            ev_docs += 1
    wiki_n = 0
    if args.wiki and Path(args.wiki).is_dir():
        doc = idx.add_doc("", "", "보험위키 정리", "보험위키", "2026-10-08", "wiki", "보험 일반 지식", 0, "wiki")
        meta = " ".join(tokens("보험위키 보험 일반 지식"))
        for head, text in wiki_chunks(Path(args.wiki)):
            wiki_n += int(idx.add_chunk(doc, 0, text, meta))
    idx.db.commit()
    # 너무 흔한 조각(대부분 문서에 나오는 말)은 검색어에서 뺀다.
    total = idx.n_chunks or 1
    idx.db.execute("create virtual table v using fts5vocab(fts, 'row')")
    idx.db.execute("create table df(term text primary key, doc int) without rowid")
    idx.db.execute("insert into df select term, doc from v")
    stop = [t for (t,) in idx.db.execute("select term from df where doc > ?", (int(total * 0.06),))]
    idx.db.execute("drop table v")
    idx.db.execute("insert into fts(fts) values('optimize')")
    info = {"built_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "files": str(len(jobs)), "files_skipped_by_path_rule": str(skipped_path),
            "pages_reused": str(reused), "evidence_docs": str(ev_docs), "wiki_chunks": str(wiki_n), "chunks": str(idx.n_chunks),
            "stop_tokens": json.dumps(stop, ensure_ascii=False), "build_secs": str(round(time.time() - started))}
    idx.db.executemany("insert into meta(k,v) values(?,?)", list(info.items()))
    idx.db.commit()
    idx.db.execute("vacuum")
    idx.db.close()
    os.replace(tmp, out)
    os.chmod(out, 0o600)
    info.pop("stop_tokens")
    info["stop_count"] = len(stop)
    info["size_mb"] = round(out.stat().st_size / 1e6, 1)
    print(json.dumps(info, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
