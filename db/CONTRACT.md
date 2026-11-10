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

- 검색 매칭과 일반 게시글 목록(home/posts/search/company/me)의 경험형 본문은 인증 여부와 무관하게 앞 300자만 반환합니다. 인증회원의 나머지 본문은 post 상세 조회에서만 반환하며 관리자 심사용 조회는 예외입니다.

- 증빙 업로드는 회원별 보관 객체 최대 5개로 제한합니다. RLS 사전 검사는 보조 장치이며, 실제 storage.objects INSERT 트리거에서 전용 카운터를 조건부 원자 UPDATE하여 한도를 강제합니다. 삭제·폴더 이동도 같은 트리거가 카운터에 반영합니다. 미제출 고아 파일은 24시간 후 worker cleanup 대상으로 넣습니다.

- 004 이전에 이미 5개를 초과한 증빙은 삭제하지 않고 실제 개수로 카운터를 맞춥니다. 5개 미만이 될 때까지 신규 저장을 거부합니다. 다른 bucket의 Storage 동작은 이 트리거가 변경하지 않습니다.

- 모든 성공한 관리자 일반 쓰기(profile/post/comment/review/반응/신고/이의/읽음표시/탈퇴 포함)는 `admin_write_*` 감사 사건을 추가합니다. 본문·이름·연락처·증빙 경로 대신 행위·대상 UUID·허용된 상태/반응 메타데이터만 기록합니다. 관리 메뉴는 기존 감사 기록을 유지하며 중복 래퍼 기록은 하지 않습니다. 내부 구현 `bl_action_internal`은 외부 역할에서 실행할 수 없습니다.

## 006 권한·관리 보완 (2026-11-08)
- `viewer`에 `{can_write,can_admin,verification_exempt,is_sample}`를 추가합니다. 권한 판단은 서버 값이 우선입니다. 대표(owner)는 인증·소속 면제, 일반 관리자는 운영 권한과 회원 작성 권한을 분리합니다. 일반 관리자의 글·댓글·리뷰와 반응은 유효기간 내 인증이 필요합니다. 보완·반려·만료·정지·탈퇴도 작성·수정·삭제·반응이 차단됩니다.
- 대표는 인증이나 소속 등록 없이 닉네임만 변경할 수 있고, 활성 회사에 리뷰를 작성할 수 있습니다. 대표의 정지·역할 회수·직접 탈퇴는 계속 차단됩니다. 타인 본문 수정은 허용하지 않으며 운영자는 기존 콘텐츠 관리 기능으로 숨김·삭제·복구합니다.
- 신고는 미인증·대기·보완·반려·만료를 포함한 로그인 회원에게 허용합니다(댓글 신고는 댓글 열람 권한 필요). 정지·탈퇴는 신고 차단, 정지 회원의 본인 가림 콘텐츠 이의신청은 유지합니다. 알림 조회는 로그인 사용자, 읽음 처리는 탈퇴 외 로그인 사용자에게 허용합니다.
- `admin channel_delete`: `{operation:'channel_delete',id,target_channel_id?,reason?}`. 연결 글이 있으면 서로 다른 활성 대상 채널이 필수입니다. 가림·삭제 글을 포함해 모든 글을 이동하며 팔로우도 중복 없이 옮깁니다. 빈 채널은 바로 삭제합니다. 한 트랜잭션으로 수행하고 `admin_channel_delete`, 글 이동 시 `admin_channel_move`를 기록합니다. 응답 `{ok:true,id,moved_posts}`.
- `admin company_delete`: `{operation:'company_delete',id,target_company_id?,reason?}`. 연결 글·리뷰·회원이 있으면 서로 다른 활성 대상 회사가 필수입니다. 글 태그·리뷰·현재 회원 소속을 병합하고 회사명도 맞춥니다. 기존 작성 시점의 작성자 회사 표시값은 보존합니다. 한 트랜잭션으로 수행하며 `admin_company_delete`, 병합 시 `admin_company_merge`를 기록합니다. 응답 `{ok:true,id,moved_posts,moved_reviews,moved_members}`. 회사 이름 수정 시 현재 연결 회원의 소속명도 반영합니다.
- 관리자 채널 DTO에 `post_count`, 회사 DTO에 `post_count,total_review_count,member_count,reference_count`를 제공합니다. 일반 조회에서는 이 관리용 값이 null입니다. 삭제 여부는 숨김·삭제 콘텐츠까지 포함한 전체 연결 수를 기준으로 합니다.
- profiles/posts/comments/reviews에 서버 전용 `is_sample`을 추가합니다. 견본 계정에서 작성한 글·댓글·리뷰에 자동 전파하며 클라이언트가 값을 지정할 수 없습니다. post/comment/review DTO에 `is_sample`을 제공합니다. 견본은 공개 유지하고 기존 `is_test` 가림은 유지합니다.
- 관리자 dashboard의 회원·대기·신고·오늘 글·오늘 댓글 집계는 시험과 견본을 제외합니다. 글·댓글은 삭제 상태도 제외합니다. `dashboard.counts_exclude_test_and_sample=true`로 기준을 표시합니다.
- 회사 리뷰 통계는 시험·견본을 제외합니다. 회사 병합으로 같은 작성자의 리뷰가 여러 개가 되면 가장 최근 공개 리뷰 한 건만 점수와 최소 5명 기준에 반영합니다. 리뷰 원문은 삭제하지 않습니다.
- 회원 소속 `bl_profiles.company_id`에도 `bl_profiles_company_fk` 외래 키를 추가합니다. 회사 병합/삭제와 회원 소속 제출이 동시에 실행되어도 존재하지 않는 회사 참조를 남길 수 없습니다.

## 2026-11-09 수정 (007~013)
- **007 인증 신청**: `profile_submit`의 `registration_number`(설계사 고유번호)는 숫자 14자리 필수. 활성 신청·회원(대기·보완·인증·정지)과 중복이면 `'이미 등록된 설계사 고유번호입니다.'`(탈퇴·반려·미인증 제외). 원번호는 30일 정리 규칙을 따르고 `bl_profiles.registration_digest`(확인값)만 탈퇴 전까지 보관. 주민번호 모양 차단 삭제. 하루 5회. `profile_precheck`(사진 올리기 전 같은 검사 → `{ok,proof_slots_left,cleaning}`), `proof_discard {proof_path}`(실패한 신청 사진을 즉시 정리 대상으로). 증빙 5장 한도는 정리 예정 사진을 빼고 센다. unique 위반은 한국어 안내.
- **008 증빙 자동 판정**: worker `proof_queue` → `{items:[{id,proof_path,name,registration_number,company_id,company_name}],companies}`, `proof_judgment {id,proof_path,decision:'approve'|'reject'|'hold',reasons,fields,read,company_id?}`. 승인은 기존 회사 목록의 회사로만 연결(없으면 보류). `bl_profiles.auto_result/auto_checked_at`, 감사 `auto_verification`(이름 첫 글자·번호 끝 4자리). 관리자 `verification`은 직접 입력 회사를 `company_id`로 기존 회사에 연결해야 승인(회사 자동 생성 없음).
- **009 신고·알림**: `report`는 인증 회원·관리자만, 본인 글 불가, 서로 다른 신고자 3명 이상이면 임시 가림(공지·운영팀 글은 가리지 않음), 응답 `{ok,hidden}`. 30일 자동 복구는 실제로 가린 콘텐츠만. 관리자 앱 알림 kind `admin_todo`(새 신고·새 인증 신청·자동 판정 보류·이의신청·문의, 시험 계정 건은 시험 관리자에게만). `viewer.unread_count`.
- **010 관리자**: `bl_read('admin',{v:'2',section,q,status,offset,limit<=100,id?,channel_id?})` → 탭별 자료만(`dashboard{todo,trend}`, `verifications`, `members`, `member`, `posts`, `comments`, `reviews`, `reports`, `inquiries`, `channels`, `companies`, `ai`, `audit`, `admins`, `settings`). 개인정보가 담긴 조회(인증 심사 목록·회원 상세)만 감사 기록. 새 operation: `member_status`(+`days`: 1·3·7·30·90·365·0, 기간 끝나면 worker `temporary_review`가 해제), `member_withdraw`, `report_block {days:0|7|30|90|36500}`, `post_move {channel_id}`, `notice_order {direction}`, `channel_move {direction}`, `ai_edit {body}`, `ai_retry`, `ai_regenerate`, `banned_words {words}`, `reveal_author {target,id,reason}`(011), `inquiry_answer {answer}`(012). `channel_save`의 `slug`는 비우면 자동. `post_save`의 `as_team`·`pinned`(관리자, 인증 없이 운영팀 이름 가능). 작성자 표시: 소속 없으면 `닉***`, `as_team`이면 '보험라이브 운영팀'. 금칙어가 든 글·댓글·리뷰는 거부.
- **011 채널**: `bl_channels.anonymous`, `bl_posts.anonymous`, `bl_comments.anonymous`. 익명 글·댓글은 작성자 회사·닉네임을 비워 저장하고 `author_display`는 '익명'(댓글은 글쓴이 본인이면 '글쓴이'). 한 번 익명이면 계속 익명, 익명 채널로 옮겨진 글은 익명으로 바뀜(`bl_anon_sync`). 익명 글은 관련 회사 태그 없음.
- **012 회원 기능**: 견본 계정 작성자 표시 '견본 계정'. `toggle`의 bookmark·follow는 로그인 회원(정지·탈퇴 제외). `posts`·`search`에 `offset`. 잘못된 글·회사 id는 오류 대신 `unavailable_reason:'not_found'`/`company:null`. `inquiry {kind:'general'|'privacy'|'rights'|'account',link?,body}`(하루 5회, 탈퇴 시 삭제).
- **013**: 검색어 `%`·`_`는 글자 그대로. 가려진 글은 작성자 본인이 제목·본문을 볼 수 있음(이의신청용). 회사 종류 `생명보험사`·`손해보험사`·`GA`(·`보험사`).

## 2026-11-10 블라인드형 개편 (014~016)
- **014 조회수·홈**: `bl_posts.view_count`. post DTO에 `views`(목록·상세 공통). `bl_read('post',{id,view:'1'})`일 때만 1 증가 — 화면은 같은 기기·같은 접속에서 글마다 한 번만 `view`를 보낸다. 가려진 글·작성자 본인은 세지 않고, 시험 계정의 조회는 시험 글에서만 센다. `bl_read('home',{v:'3'})` → `{viewer,notices,best,boxes,channels}`: `best`는 공지 제외 인기 글 10개(최근 30일 우선 → 좋아요 → 댓글 → 조회수 → 최신), `boxes`는 사용 중인 채널마다 `{channel_id,posts:[최신 5개, 공지 제외]}`. `bl_read('best')` → `{viewer,best}`(PC 오른쪽 '인기 글'용). `v` 없는 `home` 호출은 예전 응답 그대로.
- **015 채널별 손님 공개 범위**: `bl_channels.guest_full`(채널 DTO에도 제공). `post_save`가 `content_kind`를 받지 않으면 자동으로 정한다 — ① 같은 채널에서 고치는 글은 원래 값 유지 ② `as_team`(관리자)이면 `weekly` ③ 채널 `guest_full`이면 `practice`, 아니면 `experience`. `content_kind`를 보내면 예전처럼 그 값을 쓴다(`weekly`는 관리자만). 손님 300자 제한 방식(`experience`)과 댓글 권한은 그대로. 관리자 `channel_save`에 `guest_full?:boolean`(없으면 기존 값 유지, 새 채널 기본 false). 채널 설정을 바꿔도 이미 쓴 글의 `content_kind`는 바뀌지 않는다(새 글부터 적용).
- **016**: 작성자 정보가 없는 글(운영팀 공지·탈퇴 회원 글)을 손님이 열 때도 조회수를 센다(014의 조건 보완).
- 화면 쪽 약속: 좋아요·저장·팔로우는 `toggle` 응답 `active`로 그 자리에서 반영(전체 다시 그리지 않음), 댓글 저장·삭제 뒤에는 `post`를 다시 읽어 댓글 구역만 갱신. 글쓰기 임시저장은 기기 저장소(`bl_draft:<회원>:<글|new>`)에만 두고 서버로 보내지 않으며 등록·로그아웃 때 지운다.

## 2026-11-10 팔로우 알림·AI 참고 자료 (020)
- **채널 팔로우 새 글 알림**: `bl_posts`에 새 글이 들어가면(공개·사용 중 채널) 트리거 `bl_posts_follow_notify`가 그 채널 팔로워에게 `bl_notifications(kind='follow', post_id, channel_id)`를 만든다. 글쓴이 본인·탈퇴 회원 제외, 시험 글(`is_test`)은 시험 프로필에만.
- `bl_read('me'|'notifications')`의 `notifications`: 팔로우 알림은 **읽지 않은 것·지금 볼 수 있는 글**만 준다. 같은 채널이 5개 이상이면 한 줄 `{id:null,kind:'follow_group',title:'○○ 채널에 N개의 새 글이 있습니다',channel_id,count:N,read_at:null,created_at}`, 4개 이하는 `{id,kind:'follow',title:'○○ 채널 새 글: 제목',post_id,channel_id,count:1}`. 다른 알림은 예전 그대로.
- `viewer.unread_count`는 팔로우 알림을 목록과 같은 기준(볼 수 있는 글만)으로 센다 — 묶음의 N과 합이 맞는다.
- `bl_read('post')`를 로그인 회원이 부르면 그 글의 팔로우 알림은 읽음 처리된다.
- `notification_read {channel_id}`: 그 채널의 팔로우 알림만 읽음(묶음을 눌렀을 때). `{id}`·`{}`는 예전 그대로.
- 관리자 `ai_settings`: `enabled`만 저장한다. 하루 개수(`ai_daily_limit`, 019에서 1000000)는 바꾸지 않는다(30 상한 제거).
- **AI 참고 자료(Mac 처리기)**: `worker/kb_build.py`로 상품 자료 목록(최신판 약관·상품요약서·사업방법서·상품설명서, 허용 폴더만)과 보험위키 정리 원문을 한 번 읽어 `worker/kb/bl_kb.sqlite3`(git 제외)를 만든다. 처리기는 질문마다 `kb_search.search`로 맞는 발췌 0~3개를 찾아 `official_sources`(자료·보험사·상품·종류·기준·쪽·발췌)로 넣는다. 색인이 없거나 깨지면 자료 없이 예전처럼 답한다. 고객·개인 자료 폴더(메일·메신저·고객 파일·접수함)는 경로 규칙으로 읽지 않는다.

## 2026-11-10 댓글·답글 알림 묶음 (021, 대표 추가 지시 2)
- **알림 만들기**: `bl_comments`에 새 댓글이 들어가면 트리거 `bl_comments_notify`가 ① 원댓글 작성자에게 `kind='reply'`(답글일 때) ② 글쓴이에게 `kind='comment'`를 만든다(`post_id`, `comment_id`=새 댓글). 본인이 쓴 것·탈퇴 회원 제외, 시험 댓글은 시험 프로필에만, 글쓴이가 곧 원댓글 작성자면 `reply` 1건만. `comment_save`의 예전 알림 줄은 뺐다(중복 방지).
- **AI 참고 답변**: `bl_ai_replies`에 처음 공개 insert될 때 트리거 `bl_ai_replies_notify`가 글쓴이에게 `kind='comment'` 1건(제목 '내 글 '…'에 AI 참고 답변이 달렸습니다', `comment_id` 없음). 다시 만들어 덮어쓰기(update)는 알리지 않는다.
- `bl_read('me'|'notifications')`의 `notifications` 각 줄에 `count`·`anchor`·`comment_id`가 있다. 같은 종류·같은 대상·같은 읽음 상태가 5개 이상이면 한 줄: `comment_group`(대상=글, `post_id`, '내 글 '제목'에 N개의 댓글이 달렸습니다', anchor `comments`), `reply_group`(대상=원댓글, `comment_id`=원댓글, '내 댓글에 N개의 답글이 달렸습니다', body '내 댓글: 앞부분…', anchor `comment-<원댓글>`), `follow_group`(020 그대로). 4개 이하는 `comment`('내 글 '제목'에 새 댓글이 달렸습니다', anchor `comment-<댓글>`)·`reply`('내 댓글에 새 답글이 달렸습니다')·AI(anchor `comment-ai`). 댓글·답글 알림은 읽은 뒤에도 남고(5개 이상이면 읽은 묶음 한 줄), 팔로우 알림은 읽으면 빠진다. 지워지거나 가려진 글·댓글의 알림은 목록·종 숫자에서 빠진다(`bl_note_visible`).
- `viewer.unread_count`는 목록과 같은 기준 — 묶음 N의 합과 같다.
- `notification_read {post_id}` = 그 글의 `comment` 알림, `{comment_id}` = 그 원댓글에 달린 `reply` 알림, `{channel_id}` = 팔로우(020). `{id}`·`{}`는 예전 그대로.
- `bl_read('post')`를 로그인 회원이 부르면 그 글의 팔로우 알림과(댓글을 볼 수 있는 회원이면) 댓글·답글 알림이 읽음 처리되고, 응답의 `viewer.unread_count`도 바로 맞춘다.
- 예전 '내 댓글에 답글이 달렸습니다' 줄은 `kind='reply'`로 맞췄다(대상 정보가 없어 한 줄씩).
- **AI 답변에는 근거·출처를 쓰지 않는다**(같은 날 대표 지시): 처리기는 Mac 자료 발췌를 입력에만 넣고, 답변 본문에 자료 이름·약관명·기준일·쪽·조항·'○○에 따르면'·출처 줄·질문에 없는 회사·상품 이름이 있으면 1회 고쳐 쓰게 하고, 남으면 지운 뒤 그래도 남으면 공개하지 않는다(다음 회차 다시). '확인 포인트' 줄은 쓰지 않는다.

## 2026-11-10 AI 실제 댓글 통합 (023)
- AI 답변은 `bl_comments.is_ai=true`, `author_id=null`인 원댓글 한 건이다. AI 로그인 계정·회원 프로필을 만들지 않는다. 회원 통계·개인 활동·댓글 작성 제한에서 제외하며, 운영 대시보드의 오늘 댓글·댓글 추이에서도 제외한다. 일반 회원 댓글은 작성자 필수이다. 클라이언트가 AI 여부를 지정할 수 없다.
- comment DTO에 `is_ai:boolean`을 추가한다. AI의 `author_display`는 **AI 답변은 참고만 하세요**, `is_mine=false`이다. 좋아요·답글·정렬·신고·임시 가림·관리자 숨김/복구는 일반 댓글과 같은 경로이다. AI가 작성자이므로 받을 사람이 없는 알림은 생기지 않으며, 글쓴이는 기존 댓글 알림 규칙으로 한 건만 받는다.
- `post.comments`에 AI도 들어가고 `ai_reply`는 호환용으로 항상 null이다. 기존 `bl_ai_replies`는 삭제·수정하지 않고 보존하되 조회·처리기·관리자 AI 기능은 모두 실제 댓글을 사용한다. 기존 답변 8건은 ID·본문·공개 여부·작성 시각을 유지하여 옮겼으며 과거 알림은 새 댓글 ID에 연결한다(재발송 없음).
- `bl_worker complete`는 댓글을 upsert하고 `{ok,status:'published',comment_id}`를 반환한다. 글당 AI 1건은 부분 고유 색인으로 강제한다. 재작성은 ID·최초 시각·좋아요·답글을 유지하며 본문·갱신 시각을 바꾼다. 관리자 AI 수정/숨김/다시 생성도 같은 댓글을 사용한다. 모델·노력 수준·형식·바로 공개·자료 참고·출처 미표기 규칙은 유지한다.
- `comment_count`는 공개 댓글(AI 포함)만 한 번 센다. 022 인기 점수의 댓글×2에도 동일한 저장소의 AI가 포함된다. AI 댓글 좋아요는 `target='comment'`여서 글 좋아요×3에 들어가지 않는다. 최근 30일 우선·10개·시간 감쇠 지수 1.2 등 나머지 기준은 유지한다.
- 댓글 열람 권한은 기존대로 인증 회원·관리자이며 손님은 댓글 수만 본다. 화면의 AI 작성자 문구만 변경하고 관리자 안내·약관·글쓰기 체크칸은 그대로 둔다. 과거 `#comment-ai` 링크도 새 댓글로 이동한다.
