"""TASK-AIUP-FIX1 privacy regressions; all identifiers are synthetic."""

import unittest

from privacy import redact, redact_output


class InputPrivacy(unittest.TestCase):
    def test_real_preview_phrases_remain_unchanged(self):
        for value in (
            "기존 관련 보장을 일정 기간 유지한 고객이라면",
            "가벼운 고객은",
            "병력이 있는 고객은",
            "고객은 특히 확인",
            "확인할 고객의 기억",
            "고객에게 맞는",
            "수술 고객에게",
            "우선 고객님이 확인합니다.",
            "메모에는 고객님이 확인합니다.",
            "고객님이 확인하고 설계사님께 설명합니다. 계약자님과 피보험자님도 함께합니다.",
        ):
            with self.subTest(value=value):
                self.assertEqual(redact(value), value)
                self.assertEqual(redact_output(value), value)

    def test_adnominal_phrases_before_customer_roles_are_never_name_guesses(self):
        for modifier in ("유지한", "가벼운", "있는", "확인할", "결정한", "이해한", "강한", "고른",
                         "선택한", "손해본", "이사한", "전환한", "검사받는", "서두르는", "남은"):
            for role in ("고객", "고객님", "계약자", "설계사"):
                value = f"{modifier} {role}에게 먼저 확인합니다."
                with self.subTest(value=value):
                    self.assertEqual(redact(value), value)

    def test_input_names_require_exact_values_or_narrow_honorific_context(self):
        for name in ("홍길동", "김철수", "김하은", "김가을", "최다이", "한별", "남궁민수", "제갈민수"):
            for suffix in ("님", " 씨"):
                with self.subTest(name=name, suffix=suffix):
                    self.assertEqual(redact(name + suffix + "이 확인했습니다."), "[인명 삭제]이 확인했습니다.")
            for role in ("고객", "계약자", "설계사", "고객님", "팀장님"):
                with self.subTest(name=name, role=role):
                    self.assertEqual(redact(f"{name} {role}이 확인했습니다.", known_names=[name]),
                                     "[인명 삭제]이 확인했습니다.")

    def test_unlabelled_role_is_not_sufficient_to_infer_a_name(self):
        self.assertEqual(redact("김정보 설계사와 김자료 계약자가 확인합니다."),
                         "김정보 설계사와 김자료 계약자가 확인합니다.")

    def test_role_and_family_honorifics_remain_generic(self):
        value = "선배님과 원장님께 문의하고 고객의 이모님과 어머님께 안내합니다."
        self.assertEqual(redact(value), value)

    def test_family_medical_and_customer_demographic_roles_are_not_names(self):
        for value in ("배우자님과 주치의님께 먼저 문의하세요.", "임산부님께 설명합니다."):
            with self.subTest(value=value):
                self.assertEqual(redact(value), value)
                self.assertEqual(redact_output(value), value)

    def test_exact_names_and_nicknames_are_normalized_and_not_regexes(self):
        value = "<b>김\u200b하은</b> 고객님과 꽃.별님이 확인했습니다. 꽃과별은 남습니다."
        result = redact(value, known_names=["김하은", "꽃.별"])
        self.assertEqual(result, "[인명 삭제]과 [인명 삭제]이 확인했습니다. 꽃과별은 남습니다.")
        self.assertEqual(redact("보라왕님이 확인했습니다.", known_names="보라왕"), "[인명 삭제]이 확인했습니다.")

    def test_input_explicit_name_labels_are_private(self):
        self.assertEqual(redact("이름: 홍길동, 닉네임: 보라왕"), "[개인정보 삭제], [개인정보 삭제]")

    def test_insurance_conditions_with_si_are_not_names(self):
        for value in ("전환 시 비교하세요.", "가입시 확인하세요.", "강한 고객님께 확인합니다.",
                      "임신 시 검토합니다.", "당시 고객이 확인했습니다.", "날씨가 좋습니다."):
            with self.subTest(value=value):
                self.assertEqual(redact(value), value)


class OutputPrivacy(unittest.TestCase):
    def test_output_never_uses_name_heuristics(self):
        value = "김철수님과 남궁민수 씨가 확인했습니다. 이름: 보라왕"
        self.assertEqual(redact_output(value), value)

    def test_direct_identifiers_still_removed_on_both_boundaries(self):
        identifiers = (
            "010-1234-5678", "０１０-１２３４-５６７８", "010\u200b12345678",
            "<b>900101</b>-<i>1234567</i>", "9001011234567",
            "test@example.invalid", "https://example.invalid/private", "www.example.invalid/a",
            "계좌: 110-123-123456", "등록번호: 12345678", "증권번호: 12345678", "계약번호: 12345678",
            "서울특별시 강남구 테헤란로 123", "경기도 성남구 분당동 123-4",
        )
        for identifier in identifiers:
            for cleaner in (redact, redact_output):
                with self.subTest(identifier=identifier, cleaner=cleaner.__name__):
                    self.assertEqual(cleaner(identifier), "[개인정보 삭제]")

    def test_numeric_insurance_information_is_not_a_direct_identifier(self):
        value = "25만원을 청구합니다. 3세대와 4세대 실손, 90일과 20%를 비교합니다."
        self.assertEqual(redact_output(value), value)

    def test_empty_inputs_are_safe(self):
        for value in (None, "", "  "):
            self.assertEqual(redact(value), "")
            self.assertEqual(redact_output(value), "")


if __name__ == "__main__":
    unittest.main()
