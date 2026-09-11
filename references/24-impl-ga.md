# 24 · 참고 구현 — GA

실제 운영 코드를 일반화한 것이다. 브랜드·캠페인 값은 `{{site}}` `{{campaign}}` 같은 자리표시로 바꿨다.

## src/components/Analytics.tsx

```tsx
import Script from "next/script";

/**
 * GA4. NEXT_PUBLIC_GA_MEASUREMENT_ID 가 없으면 아무것도 렌더하지 않는다.
 *
 * gtag 스텁(`window.gtag`)과 config 는 <head>에 인라인으로 먼저 심는다.
 * 그래야 하이드레이션 직후 useEffect 에서 쏘는 landing_view / form_view 같은
 * 초기 이벤트가 gtag 큐(dataLayer)에 arguments 형태로 쌓였다가, gtag.js 가
 * 뒤늦게 로드돼도 순서대로 GA에 전송된다. (afterInteractive 인라인이면
 * 초기 이벤트가 gtag 없는 상태에서 plain object 로 push 되어 유실됨.)
 */
export function Analytics() {
  const id = process.env.NEXT_PUBLIC_GA_MEASUREMENT_ID;
  if (!id) return null;
  return (
    <>
      <Script src={`https://www.googletagmanager.com/gtag/js?id=${id}`} strategy="afterInteractive" />
    </>
  );
}

/** <head> 안에 넣는 gtag 스텁 + config. 외부 gtag.js 보다 먼저 실행된다. */
export function AnalyticsHead() {
  const id = process.env.NEXT_PUBLIC_GA_MEASUREMENT_ID;
  if (!id) return null;
  const code = `window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments);}window.gtag=gtag;gtag('js',new Date());gtag('config','${id}',{send_page_view:true});`;
  return <script id="ga4-init" dangerouslySetInnerHTML={{ __html: code }} />;
}
```

## src/app/layout.tsx (head 삽입 위치)

`AnalyticsHead` 는 `<head>` 안, 다른 스타일·폰트 태그보다 뒤·닫는 태그 바로 앞에 둔다. `Analytics`(외부 스크립트 로더)는 `<body>` 맨 끝, `children` 다음에 둔다.

```tsx
      <head>
        {/* …폰트·메타… */}
        <AnalyticsHead />
      </head>
      <body>
        {children}
        <Analytics />
      </body>
```

## src/lib/analytics.ts

```ts
/** 이벤트 목록. GA4(gtag)가 있으면 보내고, 없으면 dataLayer에 쌓는다. */
export type EventName =
  | "landing_view"
  | "cta_click"
  | "form_view"
  | "form_start"
  | "signup_submit"
  | "signup_duplicate";

type Params = Record<string, string | number | boolean | null | undefined>;

declare global {
  interface Window {
    dataLayer?: unknown[];
    gtag?: (...args: unknown[]) => void;
  }
}

export function track(event: EventName, params: Params = {}) {
  if (typeof window === "undefined") return;
  const payload = { ...params, campaign: "{{campaign}}" };
  if (typeof window.gtag === "function") {
    window.gtag("event", event, payload);
  } else {
    // gtag 스텁이 아직 없으면(측정 ID 미설정 등) 같은 규약으로 큐에 넣는다.
    // arguments 형태여야 gtag.js 가 나중에 로드됐을 때 그대로 처리한다.
    window.dataLayer = window.dataLayer ?? [];
    // gtag.js 는 배열이 아니라 Arguments 객체만 명령으로 인식하므로 rest 파라미터를 쓰면 안 된다.
    // eslint-disable-next-line prefer-rest-params
    window.gtag = function () { window.dataLayer!.push(arguments); };
    window.gtag("event", event, payload);
  }
  if (process.env.NODE_ENV !== "production") {
    console.debug("[track]", event, payload);
  }
}

export type Attribution = {
  source: string | null;
  utm_source: string | null;
  utm_medium: string | null;
  utm_campaign: string | null;
  utm_content: string | null;
  utm_term: string | null;
  referrer: string | null;
  landing_path: string | null;
};

const ATTR_KEY = "{{prefix}}_attribution";

/**
 * UTM·referrer 캡처.
 * - 현재 URL에 utm_* / source 가 있으면 그 값을 쓰고 sessionStorage에 덮어쓴다.
 * - 없으면 같은 탭에서 먼저 잡아둔 값을 쓴다 (랜딩 후 내부 이동해도 유지).
 * - 둘 다 없으면 referrer / landing_path 만 기록한다.
 */
export function captureAttribution(): Attribution {
  const empty: Attribution = {
    source: null, utm_source: null, utm_medium: null, utm_campaign: null,
    utm_content: null, utm_term: null, referrer: null, landing_path: null,
  };
  if (typeof window === "undefined") return empty;

  const q = new URLSearchParams(window.location.search);
  const pick = (k: string) => q.get(k)?.trim().slice(0, 100) || null;
  const current: Attribution = {
    source: pick("source") ?? pick("src") ?? pick("ref"),
    utm_source: pick("utm_source"),
    utm_medium: pick("utm_medium"),
    utm_campaign: pick("utm_campaign"),
    utm_content: pick("utm_content"),
    utm_term: pick("utm_term"),
    referrer: document.referrer ? document.referrer.slice(0, 500) : null,
    landing_path: (window.location.pathname + window.location.search).slice(0, 300),
  };
  const hasCampaign = Boolean(
    current.source || current.utm_source || current.utm_medium ||
    current.utm_campaign || current.utm_content || current.utm_term,
  );

  let saved: Attribution | null = null;
  try {
    const raw = window.sessionStorage.getItem(ATTR_KEY);
    if (raw) saved = { ...empty, ...(JSON.parse(raw) as Partial<Attribution>) };
  } catch {}

  const result = hasCampaign || !saved ? current : saved;
  try { window.sessionStorage.setItem(ATTR_KEY, JSON.stringify(result)); } catch {}
  return result;
}
```

이벤트 이름은 예시다. 실제 캠페인의 행동 계단(도착 → 관심 → 폼 도달 → 시작 → 전환)에 맞게 바꾼다. `campaign` 파라미터는 모든 이벤트에 공통으로 붙여 GA 쪽에서 캠페인별로 필터링할 수 있게 한다.

## src/lib/ga.ts (전체)

```ts
import "server-only";
import { ExternalAccountClient, JWT } from "google-auth-library";
import { getVercelOidcToken } from "@vercel/functions/oidc";

/**
 * GA4 Data API 클라이언트 (서비스 계정).
 * 인증은 두 가지 중 하나:
 *   A. Vercel OIDC 연합 (권장 · 비밀키 없음)
 *      GCP_PROJECT_NUMBER, GCP_WORKLOAD_IDENTITY_POOL_ID, GCP_WORKLOAD_IDENTITY_POOL_PROVIDER_ID, GCP_SERVICE_ACCOUNT_EMAIL
 *      + Vercel 프로젝트 Settings → Security → OIDC Federation 켜기
 *   B. 서비스 계정 키 JSON (GA_SERVICE_ACCOUNT_JSON)
 * 공통: GA_PROPERTY_ID (GA4 속성 ID 숫자)
 * 설정이 없으면 connected=false 로 조용히 비활성.
 */

export type GaRange = { startDate: string; endDate: string }; // YYYY-MM-DD (GA 속성 시간대 기준)

export type GaSummary = {
  sessions: number;
  users: number;
  keyEvents: number;          // 핵심 전환 이벤트(KEY_EVENT) 수
  engagementRate: number;     // 0~1
};
export type GaSourceRow = { source: string; medium: string; campaign: string; sessions: number; users: number; keyEvents: number };
export type GaDaily = { day: string; sessions: number; keyEvents: number };
export type GaReport = {
  connected: true;
  propertyId: string;
  keyEventName: string;
  summary: GaSummary;
  sources: GaSourceRow[];
  daily: GaDaily[];
  fetchedAt: string;
} | { connected: false; reason: string };

const KEY_EVENT = process.env.GA_KEY_EVENT_NAME || "signup_submit";

function readCredentials(): { client_email: string; private_key: string } | null {
  const raw = process.env.GA_SERVICE_ACCOUNT_JSON?.trim();
  if (!raw) return null;
  try {
    const json = raw.startsWith("{") ? raw : Buffer.from(raw, "base64").toString("utf8");
    const parsed = JSON.parse(json) as { client_email?: string; private_key?: string };
    if (!parsed.client_email || !parsed.private_key) return null;
    return { client_email: parsed.client_email, private_key: parsed.private_key.replace(/\\n/g, "\n") };
  } catch {
    return null;
  }
}

function oidcConfig() {
  const { GCP_PROJECT_NUMBER, GCP_WORKLOAD_IDENTITY_POOL_ID, GCP_WORKLOAD_IDENTITY_POOL_PROVIDER_ID, GCP_SERVICE_ACCOUNT_EMAIL } = process.env;
  if (!GCP_PROJECT_NUMBER || !GCP_WORKLOAD_IDENTITY_POOL_ID || !GCP_WORKLOAD_IDENTITY_POOL_PROVIDER_ID || !GCP_SERVICE_ACCOUNT_EMAIL) return null;
  return { num: GCP_PROJECT_NUMBER, pool: GCP_WORKLOAD_IDENTITY_POOL_ID, provider: GCP_WORKLOAD_IDENTITY_POOL_PROVIDER_ID, sa: GCP_SERVICE_ACCOUNT_EMAIL };
}

export function gaConfigured(): boolean {
  return Boolean(process.env.GA_PROPERTY_ID && (oidcConfig() || readCredentials()));
}

const SCOPE = "https://www.googleapis.com/auth/analytics.readonly";
let tokenCache: { token: string; exp: number } | null = null;

async function accessToken(): Promise<string> {
  if (tokenCache && tokenCache.exp > Date.now() + 60_000) return tokenCache.token;

  const oidc = oidcConfig();
  if (oidc) {
    // Vercel OIDC 토큰 → GCP STS → 서비스 계정 가장(impersonation). 비밀키를 어디에도 저장하지 않는다.
    const client = ExternalAccountClient.fromJSON({
      type: "external_account",
      audience: `//iam.googleapis.com/projects/${oidc.num}/locations/global/workloadIdentityPools/${oidc.pool}/providers/${oidc.provider}`,
      subject_token_type: "urn:ietf:params:oauth:token-type:jwt",
      token_url: "https://sts.googleapis.com/v1/token",
      service_account_impersonation_url: `https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${oidc.sa}:generateAccessToken`,
      // 주의: 인자 없이 호출해야 한다. google-auth-library가 넘기는 context(audience 포함)가 옵션으로 해석되면 토큰 aud가 바뀐다.
      subject_token_supplier: { getSubjectToken: () => getVercelOidcToken() },
    });
    if (!client) throw new Error("OIDC client init failed");
    client.scopes = [SCOPE];
    const { token } = await client.getAccessToken();
    if (!token) throw new Error("OIDC token exchange failed");
    tokenCache = { token, exp: Date.now() + 50 * 60_000 };
    return token;
  }

  const cred = readCredentials();
  if (!cred) throw new Error("GA credentials missing");
  const jwt = new JWT({ email: cred.client_email, key: cred.private_key, scopes: [SCOPE] });
  const { access_token, expiry_date } = await jwt.authorize();
  if (!access_token) throw new Error("GA token failed");
  tokenCache = { token: access_token, exp: expiry_date ?? Date.now() + 50 * 60_000 };
  return access_token;
}

type RunReportBody = {
  dateRanges: GaRange[];
  dimensions?: { name: string }[];
  metrics: { name: string }[];
  dimensionFilter?: unknown;
  orderBys?: unknown[];
  limit?: number;
};
type RunReportRes = { rows?: { dimensionValues?: { value: string }[]; metricValues?: { value: string }[] }[] };

async function runReport(body: RunReportBody): Promise<RunReportRes> {
  const pid = process.env.GA_PROPERTY_ID!;
  const res = await fetch(`https://analyticsdata.googleapis.com/v1beta/properties/${pid}:runReport`, {
    method: "POST",
    headers: { Authorization: `Bearer ${await accessToken()}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    cache: "no-store",
  });
  if (!res.ok) throw new Error(`GA API ${res.status}: ${(await res.text()).slice(0, 300)}`);
  return (await res.json()) as RunReportRes;
}

const n = (v?: string) => Number(v ?? 0) || 0;

// 5분 캐시 (기간별). GA Data API 는 무료지만 호출 상한이 있다.
const cache = new Map<string, { at: number; data: GaReport }>();

export async function getGaReport(range: GaRange): Promise<GaReport> {
  if (!gaConfigured()) return { connected: false, reason: "GA_PROPERTY_ID 와 인증 설정(OIDC 연합 또는 서비스 계정 키)이 없습니다." };
  const key = `${range.startDate}|${range.endDate}`;
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < 5 * 60_000) return hit.data;

  const keyEventFilter = { filter: { fieldName: "eventName", stringFilter: { value: KEY_EVENT } } };
  try {
    const [summary, sources, daily, keyDaily, keyBySource] = await Promise.all([
      runReport({ dateRanges: [range], metrics: [{ name: "sessions" }, { name: "totalUsers" }, { name: "engagementRate" }] }),
      runReport({
        dateRanges: [range],
        dimensions: [{ name: "sessionSource" }, { name: "sessionMedium" }, { name: "sessionCampaignName" }],
        metrics: [{ name: "sessions" }, { name: "totalUsers" }],
        orderBys: [{ metric: { metricName: "sessions" }, desc: true }],
        limit: 50,
      }),
      runReport({ dateRanges: [range], dimensions: [{ name: "date" }], metrics: [{ name: "sessions" }], orderBys: [{ dimension: { dimensionName: "date" } }] }),
      runReport({ dateRanges: [range], dimensions: [{ name: "date" }], metrics: [{ name: "eventCount" }], dimensionFilter: keyEventFilter }),
      runReport({
        dateRanges: [range],
        dimensions: [{ name: "sessionSource" }, { name: "sessionMedium" }, { name: "sessionCampaignName" }],
        metrics: [{ name: "eventCount" }],
        dimensionFilter: keyEventFilter,
      }),
    ]);

    const sRow = summary.rows?.[0]?.metricValues ?? [];
    const keyMap = new Map<string, number>();
    for (const r of keyBySource.rows ?? []) {
      const d = r.dimensionValues ?? [];
      keyMap.set(`${d[0]?.value}|${d[1]?.value}|${d[2]?.value}`, n(r.metricValues?.[0]?.value));
    }
    const sourceRows: GaSourceRow[] = (sources.rows ?? []).map((r) => {
      const d = r.dimensionValues ?? [], m = r.metricValues ?? [];
      const k = `${d[0]?.value}|${d[1]?.value}|${d[2]?.value}`;
      return { source: d[0]?.value ?? "(not set)", medium: d[1]?.value ?? "(not set)", campaign: d[2]?.value ?? "(not set)", sessions: n(m[0]?.value), users: n(m[1]?.value), keyEvents: keyMap.get(k) ?? 0 };
    });
    const keyDailyMap = new Map<string, number>();
    for (const r of keyDaily.rows ?? []) keyDailyMap.set(r.dimensionValues?.[0]?.value ?? "", n(r.metricValues?.[0]?.value));
    const dailyRows: GaDaily[] = (daily.rows ?? []).map((r) => {
      const d = r.dimensionValues?.[0]?.value ?? "";
      const day = `${d.slice(0, 4)}-${d.slice(4, 6)}-${d.slice(6, 8)}`;
      return { day, sessions: n(r.metricValues?.[0]?.value), keyEvents: keyDailyMap.get(d) ?? 0 };
    });
    const totalKey = [...keyMap.values()].reduce((a, b) => a + b, 0);

    const data: GaReport = {
      connected: true,
      propertyId: process.env.GA_PROPERTY_ID!,
      keyEventName: KEY_EVENT,
      summary: { sessions: n(sRow[0]?.value), users: n(sRow[1]?.value), keyEvents: totalKey, engagementRate: Number(sRow[2]?.value ?? 0) || 0 },
      sources: sourceRows,
      daily: dailyRows,
      fetchedAt: new Date().toISOString(),
    };
    cache.set(key, { at: Date.now(), data });
    return data;
  } catch (e) {
    console.error("[ga] report failed", e);
    let reason = e instanceof Error ? e.message : "GA API 오류";
    // 진단: OIDC 토큰의 공개 클레임(iss/aud/sub)만 덧붙인다. 토큰 자체는 노출하지 않는다.
    if (oidcConfig()) {
      try {
        const t = await getVercelOidcToken();
        const payload = JSON.parse(Buffer.from(t.split(".")[1], "base64url").toString("utf8")) as Record<string, unknown>;
        reason += ` | oidc claims: iss=${String(payload.iss)} aud=${String(payload.aud)} sub=${String(payload.sub)}`;
      } catch (err) {
        reason += ` | oidc token unavailable: ${err instanceof Error ? err.message : String(err)}`;
      }
    }
    return { connected: false, reason };
  }
}
```

## src/app/api/ga/route.ts

```ts
import { NextResponse } from "next/server";
import { getGaReport } from "@/lib/ga";
import { resolvePeriod, type Period } from "@/lib/stats";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** 대시보드용 GA4 요약. 서비스 계정이 없으면 connected:false */
export async function GET(req: Request) {
  const u = new URL(req.url);
  const period = (u.searchParams.get("period") as Period) || "30d";
  const { from, to } = resolvePeriod(period, u.searchParams.get("from"), u.searchParams.get("to"));
  const kst = (d: Date) => new Date(d.getTime() + 9 * 3600 * 1000).toISOString().slice(0, 10);
  const endInclusive = kst(new Date(to.getTime() - 1));
  const report = await getGaReport({ startDate: kst(from), endDate: endInclusive });
  return NextResponse.json({ ...report, period, from: from.toISOString(), to: to.toISOString() });
}
```

이 라우트도 관리용이므로, 26-impl-admin-auth 의 `requireAdmin(req)` 를 첫 줄에 넣는다.

## 이 파일이 지키는 것

- AnalyticsHead 는 `<head>` 인라인 `<script dangerouslySetInnerHTML>`. `next/script afterInteractive` 로 넣으면 hydration 직후 useEffect 의 이벤트가 먼저 실행돼 유실된다.
- track() 은 gtag 부재 시 `Arguments` 객체를 dataLayer 에 push (배열 아님. gtag.js 는 Arguments 만 명령으로 인식).
- captureAttribution: 주소의 utm_* 가 항상 우선하고, 없을 때만 sessionStorage 보관값을 쓴다. 전환 API 호출 시 이 값을 본문에 실어 서버가 저장한다.
- ga.ts: `subject_token_supplier: { getSubjectToken: () => getVercelOidcToken() }` 처럼 **화살표 함수로 감싼다**. 직접 넘기면 STS 컨텍스트가 옵션으로 들어가 audience 가 공급자 URL 로 바뀌어 invalid_grant.
- 실패 시 reason 에 OIDC 클레임(iss/aud/sub)을 붙여 어드민에 그대로 보여 준다. 숨기지 않는다.
- 5분 캐시. GA Data API 는 무료지만 호출 상한이 있다.
