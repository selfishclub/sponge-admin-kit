# 50 · 보고서 양식 3종

## (a) 단계 완료 보고

기능 하나가 끝날 때마다(12-spec-security A절 13번과 같은 규칙) 이 양식으로 짧게 보고한다.

```
## 완료: <기능 이름>

한 일:
- …

확인한 것(명령·결과):
- `<실행한 명령>` → <결과 한 줄>
- …

확인 못 한 것:
- …(환경이 없어서 / 권한이 없어서 / 시간 관계상 등 이유를 같이 적는다)

보안상 확인한 것: <한 줄>
(예: "관리용 API 3곳 모두 requireAdmin 통과 확인, service_role 키는 서버 코드 밖으로 나가지 않음")

커밋: <해시> <메시지 한 줄>
```

## (b) 인수인계

작업을 다른 사람(또는 다음 세션)에게 넘길 때 쓴다. 값은 실제로 설정된 것만 적고, 비워 둔 항목은 "미설정"이라고 분명히 쓴다.

```
## 인수인계 — <프로젝트/캠페인 이름>

사이트 주소: <url>

어드민 주소와 접근 방식:
- /tools/login 에서 ADMIN_PASSCODE 로 로그인 (세션 쿠키, 12시간)
- /tools/utm, /tools/dashboard

표 목록:
| 표 이름 | 한 줄 뜻 |
|---|---|
| {{prefix}}_channels | 채널 등록부 |
| {{prefix}}_links | UTM 링크 장부 |
| {{prefix}}_clicks | 링크별 클릭 로그 |
| {{prefix}}_exports | 내보내기(CSV 등) 기록 |
| {{prefix}}_audit | 관리 행위 감사 로그 |
| … | … |

환경변수 이름 목록(어디에):
| 이름 | 위치 | 용도 |
|---|---|---|
| ADMIN_PASSCODE | Vercel Production | 어드민 로그인 |
| ADMIN_SESSION_SECRET | Vercel Production | 세션 쿠키 서명 |
| GA_PROPERTY_ID | Vercel Production | GA4 속성 ID |
| GCP_PROJECT_NUMBER / GCP_WORKLOAD_IDENTITY_POOL_ID / GCP_WORKLOAD_IDENTITY_POOL_PROVIDER_ID / GCP_SERVICE_ACCOUNT_EMAIL | Vercel Production | GA OIDC 연합 |
| … | … | … |

부여한 외부 권한:
- GA4 속성 액세스 관리 → <서비스 계정 이메일> = 뷰어
- GCP IAM → <서비스 계정> 에 "워크로드 아이덴티티 사용자" 역할, 주체 `principal://…/workloadIdentityPools/vercel/subject/…`

남은 테스트 데이터(표·건수·식별 방법):
- {{prefix}}_links: 테스트 채널 "test" 로 만든 링크 N개, `source='test'` 로 식별
- …

다음에 할 일:
- …
```

## (c) 보안 보고서

보안 점검 보고서는 따로 양식을 만들지 않는다. `references/12-spec-security.md` 의 **"C. 보고서 양식"** 절을 그대로 쓴다 — 환경 표, 한 줄 요약(지금 당장/이번 주/나중에 개수), 항목별 표(번호·항목·결과·근거·왜 위험한가·고치는 방법), 우선순위 표, "사용자가 직접 할 것 / AI가 승인받고 할 것" 구분까지 그 절의 구조를 따른다.

링크: [`references/12-spec-security.md#c-보고서-양식`](./12-spec-security.md#c-보고서-양식)
