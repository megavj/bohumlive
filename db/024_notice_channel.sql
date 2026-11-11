-- 2026-11-11 이사님 승인: 운영 공지를 '공지' 전용 채널로 옮긴다. 이 채널은 운영자만 글을 쓴다.
insert into public.bl_channels(id,slug,name,description,display_order,enabled,anonymous,guest_full)
values (gen_random_uuid(),'notice','공지','보험라이브 운영팀의 공지와 운영 안내입니다.',10,true,false,true)
on conflict (slug) do nothing;

create or replace function public.bl_notice_channel_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from public.bl_channels c where c.id=new.channel_id and c.slug='notice')
     and (tg_op='INSERT' or new.channel_id is distinct from old.channel_id)
     and auth.uid() is not null and not public.bl_is_admin() then
    raise exception '공지 채널에는 운영자만 글을 쓸 수 있어요.';
  end if;
  return new;
end $$;
drop trigger if exists bl_posts_notice_guard on public.bl_posts;
create trigger bl_posts_notice_guard before insert or update of channel_id on public.bl_posts for each row execute function public.bl_notice_channel_guard();

update public.bl_posts set channel_id=(select id from public.bl_channels where slug='notice')
where pinned and status='published';

select json_agg(x) from (select p.id,p.title,c.name from public.bl_posts p join public.bl_channels c on c.id=p.channel_id where p.pinned) x;
