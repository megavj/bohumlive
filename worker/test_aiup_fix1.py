"""Actual-preview regressions using synthetic streams; no DB or live generation."""
import json
import unittest
from unittest import mock

import bohumlive_worker as w


def reply(body, style="general", web=()):
    return dict(body=body, classification="question", answer_type=style, web_sources=list(web),
                model=w.MODEL, effort=w.EFFORT, subscription=True, fallback_used=False)


class NumericEvidence(unittest.TestCase):
    def test_question_conversation_and_successful_web_are_known(self):
        self.assertEqual(w.answer_problem("통원치료비 25만 원의 서류를 정리하세요.", question="25만원 청구"), "")
        self.assertEqual(w.answer_problem("90일 조건을 다시 확인하세요.", conversation=[{"body": "90일 조건 문의"}]), "")
        self.assertEqual(w.answer_problem("기간은 30일입니다.", [{"종류": "웹", "발췌": "기간은 30일"}]), "")
        self.assertEqual(w.answer_problem("비율은 20%입니다.", [{"발췌": "비율 20퍼센트"}]), "")
        self.assertIn("금액", w.answer_problem("기간은 10일입니다.", question="210일인가요?"))

    def test_only_unknown_numeric_sentence_is_removed(self):
        body = "먼저 가입한 실손 계약을 확인하세요. 면책기간은 999일입니다.\n영수증과 진료비 세부내역서를 준비하세요.\n접수번호를 기록하고 추가 요청을 확인하세요."
        with mock.patch.object(w, "_generate_once", side_effect=[reply(body, "procedure"), reply(body, "procedure")]):
            result = w.generate({"title": "실손 청구", "body": "통원 25만원"})
        self.assertNotIn("999", result["body"])
        for text in ("실손 계약", "세부내역서", "접수번호"):
            self.assertIn(text, result["body"])
        self.assertEqual(result["removed_sentence_count"], 1)
        self.assertEqual(result["rewrite_reasons"], ["amount"])
        self.assertFalse(result["general_guidance_used"])

    def test_rewrite_failure_keeps_useful_first_answer(self):
        body = "청구할 계약과 진료 내역을 먼저 확인하세요.\n접수에는 999일이 걸립니다.\n접수 후 추가 서류 요청을 확인하세요."
        with mock.patch.object(w, "_generate_once", side_effect=[reply(body), w.WorkerError("subscription_timeout")]):
            result = w.generate({"title": "실손 청구", "body": "순서 문의"})
        self.assertTrue(result["rewrite_failed"])
        self.assertNotIn("999", result["body"])
        self.assertIn("진료 내역", result["body"])

    def test_clean_rewrite_outranks_longer_truncated_draft(self):
        first = "계약별 보장과 지급 조건을 구분하여 확인하세요. " * 30
        second = "상품별 보장 범위와 지급 조건을 나눠 확인하세요. 해당 계약의 제외 조건과 예외를 함께 대조하세요."
        with mock.patch.object(w, "_generate_once", side_effect=[reply(first), reply(second)]):
            result = w.generate({"title": "보장 조건", "body": "설명해 주세요"})
        self.assertEqual(result["body"], second)
        self.assertTrue(result["rewritten"])

    def test_prior_web_evidence_reaches_rewrite_and_final_validation(self):
        web = [{"종류": "웹", "발췌": "접수 기한은 30일"}]
        first = reply("자료가 없습니다. 기한은 30일입니다.", web=web)
        second = reply("접수 기한은 30일입니다. 계약의 적용 조건을 함께 확인하세요.")
        with mock.patch.object(w, "_generate_once", side_effect=[first, second]) as generate:
            result = w.generate({"title": "접수", "body": "기한 문의"})
        rewrite_job = generate.call_args_list[1].args[0]
        prompt = w.question_data(rewrite_job)
        self.assertIn("30일", prompt)
        self.assertIn("verified_web_results", prompt)
        self.assertIn("30일", result["body"])
        self.assertEqual(result["web_sources"], web)

    def test_rewrite_reasons_include_all_issues_from_both_attempts(self):
        with mock.patch.object(w, "_generate_once", side_effect=[reply("자료가 없습니다. 기간은 999일입니다."),
                                                                reply("접수에는 888일이 걸립니다.")]):
            result = w.generate({"title": "접수", "body": "기한 문의"})
        self.assertEqual(result["rewrite_reasons"], ["hedge", "amount"])
        self.assertEqual(result["rewrite_attempts"][1]["reasons"], ["amount"])

    def test_web_comparison_company_names_are_not_source_citations(self):
        sources = [{"종류": "웹", "발췌": "삼성화재, 현대해상 상품 비교 결과"}]
        self.assertEqual(w.source_problem("삼성화재: 보장 범위를 확인하세요.\n현대해상: 인수 조건을 대조하세요.",
                                         sources, "암보험 회사별 비교", "comparison"), "")


class UsefulAnswers(unittest.TestCase):
    def test_model_generated_referral_only_cannot_be_the_entire_answer(self):
        for body in ("상품과 적용 시점을 구체적으로 적어 동료 경험을 물어보세요. 개인을 알아볼 수 있는 정보는 제외해 주세요.",
                     "상품과 적용 시점을 구체적으로 적어 보상 채널 동료 경험을 물어보세요."):
            with mock.patch.object(w, "_generate_once", return_value=reply(body)):
                result = w.generate({"title": "실손 청구", "body": "순서", "channels": [{"name": "보상"}]})
            self.assertGreaterEqual(len(result["body"].splitlines()), 3)
            self.assertIn("영수증", result["body"])
            self.assertTrue(result["body"].endswith("보상 채널 동료 경험을 물어보세요."))

    def test_sentence_removal_never_leaves_an_empty_numbered_step(self):
        body = "1. 면책기간은 999일입니다.\n2. 영수증과 진료비 세부내역서를 준비하세요.\n3. 접수번호를 기록하세요."
        cleaned, _ = w.salvage_answer(body, [], "", [], "procedure")
        self.assertNotIn("1.", cleaned)
        self.assertIn("영수증", cleaned)

    def test_unrelated_short_script_is_not_replaced_with_cancellation_advice(self):
        with mock.patch.object(w, "_generate_once", return_value=reply("고객님, 실손 청구는 제가 도와드릴게요.", "script")):
            result = w.generate({"title": "실손 청구 안내 화법", "body": "병원 서류를 어려워하는 고객에게 어떻게 설명하나요?"})
        self.assertNotIn("해지", result["body"])
        self.assertNotIn("보험료", result["body"])
        self.assertTrue(w.script_complete(result["body"]))

    def test_source_sentence_does_not_erase_all_valid_guidance(self):
        body = "가상생명 상품요약서 내용대로 진행하세요.\n계약의 납입액과 해지환급금을 나란히 비교하세요.\n보증금액과 예시금액을 구분하세요."
        with mock.patch.object(w, "_generate_once", return_value=reply(body)):
            result = w.generate({"title": "종신 해지환급금", "body": "원금 문의"})
        self.assertNotIn("상품요약서", result["body"])
        self.assertIn("납입액과 해지환급금", result["body"])
        self.assertIn("source_named", result["rewrite_reasons"])
        self.assertFalse(result["general_guidance_used"])

    def test_nested_peer_comment_names_are_only_used_for_redaction(self):
        job = {"peer_sources": [{"post_id": "10000000-0000-0000-0000-000000000002", "comments": [
            {"nickname": "합성별명", "body": "합성별명이 알려줍니다."}]}]}
        self.assertNotIn("합성별명", w.question_data(job))

    def test_current_date_is_supplied_for_time_specific_rates(self):
        with mock.patch.object(w.time, "strftime", return_value="2026-11-11"):
            data = json.loads(w.question_data({"title": "이번달 수수료"}).split("\n", 1)[1])
        self.assertEqual(data["current_date"], "2026-11-11")
        self.assertIn("적용 월·조직·지급 대상이 일치", w.SYSTEM_PROMPT)

    def test_undated_or_old_rates_are_not_presented_as_this_month(self):
        job = {"title": "이번달 시책 어떤가요", "body": "손보사 수수료 높은 곳"}
        for basis in ("", "2026-09"):
            sources = [{"기준": basis, "발췌": "선지급 수수료 306.25%"}]
            with mock.patch.object(w.time, "strftime", return_value="2026-11"), \
                    mock.patch.object(w, "_generate_once", return_value=reply("이번 달 선지급 수수료는 306.25%입니다.", "comparison")):
                result = w.generate(job, sources=sources)
            self.assertTrue(result["time_scope_guarded"])
            self.assertNotIn("306.25", result["body"])
            self.assertIn("환수", result["body"])
            self.assertEqual(len(result["body"].splitlines()), 3)
        with mock.patch.object(w.time, "strftime", return_value="2026-11"):
            self.assertFalse(w.needs_current_commission_guard(job, [{"기준": "2026-11", "발췌": "시책 지급 조건"}]))

    def test_unsafe_only_answer_has_practical_lines_and_referral_last(self):
        with mock.patch.object(w, "_generate_once", return_value=reply("기간은 999일입니다.")):
            result = w.generate({"title": "실손 청구", "body": "순서", "channels": [{"name": "보상"}]})
        lines = result["body"].splitlines()
        self.assertEqual(len(lines), 4)
        self.assertIn("영수증", result["body"])
        self.assertEqual(lines[-1], "보상 채널 동료 경험을 물어보세요.")
        self.assertEqual(result["rewrite_reasons"], ["amount"])
        self.assertNotIn("999", result["body"])

    def test_existing_evidence_does_not_trigger_colleague_referral(self):
        with mock.patch.object(w, "_generate_once", return_value=reply("자료가 없습니다.")):
            result = w.generate({"title": "실손 청구", "body": "순서", "channels": [{"name": "보상"}]},
                                sources=[{"발췌": "청구 서류는 영수증과 진료 내용입니다."}])
        self.assertNotIn("채널", result["body"])
        self.assertGreaterEqual(len(result["body"].splitlines()), 2)

    def test_single_short_script_is_expanded_to_guidance_and_one_example(self):
        with mock.patch.object(w, "_generate_once", return_value=reply("고객님, 보험료가 부담되시는 건 충분히 이해합니다.", "script")):
            result = w.generate({"title": "보험료 부담 상담 화법", "body": "어떻게 말씀드릴까요"})
        self.assertTrue(w.script_complete(result["body"]))
        self.assertEqual(result["body"].count("예시:"), 1)
        self.assertGreater(len(result["body"]), 100)
        self.assertIn("length", result["rewrite_reasons"])

    def test_script_rejects_cut_off_quote_and_excess_guidance_lines(self):
        truncated = ('부담의 원인을 먼저 확인하세요.\n보장 조정 전후를 비교하세요.\n'
                     '예시: “고객님, 보험료가 부담되시는 마음을 이해합니다. 필요한 보장을 남길 방법을 함께 살펴볼까요?')
        self.assertFalse(w.script_complete(truncated))
        complete = truncated + '”'
        self.assertTrue(w.script_complete(complete))
        self.assertFalse(w.script_complete('추가 안내입니다.\n더 자세한 안내입니다.\n' + complete))
        with mock.patch.object(w, "_generate_once", return_value=reply(truncated, "script")):
            result = w.generate({"title": "보험료 부담 화법", "body": "어떻게 말씀드릴까요"})
        self.assertTrue(w.script_complete(result["body"]))
        self.assertTrue(result["body"].endswith('”'))

    def test_output_parser_preserves_real_preview_phrases(self):
        body = "기존 관련 보장을 일정 기간 유지한 고객이라면\n가벼운 고객은 병력이 있는 고객은\n확인할 고객의 기억과 수술 고객에게 맞는 조건을 봅니다."
        stream = json.dumps({"type": "result", "modelUsage": {w.MODEL: {}},
                             "result": json.dumps(reply(body))})
        self.assertEqual(w.parse_generation(stream)["body"], body)

    def test_web_metadata_empty_or_error_results_cannot_supply_numbers(self):
        events = [{"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "ok", "name": "WebSearch"}]}}]
        for content, error in (([{"type": "text", "text": "기간은 30일", "metadata": "999일"}], False),
                               ("", False), ("888일", True)):
            events.append({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "ok",
                                                                       "content": content, "is_error": error}]}})
        events.append({"type": "result", "modelUsage": {w.MODEL: {}}, "result": json.dumps(reply("계약을 확인하세요."))})
        sources = w.parse_generation("\n".join(map(json.dumps, events)))["web_sources"]
        self.assertEqual(sources, [{"종류": "웹", "발췌": "기간은 30일"}])


if __name__ == "__main__":
    unittest.main()
