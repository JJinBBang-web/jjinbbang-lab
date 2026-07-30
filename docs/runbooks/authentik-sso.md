# Authentik SSO Runbook

Authentik은 운영 도구 접근의 SSO 기준이다.

## 1. Bootstrap Job

초기 admin과 SSO Provider는 `platform/authentik/bootstrap`의 one-shot Job으로
만든다. 이 Job은 Authentik runtime Secret, bootstrap Secret, SSO Secret을
읽고 다음 blueprint를 적용한다.

- `/blueprints/system/bootstrap.yaml`: 초기 admin 생성.
- `jjinbbang-sso.yaml`: `ryuwon` admin 보정, Argo CD와 관리자 앱 OIDC Provider,
  n8n Proxy Provider, Embedded Outpost 연결.
- Job 후처리: Embedded Outpost의 internal host와 browser host를 고정.

embedded outpost가 OIDC discovery URL을 public host로 만들려면
`auth.jjinbbang.kr` DNS가 먼저 정상이어야 한다. 초기 bootstrap 중 DNS 전파가
늦으면 hostAlias를 live patch로 임시 적용할 수 있지만, 실제 worker IP를 repo
manifest에 커밋하지 않는다.

Secret 생성 예시는 `platform/secrets/README.md`를 따른다. 값은 터미널에
출력하지 않고 env-file로 넣는다.

```bash
kubectl apply -k platform/authentik/bootstrap
kubectl -n authentik wait --for=condition=complete job/authentik-apply-blueprints --timeout=300s
```

Job을 다시 실행해야 하면 기존 Job을 먼저 지운다.

```bash
kubectl -n authentik delete job authentik-apply-blueprints
kubectl apply -k platform/authentik/bootstrap
```

초기 admin 비밀번호는 필요할 때만 Secret에서 조회한다.

```bash
kubectl -n authentik get secret authentik-bootstrap \
  -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_PASSWORD}' | base64 -d
```

## 2. 초기 admin 보강

Authentik 배포 후 브라우저에서 `auth.jjinbbang.kr`로 접속한다. 처음 접속을
`localhost` port-forward로 하지 않는다. Embedded Outpost가 최초 접근 URL을
기준으로 자기 URL을 잡을 수 있기 때문이다.

```text
https://auth.jjinbbang.kr/if/flow/initial-setup/
```

Bootstrap Job을 사용하면 `ryuwon` admin 사용자는 이미 만들어져 있다. 최초 로그인
후 passkey와 TOTP를 모두 등록한다. 이 사용자는 `authentik Admins`,
`jjinbbang-admins`, `jjinbbang-backoffice-admins` group에 속한다.

## 3. Argo CD OIDC Provider

Bootstrap Job을 사용하면 Authentik OAuth2/OpenID Provider가 이미 만들어져
있다. UI에서 수동으로 만들 때는 아래 값과 맞춘다.

| 항목 | 값 |
| --- | --- |
| Name | `argocd` |
| Client type | Confidential |
| Redirect URI | `https://argo.jjinbbang.kr/auth/callback` |
| Issuer mode | per-provider |
| Signing key | Authentik 기본 signing key |

Argo CD manifest는 아래 issuer를 참조한다.

```text
https://auth.jjinbbang.kr/application/o/argocd/
```

client secret은 Kubernetes Secret으로만 저장한다. Argo CD OIDC 설정은
`argocd-secret`의 `oidc.authentik.clientSecret` 키만 참조한다.
`argocd-oidc-secret`은 bootstrap source로 유지하고, guarded script가 이 값을
`argocd-secret`으로 동기화한다.

```bash
kubectl -n argocd create secret generic argocd-oidc-secret \
  --from-literal=clientSecret='REPLACE_WITH_AUTHENTIK_CLIENT_SECRET'
```

OIDC Provider, Secret, public DNS, TLS가 모두 준비되기 전에는 `argocd-cm`의
`admin.enabled=false`를 적용하지 않는다. 초기 root Application은 잠금 방지를
위해 Argo CD OIDC/RBAC 전환 설정을 제외한다. 준비 후 guarded script로
preflight를 먼저 확인한다.

```bash
./scripts/apply-argocd-sso.sh --check
./scripts/apply-argocd-sso.sh
```

이 스크립트는 `auth/argo/n8n` DNS, `authentik-public-tls`,
`argocd-public-tls`, `n8n-public-tls`, `argocd-oidc-secret`, public OIDC
discovery가 준비되지 않으면 적용을 거부한다. 실제 Argo CD가 읽는
`argocd-secret/oidc.authentik.clientSecret`도 함께 검증한다.

권장 group mapping:

```text
jjinbbang-admins -> role:admin
jjinbbang-observers -> role:readonly
```

`authentik Admins` group도 bootstrap overlay에서 Argo CD Application 접근
권한을 받는다. Argo CD RBAC에서는 `jjinbbang-admins`와
`jjinbbang-observers`를 기준으로 권한을 나눈다.

## 4. 찐빵 관리자 OIDC Provider

관리자 앱은 인프라 도구와 다른 `jjinbbang-backoffice-admins` 그룹을 사용한다.

| 항목 | 값 |
| --- | --- |
| Name / slug | `jjinbbang-admin` |
| Client type | Confidential |
| Redirect URI | `https://admin.jjinbbang.kr/login/oauth2/code/authentik` |
| Post logout URI | `https://admin.jjinbbang.kr/login?logout` |
| Issuer | `https://auth.jjinbbang.kr/application/o/jjinbbang-admin/` |

client secret은 `authentik-sso-bootstrap`의 `ADMIN_OIDC_CLIENT_SECRET`과 관리자
서버 Secret의 `AUTHENTIK_CLIENT_SECRET`에 같은 값으로 넣는다. 앱 자체
회원가입은 제공하지 않는다.

## 5. n8n Proxy Provider

n8n은 Authentik Proxy Provider와 Traefik forwardAuth로 보호한다. Bootstrap
Job을 사용하면 Proxy Provider와 Embedded Outpost 연결이 이미 만들어져 있다.

| 항목 | 값 |
| --- | --- |
| Provider type | Proxy Provider |
| Mode | Forward auth, single application |
| External host | `https://n8n.jjinbbang.kr` |
| Outpost | Embedded Outpost |
| Authentication flow | passkey 기반 flow |
| Authorization | `authentik Admins`, `jjinbbang-admins` |

Traefik middleware는 n8n namespace의 `ExternalName` Service를 통해 아래
endpoint를 호출한다.

```text
http://ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik
```

Provider가 Embedded Outpost에 연결되기 전에는 `/outpost.goauthentik.io/ping`
응답이 `404`일 수 있다. 이 상태에서 n8n public ingress는 fail-closed로 닫힌다.

Provider 연결 후 확인:

```bash
curl -k --resolve n8n.jjinbbang.kr:443:$WORKER_1_PUBLIC_IP \
  https://n8n.jjinbbang.kr/outpost.goauthentik.io/ping
```

정상 기대값은 `204`다.

## 6. n8n 내부 사용자

n8n Community에서는 공식 내부 OIDC SSO 대신 forward-auth shim을 쓴다.
Authentik user email과 n8n user email이 같아야 자동 cookie 발급이 가능하다.

shim이 user를 찾지 못하면 401로 fail-closed 한다.

초기 owner는 Authentik bootstrap email과 같은 값으로 만든다. password는
`n8n/n8n-owner-bootstrap` live Secret에만 보관하고 repo에는 넣지 않는다.
다른 email을 써야 하면 `N8N_OWNER_EMAIL` 환경 변수로 넘긴다.

```bash
./scripts/bootstrap-n8n-owner.sh
./scripts/bootstrap-n8n-owner.sh --check
```

정상 기대값:

```text
showSetupOnFirstLoad=false
forward_auth_status=200
forward_auth_cookie=present
```

n8n pod 로그에서 shim 로드도 확인한다.

```text
n8n forward-auth SSO shim enabled
```

## 7. 복구

SSO가 깨지면 다음 순서로 복구한다.

1. `auth.jjinbbang.kr` 직접 접속 가능 여부 확인.
2. Argo CD는 SSH port-forward로 우회 접속.
3. n8n은 Traefik Middleware annotation을 임시 제거하면 Authentik edge gate만 빠진다.
4. n8n forward-auth hook을 비활성화하려면 `N8N_FORWARD_AUTH_ENABLED=false`로 재배포한다.
