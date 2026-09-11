# 11 · GA 명세 (모드 ②)

## 설치
- 측정 ID는 환경변수 NEXT_PUBLIC_GA_MEASUREMENT_ID (공개 값. AI가 넣어도 된다).
- gtag 초기화(dataLayer, gtag 함수, config)는 반드시 <head> 인라인으로 먼저. 외부 gtag.js 만 지연 로드.
  이유: 페이지가 뜨자마자 쏘는 이벤트가 초기화보다 먼저 실행되면 plain object 로 dataLayer 에 들어가 GA에 도착하지 않는다 (40-lessons #1).
- 이벤트는 track(이름, 파라미터) 하나를 거친다 (24-impl-ga). 모든 이벤트에 campaign 파라미터 자동. 개인정보·토큰 금지.

## 이벤트 설계 (예시. 사용자 전환에 맞게 이름을 제안하고 확인받는다)
계단: landing_view(도착) → cta_click(관심, from 파라미터) → form_view(폼 노출, 1회) → form_start(첫 입력, 1회) → {{conversion}}_submit(전환, 서버 저장 성공 뒤에만) → {{conversion}}_duplicate
규칙: 이름은 대상_동사 소문자, 상황은 파라미터로, "1회/매번" 구분을 주석에.

## GA 쪽 세팅 (AI가 브라우저로 직접, 30-browser-setup)
1 계정·속성(시간대 대한민국, 통화 KRW) 2 웹 스트림 → 측정 ID 3 환경변수 넣고 재배포 4 실시간에서 page_view 확인
5 관리 → 이벤트 → "이벤트 만들기"로 전환 이벤트 이름 등록 + 주요 이벤트 표시 (데이터 전에도 가능)
6 데이터 보관 14개월, 내부 트래픽 정의(사무실 IP)

## 어드민 연동 (GA Data API)
방법 1 (권장, 키 없음): Vercel OIDC → GCP Workload Identity 연합 → 서비스 계정(GA 속성 "뷰어") 가장.
  환경변수: GA_PROPERTY_ID, GCP_PROJECT_NUMBER, GCP_WORKLOAD_IDENTITY_POOL_ID, GCP_WORKLOAD_IDENTITY_POOL_PROVIDER_ID, GCP_SERVICE_ACCOUNT_EMAIL
  GCP: 프로젝트 생성(결제 계정 연결 금지) → Analytics Data API, IAM Service Account Credentials API 활성화 → WIF 풀·공급자(발급자 https://oidc.vercel.com/<팀슬러그>, 허용 대상 https://vercel.com/<팀슬러그>, 매핑 google.subject=assertion.sub) → 서비스 계정 → 주체 owner:<팀>:project:<프로젝트>:environment:production 에 워크로드 아이덴티티 사용자 권한 → GA 속성에 서비스 계정 이메일을 뷰어로 추가
  Vercel 프로젝트 설정에서 OIDC 토큰 발급이 켜져 있어야 한다.
방법 2 (대안): GA_SERVICE_ACCOUNT_JSON. 키 파일은 AI가 다운로드·붙여넣기 하지 않는다. 사용자가 Vercel 화면에 직접. 절차만 안내.
어드민 표시: 세션·사용자·주요 이벤트·참여율, 소스/매체/캠페인별, 일별. 5분 캐시. 연결 실패 사유를 화면에 그대로.

## 확인 방법
1 실시간 보고서 → "이벤트 이름별 이벤트 수"에 1분 안에 뜬다 2 F12 → Network → collect 필터 → google-analytics.com/g/collect?…&en=이벤트이름 (204) 3 콘솔에서 dataLayer 항목 확인 4 일반 보고서는 24~48시간 뒤

## 완료 기준
배포된 사이트에서 도착·CTA·폼·전환 이벤트가 실시간 보고서에 보인다(스크린샷). 주요 이벤트가 등록돼 있다. 어드민 GA 섹션이 connected:true 다. 결제 계정이 연결돼 있지 않다.
