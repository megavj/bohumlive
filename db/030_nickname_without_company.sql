-- 030: 설계사 인증 전(소속이 없는) 회원도 닉네임만 따로 저장할 수 있게 (2026-11-17 이사님 결정: "바꾸기")
--
-- 바뀌는 것은 하나뿐이다. 내 정보 저장(profile_update)에서 '소속 회사명 2~80자' 조건을 건너뛰는 예외가
--   지금은 대표(owner)에게만 있는데, 여기에 '등록된 소속이 없는 회원(company_id 없음 + company_name 빈 값)'을 더한다.
--   예외는 전과 같이 profile_update 이고 요청에 company_id·company_name 이 둘 다 없을 때만 적용된다(= 닉네임만 바꾸는 요청).
-- 그대로 두는 것: 닉네임 검사(2~20자·개인정보 금지), 소속을 넣거나 바꾸는 요청의 회사명 검사, 이미 소속이 있는 회원의 처리,
--   인증 상태(소속이 그대로이므로 status 는 바뀌지 않는다), 정지·탈퇴 회원 차단, 인증 신청(profile_submit·profile_precheck),
--   글·댓글에 보이는 이름(인증 전에는 계속 '소속 미확인 · 닉***').
--
-- 방식(029와 같음): 운영 DB의 함수 본문은 저장소 SQL과 다를 수 있으므로 통째로 덮어쓰지 않는다.
--   실제 정의(pg_get_functiondef)를 읽어, 내 정보 저장 구간 안에 예전 조건문이 정확히 한 번 있을 때만 그 한 줄을 바꾼다.
--   문맥이 다르면 아무것도 바꾸지 않고 중단한다(DO 블록 하나 = 전부 아니면 전무). 이미 적용된 상태에서 다시 실행하면 아무것도 하지 않는다.
-- 적용 전: 실제 정의를 따로 보관한다(비서작업기록/팀쿡/20261117_보라닉네임/db-before-030/).
-- 되돌리기: db/030_nickname_without_company_rollback.sql (같은 방식으로 그 한 줄만 원래대로).

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
  raise exception '030 중단: 필요한 함수가 없습니다.';
 end if;
 src := pg_get_functiondef(sig::regprocedure);
 n_branch := (length(src) - length(replace(src, branch, ''))) / length(branch);
 n_old := (length(src) - length(replace(src, old_gate, ''))) / length(old_gate);
 n_new := (length(src) - length(replace(src, new_gate, ''))) / length(new_gate);

 if n_old = 0 and n_new = 1 then
  raise notice '030: 이미 적용되어 있습니다. 변경 없음.';
  return;
 end if;
 if n_branch <> 1 or n_old <> 1 or n_new <> 0 then
  raise exception '030 중단: 내 정보 저장 구간 문맥이 예상과 다릅니다(branch=%, old=%, new=%). 아무것도 바꾸지 않았습니다.', n_branch, n_old, n_new;
 end if;
 -- 바꿀 조건문이 내 정보 저장 구간 안, 그것도 구간의 맨 바깥 단계에 있어야 한다.
 pos_branch := position(branch in src);
 pos_gate := position(old_gate in src);
 if pos_gate < pos_branch then
  raise exception '030 중단: 조건문이 내 정보 저장 구간 시작보다 앞에 있습니다. 아무것도 바꾸지 않았습니다.';
 end if;
 -- 구간 시작과 조건문 사이: 다른 p_action 판정이나 return 이 없어야 하고(= 아직 같은 구간), 열린 if 가 모두 닫혀 있어야 한다(= 구간의 맨 바깥 단계).
 between_txt := lower(substr(src, pos_branch + length(branch), pos_gate - pos_branch - length(branch)));
 n_endif := (select count(*) from regexp_matches(between_txt, '\mend\s+if\M', 'g'));
 n_if := (select count(*) from regexp_matches(between_txt, '\mif\M', 'g')) - n_endif;
 if between_txt ~ '(p_action|\mreturn\M)' or n_if <> n_endif then
  raise exception '030 중단: 조건문이 내 정보 저장 구간의 예상 위치에 있지 않습니다. 아무것도 바꾸지 않았습니다.';
 end if;

 execute replace(src, old_gate, new_gate);

 src := pg_get_functiondef(sig::regprocedure);
 if (length(src) - length(replace(src, new_gate, ''))) / length(new_gate) <> 1 or position(old_gate in src) > 0 then
  raise exception '030 중단: 적용 뒤 확인에 실패했습니다. 되돌립니다.';
 end if;
 raise notice '030: 소속이 없는 회원도 닉네임만 저장할 수 있게 바꿨습니다.';
end
$$;

-- 확인용(읽기 전용): new_gate=1, old_gate=0 이면 적용된 상태.
select
 (length(d) - length(replace(d, '(public.bl_is_owner() or (pr.company_id is null and pr.company_name='''')) and p_action=''profile_update''', ''))) / length('(public.bl_is_owner() or (pr.company_id is null and pr.company_name='''')) and p_action=''profile_update''') as new_gate,
 (length(d) - length(replace(d, 'public.bl_require(((public.bl_is_owner() and p_action=''profile_update''', ''))) / length('public.bl_require(((public.bl_is_owner() and p_action=''profile_update''') as old_gate
from (select pg_get_functiondef('public.bl_action_internal(text,jsonb)'::regprocedure) as d) s;
