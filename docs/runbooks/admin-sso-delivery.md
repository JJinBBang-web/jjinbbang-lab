# Admin SSO and Delivery Runbook

찐빵 관리자 웹과 API는 dev/prod 환경으로 분리한다.

| 환경 | 웹/API 브랜치 | Host | Namespace | Authentik Provider |
| --- | --- | --- | --- | --- |
| dev | `develop` | `admin-dev.jjinbbang.kr` | `jjinbbang-admin-dev` | `jjinbbang-admin-dev` |
| prod | `main` | `admin.jjinbbang.kr` | `jjinbbang-admin` | `jjinbbang-admin` |

각 환경은 별도 DB/schema, Secret, OIDC client/redirect URI를 사용한다.
브라우저에는 HttpOnly 세션 쿠키만 남기고 OIDC 토큰은 관리자 서버가 보관한다.
## 요청 경로

| 경로 | 대상 |
| --- | --- |
| `/api`, `/oauth2`, `/login/oauth2` | `jjinbbang-admin-server` |
| `/`, `/login` | `jjinbbang-admin-web` |

로그인 시작 경로는 `/oauth2/authorization/authentik`이다. Authentik 인증이
끝나면 Spring Security가 `/login/oauth2/code/authentik`에서 callback을
받고 기본적으로 `/api/admin/auth/me`로 이동한다. 프론트엔드는
`ADMIN_LOGIN_SUCCESS_URI`를 화면 경로로 바꾸고, 서버가 제공하는 로그인
시작·세션 조회·CSRF 조회·로그아웃 API 계약을 사용한다.

회원가입, 비밀번호, MFA는 Authentik에서만 관리한다. 애플리케이션은
`(issuer, subject)`로 `admins` 행을 처음 로그인할 때 만들고 이후 프로필과
마지막 로그인 시각을 동기화한다.

## 권한 경계

- 관리자 앱 전용 그룹: `jjinbbang-backoffice-admins`
- 기존 운영 도구 그룹 `jjinbbang-admins`와 분리한다.
- Authentik Application policy와 Spring 서버의 `groups` claim 검증을 모두
  통과해야 한다.
- 로컬 `admins.status=DEACTIVATED`이면 Authentik 로그인이 성공해도 거부한다.

첫 운영자 `ryuwon`은 bootstrap blueprint에서 앱 전용 그룹에 포함한다. 다른
운영자는 Authentik에서 이 그룹에 명시적으로 추가한다.

## 배포 흐름

```text
component별 source repository develop/main
-> test/build
-> GHCR에 전체 Git SHA 태그와 digest로 이미지 게시
-> GitHub App으로 jjinbbang-lab repository_dispatch
-> 발신 App, component별 source/image, source branch HEAD, 환경, image digest 검증
-> 해당 환경 overlay의 선택한 component image digest 갱신
-> manifest 전체 검증
-> 사용자 승인 전까지 자동 commit/push 중지
```

`develop`은 `dev` overlay만 갱신하고 `main`은 `prod` overlay만 갱신한다.
component별 허용 payload는 다음과 같다. 태그는 source SHA와 같은 40자리 소문자
hex이고 digest는 `sha256:` 뒤 64자리 소문자 hex여야 한다.

| component | source repository | GHCR image |
| --- | --- | --- |
| `web` | `JJinBBang-web/JJinBBang_Admin` | `ghcr.io/jjinbbang-web/jjinbbang-admin` |
| `server` | `JJinBBang-web/jjinbbang-server` | `ghcr.io/jjinbbang-web/jjinbbang-server` |

`scripts/update-admin-image.sh`는 위 payload와 환경/branch 매핑을 검증하고 선택한
overlay의 선택 component만 `IMAGE@sha256:...`로 갱신한다. workflow는 이 공유
스크립트 밖에서 dispatch sender, 원격 source branch HEAD, 실제 GHCR manifest
digest를 검증한다.

현재 workflow의 `contents` 권한은 read-only이고 자동 commit/push 단계는
비활성화되어 있다. 따라서 workflow 실행 결과는 검증된 working-tree 변경이며
`jjinbbang-lab/main`에는 반영되지 않는다. 자동 commit/push를 활성화하려면 별도
사용자 승인을 받은 뒤 write-scoped GitHub App checkout과 commit/push 단계를
함께 검토해야 한다. 승인 전에는 이를 활성화하지 않는다.

source 저장소의 dispatch workflow에 다음 Actions Secret을 설정한다.

```text
GITOPS_APP_ID
GITOPS_APP_PRIVATE_KEY
```

GitHub App은 repository dispatch 발신에 사용한다. source branch HEAD는 공개
GitHub API로 확인하고 개인 PAT는 사용하지 않는다. 각 앱 이미지 게시에는 저장소
기본 `GITHUB_TOKEN`의 Packages write 권한을 쓴다. 향후 자동 commit/push 승인
시에는 App을 `jjinbbang-lab`에 설치하고 Contents write 범위를 lab 저장소로만
제한한다.

`jjinbbang-lab` Actions variable에는 repository dispatch를 보내는 GitHub App
bot login을 정확히 설정한다.

```text
GITOPS_DISPATCH_SENDER=jjinbbang-gitops[bot]
```

실제 App slug가 다르면 GitHub audit log 또는 최초 거부된 workflow의
`unexpected dispatch sender` 값으로 확인해 variable만 맞춘다. 수신 workflow는
발신자, source repository, source branch HEAD, image digest가 모두 일치해야만
desired state를 변경한다. GHCR package가 private이면 package 설정의 Actions
access에 `JJinBBang-web/jjinbbang-lab`을 Read로 추가한다. 수신 workflow의
`GITHUB_TOKEN`은 Packages read 외 권한을 사용하지 않고, `image:SHA`가 가리키는
실제 manifest digest와 dispatch digest를 대조한다.

현재 `jjinbbang-lab` 수신 workflow에는 Contents write 권한을 주지 않는다.
자동 반영을 별도 승인한 뒤에도 `main` branch protection이 직접 push를 막으면
승인 범위에 PR 생성 방식을 포함해 다시 결정한다.

## 최초 활성화 전 게이트

아래 조건을 모두 충족하기 전에는 관리자 API Argo CD Application을 적용하지
않는다.

1. `admin-dev.jjinbbang.kr`와 `admin.jjinbbang.kr`이 worker edge를 가리킨다.
2. dev/prod용 빈 MySQL database/schema와 전용 사용자가 준비되어 있다.
3. 두 namespace의 `jjinbbang-admin-secrets`가 각각 `DB_*`,
   `AUTHENTIK_CLIENT_ID`, `AUTHENTIK_CLIENT_SECRET` 키를 가진다.
4. Authentik bootstrap Secret에 `ADMIN_OIDC_CLIENT_SECRET`과
   `ADMIN_OIDC_DEV_CLIENT_SECRET`이 들어 있고 blueprint Job 재적용이 성공했다.
5. 웹/API GHCR image가 실제 SHA 태그로 존재하며 클러스터에서 pull 가능하다.
6. dev/prod overlay의 웹/API image가 실제 `sha256` digest를 가리킨다.

준비 후 Authentik blueprint를 다시 적용한다.

```bash
kubectl -n authentik delete job authentik-apply-blueprints-v2 --ignore-not-found
kubectl apply -k platform/authentik/bootstrap
kubectl -n authentik wait --for=condition=complete \
  job/authentik-apply-blueprints-v2 --timeout=300s
```

그 다음 dev/prod Application을 활성화한다.

```bash
kubectl apply -f platform/applications/apps/jjinbbang-admin-dev.yaml
kubectl apply -f platform/applications/apps/jjinbbang-admin.yaml
kubectl -n argocd get application jjinbbang-admin-dev jjinbbang-admin
kubectl -n jjinbbang-admin-dev rollout status deployment/jjinbbang-admin-server --timeout=300s
kubectl -n jjinbbang-admin rollout status deployment/jjinbbang-admin-server --timeout=300s
```

## 검증

GitOps payload와 overlay 변경 불변식은 임시 복사본에서 먼저 검증한다.

```bash
bash -n scripts/update-admin-image.sh scripts/test-update-admin-image.sh scripts/validate-manifests.sh
./scripts/test-update-admin-image.sh
./scripts/validate-manifests.sh
```

첫 번째 테스트는 잘못된 component/environment/source/ref/image/digest를 거부하고,
dev web과 prod server fixture에서 선택하지 않은 환경과 component가 byte-for-byte
동일한지 확인한다.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  https://admin-dev.jjinbbang.kr/api/admin/auth/me
curl -sS -o /dev/null -w '%{http_code}\n' \
  https://admin.jjinbbang.kr/api/admin/auth/me
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  https://admin-dev.jjinbbang.kr/oauth2/authorization/authentik
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  https://admin.jjinbbang.kr/oauth2/authorization/authentik
```

로그아웃 상태의 `/api/admin/auth/me` 기대값은 `401`이고 로그인 시작 경로는
Authentik으로 `302` 응답해야 한다. 실제 계정 로그인과 로그아웃은 Authentik
Provider, DNS, Secret 적용 후 브라우저에서 검증한다. 프론트팀은 서버 API
계약을 기준으로 화면 진입과 보호 라우트를 연결한다.

## 롤백

앱 코드 롤백은 `kustomization.yaml`의 image digest를 직전 정상 digest로
되돌린다. DB migration은 이미 적용된 파일을 수정하지 않고 새 Flyway migration
으로만 보정한다. Argo CD는 `prune=false`이므로 리소스 삭제는 별도 승인 후
수동으로 처리한다.
