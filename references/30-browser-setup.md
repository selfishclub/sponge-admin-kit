# 30 · 브라우저로 직접 하는 셋업 — GA, GCP, Vercel

이 스킬의 모드 ②(GA 연동)·모드 ⑤(전체) 에서, 로그인된 브라우저로 직접 처리하는 설정 단계다. 값(측정 ID, 프로젝트 번호, 팀 슬러그 등)은 실행 시점에 화면에서 읽어 쓰고, 이 문서에는 자리표시로만 남긴다.

## GA — 속성 만들고 측정 ID 설치

1. analytics.google.com → 측정 시작 → 계정 이름 → 다음
2. 속성 이름 / 시간대 / 통화 → 다음
3. 업종·규모 → 다음 → 목표(리드 생성 + 트래픽 파악) → 만들기
4. 약관: 국가를 맞게 바꾸고 동의함 (쿠키 배너는 거부 가능한 선택지를 고른다)
5. 플랫폼 "웹" → URL(도메인만) + 스트림 이름 → 만들고 계속하기
6. "직접 설치" 코드 상자에서 `G-…` 측정 ID만 복사
7. Vercel → 프로젝트 → Settings → Environment Variables → Config 타입, Key `NEXT_PUBLIC_GA_MEASUREMENT_ID`, Value `G-…`, Production 체크 → Save
8. 재배포 (빈 커밋 push 또는 Deployments → Redeploy)
9. `curl -s https://<도메인>/ | grep -o "gtag/js?id=G-[A-Z0-9]*"` 로 태그가 실제로 심겼는지 확인
10. GA → 보고서 → 실시간에서 방문과 `page_view` 를 확인 (UTM 을 붙여 열면 소스/매체까지 확인)
11. 핵심 이벤트(전환) 등록 — 데이터가 들어오기 전에도 미리 할 수 있다
    - 왼쪽 아래 톱니(관리) → 속성 설정 → 데이터 표시 → **이벤트**
    - **"이벤트 만들기"** → 이벤트 이름에 목표 이벤트(예: `signup_submit`) 입력
    - **"주요 이벤트로 표시"** 스위치 켜기
    - 이벤트 생성 방법은 **"코드로 만들기"**(사이트 코드가 이미 그 이름으로 보내고 있으므로) → "만들기"
    - "주요 이벤트" 탭에 별표가 채워진 채로 나타나면 끝. 실제 데이터는 최대 24시간 뒤 "최근 활동" 탭에 보인다

## GCP (OIDC 연합) — 비밀키 없이 GA Data API 붙이기

어드민 대시보드가 GA4 수치를 직접 읽어오게 하려면 서비스 계정이 필요하다. 비밀키 JSON 을 만들어 환경변수에 박아 넣는 대신, Vercel 의 OIDC 토큰으로 그 서비스 계정을 가장(impersonate)하는 쪽을 권장한다 — 어디에도 장기 비밀키가 남지 않는다.

1. GCP 콘솔에서 새 프로젝트 만들기 (결제 계정은 연결하지 않는다 — GA Data API·IAM 은 무료)
2. API 및 서비스 → 라이브러리에서 사용 설정
   - "Google Analytics Data API"
   - "IAM Service Account Credentials API"
3. IAM 및 관리자 → Workload Identity 연합 → 풀 만들기
   - 풀 ID: `vercel`
4. 같은 풀에 공급자 추가
   - 유형: OIDC
   - 공급자 ID: `vercel`
   - 발급자(issuer) URL: `https://oidc.vercel.com/<팀슬러그>`
   - 허용된 대상(audience): `https://vercel.com/<팀슬러그>`
   - 속성 매핑: `google.subject = assertion.sub`
5. IAM 및 관리자 → 서비스 계정 → 만들기 (역할 없이 생성해도 된다)
6. 그 서비스 계정에 "워크로드 아이덴티티 사용자" 역할을 부여하되, 주체(principal)를 구체적으로 지정한다 — 아무 Vercel 프로젝트가 아니라 이 프로젝트·이 환경만 가장할 수 있게:
   ```
   principal://iam.googleapis.com/projects/<번호>/locations/global/workloadIdentityPools/vercel/subject/owner:<팀>:project:<프로젝트>:environment:production
   ```
7. GA 관리 → 속성 액세스 관리 → 서비스 계정 이메일을 "뷰어"로 추가
8. Vercel 프로젝트 → Settings → Security → OIDC 토큰 발급을 켠다 (이게 꺼져 있으면 런타임에 `getVercelOidcToken()` 이 토큰을 못 받는다)
9. Vercel 환경변수 5개를 Production 에 추가 (24-impl-ga 참고):
   - `GCP_PROJECT_NUMBER`
   - `GCP_WORKLOAD_IDENTITY_POOL_ID` (= `vercel`)
   - `GCP_WORKLOAD_IDENTITY_POOL_PROVIDER_ID` (= `vercel`)
   - `GCP_SERVICE_ACCOUNT_EMAIL`
   - `GA_PROPERTY_ID`

순서가 중요한 지점: 3·4의 풀/공급자는 먼저 만들어 둬야 6의 주체 문자열(`workloadIdentityPools/vercel/...`)이 유효하다. 2의 API 활성화는 몇 분 정도 전파 시간이 있다 — 바로 호출하면 "has not been used" 오류가 난다(40-lessons #6).

## Vercel — 환경변수·재배포

- 환경변수는 프로젝트 → Settings → Environment Variables 에서 추가한다. 타입은 비밀키든 공개 값이든 **Config** 로 두고(Secret 타입은 한 번 쓰면 값을 다시 못 본다), 체크박스는 **Production 만** 켠다 — Preview 배포에서 운영 DB·운영 GA 속성에 실수로 쓰는 걸 막는다.
- 값을 추가·수정한 뒤에는 재배포해야 반영된다. 가장 간단한 방법은 빈 커밋을 만들어 push 하는 것:
  ```
  git commit --allow-empty -m "chore: redeploy for env var"
  git push
  ```
  또는 Vercel 대시보드 Deployments → 가장 최근 배포 옆 "…" → Redeploy.

## 브라우저 조작 요령

- **GCP 콘솔은 키보드 입력이 페이지 단축키로 새는 화면이 많다.** 입력창에 그냥 타이핑하면 엉뚱한 패널이 열리거나 포커스가 날아간다. `find` 로 입력창의 엘리먼트 참조(ref)를 먼저 잡고, `form_input` 으로 값을 넣는다. 직접 타이핑(`computer` 의 `type`)은 확인란·검색창처럼 단축키가 없는 곳에만 쓴다.
- 값을 넣은 뒤에는 **스크린샷으로 확인**한다. 특히 풀 ID·발급자 URL·주체 문자열처럼 한 글자만 틀려도 실패하는 값은 넣고 나서 바로 확대해서 본다.
- **클립보드는 사용자와 공유하는 자원이다.** 사용자가 그 사이 다른 걸 복사하면 내용이 바뀐다. 복사-붙여넣기를 쓸 때는 복사 직후 바로 붙여넣고, 붙여넣은 화면을 확인한다(40-lessons #7).
