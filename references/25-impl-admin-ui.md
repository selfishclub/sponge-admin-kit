# 25 · 참고 구현 — 어드민 화면 골격

이 문서는 전체 코드를 넣지 않는다. 화면 스타일·브랜드 className 은 프로젝트마다 다르므로, 그대로 베끼면 안 맞는다. 대신 **상태·API 호출·블록 순서**만 잡는다. 실제 마크업·스타일은 그 프로젝트의 디자인 토큰으로 새로 짠다.

## 페이지 파일 2개는 그대로 쓴다

둘 다 noindex — 내부 도구라 검색엔진에 노출하지 않는다.

```tsx
// src/app/tools/utm/page.tsx
import type { Metadata } from "next";
import { UtmTool } from "@/components/UtmTool";

export const metadata: Metadata = {
  title: "UTM 링크 생성기",
  description: "{{campaign}} 캠페인 채널별 UTM 링크를 만들고 장부에 기록합니다.",
  robots: { index: false, follow: false },
};

export const dynamic = "force-dynamic";

export default function UtmToolPage() {
  return <UtmTool />;
}
```

```tsx
// src/app/tools/dashboard/page.tsx
import type { Metadata } from "next";
import { Dashboard } from "@/components/Dashboard";

export const metadata: Metadata = {
  title: "성과 대시보드",
  description: "{{campaign}} 캠페인 채널별 클릭·신청·전환율.",
  robots: { index: false, follow: false },
};
export const dynamic = "force-dynamic";

export default function DashboardPage() {
  return <Dashboard />;
}
```

두 페이지 다 보호 대상이다. 26-impl-admin-auth 의 "보호된 페이지 첫 줄"을 `export default function` 위에 넣는다(서버 컴포넌트로 바꿔야 하면 `UtmTool`/`Dashboard` 는 클라이언트 컴포넌트로 감싸인 채 그대로 두고, 이 page.tsx 파일에서만 세션을 검사한다).

## UtmTool — 상태와 API 호출 골격

```ts
// 상태
channels: Channel[]                 // GET /api/channels 로 채움
links: UtmLink[]                     // GET /api/utm-links 로 채움
selected: Set<string>                // 체크한 채널 id (여러 개 가능 → 한 번에 N개 생성)
content: string                      // 소재 코드 (자동 제안 + 사용자가 손대면 제안 중단)
label: string                        // 메모, 비우면 서버가 "채널명 · 소재"로 채움
createdBy: string                    // localStorage 에 저장해 다음 방문에도 유지
advanced: { source, medium, campaign, term, shortCode }  // "고급" 접었을 때만 씀
filter: { channelId, query, showArchived }               // 장부 필터

// API
GET   /api/channels
GET   /api/utm-links
POST  /api/utm-links   body: { channelIds } | { manual: { source, medium, campaign }, shortCode }
PATCH /api/utm-links   body: { id, archived? , label? }
POST  /api/channels    새 채널 추가
PATCH /api/channels    body: { id, active? }  — 삭제 대신 숨김
```

`createdBy` 는 `localStorage` 키 하나에 저장하고 마운트 시 한 번 읽는다. 서버에는 매 요청 바디로만 실어 보낸다(별도 로그인 아님 — 누가 만들었는지 기록용).

복사는 `navigator.clipboard.writeText()` 를 쓰되, **저장 성공과 분리해서 보여준다.** 클립보드 API 는 권한이 없거나 HTTPS 가 아니면 조용히 거부될 수 있는데, 이걸 저장 실패로 오인하면 사용자가 같은 걸 두 번 만든다(40-lessons #9). 저장은 됐고 복사만 막혔을 때는 "복사가 막혀 있습니다, 아래에서 직접 복사해 주세요" 로 표시한다.

QR 은 `qrcode` 패키지의 `QRCode.toCanvas(canvasRef, text, { width, margin, color })` 를 쓴다. `text` 는 짧은 링크(`/l/<code>`) — 긴 UTM URL 을 넣으면 스캔 한 번에 클릭이 안 세인다.

## 화면 블록 순서 (UtmTool)

1. **채널 카드** — 왜: 칸에 source/medium 을 손으로 적게 하면 사람마다 표기가 갈린다(reel vs Reel vs reels). 등록된 채널을 카드로 고르게 하면 값이 항상 같다.
2. **소재 · 메모 · 만든 사람**
3. **고급(접기)** — source/medium/campaign 직접 입력. 기본은 숨겨서 대부분은 채널 카드만 보게 한다.
4. **미리보기 + 만들기(N개)** — 고른 채널 수만큼 링크를 한 번에 만든다.
5. **결과(복사 · 전부 복사 · QR)** — "전부 복사"는 `메모\n링크` 를 링크 사이 빈 줄로 이어 붙인다 — 왜: 슬랙·카톡에 붙였을 때 "메모 한 줄 · 링크 한 줄"로 끊겨야 누가 어떤 링크인지 바로 읽힌다.
6. **채널 관리** — 이름·코드·source/medium·소재 코드 방식(없음/순번/날짜/자유)·설명을 등록. 소재 코드 방식을 "순번"으로 두면 같은 채널의 기존 링크를 보고 다음 번호를 자동 제안한다 — 왜: 두 사람이 동시에 만들면 번호가 겹칠 수 있으니, 제안만 자동으로 하고 최종 값은 화면에서 확인시킨다.
7. **장부(필터 · 검색 · 보관 토글)** — 채널 필터, 메모/코드 검색, 보관된 링크 포함 여부. 삭제 버튼은 없다 — 보관(archived)만 있다.

## Dashboard — 상태와 API 호출 골격

```ts
period: "today" | "7d" | "30d" | "all" | "custom"
from, to: string   // period === "custom" 일 때만

GET /api/stats?period=...(&from=&to=)   // 우리 DB 집계 (클릭·신청)
GET /api/ga?period=...(&from=&to=)      // GA4 집계. 응답이 느려도 위 집계를 막지 않게 별도로 fetch
```

## 화면 블록 순서 (Dashboard)

1. **타일 4개** — 클릭 / 신청 / 전환율(클릭 대비) / 활성 링크 수.
2. **DailyChart** — 날짜별 클릭·신청 두 시리즈를 **같은 축**에 막대로 그린다(SVG 직접 그림, 차트 라이브러리 없이). 색은 두 시리즈만 쓰고 명도 차이를 확보한다 — 왜: 채널이 늘어도 이 차트는 "전체 클릭 대비 전체 신청" 하나만 보면 되므로, 색을 늘리면 오히려 읽기 어려워진다.
3. **채널별 표** — 정렬 가능(클릭순/신청순/전환율순). 클릭 비중을 막대로 같이 보여준다.
4. **소재 상위** — 전환율 기준 상위 10개 소재(링크) 한 줄씩.
5. **GA 섹션** — `connected: true` 면 세션/사용자/핵심 이벤트/세션 전환율 타일 + 소스별 표. `connected: false` 면 `reason` 그대로 보여주고 설정 순서를 안내한다(숨기지 않는다 — 24-impl-ga 의 원칙과 동일).

## ToolsNav

내부 도구 전체에 공통으로 쓰는 얇은 헤더. 현재 페이지를 `current` prop 으로 받아 강조한다.

```tsx
<nav aria-label="내부 도구">
  <Link href="/tools/utm" aria-current={current === "utm" ? "page" : undefined}>링크 만들기</Link>
  <Link href="/tools/dashboard" aria-current={current === "dashboard" ? "page" : undefined}>대시보드</Link>
  {/* 확장 시: <Link href="/tools/people">명단</Link> 등을 같은 패턴으로 추가 */}
</nav>
```

브랜드 로고·워드마크 자리는 프로젝트의 기존 헤더 컴포넌트를 그대로 재사용한다(이 문서에서 별도로 만들지 않는다).
