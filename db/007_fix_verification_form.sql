-- 007 설계사 인증 신청 정리 (2026-11-09, TASK-FIX 2단계)
-- * 설계사 고유번호: 숫자 14자리 필수, 기존 회원과 중복이면 거부(탈퇴·반려·미인증 제외). 원번호는 심사 후 30일 정리 규칙을 그대로 따르고,
--   중복 검사에는 지워지지 않는 확인값(해시)만 남긴다. 탈퇴 시 확인값도 지운다.
-- * 고유번호·연락처를 주민번호로 오인하던 차단과 '주민번호는 받지 않습니다' 문구 삭제(글 본문 개인정보 차단은 유지).
-- * profile_precheck: 사진 올리기 전 입력 검사 + 남은 사진 칸 안내. proof_discard: 신청 실패 시 방금 올린 사진을 바로 정리 대상으로.
-- * 사진 한도 5장은 정리 예정 사진(교체된 예전 증빙·실패한 신청 사진)을 빼고 센다. 신청은 하루 5번까지.
-- * 겹치는 값(고유번호·채널 주소·회사 이름)은 영어 오류 대신 한국어로 안내.
begin;
alter table public.bl_profiles add column if not exists registration_digest text;
create or replace function public.bl_registration_digest(p text) returns text language sql immutable set search_path='' as $$
 select case when regexp_replace(coalesce(p,''),'[^0-9]','','g') ~ '^[0-9]{14}$' then encode(sha256(convert_to('bl-reg:'||regexp_replace(p,'[^0-9]','','g'),'UTF8')),'hex') end; $$;
revoke all on function public.bl_registration_digest(text) from public,anon,authenticated;
update public.bl_profiles set registration_digest=public.bl_registration_digest(registration_number) where registration_digest is null and registration_number<>'' and status<>'withdrawn';
create unique index if not exists bl_profiles_registration_unique on public.bl_profiles(registration_digest)
 where registration_digest is not null and status in ('pending','supplement','verified','suspended');

CREATE OR REPLACE FUNCTION public.bl_proof_upload_allowed(p_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare object_count int;
begin
 if auth.uid() is null or split_part(p_name,'/',1)<>auth.uid()::text or p_name !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$' then return false; end if;
 -- Storage INSERT 트랜잭션 동안 본인 프로필을 잠가 동시 업로드 수 검사를 직렬화한다.
 perform 1 from public.bl_profiles where id=auth.uid() and status not in ('withdrawn','suspended') for update;
 if not found then return false; end if;
 -- 정리 예정(교체된 예전 증빙·실패한 신청 사진)은 한도에서 뺀다.
 select count(*) into object_count from storage.objects o where o.bucket_id='bl-proofs' and split_part(o.name,'/',1)=auth.uid()::text and not exists(select 1 from public.bl_proof_cleanup q where q.path=o.name and q.deleted_at is null);
 return object_count<5;
end; $function$;

CREATE OR REPLACE FUNCTION public.bl_proof_quota_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_old_owner uuid; v_new_owner uuid; v_count integer;
begin
 if TG_OP in ('DELETE','UPDATE') and OLD.bucket_id='bl-proofs' then
  v_old_owner:=split_part(OLD.name,'/',1)::uuid;
 end if;
 if TG_OP in ('INSERT','UPDATE') and NEW.bucket_id='bl-proofs' then
  if NEW.name !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$' then
   raise exception using errcode='23514',message='증빙 파일 경로 형식이 올바르지 않습니다.';
  end if;
  v_new_owner:=split_part(NEW.name,'/',1)::uuid;
 end if;
 -- 다른 버킷 또는 같은 회원 폴더 안의 이름 변경은 객체 수를 바꾸지 않는다.
 if v_old_owner is not distinct from v_new_owner then
  if TG_OP='DELETE' then return OLD; else return NEW; end if;
 end if;
 if v_new_owner is not null then
  -- 사전 권한 검사 후 정지/탈퇴된 요청도 최종 쓰기에서 차단한다.
  perform 1 from public.bl_profiles where id=v_new_owner and status not in ('suspended','withdrawn') for update;
  if not found then
   raise exception using errcode='23514',message='증빙을 저장할 수 없는 회원 상태입니다.';
  end if;
  insert into public.bl_proof_counters(owner_id,object_count) values(v_new_owner,0) on conflict(owner_id) do nothing;
  update public.bl_proof_counters set object_count=object_count+1 where owner_id=v_new_owner;
  -- 위 프로필 잠금으로 같은 회원의 업로드는 한 줄로 처리된다. 정리 예정 사진(교체된 예전 증빙 등)은 한도에서 뺀다.
  select count(*) into v_count from storage.objects o where o.bucket_id='bl-proofs' and split_part(o.name,'/',1)=v_new_owner::text and not exists(select 1 from public.bl_proof_cleanup q where q.path=o.name and q.deleted_at is null);
  if v_count>5 then
   raise exception using errcode='23514',message='증빙 사진은 제출 전 사진을 포함해 5장까지 올릴 수 있습니다. 제출하지 않은 사진은 자동으로 정리됩니다.';
  end if;
 end if;
 if v_old_owner is not null then
  update public.bl_proof_counters set object_count=greatest(0,object_count-1) where owner_id=v_old_owner;
 end if;
 if TG_OP='DELETE' then return OLD; else return NEW; end if;
end; $function$;

CREATE OR REPLACE FUNCTION public.bl_action_internal(p_action text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
declare u uuid:=auth.uid(); pr public.bl_profiles; oth public.bl_profiles; p public.bl_posts; cm public.bl_comments; rv public.bl_reviews; rp public.bl_reports; idv uuid; parentv uuid; companyv uuid; companyname text; targetv text; op text; st text; reasonv text; bodyv text; titlev text; nickv text; pathv text; sc int[]; activev boolean; authorv uuid; postv uuid; oldproof text; n int; destination uuid; moved int; moved_reviews int; moved_members int; destination_name text; regv text; cname text;
begin
 perform public.bl_require(u is not null,'로그인이 필요합니다.'); perform public.bl_ensure_profile();
 -- Match company deletion's lock order, so a concurrent affiliation change cannot deadlock or retain a deleted company.
 if p_action in ('profile_submit','profile_update','profile_precheck') and nullif(p_payload->>'company_id','') is not null then
  perform 1 from public.bl_companies where id=(p_payload->>'company_id')::uuid and enabled for key share;
  perform public.bl_require(found,'소속 회사를 확인해 주세요.');
 end if;
 select * into pr from public.bl_profiles where id=u for update;
 perform public.bl_require(pr.status<>'withdrawn','탈퇴한 계정은 사용할 수 없습니다.');
 idv:=nullif(p_payload->>'id','')::uuid; reasonv:=left(coalesce(p_payload->>'reason',''),1000);
 if p_action='notification_read' then update public.bl_notifications set read_at=now() where user_id=u and (idv is null or id=idv); return jsonb_build_object('ok',true); end if;
 if p_action='withdraw' then
  perform public.bl_require(not public.bl_is_owner(),'대표 관리자 권한을 이전한 후 탈퇴할 수 있습니다.');
  if pr.proof_path is not null then insert into public.bl_proof_cleanup(path,user_id,due_at) values(pr.proof_path,u,now()) on conflict(path) do update set due_at=now(); end if;
  insert into public.bl_proof_cleanup(path,user_id,due_at) select name,u,now() from storage.objects where bucket_id='bl-proofs' and split_part(name,'/',1)=u::text on conflict(path) do update set due_at=now();
  update public.bl_profiles set status='withdrawn',name='',phone='',registration_number='',registration_digest=null,nickname='',company_id=null,company_name='',proof_path=null,proof_processed_at=now(),verified_until=null,review_reason='',updated_at=now() where id=u;
  delete from public.bl_admins where user_id=u; delete from public.bl_notifications where user_id=u; delete from public.bl_reactions where user_id=u;
  update public.bl_posts set author_company='',author_nickname='' where author_id=u; update public.bl_comments set author_company='',author_nickname='' where author_id=u; update public.bl_reviews set author_company='',author_nickname='' where author_id=u;
  perform public.bl_log('withdraw','member',u::text); return jsonb_build_object('ok',true);
 end if;
 if p_action='appeal' then
  targetv:=p_payload->>'target'; perform public.bl_require(targetv in ('post','comment','review') and length(reasonv) between 5 and 1000,'이의신청 사유를 5자 이상 입력해 주세요.');
  if targetv='post' then select author_id into authorv from public.bl_posts where id=idv and status='hidden';
  elsif targetv='comment' then select author_id into authorv from public.bl_comments where id=idv and status='hidden';
  else select author_id into authorv from public.bl_reviews where id=idv and status='hidden'; end if;
  perform public.bl_require(authorv=u,'본인의 가려진 콘텐츠만 이의신청할 수 있습니다.');
  perform public.bl_require(not exists(select 1 from public.bl_audit where actor_id=u and action='appeal' and target_id=idv::text and created_at>now()-interval '24 hours'),'같은 콘텐츠의 이의신청은 하루 1회 가능합니다.');
  perform public.bl_log('appeal',targetv,idv::text,jsonb_build_object('reason',reasonv));
  insert into public.bl_notifications(user_id,kind,title,body,post_id) select user_id,'appeal','게시물 처리 이의신청이 접수되었습니다',targetv||' / '||idv::text||' / '||reasonv,case when targetv='post' then idv end from public.bl_admins;
  insert into public.bl_notifications(user_id,kind,title,body) values(u,'appeal','이의신청이 접수되었습니다','운영자가 소명 내용을 검토하고 처리 결과를 알려드립니다.');
  return jsonb_build_object('ok',true);
 end if;
 if p_action='proof_discard' then
  pathv:=p_payload->>'proof_path';
  perform public.bl_require(split_part(coalesce(pathv,''),'/',1)=u::text and pathv is distinct from pr.proof_path,'정리할 사진을 확인해 주세요.');
  insert into public.bl_proof_cleanup(path,user_id,due_at) select o.name,u,now() from storage.objects o where o.bucket_id='bl-proofs' and o.name=pathv
   on conflict(path) do update set due_at=now() where public.bl_proof_cleanup.deleted_at is null;
  return jsonb_build_object('ok',true);
 end if;
 perform public.bl_require(pr.status<>'suspended','이용 정지 상태입니다.');
 if p_action in ('profile_submit','profile_update','profile_precheck') then
  nickv:=btrim(coalesce(p_payload->>'nickname',pr.nickname)); perform public.bl_require(length(nickv) between 2 and 20 and public.bl_safe_text(nickv),'닉네임은 개인정보 없이 2~20자로 입력해 주세요.');
  companyv:=case when p_payload ? 'company_id' then nullif(p_payload->>'company_id','')::uuid else pr.company_id end;
  if companyv is not null then select name into companyname from public.bl_companies where id=companyv and enabled; perform public.bl_require(companyname is not null,'소속 회사를 확인해 주세요.');
  else companyname:=btrim(coalesce(p_payload->>'company_name',pr.company_name)); end if;
  perform public.bl_require(((public.bl_is_owner() and p_action='profile_update' and not (p_payload ? 'company_id' or p_payload ? 'company_name')) or (length(companyname) between 2 and 80 and public.bl_safe_text(companyname))),'소속 회사명을 2~80자로 입력해 주세요.');
  if p_action in ('profile_submit','profile_precheck') then
   perform public.bl_require(length(btrim(coalesce(p_payload->>'name',''))) between 2 and 60 and (p_payload->>'name') !~ '[0-9]' and (p_payload->>'name') !~ '@','이름을 2~60자로 입력해 주세요(숫자·이메일 제외).');
   perform public.bl_require(coalesce(p_payload->>'phone','') ~ '^\+?[0-9 ()-]{8,20}$' and length(regexp_replace(p_payload->>'phone','[^0-9]','','g')) between 9 and 12,'연락처를 확인해 주세요. 예: 010-1234-5678');
   regv:=regexp_replace(coalesce(p_payload->>'registration_number',''),'[[:space:]-]','','g');
   perform public.bl_require(regv ~ '^[0-9]{14}$','설계사 고유번호는 숫자 14자리로 입력해 주세요.');
   perform public.bl_require(not exists(select 1 from public.bl_profiles x where x.registration_digest=public.bl_registration_digest(regv) and x.id<>u and x.status in ('pending','supplement','verified','suspended')),'이미 등록된 설계사 고유번호입니다.');
   perform public.bl_require((select count(*) from public.bl_audit where actor_id=u and action='profile_submit' and created_at>now()-interval '24 hours')<5,'인증 신청은 하루 5번까지 할 수 있어요. 내일 다시 시도해 주세요.');
  end if;
  if p_action='profile_precheck' then
   -- 제출하지 않고 남은 내 사진은 바로 정리 대상으로 돌린다(처리기가 2분 안에 지움).
   insert into public.bl_proof_cleanup(path,user_id,due_at) select o.name,u,now() from storage.objects o where o.bucket_id='bl-proofs' and split_part(o.name,'/',1)=u::text and o.name is distinct from pr.proof_path and o.created_at<now()-interval '10 minutes' and not exists(select 1 from public.bl_proof_cleanup q where q.path=o.name) on conflict do nothing;
   select count(*) into n from storage.objects o where o.bucket_id='bl-proofs' and split_part(o.name,'/',1)=u::text and not exists(select 1 from public.bl_proof_cleanup q where q.path=o.name and q.deleted_at is null);
   return jsonb_build_object('ok',true,'proof_slots_left',greatest(0,5-n),'cleaning',(select count(*) from public.bl_proof_cleanup q where q.user_id=u and q.deleted_at is null and q.due_at<=now()));
  end if;
  if p_action='profile_submit' then
   pathv:=p_payload->>'proof_path'; perform public.bl_require(split_part(pathv,'/',1)=u::text and exists(select 1 from storage.objects where bucket_id='bl-proofs' and name=pathv),'본인 증빙 사진 1장을 먼저 업로드해 주세요.');
   if pr.proof_path is not null and pr.proof_path<>pathv then insert into public.bl_proof_cleanup(path,user_id,due_at) values(pr.proof_path,u,now()+interval '30 days') on conflict do nothing; end if;
   delete from public.bl_proof_cleanup where path=pathv and deleted_at is null;
   update public.bl_profiles set name=btrim(p_payload->>'name'),nickname=nickv,company_id=companyv,company_name=companyname,phone=btrim(p_payload->>'phone'),registration_number=regv,registration_digest=public.bl_registration_digest(regv),proof_path=pathv,proof_submitted_at=now(),proof_processed_at=null,status='pending',verified_until=null,review_reason='',updated_at=now() where id=u;
   perform public.bl_log('profile_submit','member',u::text);
   return jsonb_build_object('ok',true,'status','pending');
  end if;
  st:=pr.status;
  if companyname<>pr.company_name or companyv is distinct from pr.company_id then
   st:='pending'; if pr.proof_path is not null then insert into public.bl_proof_cleanup(path,user_id,due_at) values(pr.proof_path,u,now()+interval '30 days') on conflict do nothing; end if;
   update public.bl_profiles set proof_path=null,proof_submitted_at=null,proof_processed_at=null,verified_until=null,review_reason='소속 변경 후 새 증빙 사진을 제출해 주세요.' where id=u;
  end if;
  update public.bl_profiles set nickname=nickv,company_id=companyv,company_name=companyname,status=st,updated_at=now() where id=u;
  return jsonb_build_object('ok',true,'status',st);
 end if;
 if p_action='admin' then
  perform public.bl_require(public.bl_is_admin(),'관리자 권한이 필요합니다.'); op:=p_payload->>'operation';
  if op in ('verification','member_status','nickname','admin_role','proof_access') then select * into oth from public.bl_profiles where id=idv for update; perform public.bl_require(oth.id is not null,'회원을 찾을 수 없습니다.'); end if;
  if op='verification' then
   st:=p_payload->>'status'; perform public.bl_require(st in ('verified','supplement','rejected'),'심사 상태를 확인해 주세요.');
   perform public.bl_require(oth.status not in ('withdrawn','suspended') and oth.proof_path is not null,'심사 가능한 증빙이 없습니다.');
   perform public.bl_require(st='verified' or length(reasonv)>=2,'보완 또는 반려 사유를 입력해 주세요.');
   companyv:=oth.company_id;
   if st='verified' and companyv is null then insert into public.bl_companies(name,kind) values(oth.company_name,'GA') on conflict(name) do update set name=excluded.name returning id into companyv; end if;
   update public.bl_profiles set status=st,company_id=companyv,verified_until=case when st='verified' then now()+interval '365 days' else null end,review_reason=reasonv,proof_processed_at=now(),updated_at=now() where id=idv;
   insert into public.bl_proof_cleanup(path,user_id,due_at) values(oth.proof_path,idv,now()+interval '30 days') on conflict(path) do update set due_at=excluded.due_at;
   insert into public.bl_notifications(user_id,kind,title,body) values(idv,'verification',case st when 'verified' then '설계사 인증이 완료되었습니다' when 'supplement' then '인증 자료 보완이 필요합니다' else '인증 신청이 반려되었습니다' end,reasonv);
  elsif op='member_status' then
   st:=p_payload->>'status'; perform public.bl_require(st in ('suspended','verified','unverified') and length(reasonv)>=2,'상태와 사유를 확인해 주세요.'); perform public.bl_require(oth.status<>'withdrawn','탈퇴 계정은 복구할 수 없습니다.');
   perform public.bl_require(not exists(select 1 from public.bl_admins where user_id=idv and role='owner'),'대표 관리자는 정지할 수 없습니다.');
   perform public.bl_require(not exists(select 1 from public.bl_admins where user_id=idv) or public.bl_is_owner(),'관리자 상태 변경은 대표만 가능합니다.');
   if st='verified' then perform public.bl_require(oth.verified_until>now() and (oth.status='verified' or oth.previous_status='verified'),'유효한 인증이 없어 해제 후 재심사가 필요합니다.'); end if;
   update public.bl_profiles set previous_status=case when st='suspended' then status else previous_status end,status=st,review_reason=reasonv,updated_at=now() where id=idv;
   insert into public.bl_notifications(user_id,kind,title,body) values(idv,'status','회원 상태가 변경되었습니다',reasonv);
  elsif op='nickname' then
   nickv:=btrim(p_payload->>'nickname'); perform public.bl_require(length(nickv) between 2 and 20 and public.bl_safe_text(nickv) and length(reasonv)>=2,'닉네임과 변경 사유를 확인해 주세요.');
   update public.bl_profiles set nickname=nickv,updated_at=now() where id=idv;
   update public.bl_posts set author_nickname=nickv where author_id=idv; update public.bl_comments set author_nickname=nickv where author_id=idv; update public.bl_reviews set author_nickname=nickv where author_id=idv;
   insert into public.bl_notifications(user_id,kind,title,body) values(idv,'status','닉네임이 변경되었습니다',reasonv);
  elsif op='admin_role' then
   perform public.bl_require(public.bl_is_owner(),'관리자 지정과 회수는 대표만 가능합니다.'); perform public.bl_require(idv<>u and not exists(select 1 from public.bl_admins where user_id=idv and role='owner'),'대표 권한은 이 화면에서 변경할 수 없습니다.');
   perform public.bl_require(oth.status not in ('suspended','withdrawn') and p_payload->>'role' in ('admin','member') and length(reasonv)>=2,'대상 회원과 사유를 확인해 주세요.');
   if p_payload->>'role'='admin' then insert into public.bl_admins(user_id,role) values(idv,'admin') on conflict(user_id) do update set role='admin'; else delete from public.bl_admins where user_id=idv; end if;
  elsif op='proof_access' then
   perform public.bl_require(oth.proof_path is not null and length(reasonv)>=2,'열람 사유를 입력해 주세요.'); perform public.bl_log('proof_access','member',idv::text,jsonb_build_object('reason',reasonv)); return jsonb_build_object('ok',true,'path',oth.proof_path);
  elsif op='content' then
   targetv:=p_payload->>'target'; st:=p_payload->>'status'; perform public.bl_require(targetv in ('post','comment','review') and st in ('published','hidden','deleted') and length(reasonv)>=2,'콘텐츠 상태와 사유를 확인해 주세요.');
   if targetv='post' then update public.bl_posts set status=st,pinned=coalesce((p_payload->>'pinned')::boolean,pinned),temporary_until=null,updated_at=now() where id=idv returning author_id into authorv;
   elsif targetv='comment' then update public.bl_comments set status=st,temporary_until=null,updated_at=now() where id=idv returning author_id into authorv;
   else update public.bl_reviews set status=st,temporary_until=null,updated_at=now() where id=idv returning author_id into authorv; end if;
   get diagnostics n=row_count; perform public.bl_require(n>0,'콘텐츠를 찾을 수 없습니다.');
   update public.bl_reports set status=case when st='published' then 'restored' else 'maintained' end,decided_by=u,decided_at=now(),decision_reason=reasonv where target=targetv and target_id=idv and status='pending';
   if authorv is not null then insert into public.bl_notifications(user_id,kind,title,body) values(authorv,'moderation','게시물 처리 결과 안내',reasonv); end if;
  elsif op='report_resolve' then
   select * into rp from public.bl_reports where id=idv for update; perform public.bl_require(rp.id is not null and p_payload->>'decision' in ('restore','maintain') and length(reasonv)>=2,'신고 판단과 사유를 입력해 주세요.');
   st:=case when p_payload->>'decision'='restore' then 'published' else 'hidden' end;
   if rp.target='post' then update public.bl_posts set status=st,temporary_until=null,updated_at=now() where id=rp.target_id and status<>'deleted' returning author_id into authorv;
   elsif rp.target='comment' then update public.bl_comments set status=st,temporary_until=null,updated_at=now() where id=rp.target_id and status<>'deleted' returning author_id into authorv;
   else update public.bl_reviews set status=st,temporary_until=null,updated_at=now() where id=rp.target_id and status<>'deleted' returning author_id into authorv; end if;
   update public.bl_reports set status=case when st='published' then 'restored' else 'maintained' end,decided_by=u,decided_at=now(),decision_reason=reasonv where target=rp.target and target_id=rp.target_id and status='pending';
   insert into public.bl_notifications(user_id,kind,title,body) select distinct uid,'report','신고 처리 결과 안내',case when st='published' then '검토 후 복구: ' else '운영정책 위반으로 가림 유지: ' end||reasonv from unnest(array[rp.reporter_id,authorv]) uid where uid is not null;
  elsif op='channel_save' then
   perform public.bl_require(length(p_payload->>'name') between 2 and 40 and (p_payload->>'slug') ~ '^[a-z0-9-]{2,40}$','채널 이름과 영문 주소를 확인해 주세요.');
   idv:=coalesce(idv,gen_random_uuid()); insert into public.bl_channels(id,slug,name,description,display_order,enabled) values(idv,p_payload->>'slug',p_payload->>'name',left(coalesce(p_payload->>'description',''),500),coalesce((p_payload->>'display_order')::int,0),coalesce((p_payload->>'enabled')::boolean,true)) on conflict(id) do update set slug=excluded.slug,name=excluded.name,description=excluded.description,display_order=excluded.display_order,enabled=excluded.enabled;
  elsif op='company_save' then
   perform public.bl_require(length(p_payload->>'name') between 2 and 80 and p_payload->>'kind' in ('보험사','GA'),'회사 이름과 유형을 확인해 주세요.');
   idv:=coalesce(idv,gen_random_uuid()); insert into public.bl_companies(id,name,kind,description,enabled) values(idv,p_payload->>'name',p_payload->>'kind',left(coalesce(p_payload->>'description',''),1000),coalesce((p_payload->>'enabled')::boolean,true)) on conflict(id) do update set name=excluded.name,kind=excluded.kind,description=excluded.description,enabled=excluded.enabled;
   update public.bl_profiles set company_name=p_payload->>'name',updated_at=now() where company_id=idv;
  elsif op='channel_delete' then
   perform public.bl_require(exists(select 1 from public.bl_channels where id=idv),'삭제할 채널을 찾을 수 없습니다.');
   perform 1 from public.bl_channels where id=idv for update;
   destination:=nullif(p_payload->>'target_channel_id','')::uuid;
   select count(*) into moved from public.bl_posts where channel_id=idv;
   if destination is not null then
    perform public.bl_require(destination<>idv,'서로 다른 채널을 선택해 주세요.');
    perform 1 from public.bl_channels where id=destination and enabled for update;
    perform public.bl_require(found,'이동할 활성 채널을 선택해 주세요.');
   end if;
   perform public.bl_require(moved=0 or destination is not null,'글이 있는 채널은 글을 옮길 채널을 선택해 주세요.');
   if destination is not null then
    update public.bl_posts set channel_id=destination,updated_at=now() where channel_id=idv;
    insert into public.bl_reactions(user_id,target,target_id,kind,created_at)
     select user_id,'channel',destination,'follow',created_at from public.bl_reactions where target='channel' and target_id=idv and kind='follow' on conflict do nothing;
   end if;
   delete from public.bl_reactions where target='channel' and target_id=idv;
   delete from public.bl_channels where id=idv;
   perform public.bl_log('admin_channel_delete','channel',idv::text,jsonb_build_object('reason',reasonv,'target_channel_id',destination,'moved_posts',moved));
   if moved>0 then perform public.bl_log('admin_channel_move','channel',idv::text,jsonb_build_object('target_channel_id',destination,'moved_posts',moved)); end if;
   return jsonb_build_object('ok',true,'id',idv,'moved_posts',moved);
  elsif op='company_delete' then
   perform public.bl_require(exists(select 1 from public.bl_companies where id=idv),'삭제할 회사를 찾을 수 없습니다.');
   perform 1 from public.bl_companies where id=idv for update;
   destination:=nullif(p_payload->>'target_company_id','')::uuid;
   select count(*) into moved from public.bl_posts where company_id=idv;
   select count(*) into moved_reviews from public.bl_reviews where company_id=idv;
   select count(*) into moved_members from public.bl_profiles where company_id=idv;
   if destination is not null then
    perform public.bl_require(destination<>idv,'서로 다른 회사를 선택해 주세요.');
    select name into destination_name from public.bl_companies where id=destination and enabled for update;
    perform public.bl_require(found,'병합할 활성 회사를 선택해 주세요.');
   end if;
   perform public.bl_require(moved+moved_reviews+moved_members=0 or destination is not null,'연결된 글·리뷰·회원이 있어 병합할 회사를 선택해 주세요.');
   if destination is not null then
    update public.bl_posts set company_id=destination,updated_at=now() where company_id=idv;
    update public.bl_reviews set company_id=destination,updated_at=now() where company_id=idv;
    update public.bl_profiles set company_id=destination,company_name=destination_name,updated_at=now() where company_id=idv;
   end if;
   delete from public.bl_companies where id=idv;
   perform public.bl_log('admin_company_delete','company',idv::text,jsonb_build_object('reason',reasonv,'target_company_id',destination,'moved_posts',moved,'moved_reviews',moved_reviews,'moved_members',moved_members));
   if destination is not null then perform public.bl_log('admin_company_merge','company',idv::text,jsonb_build_object('target_company_id',destination,'moved_posts',moved,'moved_reviews',moved_reviews,'moved_members',moved_members)); end if;
   return jsonb_build_object('ok',true,'id',idv,'moved_posts',moved,'moved_reviews',moved_reviews,'moved_members',moved_members);
  elsif op='ai_settings' then
   update public.bl_settings set ai_enabled=(p_payload->>'enabled')::boolean,ai_daily_limit=least(30,greatest(0,coalesce((p_payload->>'daily_limit')::int,ai_daily_limit))) where id=true;
  elsif op in ('ai_publish','ai_reject') then
   select post_id into postv from public.bl_ai_jobs where id=idv; perform public.bl_require(postv is not null,'AI 작업을 찾을 수 없습니다.');
   update public.bl_ai_replies set status=case when op='ai_publish' then 'published' else 'hidden' end where post_id=postv;
   update public.bl_ai_jobs set status=case when op='ai_publish' then 'complete' else 'skipped' end where id=idv;
  else raise exception '지원하지 않는 관리자 작업입니다.'; end if;
  perform public.bl_log('admin_'||op,coalesce(targetv,'member'),idv::text,jsonb_build_object('reason',reasonv,'status',st,'role',p_payload->>'role','enabled',p_payload->'enabled'));
  return jsonb_build_object('ok',true,'id',idv);
 end if;
 if p_action='report' then
  targetv:=p_payload->>'target'; perform public.bl_require(targetv in ('post','comment','review') and length(reasonv) between 5 and 1000,'신고 대상과 사유를 5자 이상 입력해 주세요.');
  perform public.bl_require((select count(*)<10 from public.bl_reports where reporter_id=u and created_at>=date_trunc('day',now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'),'하루 신고 가능 횟수 10회를 초과했습니다.');
  perform public.bl_require(not exists(select 1 from public.bl_reports where reporter_id=u and target=targetv and target_id=idv and status='pending'),'이미 접수된 신고입니다.');
  if targetv='post' then select * into p from public.bl_posts where id=idv and status='published' and public.bl_test_visible(is_test) for update; authorv:=p.author_id; postv:=p.id; perform public.bl_require(p.id is not null,'신고할 게시물을 찾을 수 없습니다.'); update public.bl_posts set status='hidden',temporary_until=now()+interval '30 days',updated_at=now() where id=idv;
  elsif targetv='comment' then
   perform public.bl_require(public.bl_verified() or public.bl_is_admin(),'댓글 신고는 인증 회원만 가능합니다.'); select c.* into cm from public.bl_comments c join public.bl_posts p on p.id=c.post_id where c.id=idv and c.status='published' and p.status='published' and public.bl_test_visible(c.is_test) for update of c; authorv:=cm.author_id; postv:=cm.post_id; perform public.bl_require(cm.id is not null,'댓글을 찾을 수 없습니다.'); update public.bl_comments set status='hidden',temporary_until=now()+interval '30 days',updated_at=now() where id=idv;
  else select * into rv from public.bl_reviews where id=idv and status='published' and public.bl_test_visible(is_test) for update; authorv:=rv.author_id; perform public.bl_require(rv.id is not null,'리뷰를 찾을 수 없습니다.'); update public.bl_reviews set status='hidden',temporary_until=now()+interval '30 days',updated_at=now() where id=idv; end if;
  insert into public.bl_reports(reporter_id,target,target_id,reason) values(u,targetv,idv,reasonv);
  insert into public.bl_notifications(user_id,kind,title,body,post_id) select distinct uid,'report','신고 접수 및 임시 가림 안내','권리침해 신고가 접수되어 최대 30일간 임시로 가렸습니다. 운영자가 사유를 검토해 복구 또는 최종 가림을 결정합니다. 사유: '||reasonv,postv from unnest(array[u,authorv]) uid where uid is not null;
  perform public.bl_log('report_temporary_hide',targetv,idv::text,jsonb_build_object('until',now()+interval '30 days')); return jsonb_build_object('ok',true);
 end if;
 perform public.bl_require(public.bl_can_write(),'설계사 인증 완료 후 이용할 수 있습니다.');
 if p_action='post_save' then
  titlev:=btrim(p_payload->>'title'); bodyv:=btrim(p_payload->>'body'); st:=p_payload->>'content_kind';
  perform public.bl_require(length(titlev) between 2 and 150 and length(bodyv) between 5 and 10000,'제목 2~150자, 본문 5~10000자로 입력해 주세요.'); perform public.bl_require(public.bl_safe_text(titlev||' '||bodyv),'주민번호·연락처·이메일 등 개인정보는 게시할 수 없습니다.');
  perform public.bl_require(st in ('practice','career','experience','weekly') and (st<>'weekly' or public.bl_is_admin()),'글 유형을 확인해 주세요.');
  perform public.bl_require(exists(select 1 from public.bl_channels where id=(p_payload->>'channel_id')::uuid and enabled),'활성 채널을 선택해 주세요.');
  companyv:=nullif(p_payload->>'company_id','')::uuid; if companyv is not null then perform public.bl_require(exists(select 1 from public.bl_companies where id=companyv and enabled),'회사 태그를 확인해 주세요.'); end if;
  if idv is null then
   perform public.bl_require((select count(*)<10 from public.bl_posts where author_id=u and created_at>=date_trunc('day',now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'),'하루 글 작성 한도 10개를 초과했습니다.');
   perform public.bl_require(not exists(select 1 from public.bl_posts where author_id=u and created_at>now()-interval '60 seconds'),'글은 60초 간격으로 작성할 수 있습니다.');
   insert into public.bl_posts(author_id,channel_id,company_id,title,body,content_kind,is_question,author_company,author_nickname,is_test,is_sample) values(u,(p_payload->>'channel_id')::uuid,companyv,titlev,bodyv,st,coalesce((p_payload->>'is_question')::boolean,false),pr.company_name,pr.nickname,pr.is_test,pr.is_sample) returning id into idv;
  else
   select * into p from public.bl_posts where id=idv for update; perform public.bl_require(p.author_id=u and p.status='published','본인의 공개 중인 글만 수정할 수 있습니다.');
   update public.bl_posts set channel_id=(p_payload->>'channel_id')::uuid,company_id=companyv,title=titlev,body=bodyv,content_kind=st,is_question=coalesce((p_payload->>'is_question')::boolean,false),updated_at=now() where id=idv;
   -- 수정 전 내용을 기반으로 만든 답변은 즉시 숨기고 다시 검수한다.
   update public.bl_ai_replies set status='review' where post_id=idv;
  end if;
  if coalesce((p_payload->>'is_question')::boolean,false) then insert into public.bl_ai_jobs(post_id) values(idv) on conflict(post_id) do nothing; end if;
  return jsonb_build_object('ok',true,'id',idv);
 elsif p_action='post_delete' then
  update public.bl_posts set status='deleted',temporary_until=null,updated_at=now() where id=idv and author_id=u; get diagnostics n=row_count; perform public.bl_require(n>0,'본인 글만 삭제할 수 있습니다.'); return jsonb_build_object('ok',true);
 elsif p_action='comment_save' then
  bodyv:=btrim(p_payload->>'body'); perform public.bl_require(length(bodyv) between 1 and 3000 and public.bl_safe_text(bodyv),'댓글은 개인정보 없이 1~3000자로 입력해 주세요.');
  postv:=(p_payload->>'post_id')::uuid; perform public.bl_require(exists(select 1 from public.bl_posts p join public.bl_channels c on c.id=p.channel_id where p.id=postv and p.status='published' and c.enabled and public.bl_test_visible(p.is_test)),'댓글을 달 수 없는 글입니다.');
  parentv:=nullif(p_payload->>'parent_id','')::uuid; if parentv is not null then perform public.bl_require(exists(select 1 from public.bl_comments where id=parentv and post_id=postv and parent_id is null and status='published'),'대댓글은 공개된 원댓글에 한 단계만 작성할 수 있습니다.'); end if;
  if idv is null then
   perform public.bl_require((select count(*)<50 from public.bl_comments where author_id=u and created_at>=date_trunc('day',now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'),'하루 댓글 작성 한도 50개를 초과했습니다.');
   perform public.bl_require(not exists(select 1 from public.bl_comments where author_id=u and created_at>now()-interval '10 seconds'),'댓글은 10초 간격으로 작성할 수 있습니다.');
   insert into public.bl_comments(post_id,author_id,parent_id,body,author_company,author_nickname,is_test,is_sample) values(postv,u,parentv,bodyv,pr.company_name,pr.nickname,pr.is_test,pr.is_sample) returning id into idv;
   insert into public.bl_notifications(user_id,kind,title,body,post_id) select distinct uid,'comment','내 글에 새 댓글이 달렸습니다','인증 회원으로 로그인하여 댓글을 확인하세요.',postv from (select author_id uid from public.bl_posts where id=postv union select author_id from public.bl_comments where id=parentv) q where uid is not null and uid<>u;
  else update public.bl_comments set body=bodyv,updated_at=now() where id=idv and author_id=u and post_id=postv and status='published'; get diagnostics n=row_count; perform public.bl_require(n>0,'본인의 공개 중인 댓글만 수정할 수 있습니다.'); end if;
  return jsonb_build_object('ok',true,'id',idv);
 elsif p_action='comment_delete' then update public.bl_comments set status='deleted',temporary_until=null,updated_at=now() where id=idv and author_id=u; get diagnostics n=row_count; perform public.bl_require(n>0,'본인 댓글만 삭제할 수 있습니다.'); return jsonb_build_object('ok',true);
 elsif p_action='toggle' then
  targetv:=p_payload->>'target'; st:=p_payload->>'kind'; perform public.bl_require((targetv='post' and st in ('like','bookmark')) or (targetv='comment' and st='like') or (targetv='channel' and st='follow'),'지원하지 않는 반응입니다.');
  if targetv='post' then select * into p from public.bl_posts where id=idv and status='published' and public.bl_test_visible(is_test); perform public.bl_require(p.id is not null,'게시물을 찾을 수 없습니다.'); authorv:=p.author_id;
  elsif targetv='comment' then select c.* into cm from public.bl_comments c join public.bl_posts p on p.id=c.post_id where c.id=idv and c.status='published' and p.status='published' and public.bl_test_visible(c.is_test); perform public.bl_require(cm.id is not null,'댓글을 찾을 수 없습니다.'); authorv:=cm.author_id;
  else perform public.bl_require(exists(select 1 from public.bl_channels where id=idv and enabled),'채널을 찾을 수 없습니다.'); end if;
  perform public.bl_require(st<>'like' or authorv is distinct from u,'자신이 작성한 글에는 좋아요를 누를 수 없습니다.');
  delete from public.bl_reactions where user_id=u and target=targetv and target_id=idv and kind=st; get diagnostics n=row_count; activev:=n=0;
  if activev then insert into public.bl_reactions(user_id,target,target_id,kind) values(u,targetv,idv,st); end if; return jsonb_build_object('ok',true,'active',activev);
 elsif p_action='review_save' then
  companyv:=(p_payload->>'company_id')::uuid; perform public.bl_require((public.bl_is_owner() or (public.bl_verified() and companyv=pr.company_id)) and exists(select 1 from public.bl_companies where id=companyv and enabled),'인증 회원은 현재 소속 회사에만 리뷰를 작성할 수 있습니다.');
  select array_agg(value::int) into sc from jsonb_array_elements_text(p_payload->'scores'); perform public.bl_require(array_length(sc,1)=5 and 1<=all(sc) and 5>=all(sc),'별점 다섯 항목을 각각 1~5점으로 입력해 주세요.');
  titlev:=btrim(p_payload->>'title'); bodyv:=btrim(p_payload->>'body'); perform public.bl_require(length(titlev) between 2 and 150 and length(bodyv) between 10 and 5000 and public.bl_safe_text(titlev||' '||bodyv),'리뷰 제목·본문과 개인정보 포함 여부를 확인해 주세요.');
  if idv is null then
   perform public.bl_require(not exists(select 1 from public.bl_reviews where author_id=u and company_id=companyv and created_at>now()-interval '365 days'),'회사 리뷰는 365일에 1개만 작성할 수 있습니다. 기존 리뷰를 수정해 주세요.');
   insert into public.bl_reviews(author_id,company_id,title,body,scores,author_company,author_nickname,is_test,is_sample) values(u,companyv,titlev,bodyv,sc,pr.company_name,pr.nickname,pr.is_test,pr.is_sample) returning id into idv;
  else update public.bl_reviews set title=titlev,body=bodyv,scores=sc,updated_at=now() where id=idv and author_id=u and company_id=companyv and status='published'; get diagnostics n=row_count; perform public.bl_require(n>0,'본인의 공개 중인 리뷰만 수정할 수 있습니다.'); end if;
  return jsonb_build_object('ok',true,'id',idv);
 elsif p_action='review_delete' then update public.bl_reviews set status='deleted',temporary_until=null,updated_at=now() where id=idv and author_id=u; get diagnostics n=row_count; perform public.bl_require(n>0,'본인 리뷰만 삭제할 수 있습니다.'); return jsonb_build_object('ok',true);
 end if;
 raise exception '지원하지 않는 작업입니다.';
exception when unique_violation then
 get stacked diagnostics cname=constraint_name;
 raise exception '%',case cname when 'bl_profiles_registration_unique' then '이미 등록된 설계사 고유번호입니다.' when 'bl_channels_slug_key' then '같은 영문 주소를 쓰는 채널이 이미 있어요. 다른 이름으로 해 주세요.' when 'bl_companies_name_key' then '같은 이름의 회사가 이미 있어요.' else '이미 있는 값과 겹쳐요. 입력값을 확인해 주세요.' end;
end; $function$;

revoke all on function public.bl_action_internal(text,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.bl_proof_quota_guard() from public,anon,authenticated;
notify pgrst, 'reload schema';
commit;
