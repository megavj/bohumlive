begin;
-- API 이름은 유지하고 권한이 차단된 내부 구현을 감사 래퍼로 호출한다.
do $$ begin
 if to_regprocedure('public.bl_action_internal(text,jsonb)') is null then
  alter function public.bl_action(text,jsonb) rename to bl_action_internal;
 end if;
end $$;
revoke all on function public.bl_action_internal(text,jsonb) from public,anon,authenticated,service_role;

create or replace function public.bl_action(p_action text,p_payload jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 v_result jsonb;
 v_admin_before boolean:=exists(select 1 from public.bl_admins where user_id=auth.uid());
 v_target text;
 v_target_id text;
begin
 v_result:=public.bl_action_internal(p_action,p_payload);
 -- 관리 메뉴는 내부 구현이 이미 기록한다. 여기서는 성공한 일반 쓰기를 보완한다.
 if p_action<>'admin' and (v_admin_before or exists(select 1 from public.bl_admins where user_id=auth.uid())) then
  v_target:=case
   when p_action in ('profile_submit','profile_update','withdraw') then 'member'
   when p_action in ('post_save','post_delete') then 'post'
   when p_action in ('comment_save','comment_delete') then 'comment'
   when p_action in ('review_save','review_delete') then 'review'
   when p_action in ('toggle','report','appeal') then p_payload->>'target'
   when p_action='notification_read' then 'notification'
   else 'action' end;
  v_target_id:=case when v_target='member' then auth.uid()::text else coalesce(v_result->>'id',p_payload->>'id') end;
  if v_target_id is not null and v_target_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then v_target_id:=null; end if;
  perform public.bl_log('admin_write_'||p_action,v_target,v_target_id,
   jsonb_strip_nulls(jsonb_build_object('success',true,'kind',case when p_action='toggle' then p_payload->>'kind' end,'active',v_result->'active','status',v_result->'status')));
 end if;
 return v_result;
end; $$;
revoke all on function public.bl_action(text,jsonb) from public,anon;
grant execute on function public.bl_action(text,jsonb) to authenticated;
commit;
