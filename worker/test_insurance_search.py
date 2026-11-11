"""Read-only retrieval boundaries using invented insurance documents only."""
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.error
import urllib.parse

spec = importlib.util.spec_from_file_location("insurance_search", Path(__file__).with_name("insurance_search.py"))
searcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(searcher)


def hit(title="가상보험 실손 약관", text=None, **extra):
    return {"title": title, "document": text or "실손 청구 전에 가입 상품과 입원 여부를 확인하며 청구 서류의 제출 방법과 추가 서류 필요 여부를 안내합니다.",
            "metadata": {"path": "/보험자료/공통/" + title + ".pdf", "page_number": 12}, **extra}


class CustomerSourceBoundary(unittest.TestCase):
    def test_every_forbidden_marker_is_blocked_in_path_and_title(self):
        for marker in searcher.FORBIDDEN_SOURCE_MARKERS:
            for location in ("title", "path"):
                with self.subTest(marker=marker, location=location):
                    source = hit()
                    if location == "title":
                        source["title"] = marker + "_보험자료"
                    else:
                        source["metadata"]["path"] = "/보관/" + marker + "/약관.pdf"
                    self.assertFalse(searcher.allowed_source(source))

    def test_alternate_title_cannot_hide_customer_folder(self):
        source = hit()
        source["citation"] = {"document_title": "공개된 실손 약관"}
        source["metadata"]["path"] = "/원본자료/계약자/청구서.pdf"
        self.assertIsNone(searcher._normalise(source))

    def test_nested_percent_encoded_and_invisible_paths_are_blocked(self):
        for value in ("/문서/고\u200b객/자료.pdf", "/문서/고객/자료.pdf",
                      urllib.parse.quote(urllib.parse.quote("/계약자/자료.pdf")),
                      "/Documents/E_MAIL/report.pdf", "/문서/카 톡/자료.pdf"):
            with self.subTest(value=value):
                source = hit()
                source["metadata"]["source"] = {"alternate": [value]}
                self.assertFalse(searcher.allowed_source(source))

    def test_camel_case_path_fields_are_checked(self):
        source = hit()
        source["metadata"]["originalFilePath"] = "/customer/private.pdf"
        self.assertFalse(searcher.allowed_source(source))

    def test_customer_vocabulary_in_public_document_content_is_allowed(self):
        source = hit(text="실손 청구 절차를 설명할 때 고객에게 필요한 서류를 안내하며 계약자와 피보험자의 일반적인 의무를 확인합니다.")
        self.assertTrue(searcher.allowed_source(source))

    def test_public_section_headings_are_not_customer_provenance(self):
        source = hit()
        source["metadata"].update(section_title="계약자 및 피보험자의 의무", table_title="고객 안내사항")
        self.assertIsNotNone(searcher._normalise(source))
        source["metadata"]["path"] = "/계약자/개인청구.pdf"
        self.assertIsNone(searcher._normalise(source))

    def test_public_customer_teaching_title_keeps_private_folder_boundary(self):
        for title in ("고객 응대 화법 교육자료", "계약자 변경 안내 약관", "피보험자 범위 안내"):
            with self.subTest(title=title):
                source = hit(title=title)
                self.assertTrue(searcher.allowed_source(source))
                source["metadata"]["path"] = "/고객/" + title + ".pdf"
                self.assertFalse(searcher.allowed_source(source))
        for title in ("고객 청구내역", "계약자 계약목록", "고객 안내_고객진료기록"):
            self.assertFalse(searcher.allowed_source(hit(title=title)))

    def test_public_phrases_never_hide_individual_customer_filenames(self):
        titles = (
            "고객 안내_김철수", "김철수 고객 안내", "피보험자 변경_김철수",
            "고객 안내_김철수_교육자료", "고객 응대 화법 교육자료_김철수",
            "김철수_고객 응대 화법 교육자료", "계약자 변경 안내 약관_개인청구",
            "고객 응대 화법 교육자료<김철수>", "고객 응대 화법 교육자료_01012345678",
        )
        for title in titles:
            with self.subTest(title=title):
                source = hit(title=title)
                self.assertFalse(searcher.allowed_source(source))
                self.assertIsNone(searcher._normalise(source))
                # A harmless alternative title must not conceal the original path.
                source["title"] = "공개 보험 교육자료"
                source["metadata"]["path"] = urllib.parse.quote("/보험자료/" + title + ".pdf")
                self.assertIsNone(searcher._normalise(source))

    def test_folder_and_directory_fields_never_get_public_title_exception(self):
        for field in ("folder", "directory", "originalFolder", "sourceDirectory"):
            for value in ("고객 안내", "계약자 변경", "고객 응대 화법 교육자료", "피보험자 범위 안내.pdf"):
                with self.subTest(field=field, value=value):
                    source = hit()
                    source["metadata"][field] = value
                    self.assertIsNone(searcher._normalise(source))
                    source["metadata"][field] = {"title": value}
                    self.assertIsNone(searcher._normalise(source))

    def test_directory_paths_and_source_categories_do_not_get_title_exception(self):
        for field in ("path", "source_path", "category", "collection", "channel"):
            source = hit()
            source["metadata"][field] = "고객 응대 화법 교육자료"
            with self.subTest(field=field):
                self.assertIsNone(searcher._normalise(source))
            if field in {"category", "collection", "channel"}:
                source["metadata"][field] = {"title": "고객 응대 화법 교육자료"}
                self.assertIsNone(searcher._normalise(source))
        source = hit()
        source["metadata"]["path"] = "/보험자료/고객 응대 화법 교육자료/실손약관.pdf"
        self.assertIsNone(searcher._normalise(source))

    def test_literal_markup_does_not_hide_customer_metadata(self):
        for marker in ("<고객>", "&lt;고객&gt;", "<계약자>", "<customer>"):
            source = hit()
            source["metadata"]["path"] = "/보험자료/" + marker + "/보험자료.pdf"
            with self.subTest(marker=marker):
                self.assertIsNone(searcher._normalise(source))

    def test_all_requested_document_types_are_eligible(self):
        for kind in ("약관", "상품요약서", "사업방법서", "사내교육자료", "소식지", "수수료표", "시책자료"):
            with self.subTest(kind=kind):
                source = searcher._normalise(hit(title="가상보험 실손 " + kind))
                self.assertIsNotNone(source)
                self.assertEqual(source["종류"], kind)

    def test_declared_training_kind_takes_precedence_over_title_terms(self):
        source = searcher._normalise(hit(title="실손 약관 해설", doc_type="사내교육자료"))
        self.assertEqual(source["종류"], "사내교육자료")

    def test_unknown_kind_uses_fixed_category_without_restricting_sources(self):
        source = searcher._normalise(hit(title="실손 청구 안내", doc_type="UNTRUSTED_KIND"))
        self.assertEqual(source["종류"], "보험자료")


class ProductAndQueryResolution(unittest.TestCase):
    CATALOG = (
        ("NH농협손해보험", "무배당 아이맘헤아림어린이보험", "2025-01"),
        ("NH농협손해보험", "무배당 아이맘헤아림어린이보험", "2026-10"),
        ("NH농협손해보험", "가상어린이보험", "2026-01"),
        ("NH농협손해보험", "실손의료비보험", "2026-01"),
        ("가상생명", "튼튼어린이보험", "2026-01"),
    )

    def test_actual_product_name_resolution_and_no_duplicate_editions(self):
        with mock.patch.object(searcher, "product_catalog", return_value=self.CATALOG):
            insurer, products = searcher.resolve_products("농협손보 어린이보험 주요내용요약")
        self.assertEqual(insurer, "NH농협손해보험")
        self.assertEqual(len(products), 2)
        self.assertIn("무배당 아이맘헤아림어린이보험", products)
        self.assertNotIn("실손의료비보험", products)

    def test_exact_product_outranks_other_product_categories(self):
        with mock.patch.object(searcher, "product_catalog", return_value=self.CATALOG):
            _, products = searcher.resolve_products("농협손보 아이맘헤아림어린이보험 요약")
        self.assertEqual(products, ["무배당 아이맘헤아림어린이보험"])

    def test_company_name_does_not_trigger_fire_product_resolution(self):
        catalog = (("삼성화재", "가상주택화재보험", "2026-01"), ("삼성화재", "가상어린이보험", "2026-01"))
        with mock.patch.object(searcher, "product_catalog", return_value=catalog):
            _, products = searcher.resolve_products("삼성화재 어린이보험")
        self.assertEqual(products, ["가상어린이보험"])

    def test_synonyms_and_joined_occupation_change(self):
        queries = searcher.search_queries("메리츠 직업변경시 절차 알려주세요")
        self.assertIn("메리츠 직업 변경 배서", queries)
        queries = searcher.search_queries("실비 진단금 입원비 수술금 유병자 간병비 당뇨 치매 뇌졸중")
        for term in ("실손", "진단비", "입원일당", "수술비", "간편고지", "간병인", "당뇨병", "치매진단", "뇌혈관질환"):
            self.assertIn(term, queries[-1])

    def test_missing_catalog_creates_no_database(self):
        with tempfile.TemporaryDirectory() as directory:
            missing_db = Path(directory) / "absent.sqlite3"
            searcher.product_catalog.cache_clear()
            with mock.patch.object(searcher, "PRODUCT_CATALOG_JSON", Path(directory) / "absent.json"), \
                    mock.patch("sqlite3.connect", side_effect=AssertionError("SQLite must not be opened")):
                self.assertEqual(searcher.product_catalog(), ())
            self.assertFalse(missing_db.exists())
        searcher.product_catalog.cache_clear()

    def test_json_catalog_is_usable_without_sqlite(self):
        with tempfile.TemporaryDirectory() as directory:
            catalog = Path(directory) / "catalog.json"
            catalog.write_text(json.dumps(self.CATALOG), encoding="utf-8")
            searcher.product_catalog.cache_clear()
            with mock.patch.object(searcher, "PRODUCT_CATALOG_JSON", catalog), \
                    mock.patch("sqlite3.connect", side_effect=AssertionError("SQLite must not be opened")):
                self.assertEqual(searcher.product_catalog(), self.CATALOG)
        searcher.product_catalog.cache_clear()

    def test_conversational_customer_details_do_not_dominate_first_query(self):
        cases = (
            ("암보험 어디가 나아요 50대 남성 고객 암보험 추천하려는데 회사별로 어떤 차이가 있나요?", ("암보험", "진단비")),
            ("고객이 통원치료비 25만원 나왔는데 실손 청구 어떻게 해야 하나요? 서류랑 순서 알려주세요.", ("실손", "통원", "청구서류")),
            ("고혈압 약 3년째 먹는 60세 고객, 간편고지로 가입하려면 뭘 확인해야 하나요?", ("고혈압", "간편고지", "알릴 의무")),
            ("고객이 보험료가 비싸다고 해지하겠다는데 어떻게 말씀드리면 좋을까요?", ("보험료", "해지", "계약유지")),
            ("이번 달 손보사 시책이나 수수료 높은 곳 어디인가요?", ("시책", "수수료")),
            ("강아지 슬개골 탈구 수술 펫보험에서 보장되나요?", ("펫보험", "슬개골 탈구")),
        )
        for question, terms in cases:
            with self.subTest(question=question):
                first = searcher.search_queries(question)[0]
                for term in terms:
                    self.assertIn(term, first)
                self.assertNotIn("고객", first)
                self.assertNotIn("어떻게", first)

    def test_malformed_catalog_rows_do_not_enter_queries(self):
        with tempfile.TemporaryDirectory() as directory:
            catalog = Path(directory) / "catalog.json"
            catalog.write_text(json.dumps([list(self.CATALOG[0]), ["wrong"], [1, 2, 3],
                                          ["고객", "보험", "2026"]]), encoding="utf-8")
            searcher.product_catalog.cache_clear()
            with mock.patch.object(searcher, "PRODUCT_CATALOG_JSON", catalog):
                self.assertEqual(searcher.product_catalog(), (self.CATALOG[0],))
        searcher.product_catalog.cache_clear()


class SearchEvidence(unittest.TestCase):
    def setUp(self):
        self.catalog = mock.patch.object(searcher, "product_catalog", return_value=())
        self.catalog.start()
        self.addCleanup(self.catalog.stop)

    def test_at_most_eight_excerpts_and_only_allowlisted_fields(self):
        raw = [hit(title=f"실손 청구 자료 {n}", text=f"실손 청구 자료 {n}번은 제출서류의 종류와 계약 확인 순서를 설명합니다. 입원과 통원 구분을 안내할 수 있습니다.",
                   author="DO_NOT_TRANSMIT", nickname="DO_NOT_TRANSMIT", company="DO_NOT_TRANSMIT", url="https://example.invalid/private")
               for n in range(12)]
        with mock.patch.object(searcher, "_request", return_value=raw):
            result = searcher.search("실손 청구", limit=99)
        self.assertEqual(len(result), 8)
        self.assertTrue(all(set(item) == {"자료", "보험사", "상품", "종류", "기준", "쪽", "발췌"} for item in result))
        self.assertNotIn("DO_NOT_TRANSMIT", json.dumps(result))
        self.assertNotIn("example.invalid", json.dumps(result))
        self.assertNotIn("/보험자료/", json.dumps(result, ensure_ascii=False))

    def test_search_removes_unsafe_documents_before_scoring(self):
        bad = hit(title="실손 청구 고객 기록")
        with mock.patch.object(searcher, "_request", return_value=[bad, hit()]):
            result = searcher.search("실손 청구")
        self.assertEqual(len(result), 1)
        self.assertNotIn("고객", result[0]["자료"])

    def test_deduplicates_content_but_keeps_distinct_chunks_on_same_page(self):
        first = hit()
        second = hit(text="실손 청구 시 진료 내용에 따른 추가 확인 절차를 설명합니다. 통원 자료와 입원 자료를 구분해 제출하도록 안내합니다.")
        with mock.patch.object(searcher, "_request", return_value=[first, first, second]):
            result = searcher.search("실손 청구")
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]["쪽"], result[1]["쪽"])

    def test_supplemental_failure_preserves_prior_evidence(self):
        with mock.patch.object(searcher, "_request", side_effect=[[hit()], TimeoutError("fixture"), TimeoutError("fixture")]):
            result = searcher.search("실손 청구 알려주세요")
        self.assertEqual(len(result), 1)

    def test_all_search_failures_return_empty_without_logging(self):
        output = io.StringIO()
        with mock.patch.object(searcher, "_request", side_effect=urllib.error.URLError("DO_NOT_LOG")), \
                mock.patch("sys.stdout", output), mock.patch("sys.stderr", output):
            self.assertEqual(searcher.search("실손 청구 알려주세요"), [])
        self.assertEqual(output.getvalue(), "")

    def test_deadline_prevents_more_requests(self):
        with mock.patch.object(searcher.time, "monotonic", side_effect=[0, 1, searcher.SEARCH_SECONDS + 1]), \
                mock.patch.object(searcher, "_request", return_value=[hit()]) as request:
            result = searcher.search("실손 청구 알려주세요")
        self.assertEqual(request.call_count, 1)
        self.assertEqual(len(result), 1)
        self.assertLessEqual(request.call_args.args[1], searcher.REQUEST_SECONDS)

    def test_loaded_search_gets_enough_time_and_stops_when_evidence_is_full(self):
        raw = [hit(title=f"실손 청구 안내 {n}", text=f"실손 청구 서류 {n}번의 제출 절차와 접수 안내를 확인합니다. 통원과 입원 구분에 따라 필요한 서류를 제출합니다.")
               for n in range(8)]

        def loaded_search(query, timeout):
            if timeout <= 6:
                raise TimeoutError("old concurrent request budget")
            return raw

        with mock.patch.object(searcher, "_request", side_effect=loaded_search) as request:
            result = searcher.search("실손 청구", "고객의 통원치료 청구 서류랑 순서 알려주세요")
        self.assertEqual(len(result), 8)
        self.assertEqual(request.call_count, 1)

    def test_comparison_does_not_discard_second_company_documents(self):
        catalog = (("메리츠화재", "간편건강보험", "2026"), ("현대해상", "간편건강보험", "2026"))
        raw = [hit(title="현대해상 간편고지 약관", text="간편고지 건강보험의 가입 조건과 보장 내용을 확인합니다. 계약 전 알릴 의무에 해당하는 질병을 확인합니다.")]
        with mock.patch.object(searcher, "product_catalog", return_value=catalog), \
                mock.patch.object(searcher, "_request", return_value=raw) as request:
            result = searcher.search("메리츠 vs 현대해상 간편보험 비교")
        self.assertEqual(len(result), 1)
        self.assertIn("현대해상", request.call_args_list[0].args[0])
        self.assertIn("메리츠화재", request.call_args_list[0].args[0])

    def test_empty_question_and_zero_limit_do_not_search(self):
        with mock.patch.object(searcher, "_request") as request:
            self.assertEqual(searcher.search(""), [])
            self.assertEqual(searcher.search("실손 청구", limit=0), [])
        request.assert_not_called()

    def test_excerpt_targets_relevant_passage(self):
        text = "다른 내용의 일반적인 설명입니다. " * 180 + "실손 청구 제출서류 핵심 설명입니다. " * 40
        result = searcher.excerpt(text, ["실손", "청구", "제출서류"])
        self.assertIn("제출서류", result)
        self.assertLessEqual(len(result), searcher.EXCERPT_CHARS)

    def test_unrelated_result_does_not_become_evidence(self):
        unrelated = hit(title="연금 소식지", text="연금보험의 장기적인 유지와 관련한 일반적인 교육 내용입니다. 납입 기간과 연금 지급 방식을 차례로 설명합니다.")
        with mock.patch.object(searcher, "_request", return_value=[unrelated]):
            self.assertEqual(searcher.search("실손 청구"), [])

    def test_redirects_are_rejected(self):
        request = searcher.urllib.request.Request(searcher.SEARCH_URL)
        with self.assertRaises(urllib.error.URLError):
            searcher._NoRedirect().redirect_request(request, None, 302, "redirect", {}, "https://example.invalid")


if __name__ == "__main__":
    unittest.main()
