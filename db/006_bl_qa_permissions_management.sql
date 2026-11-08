-- QA 2026-11-08: deployed pg_get_functiondef baseline, permission separation,
-- atomic channel deletion/company merge, public sample flags, real activity metrics.
begin;
alter table public.bl_profiles add column if not exists is_sample boolean not null default false;
alter table public.bl_posts add column if not exists is_sample boolean not null default false;
alter table public.bl_comments add column if not exists is_sample boolean not null default false;
alter table public.bl_reviews add column if not exists is_sample boolean not null default false;
-- An actual FK also serializes concurrent profile affiliation writes against company deletion.
do $$ begin
 if not exists(select 1 from pg_constraint where conrelid='public.bl_profiles'::regclass and conname='bl_profiles_company_fk') then
  alter table public.bl_profiles add constraint bl_profiles_company_fk foreign key(company_id) references public.bl_companies(id) on delete restrict;
 end if;
end $$;
create or replace function public.bl_can_write() returns boolean language sql stable security definer set search_path='' as $$ select public.bl_is_owner() or public.bl_verified(); $$;
revoke all on function public.bl_can_write() from public,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.bl_viewer()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select jsonb_build_object('status',p.status,'role',coalesce(a.role,'member'),'nickname',p.nickname,'company_name',p.company_name,'verified_until',p.verified_until,'is_test',p.is_test,'is_sample',p.is_sample,'can_write',public.bl_can_write(),'can_admin',public.bl_is_admin(),'verification_exempt',public.bl_is_owner()) from public.bl_profiles p left join public.bl_admins a on a.user_id=p.id where p.id=auth.uid(); $function$;

CREATE OR REPLACE FUNCTION public.bl_channels_json()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'slug',c.slug,'name',c.name,'description',c.description,'display_order',c.display_order,'enabled',c.enabled,'post_count',case when public.bl_is_admin() then (select count(*) from public.bl_posts p where p.channel_id=c.id) end,'followers',(select count(*) from public.bl_reactions r where r.target='channel' and r.target_id=c.id and r.kind='follow'),'following',exists(select 1 from public.bl_reactions r where r.user_id=auth.uid() and r.target='channel' and r.target_id=c.id and r.kind='follow')) order by c.display_order),'[]') from public.bl_channels c where c.enabled or public.bl_is_admin(); $function$;

CREATE OR REPLACE FUNCTION public.bl_company_json(c public.bl_companies)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select jsonb_build_object('id',c.id,'name',c.name,'kind',c.kind,'description',c.description,'enabled',c.enabled,'post_count',case when public.bl_is_admin() then (select count(*) from public.bl_posts p where p.company_id=c.id) end,'total_review_count',case when public.bl_is_admin() then (select count(*) from public.bl_reviews r where r.company_id=c.id) end,'member_count',case when public.bl_is_admin() then (select count(*) from public.bl_profiles p where p.company_id=c.id) end,'reference_count',case when public.bl_is_admin() then (select count(*) from public.bl_posts p where p.company_id=c.id)+(select count(*) from public.bl_reviews r where r.company_id=c.id)+(select count(*) from public.bl_profiles p where p.company_id=c.id) end,'review_count',s.n,'average',case when s.n>=5 then round((s.a1+s.a2+s.a3+s.a4+s.a5)/5,2) end,'scores',case when s.n>=5 then jsonb_build_array(round(s.a1,2),round(s.a2,2),round(s.a3,2),round(s.a4,2),round(s.a5,2)) end) from (select count(*) n,avg(r.scores[1]) a1,avg(r.scores[2]) a2,avg(r.scores[3]) a3,avg(r.scores[4]) a4,avg(r.scores[5]) a5 from (select distinct on (author_id) * from public.bl_reviews where company_id=c.id and status='published' and not is_test and not is_sample order by author_id,created_at desc,id) r) s; $function$;

CREATE OR REPLACE FUNCTION public.bl_post_json(p public.bl_posts)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select jsonb_build_object('id',p.id,'is_sample',p.is_sample,'channel_id',p.channel_id,'channel_name',(select name from public.bl_channels where id=p.channel_id),'company_id',p.company_id,'company_name',(select name from public.bl_companies where id=p.company_id),'title',case when p.status='published' or public.bl_is_admin() then p.title else '가려진 게시물' end,'body',case when p.status<>'published' and not public.bl_is_admin() then '' when p.content_kind='experience' and not(public.bl_verified() or public.bl_is_admin()) then left(p.body,300) else p.body end,'content_kind',p.content_kind,'is_question',p.is_question,'author_display',public.bl_author(p.author_id,p.author_company,p.author_nickname),'created_at',p.created_at,'updated_at',p.updated_at,'status',p.status,'pinned',p.pinned,'likes',(select count(*) from public.bl_reactions r where r.target='post' and r.target_id=p.id and r.kind='like'),'comment_count',(select count(*) from public.bl_comments c where c.post_id=p.id and c.status='published' and public.bl_test_visible(c.is_test)),'liked',exists(select 1 from public.bl_reactions r where r.user_id=auth.uid() and r.target='post' and r.target_id=p.id and r.kind='like'),'bookmarked',exists(select 1 from public.bl_reactions r where r.user_id=auth.uid() and r.target='post' and r.target_id=p.id and r.kind='bookmark'),'is_mine',coalesce(p.author_id=auth.uid(),false),'is_truncated',p.content_kind='experience' and length(p.body)>300 and not(public.bl_verified() or public.bl_is_admin())); $function$;

CREATE OR REPLACE FUNCTION public.bl_comment_json(c public.bl_comments)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select jsonb_build_object('id',c.id,'is_sample',c.is_sample,'post_id',c.post_id,'parent_id',c.parent_id,'body',c.body,'author_display',public.bl_author(c.author_id,c.author_company,c.author_nickname),'created_at',c.created_at,'updated_at',c.updated_at,'status',c.status,'likes',(select count(*) from public.bl_reactions r where r.target='comment' and r.target_id=c.id and r.kind='like'),'liked',exists(select 1 from public.bl_reactions r where r.user_id=auth.uid() and r.target='comment' and r.target_id=c.id and r.kind='like'),'is_mine',c.author_id=auth.uid()); $function$;

CREATE OR REPLACE FUNCTION public.bl_review_json(r public.bl_reviews)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select jsonb_build_object('id',r.id,'is_sample',r.is_sample,'company_id',r.company_id,'title',r.title,'body',case when public.bl_verified() or public.bl_is_admin() then r.body else left(r.body,300) end,'scores',r.scores,'author_display',public.bl_author(r.author_id,r.author_company,r.author_nickname),'created_at',r.created_at,'updated_at',r.updated_at,'status',r.status,'is_mine',r.author_id=auth.uid(),'is_truncated',length(r.body)>300 and not(public.bl_verified() or public.bl_is_admin())); $function$;

CREATE OR REPLACE FUNCTION public.bl_read(p_scope text, p_args jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
declare v jsonb; a jsonb; b jsonb; c jsonb; d jsonb; e jsonb; p public.bl_posts; co public.bl_companies; prof public.bl_profiles; lim int:=least(100,greatest(1,coalesce((p_args->>'limit')::int,50)));
begin
 perform public.bl_ensure_profile(); v:=public.bl_viewer();
 if p_scope='channels' then return jsonb_build_object('viewer',v,'channels',public.bl_channels_json()); end if;
 if p_scope in ('companies','home') then select coalesce(jsonb_agg(public.bl_company_json(x) order by x.name),'[]') into c from public.bl_companies x where x.enabled or public.bl_is_admin(); end if;
 if p_scope='companies' then return jsonb_build_object('viewer',v,'companies',c); end if;
 if p_scope in ('home','posts','search') then
  select coalesce(jsonb_agg(public.bl_post_preview(x)),'[]') into a from (select z.* from public.bl_posts z join public.bl_channels ch on ch.id=z.channel_id where z.status='published' and ch.enabled and public.bl_test_visible(z.is_test) and (nullif(p_args->>'channel_id','') is null or z.channel_id=(p_args->>'channel_id')::uuid) and (nullif(p_args->>'company_id','') is null or z.company_id=(p_args->>'company_id')::uuid) and (coalesce(p_args->>'q','')='' or z.title ilike '%'||(p_args->>'q')||'%' or (case when z.content_kind='experience' then left(z.body,300) else z.body end) ilike '%'||(p_args->>'q')||'%') order by z.pinned desc,case when p_args->>'sort'='popular' then (select count(*) from public.bl_reactions r where r.target='post' and r.target_id=z.id and r.kind='like') else 0 end desc,z.created_at desc limit lim) x;
  if p_scope<>'home' then return jsonb_build_object('viewer',v,'posts',a); end if;
  select coalesce(jsonb_agg(public.bl_post_preview(x)),'[]') into b from (select z.* from public.bl_posts z join public.bl_channels ch on ch.id=z.channel_id where z.status='published' and ch.enabled and public.bl_test_visible(z.is_test) order by (select count(*) from public.bl_reactions r where r.target='post' and r.target_id=z.id and r.kind='like') desc,z.created_at desc limit 8) x;
  select coalesce(jsonb_agg(public.bl_post_preview(x) order by x.created_at desc),'[]') into d from public.bl_posts x where x.pinned and x.status='published' and public.bl_test_visible(x.is_test);
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
  select coalesce(jsonb_agg(public.bl_post_preview(x) order by x.created_at desc),'[]') into b from public.bl_posts x join public.bl_channels ch on ch.id=x.channel_id where x.company_id=co.id and x.status='published' and ch.enabled and public.bl_test_visible(x.is_test);
  return jsonb_build_object('viewer',v,'company',case when co.id is not null then public.bl_company_json(co) end,'reviews',a,'posts',b);
 end if;
 if p_scope in ('me','notifications') then
  perform public.bl_require(auth.uid() is not null,'로그인이 필요합니다.'); select * into prof from public.bl_profiles where id=auth.uid();
  select coalesce(jsonb_agg(public.bl_post_preview(x) order by x.created_at desc),'[]') into a from public.bl_posts x where x.author_id=auth.uid() and x.status<>'deleted';
  select coalesce(jsonb_agg(public.bl_post_preview(x) order by x.created_at desc),'[]') into b from public.bl_posts x join public.bl_reactions r on r.target_id=x.id and r.target='post' and r.kind='bookmark' and r.user_id=auth.uid() where x.status<>'deleted';
  select coalesce(jsonb_agg(to_jsonb(x)-'user_id' order by x.created_at desc),'[]') into c from public.bl_notifications x where x.user_id=auth.uid();
  d:='[]'; if public.bl_verified() or public.bl_is_admin() then select coalesce(jsonb_agg(public.bl_comment_json(x) order by x.created_at desc),'[]') into d from public.bl_comments x join public.bl_posts pp on pp.id=x.post_id where x.author_id=auth.uid() and x.status='published' and pp.status='published'; end if;
  select coalesce(jsonb_agg(public.bl_review_json(x) order by x.created_at desc),'[]') into e from public.bl_reviews x where x.author_id=auth.uid() and x.status='published';
  return jsonb_build_object('viewer',v,'profile',jsonb_build_object('nickname',prof.nickname,'company_id',prof.company_id,'company_name',prof.company_name,'status',prof.status,'review_reason',prof.review_reason,'verified_until',prof.verified_until,'name_masked',case when prof.name<>'' then left(prof.name,1)||'**' else '' end,'phone_masked',case when prof.phone<>'' then '***-****-'||right(prof.phone,4) else '' end,'has_proof',prof.proof_path is not null,'role',v->>'role'),'posts',a,'comments',d,'bookmarks',b,'notifications',c,'follows',(select coalesce(jsonb_agg(target_id),'[]') from public.bl_reactions where user_id=auth.uid() and kind='follow'),'reviews',e);
 end if;
 if p_scope='admin' then
  perform public.bl_require(public.bl_is_admin(),'관리자 권한이 필요합니다.'); perform public.bl_log('admin_read',coalesce(p_args->>'section','dashboard'));
  return jsonb_build_object('viewer',v,
   'dashboard',jsonb_build_object('counts_exclude_test_and_sample',true,
    'members',(select count(*) from public.bl_profiles where status<>'withdrawn' and not is_test and not is_sample),
    'pending',(select count(*) from public.bl_profiles where status='pending' and not is_test and not is_sample),
    'reports',(select count(*) from public.bl_reports r join public.bl_profiles u on u.id=r.reporter_id where r.status='pending' and not u.is_test and not u.is_sample and case r.target when 'post' then exists(select 1 from public.bl_posts p where p.id=r.target_id and not p.is_test and not p.is_sample and p.status<>'deleted') when 'comment' then exists(select 1 from public.bl_comments c where c.id=r.target_id and not c.is_test and not c.is_sample and c.status<>'deleted') else exists(select 1 from public.bl_reviews v where v.id=r.target_id and not v.is_test and not v.is_sample and v.status<>'deleted') end),
    'today_posts',(select count(*) from public.bl_posts where not is_test and not is_sample and status<>'deleted' and created_at>=date_trunc('day',now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul'),
    'today_comments',(select count(*) from public.bl_comments where not is_test and not is_sample and status<>'deleted' and created_at>=date_trunc('day',now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul')),
   'members',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'nickname',p.nickname,'company_name',p.company_name,'status',p.status,'verified_until',p.verified_until,'role',coalesce(a.role,'member'),'is_test',p.is_test,'is_sample',p.is_sample) order by p.created_at desc),'[]') from public.bl_profiles p left join public.bl_admins a on a.user_id=p.id where p.nickname ilike '%'||coalesce(p_args->>'q','')||'%' or p.company_name ilike '%'||coalesce(p_args->>'q','')||'%'),
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
end; $function$;

CREATE OR REPLACE FUNCTION public.bl_action_internal(p_action text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
declare u uuid:=auth.uid(); pr public.bl_profiles; oth public.bl_profiles; p public.bl_posts; cm public.bl_comments; rv public.bl_reviews; rp public.bl_reports; idv uuid; parentv uuid; companyv uuid; companyname text; targetv text; op text; st text; reasonv text; bodyv text; titlev text; nickv text; pathv text; sc int[]; activev boolean; authorv uuid; postv uuid; oldproof text; n int; destination uuid; moved int; moved_reviews int; moved_members int; destination_name text;
begin
 perform public.bl_require(u is not null,'로그인이 필요합니다.'); perform public.bl_ensure_profile();
 -- Match company deletion's lock order, so a concurrent affiliation change cannot deadlock or retain a deleted company.
 if p_action in ('profile_submit','profile_update') and nullif(p_payload->>'company_id','') is not null then
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
  perform public.bl_require(((public.bl_is_owner() and p_action='profile_update' and not (p_payload ? 'company_id' or p_payload ? 'company_name')) or (length(companyname) between 2 and 80 and public.bl_safe_text(companyname))),'소속 회사명을 2~80자로 입력해 주세요.');
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
end; $function$;
revoke all on function public.bl_action_internal(text,jsonb) from public,anon,authenticated,service_role;
notify pgrst, 'reload schema';
commit;
