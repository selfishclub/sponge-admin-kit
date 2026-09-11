# 23 · 참고 구현 — API 라우트

Next.js App Router(Route Handler) 기준. 다른 스택이면 같은 파일 역할 분담(테이블명 상수 →
Supabase 클라이언트 → rate limit → 리소스별 라우트 → 집계)만 옮기면 된다.

개발 편의용으로 Supabase 없이 JSON 파일로 굴리던 폴백 분기는 걷어냈다. 참고 구현 단계에서부터
실제 배포 형태로 맞춰 두는 편이 옮겨 쓰기 쉽다 — Supabase env 가 없으면 기능이 조용히 달라지는
대신 503 한 가지로만 반응한다.

---

### `src/lib/tables.ts`

이 아래 모든 라우트가 `TABLES.*` 로만 테이블을 가리킨다. 표 이름 자체를 라우트 코드에 직접 쓰지
않으니, 접두어를 바꾸거나 표를 하나 더 쪼갤 때 이 파일 한 곳만 고치면 된다.

```ts
/** 이 사이트 전용 테이블명. 접두어로 같은 프로젝트의 다른 서비스 테이블과 분리한다. */
export const TABLES = {
  signups: "{{prefix}}_signups",
  links: "{{prefix}}_utm_links",
  channels: "{{prefix}}_channels",
  clicks: "{{prefix}}_link_clicks",
} as const;
```

---

### `src/lib/supabase.ts` (발췌 — `hasSupabaseEnv` / `getSupabaseAdmin` 부분만)

```ts
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";

/**
 * 서버 전용 Supabase 클라이언트 (service_role).
 * 절대 클라이언트 컴포넌트에서 import 하지 않는다.
 */
let cached: SupabaseClient | null = null;

export function hasSupabaseEnv(): boolean {
  return Boolean(process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY);
}

export function getSupabaseAdmin(): SupabaseClient {
  if (cached) return cached;
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    throw new Error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 환경변수가 없습니다.");
  }
  cached = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return cached;
}

/** Supabase env 가 없을 때 모든 라우트가 공통으로 돌려주는 응답. JSON 폴백 대신 이것 하나로. */
export function supabaseUnavailable(): NextResponse {
  return NextResponse.json(
    { error: "Supabase 환경변수(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)가 설정되지 않았습니다.", code: "supabase_env_missing" },
    { status: 503 },
  );
}
```

---

### `src/lib/rate-limit.ts`

POST 로 남용될 수 있는 라우트(링크 생성)가 호출하는 카운터. 키는 호출부가 정한다 — IP, 세션 id
등 상황에 맞는 값을 넘기면 된다.

```ts
/**
 * 아주 단순한 인메모리 rate limit.
 * Vercel 서버리스에서는 인스턴스별로 동작하므로 "완벽한" 방어가 아니라
 * 실수·단순 봇을 막는 1차 안전장치다. 트래픽이 커지면 Upstash 등으로 교체.
 */
type Bucket = { count: number; resetAt: number };
const buckets = new Map<string, Bucket>();

export function rateLimit(
  key: string,
  { limit = 5, windowMs = 60_000 }: { limit?: number; windowMs?: number } = {},
): { ok: boolean; retryAfterSec: number } {
  const now = Date.now();
  const b = buckets.get(key);
  if (!b || b.resetAt <= now) {
    buckets.set(key, { count: 1, resetAt: now + windowMs });
    return { ok: true, retryAfterSec: 0 };
  }
  b.count += 1;
  if (b.count > limit) {
    return { ok: false, retryAfterSec: Math.ceil((b.resetAt - now) / 1000) };
  }
  return { ok: true, retryAfterSec: 0 };
}

// 메모리 누수 방지: 가끔 만료된 버킷 정리
if (typeof setInterval === "function") {
  const t = setInterval(() => {
    const now = Date.now();
    for (const [k, b] of buckets) if (b.resetAt <= now) buckets.delete(k);
  }, 5 * 60_000);
  // Node에서 프로세스 종료를 막지 않도록
  (t as { unref?: () => void }).unref?.();
}
```

---

### `src/app/api/channels/route.ts`

채널 등록부: 관리자 빌더 화면이 읽고(`GET`) 추가(`POST`)·수정(`PATCH`)하는 카드 목록이다. 빌더
화면 자체가 로그인 뒤에 있으므로 `GET` 을 포함한 모든 메서드를 인증 뒤에 둔다.

```ts
import { NextResponse } from "next/server";
import { requireAdmin } from "@/lib/admin-auth";
import { getSupabaseAdmin, hasSupabaseEnv, supabaseUnavailable } from "@/lib/supabase";
import { TABLES } from "@/lib/tables";
import { hasHangul, normalizeValue, type Channel, type ContentMode } from "@/lib/utm";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MODES: ContentMode[] = ["none", "serial", "date", "free"];

export async function listChannels(): Promise<Channel[]> {
  const { data, error } = await getSupabaseAdmin().from(TABLES.channels).select("*").order("sort").order("name");
  if (error) throw error;
  return (data ?? []) as Channel[];
}

export async function GET(req: Request) {
  const denied = requireAdmin(req);
  if (denied) return denied;
  if (!hasSupabaseEnv()) return supabaseUnavailable();
  try {
    return NextResponse.json({ channels: await listChannels() });
  } catch (e) {
    console.error("[channels] GET", e);
    return NextResponse.json({ channels: [], error: "채널 목록을 불러오지 못했습니다." }, { status: 500 });
  }
}

/** 채널 추가 */
export async function POST(req: Request) {
  const denied = requireAdmin(req);
  if (denied) return denied;
  if (!hasSupabaseEnv()) return supabaseUnavailable();

  let b: Partial<Channel>;
  try { b = (await req.json()) as Partial<Channel>; } catch { return NextResponse.json({ error: "잘못된 요청입니다." }, { status: 400 }); }

  const name = (b.name ?? "").trim().slice(0, 40);
  const source = normalizeValue(b.source), medium = normalizeValue(b.medium);
  const code = normalizeValue(b.code) || normalizeValue(`${source}-${medium}`);
  const mode: ContentMode = MODES.includes(b.content_mode as ContentMode) ? (b.content_mode as ContentMode) : "free";
  const prefix = mode === "serial" ? normalizeValue(b.content_prefix) || "n" : null;
  const errors: Record<string, string> = {};
  if (!name) errors.name = "채널 이름을 적어 주세요.";
  if (!source) errors.source = "utm_source는 필수입니다.";
  if (!medium) errors.medium = "utm_medium은 필수입니다.";
  if (hasHangul(b.source) || hasHangul(b.medium) || hasHangul(b.code) || hasHangul(b.content_prefix)) errors.source = "값에는 한글을 쓸 수 없습니다.";
  if (Object.keys(errors).length) return NextResponse.json({ error: "입력값을 확인해 주세요.", errors }, { status: 422 });

  const row = { code, name, source, medium, content_mode: mode, content_prefix: prefix, note: (b.note ?? "").trim().slice(0, 120) || null, sort: 100, active: true };
  try {
    const { data, error } = await getSupabaseAdmin().from(TABLES.channels).insert(row).select("*").single<Channel>();
    if (error) {
      if (error.code === "23505") return NextResponse.json({ error: `코드 ${code} 가 이미 있습니다.` }, { status: 409 });
      throw error;
    }
    return NextResponse.json({ channel: data });
  } catch (e) {
    console.error("[channels] POST", e);
    return NextResponse.json({ error: "채널을 저장하지 못했습니다." }, { status: 500 });
  }
}

/** 채널 숨김/표시, 이름·메모 수정 */
export async function PATCH(req: Request) {
  const denied = requireAdmin(req);
  if (denied) return denied;
  if (!hasSupabaseEnv()) return supabaseUnavailable();

  let b: Partial<Channel> & { id?: string };
  try { b = (await req.json()) as Partial<Channel>; } catch { return NextResponse.json({ error: "잘못된 요청입니다." }, { status: 400 }); }
  if (!b.id) return NextResponse.json({ error: "id가 없습니다." }, { status: 422 });
  const patch: Partial<Channel> = {};
  if (typeof b.active === "boolean") patch.active = b.active;
  if (typeof b.name === "string" && b.name.trim()) patch.name = b.name.trim().slice(0, 40);
  if (typeof b.note === "string") patch.note = b.note.trim().slice(0, 120) || null;
  try {
    const { data, error } = await getSupabaseAdmin().from(TABLES.channels).update(patch).eq("id", b.id).select("*").single<Channel>();
    if (error) throw error;
    return NextResponse.json({ channel: data });
  } catch (e) {
    console.error("[channels] PATCH", e);
    return NextResponse.json({ error: "채널을 수정하지 못했습니다." }, { status: 500 });
  }
}
```

---

### `src/app/api/utm-links/route.ts`

링크 장부: 목록 + 신청자 수 합치기(`GET`), 채널 여러 개로 한 번에 생성(`POST`), 보관·메모
수정(`PATCH`). `GET` 응답에도 `created_by`·`short_code` 같은 운영 정보가 그대로 실려 나가므로,
이 라우트 역시 `GET` 을 포함한 모든 메서드를 인증 뒤에 둔다.

```ts
import { NextResponse } from "next/server";
import { headers } from "next/headers";
import { requireAdmin } from "@/lib/admin-auth";
import { rateLimit } from "@/lib/rate-limit";
import { getSupabaseAdmin, hasSupabaseEnv, supabaseUnavailable } from "@/lib/supabase";
import { TABLES } from "@/lib/tables";
import { listChannels } from "@/app/api/channels/route";
import {
  DEFAULT_CAMPAIGN, LANDING_URL, buildUtmUrl, comboKey, hasHangul, normalizeValue,
  randomSuffix, suggestShortCode, type Channel, type UtmLink,
} from "@/lib/utm";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type SignupUtm = { utm_source: string | null; utm_medium: string | null; utm_campaign: string | null; utm_content: string | null; utm_term: string | null };

function countSignups(rows: SignupUtm[]): Map<string, number> {
  const m = new Map<string, number>();
  for (const r of rows) {
    const k = comboKey({ source: r.utm_source, medium: r.utm_medium, campaign: r.utm_campaign, content: r.utm_content, term: r.utm_term });
    m.set(k, (m.get(k) ?? 0) + 1);
  }
  return m;
}

/** 목록 + 링크별 신청자 수 + 채널 목록 */
export async function GET(req: Request) {
  const denied = requireAdmin(req);
  if (denied) return denied;
  if (!hasSupabaseEnv()) return supabaseUnavailable();
  try {
    const channels = await listChannels();
    const db = getSupabaseAdmin();
    const [{ data: links, error: e1 }, { data: signups, error: e2 }] = await Promise.all([
      db.from(TABLES.links).select("*").order("created_at", { ascending: false }).limit(500),
      db.from(TABLES.signups).select("utm_source, utm_medium, utm_campaign, utm_content, utm_term").limit(10000),
    ]);
    if (e1) throw e1;
    if (e2) throw e2;
    // 단축 코드가 없는 옛 행은 채워 넣는다
    const rows = (links ?? []) as UtmLink[];
    for (const l of rows) {
      if (l.short_code) continue;
      const ch = channels.find((c) => c.source === l.source && c.medium === l.medium);
      const code = await allocateShortCode(db, suggestShortCode(ch?.code ?? `${l.source}-${l.medium}`, l.content));
      const { error } = await db.from(TABLES.links).update({ short_code: code, channel_id: ch?.id ?? null }).eq("id", l.id);
      if (!error) { l.short_code = code; l.channel_id = ch?.id ?? null; }
    }
    const counts = countSignups((signups ?? []) as SignupUtm[]);
    return NextResponse.json({ links: rows.map((l) => ({ ...l, signups: counts.get(comboKey(l)) ?? 0 })), channels });
  } catch (e) {
    console.error("[utm-links] GET failed", e);
    return NextResponse.json({ links: [], channels: [], error: "목록을 불러오지 못했습니다." }, { status: 500 });
  }
}

type CreateBody = {
  channelIds?: string[];           // 등록된 채널로 만들기 (여러 개 가능)
  manual?: { source: string; medium: string; campaign?: string };  // 고급: 직접 입력
  content?: string; term?: string; label?: string; createdBy?: string; shortCode?: string;
};

/** 링크 생성 (채널 여러 개 일괄 가능). 같은 조합이면 기존 행을 돌려준다. */
export async function POST(req: Request) {
  const denied = requireAdmin(req);
  if (denied) return denied;
  if (!hasSupabaseEnv()) return supabaseUnavailable();

  const h = await headers();
  const ip = h.get("x-forwarded-for")?.split(",")[0]?.trim() || "unknown";
  if (!rateLimit(`utm:${ip}`, { limit: 40, windowMs: 60_000 }).ok) {
    return NextResponse.json({ error: "잠시 후 다시 시도해 주세요." }, { status: 429 });
  }
  let b: CreateBody;
  try { b = (await req.json()) as CreateBody; } catch { return NextResponse.json({ error: "잘못된 요청입니다." }, { status: 400 }); }

  if (hasHangul(b.content) || hasHangul(b.term) || hasHangul(b.shortCode) || hasHangul(b.manual?.source) || hasHangul(b.manual?.medium)) {
    return NextResponse.json({ error: "UTM 값과 코드에는 한글을 쓸 수 없습니다." }, { status: 422 });
  }

  const channels = await listChannels();
  const targets: { channel: Channel | null; source: string; medium: string; campaign: string }[] = [];
  if (b.manual) {
    const s = normalizeValue(b.manual.source), m = normalizeValue(b.manual.medium);
    if (!s || !m) return NextResponse.json({ error: "utm_source와 utm_medium은 필수입니다." }, { status: 422 });
    const ch = channels.find((c) => c.source === s && c.medium === m) ?? null;
    targets.push({ channel: ch, source: s, medium: m, campaign: normalizeValue(b.manual.campaign) || DEFAULT_CAMPAIGN });
  } else {
    for (const id of b.channelIds ?? []) {
      const ch = channels.find((c) => c.id === id);
      if (ch) targets.push({ channel: ch, source: ch.source, medium: ch.medium, campaign: DEFAULT_CAMPAIGN });
    }
  }
  if (!targets.length) return NextResponse.json({ error: "채널을 하나 이상 골라 주세요." }, { status: 422 });

  const content = normalizeValue(b.content) || null;
  const term = normalizeValue(b.term) || null;
  const userLabel = (b.label ?? "").trim().slice(0, 120) || null;
  const created_by = (b.createdBy ?? "").trim().slice(0, 40) || null;
  const customCode = targets.length === 1 ? normalizeValue(b.shortCode) : "";

  const db = getSupabaseAdmin();
  const results: { link: UtmLink; existed: boolean }[] = [];
  try {
    for (const t of targets) {
      const base = { source: t.source, medium: t.medium, campaign: t.campaign, content, term };
      const url = buildUtmUrl(LANDING_URL, base);
      const label = userLabel ?? [t.channel?.name ?? `${t.source} / ${t.medium}`, content].filter(Boolean).join(" · ");
      const wanted = customCode || suggestShortCode(t.channel?.code ?? `${t.source}-${t.medium}`, content);

      let q = db.from(TABLES.links).select("*").eq("source", base.source).eq("medium", base.medium).eq("campaign", base.campaign);
      q = content ? q.eq("content", content) : q.is("content", null);
      q = term ? q.eq("term", term) : q.is("term", null);
      const { data: found, error: selErr } = await q.maybeSingle<UtmLink>();
      if (selErr) throw selErr;
      if (found) { results.push({ link: found, existed: true }); continue; }

      const code = await allocateShortCode(db, wanted);
      const { data: inserted, error: insErr } = await db.from(TABLES.links)
        .insert({ channel_id: t.channel?.id ?? null, ...base, url, short_code: code, label, created_by })
        .select("*").single<UtmLink>();
      if (insErr) throw insErr;
      results.push({ link: inserted, existed: false });
    }
    return NextResponse.json({ results });
  } catch (e) {
    console.error("[utm-links] POST failed", e);
    return NextResponse.json({ error: "저장하지 못했습니다. 잠시 후 다시 시도해 주세요.", results }, { status: 500 });
  }
}

/** 보관/복원, 메모 수정 */
export async function PATCH(req: Request) {
  const denied = requireAdmin(req);
  if (denied) return denied;
  if (!hasSupabaseEnv()) return supabaseUnavailable();

  let b: { id?: string; archived?: boolean; label?: string };
  try { b = (await req.json()) as typeof b; } catch { return NextResponse.json({ error: "잘못된 요청입니다." }, { status: 400 }); }
  if (!b.id) return NextResponse.json({ error: "id가 없습니다." }, { status: 422 });
  const patch: Partial<UtmLink> = {};
  if (typeof b.archived === "boolean") patch.archived = b.archived;
  if (typeof b.label === "string") patch.label = b.label.trim().slice(0, 120) || null;
  try {
    const { data, error } = await getSupabaseAdmin().from(TABLES.links).update(patch).eq("id", b.id).select("*").single<UtmLink>();
    if (error) throw error;
    return NextResponse.json({ link: data });
  } catch (e) {
    console.error("[utm-links] PATCH failed", e);
    return NextResponse.json({ error: "수정하지 못했습니다." }, { status: 500 });
  }
}

/** 단축 코드가 이미 있으면 뒤에 랜덤 4자리를 붙여 비어 있는 코드를 찾는다 */
async function allocateShortCode(db: ReturnType<typeof getSupabaseAdmin>, wanted: string): Promise<string> {
  let code = wanted || `l-${randomSuffix()}`;
  for (let i = 0; i < 5; i++) {
    const { data } = await db.from(TABLES.links).select("id").eq("short_code", code).maybeSingle();
    if (!data) return code;
    code = `${wanted}-${randomSuffix()}`;
  }
  return `${wanted}-${Date.now().toString(36)}`;
}
```

---

### `src/lib/stats.ts`

API 와 화면이 같이 쓰는 집계 타입·기간 계산. DB 조회는 전혀 없다 — 순수 계산 유틸.

```ts
/** 대시보드 집계 타입 (API ↔ 화면 공용) */
export type Period = "today" | "7d" | "30d" | "all" | "custom";

export type ChannelStat = { channelId: string | null; name: string; links: number; clicks: number; conversions: number };
export type ContentStat = { linkId: string; channel: string; content: string | null; label: string | null; shortCode: string | null; clicks: number; conversions: number };
export type DayPoint = { day: string; clicks: number; conversions: number };

export type Stats = {
  from: string; to: string;
  summary: { clicks: number; conversions: number; activeLinks: number; conversionsWithoutUtm: number; mobileShare: number | null };
  channels: ChannelStat[];
  daily: DayPoint[];
  contents: ContentStat[];
};

/** 기간 → [from, to) (KST 기준 자정 경계) */
export function resolvePeriod(period: Period, from?: string | null, to?: string | null, now: Date = new Date()): { from: Date; to: Date } {
  const KST = 9 * 60 * 60 * 1000;
  const kstNow = new Date(now.getTime() + KST);
  const startOfKstDay = (d: Date) => new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()) - KST);
  const todayStart = startOfKstDay(kstNow);
  const tomorrow = new Date(todayStart.getTime() + 24 * 3600 * 1000);
  switch (period) {
    case "today": return { from: todayStart, to: tomorrow };
    case "7d": return { from: new Date(todayStart.getTime() - 6 * 24 * 3600 * 1000), to: tomorrow };
    case "30d": return { from: new Date(todayStart.getTime() - 29 * 24 * 3600 * 1000), to: tomorrow };
    case "custom": {
      const f = from ? new Date(`${from}T00:00:00+09:00`) : new Date(todayStart.getTime() - 29 * 24 * 3600 * 1000);
      const t = to ? new Date(new Date(`${to}T00:00:00+09:00`).getTime() + 24 * 3600 * 1000) : tomorrow;
      return { from: f, to: t };
    }
    default: return { from: new Date("2026-01-01T00:00:00+09:00"), to: tomorrow };
  }
}

/** ISO 시각 → KST 날짜 문자열 YYYY-MM-DD */
export function kstDay(iso: string): string {
  const d = new Date(new Date(iso).getTime() + 9 * 3600 * 1000);
  return d.toISOString().slice(0, 10);
}

export function eachDay(from: Date, to: Date): string[] {
  const out: string[] = [];
  const cur = new Date(from.getTime());
  while (cur < to) { out.push(kstDay(cur.toISOString())); cur.setTime(cur.getTime() + 24 * 3600 * 1000); }
  return out;
}
```

---

### `src/app/api/stats/route.ts`

채널·링크·클릭·신청 네 테이블을 한 번에 읽어 기간별로 묶는다. 관리자만 보는 화면이라 라우트
전체를 `requireAdmin()` 뒤에 둔다.

```ts
import { NextResponse } from "next/server";
import { requireAdmin } from "@/lib/admin-auth";
import { getSupabaseAdmin, hasSupabaseEnv, supabaseUnavailable } from "@/lib/supabase";
import { TABLES } from "@/lib/tables";
import { listChannels } from "@/app/api/channels/route";
import { comboKey, type Channel, type UtmLink } from "@/lib/utm";
import { eachDay, kstDay, resolvePeriod, type ChannelStat, type ContentStat, type DayPoint, type Period, type Stats } from "@/lib/stats";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type ClickRow = { link_id: string; clicked_at: string; device: string };
type ConvRow = { created_at: string; utm_source: string | null; utm_medium: string | null; utm_campaign: string | null; utm_content: string | null; utm_term: string | null };

export async function GET(req: Request) {
  const denied = requireAdmin(req);
  if (denied) return denied;
  if (!hasSupabaseEnv()) return supabaseUnavailable();

  const u = new URL(req.url);
  const period = (u.searchParams.get("period") ?? "30d") as Period;
  const { from, to } = resolvePeriod(period, u.searchParams.get("from"), u.searchParams.get("to"));

  try {
    const channels = await listChannels();
    const db = getSupabaseAdmin();
    const [l, c, w] = await Promise.all([
      db.from(TABLES.links).select("*").limit(1000),
      db.from(TABLES.clicks).select("link_id, clicked_at, device").gte("clicked_at", from.toISOString()).lt("clicked_at", to.toISOString()).limit(50000),
      db.from(TABLES.signups).select("created_at, utm_source, utm_medium, utm_campaign, utm_content, utm_term").gte("created_at", from.toISOString()).lt("created_at", to.toISOString()).limit(20000),
    ]);
    if (l.error) throw l.error;
    if (c.error) throw c.error;
    if (w.error) throw w.error;
    const links = (l.data ?? []) as UtmLink[];
    let clicks = (c.data ?? []) as ClickRow[];
    let convs = (w.data ?? []) as ConvRow[];

    const inRange = (iso: string) => { const t = new Date(iso).getTime(); return t >= from.getTime() && t < to.getTime(); };
    clicks = clicks.filter((c) => inRange(c.clicked_at));
    convs = convs.filter((c) => inRange(c.created_at));

    const linkById = new Map(links.map((l) => [l.id, l]));
    const linkByCombo = new Map(links.map((l) => [comboKey(l), l]));
    const channelOf = (l: UtmLink | undefined): Channel | undefined =>
      l ? channels.find((c) => c.id === l.channel_id) ?? channels.find((c) => c.source === l.source && c.medium === l.medium) : undefined;

    // 링크별 집계
    const perLink = new Map<string, { clicks: number; conversions: number }>();
    const bump = (id: string, k: "clicks" | "conversions") => { const v = perLink.get(id) ?? { clicks: 0, conversions: 0 }; v[k] += 1; perLink.set(id, v); };
    for (const c of clicks) if (linkById.has(c.link_id)) bump(c.link_id, "clicks");
    let conversionsWithoutUtm = 0;
    for (const w of convs) {
      const l = linkByCombo.get(comboKey({ source: w.utm_source, medium: w.utm_medium, campaign: w.utm_campaign, content: w.utm_content, term: w.utm_term }));
      if (l) bump(l.id, "conversions"); else conversionsWithoutUtm += 1;
    }

    // 채널별
    const chMap = new Map<string, ChannelStat>();
    for (const l of links) {
      const ch = channelOf(l);
      const key = ch?.id ?? `${l.source}/${l.medium}`;
      const row = chMap.get(key) ?? { channelId: ch?.id ?? null, name: ch?.name ?? `${l.source} / ${l.medium}`, links: 0, clicks: 0, conversions: 0 };
      const s = perLink.get(l.id);
      if (!l.archived) row.links += 1;
      row.clicks += s?.clicks ?? 0; row.conversions += s?.conversions ?? 0;
      chMap.set(key, row);
    }
    const channelStats = [...chMap.values()].sort((a, b) => b.clicks - a.clicks || b.conversions - a.conversions);

    // 일별
    const days = eachDay(from, to);
    const dayMap = new Map<string, DayPoint>(days.map((d) => [d, { day: d, clicks: 0, conversions: 0 }]));
    for (const c of clicks) { const p = dayMap.get(kstDay(c.clicked_at)); if (p) p.clicks += 1; }
    for (const w of convs) { const p = dayMap.get(kstDay(w.created_at)); if (p) p.conversions += 1; }
    const daily = period === "all" ? [...dayMap.values()].filter((p, i, arr) => p.clicks || p.conversions || i >= arr.length - 14) : [...dayMap.values()];

    // 소재 상위
    const contents: ContentStat[] = links
      .map((l) => ({ linkId: l.id, channel: channelOf(l)?.name ?? `${l.source} / ${l.medium}`, content: l.content, label: l.label, shortCode: l.short_code, clicks: perLink.get(l.id)?.clicks ?? 0, conversions: perLink.get(l.id)?.conversions ?? 0 }))
      .filter((c) => c.clicks || c.conversions)
      .sort((a, b) => (b.conversions / Math.max(b.clicks, 1)) - (a.conversions / Math.max(a.clicks, 1)) || b.conversions - a.conversions || b.clicks - a.clicks)
      .slice(0, 10);

    const mobile = clicks.filter((c) => c.device === "mobile").length;
    const stats: Stats = {
      from: from.toISOString(), to: to.toISOString(),
      summary: {
        clicks: clicks.length,
        conversions: convs.length,
        activeLinks: links.filter((l) => !l.archived).length,
        conversionsWithoutUtm,
        mobileShare: clicks.length ? Math.round((mobile / clicks.length) * 100) : null,
      },
      channels: channelStats, daily, contents,
    };
    return NextResponse.json(stats);
  } catch (e) {
    console.error("[stats] GET", e);
    return NextResponse.json({ error: "집계를 불러오지 못했습니다." }, { status: 500 });
  }
}
```

## 이 파일이 지키는 것
- 모든 입력은 길이·형식을 검사하고 허용 목록(채널 코드, content_mode 등)을 벗어나면 422 로 거절한다.
  한글 차단(`hasHangul`)도 같은 계열의 방어다.
- 같은 조합(채널/소재 UTM 묶음)으로 다시 POST 하면 새 행을 만들지 않고 **기존 행을 그대로
  반환**한다. 생성기를 두 번 눌러도 링크 장부가 중복되지 않는다.
- 링크는 삭제가 없다 — `archived` 플래그로 숨길 뿐이다. 이미 배포된 단축 링크가 가리키는 행이
  갑자기 사라지면 그 링크는 죽은 링크가 된다.
- rate limit 은 인메모리(인스턴스별) 1차 방어일 뿐이다. 완벽한 차단이 필요하면 Upstash 같은 공유
  스토어로 교체한다 — `rateLimit()` 의 시그니처만 유지하면 호출부는 그대로 둬도 된다.
- `channels`·`utm-links`·`stats` 는 모두 관리자 전용 라우트다. `channels`·`utm-links` 는 **GET 포함
  전 메서드**를, `stats` 는 유일한 메서드인 `GET` 을 `26-impl-admin-auth.md` 에서 정의하는
  `requireAdmin` 뒤에 둔다 — 목록 조회 자체가 `created_by`·`short_code`·신청자 수 같은 운영 정보를
  그대로 내보내므로, 읽기 전용이라고 예외를 두지 않는다. 호출은 각 핸들러 **첫 줄**에서 판정값을
  받아 바로 반환하는 형태로 하고, 거부 응답이 오면 그 자리에서 끝낸다(각 라우트 코드 블록 참고).
