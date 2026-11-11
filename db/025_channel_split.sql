-- 2026-11-11 이사님 승인(1번): 보상/심사, 고객확보/마케팅 분리 + 신입 질문·제도·규정 변경·세금·정산 추가. 원수사·GA는 그대로.
update public.bl_channels set name='보상', description='보험금 청구 절차와 서류, 지급·분쟁 실무를 이야기해요.' where slug='claims';
update public.bl_channels set name='마케팅', description='블로그·SNS·광고·개인 브랜딩 경험을 나눠요. 고객정보는 올리지 마세요.', display_order=112 where slug='marketing';
insert into public.bl_channels(slug,name,description,display_order,enabled,anonymous,guest_full) values
 ('newbie','신입 질문','처음 시작한 설계사가 부담 없이 묻고 답해요. 기초 질문 환영해요.',20,true,false,true),
 ('regulation','제도·규정 변경','약관 개정, 판매 규정, 수수료 제도, 절판 등 바뀐 내용을 나눠요.',95,true,false,true),
 ('underwriting','심사','가입 심사(인수), 고지사항, 할증·부담보 실무를 이야기해요.',102,true,false,true),
 ('prospecting','고객확보','소개·개척·상담 연결 등 고객을 만나는 방법을 나눠요. 고객정보는 올리지 마세요.',110,true,false,true),
 ('tax','세금·정산','설계사 종합소득세, 3.3% 원천징수, 경비처리 경험을 나눠요.',160,true,false,true)
on conflict (slug) do nothing;
update public.bl_posts set channel_id=(select id from public.bl_channels where slug='underwriting') where id='30347287-fe91-4db6-976f-2eb276d3cf86';
update public.bl_posts set channel_id=(select id from public.bl_channels where slug='prospecting') where id in ('841d1b91-2492-40e8-ba6b-6c43c0de78af','28fc7477-1789-49a3-bfca-4b82b89c9b5f');
select json_agg(x) from (select c.display_order o,c.slug,c.name,(select count(*) from public.bl_posts p where p.channel_id=c.id and p.status='published') n from public.bl_channels c where c.enabled order by c.display_order) x;
