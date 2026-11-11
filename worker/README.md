# 보험라이브 Mac 처리기

기존 AskQueue 스크립트, 기존 예약 작업, LaunchAgent를 변경하지 않는 독립 처리기입니다. Python 표준 라이브러리만 사용합니다. GitHub Pages에서 실행되지 않으며 Mac이 켜져 있어야 합니다.

## 실행과 재시작

서비스 키는 macOS 로그인 Keychain의 서비스 `bohumlive-service-role`에 저장합니다. 대안은 프로세스 환경 `BL_SERVICE_ROLE_KEY`이며 파일·명령 인자·Git에 기록하지 않습니다. Claude는 기존 Keychain 서비스 `timcook-claude-oauth-token`만 사용하며 API 키나 유료 API로 전환하지 않습니다.

```sh
/usr/bin/python3 /Volumes/MacWorkSSD/timcook/bohumlive/worker/bohumlive_worker.py --preview "청구 절차" "진단비 청구를 어떤 순서로 안내하나요?"
/usr/bin/python3 /Volumes/MacWorkSSD/timcook/bohumlive/worker/bohumlive_worker.py --dry-run
/usr/bin/python3 /Volumes/MacWorkSSD/timcook/bohumlive/worker/bohumlive_worker.py --once
/usr/bin/python3 /Volumes/MacWorkSSD/timcook/bohumlive/worker/bohumlive_worker.py --maintenance-only
```

`--dry-run`은 DB 상태와 인증 수단의 존재만 확인하며 질문을 가져오거나 생성·삭제하지 않습니다. `--once`는 증빙 정리·자동 판정 후 실행 시작 기준 360초 예산 안에서 최대 8건을 시도합니다. 다음 작업에는 검색·생성·완료 여유 175초를 확보하며, 개별 생성 실패를 기록한 뒤 다음 작업을 계속합니다. 모델 작성은 건당 110초 예산이고 실제 시간은 네트워크·종료 정리만큼 소폭 늘어날 수 있습니다. 재시작은 같은 `--once` 명령을 다시 실행하면 됩니다. 중복 프로세스는 전용 파일 잠금으로 종료하며 서버에서도 lease token으로 중복 생성을 차단합니다. Mac 종료/네트워크 오류 이후에는 서버 lease 만료 뒤 다시 처리됩니다. 로그에는 질문, 답변, 회원/게시글 ID, 경로, 키, CLI 오류 본문을 기록하지 않습니다.

## 팀쿡이 등록할 예약 작업

다음은 **아직 등록하지 않은** crontab 행입니다. Mac 로그인 사용자 `megavj`의 크론에 등록합니다. Keychain 잠금 해제 상태와 `/Volumes/MacWorkSSD` 연결이 필요합니다. 경로를 바꾸지 않았다면 아래 행 그대로 사용합니다.

```cron
*/2 * * * * /usr/bin/python3 /Volumes/MacWorkSSD/timcook/bohumlive/worker/bohumlive_worker.py --once >/dev/null 2>&1
```

AI를 끈 상태에서도 같은 작업은 증빙 정리를 수행합니다. 비식별 상태 로그를 보려면 수동 `--once`를 실행합니다. 기본 프로젝트는 보험라이브 전용 `behqpqucmnehzinssnxr`입니다. 다른 보험라이브 전용 프로젝트로 이전한 경우에만 `BL_SUPABASE_URL=https://프로젝트ID.supabase.co`를 지정하고 해당 프로젝트의 서비스 키로 바꿉니다.

## 생성과 개인정보 경계

- **새 처리기는 DB 026 적용 뒤 운영 실행합니다.** 화면은 026 이전에도 작동하지만 새 처리기의 `skip`과 후속 맥락은 026 계약입니다. 적용·복구 절차는 `db/CONTRACT.md`와 작업 보고서에 있습니다.
- `bl_worker`는 service_role 전용입니다. 서버 AI 스위치·재시도 한도·lease token은 유지합니다. 글당 첫 답변 포함 AI 댓글 5개를 예약 작업까지 합쳐 잠금으로 제한합니다. 관리자 재생성은 기존 댓글 ID를 유지합니다. 숨김·삭제된 AI도 총량에 포함합니다.
- `claude-opus-5-5`, effort `medium`, 기존 Keychain 구독 OAuth만 사용합니다. `WebSearch,WebFetch`만 허용하고 `--max-turns 8`, safe mode, 빈 MCP, 설정 파일 미사용, 세션 저장 없음으로 실행합니다. 실제 사용 모델에 Opus 5.5가 있어야 하고 보조 모델도 모두 `claude-*`여야 합니다. API 키·서비스 키·프록시는 자식 프로세스에 전달하지 않습니다.
- `insurance_search.py`는 5111 검색만 요청합니다. AskQueue의 `~/Library/Application Support/AskQueue/product-catalog.json`만 읽고 상품목록 SQLite는 열지 않습니다. 보험 용어·구어 동의어·실제 상품명으로 검색하며 최대 8개 발췌를 확보하면 일찍 종료합니다. 5111 요청당 20초·총 45초 예산이며, 검색 실패 시 기존 작은 `kb_search`(6초)를 보조로 씁니다.
- 고객·계약자·카톡·메일·보험노트 등 원본 제목/경로 표시는 `FORBIDDEN_SOURCE_MARKERS`로 차단합니다. 전체 제목이 정형 일반 교육·안내 제목에 일치하는 경우와 본문 소제목은 허용하지만, 개인명이 섞인 제목과 고객 폴더·분류는 계속 차단합니다. 검색 경로·URL은 모델에 전달하지 않습니다. 고객 파일·메일·카톡·증빙은 AI 자료로 읽지 않습니다.
- DB가 알려진 작성자 이름·닉네임·소속·연락처를 본문에서 지우고, `privacy.redact`는 명시된 이름 목록과 좁은 성씨+님/씨 규칙, 형식 기반 개인정보를 추가 제거합니다. 고객·계약자 앞 일반 단어를 이름으로 추정하지 않습니다. 모델 출력에는 `redact_output`의 전화·이메일·식별번호·계좌·주소·URL 형식 제거만 적용합니다. 계정/작성자 객체는 전달하지 않습니다. 자유서술 개인정보를 정규식으로 완전히 식별할 수는 없습니다.
- 동료 자료는 공개된 일반 채널의 non-test/non-sample/non-anonymous 글·사람 댓글만 사용합니다. 현재 글과 다른 글의 채택 답변을 우선 참고하되 공식 자료와 충돌하면 공식 자료가 우선입니다.
- 질문/정보 요청, 잡담·하소연, 의미 없는 글을 분류합니다. 의미 없는 글은 오류 없이 `skip`으로 종료합니다. 비교는 최대 700자, 절차는 순서대로, 상담 화법은 상황 판단·대응 포인트 2~3줄 + 바로 쓸 예시 한 덩어리(2~3문장), 일반 답은 대략 250~450자입니다.
- 출처 이름·쪽수·URL·인용번호·못 찾음 문구를 후처리로 제거합니다. 숫자는 보험 발췌·질문·이전 대화·성공한 실제 웹 도구 텍스트와 대조하고, 재작성에도 첫 웹 근거를 유지합니다. 미지원 숫자 문장만 제거해 유효한 내용을 보존합니다. 남은 답이 부족하면 질문에 맞는 실무 안내를 먼저 제공하며, 근거도 없을 때만 DB의 실제 채널을 마지막 한 줄로 연결합니다.
- 이번 달 시책·수수료 질문에는 현재 날짜를 전달하고 적용 월·조직·대상이 맞을 때만 수치를 비교하도록 지시합니다. 현재 연월을 확인할 근거가 없으면 오래되거나 날짜 없는 요율 대신 지급·유지·환수 조건 비교 안내를 제공합니다(`time_scope_guarded=true`).
- 답변은 사전 검수 없이 AI 댓글로 공개되며 화면의 **AI 답변은 참고만 하세요**를 유지합니다. 관련 동료 글은 본문 밖에서 UUID로 만든 동일 사이트 링크 최대 2개만 표시합니다.
- 잠금과 10초 단위 heartbeat를 유지합니다. 실패 로그는 고정 오류 코드와 수치만 기록하며 질문·답변·회원 ID·자료 제목·경로·CLI 응답은 로그에 남기지 않습니다.

## DB 없는 미리보기

```sh
python3 worker/bohumlive_worker.py --preview "회사별 실손 비교" "삼성화재와 현대해상 상담에서 비교할 항목은?"
```

분류, 답변 유형, 제공한 보험자료 수·종류별 수, 성공한 웹 도구 결과 수, 최종 본문을 JSON으로 출력합니다. `rewrite_reasons`는 최초/재작성에서 감지한 `hedge/amount/source_named/length`, `rewrite_attempts`는 단계별 사유를 보여줍니다. `rewritten`, `rewrite_failed`, `removed_sentence_count`, `general_guidance_used`도 확인할 수 있습니다. 자료 수는 입력으로 제공된 발췌 수이며 모델의 실제 인용 여부를 뜻하지 않습니다. 미리보기는 Backend·DB 서비스 키·job claim·정리·증빙·잠금 상태 폴더를 사용하지 않습니다. 실제 구독 CLI와 5111 검색은 사용합니다. DB를 읽지 않으므로 동료 자료와 실시간 채널 목록은 없고 `community=0`입니다. 실제 채널 연결·후속 맥락·채택 우선순위는 mock 테스트와 운영자 DB 적용 후 검증에서 확인합니다.

## 증빙 보존과 삭제

`bl-proofs` 전용 private bucket의 서버가 지정한 UUID 파일만 삭제합니다. 승인/반려 등 심사 처리 뒤 30일이 지난 증빙과 탈퇴 증빙을 Storage API로 제거한 다음 DB에 완료를 알립니다. 처리 실패 때는 다음 실행에서 재시도합니다.

탈퇴 시 개인정보 필드와 열람 권한은 DB에서 즉시 제거됩니다. worker는 증빙 원본의 삭제가 끝나고 서버가 `withdrawn`으로 확인한 계정만 Auth Admin API로 실제 삭제하여 로그인 이메일·인증 metadata도 제거합니다. 게시물에는 신원값 없는 UUID 상태행만 남아 `탈퇴한 회원`으로 표시됩니다. 기존 프라임에셋 프로젝트의 계정에는 접근하지 않습니다.

증빙 원본과 로그인 정보의 물리 삭제는 이 처리기가 실행되는 시점에 이뤄집니다. 따라서 예약 작업 등록 전에는 원본/인증계정 정리를 자동 완료했다고 볼 수 없습니다. 2분 크론 등록 후 Mac과 네트워크가 정상일 때 다음 실행에 처리되며, 처리 실패가 계속되는 경우 운영자가 수동 명령을 실행해 개인정보처리방침의 정리 기한을 지켜야 합니다.

## 검증

```sh
/usr/bin/python3 -m unittest discover -s /Volumes/MacWorkSSD/timcook/bohumlive/worker -p 'test_*.py' -v
```

합성 식별값 제거, 유니코드 우회, AI 입력 필드 제한, 환경 비밀값 차단, 저장소 경로 제한, 탈퇴 정리 순서, 실패 기록 경계를 확인합니다. 실제 구독 생성 결과와 DB 권한 검증은 작업 결과 보고서의 증거를 함께 봅니다.

## 증빙 자동 판정 (2026-11-09)

`--once` 실행마다 정리 작업 뒤 증빙 자동 판정을 최대 3건 처리합니다. `bl_worker('proof_queue')`로 대기 신청을 받고, 비공개 저장소의 증빙을 서비스 키로 내려받아 `~/Library/Application Support/Bohumlive/ocr`(권한 700)에 잠깐 두고 **이 Mac의 Apple Vision 글자인식**(`worker/ocr/bl_ocr.swift`, 처음 실행 때 `/usr/bin/swiftc`로 `worker/ocr/bl_ocr`를 만들어 씀)으로 읽은 뒤 바로 지웁니다. 사진과 읽은 글자는 외부 AI나 다른 서비스로 보내지 않습니다.

`worker/proof_check.py`가 '성명' 옆 이름, 14자리 숫자(설계사 고유번호), '소속회사' 옆 회사명을 찾아 신청 내용과 비교합니다. 회사는 공백·주식회사·(주)·㈜·대소문자를 정리하고 별칭표(예: INCAR=인카=인카금융서비스)로 비교합니다. 셋 다 맞고 회사가 목록에 있으면 승인, 분명히 다르면 반려(어느 항목인지 안내), 못 읽거나 애매하면 보류하고 관리자에게 앱 알림을 보냅니다. 판정 결과는 `bl_worker('proof_judgment')`로 저장되며 감사 기록에는 이름 첫 글자·번호 끝 4자리만 남습니다. 자동 판정이 막혀도(글자인식 실패 등) AI 답변과 정리는 계속하고 해당 신청은 보류로 넘깁니다.

```sh
/usr/bin/python3 -m unittest discover -s /Volumes/MacWorkSSD/timcook/bohumlive/worker -p 'test_*.py' -v
```
