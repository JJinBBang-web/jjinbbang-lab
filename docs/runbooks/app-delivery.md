# App Delivery Runbook

찐빵 백엔드 배포는 GitHub Actions, GHCR, Argo CD, Kustomize를 기준으로 한다.

## 1. Repo 경계

| Repo | 역할 |
| --- | --- |
| `JJinBBang_BE` | 현재 운영 중인 레거시 Spring Boot 코드와 `jjinbbang-api` 이미지 빌드 |
| `jjinbbang-server` | 리팩터링 중인 통합 Spring Boot 코드와 `jjinbbang-server` 이미지 빌드 |
| `jjinbbang-lab` | Kubernetes manifest, Argo CD Application, 배포 환경 값 |

앱 코드 repo에서 Kubernetes resource를 직접 적용하지 않는다.

## 2. Image 흐름

```text
JJinBBang_BE develop/release
-> GitHub Actions ARM64 image build
-> private ghcr.io/jjinbbang-web/jjinbbang-api:<git-sha>
-> GitHub App repository_dispatch
-> jjinbbang-lab environment overlay digest update
-> Argo CD sync
```

이 repo 자체는 `.github/workflows/validate.yml`에서 YAML parse, shell syntax,
Kustomize build를 검증한다. 실제 이미지는 각 애플리케이션 repo에서 빌드한다.

## 3. 필요한 GitHub 설정

`JJinBBang_BE` workflow:

```text
packages: write
contents: read
```

이미지는 `linux/arm64`만 발행하고 package visibility가 `private`인지 발행 전후에
검증한다. 운영 profile, GCP 키, security-path는 이미지에 포함하지 않는다.

`jjinbbang-lab` 자동 갱신에는 Contents read/write 권한만 가진 GitHub App을
사용한다.

```text
contents: write
```

Private package 설정에서 `jjinbbang-lab` Actions access를 Read로 추가한다.
클러스터 Pull용 자격 증명은 별도 PAT classic의 `read:packages`만 허용하고
namespace별 `ghcr-pull` Secret으로 관리한다.

## 4. Manifest 구조

서비스 manifest는 platform bootstrap이 안정화된 뒤 추가한다.

```text
apps/jjinbbang-api/base
apps/jjinbbang-api/overlays/dev
apps/jjinbbang-api/overlays/prod
apps/jjinbbang-api/overlays/legacy
platform/applications/apps/jjinbbang-api-dev.yaml
platform/applications/apps/jjinbbang-api-prod.yaml
platform/applications/apps/jjinbbang-api-legacy.yaml
```

The app Applications are optional at this stage. They are intentionally not
referenced from `platform/kustomization.yaml` until DNS records and live Secrets
are ready.

dev:

- replica 1
- 작은 resource request
- auto sync 허용
- dev DB/Redis/Mongo secret 사용
- host `api-dev.jjinbbang.kr`
- control-plane node는 scheduling 대상에서 제외

prod:

- worker 두 대에 replica 2 이상
- PodDisruptionBudget 설정
- hostname 기준 topology spread 설정
- manual sync 기본
- DB migration과 백업 확인 후 승격
- host `api.jjinbbang.kr`

legacy:

- AWS EC2 운영 서버와 동일한 `release` SHA 기준 이미지
- `jjinbbang-legacy` 전용 DB, Redis PVC, Secret 사용
- `api.jjinbbang.kr` Ingress는 Cloudflare DNS-01 인증서와 함께 미리 준비
- DNS는 AWS를 유지하고 OCI worker IP에 `curl --resolve`로 HTTPS smoke test 수행
- Cloudflare 전환 전까지 AWS 트래픽 유지
- OCI Object Storage Customer Secret Key, S3 endpoint namespace, upload bucket이
  같은 tenancy인지 presigned PUT으로 확인
- RDS/OCI table count와 row checksum, MongoDB review ID와 image key, public object
  HTTP 응답을 함께 비교

## 5. Secret 계약

앱 Secret은 처음에는 live Secret로 만들고 Sealed Secrets 검증 후 이관한다.

예상 키:

```text
SPRING_DATASOURCE_URL
SPRING_DATASOURCE_USERNAME
SPRING_DATASOURCE_PASSWORD
SPRING_DATA_MONGODB_URI
REDIS_HOST
REDIS_PORT
REDIS_PASSWORD
JWT_SECRET
OPENAI_API_KEY
GOOGLE_CLIENT_ID
GOOGLE_CLIENT_SECRET
KAKAO_CLIENT_ID
KAKAO_CLIENT_SECRET
NAVER_CLIENT_ID
NAVER_CLIENT_SECRET
MAIL_USERNAME
MAIL_PASSWORD
```

파일 기반 Secret:

```text
jjinbbang-api-runtime/application-prod.yml
jjinbbang-api-runtime/application-dev.yml
jjinbbang-api-runtime/security-path.yml
jjinbbang-api-google/gcp_iam_key.json
ghcr-pull/.dockerconfigjson
```

Create the namespace and live Secret before syncing the Application. The
Application overlay also creates the namespace, but creating it first lets the
Secret exist before Argo CD starts the Deployment. Do not commit plaintext
secret values to this repo.

```bash
kubectl create namespace jjinbbang-dev --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jjinbbang-dev create secret generic jjinbbang-api-secrets \
  --from-literal=SPRING_DATASOURCE_URL='<value>' \
  --from-literal=SPRING_DATASOURCE_USERNAME='<value>' \
  --from-literal=SPRING_DATASOURCE_PASSWORD='<value>' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create namespace jjinbbang-prod --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jjinbbang-prod create secret generic jjinbbang-api-secrets \
  --from-literal=SPRING_DATASOURCE_URL='<value>' \
  --from-literal=SPRING_DATASOURCE_USERNAME='<value>' \
  --from-literal=SPRING_DATASOURCE_PASSWORD='<value>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

## 6. Application activation

Prerequisites:

- DNS records exist for `api-dev.jjinbbang.kr` and `api.jjinbbang.kr`. legacy
  사전 검증에서는 production DNS가 AWS를 계속 가리켜도 된다.
- `jjinbbang-api-secrets` exists in `jjinbbang-dev` and `jjinbbang-prod`.
- `jjinbbang-api-runtime`, `jjinbbang-api-google`, `ghcr-pull`이 대상 namespace에 존재한다.
- The referenced image tags exist in GHCR.
- GHCR package는 private이며 target namespace의 `ghcr-pull`로 인증한다.

`api.jjinbbang.kr` already resolves to the existing AWS load balancer. Do not
point `api` at this lab cluster until a production API cutover is explicitly
approved.

legacy 인증서 선발급에는 `cert-manager/cloudflare-api-token` Secret과
`letsencrypt-dns01-cloudflare` ClusterIssuer가 필요하다. 인증서가 Ready가 되면
DNS 변경 없이 worker edge를 직접 지정해 확인한다.

legacy와 prod overlay는 모두 `api.jjinbbang.kr`을 사용하므로 두 Ingress를
동시에 활성화하지 않는다. 현재 전환 준비 단계에서는 legacy Application만
활성화한다. 리팩터링 prod로 승격할 때는 먼저 legacy Ingress를 비활성화하고,
prod Ingress가 유일한 `api.jjinbbang.kr` 라우트인지 확인한 뒤 전환한다.

```bash
curl --resolve "api.jjinbbang.kr:443:$WORKER_1_PUBLIC_IP" \
  https://api.jjinbbang.kr/actuator/health
curl --resolve "api.jjinbbang.kr:443:$WORKER_2_PUBLIC_IP" \
  https://api.jjinbbang.kr/actuator/health
```

Activation options:

```bash
kubectl apply -k platform/applications/apps
```

Or add `applications/apps` to `platform/kustomization.yaml` after the
prerequisites are ready, then let the platform root Application sync it.

## 7. 승격 흐름

현재 lab 저장소의 기본 승격은 `feat -> main`이다. `develop` 또는 `master`
브랜치를 추가하기 전에는 문서와 Argo CD `targetRevision` 모두 `main`을
단일 운영 기준으로 사용한다.

1. feature branch에서 앱 코드 변경.
2. PR에서 test/build/scan 통과.
3. merge 후 dev image tag 갱신.
4. dev에서 smoke test.
5. prod overlay image tag 변경 PR 생성.
6. DB migration/rollback 확인 후 prod sync.

## 8. 배포 검증

Argo CD:

```bash
kubectl -n argocd get applications
```

Kubernetes:

```bash
kubectl -n jjinbbang-dev rollout status deployment/jjinbbang-api --timeout=300s
kubectl -n jjinbbang-dev get pods,svc,ingress -o wide
```

HTTP:

```bash
curl -fsS https://api-dev.jjinbbang.kr/actuator/health
```

이 endpoint와 host는 실제 API ingress를 만들 때 확정한다.
