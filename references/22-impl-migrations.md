# 22 · 참고 구현 — 마이그레이션 4개

Supabase(Postgres) 기준. 파일 4개를 순서대로 적용한다. 파일명 규약:
`supabase/migrations/YYYYMMDD00000N_<이름>.sql` — 날짜는 적용한 날, N 은 그날 안에서의 순번.

---

### `supabase/migrations/YYYYMMDD000001_core_tables.sql`

전환 표 예시(전환 폼이 없을 때 새로 만드는 최소 표)와 그 표의 RLS/권한. 다른 조건부 표(캠페인 상태
같은)는 필요할 때 `13-spec-admin-extensions.md`(EXT-03) 기준으로 따로 만든다.

```sql
create extension if not exists pgcrypto;

create table if not exists public.{{prefix}}_signups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 30),
  phone text not null,                       -- 숫자만 남긴 정규화 값 (예: 01012345678)
  email text not null,                       -- 소문자 정규화
  requested_at timestamptz not null default now(),  -- 전환 요청 시각

  -- 개인정보 수집·이용 동의 (필수)
  privacy_consent boolean not null check (privacy_consent = true),
  privacy_consent_at timestamptz not null,
  privacy_consent_version text not null,

  -- 광고성 정보 수신동의 (선택 · SMS/이메일 통합 체크박스)
  marketing_consent boolean not null default false,
  marketing_consent_at timestamptz,
  marketing_consent_version text,
  sms_marketing_enabled boolean not null default false,    -- 초기엔 통합 동의값과 동일, 이후 개별 해지
  email_marketing_enabled boolean not null default false,

  -- 유입 경로
  source text,
  utm_source text,
  utm_medium text,
  utm_campaign text,
  utm_content text,
  utm_term text,
  referrer text,
  landing_path text,

  -- 운영 메모
  submit_count integer not null default 1,   -- 같은 번호로 재신청한 횟수
  last_submitted_at timestamptz not null default now(),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists {{prefix}}_signups_phone_key on public.{{prefix}}_signups (phone);
create index if not exists {{prefix}}_signups_email_idx on public.{{prefix}}_signups (lower(email));
create index if not exists {{prefix}}_signups_marketing_idx
  on public.{{prefix}}_signups (marketing_consent, sms_marketing_enabled, email_marketing_enabled);

create or replace function public.{{prefix}}_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;
drop trigger if exists {{prefix}}_signups_set_updated_at on public.{{prefix}}_signups;
create trigger {{prefix}}_signups_set_updated_at
  before update on public.{{prefix}}_signups
  for each row execute function public.{{prefix}}_set_updated_at();

-- 브라우저(anon) 직접 접근 차단. 서버 API(service_role)만 쓴다.
alter table public.{{prefix}}_signups enable row level security;
revoke all on public.{{prefix}}_signups from anon, authenticated;
grant select, insert, update on public.{{prefix}}_signups to service_role;
```

---

### `supabase/migrations/YYYYMMDD000002_utm_links.sql`

UTM 링크 장부. 생성기가 만든 링크를 한 행씩 쌓는다.

```sql
-- UTM 링크 장부 (/tools/utm 생성기가 기록)
create table if not exists public.{{prefix}}_utm_links (
  id uuid primary key default gen_random_uuid(),
  source text not null,          -- utm_source
  medium text not null,          -- utm_medium
  campaign text not null,        -- utm_campaign
  content text,                  -- utm_content (없으면 null)
  term text,                     -- utm_term
  url text not null,             -- 완성 링크
  label text,                    -- 메모: "9/10 릴스 스켑틱 컷"
  created_by text,               -- 만든 사람 (자유 입력)
  created_at timestamptz not null default now()
);
-- 같은 조합은 한 번만 (content/term 이 null 이어도 유일하게)
create unique index if not exists {{prefix}}_utm_links_key
  on public.{{prefix}}_utm_links (source, medium, campaign, coalesce(content, ''), coalesce(term, ''));

alter table public.{{prefix}}_utm_links enable row level security;
revoke all on public.{{prefix}}_utm_links from anon, authenticated;
grant select, insert, update on public.{{prefix}}_utm_links to service_role;
```

---

### `supabase/migrations/YYYYMMDD000003_channels_shortlinks.sql`

채널 등록부(생성기 카드 목록) + 링크 장부에 단축 코드·클릭·보관 컬럼 추가 + 클릭 집계 함수.
seed 값은 예시이므로 실제 채널은 사용자에게 받은 목록으로 바꾼다.

```sql
-- 채널 등록부 + 단축 링크 + 클릭 집계

-- 1) 채널 등록부: 생성기에서 카드로 고르는 목록
create table if not exists public.{{prefix}}_channels (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,                  -- 짧은 링크 코드의 앞부분. 예: ig-reel
  name text not null,                         -- 카드 이름. 예: 인스타 릴스
  source text not null,                       -- utm_source
  medium text not null,                       -- utm_medium
  content_mode text not null default 'free'
    check (content_mode in ('none','serial','date','free')),  -- 소재 코드 제안 방식
  content_prefix text,                        -- serial 일 때 접두어. 예: reel → reel01, reel02
  note text,                                  -- 어디에 거는 링크인지 설명
  sort integer not null default 100,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.{{prefix}}_channels enable row level security;
revoke all on public.{{prefix}}_channels from anon, authenticated;
grant select, insert, update on public.{{prefix}}_channels to service_role;

insert into public.{{prefix}}_channels (code, name, source, medium, content_mode, content_prefix, note, sort) values
  ('ig-bio',   '인스타 프로필',     'instagram', 'bio',   'none',   null,   '프로필 상단 링크. 하나만 둔다',            10),
  ('ig-reel',  '인스타 릴스',       'instagram', 'reel',  'serial', 'reel', '릴스 댓글·스티커. 릴스마다 새 번호',         20),
  ('ig-story', '인스타 스토리',     'instagram', 'story', 'date',   null,   '스토리 링크 스티커. 올린 날짜가 코드',       30),
  ('yt-desc',  '유튜브 설명란',     'youtube',   'video', 'serial', 'ep',   '영상 설명란·고정 댓글. 회차가 번호',         40),
  ('kakao',    '카카오 DM·채널',    'kakao',     'dm',    'none',   null,   '카카오톡 채널 메시지·1:1 공유',              50),
  ('meta-ads', '메타 유료 광고',    'meta-ads',  'paid',  'free',   null,   '광고 소재명을 코드로. 예: skeptic-cut',       60),
  ('naver-ads','네이버 검색 광고',  'naver',     'cpc',   'free',   null,   '키워드는 utm_term 에',                       70)
on conflict (code) do nothing;

-- 2) 링크 장부에 단축 코드·클릭·보관 컬럼
alter table public.{{prefix}}_utm_links
  add column if not exists short_code text,
  add column if not exists channel_id uuid references public.{{prefix}}_channels(id),
  add column if not exists clicks integer not null default 0,
  add column if not exists last_clicked_at timestamptz,
  add column if not exists archived boolean not null default false;
create unique index if not exists {{prefix}}_utm_links_short_code_key
  on public.{{prefix}}_utm_links (short_code) where short_code is not null;

-- 3) 클릭 1 증가 + 목적지 반환 (원자적). 서버 API만 호출한다.
create or replace function public.{{prefix}}_hit_link(p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare v_url text;
begin
  update public.{{prefix}}_utm_links
     set clicks = clicks + 1, last_clicked_at = now()
   where short_code = p_code and archived = false
   returning url into v_url;
  return v_url;
end $$;
revoke all on function public.{{prefix}}_hit_link(text) from public, anon, authenticated;
grant execute on function public.{{prefix}}_hit_link(text) to service_role;
```

---

### `supabase/migrations/YYYYMMDD000004_link_clicks.sql`

클릭 로그 표(대시보드 집계용) + `hit_link` 함수를 디바이스·리퍼러까지 기록하는 3-인자 버전으로
교체. 이전 버전(1-인자)은 마지막에 drop 한다 — 함수는 인자 개수까지 포함해 시그니처로 구분되므로
같은 이름이라도 옛 시그니처가 남아 있으면 정리해야 한다.

```sql
-- click log for the dashboard (one row per counted click)
create table if not exists public.{{prefix}}_link_clicks (
  id bigint generated always as identity primary key,
  link_id uuid not null references public.{{prefix}}_utm_links(id) on delete cascade,
  clicked_at timestamptz not null default now(),
  device text not null default 'other' check (device in ('mobile','desktop','other')),
  referer_host text
);
create index if not exists {{prefix}}_link_clicks_time_idx on public.{{prefix}}_link_clicks (clicked_at desc);
create index if not exists {{prefix}}_link_clicks_link_idx on public.{{prefix}}_link_clicks (link_id, clicked_at desc);
alter table public.{{prefix}}_link_clicks enable row level security;
revoke all on public.{{prefix}}_link_clicks from anon, authenticated;
grant select, insert on public.{{prefix}}_link_clicks to service_role;

-- hit function: bump counter and append a log row atomically
create or replace function public.{{prefix}}_hit_link(p_code text, p_device text default 'other', p_referer text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_url text; v_id uuid;
begin
  update public.{{prefix}}_utm_links
     set clicks = clicks + 1, last_clicked_at = now()
   where short_code = p_code and archived = false
   returning url, id into v_url, v_id;
  if v_id is not null then
    insert into public.{{prefix}}_link_clicks (link_id, device, referer_host)
    values (v_id, case when p_device in ('mobile','desktop') then p_device else 'other' end, left(p_referer, 200));
  end if;
  return v_url;
end $$;
revoke all on function public.{{prefix}}_hit_link(text, text, text) from public, anon, authenticated;
grant execute on function public.{{prefix}}_hit_link(text, text, text) to service_role;
-- drop the old single-argument version
drop function if exists public.{{prefix}}_hit_link(text);
```

## 실행 방법

두 가지 중 하나를 쓴다.

1. **스크립트(`scripts/db-migrate.mjs` 방식)** — `SUPABASE_DB_URL` 환경변수(Postgres 접속 문자열)를
   읽어 `pg` 클라이언트로 `supabase/migrations/*.sql` 을 파일명 순서대로 실행하고, 실행한 파일명을
   별도 표(또는 `schema_migrations`)에 기록해 재실행 시 건너뛴다. CI/배포 파이프라인에 넣기 좋다.
2. **Supabase SQL Editor** — 대시보드에서 직접 붙여넣어 실행한다. 에디터가 Monaco 기반이라 일반
   붙여넣기가 씹히는 경우, 붙여넣기 스크립트에서 `setValue()` 로 본문을 직접 꽂는 방식을 쓴다
   (`40-lessons.md` #7 참고). 파일 하나씩, 위 순서대로 실행한다.

## 이 파일이 지키는 것
- 표 생성·RLS 켜기·anon/authenticated revoke·service_role grant가 **같은 파일**에 있다. 표를 만들고
  권한을 나중에 다른 파일에서 잠그면, 그 사이에 배포되는 순간이 생긴다.
- 정책(policy)을 만들지 않는다 → anon 은 select/insert/update 를 전부 못 한다. 브라우저는 이 표에
  직접 닿지 않고, 서버(API route)가 service_role 로만 접근한다.
- `SECURITY DEFINER` 함수는 `set search_path = public` 을 반드시 같이 쓴다(검색 경로 조작으로 다른
  스키마 객체를 부르게 되는 공격을 막는다) — 그리고 `public, anon, authenticated` 에서 EXECUTE 를
  회수한 뒤 `service_role` 에게만 준다.
- `updated_at` 은 표마다 독립된 트리거로 건다(`drop trigger if exists` → `create trigger`). 함수 자체는
  공용으로 재사용해도 되지만, 트리거는 표 단위로 연결해야 나중에 표를 하나만 떼어낼 수 있다.
