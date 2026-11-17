-- 029 되돌리기: 신고 접수 조건을 029 적용 전(028 상태: 정지·탈퇴가 아닌 로그인 회원 누구나 + 관리자)으로 돌린다.
-- 029와 같은 방식이다. 실제 정의를 읽어 029가 넣은 조건문이 신고 구간 안에 정확히 한 번 있을 때만
-- 그 한 줄을 예전 조건문으로 바꾼다. 029 뒤에 함수의 다른 부분이 바뀌었어도 그 변경은 건드리지 않는다.
-- 문맥이 다르면 아무것도 바꾸지 않고 중단한다. 이미 되돌린 상태에서 다시 실행하면 아무것도 하지 않는다.
-- (함수 전체를 029 적용 직전 정의로 되돌려야 하면 비서작업기록/팀쿡/20261117_보라신고인증/db-before-029/ 의 보관본을 쓴다.
--  단, 029 뒤에 다른 수정이 있었다면 보관본은 그 수정을 지우므로 이 파일을 먼저 쓴다.)

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
 if to_regprocedure(sig) is null or to_regprocedure('public.bl_can_write()') is null then
  raise exception '029 되돌리기 중단: 필요한 함수가 없습니다.';
 end if;
 src := pg_get_functiondef(sig::regprocedure);
 n_branch := (length(src) - length(replace(src, branch, ''))) / length(branch);
 n_old := (length(src) - length(replace(src, old_gate, ''))) / length(old_gate);
 n_new := (length(src) - length(replace(src, new_gate, ''))) / length(new_gate);

 if n_old = 1 and n_new = 0 then
  raise notice '029 되돌리기: 이미 029 적용 전 상태입니다. 변경 없음.';
  return;
 end if;
 if n_branch <> 1 or n_new <> 1 or n_old <> 0 then
  raise exception '029 되돌리기 중단: 신고 구간 문맥이 예상과 다릅니다(branch=%, old=%, new=%). 아무것도 바꾸지 않았습니다.', n_branch, n_old, n_new;
 end if;
 pos_branch := position(branch in src);
 pos_gate := position(new_gate in src);
 if pos_gate < pos_branch then
  raise exception '029 되돌리기 중단: 조건문이 신고 구간 시작보다 앞에 있습니다. 아무것도 바꾸지 않았습니다.';
 end if;
 -- 구간 시작과 조건문 사이에 구간을 닫거나 가르는 말(end if·else·elsif)이나 다른 p_action 판정이 없어야 구간 안이다.
 between_txt := lower(substr(src, pos_branch + length(branch), pos_gate - pos_branch - length(branch)));
 if between_txt ~ '(end\s+if|els(e|if)|p_action)' then
  raise exception '029 되돌리기 중단: 조건문이 신고 구간 안에 있지 않습니다. 아무것도 바꾸지 않았습니다.';
 end if;

 execute replace(src, new_gate, old_gate);

 src := pg_get_functiondef(sig::regprocedure);
 if (length(src) - length(replace(src, old_gate, ''))) / length(old_gate) <> 1 or position(new_gate in src) > 0 then
  raise exception '029 되돌리기 중단: 적용 뒤 확인에 실패했습니다. 되돌립니다.';
 end if;
 raise notice '029 되돌리기: 신고 조건을 029 적용 전으로 돌렸습니다.';
end
$$;

-- 확인용(읽기 전용): new_gate=0, old_gate=1 이면 되돌린 상태.
select
 (length(d) - length(replace(d, 'public.bl_require(public.bl_verified() or public.bl_is_owner() or public.bl_is_admin(),''신고는', ''))) / length('public.bl_require(public.bl_verified() or public.bl_is_owner() or public.bl_is_admin(),''신고는') as new_gate,
 (length(d) - length(replace(d, 'public.bl_require(public.bl_can_write() or public.bl_is_admin(),''신고는', ''))) / length('public.bl_require(public.bl_can_write() or public.bl_is_admin(),''신고는') as old_gate
from (select pg_get_functiondef('public.bl_action_internal(text,jsonb)'::regprocedure) as d) s;
