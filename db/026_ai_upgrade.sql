-- 026: AI 자료·이어 묻기·동료 답변 채택 (023~025 적용 후, 운영자가 실행).
-- 이 파일은 작성만 했으며 DB에서 실행하지 않았다. 처리기/크론을 멈춘 뒤 적용한다.
-- 기존 함수의 실제 정의를 권한 없는 백업에 보존한다. 문맥이 달라졌으면 원자적으로 중단한다.
begin;
set local lock_timeout='10s';
lock table public.bl_posts, public.bl_comments, public.bl_ai_jobs in share row exclusive mode;

create table public.bl_ai_upgrade_026_backup(signature text primary key, definition text not null, upgraded_definition text);
alter table public.bl_ai_upgrade_026_backup enable row level security;
revoke all on public.bl_ai_upgrade_026_backup from public, anon, authenticated, service_role;
insert into public.bl_ai_upgrade_026_backup(signature,definition)
 select signature,pg_get_functiondef(signature::regprocedure)
 from unnest(array['public.bl_post_json(bl_posts)','public.bl_comment_json(bl_comments)',
 'public.bl_read(text,jsonb)','public.bl_worker(text,jsonb)',
 'public.bl_action_internal(text,jsonb)','public.bl_admin_read(text,jsonb)',
 'public.bl_note_visible(text,uuid,uuid)']) signature;

alter table public.bl_comments drop constraint bl_comments_author_kind;
alter table public.bl_comments add constraint bl_comments_author_kind check (
 (is_ai and author_id is null and author_company='' and author_nickname='')
 or (not is_ai and author_id is not null and ai_model is null and legacy_ai_reply_id is null));
drop index public.bl_comments_one_ai_per_post;
alter table public.bl_comments add column related_posts jsonb not null default '[]'::jsonb
 check (jsonb_typeof(related_posts)='array' and jsonb_array_length(related_posts)<=2);
alter table public.bl_posts add column accepted_comment_id uuid references public.bl_comments(id) on delete set null;
alter table public.bl_ai_jobs drop constraint bl_ai_jobs_post_id_key;
alter table public.bl_ai_jobs add column trigger_comment_id uuid references public.bl_comments(id);
alter table public.bl_ai_jobs add column comment_id uuid unique references public.bl_comments(id);
alter table public.bl_ai_jobs add column question_updated_at timestamptz;
update public.bl_ai_jobs j set comment_id=c.id from public.bl_comments c where c.post_id=j.post_id and c.is_ai;
create unique index bl_ai_jobs_initial_post on public.bl_ai_jobs(post_id) where trigger_comment_id is null;
create unique index bl_ai_jobs_followup on public.bl_ai_jobs(trigger_comment_id) where trigger_comment_id is not null;
create index bl_ai_jobs_post on public.bl_ai_jobs(post_id,created_at);
create index bl_comments_ai_post on public.bl_comments(post_id) where is_ai;

-- 사람 댓글의 숨겨진 조상도 함께 검사한다. 반복/다른 글 참조는 공개하지 않는다.
create function public.bl_ai_thread_visible(p_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
 with recursive chain as (
  select c.id,c.post_id,c.parent_id,c.status,c.is_test,array[c.id] seen,0 depth
   from public.bl_comments c where c.id=p_id
  union all
  select c.id,c.post_id,c.parent_id,c.status,c.is_test,x.seen||c.id,x.depth+1
   from chain x join public.bl_comments c on c.id=x.parent_id and c.post_id=x.post_id
   where not c.id=any(x.seen) and x.depth<32
 )
 select coalesce(bool_and(status='published' and (auth.role()='service_role' or public.bl_test_visible(is_test)))
  and bool_or(parent_id is null),false) from chain;
$$;

-- 개인정보는 모델에 보내기 전에 DB에서 먼저 지운다. 작성자 객체는 반환하지 않는다.
create function public.bl_ai_redact(p_text text,p_author uuid,p_company text default '',p_nickname text default '')
returns text language plpgsql stable security definer set search_path='' as $$
declare txt text:=coalesce(p_text,''); secret text; pr public.bl_profiles; emailv text;
begin
 select * into pr from public.bl_profiles where id=p_author;
 select email into emailv from auth.users where id=p_author;
 for secret in select distinct x from unnest(array[pr.name,pr.nickname,pr.company_name,pr.phone,
   pr.registration_number,emailv,p_company,p_nickname]) x where length(btrim(x))>=2 order by x
 loop txt:=replace(txt,secret,'[개인정보 삭제]'); end loop;
 txt:=regexp_replace(txt,'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}','[이메일 삭제]','g');
 txt:=regexp_replace(txt,'[0-9]{6}[[:space:]-]*[1-8][0-9]{6}','[개인번호 삭제]','g');
 txt:=regexp_replace(txt,'01[016789][[:space:].-]*[0-9]{3,4}[[:space:].-]*[0-9]{4}','[연락처 삭제]','g');
 txt:=regexp_replace(txt,'0[2-6][0-9]?[[:space:].-]+[0-9]{3,4}[[:space:].-]+[0-9]{4}','[연락처 삭제]','g');
 txt:=regexp_replace(txt,'(고객명|계약자명|피보험자명|성명|계좌번호|설계사[[:space:]]*고유번호)[[:space:]:：]+[^[:space:],;]+','[개인정보 삭제]','g');
 return txt;
end;
$$;

-- 생성된 AI(숨김/삭제 포함) + 아직 새 댓글을 예약하고 있는 작업. 실패/skip은 예약을 해제한다.
create function public.bl_ai_slots_used(p_post uuid) returns integer
language sql stable security definer set search_path='' as $$
 select ((select count(*) from public.bl_comments c where c.post_id=p_post and c.is_ai)
 +(select count(*) from public.bl_ai_jobs j where j.post_id=p_post and j.comment_id is null
   and j.status in ('queued','processing','review')))::integer;
$$;

create function public.bl_ai_enqueue(p_post uuid,p_question uuid default null) returns boolean
language plpgsql security definer set search_path='' as $$
declare p public.bl_posts;
begin
 select * into p from public.bl_posts where id=p_post for update;
 if p.id is null or p.status<>'published' or not p.is_question
  or not exists(select 1 from public.bl_channels where id=p.channel_id and enabled)
  or exists(select 1 from public.bl_ai_jobs where post_id=p_post and trigger_comment_id is not distinct from p_question)
  or public.bl_ai_slots_used(p_post)>=5 then return false; end if;
 if p_question is not null and not exists(
  select 1 from public.bl_comments q join public.bl_comments a on a.id=q.parent_id
   join public.bl_profiles pr on pr.id=q.author_id
  where q.id=p_question and q.post_id=p_post and not q.is_ai and q.status='published'
   and a.post_id=p_post and a.is_ai and public.bl_ai_thread_visible(a.id)
   and (pr.status='verified' and pr.verified_until>now()
     or pr.status not in ('suspended','withdrawn') and exists(select 1 from public.bl_admins ad where ad.user_id=pr.id and ad.role='owner'))
 ) then return false; end if;
 insert into public.bl_ai_jobs(post_id,trigger_comment_id) values(p_post,p_question) on conflict do nothing;
 return found;
end;
$$;

create function public.bl_ai_followup_enqueue() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if not new.is_ai and new.parent_id is not null and new.status='published'
  and exists(select 1 from public.bl_comments where id=new.parent_id and post_id=new.post_id and is_ai) then
  perform public.bl_ai_enqueue(new.post_id,new.id);
 end if;
 return new;
end;
$$;
create trigger bl_comments_ai_followup after insert on public.bl_comments
 for each row execute function public.bl_ai_followup_enqueue();

-- 모든 AI INSERT에 최후 방어: 같은 글 row lock으로 총 5개를 직렬화한다.
create function public.bl_ai_comment_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.is_ai then
  perform 1 from public.bl_posts where id=new.post_id for update;
  perform public.bl_require((select count(*)<5 from public.bl_comments where post_id=new.post_id and is_ai),'AI 답변은 글마다 다섯 번까지입니다.');
  perform public.bl_require(new.parent_id is null or exists(select 1 from public.bl_comments
   where id=new.parent_id and post_id=new.post_id and not is_ai and status='published'),'후속 질문을 확인해 주세요.');
 end if;
 return new;
end;
$$;
create trigger bl_comments_ai_limit before insert on public.bl_comments
 for each row execute function public.bl_ai_comment_guard();

-- 링크는 UUID만 저장·신뢰한다. 제목과 공개 범위는 저장할 때와 읽을 때 모두 다시 검사한다.
create function public.bl_ai_related_posts(p_post uuid,p_items jsonb) returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'title',x.title) order by x.ord),'[]'::jsonb)
 from (
  select p.id,p.title,min(e.ord) ord from jsonb_array_elements(
   case when jsonb_typeof(p_items)='array' then p_items else '[]'::jsonb end) with ordinality e(item,ord)
  join public.bl_posts p on p.id=case when e.item->>'id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   then (e.item->>'id')::uuid else null end
  join public.bl_channels ch on ch.id=p.channel_id
  where p.id<>p_post and p.status='published' and not p.is_test and not p.is_sample
   and not p.anonymous and ch.enabled and not ch.anonymous
  group by p.id,p.title order by min(e.ord) limit 2
 ) x;
$$;

-- 채택은 원글 작성자만. 숨김·삭제·AI·본인 댓글은 채택할 수 없다. null은 취소.
create function public.bl_ai_accept(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p public.bl_posts; cid uuid:=nullif(p_payload->>'comment_id','')::uuid;
begin
 perform public.bl_require(auth.uid() is not null and public.bl_can_write(),'설계사 인증을 마친 뒤 이용할 수 있어요.');
 select p0.* into p from public.bl_posts p0 join public.bl_channels ch on ch.id=p0.channel_id
  where p0.id=(p_payload->>'post_id')::uuid and ch.enabled for update of p0;
 perform public.bl_require(p.author_id=auth.uid() and p.status='published' and public.bl_test_visible(p.is_test),'글 작성자만 동료 답변을 채택할 수 있어요.');
 if cid is not null then
  perform 1 from public.bl_comments c where c.id=cid and c.post_id=p.id and not c.is_ai
   and c.author_id<>auth.uid() and c.status='published' and public.bl_test_visible(c.is_test)
   and public.bl_ai_thread_visible(c.id) for key share;
  perform public.bl_require(found,'채택할 동료 댓글을 확인해 주세요.');
 end if;
 update public.bl_posts set accepted_comment_id=cid where id=p.id;
 return jsonb_build_object('ok',true,'id',p.id,'accepted_comment_id',cid);
end;
$$;

create function public.bl_ai_post_fields(p public.bl_posts) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ai_upgrade',true,'ai_reply_limit',5,
 'ai_reply_count',(select count(*) from public.bl_comments where post_id=p.id and is_ai),
 'ai_followup_available',p.is_question and p.status='published' and public.bl_can_write()
  and (select ai_enabled from public.bl_settings where id) and public.bl_ai_slots_used(p.id)<5,
 'accepted_comment_id',case when public.bl_verified() or public.bl_is_admin() then
  (select c.id from public.bl_comments c where c.id=p.accepted_comment_id and c.post_id=p.id
   and not c.is_ai and public.bl_ai_thread_visible(c.id)) end);
$$;

create function public.bl_ai_comment_fields(c public.bl_comments) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('is_accepted',not c.is_ai and c.status='published'
  and exists(select 1 from public.bl_posts p where p.id=c.post_id and p.accepted_comment_id=c.id)
  and public.bl_ai_thread_visible(c.id),
  'related_posts',case when c.is_ai then public.bl_ai_related_posts(c.post_id,c.related_posts) else '[]'::jsonb end);
$$;

-- 최대 8개 관련 동료 글. 원글/전체익명/시험/견본 제외, 공개된 사람 댓글만.
create function public.bl_ai_peer_sources(p_post uuid,p_query text) returns jsonb
language sql stable security definer set search_path='' as $$
 with tokens as (
  select distinct lower(t) t from regexp_split_to_table(left(coalesce(p_query,''),1800),'[^[:alnum:]가-힣]+') t
  where length(t)>=2 and t not in ('질문','문의','합니다','있나요','주세요','어떻게','보험') limit 24
 ), ranked as (
  select p.*, (select count(*) from tokens t where lower(p.title||' '||left(p.body,6000)) like '%'||t.t||'%') hits,
   exists(select 1 from public.bl_comments c where c.id=p.accepted_comment_id and c.post_id=p.id
    and not c.is_ai and not c.is_test and not c.is_sample and not c.anonymous and public.bl_ai_thread_visible(c.id)) adopted
  from public.bl_posts p join public.bl_channels ch on ch.id=p.channel_id
  where p.id<>p_post and p.status='published' and not p.is_test and not p.is_sample and not p.anonymous
   and ch.enabled and not ch.anonymous
 ), picked as (
  select * from ranked where hits>0 order by (hits+case when adopted then 2 else 0 end) desc,adopted desc,created_at desc,id limit 8
 )
 select coalesce(jsonb_agg(jsonb_build_object('post_id',p.id,
  'title',public.bl_ai_redact(p.title,p.author_id,p.author_company,p.author_nickname),
  'body',left(public.bl_ai_redact(p.body,p.author_id,p.author_company,p.author_nickname),1800),
  'comments',(select coalesce(jsonb_agg(jsonb_build_object('body',
   left(public.bl_ai_redact(c.body,c.author_id,c.author_company,c.author_nickname),1200),
   'is_accepted',coalesce(c.id=p.accepted_comment_id,false)) order by (c.id=p.accepted_comment_id) desc nulls last,c.created_at),'[]'::jsonb)
   from (select c.* from public.bl_comments c where c.post_id=p.id and not c.is_ai and c.status='published'
    and not c.is_test and not c.is_sample and not c.anonymous and public.bl_ai_thread_visible(c.id)
    order by (c.id=p.accepted_comment_id) desc nulls last,c.created_at limit 4) c))
  order by (p.hits+case when p.adopted then 2 else 0 end) desc,p.adopted desc,p.created_at desc,p.id),'[]'::jsonb) from picked p;
$$;

-- AI 경로만 새 구현으로 연결한다. 증빙 판정/탈퇴/정리/heartbeat/fail은 기존 코드를 그대로 쓴다.
create function public.bl_ai_worker_upgrade(p_action text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
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
   where a.status='queued' and pp.status='published' and pp.is_question
    and not exists(select 1 from public.bl_ai_jobs busy where busy.post_id=a.post_id and busy.status='processing')
    and exists(select 1 from public.bl_channels ch where ch.id=pp.channel_id and ch.enabled)
    and exists(select 1 from public.bl_profiles pr where pr.id=pp.author_id and pr.status not in ('suspended','withdrawn'))
   order by a.created_at,a.id limit 30
  loop
   select * into p from public.bl_posts where id=postv for update;
   select * into j from public.bl_ai_jobs where id=candidate and status='queued' for update skip locked;
   if j.id is null then continue; end if;
   if p.status<>'published' or not p.is_question
    or not exists(select 1 from public.bl_channels where id=p.channel_id and enabled)
    or not exists(select 1 from public.bl_profiles where id=p.author_id and status not in ('suspended','withdrawn')) then
    update public.bl_ai_jobs set status='skipped',error_code=null,completed_at=now() where id=j.id; continue;
   end if;
   if j.comment_id is null and (select count(*) from public.bl_comments where post_id=p.id and is_ai)>=5 then
    update public.bl_ai_jobs set status='skipped',error_code=null,completed_at=now() where id=j.id; continue;
   end if;
   if j.trigger_comment_id is not null then
    select c.* into q from public.bl_comments c join public.bl_profiles pr on pr.id=c.author_id
     where c.id=j.trigger_comment_id and c.post_id=p.id and not c.is_ai and public.bl_ai_thread_visible(c.id)
      and (pr.status='verified' and pr.verified_until>now() or pr.status not in ('suspended','withdrawn')
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
      or c.id=p.accepted_comment_id and not c.is_ai and not c.is_test and not c.is_sample and not c.anonymous
       and not p.is_test and not p.is_sample and not p.anonymous
       and exists(select 1 from public.bl_channels ch where ch.id=p.channel_id and not ch.anonymous and ch.enabled))
     and c.id is distinct from j.comment_id and (q.id is null or c.created_at<=q.created_at or c.is_ai or c.id=p.accepted_comment_id)
     order by (c.id=p.accepted_comment_id) desc nulls last,c.is_ai desc,c.created_at desc,c.id limit 50) c;
   peers:=public.bl_ai_peer_sources(p.id,tit||' '||left(txt,1200)||' '||public.bl_ai_redact(q.body,q.author_id,q.author_company,q.author_nickname));
   select coalesce(jsonb_agg(jsonb_build_object('id',ch.id,'name',ch.name) order by ch.display_order),'[]'::jsonb)
    into channelsv from public.bl_channels ch where ch.enabled and not ch.anonymous and ch.slug<>'notice';
   return jsonb_build_object('job',jsonb_build_object('id',j.id,'post_id',p.id,'lease_token',leasev,'title',tit,'body',txt,
    'attempts',j.attempts+1,'trigger_comment_id',j.trigger_comment_id,'comment_id',j.comment_id,
    'ai_reply_count',(select count(*) from public.bl_comments where post_id=p.id and is_ai),'ai_reply_limit',5,
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
 perform public.bl_require(p.status='published' and p.is_question and p.updated_at=j.source_updated_at
  and exists(select 1 from public.bl_channels where id=p.channel_id and enabled)
  and exists(select 1 from public.bl_profiles where id=p.author_id and status not in ('suspended','withdrawn'))
  and (select ai_enabled from public.bl_settings where id),'생성 중 원문이나 AI 허용 상태가 변경되었습니다.');
 if j.trigger_comment_id is not null then
  select c.* into q from public.bl_comments c join public.bl_profiles pr on pr.id=c.author_id
   where c.id=j.trigger_comment_id and c.post_id=p.id and not c.is_ai and public.bl_ai_thread_visible(c.id)
    and (pr.status='verified' and pr.verified_until>now() or pr.status not in ('suspended','withdrawn')
     and exists(select 1 from public.bl_admins ad where ad.user_id=pr.id and ad.role='owner')) for share of c;
  perform public.bl_require(q.id is not null and q.updated_at=j.question_updated_at,'생성 중 후속 질문이 변경되었거나 가려졌습니다.');
 end if;
 if j.comment_id is null and (select count(*) from public.bl_comments where post_id=p.id and is_ai)>=5 then
  update public.bl_ai_jobs set status='skipped',error_code=null,lease_token=null,lease_until=null,completed_at=now() where id=j.id;
  return jsonb_build_object('ok',true,'status','skipped');
 end if;
 txt:=btrim(coalesce(p_payload->>'body',p_payload->>'answer',''));
 perform public.bl_require(length(txt) between 2 and 15000 and public.bl_safe_text(txt),'AI 답변에 금지 정보가 있거나 길이가 잘못되었습니다.');
 relatedv:=public.bl_ai_related_posts(p.id,p_payload->'related_posts');
 if j.comment_id is null then
  insert into public.bl_comments(post_id,parent_id,author_id,body,status,is_ai,ai_model,is_test,is_sample,anonymous,related_posts)
   values(p.id,j.trigger_comment_id,null,txt,'published',true,left(coalesce(p_payload->>'model','claude'),80),p.is_test,p.is_sample,p.anonymous,relatedv)
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
$$;

-- 관리자 AI 작업은 해당 job의 댓글 하나에만 적용한다. 기존 ID·좋아요·답글을 유지한다.
create function public.bl_ai_admin_action(p_op text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j public.bl_ai_jobs; p public.bl_posts; postv uuid; txt text; n integer; st text;
begin
 perform public.bl_require(public.bl_is_admin(),'관리자 권한이 필요합니다.');
 select post_id into postv from public.bl_ai_jobs where id=(p_payload->>'id')::uuid;
 select * into p from public.bl_posts where id=postv for update;
 select * into j from public.bl_ai_jobs where id=(p_payload->>'id')::uuid for update;
 perform public.bl_require(j.id is not null,'AI 작업을 찾을 수 없습니다.');
 if p_op='ai_edit' then
  txt:=btrim(coalesce(p_payload->>'body','')); perform public.bl_require(length(txt) between 20 and 15000 and public.bl_safe_text(txt),'AI 답변은 개인정보 없이 20자 이상으로 고쳐 주세요.');
  update public.bl_comments set body=txt,updated_at=now() where id=j.comment_id and post_id=p.id and is_ai;
  get diagnostics n=row_count; perform public.bl_require(n=1,'고칠 AI 답변이 없습니다.'); st:='edited';
 elsif p_op in ('ai_retry','ai_regenerate') then
  perform public.bl_require(p_op='ai_regenerate' or j.status in ('failed','skipped'),'실패하거나 반려된 작업만 다시 시도할 수 있습니다.');
  perform public.bl_require(j.comment_id is not null or j.status in ('queued','processing','review') or public.bl_ai_slots_used(p.id)<5,'AI 답변은 글마다 다섯 번까지입니다.');
  update public.bl_comments set status='hidden',temporary_until=null,updated_at=now() where id=j.comment_id and post_id=p.id and is_ai and p_op='ai_regenerate';
  update public.bl_ai_jobs set status='queued',attempts=0,error_code=null,lease_token=null,lease_until=null,completed_at=null where id=j.id; st:='queued';
 elsif p_op in ('ai_publish','ai_reject') then
  update public.bl_comments set status=case when p_op='ai_publish' then 'published' else 'hidden' end,temporary_until=null,updated_at=now()
   where id=j.comment_id and post_id=p.id and is_ai;
  get diagnostics n=row_count; perform public.bl_require(n=1,'AI 답변을 찾을 수 없습니다.');
  st:=case when p_op='ai_publish' then 'complete' else 'skipped' end;
  update public.bl_ai_jobs set status=st,lease_token=null,lease_until=null where id=j.id;
 else raise exception '지원하지 않는 AI 관리 작업입니다.'; end if;
 perform public.bl_log('admin_'||p_op,'ai',j.id::text,jsonb_build_object('reason',left(coalesce(p_payload->>'reason',''),1000),'status',st));
 return jsonb_build_object('ok',true,'id',j.id);
end;
$$;

-- 원본 함수의 필요한 문맥만 치환한다. 023 이후 별도 수정으로 문맥이 다르면 중단한다.
create function pg_temp.bl_aiup_patch(p_signature text,p_old text,p_new text) returns void
language plpgsql as $$
declare src text;
begin
 src:=pg_get_functiondef(p_signature::regprocedure);
 if (length(src)-length(replace(src,p_old,'')))/length(p_old)<>1 then
  raise exception '026 source guard failed: %',p_signature;
 end if;
 execute replace(src,p_old,p_new);
end;
$$;

select pg_temp.bl_aiup_patch('public.bl_post_json(bl_posts)',
 $old$AS $function$ select jsonb_build_object($old$,
 $new$AS $function$ select public.bl_ai_post_fields(p)||jsonb_build_object($new$);
select pg_temp.bl_aiup_patch('public.bl_comment_json(bl_comments)',
 $old$AS $function$ select jsonb_build_object($old$,
 $new$AS $function$ select public.bl_ai_comment_fields(c)||jsonb_build_object($new$);
select pg_temp.bl_aiup_patch('public.bl_read(text,jsonb)',
 $old$and (x.parent_id is null or exists(select 1 from public.bl_comments par where par.id=x.parent_id and par.status='published') or public.bl_is_admin())$old$,
 $new$and (public.bl_ai_thread_visible(x.id) or public.bl_is_admin())$new$);
select pg_temp.bl_aiup_patch('public.bl_read(text,jsonb)',
 $old$where x.author_id=auth.uid() and x.status='published' and pp.status='published'; end if;$old$,
 $new$where x.author_id=auth.uid() and x.status='published' and pp.status='published'
  and (public.bl_ai_thread_visible(x.id) or public.bl_is_admin()); end if;$new$);
select pg_temp.bl_aiup_patch('public.bl_note_visible(text,uuid,uuid)',
 $old$and (c.parent_id is null or exists(select 1 from public.bl_comments par where par.id=c.parent_id and par.status='published'))$old$,
 $new$and public.bl_ai_thread_visible(c.id)$new$);
select pg_temp.bl_aiup_patch('public.bl_worker(text,jsonb)',
 $old$if p_action='status' then$old$,
 $new$if p_action in ('claim','complete','skip') then return public.bl_ai_worker_upgrade(p_action,p_payload); end if;
 if p_action='status' then$new$);
select pg_temp.bl_aiup_patch('public.bl_action_internal(text,jsonb)',
 $old$if p_action='notification_read' then$old$,
 $new$if p_action='comment_accept' then return public.bl_ai_accept(p_payload); end if;
 if p_action='notification_read' then$new$);
select pg_temp.bl_aiup_patch('public.bl_action_internal(text,jsonb)',
 $old$op:=p_payload->>'operation';$old$,
 $new$op:=p_payload->>'operation';
  if op in ('ai_edit','ai_retry','ai_regenerate','ai_publish','ai_reject') then return public.bl_ai_admin_action(op,p_payload); end if;$new$);
select pg_temp.bl_aiup_patch('public.bl_action_internal(text,jsonb)',
 $old$insert into public.bl_ai_jobs(post_id) values(idv) on conflict(post_id) do nothing;$old$,
 $new$perform public.bl_ai_enqueue(idv);$new$);
select pg_temp.bl_aiup_patch('public.bl_action_internal(text,jsonb)',
 $old$postv:=(p_payload->>'post_id')::uuid; perform public.bl_require($old$,
 $new$postv:=(p_payload->>'post_id')::uuid;
  perform 1 from public.bl_posts where id=postv for update;
  perform public.bl_require($new$);
select pg_temp.bl_aiup_patch('public.bl_action_internal(text,jsonb)',
 $old$where id=parentv and post_id=postv and parent_id is null and status='published'),'대댓글은 공개된 원댓글에 한 단계만 작성할 수 있습니다.');$old$,
 $new$where id=parentv and post_id=postv and (parent_id is null or is_ai) and status='published' and public.bl_ai_thread_visible(id)),'공개된 원댓글이나 AI 답변에 답글을 작성할 수 있습니다.');$new$);
select pg_temp.bl_aiup_patch('public.bl_admin_read(text,jsonb)',
 $old$(select body from public.bl_comments where post_id=j.post_id and is_ai)$old$,
 $new$(select body from public.bl_comments where id=j.comment_id and post_id=j.post_id and is_ai)$new$);
select pg_temp.bl_aiup_patch('public.bl_admin_read(text,jsonb)',
 $old$(select status from public.bl_comments where post_id=j.post_id and is_ai)$old$,
 $new$(select status from public.bl_comments where id=j.comment_id and post_id=j.post_id and is_ai)$new$);
drop function pg_temp.bl_aiup_patch(text,text,text);

-- 신규 보조 함수는 RPC로 노출하지 않는다. 기존 bl_action/worker/read의 ACL은 그대로다.
do $$ declare r record; begin
 for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname in ('bl_ai_thread_visible','bl_ai_redact','bl_ai_slots_used','bl_ai_enqueue',
   'bl_ai_followup_enqueue','bl_ai_comment_guard','bl_ai_related_posts','bl_ai_accept','bl_ai_post_fields',
   'bl_ai_comment_fields','bl_ai_peer_sources','bl_ai_worker_upgrade','bl_ai_admin_action')
 loop execute format('revoke all on function %s from public, anon, authenticated, service_role',r.sig); end loop;
end $$;

update public.bl_ai_upgrade_026_backup set upgraded_definition=pg_get_functiondef(signature::regprocedure);

commit;

-- 팀쿡 확인용 읽기 전용 대상 지정: 결과가 7건인지 확인하고 관리자 AI 화면에서 해당 job만
-- "다시 만들기"를 실행한다. 이 SELECT 자체는 생성/DB 변경을 하지 않는다.
select j.id as job_id,c.id as comment_id,p.id as post_id,p.title
from public.bl_ai_jobs j join public.bl_comments c on c.id=j.comment_id join public.bl_posts p on p.id=j.post_id
where c.is_ai and (c.body like '공식 자료를 확인하지 못한 AI 참고 답변입니다%'
 or c.body like '%확인 포인트:%') order by c.created_at;
