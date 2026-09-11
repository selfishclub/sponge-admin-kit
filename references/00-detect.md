# 00 · 환경 자동 파악

모든 모드는 이 절차로 시작한다. 값(키·비밀번호·토큰)은 절대 출력하지 않는다. 이름만 적는다.
사용자가 【 】에 적은 값이 있으면 우선하고, 없거나 "모름"이면 여기서 파악한 값을 쓴다.

## 파악 항목 15개와 보는 곳

| # | 항목 | 보는 곳 | 파악 방법 |
|---|---|---|---|
| 1 | 프레임워크·언어 | package.json dependencies, requirements.txt, go.mod | next/react/vite/astro/express/remix 중 무엇이 있나 |
| 2 | 패키지 관리자 | package-lock.json / pnpm-lock.yaml / yarn.lock / bun.lockb | 있는 lockfile 하나 |
| 3 | 호스팅·배포 | vercel.json, .vercel/, netlify.toml, wrangler.toml, Dockerfile, fly.toml, .github/workflows | 파일 존재로 판단. 여러 개면 전부 적고 물어본다 |
| 4 | 서버 라우트 가능 여부 | app/api, pages/api, src/app/api, 서버 함수 설정 | 없으면 "정적 사이트"로 표시 (단축 링크를 어디서 돌릴지 물어야 함) |
| 5 | 데이터베이스 | supabase/, @supabase/supabase-js, firebase.json, prisma/schema.prisma, drizzle, DATABASE_URL·POSTGRES_URL 변수 이름 | 없으면 "없음 → Supabase 무료 제안" |
| 6 | 랜딩 경로 | app/ 또는 pages/ 아래 page 파일 목록, 루트(/)의 redirect | 후보가 여럿이면 전부 적는다 |
| 7 | 전환 폼과 저장 표 | 폼 컴포넌트(form, onSubmit, fetch('/api/…')) → 그 API가 쓰는 표 이름 | 없으면 "전환 폼 없음" |
| 8 | 전환 표에 UTM 컬럼 | 스키마·마이그레이션에 utm_source 등, 폼이 window.location.search 를 읽는지 | 있음/없음 |
| 9 | GA 여부 | gtag( , googletagmanager.com, NEXT_PUBLIC_GA_*, GTM- 컨테이너 | 있으면 측정 ID 변수 이름과 track 함수 위치 |
| 10 | 환경변수 이름 목록 | .env.example, 코드의 process.env.* / import.meta.env.* | 이름만. 브라우저 노출 접두사(NEXT_PUBLIC_, VITE_, REACT_APP_)는 따로 표시 |
| 11 | 공개 주소 | README, vercel.json, NEXT_PUBLIC_SITE_URL, metadataBase | 없으면 "모름" |
| 12 | 개인정보 수집 여부 | 폼 필드와 표 컬럼에 name/phone/email/address/birth | 있음/없음 + 항목 |
| 13 | DB 공유 여부·접두사 | 코드가 접근하는 표 이름 전체 목록. 서로 다른 접두사가 섞여 있나 | 다른 서비스 표가 보이면 "공유 프로젝트, 접두사 규칙 필요" |
| 14 | AI 도구 설정 | .cursor/mcp.json, .claude/, .codex/, .mcp.json | DB 연결·토큰 이름 유무 (값은 안 봄) |
| 15 | 기존 어드민 | /admin, /tools, /dashboard 경로, middleware 의 인증 | 있음(인증 있음/없음)/없음 |

## 명령 예시 (저장소 루트에서)

```bash
cat package.json | head -60
ls package-lock.json pnpm-lock.yaml yarn.lock bun.lockb vercel.json netlify.toml wrangler.toml Dockerfile 2>/dev/null
find . -path ./node_modules -prune -o \( -name "page.tsx" -o -name "page.js" -o -name "route.ts" \) -print | head -40
grep -rhoE "process\.env\.[A-Z0-9_]+|import\.meta\.env\.[A-Z0-9_]+" src app pages 2>/dev/null | sort -u
grep -rlE "gtag\(|googletagmanager" src app 2>/dev/null | head
grep -rhoE "from\(['\"][a-z0-9_]+['\"]\)" src app 2>/dev/null | sort | uniq -c   # supabase 표 이름
ls .cursor/mcp.json .mcp.json .claude .codex 2>/dev/null
```

## 결과 표 양식 (그대로 출력한다)

| 항목 | 파악 결과 | 근거 |
|---|---|---|
| 프레임워크·언어 | | |
| … 15개 … | | |

표 아래에 한 줄: "위 표가 틀린 곳이 있으면 고쳐 주세요. 맞으면 진행합니다."

## 저장소로는 알 수 없어 사람에게 물을 것 (AskUserQuestion 한 번에 묶는다)

1. 링크를 걸 채널 목록과 소재 구분 방식(없음/순번/날짜/자유)
2. "전환" 정의가 7번 파악과 맞는지
3. 어드민 접근: 주소만 / 공용 비밀번호 (12번이 "있음"이면 비밀번호를 기본 추천)
4. GA 연동 여부와 사용할 구글 계정(브라우저에 로그인돼 있어야 함)
5. 단축 링크 도메인: 사이트 도메인 그대로 / 별도 짧은 도메인

각 질문에 파악 결과에서 나온 추천 답을 첫 번째 선택지로 둔다.
