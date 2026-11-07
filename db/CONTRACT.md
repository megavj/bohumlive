# 보험라이브 DB / UI 계약

두 RPC: `bl_read(p_scope text, p_args jsonb={})`, `bl_action(p_action text,p_payload jsonb={})`. 성공 JSON, 실패 Supabase error의 message에 한국어 안내. 모든 ID UUID 문자열. 응답은 `data` 중첩 없이 아래 구조. 날짜 ISO. 공개 author UUID 없음.

## 조회
- 모든 read 응답 `viewer`: null 또는 `{status,role,nickname,company_name,verified_until,is_test}`. role `member/admin/owner`; status `unverified/pending/supplement/verified/rejected/suspended/withdrawn`.
- `home`: `{viewer,channels,posts,popular,notices,companies,settings:{ai_enabled}}`
- `channels`: `{viewer,channels}`. channel `{id,slug,name,description,display_order,enabled,followers,following}`
- `posts`: args `{channel_id?,q?,company_id?,sort?:'latest'|'popular',limit?:50}` -> `{viewer,posts}`
- `post`: args `{id}` -> `{viewer,post,comments,ai_reply}`. post null이면 존재하지 않음/가림.
- post DTO `{id,channel_id,channel_name,title,body,content_kind,is_question,company_id,company_name,author_display,created_at,updated_at,status,pinned,likes,comment_count,liked,bookmarked,is_mine,is_truncated}`. body는 서버가 권한별 제한; 목록도 same DTO.
- comment DTO `{id,post_id,parent_id,body,author_display,created_at,updated_at,likes,liked,is_mine,status}`. comments는 인증/관리자만, 대댓글 한 단계. ai_reply null 또는 `{id,body,created_at,label:'보험라이브 AI 참고 답변'}`. AI는 댓글 수 제외.
- `companies`: `{viewer,companies}`. company `{id,name,kind,description,enabled,review_count,average,scores}`. scores는 5항목 배열, average/scores는 유효 리뷰 5개 미만 null.
- `company`: args `{id}` -> `{viewer,company,reviews,posts}`. review `{id,company_id,title,body,scores,author_display,created_at,updated_at,is_mine,is_truncated}`
- `me`: `{viewer,profile,posts,comments,bookmarks,notifications,follows,reviews}`. profile `{nickname,company_id,company_name,status,review_reason,verified_until,name_masked,phone_masked,has_proof,role}`. 원본 이름/연락처는 본인에게도 재반환 안 함.
- `admin`: admin만. args `{section?:'dashboard'|'verifications'|'members'|'posts'|'comments'|'reports'|'reviews'|'channels'|'companies'|'ai'|'audit'|'admins',q?}` -> `{viewer,dashboard,members,verifications,posts,comments,reports,reviews,channels,companies,ai_jobs,audit,admins,settings}`. 초기 버전 모든 섹션 데이터 반환. 민감정보는 verifications 안 `{id:user_uuid,name,phone,registration_number,nickname,company_id,company_name,status,proof_path,submitted_at,review_reason}`. member `{id,nickname,company_name,status,verified_until,role}`. 관리자 대상 ID는 여기서 취득. settings `{ai_enabled,ai_daily_limit}`.

## 쓰기
- `profile_submit`: `{name,nickname,company_id?,company_name?,phone,registration_number?,proof_path}` -> `{ok:true,status:'pending'}`. company_name 직접입력 가능. proof 필수.
- `profile_update`: `{nickname?,company_id?,company_name?}` -> `{ok:true,status}`. 소속 변경은 pending으로 하향. 신규 증빙은 profile_submit 사용.
- `withdraw`: `{}` -> `{ok:true}`. 즉시 권한 차단/개인정보 삭제, 콘텐츠 탈퇴 표시. UI signOut.
- `post_save`: `{id?,channel_id,title,body,content_kind:'practice'|'career'|'experience'|'weekly',is_question:boolean,company_id?}` -> `{ok:true,id}`. weekly 관리자만.
- `post_delete`: `{id}` -> `{ok:true}`
- `comment_save`: `{id?,post_id,parent_id?,body}` -> `{ok:true,id}`
- `comment_delete`: `{id}` -> `{ok:true}`
- `toggle`: `{target:'post'|'comment'|'channel',id,kind:'like'|'bookmark'|'follow'}` -> `{ok:true,active:boolean}`. bookmark는 post, follow는 channel만.
- `report`: `{target:'post'|'comment'|'review',id,reason}` -> `{ok:true}`. 즉시 임시 가림, 신고자/작성자 인앱 통지.
- `review_save`: `{id?,company_id,title,body,scores:[1,2,3,4,5]}` -> `{ok:true,id}`. 점수 5개 각각 1~5 정수. 현 인증회사만, 회사당 365일 1건. 기존 것 수정 가능.
- `notification_read`: `{id?}` -> `{ok:true}`. id 없으면 본인 모두 읽음.
- `admin`: 아래 operation; 항상 `{ok:true}` 또는 생성 `{ok:true,id}`.
  - `verification`: `{operation:'verification',id:user_uuid,status:'verified'|'supplement'|'rejected',reason}`
  - `member_status`: `{operation:'member_status',id:user_uuid,status:'suspended'|'verified'|'unverified',reason}`
  - `nickname`: `{operation:'nickname',id:user_uuid,nickname,reason}`
  - `content`: `{operation:'content',target:'post'|'comment'|'review',id,status:'published'|'hidden'|'deleted',reason,pinned?:boolean}`
  - `report_resolve`: `{operation:'report_resolve',id:report_uuid,decision:'restore'|'maintain',reason}`
  - `channel_save`: `{operation:'channel_save',id?,slug,name,description,display_order,enabled}`
  - `company_save`: `{operation:'company_save',id?,name,kind:'보험사'|'GA',description,enabled}`
  - `ai_settings`: `{operation:'ai_settings',enabled:boolean,daily_limit?:30}`
  - `admin_role`: `{operation:'admin_role',id:user_uuid,role:'admin'|'member',reason}` owner만.
  - `proof_access`: `{operation:'proof_access',id:user_uuid,reason}` -> `{ok:true,path}` (감사기록). 이어 Storage createSignedUrl(path,60); 서버 Storage RLS도 admin 검사.

## 증빙 업로드
bucket `bl-proofs` private. 로그인 후 `bl_read('me')`로 lazy profile 생성. 경로 `${session.user.id}/${crypto.randomUUID()}.${ext}`; `upload(path,file,{upsert:false,contentType:file.type})`. JPEG/PNG/WebP, 5MB 이하. 회원은 본인 새 객체 INSERT만, 원본 읽기/목록/수정 불가. 관리자만 signed URL 생성 가능. 제출 파일은 존재/소유 검사. 증빙에 주민번호/고객정보가 보이지 않게 안내. 관리자 signed URL 유효기간 **60초**.

## AI / 정리 worker (service_role 전용)
`bl_worker(p_action,p_payload={})`:
- `claim`: `{}` -> `{job:null}` 또는 `{job:{id,post_id,title,body,attempts,lease_token}}`; enabled 확인/하루 생성 상한 30/중복 claim 방지.
- `complete`: `{id:job_uuid,lease_token,body,model?}` -> `{ok:true}`; 게시글당 AI 답변 1개 upsert, status review(검수대기), 사용자 글·댓글 독립. 관리자 ai_publish 후 공개.
- `fail`: `{id,lease_token,error}` -> `{ok:true}`; 오류는 500자 정리하여 기록(비밀값 금지).
- `cleanup_list`: `{}` -> `{paths:[...]}`; 처리일 30일 지난 증빙/탈퇴 증빙 대상. Storage remove 후
- `cleanup_done`: `{paths:[...]}` -> `{ok:true}`; 경로/개인정보 정리.
- `temporary_review`: `{}` -> 30일 지난 미결 임시조치 자동 복구+양측 알림+감사. 운영자가 maintain로 결정한 최종 가림은 복구하지 않음.

## 운영 기준
글 하루 10/60초 간격, 댓글 하루 50/10초, 신고 하루 10. 회원별 DB 잠금으로 원자 적용. 공개 body 300자 제한은 experience/review만, 나머지 전체. nickname 첫 글자+***, 회사명 유지. is_test 콘텐츠는 일반 방문자/회원에게 숨기고 시험 프로필·관리자에게만 표시. 본인/관리자 외 UUID·실명·연락처·증빙 경로 미노출. 모든 테이블 직접 접근은 RLS+권한 회수. admin 조회/행위 및 증빙 접근 감사 append-only.


## 계약 보완
- `post` 조회에서 post가 null이면 `unavailable_reason:'temporary_hidden'|'unavailable'`, `hidden_until`도 반환. 가려진 제목/본문/작성자는 반환 안 함.
- `review_delete`: `{id}` 본인 리뷰 삭제. 365일 신규 작성 제한은 삭제해도 유지.
- `appeal`: `{target:'post'|'comment'|'review',id,reason}` 본인 숨김 콘텐츠 처리결과 이의신청. 정지회원도 가능. 같은 콘텐츠 하루1회, 관리자 알림+감사 기록. 관리자 콘텐츠 복구/유지 후 회원에게 처리 통지.
- admin `operation:'ai_publish'|'ai_reject'`, `{id:job_uuid,reason}`. ai_jobs에는 `answer`, `answer_status`도 제공. 공개 전 반드시 관리자 검수.
- worker `heartbeat`: `{id,lease_token}` -> `{ok:true}`; lease6분 갱신. 일일30은 실패 포함 생성 시도 횟수.
- worker `status`: `{ai_enabled,ai_daily_limit,queued,review}`.
- worker `cleanup_users`: `{}` -> `{ids:[withdrawn uuid...]}`. 미삭제증빙/Storage객체 없는 탈퇴회원만 반환. Auth Admin hard delete 후 `cleanup_user_done:{id}`. DB는 실제 auth.users 삭제 확인 후 tombstone에 auth_deleted_at 기록. bl_profiles UUID는 익명 콘텐츠 관계를 위해 유지되며 auth.users FK는 없음.
- 인증 신청자에게는 본인 증빙 원본 SELECT 권한 없음. admin `proof_access` 기록 후 Storage sign60초; Storage SELECT도 관리자 검사와 별도 열람감사 기록.
- 신고는 로그인 회원부터 가능(설계사 인증 전 포함). 방문자는 로그인 안내. 이의신청은 대표 이메일·실명·연락처 없이 앱 내부 통지.
