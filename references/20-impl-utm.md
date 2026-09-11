# 20 · 참고 구현 — UTM 값 규칙, 단축 코드·소재 제안

Next.js + TypeScript 기준. 다른 스택은 같은 함수 이름과 규칙으로 옮긴다.
클라이언트와 서버가 같은 파일을 import 해서 같은 규칙으로 정규화한다.

```ts
/** UTM 생성기 공용 로직. 클라이언트와 서버가 같은 규칙으로 정규화한다. */

export const SITE_ORIGIN = "{{site}}";
export const LANDING_URL = `${SITE_ORIGIN}/{{landing}}`;
export const DEFAULT_CAMPAIGN = "{{campaign}}";

export type ContentMode = "none" | "serial" | "date" | "free";

export type Channel = {
  id: string;
  code: string;
  name: string;
  source: string;
  medium: string;
  content_mode: ContentMode;
  content_prefix: string | null;
  note: string | null;
  sort: number;
  active: boolean;
};

export type UtmLink = {
  id: string;
  channel_id: string | null;
  source: string;
  medium: string;
  campaign: string;
  content: string | null;
  term: string | null;
  url: string;
  short_code: string | null;
  label: string | null;
  created_by: string | null;
  clicks: number;
  last_clicked_at: string | null;
  archived: boolean;
  created_at: string;
  /** 이 링크 조합으로 들어온 신청자 수 (API가 계산) */
  signups?: number;
};

/** 채널 표가 비어 있을 때 seed 로 넣는 예시 채널. 실제 채널은 사용자에게 받은 목록으로 바꾼다 (마이그레이션 seed와 동일) */
export const DEFAULT_CHANNELS: Omit<Channel, "id">[] = [
  { code: "ig-bio", name: "인스타 프로필", source: "instagram", medium: "bio", content_mode: "none", content_prefix: null, note: "프로필 상단 링크. 하나만 둔다", sort: 10, active: true },
  { code: "ig-reel", name: "인스타 릴스", source: "instagram", medium: "reel", content_mode: "serial", content_prefix: "reel", note: "릴스 댓글·스티커. 릴스마다 새 번호", sort: 20, active: true },
  { code: "ig-story", name: "인스타 스토리", source: "instagram", medium: "story", content_mode: "date", content_prefix: null, note: "스토리 링크 스티커. 올린 날짜가 코드", sort: 30, active: true },
  { code: "yt-desc", name: "유튜브 설명란", source: "youtube", medium: "video", content_mode: "serial", content_prefix: "ep", note: "영상 설명란·고정 댓글. 회차가 번호", sort: 40, active: true },
  { code: "kakao", name: "카카오 DM·채널", source: "kakao", medium: "dm", content_mode: "none", content_prefix: null, note: "카카오톡 채널 메시지·1:1 공유", sort: 50, active: true },
  { code: "meta-ads", name: "메타 유료 광고", source: "meta-ads", medium: "paid", content_mode: "free", content_prefix: null, note: "광고 소재명을 코드로. 예: skeptic-cut", sort: 60, active: true },
  { code: "naver-ads", name: "네이버 검색 광고", source: "naver", medium: "cpc", content_mode: "free", content_prefix: null, note: "키워드는 utm_term 에", sort: 70, active: true },
];

/** 소문자, 공백→하이픈, 허용 문자 외 제거 */
export function normalizeValue(v: string | undefined | null): string {
  return (v ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9._-]/g, "")
    .replace(/-{2,}/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 60);
}

export function hasHangul(v: string | undefined | null): boolean {
  return /[ㄱ-힣]/.test(v ?? "");
}

export type UtmParts = { source: string; medium: string; campaign: string; content?: string | null; term?: string | null };

export function buildUtmUrl(base: string, p: UtmParts): string {
  const q = new URLSearchParams();
  const s = normalizeValue(p.source), m = normalizeValue(p.medium), c = normalizeValue(p.campaign);
  const t = normalizeValue(p.content), k = normalizeValue(p.term);
  if (s) q.set("utm_source", s);
  if (m) q.set("utm_medium", m);
  if (c) q.set("utm_campaign", c);
  if (t) q.set("utm_content", t);
  if (k) q.set("utm_term", k);
  const clean = base.trim().replace(/[?#].*$/, "");
  const qs = q.toString();
  return qs ? `${clean}?${qs}` : clean;
}

/** 신청자 행과 링크를 잇는 키 */
export function comboKey(v: { source?: string | null; medium?: string | null; campaign?: string | null; content?: string | null; term?: string | null }): string {
  return [v.source, v.medium, v.campaign, v.content, v.term].map((x) => normalizeValue(x ?? "")).join("|");
}

export function shortUrl(code: string, origin: string = SITE_ORIGIN): string {
  return `${origin}/l/${code}`;
}

/** 읽을 수 있는 단축 코드 후보. 예: ig-reel + reel02 → ig-reel02 / ig-story + 0910 → ig-story-0910 */
export function suggestShortCode(channelCode: string, content: string | null | undefined): string {
  const ch = normalizeValue(channelCode);
  const ct = normalizeValue(content);
  if (!ct) return ch;
  // 채널 코드의 마지막 조각과 소재 접두어가 같으면 합친다 (ig-reel + reel02 → ig-reel02)
  const last = ch.split("-").pop() ?? "";
  if (last && ct.startsWith(last) && ct.length > last.length) return ch.slice(0, ch.length - last.length) + ct;
  return `${ch}-${ct}`.slice(0, 40);
}

/** 채널 방식에 맞는 다음 소재 코드 제안 */
export function suggestContent(channel: Pick<Channel, "content_mode" | "content_prefix">, existing: UtmLink[], today: Date = new Date()): string {
  switch (channel.content_mode) {
    case "none": return "";
    case "date": {
      const mm = String(today.getMonth() + 1).padStart(2, "0");
      const dd = String(today.getDate()).padStart(2, "0");
      return `${mm}${dd}`;
    }
    case "serial": {
      const prefix = normalizeValue(channel.content_prefix) || "n";
      let max = 0;
      for (const l of existing) {
        const m = l.content?.match(new RegExp(`^${prefix.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(\\d+)$`));
        if (m) max = Math.max(max, Number(m[1]));
      }
      return `${prefix}${String(max + 1).padStart(2, "0")}`;
    }
    default: return "";
  }
}

/** 랜덤 4자리 (코드 충돌 시 뒤에 붙임) */
export function randomSuffix(): string {
  const chars = "abcdefghjkmnpqrstuvwxyz23456789";
  let s = "";
  for (let i = 0; i < 4; i++) s += chars[Math.floor(Math.random() * chars.length)];
  return s;
}

export function conversionRate(clicks: number, signups: number): string {
  if (!clicks) return "—";
  return `${Math.round((signups / clicks) * 1000) / 10}%`;
}
```

## 이 파일이 지키는 것
- normalizeValue: 소문자, 공백→하이픈, 허용 문자 외 제거. GA 가 대소문자를 다른 채널로 세기 때문.
- hasHangul: 한글이 들어오면 거부. 링크가 %EC… 로 깨지고 채팅 앱에서 잘린다.
- comboKey: 같은 UTM 조합을 장부에 한 번만 두기 위한 키. content/term 이 비면 '' 로 취급.
- suggestShortCode: 채널 code + 소재로 사람이 읽을 수 있는 코드. 충돌 시 randomSuffix 4자.
- suggestContent: 순번 모드면 다음 번호, 날짜 모드면 오늘(YYMMDD). 사용자가 고치면 자동 제안을 멈춘다.
- DEFAULT_CHANNELS 는 예시 seed. 실제 채널은 사용자에게 받은 목록으로 바꾼다.
