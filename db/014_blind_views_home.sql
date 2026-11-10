-- 014 블라인드형 개편 1 (2026-11-10, TASK-BLIND A~C단계)
-- * 33 조회수: bl_posts.view_count. 글 화면이 처음 열릴 때만(view=1) 1 올린다. 내 글·가려진 글은 세지 않고, 시험 계정의 조회는 시험 글에서만 센다.
-- * 37 인기 글만: bl_read('best') → {viewer,best}.
-- * 3 홈: bl_read('home',{v:'3'}) → {viewer,notices,best(인기 글 10),boxes([{channel_id,posts(최신 5)}]),channels}. v 없는 예전 호출은 그대로.
-- * 글 응답(post DTO)에 views 추가. 권한 규칙(손님 300자·댓글은 인증 회원만 등)은 바꾸지 않는다.
begin;
alter table public.bl_posts add column if not exists view_count integer not null default 0;

CREATE OR REPLACE FUNCTION public.bl_post_json(p bl_posts)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select jsonb_build_object('id',p.id,'is_sample',p.is_sample,'channel_id',p.channel_id,'channel_name',(select name from public.bl_channels where id=p.channel_id),'company_id',p.company_id,'company_name',(select name from public.bl_companies where id=p.company_id),'title',case when p.status='published' or public.bl_is_admin() or (p.author_id=auth.uid() and p.status='hidden') then p.title else '가려진 게시물' end,'body',case when p.status<>'published' and not public.bl_is_admin() and not (p.author_id=auth.uid() and p.status='hidden') then '' when p.content_kind='experience' and not(public.bl_verified() or public.bl_is_admin()) then left(p.body,300) else p.body end,'content_kind',p.content_kind,'is_question',p.is_question,'author_display',case when p.as_team then '보험라이브 운영팀' when p.anonymous then '익명' else public.bl_author(p.author_id,p.author_company,p.author_nickname) end,'as_team',p.as_team,'anonymous',p.anonymous,'pinned_order',p.pinned_order,'created_at',p.created_at,'updated_at',p.updated_at,'status',p.status,'pinned',p.pinned,'views',p.view_count,'likes',(select count(*) from public.bl_reactions r where r.target='post' and r.target_id=p.id and r.kind='like'),'comment_count',(select count(*) from public.bl_comments c where c.post_id=p.id and c.status='published' and public.bl_test_visible(c.is_test)),'liked',exists(select 1 from public.bl_reactions r where r.user_id=auth.uid() and r.target='post' and r.target_id=p.id and r.kind='like'),'bookmarked',exists(select 1 from public.bl_reactions r where r.user_id=auth.uid() and r.target='post' and r.target_id=p.id and r.kind='bookmark'),'is_mine',coalesce(p.author_id=auth.uid(),false),'is_truncated',p.content_kind='experience' and length(p.body)>300 and not(public.bl_verified() or public.bl_is_admin())); $function$;

CREATE OR REPLACE FUNCTION public.bl_read(p_scope text, p_args jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
declare v jsonb; a jsonb; b jsonb; c jsonb; d jsonb; e jsonb; p public.bl_posts; co public.bl_companies; prof public.bl_profiles; lim int:=least(100,greatest(1,coalesce((p_args->>'limit')::int,50))); n int;
begin
 perform public.bl_ensure_profile(); v:=public.bl_viewer();
 -- 잘못된 주소(번호 형식이 틀림)는 오류 대신 '찾을 수 없음'으로 답한다.
 if p_scope in ('post','company') and coalesce(p_args->>'id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
  if p_scope='post' then return jsonb_build_object('viewer',v,'post',null,'comments','[]'::jsonb,'ai_reply',null,'unavailable_reason','not_found'); end if;
  return jsonb_build_object('viewer',v,'company',null,'reviews','[]'::jsonb,'posts','[]'::jsonb);
 end if;
 if coalesce(p_args->>'channel_id','')<>'' and (p_args->>'channel_id') !~* '^[0-9a-f-]{36}$' then p_args:=p_args||'{"channel_id":"00000000-0000-0000-0000-000000000000"}'; end if;
 if coalesce(p_args->>'company_id','')<>'' and (p_args->>'company_id') !~* '^[0-9a-f-]{36}$' then p_args:=p_args||'{"company_id":"00000000-0000-0000-0000-000000000000"}'; end if;
 if p_scope='channels' then return jsonb_build_object('viewer',v,'channels',public.bl_channels_json()); end if;
 if p_scope in ('companies','home') then select coalesce(jsonb_agg(public.bl_company_json(x) order by x.name),'[]') into c from public.bl_companies x where x.enabled or public.bl_is_admin(); end if;
 if p_scope='companies' then return jsonb_build_object('viewer',v,'companies',c); end if;
 -- 2026-11-10 블라인드형 홈: 공지, 인기 글 10개, 채널별 최신 글 5개(공지 제외). 'best'는 인기 글만. 예전 화면(v 없음)은 아래 기존 응답을 그대로 받는다.
 if p_scope='best' or (p_scope='home' and p_args->>'v'='3') then
  select coalesce(jsonb_agg(public.bl_post_preview(z) order by t.rk),'[]') into b
   from (select z0.id,row_number() over(order by (z0.created_at>now()-interval '30 days') desc,
      (select count(*) from public.bl_reactions r where r.target='post' and r.target_id=z0.id and r.kind='like') desc,
      (select count(*) from public.bl_comments cm where cm.post_id=z0.id and cm.status='published') desc,
      z0.view_count desc,z0.created_at desc) rk
     from public.bl_posts z0 join public.bl_channels ch on ch.id=z0.channel_id
     where z0.status='published' and not z0.pinned and ch.enabled and public.bl_test_visible(z0.is_test)) t
   join public.bl_posts z on z.id=t.id where t.rk<=10;
  if p_scope='best' then return jsonb_build_object('viewer',v,'best',b); end if;
  select coalesce(jsonb_agg(public.bl_post_preview(x) order by x.pinned_order,x.created_at desc),'[]') into d from public.bl_posts x where x.pinned and x.status='published' and public.bl_test_visible(x.is_test);
  select coalesce(jsonb_agg(jsonb_build_object('channel_id',ch.id,'posts',
     (select coalesce(jsonb_agg(public.bl_post_preview(z) order by z.created_at desc),'[]') from (select z1.* from public.bl_posts z1 where z1.channel_id=ch.id and z1.status='published' and not z1.pinned and public.bl_test_visible(z1.is_test) order by z1.created_at desc limit 5) z)) order by ch.display_order),'[]') into a
   from public.bl_channels ch where ch.enabled;
  return jsonb_build_object('viewer',v,'notices',d,'best',b,'boxes',a,'channels',public.bl_channels_json());
 end if;
 if p_scope in ('home','posts','search') then
  select coalesce(jsonb_agg(public.bl_post_preview(x)),'[]') into a from (select z.* from public.bl_posts z join public.bl_channels ch on ch.id=z.channel_id where z.status='published' and ch.enabled and public.bl_test_visible(z.is_test) and (nullif(p_args->>'channel_id','') is null or z.channel_id=(p_args->>'channel_id')::uuid) and (nullif(p_args->>'company_id','') is null or z.company_id=(p_args->>'company_id')::uuid) and (coalesce(p_args->>'q','')='' or z.title ilike public.bl_like(p_args->>'q') or (case when z.content_kind='experience' then left(z.body,300) else z.body end) ilike public.bl_like(p_args->>'q')) order by z.pinned desc,z.pinned_order,case when p_args->>'sort'='popular' then (select count(*) from public.bl_reactions r where r.target='post' and r.target_id=z.id and r.kind='like') else 0 end desc,z.created_at desc offset greatest(0,least(5000,coalesce((p_args->>'offset')::int,0))) limit lim) x;
  if p_scope<>'home' then return jsonb_build_object('viewer',v,'posts',a); end if;
  select coalesce(jsonb_agg(public.bl_post_preview(x)),'[]') into b from (select z.* from public.bl_posts z join public.bl_channels ch on ch.id=z.channel_id where z.status='published' and ch.enabled and public.bl_test_visible(z.is_test) order by (select count(*) from public.bl_reactions r where r.target='post' and r.target_id=z.id and r.kind='like') desc,z.created_at desc limit 8) x;
  select coalesce(jsonb_agg(public.bl_post_preview(x) order by x.pinned_order,x.created_at desc),'[]') into d from public.bl_posts x where x.pinned and x.status='published' and public.bl_test_visible(x.is_test);
  return jsonb_build_object('viewer',v,'posts',a,'popular',b,'notices',d,'channels',public.bl_channels_json(),'companies',c,'settings',(select jsonb_build_object('ai_enabled',ai_enabled) from public.bl_settings));
 end if;
 if p_scope='post' then
  select z.* into p from public.bl_posts z join public.bl_channels ch on ch.id=z.channel_id where z.id=(p_args->>'id')::uuid and (z.status='published' and ch.enabled or public.bl_is_admin() or (z.status='hidden' and z.author_id=auth.uid())) and public.bl_test_visible(z.is_test);
  if p.id is null then select z.* into p from public.bl_posts z where z.id=(p_args->>'id')::uuid and z.status='hidden' and public.bl_test_visible(z.is_test); return jsonb_build_object('viewer',v,'post',null,'comments','[]'::jsonb,'ai_reply',null,'unavailable_reason',case when p.temporary_until is not null then 'temporary_hidden' else 'unavailable' end,'hidden_until',p.temporary_until); end if;
  a:='[]'; b:=null;
  if coalesce(p_args->>'view','') in ('1','true') and p.status='published' and p.author_id is distinct from auth.uid() and (p.is_test or not public.bl_viewer_is_test()) then
   update public.bl_posts set view_count=view_count+1 where id=p.id returning view_count into n;
   p.view_count:=n;
  end if;
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
  return jsonb_build_object('viewer',v)||public.bl_admin_read(p_args->>'section',p_args);
 end if;
 raise exception '지원하지 않는 조회입니다.';
end; $function$;

revoke all on function public.bl_post_json(public.bl_posts) from public,anon,authenticated;
revoke all on function public.bl_read(text,jsonb) from public;
grant execute on function public.bl_read(text,jsonb) to anon,authenticated,service_role;
notify pgrst, 'reload schema';
commit;
