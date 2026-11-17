-- 029: 신고는 설계사 인증을 마친 회원만 (2026-11-17 이사님 결정: "신고는 인증된 설계사만 가능하도록 변경")
--
-- 바뀌는 것은 하나뿐이다. 신고(report) 접수 조건을
--   '정지·탈퇴가 아닌 로그인 회원 누구나'(028에서 bl_can_write()가 넓어지며 생긴 상태)에서
--   '설계사 인증 완료 회원(bl_verified) + 대표(owner) + 관리자'로 되돌린다.
-- 그대로 두는 것: 미인증 회원의 읽기·글·댓글·좋아요(11/12 결정), AI 하루 한도, 하루 신고 10회,
--   서로 다른 신고자 3명 이상이면 최대 30일 임시 가림, 이미 접수된 신고 자료.
--
-- 방식: 운영 DB의 함수 본문은 저장소 SQL과 다를 수 있으므로 통째로 덮어쓰지 않는다.
--   실제 정의(pg_get_functiondef)를 읽어, 신고 구간 안에 예전 조건문이 정확히 한 번 있을 때만
--   그 한 줄을 바꾼다. 문맥이 다르면 아무것도 바꾸지 않고 중단한다(DO 블록 하나 = 전부 아니면 전무).
--   이미 적용된 상태에서 다시 실행하면 아무것도 하지 않는다.
-- 적용 전: 실제 정의를 따로 보관한다(비서작업기록/팀쿡/20261117_보라신고인증/db-before-029/).
-- 되돌리기: db/029_report_verified_only_rollback.sql (같은 방식으로 그 한 줄만 원래대로).

do $$
declare
 sig constant text := 'public.bl_action_internal(text,jsonb)';
 branch constant text := $b$if p_action='report' then$b$;
 old_gate constant text := $o$perform public.bl_require(public.bl_can_write() or public.bl_is_admin(),'신고는 설계사 인증을 마친 회원만 할 수 있어요.');$o$;
 new_gate constant text := $n$perform public.bl_require(public.bl_verified() or public.bl_is_owner() or public.bl_is_admin(),'신고는 설계사 인증을 마친 회원만 할 수 있어요.');$n$;
 src text;
 n_branch int;
 n_old int;
 n_new int;
 pos_branch int;
 pos_gate int;
 between_txt text;
begin
 set local lock_timeout = '10s';
 if to_regprocedure('public.bl_verified()') is null or to_regprocedure('public.bl_is_owner()') is null
    or to_regprocedure('public.bl_is_admin()') is null or to_regprocedure(sig) is null then
  raise exception '029 중단: 필요한 함수가 없습니다.';
 end if;
 src := pg_get_functiondef(sig::regprocedure);
 n_branch := (length(src) - length(replace(src, branch, ''))) / length(branch);
 n_old := (length(src) - length(replace(src, old_gate, ''))) / length(old_gate);
 n_new := (length(src) - length(replace(src, new_gate, ''))) / length(new_gate);

 if n_old = 0 and n_new = 1 then
  raise notice '029: 이미 적용되어 있습니다. 변경 없음.';
  return;
 end if;
 if n_branch <> 1 or n_old <> 1 or n_new <> 0 then
  raise exception '029 중단: 신고 구간 문맥이 예상과 다릅니다(branch=%, old=%, new=%). 아무것도 바꾸지 않았습니다.', n_branch, n_old, n_new;
 end if;
 -- 예전 조건문이 신고 구간 안(구간 시작 뒤, 다른 p_action 구간이 시작되기 전)에 있어야 한다.
 pos_branch := position(branch in src);
 pos_gate := position(old_gate in src);
 if pos_gate < pos_branch then
  raise exception '029 중단: 조건문이 신고 구간 시작보다 앞에 있습니다. 아무것도 바꾸지 않았습니다.';
 end if;
 -- 구간 시작과 조건문 사이에 구간을 닫거나 가르는 말(end if·else·elsif)이나 다른 p_action 판정이 없어야 구간 안이다.
 between_txt := lower(substr(src, pos_branch + length(branch), pos_gate - pos_branch - length(branch)));
 if between_txt ~ '(end\s+if|els(e|if)|p_action)' then
  raise exception '029 중단: 예전 조건문이 신고 구간 안에 있지 않습니다. 아무것도 바꾸지 않았습니다.';
 end if;

 execute replace(src, old_gate, new_gate);

 src := pg_get_functiondef(sig::regprocedure);
 if (length(src) - length(replace(src, new_gate, ''))) / length(new_gate) <> 1 or position(old_gate in src) > 0 then
  raise exception '029 중단: 적용 뒤 확인에 실패했습니다. 되돌립니다.';
 end if;
 raise notice '029: 신고 조건을 인증 회원·대표·관리자로 바꿨습니다.';
end
$$;

-- 확인용(읽기 전용): new_gate=1, old_gate=0 이면 적용된 상태.
select
 (length(d) - length(replace(d, 'public.bl_require(public.bl_verified() or public.bl_is_owner() or public.bl_is_admin(),''신고는', ''))) / length('public.bl_require(public.bl_verified() or public.bl_is_owner() or public.bl_is_admin(),''신고는') as new_gate,
 (length(d) - length(replace(d, 'public.bl_require(public.bl_can_write() or public.bl_is_admin(),''신고는', ''))) / length('public.bl_require(public.bl_can_write() or public.bl_is_admin(),''신고는') as old_gate
from (select pg_get_functiondef('public.bl_action_internal(text,jsonb)'::regprocedure) as d) s;
