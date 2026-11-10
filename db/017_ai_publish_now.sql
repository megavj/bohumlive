-- 017: AI 참고답변 검수 없이 바로 공개 + DB측 개인정보 치환 제거 (대표 지시 2026-11-10)
CREATE OR REPLACE FUNCTION public.bl_worker(p_action text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
declare j public.bl_ai_jobs; s public.bl_settings; p public.bl_posts; pr public.bl_profiles; rp public.bl_reports; idv uuid; leasev uuid; txt text; tit text; emailv text; cnt int; paths jsonb; affected int:=0; authorv uuid; st text; summary jsonb; companyv uuid; companyname text; reasons jsonb;
begin
 perform public.bl_require(auth.role()='service_role','서버 처리기 전용 작업입니다.');
 idv:=nullif(p_payload->>'id','')::uuid; leasev:=nullif(p_payload->>'lease_token','')::uuid;
 if p_action='status' then return jsonb_build_object('ai_enabled',(select ai_enabled from public.bl_settings),'ai_daily_limit',(select ai_daily_limit from public.bl_settings),'queued',(select count(*) from public.bl_ai_jobs where status='queued'),'review',(select count(*) from public.bl_ai_jobs where status='review')); end if;
 if p_action='claim' then
  select * into s from public.bl_settings where id for update;
  select count(*) into cnt from public.bl_ai_runs where created_at>=date_trunc('day',now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
  if not s.ai_enabled or cnt>=s.ai_daily_limit then return jsonb_build_object('job',null,'enabled',s.ai_enabled,'remaining',greatest(0,s.ai_daily_limit-cnt)); end if;
  update public.bl_ai_jobs set status=case when attempts<3 then 'queued' else 'failed' end,error_code='LEASE_EXPIRED',lease_token=null,lease_until=null where status='processing' and lease_until<now();
  select q.* into j from public.bl_ai_jobs q join public.bl_posts pp on pp.id=q.post_id where q.status='queued' and pp.status='published' and pp.is_question and exists(select 1 from public.bl_channels ch where ch.id=pp.channel_id and ch.enabled) and exists(select 1 from public.bl_profiles pr where pr.id=pp.author_id and pr.status not in ('suspended','withdrawn')) order by q.created_at for update of q skip locked limit 1;
  if j.id is null then return jsonb_build_object('job',null,'enabled',s.ai_enabled,'remaining',s.ai_daily_limit-cnt); end if;
  select * into p from public.bl_posts where id=j.post_id;
  select * into pr from public.bl_profiles where id=p.author_id;
  select email into emailv from auth.users where id=p.author_id;
  txt:=p.body; tit:=p.title;
  leasev:=gen_random_uuid(); update public.bl_ai_jobs set status='processing',attempts=attempts+1,lease_token=leasev,lease_until=now()+interval '6 minutes',started_at=now(),source_updated_at=p.updated_at,error_code=null where id=j.id;
  insert into public.bl_ai_runs(job_id) values(j.id);
  return jsonb_build_object('job',jsonb_build_object('id',j.id,'post_id',j.post_id,'lease_token',leasev,'title',tit,'body',txt,'attempts',j.attempts+1),'enabled',true,'remaining',s.ai_daily_limit-cnt-1);
 elsif p_action='heartbeat' then
  update public.bl_ai_jobs set lease_until=now()+interval '6 minutes' where id=idv and status='processing' and lease_token=leasev and lease_until>now(); get diagnostics cnt=row_count; perform public.bl_require(cnt=1,'처리 임대가 만료되었습니다.'); return jsonb_build_object('ok',true);
 elsif p_action in ('complete','fail') then
  select * into j from public.bl_ai_jobs where id=idv and status='processing' and lease_token=leasev and lease_until>now() for update; perform public.bl_require(j.id is not null,'처리 임대가 만료되었습니다.');
  if p_action='fail' then
   txt:=coalesce(p_payload->>'error',p_payload->>'error_code','GENERATION_FAILED'); if txt !~ '^[A-Za-z0-9_]{1,80}$' then txt:='GENERATION_FAILED'; end if;
   update public.bl_ai_jobs set status=case when attempts<3 then 'queued' else 'failed' end,error_code=txt,lease_token=null,lease_until=null,completed_at=now() where id=idv; return jsonb_build_object('ok',true);
  end if;
  select * into p from public.bl_posts where id=j.post_id;
  perform public.bl_require(p.status='published' and p.is_question and p.updated_at=j.source_updated_at,'생성 중 원문이 변경되었거나 가려졌습니다.');
  txt:=btrim(coalesce(p_payload->>'body',p_payload->>'answer')); perform public.bl_require(length(txt) between 20 and 15000 and public.bl_safe_text(txt),'AI 답변에 금지 정보가 있거나 길이가 잘못되었습니다.');
  insert into public.bl_ai_replies(post_id,body,status,model) values(j.post_id,txt,'published',left(coalesce(p_payload->>'model','claude'),80)) on conflict(post_id) do update set body=excluded.body,status='published',model=excluded.model,created_at=now();
  update public.bl_ai_jobs set status='complete',lease_token=null,lease_until=null,completed_at=now() where id=idv;
  perform public.bl_log('ai_generated_published','post',j.post_id::text); return jsonb_build_object('ok',true,'status','published');
 elsif p_action in ('cleanup_list','maintenance') then
  insert into public.bl_proof_cleanup(path,user_id,due_at) select proof_path,id,proof_processed_at+interval '30 days' from public.bl_profiles where proof_path is not null and proof_processed_at is not null on conflict do nothing;
  -- 신청하지 않고 남긴 파일도 24시간 뒤 지운다.
  insert into public.bl_proof_cleanup(path,user_id,due_at) select o.name,split_part(o.name,'/',1)::uuid,o.created_at+interval '24 hours' from storage.objects o where o.bucket_id='bl-proofs' and o.created_at<now()-interval '24 hours' and split_part(o.name,'/',1) ~ '^[0-9a-f-]{36}$' and not exists(select 1 from public.bl_profiles p where p.proof_path=o.name) on conflict do nothing;
  select coalesce(jsonb_agg(path),'[]') into paths from public.bl_proof_cleanup where due_at<=now() and deleted_at is null;
  return jsonb_build_object('paths',paths,'proof_paths',paths);
 elsif p_action in ('cleanup_done','proof_deleted') then
  perform public.bl_require(jsonb_typeof(p_payload->'paths')='array','삭제 경로 목록이 필요합니다.');
  update public.bl_profiles set name='',phone='',registration_number='',proof_path=null,updated_at=now() where proof_path in (select value from jsonb_array_elements_text(p_payload->'paths')) and exists(select 1 from public.bl_proof_cleanup q where q.path=proof_path and q.due_at<=now());
  update public.bl_proof_cleanup set deleted_at=now() where path in (select value from jsonb_array_elements_text(p_payload->'paths')) and due_at<=now() and not exists(select 1 from storage.objects o where o.bucket_id='bl-proofs' and o.name=path);
  get diagnostics cnt=row_count; perform public.bl_log('proof_cleanup',null,null,jsonb_build_object('count',cnt)); return jsonb_build_object('ok',true,'count',cnt);
 elsif p_action='cleanup_users' then
  return jsonb_build_object('ids',(select coalesce(jsonb_agg(p.id),'[]') from public.bl_profiles p where p.status='withdrawn' and p.auth_deleted_at is null and not exists(select 1 from public.bl_proof_cleanup q where q.user_id=p.id and q.deleted_at is null) and not exists(select 1 from storage.objects o where o.bucket_id='bl-proofs' and split_part(o.name,'/',1)=p.id::text)));
 elsif p_action='cleanup_user_done' then
  perform public.bl_require(exists(select 1 from public.bl_profiles where id=idv and status='withdrawn') and not exists(select 1 from auth.users where id=idv),'인증 계정 삭제 완료를 확인할 수 없습니다.');
  update public.bl_profiles set auth_deleted_at=now() where id=idv and status='withdrawn'; perform public.bl_log('withdraw_auth_deleted','member',idv::text); return jsonb_build_object('ok',true);
 elsif p_action='proof_queue' then
  -- 자동 판정 대기: 제출된 증빙이 있고 아직 자동 판정을 하지 않은 신청(오래된 순 3건)
  return jsonb_build_object(
   'items',(select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'proof_path',x.proof_path,'name',x.name,'registration_number',x.registration_number,'company_id',x.company_id,'company_name',x.company_name) order by x.proof_submitted_at),'[]') from (select * from public.bl_profiles where status='pending' and proof_path is not null and auto_checked_at is null order by proof_submitted_at limit 3) x),
   'companies',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'name',c.name)),'[]') from public.bl_companies c where c.enabled));
 elsif p_action='proof_judgment' then
  select * into pr from public.bl_profiles where id=idv for update;
  perform public.bl_require(pr.id is not null and pr.status='pending' and pr.proof_path=(p_payload->>'proof_path') and pr.auto_checked_at is null,'판정 대상이 바뀌었습니다.');
  st:=p_payload->>'decision'; perform public.bl_require(st in ('approve','reject','hold'),'판정 결과를 확인해 주세요.');
  reasons:=coalesce((select jsonb_agg(value) from jsonb_array_elements_text(case when jsonb_typeof(p_payload->'reasons')='array' then p_payload->'reasons' else '[]'::jsonb end) value where value ~ '^[a-z_]{2,40}$'),'[]');
  if st='approve' then
   companyv:=coalesce(pr.company_id,nullif(p_payload->>'company_id','')::uuid);
   select name into companyname from public.bl_companies where id=companyv and enabled;
   -- 목록에 없는 회사는 새로 만들지 않고 관리자 확인으로 넘긴다.
   if companyname is null then st:='hold'; reasons:='["company_not_in_list"]'; end if;
  end if;
  -- 읽은 값 요약은 서버에서 한 번 더 줄인다(이름 첫 글자, 번호 끝 4자리).
  summary:=jsonb_build_object('decision',st,'by','자동 판정','at',now(),'reasons',reasons,
   'fields',jsonb_build_object('name',left(coalesce(p_payload#>>'{fields,name}',''),10),'number',left(coalesce(p_payload#>>'{fields,number}',''),10),'company',left(coalesce(p_payload#>>'{fields,company}',''),10)),
   'read',jsonb_build_object('name',case when coalesce(p_payload#>>'{read,name}','')<>'' then left(p_payload#>>'{read,name}',1)||'**' else '' end,
    'number_last4',right(regexp_replace(coalesce(p_payload#>>'{read,number_last4}',''),'[^0-9]','','g'),4),
    'company',left(coalesce(p_payload#>>'{read,company}',''),40)));
  if st='approve' then
   update public.bl_profiles set status='verified',company_id=companyv,company_name=companyname,verified_until=now()+interval '365 days',review_reason='증빙 사진을 자동으로 확인해 인증했습니다.',proof_processed_at=now(),auto_checked_at=now(),auto_result=summary,updated_at=now() where id=idv;
   insert into public.bl_proof_cleanup(path,user_id,due_at) values(pr.proof_path,idv,now()+interval '30 days') on conflict(path) do update set due_at=excluded.due_at;
   insert into public.bl_notifications(user_id,kind,title,body) values(idv,'verification','설계사 인증이 완료되었습니다','증빙 사진을 자동으로 확인해 인증을 완료했습니다. 이제 글·댓글·리뷰를 쓸 수 있어요.');
  elsif st='reject' then
   txt:=coalesce((select string_agg(case value when 'name' then '증빙 사진의 이름이 신청한 이름과 달라요' when 'number' then '증빙 사진의 설계사 고유번호가 신청한 번호와 달라요' when 'company' then '증빙 사진의 소속 회사가 신청한 회사와 달라요' end,', ') from jsonb_array_elements_text(reasons) value where value in ('name','number','company')),'증빙 사진의 내용이 신청 내용과 달라요');
   update public.bl_profiles set status='rejected',verified_until=null,review_reason=txt||'. 정보를 확인해 다시 신청해 주세요.',proof_processed_at=now(),auto_checked_at=now(),auto_result=summary,updated_at=now() where id=idv;
   insert into public.bl_proof_cleanup(path,user_id,due_at) values(pr.proof_path,idv,now()+interval '30 days') on conflict(path) do update set due_at=excluded.due_at;
   insert into public.bl_notifications(user_id,kind,title,body) values(idv,'verification','인증 신청이 반려되었습니다',txt||'. 정보를 확인해 다시 신청해 주세요. 잘못 판정되었다면 운영팀이 확인해 바로잡습니다.');
  else
   txt:=coalesce((select string_agg(case value when 'unreadable' then '사진의 글자를 읽지 못했어요' when 'ocr_failed' then '사진 글자인식이 실패했어요' when 'name_unknown' then '사진에서 이름을 찾지 못했어요' when 'name_unclear' then '이름이 비슷하지만 확실하지 않아요' when 'number_unknown' then '사진에서 14자리 고유번호를 찾지 못했어요' when 'number_unclear' then '고유번호가 한두 자리 달라 보여요' when 'company_unknown' then '사진에서 소속 회사를 찾지 못했어요' when 'company_unclear' then '소속 회사 이름을 확실히 비교하지 못했어요' when 'company_not_in_list' then '소속 회사가 회사 목록에 없어요(목록에 추가하거나 맞는 회사를 골라 승인)' end,', ') from jsonb_array_elements_text(reasons) value),'자동으로 판단하기 어려운 신청이에요');
   update public.bl_profiles set auto_checked_at=now(),auto_result=summary||jsonb_build_object('hold_text',txt),updated_at=now() where id=idv;
   insert into public.bl_notifications(user_id,kind,title,body) select a.user_id,'admin_todo','인증 신청 확인 필요 (자동 판정 보류)',txt||'. 관리자 화면의 인증 심사에서 확인해 주세요.' from public.bl_admins a join public.bl_profiles ap on ap.id=a.user_id where ap.status not in ('suspended','withdrawn') and (not pr.is_test or ap.is_test);
  end if;
  perform public.bl_log('auto_verification','member',idv::text,summary);
  return jsonb_build_object('ok',true,'decision',st);
 elsif p_action='temporary_review' then
  -- 기간 정지가 끝난 회원은 정지 전 상태로 돌린다(인증 기간이 지났으면 재인증 필요).
  for pr in select * from public.bl_profiles where status='suspended' and suspended_until is not null and suspended_until<=now() for update loop
   update public.bl_profiles set status=case when pr.previous_status='verified' and pr.verified_until>now() then 'verified' else 'unverified' end,suspended_until=null,review_reason='정지 기간이 끝났습니다.',updated_at=now() where id=pr.id;
   insert into public.bl_notifications(user_id,kind,title,body) values(pr.id,'status','이용 정지가 끝났습니다','정지 기간이 끝나 다시 이용할 수 있어요.');
   perform public.bl_log('suspension_expired','member',pr.id::text);
  end loop;
  for rp in select r.* from public.bl_reports r where r.status='pending' and r.temporary_until<=now() and case r.target when 'post' then exists(select 1 from public.bl_posts x where x.id=r.target_id and x.status='hidden' and x.temporary_until<=now()) when 'comment' then exists(select 1 from public.bl_comments x where x.id=r.target_id and x.status='hidden' and x.temporary_until<=now()) else exists(select 1 from public.bl_reviews x where x.id=r.target_id and x.status='hidden' and x.temporary_until<=now()) end order by r.created_at for update of r loop
   authorv:=null;
   if rp.target='post' then update public.bl_posts set status='published',temporary_until=null,updated_at=now() where id=rp.target_id and status='hidden' and temporary_until<=now() returning author_id into authorv;
   elsif rp.target='comment' then update public.bl_comments set status='published',temporary_until=null,updated_at=now() where id=rp.target_id and status='hidden' and temporary_until<=now() returning author_id into authorv;
   else update public.bl_reviews set status='published',temporary_until=null,updated_at=now() where id=rp.target_id and status='hidden' and temporary_until<=now() returning author_id into authorv; end if;
   update public.bl_reports set status='restored',decided_at=now(),decision_reason='30일 임시조치 기간 만료에 따른 자동 복구' where target=rp.target and target_id=rp.target_id and status='pending';
   insert into public.bl_notifications(user_id,kind,title,body) select distinct uid,'report','임시조치 기간이 종료되었습니다','30일 임시조치 기간이 끝나 해당 게시물을 복구했습니다. 추가 권리침해 소명이 필요한 경우 운영자에게 알려 주세요.' from unnest(array[rp.reporter_id,authorv]) uid where uid is not null;
   perform public.bl_log('temporary_expired_restore',rp.target,rp.target_id::text); affected:=affected+1;
  end loop;
  return jsonb_build_object('ok',true,'restored',affected);
 end if;
 raise exception '지원하지 않는 처리기 작업입니다.';
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
  perform public.bl_withdraw_user(u);
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
  perform public.bl_notify_admins('가려진 콘텐츠에 이의신청이 들어왔습니다',case targetv when 'post' then '글' when 'comment' then '댓글' else '리뷰' end||' 처리에 대한 이의신청: '||left(reasonv,200),case when targetv='post' then idv end,pr.is_test);
  insert into public.bl_notifications(user_id,kind,title,body) values(u,'appeal','이의신청이 접수되었습니다','운영자가 소명 내용을 검토하고 처리 결과를 알려드립니다.');
  return jsonb_build_object('ok',true);
 end if;
 if p_action='inquiry' then
  bodyv:=btrim(coalesce(p_payload->>'body','')); st:=coalesce(p_payload->>'kind','general');
  perform public.bl_require(st in ('general','privacy','rights','account') and length(bodyv) between 5 and 2000 and length(coalesce(p_payload->>'link',''))<=300,'문의 종류를 고르고 내용을 5자 이상 적어 주세요.');
  perform public.bl_require((select count(*) from public.bl_inquiries where user_id=u and created_at>now()-interval '24 hours')<5,'문의는 하루 5번까지 보낼 수 있어요.');
  insert into public.bl_inquiries(user_id,kind,body,link) values(u,st,bodyv,left(btrim(coalesce(p_payload->>'link','')),300)) returning id into idv;
  perform public.bl_notify_admins('운영팀 문의가 들어왔습니다',case st when 'privacy' then '[개인정보 요청] ' when 'rights' then '[권리침해] ' when 'account' then '[계정] ' else '[일반] ' end||left(bodyv,80),null,pr.is_test);
  perform public.bl_log('inquiry','inquiry',idv::text,jsonb_build_object('kind',st));
  return jsonb_build_object('ok',true,'id',idv);
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
   update public.bl_profiles set name=btrim(p_payload->>'name'),nickname=nickv,company_id=companyv,company_name=companyname,phone=btrim(p_payload->>'phone'),registration_number=regv,registration_digest=public.bl_registration_digest(regv),proof_path=pathv,proof_submitted_at=now(),proof_processed_at=null,status='pending',verified_until=null,review_reason='',auto_checked_at=null,auto_result=null,updated_at=now() where id=u;
   perform public.bl_log('profile_submit','member',u::text);
   perform public.bl_notify_admins('새 설계사 인증 신청이 들어왔습니다','증빙 사진을 자동으로 먼저 확인합니다. 보류되면 다시 알려 드려요. 관리자 화면의 인증 심사에서 볼 수 있어요.',null,pr.is_test);
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
  if op in ('verification','member_status','nickname','admin_role','proof_access','member_withdraw','report_block') then select * into oth from public.bl_profiles where id=idv for update; perform public.bl_require(oth.id is not null,'회원을 찾을 수 없습니다.'); end if;
  if op='verification' then
   st:=p_payload->>'status'; perform public.bl_require(st in ('verified','supplement','rejected'),'심사 상태를 확인해 주세요.');
   perform public.bl_require(oth.status not in ('withdrawn','suspended') and oth.proof_path is not null,'심사 가능한 증빙이 없습니다.');
   perform public.bl_require(st='verified' or length(reasonv)>=2,'보완 또는 반려 사유를 입력해 주세요.');
   companyv:=coalesce(oth.company_id,nullif(p_payload->>'company_id','')::uuid);
   if st='verified' then
    select name into companyname from public.bl_companies where id=companyv and enabled;
    perform public.bl_require(companyname is not null,'소속 회사를 목록에서 골라 연결해 주세요. 목록에 없으면 보험사·GA 관리에서 먼저 추가해 주세요.');
   end if;
   update public.bl_profiles set status=st,company_id=companyv,company_name=coalesce(companyname,company_name),verified_until=case when st='verified' then now()+interval '365 days' else null end,review_reason=reasonv,proof_processed_at=now(),updated_at=now() where id=idv;
   insert into public.bl_proof_cleanup(path,user_id,due_at) values(oth.proof_path,idv,now()+interval '30 days') on conflict(path) do update set due_at=excluded.due_at;
   insert into public.bl_notifications(user_id,kind,title,body) values(idv,'verification',case st when 'verified' then '설계사 인증이 완료되었습니다' when 'supplement' then '인증 자료 보완이 필요합니다' else '인증 신청이 반려되었습니다' end,reasonv);
  elsif op='member_status' then
   st:=p_payload->>'status'; perform public.bl_require(st in ('suspended','verified','unverified') and length(reasonv)>=2,'상태와 사유를 확인해 주세요.'); perform public.bl_require(oth.status<>'withdrawn','탈퇴 계정은 복구할 수 없습니다.');
   n:=case when st='suspended' then coalesce(nullif(p_payload->>'days','')::int,0) else 0 end; perform public.bl_require(n in (0,1,3,7,30,90,365),'정지 기간을 확인해 주세요.');
   perform public.bl_require(not exists(select 1 from public.bl_admins where user_id=idv and role='owner'),'대표 관리자는 정지할 수 없습니다.');
   perform public.bl_require(not exists(select 1 from public.bl_admins where user_id=idv) or public.bl_is_owner(),'관리자 상태 변경은 대표만 가능합니다.');
   if st='verified' then perform public.bl_require(oth.verified_until>now() and (oth.status='verified' or oth.previous_status='verified'),'유효한 인증이 없어 해제 후 재심사가 필요합니다.'); end if;
   update public.bl_profiles set previous_status=case when st='suspended' and status<>'suspended' then status else previous_status end,status=st,suspended_until=case when st='suspended' and n>0 then now()+make_interval(days=>n) end,review_reason=reasonv,updated_at=now() where id=idv;
   insert into public.bl_notifications(user_id,kind,title,body) values(idv,'status',case when st='suspended' then '이용이 정지되었습니다' else '회원 상태가 변경되었습니다' end,case when st='suspended' then case when n>0 then n||'일 동안 이용이 정지됩니다. ' else '' end||'사유: '||reasonv else reasonv end);
  elsif op='nickname' then
   nickv:=btrim(p_payload->>'nickname'); perform public.bl_require(length(nickv) between 2 and 20 and public.bl_safe_text(nickv) and length(reasonv)>=2,'닉네임과 변경 사유를 확인해 주세요.');
   update public.bl_profiles set nickname=nickv,updated_at=now() where id=idv;
   update public.bl_posts set author_nickname=nickv where author_id=idv and not anonymous; update public.bl_comments set author_nickname=nickv where author_id=idv and not anonymous; update public.bl_reviews set author_nickname=nickv where author_id=idv;
   insert into public.bl_notifications(user_id,kind,title,body) values(idv,'status','닉네임이 변경되었습니다',reasonv);
  elsif op='admin_role' then
   perform public.bl_require(public.bl_is_owner(),'관리자 지정과 회수는 대표만 가능합니다.'); perform public.bl_require(idv<>u and not exists(select 1 from public.bl_admins where user_id=idv and role='owner'),'대표 권한은 이 화면에서 변경할 수 없습니다.');
   perform public.bl_require(oth.status not in ('suspended','withdrawn') and p_payload->>'role' in ('admin','member') and length(reasonv)>=2,'대상 회원과 사유를 확인해 주세요.');
   if p_payload->>'role'='admin' then insert into public.bl_admins(user_id,role) values(idv,'admin') on conflict(user_id) do update set role='admin'; else delete from public.bl_admins where user_id=idv; end if;
  elsif op='member_withdraw' then
   perform public.bl_require(oth.status<>'withdrawn','이미 탈퇴한 회원입니다.');
   perform public.bl_require(not exists(select 1 from public.bl_admins where user_id=idv and role='owner'),'대표 관리자는 탈퇴시킬 수 없습니다.');
   perform public.bl_require(not exists(select 1 from public.bl_admins where user_id=idv) or public.bl_is_owner(),'관리자 강제 탈퇴는 대표만 할 수 있습니다.');
   perform public.bl_require(idv<>u and length(reasonv)>=2,'강제 탈퇴 사유를 입력해 주세요.');
   perform public.bl_withdraw_user(idv); st:='withdrawn';
  elsif op='report_block' then
   n:=coalesce(nullif(p_payload->>'days','')::int,-1); perform public.bl_require(n in (0,7,30,90,36500) and length(reasonv)>=2,'제한 기간과 사유를 확인해 주세요.');
   update public.bl_profiles set report_blocked_until=case when n>0 then now()+make_interval(days=>n) end,report_block_reason=case when n>0 then reasonv else '' end,updated_at=now() where id=idv;
   insert into public.bl_notifications(user_id,kind,title,body) values(idv,'status',case when n>0 then '신고 기능이 제한되었습니다' else '신고 기능 제한이 풀렸습니다' end,reasonv);
   st:=case when n>0 then 'report_blocked' else 'report_unblocked' end;
  elsif op='post_move' then
   targetv:='post'; destination:=nullif(p_payload->>'channel_id','')::uuid;
   perform public.bl_require(destination is not null and exists(select 1 from public.bl_channels where id=destination) and length(reasonv)>=2,'옮길 채널과 사유를 확인해 주세요.');
   select * into p from public.bl_posts where id=idv for update; perform public.bl_require(p.id is not null,'글을 찾을 수 없습니다.');
   perform public.bl_require(p.channel_id<>destination,'이미 그 채널에 있는 글이에요.');
   update public.bl_posts set channel_id=destination,updated_at=now() where id=idv;
   perform public.bl_anon_sync();
   st:=(select name from public.bl_channels where id=destination);
  elsif op='reveal_author' then
   targetv:=p_payload->>'target'; perform public.bl_require(targetv in ('post','comment') and length(reasonv)>=2,'확인 사유를 입력해 주세요.');
   if targetv='post' then select author_id into authorv from public.bl_posts where id=idv; else select author_id into authorv from public.bl_comments where id=idv; end if;
   perform public.bl_require(authorv is not null,'작성자를 찾을 수 없습니다.');
   perform public.bl_log('admin_reveal_author',targetv,idv::text,jsonb_build_object('reason',reasonv));
   return jsonb_build_object('ok',true,'author',(select jsonb_build_object('member_id',p.id,'nickname',p.nickname,'company_name',p.company_name,'status',p.status) from public.bl_profiles p where p.id=authorv));
  elsif op='inquiry_answer' then
   bodyv:=btrim(coalesce(p_payload->>'answer','')); perform public.bl_require(length(bodyv) between 2 and 2000,'답변을 2자 이상 적어 주세요.');
   update public.bl_inquiries set status='answered',answer=bodyv,answered_by=u,answered_at=now() where id=idv returning user_id into authorv;
   perform public.bl_require(authorv is not null,'문의를 찾을 수 없습니다.');
   insert into public.bl_notifications(user_id,kind,title,body) values(authorv,'inquiry','운영팀 문의 답변이 도착했습니다',bodyv);
   targetv:='inquiry'; st:='answered';
  elsif op='notice_order' then
   targetv:='post'; perform public.bl_require(p_payload->>'direction' in ('up','down'),'순서 방향을 확인해 주세요.');
   perform public.bl_require(exists(select 1 from public.bl_posts where id=idv and pinned and status<>'deleted'),'공지로 고정된 글만 순서를 바꿀 수 있습니다.');
   update public.bl_posts x set pinned_order=o.rn*10 from (select id,row_number() over (order by pinned_order,created_at desc) rn from public.bl_posts where pinned and status<>'deleted') o where x.id=o.id;
   select pinned_order into n from public.bl_posts where id=idv;
   select id into postv from public.bl_posts where pinned and status<>'deleted' and case when p_payload->>'direction'='up' then pinned_order<n else pinned_order>n end order by case when p_payload->>'direction'='up' then -pinned_order else pinned_order end limit 1;
   if postv is not null then update public.bl_posts set pinned_order=case when id=idv then (select pinned_order from public.bl_posts where id=postv) else n end where id in (idv,postv); end if;
   st:=p_payload->>'direction';
  elsif op='channel_move' then
   targetv:='channel'; perform public.bl_require(p_payload->>'direction' in ('up','down') and exists(select 1 from public.bl_channels where id=idv),'채널과 순서 방향을 확인해 주세요.');
   update public.bl_channels x set display_order=o.rn*10 from (select id,row_number() over (order by display_order,name) rn from public.bl_channels) o where x.id=o.id;
   select display_order into n from public.bl_channels where id=idv;
   select id into destination from public.bl_channels where case when p_payload->>'direction'='up' then display_order<n else display_order>n end order by case when p_payload->>'direction'='up' then -display_order else display_order end limit 1;
   if destination is not null then update public.bl_channels set display_order=case when id=idv then (select display_order from public.bl_channels where id=destination) else n end where id in (idv,destination); end if;
   st:=p_payload->>'direction';
  elsif op='ai_edit' then
   select post_id into postv from public.bl_ai_jobs where id=idv; perform public.bl_require(postv is not null,'AI 작업을 찾을 수 없습니다.');
   bodyv:=btrim(coalesce(p_payload->>'body','')); perform public.bl_require(length(bodyv) between 20 and 15000 and public.bl_safe_text(bodyv),'AI 답변은 개인정보 없이 20자 이상으로 고쳐 주세요.');
   update public.bl_ai_replies set body=bodyv where post_id=postv; get diagnostics n=row_count; perform public.bl_require(n>0,'고칠 AI 답변이 없습니다.');
   targetv:='ai'; st:='edited';
  elsif op in ('ai_retry','ai_regenerate') then
   select post_id into postv from public.bl_ai_jobs where id=idv; perform public.bl_require(postv is not null,'AI 작업을 찾을 수 없습니다.');
   perform public.bl_require(op='ai_regenerate' or exists(select 1 from public.bl_ai_jobs where id=idv and status in ('failed','skipped')),'실패하거나 반려된 작업만 다시 시도할 수 있습니다.');
   update public.bl_ai_replies set status='hidden' where post_id=postv and op='ai_regenerate';
   update public.bl_ai_jobs set status='queued',attempts=0,error_code=null,lease_token=null,lease_until=null,completed_at=null where id=idv;
   targetv:='ai'; st:='queued';
  elsif op='banned_words' then
   update public.bl_settings set banned_words=coalesce((select array_agg(distinct w order by w) from (select left(btrim(x),30) w from regexp_split_to_table(coalesce(p_payload->>'words',''),'[,\n]') x) z where w<>''),'{}') where id;
   perform public.bl_require(coalesce(array_length((select banned_words from public.bl_settings where id),1),0)<=300,'금칙어는 300개까지 정할 수 있습니다.');
   targetv:='settings'; st:='saved';
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
   if coalesce(p_payload->>'slug','')='' then
    p_payload:=p_payload||jsonb_build_object('slug',coalesce((select slug from public.bl_channels where id=idv),'ch-'||substr(md5(random()::text),1,6)));
   end if;
   perform public.bl_require(length(p_payload->>'name') between 2 and 40 and (p_payload->>'slug') ~ '^[a-z0-9-]{2,40}$','채널 이름과 영문 주소를 확인해 주세요.');
   idv:=coalesce(idv,gen_random_uuid()); insert into public.bl_channels(id,slug,name,description,display_order,enabled,anonymous,guest_full) values(idv,p_payload->>'slug',p_payload->>'name',left(coalesce(p_payload->>'description',''),500),coalesce((p_payload->>'display_order')::int,0),coalesce((p_payload->>'enabled')::boolean,true),coalesce((p_payload->>'anonymous')::boolean,false),coalesce((p_payload->>'guest_full')::boolean,(select x.guest_full from public.bl_channels x where x.id=idv),false)) on conflict(id) do update set slug=excluded.slug,name=excluded.name,description=excluded.description,display_order=excluded.display_order,enabled=excluded.enabled,anonymous=excluded.anonymous,guest_full=excluded.guest_full;
   perform public.bl_anon_sync();
  elsif op='company_save' then
   perform public.bl_require(length(p_payload->>'name') between 2 and 80 and p_payload->>'kind' in ('생명보험사','손해보험사','GA','보험사'),'회사 이름과 종류를 확인해 주세요.');
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
    perform public.bl_anon_sync();
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
  perform public.bl_log('admin_'||op,coalesce(targetv,'member'),idv::text,jsonb_strip_nulls(jsonb_build_object('reason',reasonv,'status',st,'role',p_payload->>'role','enabled',p_payload->'enabled','days',p_payload->'days')));
  return jsonb_build_object('ok',true,'id',idv);
 end if;
 if p_action='report' then
  targetv:=p_payload->>'target'; perform public.bl_require(targetv in ('post','comment','review') and length(reasonv) between 5 and 1000,'신고 대상과 사유를 5자 이상 입력해 주세요.');
  perform public.bl_require(public.bl_can_write() or public.bl_is_admin(),'신고는 설계사 인증을 마친 회원만 할 수 있어요.');
  perform public.bl_require(pr.report_blocked_until is null or pr.report_blocked_until<now(),'신고 기능이 제한된 계정입니다. 알림의 운영 안내를 확인해 주세요.');
  perform public.bl_require((select count(*)<10 from public.bl_reports where reporter_id=u and created_at>=date_trunc('day',now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'),'하루 신고 가능 횟수 10회를 초과했습니다.');
  perform public.bl_require(not exists(select 1 from public.bl_reports where reporter_id=u and target=targetv and target_id=idv and status='pending'),'이미 접수된 신고입니다.');
  activev:=false;
  if targetv='post' then select * into p from public.bl_posts where id=idv and status='published' and public.bl_test_visible(is_test) for update; authorv:=p.author_id; postv:=p.id; perform public.bl_require(p.id is not null,'신고할 게시물을 찾을 수 없습니다.');
   -- 공지·운영팀 글은 신고로 가려지지 않는다(신고는 관리자 검토 목록에 남는다).
   activev:=p.author_id is null or p.pinned or p.content_kind='weekly';
  elsif targetv='comment' then
   select c.* into cm from public.bl_comments c join public.bl_posts p on p.id=c.post_id where c.id=idv and c.status='published' and p.status='published' and public.bl_test_visible(c.is_test) for update of c; authorv:=cm.author_id; postv:=cm.post_id; perform public.bl_require(cm.id is not null,'댓글을 찾을 수 없습니다.');
  else select * into rv from public.bl_reviews where id=idv and status='published' and public.bl_test_visible(is_test) for update; authorv:=rv.author_id; perform public.bl_require(rv.id is not null,'리뷰를 찾을 수 없습니다.'); end if;
  perform public.bl_require(authorv is distinct from u,'내가 쓴 글은 신고할 수 없어요.');
  insert into public.bl_reports(reporter_id,target,target_id,reason) values(u,targetv,idv,reasonv);
  select count(distinct reporter_id) into n from public.bl_reports where target=targetv and target_id=idv and status='pending';
  if n>=3 and not activev then
   -- 서로 다른 회원 3명 이상이 신고하면 운영자 판단 전까지 최대 30일 임시로 가린다.
   if targetv='post' then update public.bl_posts set status='hidden',temporary_until=now()+interval '30 days',updated_at=now() where id=idv;
   elsif targetv='comment' then update public.bl_comments set status='hidden',temporary_until=now()+interval '30 days',updated_at=now() where id=idv;
   else update public.bl_reviews set status='hidden',temporary_until=now()+interval '30 days',updated_at=now() where id=idv; end if;
   update public.bl_reports set temporary_until=now()+interval '30 days' where target=targetv and target_id=idv and status='pending';
   insert into public.bl_notifications(user_id,kind,title,body,post_id) select distinct uid,'report','신고가 모여 임시로 가렸습니다','같은 콘텐츠에 신고가 여러 건 접수되어 최대 30일간 임시로 가렸습니다. 운영자가 검토해 복구하거나 가림을 유지합니다.',postv from (select reporter_id uid from public.bl_reports where target=targetv and target_id=idv and status='pending' union select authorv) q where uid is not null;
   perform public.bl_log('report_temporary_hide',targetv,idv::text,jsonb_build_object('until',now()+interval '30 days','reporters',n));
  else
   insert into public.bl_notifications(user_id,kind,title,body,post_id) values(u,'report','신고가 접수되었습니다','운영자가 검토한 뒤 결과를 알려 드려요. 같은 콘텐츠에 신고가 3건 이상 모이면 운영자 판단 전까지 임시로 가려집니다.',postv);
  end if;
  perform public.bl_notify_admins('새 신고가 접수되었습니다',case targetv when 'post' then '글' when 'comment' then '댓글' else '리뷰' end||' 신고 '||n||'건째'||case when n>=3 and not activev then ' · 임시로 가림' else '' end||' · '||left(reasonv,80),postv,coalesce(p.is_test,cm.is_test,rv.is_test,false));
  perform public.bl_log('report',targetv,idv::text,jsonb_build_object('reporters',n,'hidden',n>=3 and not activev,'protected',activev));
  return jsonb_build_object('ok',true,'hidden',n>=3 and not activev);
 end if;
 perform public.bl_require(public.bl_can_write() or (p_action='toggle' and p_payload->>'kind' in ('bookmark','follow')) or (p_action='post_save' and coalesce((p_payload->>'as_team')::boolean,false) and public.bl_is_admin()),case when p_action='toggle' then '좋아요는 설계사 인증을 마친 뒤 누를 수 있어요.' else '설계사 인증을 마친 뒤 이용할 수 있어요.' end);
 if p_action='post_save' then
  titlev:=btrim(p_payload->>'title'); bodyv:=btrim(p_payload->>'body'); st:=nullif(p_payload->>'content_kind','');
  perform public.bl_require(length(titlev) between 2 and 150 and length(bodyv) between 5 and 10000,'제목 2~150자, 본문 5~10000자로 입력해 주세요.'); perform public.bl_require(public.bl_safe_text(titlev||' '||bodyv),'주민번호·연락처·이메일 등 개인정보는 게시할 수 없습니다.');
  nickv:=public.bl_banned_hit(titlev||' '||bodyv); if nickv is not null then raise exception '금칙어(%)가 들어 있어요. 고쳐서 다시 올려 주세요.',nickv; end if;
  activev:=coalesce((p_payload->>'as_team')::boolean,false) and public.bl_is_admin();
  -- 2026-11-10 글 종류 자동: 화면이 보내지 않으면 ① 같은 채널에서 고치는 글은 원래 값 유지 ② 운영팀 이름 글은 전체 공개 ③ 그 밖에는 채널의 손님 공개 범위(guest_full)에 따른다.
  if st is null then
   if idv is not null then select x.content_kind into st from public.bl_posts x where x.id=idv and x.channel_id::text=p_payload->>'channel_id'; end if;
   if st is null and activev then st:='weekly'; end if;
   if st is null then select case when ch.guest_full then 'practice' else 'experience' end into st from public.bl_channels ch where ch.id::text=p_payload->>'channel_id'; end if;
   st:=coalesce(st,'experience');
  end if;
  if exists(select 1 from public.bl_channels where id=(p_payload->>'channel_id')::uuid and anonymous) or exists(select 1 from public.bl_posts where id=idv and anonymous) then companyv:=null; end if;
  perform public.bl_require(st in ('practice','career','experience','weekly') and (st<>'weekly' or public.bl_is_admin()),'글 유형을 확인해 주세요.');
  perform public.bl_require(exists(select 1 from public.bl_channels where id=(p_payload->>'channel_id')::uuid and enabled),'활성 채널을 선택해 주세요.');
  companyv:=nullif(p_payload->>'company_id','')::uuid; if companyv is not null then perform public.bl_require(exists(select 1 from public.bl_companies where id=companyv and enabled),'회사 태그를 확인해 주세요.'); end if;
  if idv is null then
   perform public.bl_require((select count(*)<10 from public.bl_posts where author_id=u and created_at>=date_trunc('day',now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'),'하루 글 작성 한도 10개를 초과했습니다.');
   perform public.bl_require(not exists(select 1 from public.bl_posts where author_id=u and created_at>now()-interval '60 seconds'),'글은 60초 간격으로 작성할 수 있습니다.');
   insert into public.bl_posts(author_id,channel_id,company_id,title,body,content_kind,is_question,author_company,author_nickname,is_test,is_sample,as_team,pinned) values(u,(p_payload->>'channel_id')::uuid,companyv,titlev,bodyv,st,coalesce((p_payload->>'is_question')::boolean,false),pr.company_name,pr.nickname,pr.is_test,pr.is_sample,activev,activev and coalesce((p_payload->>'pinned')::boolean,false)) returning id into idv;
   perform public.bl_anon_sync();
  else
   select * into p from public.bl_posts where id=idv for update; perform public.bl_require(p.author_id=u and p.status='published','본인의 공개 중인 글만 수정할 수 있습니다.');
   update public.bl_posts set channel_id=(p_payload->>'channel_id')::uuid,company_id=companyv,title=titlev,body=bodyv,content_kind=st,is_question=coalesce((p_payload->>'is_question')::boolean,false),as_team=case when public.bl_is_admin() then activev else as_team end,updated_at=now() where id=idv;
   perform public.bl_anon_sync();
   -- 수정 전 내용을 기반으로 만든 답변은 즉시 숨기고 다시 검수한다.
   -- 2026-11-10: AI 답변은 검수 없이 바로 공개 — 글 수정 시에도 숨기지 않음
  end if;
  if coalesce((p_payload->>'is_question')::boolean,false) then insert into public.bl_ai_jobs(post_id) values(idv) on conflict(post_id) do nothing; end if;
  return jsonb_build_object('ok',true,'id',idv);
 elsif p_action='post_delete' then
  update public.bl_posts set status='deleted',temporary_until=null,updated_at=now() where id=idv and author_id=u; get diagnostics n=row_count; perform public.bl_require(n>0,'본인 글만 삭제할 수 있습니다.'); return jsonb_build_object('ok',true);
 elsif p_action='comment_save' then
  bodyv:=btrim(p_payload->>'body'); perform public.bl_require(length(bodyv) between 1 and 3000 and public.bl_safe_text(bodyv),'댓글은 개인정보 없이 1~3000자로 입력해 주세요.');
  nickv:=public.bl_banned_hit(bodyv); if nickv is not null then raise exception '금칙어(%)가 들어 있어요. 고쳐서 다시 올려 주세요.',nickv; end if;
  postv:=(p_payload->>'post_id')::uuid; perform public.bl_require(exists(select 1 from public.bl_posts p join public.bl_channels c on c.id=p.channel_id where p.id=postv and p.status='published' and c.enabled and public.bl_test_visible(p.is_test)),'댓글을 달 수 없는 글입니다.');
  parentv:=nullif(p_payload->>'parent_id','')::uuid; if parentv is not null then perform public.bl_require(exists(select 1 from public.bl_comments where id=parentv and post_id=postv and parent_id is null and status='published'),'대댓글은 공개된 원댓글에 한 단계만 작성할 수 있습니다.'); end if;
  if idv is null then
   perform public.bl_require((select count(*)<50 from public.bl_comments where author_id=u and created_at>=date_trunc('day',now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'),'하루 댓글 작성 한도 50개를 초과했습니다.');
   perform public.bl_require(not exists(select 1 from public.bl_comments where author_id=u and created_at>now()-interval '10 seconds'),'댓글은 10초 간격으로 작성할 수 있습니다.');
   insert into public.bl_comments(post_id,author_id,parent_id,body,author_company,author_nickname,is_test,is_sample,anonymous)
    select postv,u,parentv,bodyv,case when pp.anonymous then '' else pr.company_name end,case when pp.anonymous then '' else pr.nickname end,pr.is_test,pr.is_sample,pp.anonymous from public.bl_posts pp where pp.id=postv returning id into idv;
   insert into public.bl_notifications(user_id,kind,title,body,post_id) select uid,'comment',case when uid=(select author_id from public.bl_posts where id=postv) then '내 글에 새 댓글이 달렸습니다' else '내 댓글에 답글이 달렸습니다' end,'글 보기를 눌러 확인해 주세요.',postv from (select author_id uid from public.bl_posts where id=postv union select author_id from public.bl_comments where id=parentv) q where uid is not null and uid<>u;
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
  nickv:=public.bl_banned_hit(titlev||' '||bodyv); if nickv is not null then raise exception '금칙어(%)가 들어 있어요. 고쳐서 다시 올려 주세요.',nickv; end if;
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
