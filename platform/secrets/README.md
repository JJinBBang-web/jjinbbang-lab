# Secret Contracts

원문 secret은 이 저장소에 커밋하지 않는다. 아래 Secret은 live cluster에
수동으로 만들거나, Sealed Secrets 도입 후 `SealedSecret`으로 이관한다.

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
생성한다.

```bash
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/authentik-bootstrap.env" <<EOF
AUTHENTIK_BOOTSTRAP_EMAIL=<admin-email>
AUTHENTIK_BOOTSTRAP_PASSWORD=$(openssl rand -base64 36)
EOF

argocd_secret="$(openssl rand -base64 48)"
cat >"$tmpdir/authentik-sso-bootstrap.env" <<EOF
ARGOCD_OIDC_CLIENT_SECRET=$argocd_secret
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

`apps/jjinbbang-api` overlays는 각 namespace에 같은 이름의 live Secret을
기대한다. namespace를 먼저 만든 뒤 Secret을 적용해야 Argo CD가 Deployment를
시작할 때 `envFrom.secretRef`가 준비된다.

```bash
kubectl create namespace jjinbbang-dev --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jjinbbang-dev create secret generic jjinbbang-api-secrets \
  --from-literal=SPRING_DATASOURCE_URL='<value>' \
  --from-literal=SPRING_DATASOURCE_USERNAME='<value>' \
  --from-literal=SPRING_DATASOURCE_PASSWORD='<value>' \
  --from-literal=SPRING_DATA_MONGODB_URI='<value>' \
  --from-literal=REDIS_HOST='<value>' \
  --from-literal=REDIS_PORT='6379' \
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
  --from-literal=JWT_SECRET='<value>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

OAuth provider, mail, and OpenAI keys are app-dependent. Add only the keys the
running application actually reads; keep raw values out of Git.

## Sealed Secrets 이관 순서

1. 더미 secret seal/unseal 검증.
2. `n8n-secrets`.
3. `argocd-oidc-secret`.
4. `jjinbbang-api-secrets`.
5. `authentik`, `authentik-postgresql`.

Sealed Secrets controller private key 백업 전에는 운영 secret을 GitOps로
이관하지 않는다.
