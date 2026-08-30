# Secret Contracts

원문 secret은 이 저장소에 커밋하지 않는다. 아래 Secret은 live cluster에
수동으로 만들거나, Sealed Secrets 도입 후 `SealedSecret`으로 이관한다.

## Cloudflare DNS-01 ACME

`api.jjinbbang.kr`가 AWS를 가리키는 동안에도 OCI 인증서를 미리 발급하기 위해
cert-manager는 Cloudflare DNS-01 전용 API token을 사용한다. token 권한은
`jjinbbang.kr` zone의 `Zone / DNS / Edit`와 `Zone / Zone / Read`로 제한한다.

token 원문은 1Password 찐빵 vault에 보관하고, 클러스터에는
`cert-manager/cloudflare-api-token` Secret의 `api-token` 키로만 주입한다.

```bash
kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token='<cloudflare-dns-api-token>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Secret 적용 후 `letsencrypt-dns01-cloudflare` ClusterIssuer가 `Ready=True`인지
확인한다. Secret 값이나 평문 manifest는 Git에 추가하지 않는다.

## Authentik

```bash
AUTHENTIK_SECRET_KEY="$(openssl rand -hex 64)"
AUTHENTIK_POSTGRES_PASSWORD="$(openssl rand -base64 36)"

kubectl -n authentik create secret generic authentik \
  --from-literal=AUTHENTIK_SECRET_KEY="$AUTHENTIK_SECRET_KEY" \
  --from-literal=AUTHENTIK_POSTGRESQL__HOST="authentik-postgresql" \
  --from-literal=AUTHENTIK_POSTGRESQL__NAME="authentik" \
  --from-literal=AUTHENTIK_POSTGRESQL__USER="authentik" \
  --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="$AUTHENTIK_POSTGRES_PASSWORD"

kubectl -n authentik create secret generic authentik-postgresql \
  --from-literal=postgres-password="$AUTHENTIK_POSTGRES_PASSWORD" \
  --from-literal=password="$AUTHENTIK_POSTGRES_PASSWORD"
```

`authentik` chart에서 `authentik.existingSecret.secretName`을 쓰면 chart values의
`authentik.postgresql.*` 값은 Secret으로 자동 생성되지 않는다. 그래서
Authentik runtime Secret 안에 `AUTHENTIK_POSTGRESQL__*` 환경 변수를 함께 둔다.

## Authentik Bootstrap and SSO

`platform/authentik/bootstrap`은 `/blueprints/system/bootstrap.yaml`과
`jjinbbang-sso.yaml`을 적용한다. Secret 값은 화면에 출력하지 말고 env-file로
생성한다. 운영·개발 관리자 Provider는 각각 `ADMIN_OIDC_CLIENT_SECRET`과
`ADMIN_OIDC_DEV_CLIENT_SECRET`를 사용한다.

```bash
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/authentik-bootstrap.env" <<EOF
AUTHENTIK_BOOTSTRAP_EMAIL=<admin-email>
AUTHENTIK_BOOTSTRAP_PASSWORD=$(openssl rand -base64 36)
EOF

argocd_secret="$(openssl rand -base64 48)"
admin_oidc_secret="$(openssl rand -base64 48)"
cat >"$tmpdir/authentik-sso-bootstrap.env" <<EOF
ARGOCD_OIDC_CLIENT_SECRET=$argocd_secret
ADMIN_OIDC_CLIENT_SECRET=$admin_oidc_secret
ADMIN_OIDC_DEV_CLIENT_SECRET=$(openssl rand -base64 48)
N8N_PROXY_CLIENT_SECRET=$(openssl rand -base64 48)
N8N_PROXY_COOKIE_SECRET=$(openssl rand -hex 32)
EOF

cat >"$tmpdir/argocd-oidc.env" <<EOF
clientSecret=$argocd_secret
EOF

kubectl -n authentik create secret generic authentik-bootstrap \
  --from-env-file="$tmpdir/authentik-bootstrap.env" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n authentik create secret generic authentik-sso-bootstrap \
  --from-env-file="$tmpdir/authentik-sso-bootstrap.env" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n argocd create secret generic argocd-oidc-secret \
  --from-env-file="$tmpdir/argocd-oidc.env" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n argocd patch secret argocd-secret --type merge \
  -p "{\"data\":{\"oidc.authentik.clientSecret\":\"$(printf %s "$argocd_secret" | base64 | tr -d '\n')\"}}"
```

같은 `admin_oidc_secret` 값을 관리자 API 서버 Secret의
`AUTHENTIK_CLIENT_SECRET`에 넣는다. 쉘 히스토리나 저장소 파일에는 값을 남기지
않는다.

초기 admin 비밀번호는 cluster Secret에서만 조회한다.

```bash
kubectl -n authentik get secret authentik-bootstrap \
  -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_PASSWORD}' | base64 -d
```

## Argo CD OIDC

Authentik OAuth2/OpenID Provider 생성 후 client secret을 넣는다. 위
bootstrap 절차를 쓰는 경우 같은 값이 자동으로 만들어진다.

```bash
argocd_secret='REPLACE_WITH_AUTHENTIK_CLIENT_SECRET'

kubectl -n argocd create secret generic argocd-oidc-secret \
  --from-literal=clientSecret="$argocd_secret"

kubectl -n argocd patch secret argocd-secret --type merge \
  -p "{\"data\":{\"oidc.authentik.clientSecret\":\"$(printf %s "$argocd_secret" | base64 | tr -d '\n')\"}}"
```

Argo CD `argocd-cm`은 다음 참조를 사용한다.

```text
$oidc.authentik.clientSecret
```

## n8n

```bash
kubectl -n n8n create secret generic n8n-secrets \
  --from-literal=encryption-key="$(openssl rand -base64 32)"
```

`N8N_ENCRYPTION_KEY`는 한 번 운영 데이터가 생기면 바꾸면 안 된다.
교체가 필요하면 n8n credential export/import 또는 백업 복구 절차를 먼저
정한다.

첫 owner bootstrap 이후에는 임시 owner password를 live Secret에만 둔다.
이 값은 SSO 장애 시 break-glass 성격으로만 사용한다.

```bash
./scripts/bootstrap-n8n-owner.sh
kubectl -n n8n get secret n8n-owner-bootstrap \
  -o jsonpath='{.data.email}' | base64 -d
kubectl -n n8n get secret n8n-owner-bootstrap \
  -o jsonpath='{.data.password}' | base64 -d
```

## Jjinbbang API

`apps/jjinbbang-api`의 dev, prod, legacy overlay는 환경별 namespace에 아래 live
Secret을 기대한다.

| Secret | 내용 |
| --- | --- |
| `jjinbbang-api-secrets` | 환경 변수와 Redis 비밀번호 |
| `jjinbbang-api-runtime` | profile 파일과 `security-path.yml` |
| `jjinbbang-api-google` | `gcp_iam_key.json` |
| `ghcr-pull` | private GHCR Pull 인증 |

이미지에는 위 파일을 포함하지 않는다. namespace와 Secret을 먼저 만든 뒤 Argo CD
Application을 동기화한다.

```bash
kubectl create namespace jjinbbang-dev --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jjinbbang-dev create secret generic jjinbbang-api-secrets \
  --from-literal=SPRING_DATASOURCE_URL='<value>' \
  --from-literal=SPRING_DATASOURCE_USERNAME='<value>' \
  --from-literal=SPRING_DATASOURCE_PASSWORD='<value>' \
  --from-literal=SPRING_DATA_MONGODB_URI='<value>' \
  --from-literal=REDIS_HOST='<value>' \
  --from-literal=REDIS_PORT='6379' \
  --from-literal=REDIS_PASSWORD='<value>' \
  --from-literal=JWT_SECRET='<value>' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create namespace jjinbbang-prod --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jjinbbang-prod create secret generic jjinbbang-api-secrets \
  --from-literal=SPRING_DATASOURCE_URL='<value>' \
  --from-literal=SPRING_DATASOURCE_USERNAME='<value>' \
  --from-literal=SPRING_DATASOURCE_PASSWORD='<value>' \
  --from-literal=SPRING_DATA_MONGODB_URI='<value>' \
  --from-literal=REDIS_HOST='<value>' \
  --from-literal=REDIS_PORT='6379' \
  --from-literal=REDIS_PASSWORD='<value>' \
  --from-literal=JWT_SECRET='<value>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

legacy에도 같은 Secret 이름을 사용하되 값과 Redis PVC는 dev/prod와 공유하지 않는다.
레거시 profile은 OCI MySQL, OCI Object Storage 호환 endpoint, MongoDB Atlas와
`jjinbbang-redis`를 가리켜야 한다.

Deployment는 `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`를 Spring의
`SPRING_DATA_REDIS_*` 속성으로 명시 매핑한다. 외부 `application-prod.yml`에
`localhost` 값이 남아 있어도 이 Secret 값이 우선한다.

OCI S3 호환 endpoint의 namespace와 Customer Secret Key의 tenancy는 반드시
같아야 한다. 업로드 버킷도 그 namespace 안에 존재해야 하며, 애플리케이션이
반환하는 CDN base URL은 같은 버킷의 public object URL을 사용한다. 다른 tenancy의
동명 버킷이나 public mirror를 가리키면 presigned URL 생성은 성공해도 PUT은
`NoSuchBucket`으로 실패한다.

```bash
kubectl create namespace jjinbbang-legacy --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jjinbbang-legacy create secret generic jjinbbang-api-secrets \
  --from-literal=REDIS_HOST='jjinbbang-redis' \
  --from-literal=REDIS_PORT='6379' \
  --from-literal=REDIS_PASSWORD='<legacy-value>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

파일 Secret은 승인된 로컬 비밀 저장소에서 읽어 생성한다. 실제 경로와 값은
저장소에 기록하지 않는다.

```bash
kubectl -n <namespace> create secret generic jjinbbang-api-runtime \
  --from-file=application-prod.yml=<secure-application-prod.yml> \
  --from-file=application-dev.yml=<secure-application-dev.yml> \
  --from-file=security-path.yml=<secure-security-path.yml> \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n <namespace> create secret generic jjinbbang-api-google \
  --from-file=gcp_iam_key.json=<secure-gcp-key.json> \
  --dry-run=client -o yaml | kubectl apply -f -
```

Private GHCR Pull에는 패키지 읽기 전용 PAT classic을 사용한다. 개인 개발용 토큰이나
repo 쓰기 권한 토큰을 클러스터에 넣지 않는다.

```bash
kubectl -n <namespace> create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username='<package-reader>' \
  --docker-password='<read-packages-token>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

GitOps 자동 갱신에는 `JJinBBang_BE`와 `jjinbbang-lab` Actions Secret에 동일한
GitHub App 자격 증명을 등록한다.

```text
GITOPS_APP_ID
GITOPS_APP_PRIVATE_KEY
```

App은 `jjinbbang-lab`에만 설치하고 Contents read/write로 제한한다. lab Actions
variable `GITOPS_DISPATCH_SENDER`에는 App bot login을 등록한다. GHCR package의
Actions access에는 `jjinbbang-lab`을 Read로 추가한다.

OAuth provider, mail, OpenAI 키는 애플리케이션이 실제 읽는 항목만 환경별 Secret에
추가한다. 원문 값은 Git에 기록하지 않는다.

## Jjinbbang Admin

관리자 API는 환경별 MySQL과 Authentik OIDC 비밀값을 namespace별 live Secret에서
읽는다. `DB_URL`은 각 환경의 Flyway가 접속할 빈 스키마를 가리켜야 하며,
Hibernate가 테이블을 생성하도록 두지 않는다.

```bash
kubectl create namespace jjinbbang-admin-dev --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jjinbbang-admin-dev create secret generic jjinbbang-admin-secrets \
  --from-literal=DB_URL='jdbc:mysql://<mysql-host>:3306/<dev-database>?serverTimezone=UTC' \
  --from-literal=DB_USERNAME='<dev-value>' \
  --from-literal=DB_PASSWORD='<dev-value>' \
  --from-literal=AUTHENTIK_CLIENT_ID='jjinbbang-admin-dev' \
  --from-literal=AUTHENTIK_CLIENT_SECRET='<same ADMIN_OIDC_DEV_CLIENT_SECRET value>' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create namespace jjinbbang-admin --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jjinbbang-admin create secret generic jjinbbang-admin-secrets \
  --from-literal=DB_URL='jdbc:mysql://<mysql-host>:3306/<database>?serverTimezone=UTC' \
  --from-literal=DB_USERNAME='<value>' \
  --from-literal=DB_PASSWORD='<value>' \
  --from-literal=AUTHENTIK_CLIENT_ID='jjinbbang-admin' \
  --from-literal=AUTHENTIK_CLIENT_SECRET='<same ADMIN_OIDC_CLIENT_SECRET value>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Private GHCR Pull은 관리자 web/server Deployment가 `ghcr-pull`을 사용한다.
dev/prod namespace에 docker-registry Secret을 먼저 만들고, 공개 프로젝트 이미지는
가능하면 GHCR package visibility도 public으로 맞춘다.

관리자 API 이미지 GitOps 자동 갱신에는 `jjinbbang-server`와 `jjinbbang-lab`
저장소 Actions Secret에 동일한 GitHub App 자격 증명을 등록한다.

```text
GITOPS_APP_ID
GITOPS_APP_PRIVATE_KEY
```

App은 `jjinbbang-lab`에만 설치하고 Contents read/write로 제한한다. 공개
`jjinbbang-server`의 `main` HEAD 조회에는 App token을 사용하지 않는다. lab
Actions variable `GITOPS_DISPATCH_SENDER`에는 이 App의 bot login을 등록한다.
GHCR package가 private이면 package Actions access에 `jjinbbang-lab` 저장소를
Read로 추가해 workflow의 제한된 `GITHUB_TOKEN`이 manifest digest를 조회할
수 있게 한다.

## Sealed Secrets 이관 순서

1. 더미 secret seal/unseal 검증.
2. `n8n-secrets`.
3. `argocd-oidc-secret`.
4. `jjinbbang-api-secrets`.
5. `authentik`, `authentik-postgresql`.

Sealed Secrets controller private key 백업 전에는 운영 secret을 GitOps로
이관하지 않는다.
