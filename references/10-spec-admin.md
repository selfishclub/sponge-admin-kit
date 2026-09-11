# 10 · 어드민 명세 (모드 ①)

## 만드는 것 네 가지
A. UTM 링크 빌더 (/tools/utm) — 등록된 채널 카드를 여러 개 골라 한 번에 링크 생성. 소재 코드 자동 제안(순번이면 다음 번호, 날짜면 오늘). 장부(채널·소재·메모·짧은 링크·클릭·전환·전환율·만든 날). 복사·QR. 삭제 대신 보관. 채널 추가·숨기기.
B. 자체 단축 링크 (/l/[code]) — 서버가 클릭 +1(원자적) + 클릭 로그 → UTM 긴 주소로 302. Cache-Control: no-store. 봇 UA·HEAD 제외. 모르는 코드는 랜딩으로 보내되 utm_source=short-link&utm_medium=unknown. 외부 단축 서비스 금지.
C. 대시보드 (/tools/dashboard) — 기간(오늘/7일/30일/전체/직접). 요약(클릭·전환·전환율·활성 링크). 채널별 표. 일별 추이(클릭·전환 같은 축). 소재 상위. GA 연동 시 GA 섹션(11-spec-ga). 숫자는 서버가 실제로 센 값만.
D. 전환 연결 — 랜딩이 utm_* 를 sessionStorage 에 보관하고 전환 요청 때 서버로 보내 저장. 주소의 UTM이 항상 우선. 루트 리다이렉트가 쿼리를 버리지 않게. 전환 폼이 없으면 최소 폼(이름·연락처·필수 동의·선택 동의) + 저장 표를 만든다.

## 데이터 모델 (표 이름 앞에 {{prefix}}_)
- channels: id uuid, code text unique, name, source, medium, content_mode('none'|'serial'|'date'|'free'), content_prefix, note, sort int, active bool, created_at
- links: id, channel_id → channels, landing_path, source, medium, campaign, content, term, url, short_code unique, label, created_by, clicks int, last_clicked_at, archived bool, created_at
  unique (landing_path, source, medium, campaign, coalesce(content,''), coalesce(term,''))
- clicks: id, link_id → links, clicked_at, device('mobile'|'desktop'|'other'), referer_host
- 전환 표(기존 표 또는 새 표): utm_source, utm_medium, utm_campaign, utm_content, utm_term, referrer, landing_path 컬럼 (없으면 추가만, 파괴적 변경 금지)
- 전환 집계: 전환 표의 (utm_source, utm_medium, utm_campaign, coalesce(utm_content,''), coalesce(utm_term,'')) 조합을 links와 맞춰 센다.

## API (전부 서버 라우트, 브라우저는 DB에 직접 접근하지 않는다)
GET/POST/PATCH /api/channels · GET/POST/PATCH /api/utm-links (POST: channelIds[] 일괄 또는 manual; 같은 조합이면 기존 반환) · GET /api/stats?from=&to= · GET /l/[code]
관리용 라우트(POST/PATCH 전부, stats, ga)는 어드민 인증 뒤에 둔다 (26-impl-admin-auth).

## 값 규칙
소문자, 띄어쓰기→하이픈, 영문·숫자·. _ - 만, 한글 금지, 한 번 정한 이름은 바꾸지 않는다. 빌더가 자동 정규화한다 (20-impl-utm).

## 완료 기준 (단계마다 확인하고 보고)
1. 마이그레이션 파일이 있고 실행됐다. 표 생성과 RLS·권한 회수가 같은 파일에 있다.
2. 로컬에서 링크를 만들면 장부에 남고, 같은 조합을 다시 만들면 새 행이 생기지 않는다.
3. 배포된 짧은 주소를 일반 UA로 열면 302 + 클릭 1, 봇 UA는 302만, HEAD는 세지 않는다. 모르는 코드는 랜딩으로.
4. 짧은 주소로 들어가 전환하면 전환 표 행에 utm_* 가 들어 있다.
5. 대시보드 숫자가 DB 조회와 일치한다.
6. 어드민·관리용 API가 인증 뒤에 있고 noindex 다.
7. 테스트 데이터 목록을 보고했다.

## 단계 순서
1 환경 파악·질문·확정 → 2 마이그레이션 → 3 전환 연결 → 4 API + 빌더 → 5 단축 링크 → 6 배포 후 재검증 → 7 대시보드 → 8 어드민 인증 → 9 README 한 절 + 인수인계(50-report-templates)
