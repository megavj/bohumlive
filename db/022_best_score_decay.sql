-- 022: 홈(v=3)·PC 오른쪽 인기 글에 점수와 시간 감쇠 적용(대표 승인 2026-11-10).
-- 최근 30일 우선, 부족할 때만 이전 글로 10개 보충. 지수 1.2, 점수 0끼리는 최신 순.
-- AI 참고 답변은 점수에서 제외. 채널 인기순·HOT·다른 bl_read 범위는 그대로.
-- 원복: 20261110_보라인기글/backup/bl_read.before.sql 실행.
begin;
-- 다른 작업이 그동안 바꾼 함수라면 중단하여 팔로우·알림 변경을 덮어쓰지 않는다.
do $guard$ begin
 if md5(pg_get_functiondef('public.bl_read(text,jsonb)'::regprocedure)) not in ('009347f1803c33b9740024ca45b111e9','6521819db039ab8ceea9214bc4c9e2b6') then
  raise exception 'bl_read changed since HOT backup; stop rather than overwrite';
 end if;
end $guard$;

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
  -- 022: 최근 30일 우선, (좋아요*3 + 공개 사람 댓글*2 + 조회수/100 + 1) / (경과 시간+2)^1.2.
  -- 최근 글이 10개 이상이면 과거 글은 읽지 않는다. 후보별 반응은 종류마다 한 번에 집계한다.
  with recent as materialized (
   select z0.id,z0.created_at,z0.view_count,true as is_recent
    from public.bl_posts z0 join public.bl_channels ch on ch.id=z0.channel_id
    where z0.status='published' and not z0.pinned and ch.enabled and public.bl_test_visible(z0.is_test)
      and z0.created_at>now()-interval '30 days'
  ), candidates as materialized (
   select * from recent
   union all
   select z0.id,z0.created_at,z0.view_count,false as is_recent
    from public.bl_posts z0 join public.bl_channels ch on ch.id=z0.channel_id
    where (select count(*) from recent)<10
      and z0.status='published' and not z0.pinned and ch.enabled and public.bl_test_visible(z0.is_test)
      and z0.created_at<=now()-interval '30 days'
  ), likes as (
   select r.target_id,count(*) as n from public.bl_reactions r
    where r.target='post' and r.kind='like' and r.target_id=any(array(select ca.id from candidates ca)) group by r.target_id
  ), comments as (
   select cm.post_id,count(*) as n from public.bl_comments cm
    where cm.status='published' and cm.post_id=any(array(select ca.id from candidates ca)) group by cm.post_id
  ), scored as (
   select ca.*,(coalesce(l.n,0)*3+coalesce(cm.n,0)*2+ca.view_count::numeric/100+1)
     /power(greatest(0,extract(epoch from now()-ca.created_at)/3600)+2,1.2) as rank_score
    from candidates ca left join likes l on l.target_id=ca.id left join comments cm on cm.post_id=ca.id
  ), top_posts as (
   select id,row_number() over(order by is_recent desc,rank_score desc,created_at desc,id) as rk
    from scored order by is_recent desc,rank_score desc,created_at desc,id limit 10
  )
  select coalesce(jsonb_agg(public.bl_post_preview(z) order by t.rk),'[]') into b
   from top_posts t join public.bl_posts z on z.id=t.id;
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
  if auth.uid() is not null then
   update public.bl_notifications set read_at=now() where user_id=auth.uid() and post_id=p.id and read_at is null and (kind='follow' or kind in ('comment','reply') and (public.bl_verified() or public.bl_is_admin()));
   get diagnostics n=row_count; if n>0 then v:=public.bl_viewer(); end if;
  end if;
  if coalesce(p_args->>'view','') in ('1','true') and p.status='published' and (auth.uid() is null or p.author_id is distinct from auth.uid()) and (p.is_test or not public.bl_viewer_is_test()) then
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
  -- 2026-11-10 알림 묶음(추가 지시 2): 같은 종류의 읽지 않은 알림이 같은 대상(내 글=댓글, 내 원댓글=답글, 채널=새 글)에
  -- 5개 이상이면 한 줄로 묶는다(개수=실제 읽지 않은 수). 4개 이하는 하나씩. 팔로우 새 글은 읽으면 사라지고,
  -- 댓글·답글은 읽은 뒤에도 남되 같은 대상의 읽은 알림이 5개 이상이면 역시 한 줄로 보인다. 볼 수 없게 된 글·댓글의 알림은 빠진다.
  select coalesce(jsonb_agg(q.j order by q.t desc),'[]') into c from (
   select case
     when g.cnt>=5 and g.kind='follow' then jsonb_build_object('id',null,'kind','follow_group','title',g.cname||' 채널에 '||g.cnt||'개의 새 글이 있습니다','body','','post_id',null,'channel_id',g.channel_id,'comment_id',null,'anchor','','count',g.cnt,'read_at',null,'created_at',g.last_at)
     when g.cnt>=5 and g.kind='comment' then jsonb_build_object('id',null,'kind','comment_group','title','내 글 '''||g.pshort||'''에 '||g.cnt||'개의 댓글이 달렸습니다','body','','post_id',g.post_id,'channel_id',null,'comment_id',null,'anchor','comments','count',g.cnt,'read_at',g.group_read,'created_at',g.last_at)
     when g.cnt>=5 and g.kind='reply' then jsonb_build_object('id',null,'kind','reply_group','title','내 댓글에 '||g.cnt||'개의 답글이 달렸습니다','body',g.psnip,'post_id',g.post_id,'channel_id',null,'comment_id',g.parent_id,'anchor','comment-'||g.parent_id,'count',g.cnt,'read_at',g.group_read,'created_at',g.last_at)
     when g.kind='follow' then jsonb_build_object('id',g.id,'kind','follow','title',g.cname||' 채널 새 글: '||g.ptitle,'body','','post_id',g.post_id,'channel_id',g.channel_id,'comment_id',null,'anchor','','count',1,'read_at',null,'created_at',g.created_at)
     when g.kind='comment' and g.comment_id is not null then jsonb_build_object('id',g.id,'kind','comment','title','내 글 '''||g.pshort||'''에 새 댓글이 달렸습니다','body','','post_id',g.post_id,'channel_id',null,'comment_id',g.comment_id,'anchor','comment-'||g.comment_id,'count',1,'read_at',g.read_at,'created_at',g.created_at)
     when g.kind='comment' and g.is_ai then jsonb_build_object('id',g.id,'kind','comment','title','내 글 '''||g.pshort||'''에 AI 참고 답변이 달렸습니다','body','','post_id',g.post_id,'channel_id',null,'comment_id',null,'anchor','comment-ai','count',1,'read_at',g.read_at,'created_at',g.created_at)
     when g.kind='reply' and g.comment_id is not null then jsonb_build_object('id',g.id,'kind','reply','title','내 댓글에 새 답글이 달렸습니다','body',g.psnip,'post_id',g.post_id,'channel_id',null,'comment_id',g.comment_id,'anchor','comment-'||g.comment_id,'count',1,'read_at',g.read_at,'created_at',g.created_at)
     else g.j||jsonb_build_object('count',1,'anchor',case when g.kind in ('comment','reply') and g.post_id is not null then 'comments' else '' end) end j,
    case when g.cnt>=5 then g.last_at else g.created_at end t
   from (select z.*,count(*) over w cnt,max(z.created_at) over w last_at,max(z.read_at) over w group_read,row_number() over(partition by z.kind,coalesce(z.gkey,z.id::text),z.read_at is null order by z.created_at desc) rn
     from (select x.id,x.kind,x.post_id,x.channel_id,x.comment_id,x.read_at,x.created_at,to_jsonb(x)-'user_id' j,
        ch.name cname,po.title ptitle,case when char_length(po.title)>24 then left(po.title,24)||'…' else po.title end pshort,
        cm.parent_id,'내 댓글: '||case when char_length(par.body)>30 then left(regexp_replace(par.body,'\s+',' ','g'),30)||'…' else regexp_replace(par.body,'\s+',' ','g') end psnip,
        (x.kind='comment' and x.comment_id is null and x.title like '%에 AI 참고 답변이 달렸습니다') is_ai,
        case when x.kind='follow' then x.channel_id::text when x.kind='comment' then x.post_id::text when x.kind='reply' then cm.parent_id::text end gkey
       from public.bl_notifications x
       left join public.bl_posts po on po.id=x.post_id and x.kind in ('follow','comment','reply')
       left join public.bl_channels ch on ch.id=x.channel_id and x.kind='follow'
       left join public.bl_comments cm on cm.id=x.comment_id
       left join public.bl_comments par on par.id=cm.parent_id
      where x.user_id=auth.uid() and (x.kind<>'follow' or x.read_at is null) and public.bl_note_visible(x.kind,x.post_id,x.comment_id)) z
     window w as (partition by z.kind,coalesce(z.gkey,z.id::text),z.read_at is null)) g
   where g.cnt<5 or g.rn=1) q;
  d:='[]'; if public.bl_verified() or public.bl_is_admin() then select coalesce(jsonb_agg(public.bl_comment_json(x) order by x.created_at desc),'[]') into d from public.bl_comments x join public.bl_posts pp on pp.id=x.post_id where x.author_id=auth.uid() and x.status='published' and pp.status='published'; end if;
  select coalesce(jsonb_agg(public.bl_review_json(x) order by x.created_at desc),'[]') into e from public.bl_reviews x where x.author_id=auth.uid() and x.status='published';
  return jsonb_build_object('viewer',v,'profile',jsonb_build_object('nickname',prof.nickname,'company_id',prof.company_id,'company_name',prof.company_name,'status',prof.status,'review_reason',prof.review_reason,'verified_until',prof.verified_until,'name_masked',case when prof.name<>'' then left(prof.name,1)||'**' else '' end,'phone_masked',case when prof.phone<>'' then '***-****-'||right(prof.phone,4) else '' end,'has_proof',prof.proof_path is not null,'role',v->>'role'),'posts',a,'comments',d,'bookmarks',b,'notifications',c,'follows',(select coalesce(jsonb_agg(target_id),'[]') from public.bl_reactions where user_id=auth.uid() and kind='follow'),'reviews',e);
 end if;
 if p_scope='admin' then
  return jsonb_build_object('viewer',v)||public.bl_admin_read(p_args->>'section',p_args);
 end if;
 raise exception '지원하지 않는 조회입니다.';
end; $function$
;
commit;
