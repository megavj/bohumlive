"""AI upgrade boundaries: synthetic data, no DB/network/subscription calls."""
import contextlib
import io
import json
import unittest
from unittest import mock

import bohumlive_worker as w


POST = "10000000-0000-0000-0000-000000000001"
PEER = "10000000-0000-0000-0000-000000000002"
OTHER = "10000000-0000-0000-0000-000000000003"


def answer(body="가입 조건과 적용 시점을 구분해서 확인하세요.", **extra):
    return dict(body=body, model=w.MODEL, effort=w.EFFORT, subscription=True,
                fallback_used=False, elapsed_ms=1, **extra)


class TextBoundaries(unittest.TestCase):
    def test_meaningless_is_exact_not_a_question_keyword(self):
        for text in ("테스트", "ㅋㅋㅋ", "울랄랄라", "test 123", "!!!", "ㅎㅎ"):
            self.assertTrue(w.meaningless({"title": text, "body": ""}), text)
        for text in ("검사 테스트 비용 청구가 되나요?", "ㅋㅋ 오늘 상담 취소돼 속상해요", "심사 문의"):
            self.assertFalse(w.meaningless({"title": text, "body": ""}), text)

    def test_followup_classifies_current_question(self):
        self.assertTrue(w.meaningless({"title": "보험 청구 질문", "body": "절차가 궁금해요",
                                     "trigger_comment_id": PEER, "question": "ㅋㅋ"}))

    def test_skip_never_calls_cli(self):
        with mock.patch.object(w, "_generate_once") as cli:
            result = w.generate({"title": "테스트", "body": "ㅋㅋ"})
        cli.assert_not_called()
        self.assertEqual((result["classification"], result["body"]), ("skip", ""))

    def test_drop_not_found_never_restores_short_remainder(self):
        for text in ("자료가 없습니다.", "근거를 찾지 못했습니다.", "공식 자료를 확인하지 못했습니다.",
                     "확인할 수 없습니다.", "제공된 자료에는 다른 내용만 있습니다."):
            self.assertEqual(w.drop_not_found(text), "")
        self.assertEqual(w.drop_not_found("자료가 없습니다. 계약 조건을 확인하세요."), "계약 조건을 확인하세요.")

    def test_scrub_links_numbers_and_web_mentions(self):
        text = "사내 자료에 따르면 순서대로 접수하세요.[1] [웹]\nhttps://example.invalid/a\n출처: 비밀자료 13쪽"
        clean = w.scrub_sources(text)
        for token in ("사내", "따르면", "[1]", "웹", "https", "출처", "13쪽"):
            self.assertNotIn(token, clean)

    def test_unsupported_numbers_rejected_without_any_sources(self):
        for body in ("면책기간은 90일입니다.", "수수료는 20%입니다.", "보험금은 100만원입니다."):
            self.assertIn("금액", w.answer_problem(body))
        self.assertEqual(w.answer_problem("1. 계약을 확인하세요.\n2. 서류를 접수하세요."), "")

    def test_numeric_substrings_are_not_evidence(self):
        self.assertIn("금액", w.answer_problem("기간은 10일입니다.", [{"발췌": "기간은 210일"}]))
        self.assertEqual(w.answer_problem("기간은 90일입니다.", [{"발췌": "기간은 90일"}]), "")

    def test_comparison_can_be_700_but_not_701(self):
        self.assertEqual(w.answer_problem("가" * 700, answer_type="comparison"), "")
        self.assertTrue(w.answer_problem("가" * 701, answer_type="comparison"))

    def test_comparison_can_name_evidenced_companies(self):
        sources = [{"보험사": "삼성화재", "발췌": "조건을 구분합니다."}]
        self.assertEqual(w.answer_problem("삼성화재: 조건을 구분하세요.", sources, "회사별 비교", "comparison"), "")
        self.assertTrue(w.answer_problem("현대해상: 조건을 구분하세요.", sources, "회사별 비교", "comparison"))

    def test_short_chitchat_remains_useful(self):
        for category, style, body in (("chitchat", "general", "힘드시죠.\n잠깐 쉬세요."),):
            with mock.patch.object(w, "_generate_once", return_value=answer(body, classification=category, answer_type=style)):
                result = w.generate({"title": "상담 고민", "body": "어떻게 말할까요"})
            self.assertEqual(result["body"], body)

    def test_normal_insurance_verbs_are_not_customer_names(self):
        value = "갱신되면 고객이 확인합니다. 변경되면 고객에게 안내합니다."
        self.assertEqual(w.redact(value), value)

    def test_script_keeps_guidance_and_one_multisentence_example(self):
        body = ('고객의 부담을 먼저 확인하세요.\n필요한 보장과 조정 가능한 항목을 함께 비교하세요.\n'
                '예시: “어떤 점이 가장 부담되시는지 먼저 듣고 싶습니다. 필요한 보장을 유지하면서 조정할 방법을 함께 살펴볼까요?”')
        with mock.patch.object(w, "_generate_once", return_value=answer(body, classification="question", answer_type="script")):
            result = w.generate({"title": "상담 화법", "body": "예시 한 문장"})
        self.assertEqual(result["body"], body)

    def test_empty_after_scrub_routes_to_actual_channel(self):
        job = {"title": "청구 문의", "body": "어떻게 하나요?", "channels": [{"name": "보상"}]}
        with mock.patch.object(w, "_generate_once", return_value=answer("자료가 없습니다.")):
            result = w.generate(job)
        self.assertIn("보상 채널 동료 경험을 물어보세요", result["body"])
        self.assertNotIn("자료가 없", result["body"])
        self.assertNotIn("채널", w.channel_fallback({}))

    def test_numeric_failure_cannot_publish_after_rewrite(self):
        with mock.patch.object(w, "_generate_once", return_value=answer("면책기간은 반드시 999일입니다.")):
            result = w.generate({"title": "면책기간", "body": "궁금합니다"})
        self.assertNotIn("999", result["body"])

    def test_prompt_allowlist_strips_author_metadata_and_personal_data(self):
        job = {"title": "청구 문의", "body": "연락처 010-1234-5678", "post_id": POST,
               "question": "test@example.invalid 언제 접수하나요?", "nickname": "PRIVATE_NICKNAME",
               "known_names": ["홍길동"],
               "conversation": [{"id": PEER, "author": "PRIVATE_NAME", "company_name": "PRIVATE_COMPANY", "is_ai": False, "body": "홍길동 고객님의 청구"}],
               "peer_sources": [{"post_id": PEER, "title": "청구 절차", "body": "서류 확인", "nickname": "PRIVATE_NICKNAME",
                                 "comments": [{"body": "먼저 접수합니다", "is_accepted": True, "company": "PRIVATE_COMPANY"}]}],
               "channels": [{"id": OTHER, "name": "보상", "secret": "PRIVATE_CHANNEL"}]}
        data = w.question_data(job)
        for token in ("PRIVATE_", "1234", "test@example", "홍길동", '"author"', '"company_name"', POST, OTHER):
            self.assertNotIn(token, data)
        parsed = json.loads(data.split("\n", 1)[1])
        self.assertEqual(parsed["conversation"][0]["role"], "user")
        self.assertTrue(parsed["peer_sources"][0]["comments"][0]["is_accepted"])

    def test_eight_sources_only_and_paths_not_forwarded(self):
        sources = [{"자료": "약관", "발췌": "절차" * 1000, "path": "private"} for _ in range(12)]
        clean = w.clean_sources(sources)
        self.assertEqual(len(clean), 8)
        self.assertEqual(len(clean[0]["발췌"]), 1600)
        self.assertNotIn("path", clean[0])

    def test_busy_thread_preserves_accepted_answer_and_all_ai_turns(self):
        thread = [{"body": "오래된 채택 답", "is_accepted": True},
                  {"body": "첫 AI 답", "is_ai": True}]
        thread += [{"body": f"사람 질문 {i}"} for i in range(30)]
        thread += [{"body": "마지막 AI 답", "is_ai": True}]
        clean = w.clean_conversation({"conversation": thread})
        self.assertEqual(len(clean), 18)
        self.assertTrue(clean[0]["is_accepted"])
        self.assertEqual([c["body"] for c in clean if c["role"] == "assistant"], ["첫 AI 답", "마지막 AI 답"])

    def test_related_links_require_allowlisted_uuid_and_exclude_self(self):
        job = {"post_id": POST, "peer_sources": [{"post_id": POST, "title": "자신"},
                {"post_id": PEER, "title": "동료 글"}, {"post_id": OTHER, "title": "다른 글"}]}
        result = w.related_posts(job, ["javascript:alert(1)", "https://evil.invalid/", POST,
                                     PEER + "&x=1", PEER, PEER, OTHER])
        self.assertEqual([x["id"] for x in result], [PEER, OTHER])


class SubscriptionBoundary(unittest.TestCase):
    def stream(self, models=None, result=None):
        return json.dumps({"type": "result", "modelUsage": models or {w.MODEL: {}},
                           "result": json.dumps(result or {"classification": "question", "answer_type": "general",
                                                         "body": "가입 조건과 적용 시점을 구분하세요."})})

    def test_opus_required_auxiliary_claude_allowed(self):
        self.assertEqual(w.parse_generation(self.stream({w.MODEL: {}, "claude-haiku-4-5": {}}))["model"], w.MODEL)
        for models in ({"claude-haiku-4-5": {}}, {w.MODEL: {}, "external-model": {}}):
            with self.assertRaisesRegex(w.WorkerError, "subscription_model_unverified"):
                w.parse_generation(self.stream(models))

    def test_web_count_requires_successful_actual_tool_result(self):
        events = [{"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "one", "name": "WebSearch"}]}},
                  {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "one", "content": "기간은 90일"}]}},
                  {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "bad", "content": "999일"}]}}]
        result = w.parse_generation("\n".join(map(json.dumps, events)) + "\n" + self.stream())
        self.assertEqual(len(result["web_sources"]), 1)
        self.assertIn("90일", result["web_sources"][0]["발췌"])
        self.assertNotIn("999", str(result["web_sources"]))

    def test_model_skip_is_successful_empty_answer(self):
        result = w.parse_generation(self.stream(result={"classification": "skip", "answer_type": "general", "body": ""}))
        self.assertEqual(result["classification"], "skip")

    def test_invalid_cli_shapes_fail_with_fixed_labels(self):
        with self.assertRaisesRegex(w.WorkerError, "subscription_invalid_response"):
            w.parse_generation(json.dumps({"type": "result", "modelUsage": ["bad"], "result": ""}))
        with self.assertRaisesRegex(w.WorkerError, "subscription_invalid_answer"):
            w.parse_generation(self.stream(result={"classification": "question", "answer_type": "general", "body": ["bad"]}))

    def test_cli_uses_subscription_opus_medium_and_only_web_tools(self):
        child = mock.Mock()
        child.communicate.return_value = (self.stream(), "")
        child.returncode = 0
        child.poll.return_value = 0
        with mock.patch.object(w.shutil, "which", return_value="/bin/echo"), \
                mock.patch.object(w, "keychain", return_value="synthetic-subscription") as key, \
                mock.patch.object(w.subprocess, "Popen", return_value=child) as popen:
            w._generate_once({"title": "보험 문의", "body": "절차 문의"}, None, "")
        key.assert_called_once_with("timcook-claude-oauth-token")
        command = popen.call_args.args[0]
        for flag, value in (("--model", "claude-opus-5-5"), ("--effort", "medium"),
                            ("--tools", "WebSearch,WebFetch"), ("--allowedTools", "WebSearch,WebFetch"),
                            ("--max-turns", "8"), ("--output-format", "stream-json")):
            self.assertEqual(command[command.index(flag) + 1], value)
        self.assertIn("--no-session-persistence", command)
        self.assertIn("--strict-mcp-config", command)


class RuntimeBoundary(unittest.TestCase):
    def setUp(self):
        self.log = mock.patch.object(w, "log")
        self.log.start()
        self.addCleanup(self.log.stop)

    def test_preview_never_constructs_backend_or_claims_jobs(self):
        with mock.patch.object(w, "Backend") as backend, mock.patch.object(w, "service_key") as key, \
                mock.patch.object(w, "singleton") as lock, mock.patch.object(w.sys, "argv", ["worker", "--preview", "테스트", "ㅋㅋ"]), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(w.main(), 0)
        backend.assert_not_called(); key.assert_not_called(); lock.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())["classification"], "skip")

    def test_preview_reports_evidence_counts_without_source_text(self):
        with mock.patch.object(w, "find_sources", return_value=([{"종류": "약관", "자료": "PRIVATE_DOCUMENT"}], 1)), \
                mock.patch.object(w, "generate", return_value=answer(classification="question", answer_type="general", web_sources=[{}])):
            result = w.preview("보험 문의", "알려주세요")
        self.assertEqual(result["evidence_counts"], {"insurance": 1, "by_kind": {"약관": 1}, "community": 0, "web": 1})
        self.assertNotIn("PRIVATE_DOCUMENT", json.dumps(result))

    def test_fifth_answer_stops_without_generation(self):
        backend = mock.Mock()
        backend.rpc.side_effect = [{"job": {"id": POST, "lease_token": PEER, "ai_reply_count": 5}}, {}]
        with mock.patch.object(w, "generate") as generate:
            self.assertTrue(w.process_one(backend))
        generate.assert_not_called()
        self.assertEqual(backend.rpc.call_args.args[0], "skip")

    def test_regeneration_at_cap_updates_existing_answer(self):
        backend = mock.Mock()
        backend.rpc.side_effect = [{"job": {"id": POST, "lease_token": PEER, "ai_reply_count": 5,
                                            "comment_id": OTHER, "title": "청구 질문", "body": "알려주세요"}}, {}, {}]
        with mock.patch.object(w, "find_sources", return_value=([], 0)), \
                mock.patch.object(w, "generate", return_value=answer(classification="question", web_sources=[{"발췌": "PRIVATE_WEB"}])):
            self.assertTrue(w.process_one(backend))
        action, payload = backend.rpc.call_args.args
        self.assertEqual(action, "complete")
        self.assertNotIn("web_sources", payload)
        self.assertNotIn("PRIVATE_WEB", json.dumps(payload))

    def test_model_skip_completes_with_skip_not_fail(self):
        backend = mock.Mock()
        backend.rpc.side_effect = [{"job": {"id": POST, "lease_token": PEER, "title": "의미 검토", "body": "본문"}}, {}, {}]
        with mock.patch.object(w, "find_sources", return_value=([], 0)), \
                mock.patch.object(w, "generate", return_value={"classification": "skip"}):
            self.assertTrue(w.process_one(backend))
        self.assertEqual(backend.rpc.call_args.args[0], "skip")

    def test_batch_multiple_jobs_bounded_by_time_and_max_count(self):
        with mock.patch.object(w, "process_one", side_effect=[True, True, False]) as process, \
                mock.patch.object(w.time, "monotonic", return_value=0):
            self.assertEqual(w.process_batch(mock.Mock(), 360), 2)
        self.assertEqual(process.call_count, 3)
        with mock.patch.object(w, "process_one") as process, mock.patch.object(w.time, "monotonic", return_value=230):
            self.assertEqual(w.process_batch(mock.Mock(), 360), 0)
        process.assert_not_called()

    def test_bad_job_does_not_block_next_question(self):
        with mock.patch.object(w, "process_one", side_effect=[w.WorkerError("subscription_invalid_answer"), True, False]) as process, \
                mock.patch.object(w.time, "monotonic", return_value=0):
            self.assertEqual(w.process_batch(mock.Mock(), 360), 1)
        self.assertEqual(process.call_count, 3)


if __name__ == "__main__":
    unittest.main()
