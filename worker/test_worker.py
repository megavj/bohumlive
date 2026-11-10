"""Boundary tests use synthetic strings only; no live accounts or API calls."""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("bl_worker", Path(__file__).with_name("bohumlive_worker.py"))
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


@unittest.skip("2026-11-10 대표 지시: 개인정보 치환 규칙 제거")
class PrivacyBoundary(unittest.TestCase):
    def test_direct_identifiers_removed(self):
        value = "010-1234-5678 900101-1234567 test@example.invalid https://example.invalid/private"
        result = worker.redact(value)
        for token in ("1234", "900101", "test@example", "https://"):
            self.assertNotIn(token, result)

    def test_unicode_and_markup_cannot_bypass_phone_filter(self):
        result = worker.redact("０１０-１２３４-５６７８ 010\u200b12345678 <b>900101</b>-<i>1234567</i>")
        self.assertNotIn("1234", result)
        self.assertNotIn("900101", result)

    def test_generic_insurance_guidance_is_preserved(self):
        value = ("말씀하신 방향대로 고객의 기억과 자료를 구분하세요. "
                 "이해 수준은 고객이 자기 말로 설명하도록 물어보세요. "
                 "고지 항목을 설계사가 임의로 판단하지 않습니다. "
                 "결론보다 고객이 확인한 항목을 적습니다. "
                 "말씀하신 고객이 이미 가지고 있는 자료를 확인하세요. "
                 "확인하셨다면 고객이 직접 설명하도록 도와주세요.")
        self.assertEqual(worker.redact(value), value)

    def test_names_with_roles_remain_private(self):
        # Synthetic names, including names ending in a Korean particle syllable.
        for name, role in (("홍길동", "고객님"), ("김철수", "설계사"),
                           ("김하은", "고객"), ("김가을", "계약자"),
                           ("최다이", "피보험자"), ("한별", "씨"),
                           ("남궁민수", "팀장님")):
            for gap in (" ", ""):
                with self.subTest(name=name, role=role, gap=gap):
                    value = f"{name}{gap}{role}이 확인했습니다."
                    self.assertEqual(worker.redact(value), "[인명 삭제]이 확인했습니다.")

    def test_generic_phrases_do_not_hide_adjacent_name_leaks(self):
        value = ("이해 수준은 고객이 설명합니다. 홍길동 고객님과 "
                 "<b>김철수</b> 설계사가 확인했습니다. 김\u200b하은 고객이 답했습니다.")
        result = worker.redact(value)
        self.assertIn("이해 수준은 고객이 설명합니다.", result)
        for name in ("홍길동", "김철수", "김하은"):
            self.assertNotIn(name, result)

    def test_ordinary_noun_phrases_and_sequence_words_are_preserved(self):
        value = ("상담 메모에는 고객의 기억과 자료를 구분해 적습니다. "
                 "확인 자료는 고객이 직접 준비합니다. "
                 "안내 문구에는 고객의 선택을 유도하지 않는 질문을 적습니다. "
                 "정리한 자료로 고객에게 설명합니다. "
                 "‘어떻게 이해하셨나요’처럼 고객이 직접 설명하도록 질문합니다. "
                 "우선 고객이 이미 가지고 있는 자료를 확인합니다. "
                 "먼저 고객에게 확인하고 이후 고객이 준비한 자료를 정리합니다. "
                 "그다음 고객이 이해한 내용을 확인하고 해당 설계사가 기록합니다.")
        self.assertEqual(worker.redact(value), value)

    def test_standalone_roles_with_honorifics_are_not_names(self):
        value = "고객님이 확인하고 설계사님께 설명합니다. 계약자님과 피보험자님도 함께합니다."
        self.assertEqual(worker.redact(value), value)

    def test_reviewed_ordinary_verb_phrases_are_preserved(self):
        for value in ("항목 순서로 구성하면 고객이 비용만 보지 않도록 안내할 수 있습니다.",
                      "확인 자료를 정리하면 고객이 차이를 이해하기 쉽습니다.",
                      "표에 나란히 배치하면 고객이 내용을 비교하기 쉽습니다.",
                      "확인한 자료를 보여주면 고객이 직접 설명할 수 있습니다.",
                      "상품 세대가 무엇인지 고객이 가진 증권을 확인합니다."):
            with self.subTest(value=value):
                self.assertEqual(worker.redact(value), value)

    def test_grammar_exceptions_cannot_exempt_partial_names_or_strong_honorifics(self):
        for value, name in (("문서류 고객이 확인합니다.", "문서류"),
                            ("김정보 설계사가 확인합니다.", "김정보"),
                            ("김메모 고객에게 설명합니다.", "김메모"),
                            ("김자료는 계약자입니다.", "김자료"),
                            ("박민가 수익자가 확인합니다.", "박민가"),
                            ("강하을 씨가 확인합니다.", "강하을"),
                            ("오율님이 확인합니다.", "오율"),
                            ("제갈민수 고객님이 확인합니다.", "제갈민수"),
                            ("우선 고객님이 확인합니다.", "우선"),
                            ("메모에는 고객님이 확인합니다.", "메모에는")):
            with self.subTest(value=value):
                result = worker.redact(value)
                self.assertNotIn(name, result)
                self.assertIn("[인명 삭제]", result)

    def test_synthetic_question_bodies_reach_the_model_unchanged(self):
        # The three public, fictional sample questions contain no personal data.
        jobs = [{'title': '고지 항목이 애매할 때, 상담 메모를 어떻게 정리하시나요?',
          'body': '가상의 상담 사례를 놓고 동료 의견을 듣고 싶습니다. 고객이 예전에 진료를 받은 기억은 있지만 당시 진단명이나 검사 결과를 정확히 기억하지 못하는 '
                  '상황입니다.\n'
                  '\n'
                  '저라면 우선 고객의 기억과 확인된 자료를 나눠 적고, 해당 청약서의 질문 문구를 그대로 확인한 다음 부족한 부분을 정리해 담당 부서에 문의하는 순서를 '
                  '생각하고 있습니다. 설계사가 임의로 ‘이 정도는 안 써도 된다’고 정리하지 않으려는 취지입니다.\n'
                  '\n'
                  '이런 상황에서 상담 메모에 어떤 항목을 남기면 다음 확인이 수월할까요? 실제 고객의 병력이나 신원은 빼고, 자료를 정리하는 순서와 질문 목록 중심으로 경험을 '
                  '나눠 주세요.'},
         {'title': '3세대에서 4세대 실손 전환 상담, 비교표는 어떤 순서로 보여주시나요?',
          'body': '전환을 결정한 고객 이야기가 아니라 상담 자료를 만드는 가상의 상황입니다. 3세대와 4세대 실손을 비교할 때 첫 장부터 보험료만 크게 보여 주면 다른 확인 '
                  '항목을 놓치기 쉬울 것 같아 구성 순서를 고민하고 있습니다.\n'
                  '\n'
                  '현재 계약의 가입 시점과 약관, 실제 부담하는 보험료, 자기부담 관련 항목, 이용 상황별 비교, 전환 전후 확인할 사항을 각각 빈칸으로 둔 표를 생각하고 '
                  '있습니다. 숫자와 적용 여부는 계약별 공식 자료를 확인한 뒤 채울 예정입니다.\n'
                  '\n'
                  '동료분들은 고객이 비교 내용을 이해했는지 어떤 질문으로 확인하시나요? 어느 쪽이 무조건 유리하다는 결론보다, 상담에서 빠뜨리지 않도록 체크하는 순서를 듣고 '
                  '싶습니다.'},
         {'title': '실손 청구 서류 안내, 첫 연락에서 무엇부터 확인하시나요?',
          'body': '실손 청구 안내용 체크리스트를 만들어 보는 중입니다. ‘필요한 서류를 전부 준비해 주세요’라고 한 번에 말하기보다, 접수할 보험사와 계약, 청구하려는 상황을 '
                  '확인한 뒤 공식 안내에 맞춰 설명하는 흐름을 생각하고 있습니다.\n'
                  '\n'
                  '입원인지 통원인지, 고객이 이미 가지고 있는 자료가 무엇인지, 추가 확인이 필요한 항목은 무엇인지 순서대로 정리하면 안내가 덜 길어질 것 같습니다. 다만 이 '
                  '글에서 특정 서류가 항상 필수라거나 보험금이 지급된다고 정하려는 것은 아닙니다.\n'
                  '\n'
                  '첫 통화나 메시지에 담는 설명 순서를 어떻게 구성하시나요? 실존 고객 정보 없이, 회사의 최신 청구 안내를 함께 확인하는 방식에 대한 의견을 부탁드립니다.'}]
        for job in jobs:
            with self.subTest(title=job["title"]):
                data = json.loads(worker.question_data(job).split("\n", 1)[1])
                self.assertEqual(data["title"], job["title"])
                self.assertEqual(data["question"], job["body"])

    def test_prompt_has_only_allowlisted_fields(self):
        value = worker.question_data({"title": "약관 확인", "body": "어떤 순서인가요?",
                                      "name": "DO_NOT_SEND_NAME", "phone": "DO_NOT_SEND_PHONE",
                                      "id": "DO_NOT_SEND_ID", "proof_path": "DO_NOT_SEND_PROOF"})
        self.assertNotIn("DO_NOT_SEND", value)
        data = json.loads(value.split("\n", 1)[1])
        self.assertEqual(set(data), {"title", "question", "official_sources"})

    def test_unrelated_environment_credentials_never_inherited(self):
        with mock.patch.dict(worker.os.environ, {"ANTHROPIC_API_KEY": "fake",
                "BL_SERVICE_ROLE_KEY": "fake", "OPENAI_API_KEY": "fake",
                "HTTPS_PROXY": "fake", "CLAUDE_CODE_DEBUG_LOGS_DIR": "fake"}):
            env = worker.claude_environment("test-subscription")
        self.assertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "test-subscription")
        self.assertNotIn("ANTHROPIC_API_KEY", env)
        self.assertNotIn("BL_SERVICE_ROLE_KEY", env)
        self.assertNotIn("OPENAI_API_KEY", env)
        self.assertNotIn("HTTPS_PROXY", env)
        self.assertNotIn("CLAUDE_CODE_DEBUG_LOGS_DIR", env)

    def test_storage_delete_rejects_traversal_and_foreign_paths(self):
        backend = worker.Backend(worker.DEFAULT_URL, "fake")
        with mock.patch.object(backend, "request") as request:
            for value in ("../other", "another-bucket/a", "uuid/realname.png"):
                with self.assertRaises(worker.WorkerError):
                    backend.delete_proofs([value])
            request.assert_not_called()

    def test_backend_rejects_non_supabase_host(self):
        for url in ("http://localhost", "https://supabase.co.evil.invalid", "https://evil.invalid"):
            with self.assertRaises(worker.WorkerError):
                worker.Backend(url, "fake")

    def test_auth_delete_requires_canonical_uuid_and_hard_delete(self):
        backend = worker.Backend(worker.DEFAULT_URL, "fake")
        with mock.patch.object(backend, "request") as request:
            for value in ("../other", "member@example.invalid", "{10000000-0000-0000-0000-000000000001}"):
                with self.assertRaises(worker.WorkerError):
                    backend.delete_withdrawn_auth_user(value)
            request.assert_not_called()
            user_id = "10000000-0000-0000-0000-000000000001"
            backend.delete_withdrawn_auth_user(user_id)
            request.assert_called_once_with("/auth/v1/admin/users/" + user_id,
                {"should_soft_delete": False}, method="DELETE", missing_ok=True)

    def test_auth_cleanup_follows_successful_proof_cleanup(self):
        backend = mock.Mock()
        backend.rpc.side_effect = [{"paths": ["opaque-path"]}, {}, {}, {"ids": ["opaque-user"]}, {}]
        with mock.patch.object(worker, "log"):
            worker.maintenance(backend)
        self.assertEqual(backend.mock_calls, [
            mock.call.rpc("cleanup_list"), mock.call.delete_proofs(["opaque-path"]),
            mock.call.rpc("cleanup_done", {"paths": ["opaque-path"]}),
            mock.call.rpc("temporary_review"), mock.call.rpc("cleanup_users"),
            mock.call.delete_withdrawn_auth_user("opaque-user"),
            mock.call.rpc("cleanup_user_done", {"id": "opaque-user"}),
        ])

    def test_failed_proof_cleanup_never_deletes_auth_account(self):
        backend = mock.Mock()
        backend.rpc.return_value = {"paths": ["opaque-path"]}
        backend.delete_proofs.side_effect = worker.WorkerError("backend_request_failed")
        with self.assertRaises(worker.WorkerError):
            worker.maintenance(backend)
        backend.delete_withdrawn_auth_user.assert_not_called()

    def test_ai_failure_is_recorded_without_question_or_error_body(self):
        backend = mock.Mock()
        backend.rpc.side_effect = [{"job": {"id": "job", "lease_token": "lease", "body": "private"}}, {}]
        with mock.patch.object(worker, "generate", side_effect=worker.WorkerError("subscription_timeout")):
            with self.assertRaises(worker.WorkerError):
                worker.process_one(backend)
        action, payload = backend.rpc.call_args.args
        self.assertEqual(action, "fail")
        self.assertEqual(payload, {"id": "job", "lease_token": "lease", "error": "subscription_timeout"})


class ReferenceSources(unittest.TestCase):
    """2026-11-10 맥 자료 근거: 색인이 없거나 깨져도 멈추지 않고, 근거 규칙을 지킨다."""

    def test_missing_or_broken_index_means_no_sources(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            broken = Path(d) / "broken.sqlite3"
            broken.write_bytes(b"not a database")
            for path in (Path(d) / "missing.sqlite3", broken):
                with self.subTest(path=path.name), mock.patch.object(worker.kb_search, "KB_PATH", path):
                    sources, ms = worker.find_sources({"title": "실손 전환", "body": "기존 계약은?"})
                    self.assertEqual(sources, [])
                    self.assertIsInstance(ms, int)

    def test_search_exception_never_stops_answer(self):
        with mock.patch.object(worker.kb_search, "search", side_effect=RuntimeError("boom")):
            self.assertEqual(worker.find_sources({"title": "x", "body": "y"})[0], [])

    def test_sources_reach_model_with_allowlisted_fields_only(self):
        src = [{"자료": "가나생명 다라보험 약관", "보험사": "가나생명", "상품": "다라보험", "종류": "약관",
                "기준": "2026.4 기준", "쪽": 12, "발췌": "보험금 청구 서류는 진단서입니다.",
                "_score": 3.1, "_source": "catalog", "path": "/Users/secret/file.pdf"}]
        data = json.loads(worker.question_data({"title": "t", "body": "b"}, src).split("\n", 1)[1])
        self.assertEqual(len(data["official_sources"]), 1)
        self.assertEqual(set(data["official_sources"][0]), set(worker.SOURCE_FIELDS))
        self.assertNotIn("/Users/secret", json.dumps(data, ensure_ascii=False))

    def test_answer_rules_for_sources(self):
        src = [{"자료": "가나생명 다라보험 상품요약서", "보험사": "가나생명", "발췌": "중증치매 진단자금 1,000만원을 지급합니다."}]
        ok = "결론입니다.\n\n• 가나생명 다라보험 상품요약서(2026.10 기준)에 따르면 중증치매 진단자금은 1,000만원입니다."
        self.assertEqual(worker.answer_problem(ok, src, "치매 보장"), "")
        self.assertIn("금액", worker.answer_problem(ok.replace("1,000만원", "2,000만원"), src, "치매 보장"))
        self.assertIn("회사 이름", worker.answer_problem(ok + " 삼성생명도 비슷합니다.", src, "치매 보장"))
        dsrc = [{"자료": "DB손해보험 간편실손 약관", "보험사": "DB손해보험", "발췌": "진단서"}]
        self.assertEqual(worker.answer_problem("결론.\n\n• DB손보 간편실손 약관에 따르면 진단서를 냅니다.", dsrc, "q"), "")
        self.assertIn("자료 이름", worker.answer_problem(ok, [], "치매 보장"))
        self.assertEqual(worker.answer_problem("일반 원칙입니다.\n\n• 약관의 청구 조항을 보세요.", [], "q"), "")

    def test_no_rewrite_when_first_answer_is_slow(self):
        calls = []

        def fake(job, heartbeat, fix, sources=(), deadline=None):
            calls.append(fix)
            return {"body": "삼성생명 약관에 따르면 됩니다.", "model": "claude-opus-5-5", "effort": "medium",
                    "subscription": True, "fallback_used": False, "elapsed_ms": 1}
        ticks = iter([0.0, worker.REWRITE_START_LIMIT + 1, worker.REWRITE_START_LIMIT + 2])
        with mock.patch.object(worker, "_generate_once", side_effect=fake), \
                mock.patch.object(worker.time, "monotonic", side_effect=lambda: next(ticks)):
            worker.generate({"title": "t", "body": "b"}, sources=[])
        self.assertEqual(len(calls), 1)

    def test_rewrite_once_for_unsupported_citation(self):
        answers = iter(["가나생명 약관에 따르면 됩니다.", "일반 원칙으로 보면 됩니다."])

        def fake(job, heartbeat, fix, sources=(), deadline=None):
            return {"body": next(answers), "model": "claude-opus-5-5", "effort": "medium",
                    "subscription": True, "fallback_used": False, "elapsed_ms": 1}
        with mock.patch.object(worker, "_generate_once", side_effect=fake):
            result = worker.generate({"title": "t", "body": "b"}, sources=[])
        self.assertEqual(result["body"], "일반 원칙으로 보면 됩니다.")
        self.assertTrue(result["rewritten"])
        self.assertEqual(result["rewrite_reason"], "cite_without_source")

    def test_question_words_and_insurer_detection(self):
        kb = worker.kb_search
        self.assertIn("실손", kb.key_words("실비 전환하면 어떻게 되나요?"))
        self.assertNotIn("어떻게", kb.key_words("실비 전환하면 어떻게 되나요?"))
        self.assertIn("암", kb.key_words("암 진단비 서류"))

    def test_title_tags_and_pet_documents(self):
        import tempfile, sqlite3, zlib as z
        kb = worker.kb_search
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "kb.sqlite3"
            db = sqlite3.connect(str(path))
            db.executescript("""create table docs(id integer primary key, sha text, insurer text, product text, kind text, edition text,
                category text, category_name text, pages int, source text);
                create table chunks(id integer primary key, doc_id int, page int, text blob);
                create virtual table fts using fts5(meta, body, content='', tokenize='unicode61 remove_diacritics 0');
                create table meta(k text primary key, v text); create table df(term text primary key, doc int) without rowid;""")
            rows = [(1, "가나손해보험", "튼튼건강보험", "암진단비 청구 서류: 진단서, 조직검사 결과지를 냅니다."),
                    (2, "가나손해보험", "펫사랑반려견보험", "암진단비 청구 서류: 진단서, 조직검사 결과지를 냅니다. 반려견")]
            for i, ins, prod, text in rows:
                db.execute("insert into docs values(?,?,?,?,?,?,?,?,?,?)", (i, "", ins, prod, "약관", "2026-07-01", "", "", 1, "catalog"))
                db.execute("insert into chunks values(?,?,?,?)", (i, i, 3, z.compress(text.encode())))
                db.execute("insert into fts(rowid, meta, body) values(?,?,?)", (i, " ".join(kb.tokens(ins + prod)), " ".join(kb.tokens(text))))
            db.execute("insert into meta values('chunks','2')")
            db.execute("create virtual table v using fts5vocab(fts,'row')"); db.execute("insert into df select term, doc from v")
            db.commit(); db.close()
            found = kb.search("[시험] 암 진단비 청구 서류", "조직검사 결과지도 내야 하나요?", path=path)
            self.assertEqual([x["상품"] for x in found], ["튼튼건강보험"])
            self.assertEqual(found[0]["기준"], "2026.7 기준")


if __name__ == "__main__":
    unittest.main()
