"""Synthetic tests for the proof auto-check rules (fake names and numbers only)."""

import unittest

import proof_check as pc

COMPANIES = [{"id": "c-incar", "name": "인카금융서비스"}, {"id": "c-prime", "name": "프라임에셋"},
             {"id": "c-samsung", "name": "삼성생명"}]


def line(text, x, y, w=0.08, h=0.03, conf=1.0):
    return {"text": text, "x": x, "y": y, "w": w, "h": h, "conf": conf}


def table(name, number, company):
    """Label column on the left, value column on the right (e클린 기본정보 모양)."""
    return {"lines": [
        line("모집종사자 본인정보 조회", 0.03, 0.10, 0.2),
        line("성명", 0.04, 0.30, 0.03), line(name, 0.21, 0.30, 0.05),
        line("설계사 고유번호", 0.04, 0.37, 0.09), line(number, 0.21, 0.37, 0.1),
        line("현재 소속회사", 0.04, 0.44, 0.08), line(company, 0.21, 0.44, 0.1),
        line("조회일시 2026-11-09 10:12:30", 0.03, 0.60, 0.3),
    ]}


APPLICANT = {"name": "김가짜", "registration_number": "12345678901234", "company_name": "인카금융서비스",
             "company_id": "c-incar"}


class ProofCheckTest(unittest.TestCase):
    def test_all_match_approves(self):
        r = pc.judge(table("김가짜", "12345678901234", "인카금융서비스(주)"), APPLICANT, COMPANIES)
        self.assertEqual(r["decision"], "approve")
        self.assertEqual(r["company_id"], "c-incar")

    def test_masks_read_values(self):
        r = pc.judge(table("김가짜", "12345678901234", "인카금융서비스(주)"), APPLICANT, COMPANIES)
        self.assertEqual(r["read"]["name"], "김**")
        self.assertEqual(r["read"]["number_last4"], "1234")
        self.assertNotIn("12345678901234", str(r))

    def test_clear_name_difference_rejects(self):
        r = pc.judge(table("이다른", "12345678901234", "인카금융서비스"), APPLICANT, COMPANIES)
        self.assertEqual((r["decision"], r["reasons"]), ("reject", ["name"]))

    def test_one_letter_name_difference_is_held(self):
        r = pc.judge(table("김가자", "12345678901234", "인카금융서비스"), APPLICANT, COMPANIES)
        self.assertEqual(r["decision"], "hold")

    def test_number_difference_rejects_but_one_digit_holds(self):
        self.assertEqual(pc.judge(table("김가짜", "98765432109876", "인카금융서비스"), APPLICANT, COMPANIES)["reasons"], ["number"])
        self.assertEqual(pc.judge(table("김가짜", "12345678901235", "인카금융서비스"), APPLICANT, COMPANIES)["decision"], "hold")

    def test_spaced_or_hyphenated_number_matches(self):
        r = pc.judge(table("김가짜", "1234-5678-901234", "인카금융서비스"), APPLICANT, COMPANIES)
        self.assertEqual(r["decision"], "approve")

    def test_datetime_is_not_taken_as_agent_id(self):
        ocr = {"lines": [l for l in table("김가짜", "", "인카금융서비스")["lines"] if l["text"]]}
        self.assertEqual(pc.check_number(ocr["lines"], "12345678901234")[0], "unknown")

    def test_company_aliases(self):
        for read, applied in [("INCAR 금융서비스 주식회사", "인카"), ("㈜인카금융서비스", "INCAR"),
                              ("프라임에셋주식회사", "프라임"), ("프라임 주식회사", "프라임에셋"),
                              ("(주)에이플러스에셋어드바이저", "에이플러스에셋")]:
            self.assertTrue(pc.same_company(read, applied), (read, applied))
        self.assertFalse(pc.same_company("삼성생명보험(주)", "인카금융서비스"))
        self.assertFalse(pc.same_company("ARKO", "INCAR"))

    def test_custom_company_is_linked_to_existing_list(self):
        app = dict(APPLICANT, company_name="인카", company_id=None)
        r = pc.judge(table("김가짜", "12345678901234", "INCAR 금융서비스"), app, COMPANIES)
        self.assertEqual((r["decision"], r["company_id"]), ("approve", "c-incar"))

    def test_known_different_company_rejects(self):
        r = pc.judge(table("김가짜", "12345678901234", "삼성생명보험(주)"), APPLICANT, COMPANIES)
        self.assertEqual((r["decision"], r["reasons"]), ("reject", ["company"]))

    def test_unlisted_company_is_held_not_created(self):
        app = dict(APPLICANT, company_name="보라에셋파트너스", company_id=None)
        r = pc.judge(table("김가짜", "12345678901234", "보라에셋파트너스"), app, COMPANIES)
        self.assertEqual((r["decision"], r["reasons"], r["company_id"]), ("hold", ["company_not_in_list"], None))

    def test_unreadable_photo_is_held(self):
        r = pc.judge({"lines": []}, APPLICANT, COMPANIES)
        self.assertEqual((r["decision"], r["reasons"]), ("hold", ["unreadable"]))

    def test_header_row_layout(self):
        ocr = {"lines": [line("성명", 0.04, 0.23), line("소속회사", 0.41, 0.23), line("등록번호", 0.60, 0.23),
                         line("김가짜", 0.04, 0.30), line("인카금융서비스", 0.41, 0.30, 0.12),
                         line("12345678901234", 0.60, 0.30, 0.12)]}
        self.assertEqual(pc.judge(ocr, APPLICANT, COMPANIES)["decision"], "approve")


if __name__ == "__main__":
    unittest.main()
