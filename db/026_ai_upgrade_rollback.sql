-- 026 되돌리기. 운영자가 처리기/크론을 멈춘 뒤 실행한다. 여기서는 실행하지 않았다.
-- 026 적용 후 추가된 AI 답변·작업·연결 데이터는 private archive에 보존한다.
-- 사람 후속 댓글은 삭제하지 않고 같은 글의 최초 AI 원댓글로 재연결한다.
-- 함수 백업도 archive에 옮겨 보존한다. RLS+권한 회수로 API에서 읽을 수 없다.
begin;
set local lock_timeout='10s';
lock table public.bl_posts, public.bl_comments, public.bl_ai_jobs in share row exclusive mode;

do $$ begin
 if to_regclass('public.bl_ai_upgrade_026_backup') is null then
  raise exception '026 backup missing; rollback stopped';
 end if;
 if (select count(*) from public.bl_ai_upgrade_026_backup)<>7 then
  raise exception '026 backup incomplete; rollback stopped';
 end if;
 if exists(select 1 from public.bl_ai_upgrade_026_backup
  where pg_get_functiondef(signature::regprocedure) is distinct from upgraded_definition) then
  raise exception 'Functions changed after 026; rollback stopped';
 end if;
end $$;

create table if not exists public.bl_ai_upgrade_026_archive(kind text not null,row_data jsonb not null,archived_at timestamptz not null default now());
alter table public.bl_ai_upgrade_026_archive enable row level security;
revoke all on public.bl_ai_upgrade_026_archive from public,anon,authenticated,service_role;
insert into public.bl_ai_upgrade_026_archive(kind,row_data)
 select 'function_backup',to_jsonb(b) from public.bl_ai_upgrade_026_backup b;

-- 최초 AI 원댓글을 유지한다(보통 trigger_comment_id=null인 기존 답변).
create temporary table bl_aiup_keep on commit drop as
 select distinct on (c.post_id) c.post_id,c.id from public.bl_comments c
 where c.is_ai order by c.post_id,(c.parent_id is null) desc,c.created_at,c.id;
create temporary table bl_aiup_remove on commit drop as
 select c.id,c.post_id from public.bl_comments c join bl_aiup_keep k on k.post_id=c.post_id
 where c.is_ai and c.id<>k.id;
create temporary table bl_aiup_jobs_remove on commit drop as
 select id from public.bl_ai_jobs where trigger_comment_id is not null;

insert into public.bl_ai_upgrade_026_archive(kind,row_data)
 select 'post_acceptance',jsonb_build_object('id',id,'accepted_comment_id',accepted_comment_id)
 from public.bl_posts where accepted_comment_id is not null;
insert into public.bl_ai_upgrade_026_archive(kind,row_data)
 select 'comment',to_jsonb(c) from public.bl_comments c where c.is_ai;
insert into public.bl_ai_upgrade_026_archive(kind,row_data)
 select 'reparented_comment',to_jsonb(c) from public.bl_comments c
 where c.parent_id in (select id from bl_aiup_remove) or c.parent_id in (
  select id from public.bl_comments where parent_id is not null and not is_ai);
insert into public.bl_ai_upgrade_026_archive(kind,row_data)
 select 'ai_job',to_jsonb(j) from public.bl_ai_jobs j;
insert into public.bl_ai_upgrade_026_archive(kind,row_data)
 select 'ai_run',to_jsonb(r) from public.bl_ai_runs r where r.job_id in (select id from bl_aiup_jobs_remove);
insert into public.bl_ai_upgrade_026_archive(kind,row_data)
 select 'notification',to_jsonb(n) from public.bl_notifications n where n.comment_id in (select id from bl_aiup_remove);
insert into public.bl_ai_upgrade_026_archive(kind,row_data)
 select 'reaction',to_jsonb(r) from public.bl_reactions r where r.target='comment' and r.target_id in (select id from bl_aiup_remove);

drop trigger bl_comments_ai_followup on public.bl_comments;
drop trigger bl_comments_ai_limit on public.bl_comments;
-- 구조상 기존의 1단계 답글로 돌아가도 모든 사람 댓글을 유지한다.
update public.bl_comments c set parent_id=k.id from bl_aiup_keep k
 where c.post_id=k.post_id and not c.is_ai and c.parent_id is not null
  and exists(select 1 from public.bl_comments pa where pa.id=c.parent_id and pa.parent_id is not null);
update public.bl_comments c set parent_id=null where c.id in (select id from bl_aiup_keep);
delete from public.bl_ai_runs where job_id in (select id from bl_aiup_jobs_remove);
delete from public.bl_ai_jobs where id in (select id from bl_aiup_jobs_remove);
delete from public.bl_notifications where comment_id in (select id from bl_aiup_remove);
delete from public.bl_reactions where target='comment' and target_id in (select id from bl_aiup_remove);
-- FK를 떼기 전 혹시 남은 job 포인터도 먼저 비운다(보존본은 위에 있음).
update public.bl_ai_jobs set comment_id=null where comment_id in (select id from bl_aiup_remove);
delete from public.bl_comments where id in (select id from bl_aiup_remove);

-- 적용 직전 정의 그대로 복구: 증빙·탈퇴·관리자 권한/감사 등은 덮어 쓰지 않는다.
do $$ declare r record; begin
 for r in select definition from public.bl_ai_upgrade_026_backup order by signature
 loop execute r.definition; end loop;
end $$;

drop function public.bl_ai_admin_action(text,jsonb);
drop function public.bl_ai_worker_upgrade(text,jsonb);
drop function public.bl_ai_comment_fields(public.bl_comments);
drop function public.bl_ai_post_fields(public.bl_posts);
drop function public.bl_ai_accept(jsonb);
drop function public.bl_ai_peer_sources(uuid,text);
drop function public.bl_ai_related_posts(uuid,jsonb);
drop function public.bl_ai_followup_enqueue();
drop function public.bl_ai_comment_guard();
drop function public.bl_ai_enqueue(uuid,uuid);
drop function public.bl_ai_slots_used(uuid);
drop function public.bl_ai_redact(text,uuid,text,text);
drop function public.bl_ai_thread_visible(uuid);

alter table public.bl_posts drop column accepted_comment_id;
alter table public.bl_comments drop column related_posts;
alter table public.bl_ai_jobs drop column question_updated_at;
alter table public.bl_ai_jobs drop column comment_id;
drop index public.bl_ai_jobs_initial_post;
drop index public.bl_ai_jobs_followup;
drop index public.bl_ai_jobs_post;
alter table public.bl_ai_jobs drop column trigger_comment_id;
alter table public.bl_ai_jobs add constraint bl_ai_jobs_post_id_key unique(post_id);
drop index public.bl_comments_ai_post;
create unique index bl_comments_one_ai_per_post on public.bl_comments(post_id) where is_ai;
alter table public.bl_comments drop constraint bl_comments_author_kind;
alter table public.bl_comments add constraint bl_comments_author_kind check (
 (is_ai and author_id is null and parent_id is null and author_company='' and author_nickname='')
 or (not is_ai and author_id is not null and ai_model is null and legacy_ai_reply_id is null));
-- 재적용 때는 새 시점의 정의를 다시 백업할 수 있도록 표식만 제거한다.
drop table public.bl_ai_upgrade_026_backup;
-- 이전 처리기의 lease는 모두 무효화한다. 최초 job만 023 처리기로 다시 받을 수 있다.
update public.bl_ai_jobs set status='queued',lease_token=null,lease_until=null,error_code=null
 where status='processing';
commit;
