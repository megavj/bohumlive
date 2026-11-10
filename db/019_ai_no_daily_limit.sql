-- 019: AI 참고답변 하루 개수 제한 없음 (대표 지시 2026-11-10). 0~30 제약을 풀고 사실상 무제한 값으로.
alter table public.bl_settings drop constraint if exists bl_settings_ai_daily_limit_check;
alter table public.bl_settings add constraint bl_settings_ai_daily_limit_check check (ai_daily_limit >= 0);
update public.bl_settings set ai_daily_limit = 1000000;
select ai_daily_limit, ai_enabled from public.bl_settings;
