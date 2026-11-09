# 보험라이브 Mac 처리기

기존 AskQueue 스크립트, 기존 예약 작업, LaunchAgent를 변경하지 않는 독립 처리기입니다. Python 표준 라이브러리만 사용합니다. GitHub Pages에서 실행되지 않으며 Mac이 켜져 있어야 합니다.

## 실행과 재시작

서비스 키는 macOS 로그인 Keychain의 서비스 `bohumlive-service-role`에 저장합니다. 대안은 프로세스 환경 `BL_SERVICE_ROLE_KEY`이며 파일·명령 인자·Git에 기록하지 않습니다. Claude는 기존 Keychain 서비스 `timcook-claude-oauth-token`만 사용하며 API 키나 유료 API로 전환하지 않습니다.

```sh
/usr/bin/python3 /Volumes/MacWorkSSD/timcook/bohumlive/worker/bohumlive_worker.py --dry-run
/usr/bin/python3 /Volumes/MacWorkSSD/timcook/bohumlive/worker/bohumlive_worker.py --once
/usr/bin/python3 /Volumes/MacWorkSSD/timcook/bohumlive/worker/bohumlive_worker.py --maintenance-only
```

`--dry-run`은 DB 상태와 인증 수단의 존재만 확인하며 질문을 가져오거나 생성·삭제하지 않습니다. `--once`는 증빙 정리 후 질문 최대 1건을 처리하고 종료합니다. 재시작은 같은 `--once` 명령을 다시 실행하면 됩니다. 중복 프로세스는 전용 파일 잠금으로 종료하며 서버에서도 lease token으로 중복 생성을 차단합니다. Mac 종료/네트워크 오류 이후에는 서버 lease 만료 뒤 다시 처리됩니다. 로그에는 질문, 답변, 회원/게시글 ID, 경로, 키, CLI 오류 본문을 기록하지 않습니다.

## 팀쿡이 등록할 예약 작업

다음은 **아직 등록하지 않은** crontab 행입니다. Mac 로그인 사용자 `megavj`의 크론에 등록합니다. Keychain 잠금 해제 상태와 `/Volumes/MacWorkSSD` 연결이 필요합니다. 경로를 바꾸지 않았다면 아래 행 그대로 사용합니다.

```cron
*/2 * * * * /usr/bin/python3 /Volumes/MacWorkSSD/timcook/bohumlive/worker/bohumlive_worker.py --once >/dev/null 2>&1
```

AI를 끈 상태에서도 같은 작업은 증빙 정리를 수행합니다. 비식별 상태 로그를 보려면 수동 `--once`를 실행합니다. 기본 프로젝트는 보험라이브 전용 `behqpqucmnehzinssnxr`입니다. 다른 보험라이브 전용 프로젝트로 이전한 경우에만 `BL_SUPABASE_URL=https://프로젝트ID.supabase.co`를 지정하고 해당 프로젝트의 서비스 키로 바꿉니다.

## 생성과 개인정보 경계

- `bl_worker`는 service_role만 호출합니다. 질문을 서버에서 원자적으로 claim하고 서버의 AI 스위치, 하루 30건 상한, 재시도 한도와 lease token을 적용합니다.
- Claude 실행은 `claude-opus-5-5`, effort `high`, 기존 구독 OAuth, `--safe-mode`, 빈 도구 목록, 빈 MCP 구성, 세션 저장 없음으로 고정합니다. 결과의 실제 모델명도 확인합니다. fallback 설정·다른 제공자 키·서비스 키·프록시를 자식 환경으로 전달하지 않습니다.
- DB는 작성자의 알려진 이름·연락처 등과 일치하는 본문 식별값을 지우며, worker는 질문 제목/본문만 선택해 전화·이메일·주민번호·계좌/등록번호·주소/인명 표기를 추가로 제거합니다. 가입 정보, 실명 필드, 연락처 필드, 증빙 사진, 사용자 ID는 AI에 전달하지 않습니다.
- 임의의 자유서술 인명을 정규식만으로 완벽히 판별할 수는 없습니다. 사용자는 게시물에 개인정보를 쓰지 않도록 안내받고, 생성 결과는 **관리자 검수 대기**에 저장됩니다. 관리자 승인 전 공개되지 않습니다.
- 공식 자료가 주어지지 않으므로 답변에 그 사실을 명시하고 약관·지급·금액·법령을 단정하지 않도록 제한합니다. 질문 속 지시는 자료로만 처리합니다. 사람 댓글·좋아요·인기 집계와 AI를 분리합니다.
- 실패는 정해진 오류 코드만 DB에 저장하고 사용자 글/댓글에는 영향을 주지 않습니다.

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
