-- 032 보라 표시명 + 댓글 @보라 호출 (2026-11-22 이사님 승인, 팀쿡)
-- 범위: 모든 글(질문 여부·채널 무관)에서 회원 댓글의 '@보라 질문'에 보라가 답글로 답한다. 하루 제한 없음, @호출 답변은 글당 5회 상한에서 제외.
-- 원복: 032_bora_mention_rollback.sql
alter table public.bl_ai_jobs add column if not exists is_mention boolean not null default false;
alter table public.bl_comments add column if not exists ai_mention boolean not null default false;

-- '@보라'(뒤에 야·님·씨 허용) + 호출 표시를 뺀 실제 내용 2글자 이상일 때만 호출로 본다.
create or replace function public.bl_ai_is_mention(p_body text) returns boolean
 language sql immutable set search_path to '' as $f$
 select coalesce(p_body,'') ~ '(^|[^0-9A-Za-z가-힣_])@보라(야|님|씨)?($|[^0-9A-Za-z가-힣_])'
  and char_length(regexp_replace(regexp_replace(coalesce(p_body,''),'@보라(야|님|씨)?','','g'),'[[:space:][:punct:]]','','g'))>=2;
$f$;

create or replace function public.bl_ai_mention_enqueue(p_post uuid, p_comment uuid) returns boolean
 language plpgsql security definer set search_path to '' as $f$
declare p public.bl_posts;
begin
 select * into p from public.bl_posts where id=p_post for update;
 if p.id is null or p.status<>'published' or not coalesce((select ai_enabled from public.bl_settings where id),false)
  or not exists(select 1 from public.bl_channels where id=p.channel_id and enabled) then return false; end if;
 if not exists(select 1 from public.bl_comments q join public.bl_profiles pr on pr.id=q.author_id
   where q.id=p_comment and q.post_id=p_post and not q.is_ai and q.status='published'
    and pr.status not in ('suspended','withdrawn')) then return false; end if;
 insert into public.bl_ai_jobs(post_id,trigger_comment_id,is_mention) values(p_post,p_comment,true) on conflict do nothing;
 return found;
end; $f$;
revoke all on function public.bl_ai_mention_enqueue(uuid,uuid) from public, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.bl_ai_comment_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if new.is_ai then
  perform 1 from public.bl_posts where id=new.post_id for update;
  perform public.bl_require(new.ai_mention or (select count(*)<5 from public.bl_comments where post_id=new.post_id and is_ai and not ai_mention),'AI 답변은 글마다 다섯 번까지입니다.');
  perform public.bl_require(new.parent_id is null or exists(select 1 from public.bl_comments
   where id=new.parent_id and post_id=new.post_id and not is_ai and status='published'),'후속 질문을 확인해 주세요.');
 end if;
 return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.bl_ai_followup_enqueue()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not new.is_ai and new.status='published' then
  if public.bl_ai_is_mention(new.body) or (new.parent_id is not null and exists(select 1 from public.bl_comments
    where id=new.parent_id and post_id=new.post_id and is_ai and ai_mention)) then
   perform public.bl_ai_mention_enqueue(new.post_id,new.id);
  elsif new.parent_id is not null and exists(select 1 from public.bl_comments where id=new.parent_id and post_id=new.post_id and is_ai) then
   perform public.bl_ai_enqueue(new.post_id,new.id);
  end if;
 end if;
 return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.bl_ai_slots_used(p_post uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select ((select count(*) from public.bl_comments c where c.post_id=p_post and c.is_ai and not c.ai_mention)
 +(select count(*) from public.bl_ai_jobs j where j.post_id=p_post and j.comment_id is null and not j.is_mention
   and j.status in ('queued','processing','review')))::integer;
$function$;

CREATE OR REPLACE FUNCTION public.bl_ai_post_fields(p bl_posts)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select jsonb_build_object('ai_upgrade',true,'ai_reply_limit',5,
 'ai_reply_count',(select count(*) from public.bl_comments where post_id=p.id and is_ai and not ai_mention),
 'ai_followup_available',p.is_question and p.status='published' and public.bl_can_write()
  and (select ai_enabled from public.bl_settings where id) and public.bl_ai_slots_used(p.id)<5,
 'accepted_comment_id',case when public.bl_can_write() or public.bl_is_admin() then
  (select c.id from public.bl_comments c where c.id=p.accepted_comment_id and c.post_id=p.id
   and not c.is_ai and public.bl_ai_thread_visible(c.id)) end);
$function$;

CREATE OR REPLACE FUNCTION public.bl_ai_worker_upgrade(p_action text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j public.bl_ai_jobs; p public.bl_posts; q public.bl_comments; s public.bl_settings;
 candidate uuid; postv uuid; leasev uuid; cnt integer; txt text; tit text; contextv jsonb; peers jsonb;
 channelsv jsonb; commentv uuid; relatedv jsonb;
begin
 perform public.bl_require(auth.role()='service_role','서버 처리기 전용 작업입니다.');
 if p_action='claim' then
  select * into s from public.bl_settings where id for update;
  select count(*) into cnt from public.bl_ai_runs where created_at>=date_trunc('day',now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
  if not s.ai_enabled or cnt>=s.ai_daily_limit then return jsonb_build_object('job',null,'enabled',s.ai_enabled,'remaining',greatest(0,s.ai_daily_limit-cnt)); end if;
  -- 만료 복구도 post → job 순서를 지켜 완료/재생성과 교착하지 않는다.
  for candidate,postv in select id,post_id from public.bl_ai_jobs where status='processing' and lease_until<now() order by post_id,id
  loop
   perform 1 from public.bl_posts where id=postv for update skip locked;
   if not found then continue; end if;
   update public.bl_ai_jobs set status=case when attempts<3 then 'queued' else 'failed' end,error_code='LEASE_EXPIRED',lease_token=null,lease_until=null
    where id=candidate and status='processing' and lease_until<now();
  end loop;
  -- 1건 완료 동안 다른 글을 claim할 수 있다. 같은 글은 앞선 후속 답변 완료 후에 claim한다.
  for candidate,postv in select a.id,a.post_id from public.bl_ai_jobs a join public.bl_posts pp on pp.id=a.post_id
   where a.status='queued' and pp.status='published' and (pp.is_question or a.is_mention)
    and not exists(select 1 from public.bl_ai_jobs busy where busy.post_id=a.post_id and busy.status='processing')
    and exists(select 1 from public.bl_channels ch where ch.id=pp.channel_id and ch.enabled)
    and exists(select 1 from public.bl_profiles pr where pr.id=pp.author_id and pr.status not in ('suspended','withdrawn'))
   order by a.created_at,a.id limit 30
  loop
   select * into p from public.bl_posts where id=postv for update;
   select * into j from public.bl_ai_jobs where id=candidate and status='queued' for update skip locked;
   if j.id is null then continue; end if;
   if p.status<>'published' or not (p.is_question or j.is_mention)
    or not exists(select 1 from public.bl_channels where id=p.channel_id and enabled)
    or not exists(select 1 from public.bl_profiles where id=p.author_id and status not in ('suspended','withdrawn')) then
    update public.bl_ai_jobs set status='skipped',error_code=null,completed_at=now() where id=j.id; continue;
   end if;
   if j.comment_id is null and not j.is_mention and (select count(*) from public.bl_comments where post_id=p.id and is_ai and not ai_mention)>=5 then
    update public.bl_ai_jobs set status='skipped',error_code=null,completed_at=now() where id=j.id; continue;
   end if;
   if j.trigger_comment_id is not null then
    select c.* into q from public.bl_comments c join public.bl_profiles pr on pr.id=c.author_id
     where c.id=j.trigger_comment_id and c.post_id=p.id and not c.is_ai and public.bl_ai_thread_visible(c.id)
      and (pr.status not in ('suspended','withdrawn') or pr.status not in ('suspended','withdrawn')
       and exists(select 1 from public.bl_admins ad where ad.user_id=pr.id and ad.role='owner'));
    if q.id is null then update public.bl_ai_jobs set status='skipped',error_code=null,completed_at=now() where id=j.id; continue; end if;
   else q:=null; end if;
   leasev:=gen_random_uuid();
   update public.bl_ai_jobs set status='processing',attempts=attempts+1,lease_token=leasev,lease_until=now()+interval '6 minutes',
    started_at=now(),source_updated_at=p.updated_at,question_updated_at=q.updated_at,error_code=null where id=j.id;
   insert into public.bl_ai_runs(job_id) values(j.id);
   tit:=public.bl_ai_redact(p.title,p.author_id,p.author_company,p.author_nickname);
   txt:=public.bl_ai_redact(p.body,p.author_id,p.author_company,p.author_nickname);
   select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'parent_id',c.parent_id,'is_ai',c.is_ai,
    'is_accepted',coalesce(c.id=p.accepted_comment_id,false),
    'body',public.bl_ai_redact(public.bl_ai_redact(c.body,c.author_id,c.author_company,c.author_nickname),
     p.author_id,p.author_company,p.author_nickname)) order by c.created_at,c.id),'[]'::jsonb)
    into contextv from (select c.* from public.bl_comments c where c.post_id=p.id
     and public.bl_ai_thread_visible(c.id) and (c.is_ai or exists(select 1 from public.bl_comments pa where pa.id=c.parent_id and pa.is_ai)
      or c.id=q.parent_id or c.id=p.accepted_comment_id and not c.is_ai and not c.is_test and not c.is_sample and not c.anonymous
       and not p.is_test and not p.is_sample and not p.anonymous
       and exists(select 1 from public.bl_channels ch where ch.id=p.channel_id and not ch.anonymous and ch.enabled))
     and c.id is distinct from j.comment_id and (q.id is null or c.created_at<=q.created_at or c.is_ai or c.id=p.accepted_comment_id)
     order by (c.id=p.accepted_comment_id) desc nulls last,c.is_ai desc,c.created_at desc,c.id limit 50) c;
   peers:=public.bl_ai_peer_sources(p.id,tit||' '||left(txt,1200)||' '||public.bl_ai_redact(q.body,q.author_id,q.author_company,q.author_nickname));
   select coalesce(jsonb_agg(jsonb_build_object('id',ch.id,'name',ch.name) order by ch.display_order),'[]'::jsonb)
    into channelsv from public.bl_channels ch where ch.enabled and not ch.anonymous and ch.slug<>'notice';
   return jsonb_build_object('job',jsonb_build_object('id',j.id,'post_id',p.id,'lease_token',leasev,'title',tit,'body',txt,
    'attempts',j.attempts+1,'trigger_comment_id',j.trigger_comment_id,'comment_id',j.comment_id,
    'ai_reply_count',case when j.is_mention then 0 else (select count(*) from public.bl_comments where post_id=p.id and is_ai and not ai_mention) end,'ai_reply_limit',5,'is_mention',j.is_mention,
    'question',public.bl_ai_redact(public.bl_ai_redact(q.body,q.author_id,q.author_company,q.author_nickname),
     p.author_id,p.author_company,p.author_nickname),
    'conversation',contextv,'peer_sources',peers,'channels',channelsv),'enabled',true,'remaining',s.ai_daily_limit-cnt-1);
  end loop;
  return jsonb_build_object('job',null,'enabled',s.ai_enabled,'remaining',s.ai_daily_limit-cnt);
 end if;
 perform public.bl_require(p_action in ('complete','skip'),'지원하지 않는 AI 작업입니다.');
 -- 잠금 순서: post → job. 동시에 여러 후속 완료/관리자 재생성을 해도 상한과 ID가 유지된다.
 select post_id into postv from public.bl_ai_jobs where id=(p_payload->>'id')::uuid;
 select * into p from public.bl_posts where id=postv for update;
 select * into j from public.bl_ai_jobs where id=(p_payload->>'id')::uuid and status='processing'
  and lease_token=(p_payload->>'lease_token')::uuid and lease_until>now() for update;
 perform public.bl_require(j.id is not null,'처리 임대가 만료되었습니다.');
 if p_action='skip' then
  update public.bl_ai_jobs set status='skipped',error_code=null,lease_token=null,lease_until=null,completed_at=now() where id=j.id;
  return jsonb_build_object('ok',true,'status','skipped');
 end if;
 perform public.bl_require(p.status='published' and (p.is_question or j.is_mention) and p.updated_at=j.source_updated_at
  and exists(select 1 from public.bl_channels where id=p.channel_id and enabled)
  and exists(select 1 from public.bl_profiles where id=p.author_id and status not in ('suspended','withdrawn'))
  and (select ai_enabled from public.bl_settings where id),'생성 중 원문이나 AI 허용 상태가 변경되었습니다.');
 if j.trigger_comment_id is not null then
  select c.* into q from public.bl_comments c join public.bl_profiles pr on pr.id=c.author_id
   where c.id=j.trigger_comment_id and c.post_id=p.id and not c.is_ai and public.bl_ai_thread_visible(c.id)
    and (pr.status not in ('suspended','withdrawn') or pr.status not in ('suspended','withdrawn')
     and exists(select 1 from public.bl_admins ad where ad.user_id=pr.id and ad.role='owner')) for share of c;
  perform public.bl_require(q.id is not null and q.updated_at=j.question_updated_at,'생성 중 후속 질문이 변경되었거나 가려졌습니다.');
 end if;
 if j.comment_id is null and not j.is_mention and (select count(*) from public.bl_comments where post_id=p.id and is_ai and not ai_mention)>=5 then
  update public.bl_ai_jobs set status='skipped',error_code=null,lease_token=null,lease_until=null,completed_at=now() where id=j.id;
  return jsonb_build_object('ok',true,'status','skipped');
 end if;
 txt:=btrim(coalesce(p_payload->>'body',p_payload->>'answer',''));
 perform public.bl_require(length(txt) between 2 and 15000 and public.bl_safe_text(txt),'AI 답변에 금지 정보가 있거나 길이가 잘못되었습니다.');
 relatedv:=public.bl_ai_related_posts(p.id,p_payload->'related_posts');
 if j.comment_id is null then
  insert into public.bl_comments(post_id,parent_id,author_id,body,status,is_ai,ai_model,is_test,is_sample,anonymous,related_posts,ai_mention)
   values(p.id,j.trigger_comment_id,null,txt,'published',true,left(coalesce(p_payload->>'model','claude'),80),p.is_test,p.is_sample,p.anonymous,relatedv,j.is_mention)
   returning id into commentv;
 else
  update public.bl_comments set body=txt,status='published',ai_model=left(coalesce(p_payload->>'model','claude'),80),
   related_posts=relatedv,temporary_until=null,updated_at=now()
   where id=j.comment_id and post_id=p.id and is_ai returning id into commentv;
  perform public.bl_require(commentv is not null,'다시 만들 AI 답변을 찾을 수 없습니다.');
 end if;
 update public.bl_ai_jobs set comment_id=commentv,status='complete',error_code=null,lease_token=null,lease_until=null,completed_at=now() where id=j.id;
 perform public.bl_log('ai_generated_published','post',p.id::text);
 return jsonb_build_object('ok',true,'status','published','comment_id',commentv);
end;
$function$;

CREATE OR REPLACE FUNCTION public.bl_comment_json(c bl_comments)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select public.bl_ai_comment_fields(c)||jsonb_build_object('id',c.id,'is_ai',c.is_ai,'is_sample',c.is_sample,'post_id',c.post_id,'parent_id',c.parent_id,'body',c.body,'ai_mention',c.ai_mention,'author_display',case when c.is_ai then '보라' when c.anonymous or exists(select 1 from public.bl_posts pp where pp.id=c.post_id and pp.anonymous) then case when c.author_id=(select pp.author_id from public.bl_posts pp where pp.id=c.post_id) then '글쓴이' else '익명' end else public.bl_author(c.author_id,c.author_company,c.author_nickname) end,'anonymous',c.anonymous or exists(select 1 from public.bl_posts pp where pp.id=c.post_id and pp.anonymous),'created_at',c.created_at,'updated_at',c.updated_at,'status',c.status,'likes',(select count(*) from public.bl_reactions r where r.target='comment' and r.target_id=c.id and r.kind='like'),'liked',exists(select 1 from public.bl_reactions r where r.user_id=auth.uid() and r.target='comment' and r.target_id=c.id and r.kind='like'),'is_mine',coalesce(c.author_id=auth.uid(),false)); $function$;

