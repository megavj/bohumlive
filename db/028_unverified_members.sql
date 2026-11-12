-- 2026-11-12 이사님 결정: 설계사 미인증 회원도 인증 회원과 똑같이 활동한다.

-- 다른 점은 이름 옆 소속 자리에 회사 이름 대신 '소속 미확인'만 보인다(회사 리뷰는 현재 소속 인증 회원만, 기존 그대로).

-- 되돌리기: 20261112_보라미인증/db-before-028/*.sql 을 그대로 실행 + drop function public.bl_member_active().



create or replace function public.bl_member_active() returns boolean language sql stable security definer set search_path to '' as $function$ select coalesce((select status not in ('suspended','withdrawn') from public.bl_profiles where id=auth.uid()),false); $function$;
revoke all on function public.bl_member_active() from public; grant execute on function public.bl_member_active() to anon, authenticated;

CREATE OR REPLACE FUNCTION public.bl_can_write()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select public.bl_is_owner() or public.bl_verified() or public.bl_member_active(); $function$
;

CREATE OR REPLACE FUNCTION public.bl_post_json(p bl_posts)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select public.bl_ai_post_fields(p)||jsonb_build_object('id',p.id,'is_sample',p.is_sample,'channel_id',p.channel_id,'channel_name',(select name from public.bl_channels where id=p.channel_id),'company_id',p.company_id,'company_name',(select name from public.bl_companies where id=p.company_id),'title',case when p.status='published' or public.bl_is_admin() or (p.author_id=auth.uid() and p.status='hidden') then p.title else '가려진 게시물' end,'body',case when p.status<>'published' and not public.bl_is_admin() and not (p.author_id=auth.uid() and p.status='hidden') then '' when p.content_kind='experience' and not(public.bl_can_write() or public.bl_is_admin()) then left(p.body,300) else p.body end,'content_kind',p.content_kind,'is_question',p.is_question,'author_display',case when p.as_team then '보험라이브 운영팀' when p.anonymous then '익명' else public.bl_author(p.author_id,p.author_company,p.author_nickname) end,'as_team',p.as_team,'anonymous',p.anonymous,'pinned_order',p.pinned_order,'created_at',p.created_at,'updated_at',p.updated_at,'status',p.status,'pinned',p.pinned,'views',p.view_count,'likes',(select count(*) from public.bl_reactions r where r.target='post' and r.target_id=p.id and r.kind='like'),'comment_count',(select count(*) from public.bl_comments c where c.post_id=p.id and c.status='published' and public.bl_test_visible(c.is_test)),'liked',exists(select 1 from public.bl_reactions r where r.user_id=auth.uid() and r.target='post' and r.target_id=p.id and r.kind='like'),'bookmarked',exists(select 1 from public.bl_reactions r where r.user_id=auth.uid() and r.target='post' and r.target_id=p.id and r.kind='bookmark'),'is_mine',coalesce(p.author_id=auth.uid(),false),'is_truncated',p.content_kind='experience' and length(p.body)>300 and not(public.bl_can_write() or public.bl_is_admin())); $function$
;

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
  -- 022: 최근 30일 우선, (좋아요*3 + 공개 댓글(AI 포함)*2 + 조회수/100 + 1) / (경과 시간+2)^1.2.
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
   update public.bl_notifications set read_at=now() where user_id=auth.uid() and post_id=p.id and read_at is null and (kind='follow' or kind in ('comment','reply') and (public.bl_can_write() or public.bl_is_admin()));
   get diagnostics n=row_count; if n>0 then v:=public.bl_viewer(); end if;
  end if;
  if coalesce(p_args->>'view','') in ('1','true') and p.status='published' and (auth.uid() is null or p.author_id is distinct from auth.uid()) and (p.is_test or not public.bl_viewer_is_test()) then
   update public.bl_posts set view_count=view_count+1 where id=p.id returning view_count into n;
   p.view_count:=n;
  end if;
  if (public.bl_can_write() or public.bl_is_admin()) and (p.status='published' or public.bl_is_admin()) then
   select coalesce(jsonb_agg(public.bl_comment_json(x) order by x.created_at),'[]') into a from public.bl_comments x where x.post_id=p.id and (x.status='published' or public.bl_is_admin()) and public.bl_test_visible(x.is_test) and (public.bl_ai_thread_visible(x.id) or public.bl_is_admin());
   -- AI도 comments의 실제 댓글 한 건이며 별도 답변 읽기는 중단한다.
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
     when g.kind='reply' and g.comment_id is not null then jsonb_build_object('id',g.id,'kind','reply','title','내 댓글에 새 답글이 달렸습니다','body',g.psnip,'post_id',g.post_id,'channel_id',null,'comment_id',g.comment_id,'anchor','comment-'||g.comment_id,'count',1,'read_at',g.read_at,'created_at',g.created_at)
     else g.j||jsonb_build_object('count',1,'anchor',case when g.kind in ('comment','reply') and g.post_id is not null then 'comments' else '' end) end j,
    case when g.cnt>=5 then g.last_at else g.created_at end t
   from (select z.*,count(*) over w cnt,max(z.created_at) over w last_at,max(z.read_at) over w group_read,row_number() over(partition by z.kind,coalesce(z.gkey,z.id::text),z.read_at is null order by z.created_at desc) rn
     from (select x.id,x.kind,x.post_id,x.channel_id,x.comment_id,x.read_at,x.created_at,to_jsonb(x)-'user_id' j,
        ch.name cname,po.title ptitle,case when char_length(po.title)>24 then left(po.title,24)||'…' else po.title end pshort,
        cm.parent_id,'내 댓글: '||case when char_length(par.body)>30 then left(regexp_replace(par.body,'\s+',' ','g'),30)||'…' else regexp_replace(par.body,'\s+',' ','g') end psnip,
        case when x.kind='follow' then x.channel_id::text when x.kind='comment' then x.post_id::text when x.kind='reply' then cm.parent_id::text end gkey
       from public.bl_notifications x
       left join public.bl_posts po on po.id=x.post_id and x.kind in ('follow','comment','reply')
       left join public.bl_channels ch on ch.id=x.channel_id and x.kind='follow'
       left join public.bl_comments cm on cm.id=x.comment_id
       left join public.bl_comments par on par.id=cm.parent_id
      where x.user_id=auth.uid() and (x.kind<>'follow' or x.read_at is null) and public.bl_note_visible(x.kind,x.post_id,x.comment_id)) z
     window w as (partition by z.kind,coalesce(z.gkey,z.id::text),z.read_at is null)) g
   where g.cnt<5 or g.rn=1) q;
  d:='[]'; if public.bl_can_write() or public.bl_is_admin() then select coalesce(jsonb_agg(public.bl_comment_json(x) order by x.created_at desc),'[]') into d from public.bl_comments x join public.bl_posts pp on pp.id=x.post_id where x.author_id=auth.uid() and x.status='published' and pp.status='published'
  and (public.bl_ai_thread_visible(x.id) or public.bl_is_admin()); end if;
  select coalesce(jsonb_agg(public.bl_review_json(x) order by x.created_at desc),'[]') into e from public.bl_reviews x where x.author_id=auth.uid() and x.status='published';
  return jsonb_build_object('viewer',v,'profile',jsonb_build_object('nickname',prof.nickname,'company_id',prof.company_id,'company_name',prof.company_name,'status',prof.status,'review_reason',prof.review_reason,'verified_until',prof.verified_until,'name_masked',case when prof.name<>'' then left(prof.name,1)||'**' else '' end,'phone_masked',case when prof.phone<>'' then '***-****-'||right(prof.phone,4) else '' end,'has_proof',prof.proof_path is not null,'role',v->>'role'),'posts',a,'comments',d,'bookmarks',b,'notifications',c,'follows',(select coalesce(jsonb_agg(target_id),'[]') from public.bl_reactions where user_id=auth.uid() and kind='follow'),'reviews',e);
 end if;
 if p_scope='admin' then
  return jsonb_build_object('viewer',v)||public.bl_admin_read(p_args->>'section',p_args);
 end if;
 raise exception '지원하지 않는 조회입니다.';
end; $function$
;

CREATE OR REPLACE FUNCTION public.bl_review_json(r bl_reviews)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select jsonb_build_object('id',r.id,'is_sample',r.is_sample,'company_id',r.company_id,'title',r.title,'body',case when public.bl_can_write() or public.bl_is_admin() then r.body else left(r.body,300) end,'scores',r.scores,'author_display',public.bl_author(r.author_id,r.author_company,r.author_nickname),'created_at',r.created_at,'updated_at',r.updated_at,'status',r.status,'is_mine',r.author_id=auth.uid(),'is_truncated',length(r.body)>300 and not(public.bl_can_write() or public.bl_is_admin())); $function$
;

CREATE OR REPLACE FUNCTION public.bl_ai_post_fields(p bl_posts)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select jsonb_build_object('ai_upgrade',true,'ai_reply_limit',5,
 'ai_reply_count',(select count(*) from public.bl_comments where post_id=p.id and is_ai),
 'ai_followup_available',p.is_question and p.status='published' and public.bl_can_write()
  and (select ai_enabled from public.bl_settings where id) and public.bl_ai_slots_used(p.id)<5,
 'accepted_comment_id',case when public.bl_can_write() or public.bl_is_admin() then
  (select c.id from public.bl_comments c where c.id=p.accepted_comment_id and c.post_id=p.id
   and not c.is_ai and public.bl_ai_thread_visible(c.id)) end);
$function$
;

CREATE OR REPLACE FUNCTION public.bl_author(p_id uuid, p_company text, p_nick text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select case when p_id is null then '보험라이브 운영팀' when exists(select 1 from public.bl_profiles where id=p_id and status='withdrawn') then '탈퇴한 회원' when exists(select 1 from public.bl_profiles where id=p_id and is_sample) then '견본 계정' when not exists(select 1 from public.bl_profiles where id=p_id and status='verified' and verified_until>now()) and not exists(select 1 from public.bl_admins where user_id=p_id and role='owner') then '소속 미확인 · '||left(coalesce(nullif(btrim(p_nick),''),'회원'),1)||'***' when coalesce(btrim(p_company),'')='' then left(coalesce(nullif(btrim(p_nick),''),'회원'),1)||'***' else p_company||' · '||left(coalesce(nullif(btrim(p_nick),''),'회원'),1)||'***' end; $function$
;

CREATE OR REPLACE FUNCTION public.bl_ai_enqueue(p_post uuid, p_question uuid DEFAULT NULL::uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
   and (pr.status not in ('suspended','withdrawn')
     or pr.status not in ('suspended','withdrawn') and exists(select 1 from public.bl_admins ad where ad.user_id=pr.id and ad.role='owner'))
 ) then return false; end if;
 insert into public.bl_ai_jobs(post_id,trigger_comment_id) values(p_post,p_question) on conflict do nothing;
 return found;
end;
$function$
;

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
    and (pr.status not in ('suspended','withdrawn') or pr.status not in ('suspended','withdrawn')
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
$function$
;
