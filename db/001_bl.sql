-- 보험라이브 전용 추가 migration. 기존 객체/인증 설정은 변경하지 않는다.
begin;
create table if not exists public.bl_profiles (
 id uuid primary key, auth_deleted_at timestamptz, nickname text not null default '', name text not null default '', phone text not null default '', registration_number text not null default '',
 company_id uuid, company_name text not null default '', status text not null default 'unverified' check(status in ('unverified','pending','supplement','verified','rejected','suspended','withdrawn')),
 previous_status text, verified_until timestamptz, review_reason text not null default '', proof_path text, proof_submitted_at timestamptz, proof_processed_at timestamptz,
 is_test boolean not null default false, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.bl_admins(user_id uuid primary key references public.bl_profiles(id),role text not null check(role in ('owner','admin')),created_at timestamptz not null default now());
create table if not exists public.bl_channels(id uuid primary key default gen_random_uuid(),slug text unique not null,name text not null,description text not null default '',display_order int not null default 0,enabled boolean not null default true);
create table if not exists public.bl_companies(id uuid primary key default gen_random_uuid(),name text unique not null,kind text not null default '보험사',description text not null default '',enabled boolean not null default true);
create table if not exists public.bl_posts(id uuid primary key default gen_random_uuid(),author_id uuid references public.bl_profiles(id),channel_id uuid not null references public.bl_channels(id),company_id uuid references public.bl_companies(id),title text not null,body text not null,content_kind text not null check(content_kind in ('practice','career','experience','weekly')),is_question boolean not null default false,status text not null default 'published' check(status in ('published','hidden','deleted')),pinned boolean not null default false,author_company text not null default '',author_nickname text not null default '',is_test boolean not null default false,temporary_until timestamptz,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create index if not exists bl_posts_created on public.bl_posts(created_at desc);
create index if not exists bl_posts_author on public.bl_posts(author_id,created_at desc);
create table if not exists public.bl_comments(id uuid primary key default gen_random_uuid(),post_id uuid not null references public.bl_posts(id),author_id uuid not null references public.bl_profiles(id),parent_id uuid references public.bl_comments(id),body text not null,status text not null default 'published' check(status in ('published','hidden','deleted')),author_company text not null default '',author_nickname text not null default '',is_test boolean not null default false,temporary_until timestamptz,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create index if not exists bl_comments_post on public.bl_comments(post_id,created_at);
create index if not exists bl_comments_author on public.bl_comments(author_id,created_at desc);
create table if not exists public.bl_reactions(user_id uuid not null references public.bl_profiles(id),target text not null check(target in ('post','comment','channel')),target_id uuid not null,kind text not null check(kind in ('like','bookmark','follow')),created_at timestamptz not null default now(),primary key(user_id,target,target_id,kind));
create table if not exists public.bl_reviews(id uuid primary key default gen_random_uuid(),author_id uuid not null references public.bl_profiles(id),company_id uuid not null references public.bl_companies(id),title text not null,body text not null,scores int[] not null check(array_length(scores,1)=5 and 1<=all(scores) and 5>=all(scores)),status text not null default 'published' check(status in ('published','hidden','deleted')),author_company text not null,author_nickname text not null,is_test boolean not null default false,temporary_until timestamptz,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create index if not exists bl_reviews_author on public.bl_reviews(author_id,company_id,created_at desc);
create table if not exists public.bl_reports(id uuid primary key default gen_random_uuid(),reporter_id uuid not null references public.bl_profiles(id),target text not null check(target in ('post','comment','review')),target_id uuid not null,reason text not null,status text not null default 'pending' check(status in ('pending','maintained','restored')),decision_reason text,decided_by uuid,created_at timestamptz not null default now(),decided_at timestamptz,temporary_until timestamptz not null default now()+interval '30 days');
create table if not exists public.bl_notifications(id uuid primary key default gen_random_uuid(),user_id uuid not null references public.bl_profiles(id),kind text not null,title text not null,body text not null default '',post_id uuid,read_at timestamptz,created_at timestamptz not null default now());
create table if not exists public.bl_audit(id bigint generated always as identity primary key,actor_id uuid,action text not null,target text,target_id text,detail jsonb not null default '{}',created_at timestamptz not null default now());
create table if not exists public.bl_settings(id boolean primary key default true check(id),ai_enabled boolean not null default true,ai_daily_limit int not null default 30 check(ai_daily_limit between 0 and 30));
insert into public.bl_settings(id) values(true) on conflict do nothing;
create table if not exists public.bl_ai_jobs(id uuid primary key default gen_random_uuid(),post_id uuid unique not null references public.bl_posts(id),status text not null default 'queued' check(status in ('queued','processing','review','complete','failed','skipped')),attempts int not null default 0,lease_token uuid,lease_until timestamptz,error_code text,created_at timestamptz not null default now(),started_at timestamptz,completed_at timestamptz);
create table if not exists public.bl_ai_replies(id uuid primary key default gen_random_uuid(),post_id uuid unique not null references public.bl_posts(id),body text not null,status text not null default 'review' check(status in ('review','published','hidden')),model text,created_at timestamptz not null default now());
create table if not exists public.bl_proof_cleanup(path text primary key,user_id uuid not null,due_at timestamptz not null,deleted_at timestamptz);

create or replace function public.bl_is_admin() returns boolean language sql stable security definer set search_path='' as $$ select exists(select 1 from public.bl_admins a join public.bl_profiles p on p.id=a.user_id where a.user_id=auth.uid() and p.status not in ('suspended','withdrawn')); $$;
create or replace function public.bl_is_owner() returns boolean language sql stable security definer set search_path='' as $$ select exists(select 1 from public.bl_admins a join public.bl_profiles p on p.id=a.user_id where a.user_id=auth.uid() and a.role='owner' and p.status not in ('suspended','withdrawn')); $$;
create or replace function public.bl_verified() returns boolean language sql stable security definer set search_path='' as $$ select coalesce((select status='verified' and verified_until>now() from public.bl_profiles where id=auth.uid()),false); $$;
create or replace function public.bl_test_visible(p_test boolean) returns boolean language sql stable security definer set search_path='' as $$ select not p_test or public.bl_is_admin() or coalesce((select is_test from public.bl_profiles where id=auth.uid()),false); $$;
create or replace function public.bl_require(p_ok boolean,p_message text) returns void language plpgsql security definer set search_path='' as $$ begin if not coalesce(p_ok,false) then raise exception '%',p_message; end if; end; $$;
create or replace function public.bl_safe_text(p_text text) returns boolean language sql immutable set search_path='' as $$ select p_text !~ '[0-9]{6}[[:space:]-]*[1-8][0-9]{6}' and p_text !~ '01[016789][[:space:]-]*[0-9]{3,4}[[:space:]-]*[0-9]{4}' and p_text !~ '0[2-6][0-9]?[[:space:]-]+[0-9]{3,4}[[:space:]-]+[0-9]{4}' and p_text !~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' and p_text !~* '(주민등록번호|고객[[:space:]]*(명단|연락처)|계좌번호)[[:space:]:：]*[0-9]'; $$;
create or replace function public.bl_log(p_action text,p_target text default null,p_id text default null,p_detail jsonb default '{}') returns void language sql security definer set search_path='' as $$ insert into public.bl_audit(actor_id,action,target,target_id,detail) values(auth.uid(),p_action,p_target,p_id,p_detail); $$;
create or replace function public.bl_audit_immutable() returns trigger language plpgsql security definer set search_path='' as $$ begin raise exception '감사 기록은 수정하거나 삭제할 수 없습니다.'; end; $$;
drop trigger if exists bl_audit_immutable on public.bl_audit;
create trigger bl_audit_immutable before update or delete on public.bl_audit for each row execute function public.bl_audit_immutable();
create or replace function public.bl_ensure_profile() returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then return; end if;
 insert into public.bl_profiles(id,is_test) select id,coalesce((raw_app_meta_data->>'bl_test')::boolean,false) from auth.users where id=auth.uid() on conflict do nothing;
 -- 오직 서버가 검증한 소유자 이메일에만 최초 역할 지정. 사용자 metadata는 사용하지 않는다.
 if not exists(select 1 from public.bl_admins where role='owner') and exists(select 1 from auth.users where id=auth.uid() and encode(sha256(convert_to(lower(email),'UTF8')),'hex')='2d2741150415225d6626feb209851c88a71bc07afeb6aa9cba8f0b0477d17cbc' and email_confirmed_at is not null) and exists(select 1 from public.bl_profiles where id=auth.uid() and status not in ('withdrawn','suspended')) then
  insert into public.bl_admins(user_id,role) values(auth.uid(),'owner') on conflict(user_id) do update set role='owner';
  perform public.bl_log('owner_bootstrap','member',auth.uid()::text);
 end if;
end; $$;
create or replace function public.bl_viewer() returns jsonb language sql stable security definer set search_path='' as $$ select jsonb_build_object('status',p.status,'role',coalesce(a.role,'member'),'nickname',p.nickname,'company_name',p.company_name,'verified_until',p.verified_until,'is_test',p.is_test) from public.bl_profiles p left join public.bl_admins a on a.user_id=p.id where p.id=auth.uid(); $$;
create or replace function public.bl_author(p_id uuid,p_company text,p_nick text) returns text language sql stable security definer set search_path='' as $$ select case when p_id is null then '보험라이브 운영팀' when exists(select 1 from public.bl_profiles where id=p_id and status='withdrawn') then '탈퇴한 회원' else p_company||' · '||left(p_nick,1)||'***' end; $$;
create or replace function public.bl_post_json(p public.bl_posts) returns jsonb language sql stable security definer set search_path='' as $$ select jsonb_build_object('id',p.id,'channel_id',p.channel_id,'channel_name',(select name from public.bl_channels where id=p.channel_id),'company_id',p.company_id,'company_name',(select name from public.bl_companies where id=p.company_id),'title',case when p.status='published' or public.bl_is_admin() then p.title else '가려진 게시물' end,'body',case when p.status<>'published' and not public.bl_is_admin() then '' when p.content_kind='experience' and not(public.bl_verified() or public.bl_is_admin()) then left(p.body,300) else p.body end,'content_kind',p.content_kind,'is_question',p.is_question,'author_display',public.bl_author(p.author_id,p.author_company,p.author_nickname),'created_at',p.created_at,'updated_at',p.updated_at,'status',p.status,'pinned',p.pinned,'likes',(select count(*) from public.bl_reactions r where r.target='post' and r.target_id=p.id and r.kind='like'),'comment_count',(select count(*) from public.bl_comments c where c.post_id=p.id and c.status='published' and public.bl_test_visible(c.is_test)),'liked',exists(select 1 from public.bl_reactions r where r.user_id=auth.uid() and r.target='post' and r.target_id=p.id and r.kind='like'),'bookmarked',exists(select 1 from public.bl_reactions r where r.user_id=auth.uid() and r.target='post' and r.target_id=p.id and r.kind='bookmark'),'is_mine',coalesce(p.author_id=auth.uid(),false),'is_truncated',p.content_kind='experience' and length(p.body)>300 and not(public.bl_verified() or public.bl_is_admin())); $$;
create or replace function public.bl_comment_json(c public.bl_comments) returns jsonb language sql stable security definer set search_path='' as $$ select jsonb_build_object('id',c.id,'post_id',c.post_id,'parent_id',c.parent_id,'body',c.body,'author_display',public.bl_author(c.author_id,c.author_company,c.author_nickname),'created_at',c.created_at,'updated_at',c.updated_at,'status',c.status,'likes',(select count(*) from public.bl_reactions r where r.target='comment' and r.target_id=c.id and r.kind='like'),'liked',exists(select 1 from public.bl_reactions r where r.user_id=auth.uid() and r.target='comment' and r.target_id=c.id and r.kind='like'),'is_mine',c.author_id=auth.uid()); $$;
create or replace function public.bl_review_json(r public.bl_reviews) returns jsonb language sql stable security definer set search_path='' as $$ select jsonb_build_object('id',r.id,'company_id',r.company_id,'title',r.title,'body',case when public.bl_verified() or public.bl_is_admin() then r.body else left(r.body,300) end,'scores',r.scores,'author_display',public.bl_author(r.author_id,r.author_company,r.author_nickname),'created_at',r.created_at,'updated_at',r.updated_at,'status',r.status,'is_mine',r.author_id=auth.uid(),'is_truncated',length(r.body)>300 and not(public.bl_verified() or public.bl_is_admin())); $$;
create or replace function public.bl_channels_json() returns jsonb language sql stable security definer set search_path='' as $$ select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'slug',c.slug,'name',c.name,'description',c.description,'display_order',c.display_order,'enabled',c.enabled,'followers',(select count(*) from public.bl_reactions r where r.target='channel' and r.target_id=c.id and r.kind='follow'),'following',exists(select 1 from public.bl_reactions r where r.user_id=auth.uid() and r.target='channel' and r.target_id=c.id and r.kind='follow')) order by c.display_order),'[]') from public.bl_channels c where c.enabled or public.bl_is_admin(); $$;
create or replace function public.bl_company_json(c public.bl_companies) returns jsonb language sql stable security definer set search_path='' as $$ select jsonb_build_object('id',c.id,'name',c.name,'kind',c.kind,'description',c.description,'enabled',c.enabled,'review_count',s.n,'average',case when s.n>=5 then round((s.a1+s.a2+s.a3+s.a4+s.a5)/5,2) end,'scores',case when s.n>=5 then jsonb_build_array(round(s.a1,2),round(s.a2,2),round(s.a3,2),round(s.a4,2),round(s.a5,2)) end) from (select count(*) n,avg(r.scores[1]) a1,avg(r.scores[2]) a2,avg(r.scores[3]) a3,avg(r.scores[4]) a4,avg(r.scores[5]) a5 from public.bl_reviews r where r.company_id=c.id and r.status='published' and public.bl_test_visible(r.is_test)) s; $$;

create or replace function public.bl_read(p_scope text,p_args jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare v jsonb; a jsonb; b jsonb; c jsonb; d jsonb; e jsonb; p public.bl_posts; co public.bl_companies; prof public.bl_profiles; lim int:=least(100,greatest(1,coalesce((p_args->>'limit')::int,50)));
begin
 perform public.bl_ensure_profile(); v:=public.bl_viewer();
 if p_scope='channels' then return jsonb_build_object('viewer',v,'channels',public.bl_channels_json()); end if;
 if p_scope in ('companies','home') then select coalesce(jsonb_agg(public.bl_company_json(x) order by x.name),'[]') into c from public.bl_companies x where x.enabled or public.bl_is_admin(); end if;
 if p_scope='companies' then return jsonb_build_object('viewer',v,'companies',c); end if;
 if p_scope in ('home','posts','search') then
  select coalesce(jsonb_agg(public.bl_post_json(x)),'[]') into a from (select z.* from public.bl_posts z join public.bl_channels ch on ch.id=z.channel_id where z.status='published' and ch.enabled and public.bl_test_visible(z.is_test) and (nullif(p_args->>'channel_id','') is null or z.channel_id=(p_args->>'channel_id')::uuid) and (nullif(p_args->>'company_id','') is null or z.company_id=(p_args->>'company_id')::uuid) and (coalesce(p_args->>'q','')='' or z.title ilike '%'||(p_args->>'q')||'%' or (case when z.content_kind='experience' then left(z.body,300) else z.body end) ilike '%'||(p_args->>'q')||'%') order by z.pinned desc,case when p_args->>'sort'='popular' then (select count(*) from public.bl_reactions r where r.target='post' and r.target_id=z.id and r.kind='like') else 0 end desc,z.created_at desc limit lim) x;
  if p_scope<>'home' then return jsonb_build_object('viewer',v,'posts',a); end if;
  select coalesce(jsonb_agg(public.bl_post_json(x)),'[]') into b from (select z.* from public.bl_posts z join public.bl_channels ch on ch.id=z.channel_id where z.status='published' and ch.enabled and public.bl_test_visible(z.is_test) order by (select count(*) from public.bl_reactions r where r.target='post' and r.target_id=z.id and r.kind='like') desc,z.created_at desc limit 8) x;
  select coalesce(jsonb_agg(public.bl_post_json(x) order by x.created_at desc),'[]') into d from public.bl_posts x where x.pinned and x.status='published' and public.bl_test_visible(x.is_test);
  return jsonb_build_object('viewer',v,'posts',a,'popular',b,'notices',d,'channels',public.bl_channels_json(),'companies',c,'settings',(select jsonb_build_object('ai_enabled',ai_enabled) from public.bl_settings));
 end if;
 if p_scope='post' then
  select z.* into p from public.bl_posts z join public.bl_channels ch on ch.id=z.channel_id where z.id=(p_args->>'id')::uuid and (z.status='published' and ch.enabled or public.bl_is_admin()) and public.bl_test_visible(z.is_test);
  if p.id is null then select z.* into p from public.bl_posts z where z.id=(p_args->>'id')::uuid and z.status='hidden' and public.bl_test_visible(z.is_test); return jsonb_build_object('viewer',v,'post',null,'comments','[]'::jsonb,'ai_reply',null,'unavailable_reason',case when p.temporary_until is not null then 'temporary_hidden' else 'unavailable' end,'hidden_until',p.temporary_until); end if;
  a:='[]'; b:=null;
  if (public.bl_verified() or public.bl_is_admin()) and (p.status='published' or public.bl_is_admin()) then
   select coalesce(jsonb_agg(public.bl_comment_json(x) order by x.created_at),'[]') into a from public.bl_comments x where x.post_id=p.id and (x.status='published' or public.bl_is_admin()) and public.bl_test_visible(x.is_test) and (x.parent_id is null or exists(select 1 from public.bl_comments par where par.id=x.parent_id and par.status='published') or public.bl_is_admin());
   select jsonb_build_object('id',x.id,'body',x.body,'created_at',x.created_at,'label','보험라이브 AI 참고 답변') into b from public.bl_ai_replies x where x.post_id=p.id and x.status='published';
  end if;
  return jsonb_build_object('viewer',v,'post',public.bl_post_json(p),'comments',a,'ai_reply',b);
 end if;
 if p_scope='company' then
  select * into co from public.bl_companies where id=(p_args->>'id')::uuid and (enabled or public.bl_is_admin());
  select coalesce(jsonb_agg(public.bl_review_json(x) order by x.created_at desc),'[]') into a from public.bl_reviews x where x.company_id=co.id and x.status='published' and public.bl_test_visible(x.is_test);
  select coalesce(jsonb_agg(public.bl_post_json(x) order by x.created_at desc),'[]') into b from public.bl_posts x join public.bl_channels ch on ch.id=x.channel_id where x.company_id=co.id and x.status='published' and ch.enabled and public.bl_test_visible(x.is_test);
  return jsonb_build_object('viewer',v,'company',case when co.id is not null then public.bl_company_json(co) end,'reviews',a,'posts',b);
 end if;
 if p_scope in ('me','notifications') then
  perform public.bl_require(auth.uid() is not null,'로그인이 필요합니다.'); select * into prof from public.bl_profiles where id=auth.uid();
  select coalesce(jsonb_agg(public.bl_post_json(x) order by x.created_at desc),'[]') into a from public.bl_posts x where x.author_id=auth.uid() and x.status<>'deleted';
  select coalesce(jsonb_agg(public.bl_post_json(x) order by x.created_at desc),'[]') into b from public.bl_posts x join public.bl_reactions r on r.target_id=x.id and r.target='post' and r.kind='bookmark' and r.user_id=auth.uid() where x.status<>'deleted';
  select coalesce(jsonb_agg(to_jsonb(x)-'user_id' order by x.created_at desc),'[]') into c from public.bl_notifications x where x.user_id=auth.uid();
  d:='[]'; if public.bl_verified() or public.bl_is_admin() then select coalesce(jsonb_agg(public.bl_comment_json(x) order by x.created_at desc),'[]') into d from public.bl_comments x join public.bl_posts pp on pp.id=x.post_id where x.author_id=auth.uid() and x.status='published' and pp.status='published'; end if;
  select coalesce(jsonb_agg(public.bl_review_json(x) order by x.created_at desc),'[]') into e from public.bl_reviews x where x.author_id=auth.uid() and x.status='published';
  return jsonb_build_object('viewer',v,'profile',jsonb_build_object('nickname',prof.nickname,'company_id',prof.company_id,'company_name',prof.company_name,'status',prof.status,'review_reason',prof.review_reason,'verified_until',prof.verified_until,'name_masked',case when prof.name<>'' then left(prof.name,1)||'**' else '' end,'phone_masked',case when prof.phone<>'' then '***-****-'||right(prof.phone,4) else '' end,'has_proof',prof.proof_path is not null,'role',v->>'role'),'posts',a,'comments',d,'bookmarks',b,'notifications',c,'follows',(select coalesce(jsonb_agg(target_id),'[]') from public.bl_reactions where user_id=auth.uid() and kind='follow'),'reviews',e);
 end if;
 if p_scope='admin' then
  perform public.bl_require(public.bl_is_admin(),'관리자 권한이 필요합니다.'); perform public.bl_log('admin_read',coalesce(p_args->>'section','dashboard'));
  return jsonb_build_object('viewer',v,
   'dashboard',jsonb_build_object('members',(select count(*) from public.bl_profiles where status<>'withdrawn'),'pending',(select count(*) from public.bl_profiles where status='pending'),'reports',(select count(*) from public.bl_reports where status='pending'),'today_posts',(select count(*) from public.bl_posts where created_at>=date_trunc('day',now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'),'today_comments',(select count(*) from public.bl_comments where created_at>=date_trunc('day',now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul')),
   'members',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'nickname',p.nickname,'company_name',p.company_name,'status',p.status,'verified_until',p.verified_until,'role',coalesce(a.role,'member')) order by p.created_at desc),'[]') from public.bl_profiles p left join public.bl_admins a on a.user_id=p.id where p.nickname ilike '%'||coalesce(p_args->>'q','')||'%' or p.company_name ilike '%'||coalesce(p_args->>'q','')||'%'),
   'verifications',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'phone',p.phone,'registration_number',p.registration_number,'nickname',p.nickname,'company_id',p.company_id,'company_name',p.company_name,'status',p.status,'proof_path',p.proof_path,'submitted_at',p.proof_submitted_at,'review_reason',p.review_reason) order by p.proof_submitted_at desc),'[]') from public.bl_profiles p where p.status in ('pending','supplement','rejected','verified') and p.proof_path is not null),
   'posts',(select coalesce(jsonb_agg(public.bl_post_json(p) order by p.created_at desc),'[]') from public.bl_posts p),
   'comments',(select coalesce(jsonb_agg(public.bl_comment_json(p) order by p.created_at desc),'[]') from public.bl_comments p),
   'reports',(select coalesce(jsonb_agg(to_jsonb(p) order by p.created_at desc),'[]') from public.bl_reports p),
   'reviews',(select coalesce(jsonb_agg(public.bl_review_json(p) order by p.created_at desc),'[]') from public.bl_reviews p),
   'channels',public.bl_channels_json(),'companies',(select coalesce(jsonb_agg(public.bl_company_json(p) order by p.name),'[]') from public.bl_companies p),
   'ai_jobs',(select coalesce(jsonb_agg((to_jsonb(j)-'lease_token')||jsonb_build_object('answer',(select body from public.bl_ai_replies where post_id=j.post_id),'answer_status',(select status from public.bl_ai_replies where post_id=j.post_id)) order by j.created_at desc),'[]') from public.bl_ai_jobs j),
   'audit',(select coalesce(jsonb_agg(to_jsonb(z) order by z.id desc),'[]') from (select * from public.bl_audit order by id desc limit 200) z),
   'admins',(select coalesce(jsonb_agg(jsonb_build_object('id',a.user_id,'role',a.role,'nickname',p.nickname)),'[]') from public.bl_admins a join public.bl_profiles p on p.id=a.user_id),'settings',(select to_jsonb(s)-'id' from public.bl_settings s));
 end if;
 raise exception '지원하지 않는 조회입니다.';
end; $$;

create or replace function public.bl_action(p_action text,p_payload jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare u uuid:=auth.uid(); pr public.bl_profiles; oth public.bl_profiles; p public.bl_posts; cm public.bl_comments; rv public.bl_reviews; rp public.bl_reports; idv uuid; parentv uuid; companyv uuid; companyname text; targetv text; op text; st text; reasonv text; bodyv text; titlev text; nickv text; pathv text; sc int[]; activev boolean; authorv uuid; postv uuid; oldproof text; n int;
begin
 perform public.bl_require(u is not null,'로그인이 필요합니다.'); perform public.bl_ensure_profile();
 select * into pr from public.bl_profiles where id=u for update;
 perform public.bl_require(pr.status<>'withdrawn','탈퇴한 계정은 사용할 수 없습니다.');
 idv:=nullif(p_payload->>'id','')::uuid; reasonv:=left(coalesce(p_payload->>'reason',''),1000);
 if p_action='notification_read' then update public.bl_notifications set read_at=now() where user_id=u and (idv is null or id=idv); return jsonb_build_object('ok',true); end if;
 if p_action='withdraw' then
  perform public.bl_require(not public.bl_is_owner(),'대표 관리자 권한을 이전한 후 탈퇴할 수 있습니다.');
  if pr.proof_path is not null then insert into public.bl_proof_cleanup(path,user_id,due_at) values(pr.proof_path,u,now()) on conflict(path) do update set due_at=now(); end if;
  insert into public.bl_proof_cleanup(path,user_id,due_at) select name,u,now() from storage.objects where bucket_id='bl-proofs' and split_part(name,'/',1)=u::text on conflict(path) do update set due_at=now();
  update public.bl_profiles set status='withdrawn',name='',phone='',registration_number='',nickname='',company_id=null,company_name='',proof_path=null,proof_processed_at=now(),verified_until=null,review_reason='',updated_at=now() where id=u;
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
 perform public.bl_require(pr.status<>'suspended','이용 정지 상태입니다.');
 if p_action in ('profile_submit','profile_update') then
  nickv:=btrim(coalesce(p_payload->>'nickname',pr.nickname)); perform public.bl_require(length(nickv) between 2 and 20 and public.bl_safe_text(nickv),'닉네임은 개인정보 없이 2~20자로 입력해 주세요.');
  companyv:=case when p_payload ? 'company_id' then nullif(p_payload->>'company_id','')::uuid else pr.company_id end;
  if companyv is not null then select name into companyname from public.bl_companies where id=companyv and enabled; perform public.bl_require(companyname is not null,'소속 회사를 확인해 주세요.');
  else companyname:=btrim(coalesce(p_payload->>'company_name',pr.company_name)); end if;
  perform public.bl_require(length(companyname) between 2 and 80 and public.bl_safe_text(companyname),'소속 회사명을 2~80자로 입력해 주세요.');
  if p_action='profile_submit' then
   pathv:=p_payload->>'proof_path'; perform public.bl_require(split_part(pathv,'/',1)=u::text and exists(select 1 from storage.objects where bucket_id='bl-proofs' and name=pathv),'본인 증빙 사진 1장을 먼저 업로드해 주세요.');
   perform public.bl_require(length(btrim(p_payload->>'name')) between 2 and 60 and (p_payload->>'name') !~ '[0-9]' and (p_payload->>'name') !~ '@','이름을 입력해 주세요. 주민번호는 받지 않습니다.');
   perform public.bl_require((p_payload->>'phone') ~ '^\+?[0-9 ()-]{8,20}$' and length(regexp_replace(p_payload->>'phone','[^0-9]','','g')) between 9 and 12 and (p_payload->>'phone') !~ '[0-9]{6}[- ]?[1-8][0-9]{6}','연락처 형식을 확인해 주세요. 주민번호는 받지 않습니다.');
   perform public.bl_require(length(coalesce(p_payload->>'registration_number',''))<=40 and coalesce(p_payload->>'registration_number','') !~ '[0-9]{6}[- ]?[1-8][0-9]{6}','등록번호를 확인해 주세요. 주민번호는 받지 않습니다.');
   if pr.proof_path is not null and pr.proof_path<>pathv then insert into public.bl_proof_cleanup(path,user_id,due_at) values(pr.proof_path,u,now()+interval '30 days') on conflict do nothing; end if;
   delete from public.bl_proof_cleanup where path=pathv and deleted_at is null;
   update public.bl_profiles set name=btrim(p_payload->>'name'),nickname=nickv,company_id=companyv,company_name=companyname,phone=btrim(p_payload->>'phone'),registration_number=btrim(coalesce(p_payload->>'registration_number','')),proof_path=pathv,proof_submitted_at=now(),proof_processed_at=null,status='pending',verified_until=null,review_reason='',updated_at=now() where id=u;
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
  elsif op='ai_settings' then
   update public.bl_settings set ai_enabled=(p_payload->>'enabled')::boolean,ai_daily_limit=least(30,greatest(0,coalesce((p_payload->>'daily_limit')::int,ai_daily_limit)));
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
 perform public.bl_require(public.bl_verified() or public.bl_is_admin(),'설계사 인증 완료 후 이용할 수 있습니다.');
 if p_action='post_save' then
  titlev:=btrim(p_payload->>'title'); bodyv:=btrim(p_payload->>'body'); st:=p_payload->>'content_kind';
  perform public.bl_require(length(titlev) between 2 and 150 and length(bodyv) between 5 and 10000,'제목 2~150자, 본문 5~10000자로 입력해 주세요.'); perform public.bl_require(public.bl_safe_text(titlev||' '||bodyv),'주민번호·연락처·이메일 등 개인정보는 게시할 수 없습니다.');
  perform public.bl_require(st in ('practice','career','experience','weekly') and (st<>'weekly' or public.bl_is_admin()),'글 유형을 확인해 주세요.');
  perform public.bl_require(exists(select 1 from public.bl_channels where id=(p_payload->>'channel_id')::uuid and enabled),'활성 채널을 선택해 주세요.');
  companyv:=nullif(p_payload->>'company_id','')::uuid; if companyv is not null then perform public.bl_require(exists(select 1 from public.bl_companies where id=companyv and enabled),'회사 태그를 확인해 주세요.'); end if;
  if idv is null then
   perform public.bl_require((select count(*)<10 from public.bl_posts where author_id=u and created_at>=date_trunc('day',now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'),'하루 글 작성 한도 10개를 초과했습니다.');
   perform public.bl_require(not exists(select 1 from public.bl_posts where author_id=u and created_at>now()-interval '60 seconds'),'글은 60초 간격으로 작성할 수 있습니다.');
   insert into public.bl_posts(author_id,channel_id,company_id,title,body,content_kind,is_question,author_company,author_nickname,is_test) values(u,(p_payload->>'channel_id')::uuid,companyv,titlev,bodyv,st,coalesce((p_payload->>'is_question')::boolean,false),pr.company_name,pr.nickname,pr.is_test) returning id into idv;
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
   insert into public.bl_comments(post_id,author_id,parent_id,body,author_company,author_nickname,is_test) values(postv,u,parentv,bodyv,pr.company_name,pr.nickname,pr.is_test) returning id into idv;
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
  companyv:=(p_payload->>'company_id')::uuid; perform public.bl_require(public.bl_verified() and companyv=pr.company_id and exists(select 1 from public.bl_companies where id=companyv and enabled),'현재 인증된 소속 회사에만 리뷰를 작성할 수 있습니다.');
  select array_agg(value::int) into sc from jsonb_array_elements_text(p_payload->'scores'); perform public.bl_require(array_length(sc,1)=5 and 1<=all(sc) and 5>=all(sc),'별점 다섯 항목을 각각 1~5점으로 입력해 주세요.');
  titlev:=btrim(p_payload->>'title'); bodyv:=btrim(p_payload->>'body'); perform public.bl_require(length(titlev) between 2 and 150 and length(bodyv) between 10 and 5000 and public.bl_safe_text(titlev||' '||bodyv),'리뷰 제목·본문과 개인정보 포함 여부를 확인해 주세요.');
  if idv is null then
   perform public.bl_require(not exists(select 1 from public.bl_reviews where author_id=u and company_id=companyv and created_at>now()-interval '365 days'),'회사 리뷰는 365일에 1개만 작성할 수 있습니다. 기존 리뷰를 수정해 주세요.');
   insert into public.bl_reviews(author_id,company_id,title,body,scores,author_company,author_nickname,is_test) values(u,companyv,titlev,bodyv,sc,pr.company_name,pr.nickname,pr.is_test) returning id into idv;
  else update public.bl_reviews set title=titlev,body=bodyv,scores=sc,updated_at=now() where id=idv and author_id=u and company_id=companyv and status='published'; get diagnostics n=row_count; perform public.bl_require(n>0,'본인의 공개 중인 리뷰만 수정할 수 있습니다.'); end if;
  return jsonb_build_object('ok',true,'id',idv);
 elsif p_action='review_delete' then update public.bl_reviews set status='deleted',temporary_until=null,updated_at=now() where id=idv and author_id=u; get diagnostics n=row_count; perform public.bl_require(n>0,'본인 리뷰만 삭제할 수 있습니다.'); return jsonb_build_object('ok',true);
 end if;
 raise exception '지원하지 않는 작업입니다.';
end; $$;

alter table public.bl_ai_jobs add column if not exists source_updated_at timestamptz;
create table if not exists public.bl_ai_runs(id bigint generated always as identity primary key,job_id uuid not null references public.bl_ai_jobs(id),created_at timestamptz not null default now());
create or replace function public.bl_worker(p_action text,p_payload jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare j public.bl_ai_jobs; s public.bl_settings; p public.bl_posts; pr public.bl_profiles; rp public.bl_reports; idv uuid; leasev uuid; txt text; tit text; emailv text; cnt int; paths jsonb; affected int:=0; authorv uuid; st text;
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
  if length(pr.name)>=2 then txt:=replace(txt,pr.name,'[개인정보 삭제]'); tit:=replace(tit,pr.name,'[개인정보 삭제]'); end if;
  if length(pr.nickname)>=2 then txt:=replace(txt,pr.nickname,'[닉네임 삭제]'); tit:=replace(tit,pr.nickname,'[닉네임 삭제]'); end if;
  if length(pr.phone)>=4 then txt:=replace(txt,pr.phone,'[연락처 삭제]'); tit:=replace(tit,pr.phone,'[연락처 삭제]'); end if;
  if length(pr.registration_number)>=4 then txt:=replace(txt,pr.registration_number,'[등록번호 삭제]'); tit:=replace(tit,pr.registration_number,'[등록번호 삭제]'); end if;
  if length(emailv)>=4 then txt:=replace(txt,emailv,'[이메일 삭제]'); tit:=replace(tit,emailv,'[이메일 삭제]'); end if;
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
  insert into public.bl_ai_replies(post_id,body,status,model) values(j.post_id,txt,'review',left(coalesce(p_payload->>'model','claude'),80)) on conflict(post_id) do update set body=excluded.body,status='review',model=excluded.model,created_at=now();
  update public.bl_ai_jobs set status='review',lease_token=null,lease_until=null,completed_at=now() where id=idv;
  perform public.bl_log('ai_generated_review','post',j.post_id::text); return jsonb_build_object('ok',true,'status','review');
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
 elsif p_action='temporary_review' then
  for rp in select * from public.bl_reports where status='pending' and temporary_until<=now() order by created_at for update loop
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
end; $$;

-- 비공개 증빙: 업로드는 본인 폴더, 조회/서명 URL 발행은 담당 관리자만.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('bl-proofs','bl-proofs',false,5242880,array['image/jpeg','image/png','image/webp']) on conflict(id) do update set public=false,file_size_limit=5242880,allowed_mime_types=excluded.allowed_mime_types;
create or replace function public.bl_proof_upload_allowed(p_name text) returns boolean language sql stable security definer set search_path='' as $$ select auth.uid() is not null and split_part(p_name,'/',1)=auth.uid()::text and p_name ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$' and exists(select 1 from public.bl_profiles where id=auth.uid() and status not in ('withdrawn','suspended')) and (select count(*)<10 from storage.objects where bucket_id='bl-proofs' and split_part(name,'/',1)=auth.uid()::text and created_at>now()-interval '24 hours'); $$;
create or replace function public.bl_proof_read_allowed(p_name text) returns boolean language plpgsql security definer set search_path='' as $$ begin if not public.bl_is_admin() then return false; end if; perform public.bl_log('proof_signed_access','proof',null,jsonb_build_object('purpose','인증 심사')); return true; end; $$;
drop policy if exists bl_proof_insert on storage.objects;
create policy bl_proof_insert on storage.objects for insert to authenticated with check(bucket_id='bl-proofs' and public.bl_proof_upload_allowed(name));
drop policy if exists bl_proof_select on storage.objects;
create policy bl_proof_select on storage.objects for select to authenticated using(bucket_id='bl-proofs' and public.bl_proof_read_allowed(name));
-- 게시물·개인정보·정책·설정 원본을 직접 읽거나 변경할 수 없다. RPC만 허용.
do $$ declare t record; begin for t in select tablename from pg_tables where schemaname='public' and tablename like 'bl\_%' escape '\' loop execute format('alter table public.%I enable row level security',t.tablename); execute format('revoke all on table public.%I from public,anon,authenticated',t.tablename); end loop; end $$;
do $$ declare f record; begin for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'bl\_%' escape '\' loop execute format('revoke all on function %s from public,anon,authenticated',f.sig); end loop; end $$;
grant execute on function public.bl_read(text,jsonb) to anon,authenticated;
grant execute on function public.bl_action(text,jsonb) to authenticated;
grant execute on function public.bl_worker(text,jsonb) to service_role;
grant execute on function public.bl_proof_upload_allowed(text),public.bl_proof_read_allowed(text) to authenticated;

insert into public.bl_channels(slug,name,description,display_order) values
 ('career','이직·커리어','이직 준비와 경력, 시험·자격을 이야기해요.',1),
 ('product','상품 이야기','상품 구조와 약관 확인 방법을 나눠요.',2),
 ('claims','보상·심사','보상 절차와 서류, 심사 실무를 이야기해요.',3),
 ('marketing','고객확보·마케팅','고객정보 없이 영업 경험과 안내 방법을 나눠요.',4),
 ('ga','GA·전속','조직 선택과 정산의 일반 원칙을 이야기해요.',5),
 ('free','자유 수다','설계사의 일상과 경험을 편하게 나눠요.',6)
on conflict(slug) do nothing;
insert into public.bl_companies(name,kind) values
 ('삼성생명','보험사'),('한화생명','보험사'),('교보생명','보험사'),('신한라이프','보험사'),('KB라이프생명','보험사'),('NH농협생명','보험사'),('미래에셋생명','보험사'),('동양생명','보험사'),('흥국생명','보험사'),('메트라이프생명','보험사'),('라이나생명','보험사'),('ABL생명','보험사'),('삼성화재','보험사'),('현대해상','보험사'),('DB손해보험','보험사'),('KB손해보험','보험사'),('메리츠화재','보험사'),('한화손해보험','보험사'),('롯데손해보험','보험사'),('흥국화재','보험사'),('NH농협손해보험','보험사'),('하나손해보험','보험사'),('프라임에셋','GA'),('인카금융서비스','GA'),('글로벌금융판매','GA'),('지에이코리아','GA'),('한국보험금융','GA'),('피플라이프','GA'),('에이플러스에셋','GA'),('리치앤코','GA')
on conflict(name) do nothing;
insert into public.bl_posts(channel_id,title,body,content_kind,pinned) select id,'보험라이브에 오신 것을 환영합니다','보험라이브는 보험설계사의 실무와 경험을 나누는 공간입니다. Google 또는 이메일로 로그인한 뒤 현재 소속 증빙을 제출하면 심사를 거쳐 참여할 수 있습니다. 공개 화면에는 회사명과 닉네임 첫 글자만 표시됩니다. 아직 정식 공개 전 점검 중입니다.','weekly',true from public.bl_channels where slug='career' and not exists(select 1 from public.bl_posts where author_id is null and title='보험라이브에 오신 것을 환영합니다');
insert into public.bl_posts(channel_id,title,body,content_kind,pinned) select id,'개인정보 보호와 신고 처리 안내','고객 이름·연락처·주민번호·내부 자료를 올리지 마세요. 허위사실이나 명예훼손, 개인정보가 포함된 게시물은 신고할 수 있습니다. 신고 접수 시 해당 내용은 최대 30일 임시로 가리고 당사자에게 알립니다. 운영자가 소명을 검토해 복구 또는 운영정책에 따른 최종 가림을 결정하며, 미결 상태로 30일이 지나면 자동 복구합니다. 회원이 작성한 글과 AI 참고 답변은 개인 의견과 참고 정보이며 공식 보험상품 안내나 법률·세무 판단을 대신하지 않습니다.','weekly',true from public.bl_channels where slug='free' and not exists(select 1 from public.bl_posts where author_id is null and title='개인정보 보호와 신고 처리 안내');
insert into public.bl_profiles(id) select id from auth.users where encode(sha256(convert_to(lower(email),'UTF8')),'hex')='2d2741150415225d6626feb209851c88a71bc07afeb6aa9cba8f0b0477d17cbc' and email_confirmed_at is not null on conflict do nothing;
insert into public.bl_admins(user_id,role) select id,'owner' from auth.users where encode(sha256(convert_to(lower(email),'UTF8')),'hex')='2d2741150415225d6626feb209851c88a71bc07afeb6aa9cba8f0b0477d17cbc' and email_confirmed_at is not null on conflict do nothing;
commit;
