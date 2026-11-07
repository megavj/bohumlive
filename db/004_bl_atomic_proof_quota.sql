begin;
-- Storage의 사전 RLS 검사와 실제 INSERT가 별도 단계여도 최종 쓰기에서 한도를 보장한다.
create table if not exists public.bl_proof_counters (
 owner_id uuid primary key,
 object_count integer not null default 0 check(object_count>=0)
);
alter table public.bl_proof_counters enable row level security;
revoke all on table public.bl_proof_counters from public,anon,authenticated;

create or replace function public.bl_proof_quota_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_old_owner uuid; v_new_owner uuid; v_count integer;
begin
 if TG_OP in ('DELETE','UPDATE') and OLD.bucket_id='bl-proofs' then
  v_old_owner:=split_part(OLD.name,'/',1)::uuid;
 end if;
 if TG_OP in ('INSERT','UPDATE') and NEW.bucket_id='bl-proofs' then
  if NEW.name !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$' then
   raise exception using errcode='23514',message='증빙 파일 경로 형식이 올바르지 않습니다.';
  end if;
  v_new_owner:=split_part(NEW.name,'/',1)::uuid;
 end if;
 -- 다른 버킷 또는 같은 회원 폴더 안의 이름 변경은 객체 수를 바꾸지 않는다.
 if v_old_owner is not distinct from v_new_owner then
  if TG_OP='DELETE' then return OLD; else return NEW; end if;
 end if;
 if v_new_owner is not null then
  insert into public.bl_proof_counters(owner_id,object_count) values(v_new_owner,0) on conflict(owner_id) do nothing;
  -- 조건부 UPDATE 자체가 행 잠금 및 최신 행 재검사를 수행하므로 선검사·스냅샷과 무관하다.
  update public.bl_proof_counters set object_count=object_count+1
   where owner_id=v_new_owner and object_count<5 returning object_count into v_count;
  if not found then
   raise exception using errcode='23514',message='증빙 사진은 최대 5개까지 보관할 수 있습니다. 미제출 사진은 24시간 뒤 자동 정리됩니다.';
  end if;
 end if;
 if v_old_owner is not null then
  update public.bl_proof_counters set object_count=greatest(0,object_count-1) where owner_id=v_old_owner;
 end if;
 if TG_OP='DELETE' then return OLD; else return NEW; end if;
end; $$;
revoke all on function public.bl_proof_quota_guard() from public,anon,authenticated;

-- 설치·재설치 시 집계와 트리거 사이에 쓰기가 끼지 않도록 해당 표의 쓰기만 잠근다.
lock table storage.objects in share row exclusive mode;
insert into public.bl_proof_counters(owner_id,object_count)
 select split_part(name,'/',1)::uuid,count(*)::integer from storage.objects
 where bucket_id='bl-proofs' group by split_part(name,'/',1)::uuid
on conflict(owner_id) do update set object_count=excluded.object_count;
update public.bl_proof_counters q set object_count=0 where not exists(
 select 1 from storage.objects o where o.bucket_id='bl-proofs' and split_part(o.name,'/',1)=q.owner_id::text
);
drop trigger if exists bl_proof_quota_guard on storage.objects;
create trigger bl_proof_quota_guard after insert or update of bucket_id,name or delete on storage.objects
 for each row execute function public.bl_proof_quota_guard();
commit;
