-- 030 되돌리기: 내 정보 저장(profile_update)의 닉네임 저장 조건을 030 적용 전(소속 회사명 조건을 건너뛰는 예외는 대표만)으로 돌린다.
-- 030과 같은 방식이다. 실제 정의를 읽어 030이 넣은 조건문이 내 정보 저장 구간 안에 정확히 한 번 있을 때만
-- 그 한 줄을 예전 조건문으로 바꾼다. 030 뒤에 함수의 다른 부분이 바뀌었어도 그 변경은 건드리지 않는다.
-- 문맥이 다르면 아무것도 바꾸지 않고 중단한다. 이미 되돌린 상태에서 다시 실행하면 아무것도 하지 않는다.
-- (함수 전체를 030 적용 직전 정의로 되돌려야 하면 비서작업기록/팀쿡/20261117_보라닉네임/db-before-030/ 의 보관본을 쓴다.
--  단, 030 뒤에 다른 수정이 있었다면 보관본은 그 수정을 지우므로 이 파일을 먼저 쓴다.)
-- 되돌려도 030 동안 저장된 닉네임은 그대로 남는다(자료는 지우지 않는다).

do $$
declare
 sig constant text := 'public.bl_action_internal(text,jsonb)';
 branch constant text := $b$if p_action in ('profile_submit','profile_update','profile_precheck') then$b$;
 old_gate constant text := $o$perform public.bl_require(((public.bl_is_owner() and p_action='profile_update' and not (p_payload ? 'company_id' or p_payload ? 'company_name')) or (length(companyname) between 2 and 80 and public.bl_safe_text(companyname))),'소속 회사명을 2~80자로 입력해 주세요.');$o$;
 new_gate constant text := $n$perform public.bl_require((((public.bl_is_owner() or (pr.company_id is null and pr.company_name='')) and p_action='profile_update' and not (p_payload ? 'company_id' or p_payload ? 'company_name')) or (length(companyname) between 2 and 80 and public.bl_safe_text(companyname))),'소속 회사명을 2~80자로 입력해 주세요.');$n$;
 src text;
 n_branch int;
 n_old int;
 n_new int;
 pos_branch int;
 pos_gate int;
 between_txt text;
 n_if int;
 n_endif int;
begin
 set local lock_timeout = '10s';
 if to_regprocedure(sig) is null or to_regprocedure('public.bl_is_owner()') is null
    or to_regprocedure('public.bl_safe_text(text)') is null or to_regprocedure('public.bl_require(boolean,text)') is null then
  raise exception '030 되돌리기 중단: 필요한 함수가 없습니다.';
 end if;
 src := pg_get_functiondef(sig::regprocedure);
 n_branch := (length(src) - length(replace(src, branch, ''))) / length(branch);
 n_old := (length(src) - length(replace(src, old_gate, ''))) / length(old_gate);
 n_new := (length(src) - length(replace(src, new_gate, ''))) / length(new_gate);

 if n_new = 0 and n_old = 1 then
  raise notice '030 되돌리기: 이미 되돌린 상태입니다. 변경 없음.';
  return;
 end if;
 if n_branch <> 1 or n_new <> 1 or n_old <> 0 then
  raise exception '030 되돌리기 중단: 내 정보 저장 구간 문맥이 예상과 다릅니다(branch=%, old=%, new=%). 아무것도 바꾸지 않았습니다.', n_branch, n_old, n_new;
 end if;
 -- 바꿀 조건문이 내 정보 저장 구간 안, 그것도 구간의 맨 바깥 단계에 있어야 한다.
 pos_branch := position(branch in src);
 pos_gate := position(new_gate in src);
 if pos_gate < pos_branch then
  raise exception '030 되돌리기 중단: 조건문이 내 정보 저장 구간 시작보다 앞에 있습니다. 아무것도 바꾸지 않았습니다.';
 end if;
 -- 구간 시작과 조건문 사이: 다른 p_action 판정이나 return 이 없어야 하고(= 아직 같은 구간), 열린 if 가 모두 닫혀 있어야 한다(= 구간의 맨 바깥 단계).
 between_txt := lower(substr(src, pos_branch + length(branch), pos_gate - pos_branch - length(branch)));
 n_endif := (select count(*) from regexp_matches(between_txt, '\mend\s+if\M', 'g'));
 n_if := (select count(*) from regexp_matches(between_txt, '\mif\M', 'g')) - n_endif;
 if between_txt ~ '(p_action|\mreturn\M)' or n_if <> n_endif then
  raise exception '030 되돌리기 중단: 조건문이 내 정보 저장 구간의 예상 위치에 있지 않습니다. 아무것도 바꾸지 않았습니다.';
 end if;

 execute replace(src, new_gate, old_gate);

 src := pg_get_functiondef(sig::regprocedure);
 if (length(src) - length(replace(src, old_gate, ''))) / length(old_gate) <> 1 or position(new_gate in src) > 0 then
  raise exception '030 되돌리기 중단: 적용 뒤 확인에 실패했습니다. 되돌립니다.';
 end if;
 raise notice '030 되돌리기: 닉네임 저장 조건을 030 적용 전으로 되돌렸습니다.';
end
$$;

-- 확인용(읽기 전용): new_gate=0, old_gate=1 이면 되돌린 상태.
select
 (length(d) - length(replace(d, '(public.bl_is_owner() or (pr.company_id is null and pr.company_name='''')) and p_action=''profile_update''', ''))) / length('(public.bl_is_owner() or (pr.company_id is null and pr.company_name='''')) and p_action=''profile_update''') as new_gate,
 (length(d) - length(replace(d, 'public.bl_require(((public.bl_is_owner() and p_action=''profile_update''', ''))) / length('public.bl_require(((public.bl_is_owner() and p_action=''profile_update''') as old_gate
from (select pg_get_functiondef('public.bl_action_internal(text,jsonb)'::regprocedure) as d) s;
