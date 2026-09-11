# 21 · 참고 구현 — 단축 링크 리다이렉트

Next.js App Router 기준(`app/l/[code]/route.ts`). 다른 스택이면 "코드로 조회 → 클릭 기록 → 302"
순서만 지키면 된다.

```ts
import { NextResponse } from "next/server";
import { getSupabaseAdmin, hasSupabaseEnv } from "@/lib/supabase";
import { TABLES } from "@/lib/tables";
import { readJson, writeJson } from "@/lib/local-store";
import { LANDING_URL, normalizeValue, type UtmLink } from "@/lib/utm";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** 링크 미리보기 봇은 클릭으로 세지 않는다 */
const BOT_UA = /bot|crawl|spider|slurp|facebookexternalhit|facebookcatalog|kakaotalk-scrap|kakaostory|twitterbot|slackbot|discordbot|telegrambot|whatsapp|linkedinbot|pinterest|skypeuripreview|embedly|quora link preview|line-poker|yeti|daum|preview|curl\/|wget\//i;

export type LocalClick = { link_id: string; clicked_at: string; device: "mobile" | "desktop" | "other"; referer_host: string | null };

function deviceOf(ua: string): "mobile" | "desktop" | "other" {
  if (!ua) return "other";
  if (/mobile|iphone|ipod|android.+mobile|windows phone/i.test(ua)) return "mobile";
  if (/ipad|tablet|android/i.test(ua)) return "mobile";
  if (/macintosh|windows nt|x11|linux/i.test(ua)) return "desktop";
  return "other";
}
function hostOf(referer: string | null): string | null {
  if (!referer) return null;
  try { return new URL(referer).hostname.replace(/^www\./, "").slice(0, 200); } catch { return null; }
}

/** /l/<code> → 클릭 1 세고 UTM 링크로 302 */
export async function GET(req: Request, ctx: { params: Promise<{ code: string }> }) {
  const { code: raw } = await ctx.params;
  const code = normalizeValue(raw);
  const ua = req.headers.get("user-agent") ?? "";
  const countIt = Boolean(code) && !BOT_UA.test(ua);
  const device = deviceOf(ua);
  const referer = hostOf(req.headers.get("referer"));
  const noStore = { "Cache-Control": "no-store, max-age=0" };

  try {
    let url: string | null = null;
    if (!hasSupabaseEnv()) {
      const links = await readJson<UtmLink[]>("utm-links.json", []);
      const l = links.find((x) => x.short_code === code && !x.archived);
      if (l) {
        url = l.url;
        if (countIt) {
          l.clicks = (l.clicks ?? 0) + 1; l.last_clicked_at = new Date().toISOString();
          await writeJson("utm-links.json", links);
          const log = await readJson<LocalClick[]>("link-clicks.json", []);
          log.push({ link_id: l.id, clicked_at: l.last_clicked_at, device, referer_host: referer });
          await writeJson("link-clicks.json", log);
        }
      }
    } else if (code) {
      const db = getSupabaseAdmin();
      if (countIt) {
        const { data, error } = await db.rpc("{{prefix}}_hit_link", { p_code: code, p_device: device, p_referer: referer });
        if (error) throw error;
        url = (data as string | null) ?? null;
      } else {
        const { data } = await db.from(TABLES.links).select("url").eq("short_code", code).eq("archived", false).maybeSingle<{ url: string }>();
        url = data?.url ?? null;
      }
    }
    // 모르는 코드여도 고객은 랜딩으로 보낸다 (출처만 기록)
    return NextResponse.redirect(url ?? `${LANDING_URL}?utm_source=short-link&utm_medium=unknown&utm_campaign={{campaign}}&utm_content=${encodeURIComponent(code || "empty")}`, { status: 302, headers: noStore });
  } catch (e) {
    console.error("[short-link]", e);
    return NextResponse.redirect(LANDING_URL, { status: 302, headers: noStore });
  }
}

export async function HEAD(req: Request, ctx: { params: Promise<{ code: string }> }) {
  // 미리보기용 HEAD는 세지 않고 목적지만 알려준다
  const res = await GET(new Request(req.url, { headers: { "user-agent": "preview-head-bot" } }), ctx);
  return new Response(null, { status: res.status, headers: res.headers });
}
```

단축 코드 조회·카운팅은 아래 SQL 함수(마이그레이션 일부) 한 번으로 처리한다. 전체는
`22-impl-migrations.md` 참고.

```sql
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
```

## 이 파일이 지키는 것
- 302 + `Cache-Control: no-store`. 301 이면 브라우저가 캐시해 두 번째 클릭부터 서버에 안 온다.
- BOT_UA 정규식: facebookexternalhit, kakaotalk-scrap, Twitterbot, Slackbot, Discordbot, Yeti, bot/crawl/spider. 미리보기 생성이 클릭으로 세이면 숫자가 부푼다.
- HEAD 는 세지 않는다. 링크 검사기가 HEAD 를 보낸다.
- 카운트 +1 과 클릭 로그 insert 는 SQL 함수 한 번(SECURITY DEFINER, search_path 고정, anon EXECUTE 회수)으로. 두 쿼리로 나누면 동시 클릭에서 어긋난다.
- 모르는 코드도 랜딩으로 보내되 utm_source=short-link&utm_medium=unknown 을 붙여 흔적을 남긴다.
- 목적지는 DB 의 url 컬럼뿐. 쿼리 파라미터로 받은 URL 로는 절대 넘기지 않는다(오픈 리다이렉트).
