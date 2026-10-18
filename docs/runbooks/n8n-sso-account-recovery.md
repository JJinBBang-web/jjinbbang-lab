# n8n SSO 계정 연결 및 로그아웃

## 계약

- Authentik forward-auth의 이메일이 기존 활성 n8n 사용자 이메일과 일치해야 한다.
- 이메일 없는 공용 계정이나 연결되지 않은 계정을 자동 생성하거나 owner로 연결하지 않는다.
- 이메일이 없거나 계정을 찾을 수 없는 브라우저 접근은 n8n 비밀번호 폼 대신
  연결 안내와 SSO 로그아웃 버튼을 표시한다. API 요청은 계속 401로 거부한다.
- 정상 계정의 자동 로그인은 유지한다. `/signin`에서는 SSO로 계속하거나
  통합 세션을 로그아웃할 수 있다. n8n 자체 Sign out 후에도 이 화면을 사용할 수 있다.
- 로그아웃은 동일 origin의 `POST /sso/logout`만 허용하고 n8n 쿠키를 삭제한 뒤
  Authentik `/flows/-/default/invalidation/`으로 이동한다. 임의 redirect 입력을 받지 않는다.
- Authentik 전역 로그아웃은 다른 연결 서비스의 세션도 종료할 수 있으므로 버튼 아래에 안내한다.
- 화면과 로그아웃 응답은 no-store이며 사용자 이름은 HTML escape한다.

## 검증

`node --test scripts/test-n8n-forward-auth.cjs`

누락 이메일/미등록/비활성 계정, 기존 쿠키가 남은 API 접근, 정상 계정,
로그인 페이지, 교차 origin 및 GET 로그아웃 차단, HTML escaping, health 경로를 검사한다.

배포 후에는 브라우저에서 연결 안 된 계정 안내 → SSO 로그아웃 → Authentik 로그인
→ 정상 개인 계정 → n8n을 확인한다. MFA/로그인 입력은 사용자에게 맡긴다.
동시에 예약 워크플로우가 다시 정상 실행되는지 확인한다.

## 적용과 롤백

n8n Application은 main을 selfHeal하므로 live ConfigMap만 수정하지 않는다.
승인받은 GitOps 변경을 반영한 뒤 template revision annotation으로 n8n을 재시작한다.
Recreate 1 replica이므로 짧은 UI/스케줄러 중단이 발생할 수 있다. 실행 중 workflow가
없는지 먼저 확인한다. 실패 시 이 변경의 ConfigMap과 Deployment annotation을 함께
되돌리고 재시작해 기존 훅으로 복구한다. 사용자/credential/발행 workflow 데이터는 수정하지 않는다.

## 근거

- https://version-2026-2.goauthentik.io/add-secure-apps/providers/proxy/
- https://docs.goauthentik.io/add-secure-apps/providers/single-logout/

2026-10-18: 소스 및 로컬 회귀 테스트 검증. 운영 반영과 브라우저 왕복 결과는 공유 프로젝트의 docs/qa/2026-10-18-n8n-sso-login-recovery.md에 기록한다.
