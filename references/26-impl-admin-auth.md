# 26 · 참고 구현 — 어드민 인증, 마스킹, 내보내기 기록, 감사 로그

## 환경변수
ADMIN_PASSCODE (서버 전용. 12자 이상 권장), ADMIN_SESSION_SECRET (32자 이상 랜덤. 쿠키 서명용)
둘 다 Vercel Production 에만. 값은 사용자가 직접 넣는다.

## src/lib/admin-auth.ts
```ts
import { createHmac, timingSafeEqual } from "node:crypto";
import { NextResponse } from "next/server";

const COOKIE = "admin_session";
const TTL_SEC = 60 * 60 * 12; // 12시간

function secret(): string {
  const s = process.env.ADMIN_SESSION_SECRET;
  if (!s || s.length < 32) throw new Error("ADMIN_SESSION_SECRET 이 없거나 32자 미만");
  return s;
}
function sign(payload: string): string {
  return createHmac("sha256", secret()).update(payload).digest("base64url");
}
/** 세션 토큰 = 만료시각.서명 */
export function issueSession(): { value: string; maxAge: number } {
  const exp = String(Math.floor(Date.now() / 1000) + TTL_SEC);
  return { value: `${exp}.${sign(exp)}`, maxAge: TTL_SEC };
}
export function verifySession(token: string | undefined): boolean {
  if (!token) return false;
  const [exp, sig] = token.split(".");
  if (!exp || !sig) return false;
  if (Number(exp) < Math.floor(Date.now() / 1000)) return false;
  const a = Buffer.from(sign(exp)); const b = Buffer.from(sig);
  return a.length === b.length && timingSafeEqual(a, b);
}
/** 비밀번호 비교. 길이가 달라도 timing-safe 하게. */
export function checkPasscode(input: string): boolean {
  const want = process.env.ADMIN_PASSCODE ?? "";
  if (!want) return false;
  const a = Buffer.from(input); const b = Buffer.from(want);
  if (a.length !== b.length) { timingSafeEqual(b, b); return false; }
  return timingSafeEqual(a, b);
}
function readCookie(req: Request): string | undefined {
  const raw = req.headers.get("cookie") ?? "";
  const m = raw.match(new RegExp(`(?:^|;\\s*)${COOKIE}=([^;]+)`));
  return m?.[1];
}
/** 관리용 API 라우트 첫 줄에서 호출. 통과면 null, 아니면 401 응답. */
export function requireAdmin(req: Request): NextResponse | null {
  if (verifySession(readCookie(req))) return null;
  return NextResponse.json({ error: "unauthorized" }, { status: 401, headers: { "Cache-Control": "no-store" } });
}
export const ADMIN_COOKIE = COOKIE;
```

## src/app/api/admin/login/route.ts
```ts
import { NextResponse } from "next/server";
import { checkPasscode, issueSession, ADMIN_COOKIE } from "@/lib/admin-auth";
import { rateLimit } from "@/lib/rate-limit";
export const runtime = "nodejs";
export async function POST(req: Request) {
  const ip = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
  const rl = rateLimit(`admin-login:${ip}`, { limit: 5, windowMs: 10 * 60_000 });
  if (!rl.ok) return NextResponse.json({ error: "too_many" }, { status: 429 });
  const body = await req.json().catch(() => ({}));
  const pass = typeof body?.passcode === "string" ? body.passcode.slice(0, 200) : "";
  if (!checkPasscode(pass)) return NextResponse.json({ error: "invalid" }, { status: 401 });
  const s = issueSession();
  const res = NextResponse.json({ ok: true });
  res.cookies.set(ADMIN_COOKIE, s.value, { httpOnly: true, secure: true, sameSite: "lax", path: "/", maxAge: s.maxAge });
  return res;
}
```

## src/app/api/admin/logout/route.ts
```ts
import { NextResponse } from "next/server";
import { ADMIN_COOKIE } from "@/lib/admin-auth";
export async function POST() {
  const res = NextResponse.json({ ok: true });
  res.cookies.set(ADMIN_COOKIE, "", { httpOnly: true, secure: true, sameSite: "lax", path: "/", maxAge: 0 });
  return res;
}
```

## src/proxy.ts (페이지 보호. /tools/* 와 /api 의 관리용 경로)
```ts
import { NextResponse, type NextRequest } from "next/server";
// Edge 런타임에서는 node:crypto 를 못 쓰므로 여기서는 쿠키 존재만 보고, 실제 검증은 각 라우트의 requireAdmin 이 한다.
// 페이지는 서버 컴포넌트 첫 줄에서 verifySession 을 다시 호출한다(아래 page 예시).
export function proxy(req: NextRequest) {
  const p = req.nextUrl.pathname;
  const protectedPage = p.startsWith("/tools") && p !== "/tools/login";
  if (protectedPage && !req.cookies.get("admin_session")?.value) {
    const url = req.nextUrl.clone(); url.pathname = "/tools/login"; url.searchParams.set("next", p);
    return NextResponse.redirect(url);
  }
  return NextResponse.next();
}
export const config = { matcher: ["/tools/:path*"] };
```
Next.js 15 이하면 파일 이름 `src/middleware.ts`, 함수 이름 `middleware`. 16부터는 `proxy` 다(`middleware` 는 deprecated). 00-detect 의 프레임워크 버전으로 정한다.

## src/app/tools/login/page.tsx (서버 컴포넌트 + 작은 클라이언트 폼)
```tsx
import { LoginForm } from "@/components/LoginForm";
export const metadata = { robots: { index: false, follow: false } };
export default function LoginPage() { return <main style={{maxWidth:360,margin:"80px auto"}}><h1>관리자</h1><LoginForm /></main>; }
```
```tsx
"use client";
import { useState } from "react";
export function LoginForm() {
  const [pass, setPass] = useState(""); const [err, setErr] = useState("");
  async function submit(e: React.FormEvent) {
    e.preventDefault();
    const r = await fetch("/api/admin/login", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ passcode: pass }) });
    if (r.ok) { const next = new URLSearchParams(location.search).get("next") || "/tools/utm"; location.href = next.startsWith("/tools") ? next : "/tools/utm"; }
    else setErr(r.status === 429 ? "잠시 후 다시 시도해 주세요." : "비밀번호가 맞지 않습니다.");
  }
  return <form onSubmit={submit}><input type="password" value={pass} onChange={e=>setPass(e.target.value)} autoComplete="current-password" /><button type="submit">들어가기</button>{err && <p role="alert">{err}</p>}</form>;
}
```
`next` 파라미터는 `/tools` 로 시작할 때만 따른다(오픈 리다이렉트 방지).

## 보호된 페이지 첫 줄 (서버 컴포넌트)
```tsx
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { verifySession, ADMIN_COOKIE } from "@/lib/admin-auth";
export default async function Page() {
  const c = await cookies();
  if (!verifySession(c.get(ADMIN_COOKIE)?.value)) redirect("/tools/login?next=/tools/utm");
  // …
}
```

## 관리용 API 라우트 첫 줄
```ts
const denied = requireAdmin(req); if (denied) return denied;
```
적용 대상: POST/PATCH /api/channels, POST/PATCH /api/utm-links, GET /api/stats, GET /api/ga, 확장 기능의 모든 라우트. GET /api/channels·/api/utm-links 도 명단·작성자 정보를 내면 보호한다.

## 마스킹 (src/lib/mask.ts)
```ts
export const maskPhone = (s: string) => s.replace(/(\d{3})\d+(\d{4})$/, "$1-****-$2");
export const maskEmail = (s: string) => s.replace(/^(.).*(@.*)$/, "$1***$2");
export const maskName = (s: string) => (s.length <= 1 ? s : s[0] + "*".repeat(s.length - 1));
```
명단 화면은 마스킹 값을 기본으로 내려주고, "펼치기"는 별도 요청(`?reveal=1`)으로 원본을 받는다. 그 요청은 감사 로그에 남긴다.

## 내보내기 기록 + 감사 로그 (마이그레이션)
```sql
create table if not exists public.{{prefix}}_exports (
  id uuid primary key default gen_random_uuid(),
  exported_at timestamptz not null default now(),
  actor text not null,            -- 어드민은 공용 비밀번호라 "admin" + 브라우저가 기억한 이름
  kind text not null,             -- 'people_csv' | 'backup_csv' …
  filters jsonb,                  -- 조건
  row_count integer not null
);
create table if not exists public.{{prefix}}_audit (
  id uuid primary key default gen_random_uuid(),
  at timestamptz not null default now(),
  actor text not null,
  action text not null,           -- 'settings.update' | 'link.archive' | 'people.reveal' …
  target text,                    -- 대상 id 나 키
  before jsonb, after jsonb
);
alter table public.{{prefix}}_exports enable row level security;
alter table public.{{prefix}}_audit   enable row level security;
revoke all on public.{{prefix}}_exports from anon, authenticated;
revoke all on public.{{prefix}}_audit   from anon, authenticated;
grant select, insert on public.{{prefix}}_exports to service_role;
grant select, insert on public.{{prefix}}_audit   to service_role;   -- update/delete 없음: 로그는 고치지 않는다
```
```ts
// src/lib/audit.ts
import { getSupabaseAdmin } from "@/lib/supabase";
export async function logAudit(e: { actor: string; action: string; target?: string; before?: unknown; after?: unknown }) {
  await getSupabaseAdmin().from("{{prefix}}_audit").insert({ ...e });
}
```

## CSV 내보내기 라우트 (GET /api/people/export?…) 요점
requireAdmin → 조건 파싱(허용 목록) → 조회 → `{{prefix}}_exports` 에 기록 → `text/csv; charset=utf-8` + BOM(`﻿`) + `Content-Disposition: attachment`. 엑셀에서 한글이 깨지지 않게 BOM 을 붙인다.
