# Bootstrap Status

업데이트: 2026-06-02 02:19 KST

## 직접 검증한 내용

- `JJinBBang-web/jjinbbang-lab.git`을 `$JJINBBANG_LAB_PATH`에 clone했다.
- GitHub SSH clone은 local GitHub key 권한 문제로 실패했고, HTTPS clone은 성공했다.
- OCI profile `jjinbbang`에서 세 VM이 `RUNNING`임을 확인했다.

| 노드 | Shape | OCPU | Memory | Private IP | Public IP |
| --- | --- | ---: | ---: | --- | --- |
| `jjinbbang-core` | `VM.Standard.A1.Flex` | 1 | 8GiB | `$CORE_PRIVATE_IP` | `$CORE_PUBLIC_IP` |
| `jjinbbang-worker-1` | `VM.Standard.A1.Flex` | 2 | 8GiB | `$WORKER_1_PRIVATE_IP` | `$WORKER_1_PUBLIC_IP` |
| `jjinbbang-worker-2` | `VM.Standard.A1.Flex` | 1 | 8GiB | `$WORKER_2_PRIVATE_IP` | `$WORKER_2_PUBLIC_IP` |

- `$JJINBBANG_LAB_SSH_KEY`로 세 노드 SSH 접속을 확인했다.
- worker 두 대의 `k3s-agent`가 core API에 접근하지 못해 조인 실패 중이었다.
- 원인은 OCI security list에 subnet 내부 TCP 허용이 없었던 것이다.
- OCI security list에 `$VCN_CIDR` source, protocol `all` ingress를 추가했다.
- 추가 직후 worker 두 대가 자동으로 k3s cluster에 조인됐다.
- 현재 node 상태는 세 대 모두 `Ready`다.

```text
jjinbbang-core       Ready control-plane $CORE_PRIVATE_IP
jjinbbang-worker-1   Ready               $WORKER_1_PRIVATE_IP
jjinbbang-worker-2   Ready               $WORKER_2_PRIVATE_IP
```

- worker 두 대에 edge label을 추가했다.

```text
jjinbbang-worker-1 node-role.jjinbbang.dev/edge=true svccontroller.k3s.cattle.io/enablelb=true
jjinbbang-worker-2 node-role.jjinbbang.dev/edge=true svccontroller.k3s.cattle.io/enablelb=true
```

- k3s packaged Traefik에 `HelmChartConfig`를 적용해 worker edge로 제한했다.
- Traefik Deployment는 `2/2` Ready이며 worker 두 대에 1개씩 떠 있다.
- Traefik Service external IP는 worker public IP 두 개만 남았다.

```text
service/traefik EXTERNAL-IP $WORKER_2_PUBLIC_IP,$WORKER_1_PUBLIC_IP
```

- Argo CD official standard install manifest를 `argocd` namespace에 적용했다.
- Argo CD pod rollout을 확인했다.
- Argo CD 컴포넌트에 `node-role.jjinbbang.dev/core=true` nodeSelector를 patch했다.
- 모든 Argo CD pod가 `jjinbbang-core`에서 `Running`이다.
- Argo CD public Ingress와 `server.insecure=true`를 live 적용했다.
- `argocd-server` 재기동 중 `quay.io` 504로 새 Pod가 `ImagePullBackOff`에 빠졌고,
  `imagePullPolicy=IfNotPresent`로 보정해 rollout을 복구했다.
- DNS override로 worker edge 두 IP 모두에서 `https://argo.jjinbbang.kr/`가 `200`을 반환함을 확인했다.

```text
argocd-application-controller      Running on jjinbbang-core
argocd-applicationset-controller   Running on jjinbbang-core
argocd-dex-server                  Running on jjinbbang-core
argocd-notifications-controller    Running on jjinbbang-core
argocd-redis                       Running on jjinbbang-core
argocd-repo-server                 Running on jjinbbang-core
argocd-server                      Running on jjinbbang-core
```

- cert-manager `v1.20.2` static manifest를 적용했다.
- cert-manager, cainjector, webhook rollout을 확인했고 현재 active pod는 `jjinbbang-core`에 있다.
- `letsencrypt-http01` ClusterIssuer를 적용했고 ACME account 등록까지 완료되어 `Ready=True`다.

```text
clusterissuer/letsencrypt-http01 Ready=True
```

- `authentik`, `authentik-postgresql`, `n8n-secrets`, `authentik-bootstrap`,
  `authentik-sso-bootstrap`, `argocd-oidc-secret` live Secret을 생성했다.
- Authentik bootstrap/SSO용 one-shot Job manifest를 repo에 추가했고 live cluster에서 완료했다.
- 첫 Authentik HelmChart 적용은 PostgreSQL이 생성되지 않아 실패 상태였다.
- 원인은 `authentik.existingSecret` 사용 시 DB 접속 env를 runtime Secret에 직접 넣어야 하는 chart 계약이었다.
- repo Secret 문서와 Authentik Application values에 이 요구사항을 반영했다.
- Authentik HelmChart `2026.2.2`를 live cluster에 적용했고 PostgreSQL 서브차트도 함께 생성했다.
- repo의 Authentik Argo CD Application은 Argo CD가 Helm release를 직접 설치하지 않고,
  live와 같은 k3s `HelmChart` CR을 관리하도록 바꿨다.
- 기존 `AUTHENTIK_SECRET_KEY`가 base64 line-wrap을 포함해 embedded outpost
  bearer token으로 쓸 수 없었다. 줄바꿈 없는 hex secret으로 교체했고,
  `AUTHENTIK_TOKEN`을 같은 Secret에서 주입하도록 HelmChart values를 보강했다.
- Secret/HelmChart 보강 후 서버/워커 Deployment를 재기동했다.
- Authentik server, worker, PostgreSQL pod가 모두 `Running`/`Ready`다.

```text
authentik-postgresql-0              1/1 Running
authentik-server-7747966b4-6vpxl    1/1 Running
authentik-worker-69bd78464d-c5782   1/1 Running
```

- Authentik 내부 health와 initial setup flow를 확인했다.
- Bootstrap Job으로 `ryuwon` admin과 bootstrap admin email, usable password,
  `authentik Admins`/`jjinbbang-admins` group 소속을 확인했다.
- Argo CD OIDC Provider, n8n Proxy Provider, Embedded Outpost provider 연결,
  Kubernetes service connection을 확인했다.

```text
READY:200
SETUP:200
OUTPOST_PING:204
```

Embedded Outpost는 `auth.jjinbbang.kr`로 redirect URL을 만들도록 보정했다.
DNS 전파 전 내부 OIDC discovery를 위해 Authentik pod에 `auth.jjinbbang.kr`
hostAlias를 live patch로 임시 적용했다. 실제 worker IP는 repo manifest에
남기지 않는다.

- OCI default Security List에 public TCP 80/443 ingress를 추가했다.
- worker public IP 두 개는 80/443 접속이 열렸고, core public IP는 80/443이 닫혀 있음을 확인했다.

```text
$WORKER_1_PUBLIC_IP:80  open
$WORKER_1_PUBLIC_IP:443 open
$WORKER_2_PUBLIC_IP:80  open
$WORKER_2_PUBLIC_IP:443 open
$CORE_PUBLIC_IP:80     closed
$CORE_PUBLIC_IP:443    closed
```

- Authentik public Ingress를 live cluster에 적용했다.
- DNS override로 worker edge 두 IP 모두에서 Authentik initial setup URL이 `200`을 반환함을 확인했다.

```text
https://auth.jjinbbang.kr/if/flow/initial-setup/ -> 200
```

- n8n workload를 live cluster에 적용했다.
- n8n pod가 `jjinbbang-worker-2`에서 `Running`/`Ready`다.
- n8n 내부 health와 readiness를 확인했다.

```text
N8N:200
N8N_READY:200
```

- n8n 로그에서 forward-auth SSO shim이 로드됐음을 확인했다.

```text
n8n forward-auth SSO shim enabled
Editor is now accessible via:
https://n8n.jjinbbang.kr
```

- DNS override로 `n8n.jjinbbang.kr` 외부 접근을 확인했을 때 worker edge 두 IP 모두
  `/outpost.goauthentik.io/ping -> 204`, `/ -> 302`를 반환했다. redirect는
  `https://auth.jjinbbang.kr/application/o/authorize/...`로 향한다.
- Authentik Argo CD OIDC discovery endpoint도 DNS override에서 `200`을 반환한다.
- Cloudflare nameserver 위임이 완료됐다.

```text
anderson.ns.cloudflare.com.
love.ns.cloudflare.com.
```

- `1.1.1.1` 기준 공개 DNS에서 `auth`, `argo`, `n8n`은 worker edge IP 두 개로
  정상 응답한다.

```text
auth.jjinbbang.kr -> $WORKER_2_PUBLIC_IP,$WORKER_1_PUBLIC_IP
argo.jjinbbang.kr -> $WORKER_2_PUBLIC_IP,$WORKER_1_PUBLIC_IP
n8n.jjinbbang.kr -> $WORKER_2_PUBLIC_IP,$WORKER_1_PUBLIC_IP
```

- Cloudflare record는 초기 안정화 때문에 `DNS only` 상태로 둔다.
- cert-manager HTTP-01 self-check가 CoreDNS에서 NXDOMAIN을 보던 문제를
  확인했다. 원인은 k3s CoreDNS가 참조하던 노드 `/etc/resolv.conf` upstream이
  Cloudflare 전환 후에도 stale DNS를 반환한 것이다.
- CoreDNS `forward . /etc/resolv.conf`를 `forward . 1.1.1.1 8.8.8.8`로 live
  패치했고, pod 내부에서 세 host가 정상 해석됨을 확인했다.
- CoreDNS 변경 전 백업은 core 노드의 `/tmp/coredns-before-20260601-160055.yaml`에 있다.
- CoreDNS public forward 적용/확인/복구용 `scripts/patch-coredns-public-forward.sh`를 추가했다.
- `authentik-public-tls`, `argocd-public-tls`, `n8n-public-tls`,
  `authentik-outpost-tls`가 모두 `Ready=True`다.
- ACME challenge는 남아 있지 않고 order는 `valid` 상태다.
- 앱용 `api.jjinbbang.kr`은 기존 AWS load balancer로 응답한다. 이 레코드는
  API cutover 승인 전에는 변경하지 않는다.
- Cloudflare API로 A record를 생성/갱신하는 스크립트와 DNS 검증 스크립트를 추가했다.
  기본 검증 대상은 `auth/argo/n8n`이고, 필요 시 `JJINBBANG_DNS_RECORDS`로
  `api-dev`를 추가한다.
- Route53에서 임시 A record를 만들 수 있는 fallback 스크립트도 남겨뒀지만,
  현재 authoritative DNS는 Cloudflare다.
- 기존 API record 보호를 위해 `api.jjinbbang.kr` 변경은
  `ALLOW_API_CUTOVER=true` 없이는 스크립트가 거부한다.
- Argo CD SSO 전환은 `scripts/apply-argocd-sso.sh`로 guarded 적용하도록
  했다. DNS/TLS/Secret/public OIDC discovery가 준비되지 않으면
  `admin.enabled=false` overlay 적용을 거부한다.
- Argo CD root Application은 `scripts/apply-root-app.sh`로 guarded 적용하도록
  했다. 원격 GitHub `main`의 root manifest가 로컬 파일과 일치하지 않으면
  적용을 거부한다.
- DNS 설정 후 TLS와 public endpoint, Argo CD SSO preflight를 한 번에 확인하는
  `scripts/post-dns-readiness.sh`를 추가했다.
- `scripts/post-dns-readiness.sh`는 `DNS_SERVER=1.1.1.1` 사용 시 `curl --resolve`
  로컬 override를 써서 Mac resolver cache 영향 없이 public endpoint를 확인한다.
- `scripts/post-dns-readiness.sh`가 통과했다.

```text
https://auth.jjinbbang.kr/if/flow/initial-setup/ -> 200
https://auth.jjinbbang.kr/application/o/argocd/.well-known/openid-configuration -> 200
https://n8n.jjinbbang.kr/outpost.goauthentik.io/ping -> 204
https://n8n.jjinbbang.kr/ -> 302
https://argo.jjinbbang.kr/ -> 200
argocd sso preflight ok
post-dns readiness ok
```

- Argo CD SSO overlay를 live 적용했다. `argocd-cm`에는 `admin.enabled=false`,
  Authentik OIDC issuer, `url=https://argo.jjinbbang.kr`가 들어갔다.
- `argocd-rbac-cm`은 `jjinbbang-admins -> role:admin`,
  `jjinbbang-observers -> role:readonly`로 적용됐다.
- `argocd-server` 재기동 직후 외부 확인에서 502가 한 번 발생했지만, rollout 완료
  후 worker edge 두 IP 모두 `https://argo.jjinbbang.kr/ -> 200`을 반환했다.
- Argo CD settings API에서 Authentik OIDC config와 `userLoginsDisabled=true`를 확인했다.
- repo/DNS/cluster/certificate/root/SSO gate를 한 번에 보는
  `scripts/status.sh`를 추가했다.
- repo manifest 검증용 GitHub Actions workflow를 추가했다.
- `apps/jjinbbang-api` dev/prod Kustomize scaffold와 선택형 Argo CD
  Application manifest를 추가했다. 아직 `platform/kustomization.yaml`에는
  연결하지 않았다.
- root와 platform child Argo CD Application은 `selfHeal=true`, `prune=false`로 구성했다.
- `jjinbbang-lab` bootstrap 변경분은 GitHub `main`에 merge됐다.
- `scripts/apply-root-app.sh --check`가 통과했고 root Application을 live cluster에 적용했다.
- Argo CD가 platform child Application을 생성했고 모든 Application이 `Synced/Healthy`로 수렴했다.

```text
authentik            Synced   Healthy
jjinbbang-platform   Synced   Healthy
n8n                  Synced   Healthy
sealed-secrets       Synced   Healthy
```

- `scripts/status.sh`가 통과했다.

```text
remote root app on main: HTTP 200
dns check ok
root app preflight: ok
argocd sso preflight: ok
n8n owner and forward-auth: ok
status: ready
```
- n8n owner를 Authentik bootstrap email과 같은 값으로 생성했다.
- owner bootstrap password는 live Secret `n8n/n8n-owner-bootstrap`에만 보관한다.
- n8n `showSetupOnFirstLoad=false`를 확인했고, Authentik email header가 들어오면
  n8n auth cookie가 발급되는 것을 확인했다.

```text
showSetupOnFirstLoad=false
forward_auth_status=200
forward_auth_cookie=present
```

- local manifest 검증을 통과했다.

```text
./scripts/validate-manifests.sh
yaml parse ok
kubectl kustomize platform ok
kubectl kustomize n8n ok
kubectl kustomize authentik ok
kubectl kustomize authentik bootstrap ok
kubectl kustomize argocd sso ok
kubectl kustomize jjinbbang-api dev ok
kubectl kustomize jjinbbang-api prod ok
kubectl kustomize app applications ok
```

## 남은 수동 작업

- Authentik `ryuwon` admin은 생성됐지만 passkey/TOTP 설정은 아직 브라우저에서 완료하지 않았다.
- API 배포는 `api-dev` DNS, 앱 secret, GHCR image tag가 준비된 뒤
  `platform/applications/apps`를 별도로 적용한다. `api` production DNS는 기존
  AWS endpoint cutover 승인 후 변경한다.

## 다음 운영 순서

1. `https://auth.jjinbbang.kr`에서 `ryuwon`으로 로그인하고 passkey/TOTP를 설정한다.
2. Argo CD는 `https://argo.jjinbbang.kr`에서 Authentik SSO로 로그인 확인한다.
3. n8n은 `https://n8n.jjinbbang.kr`에서 Authentik SSO로 로그인 확인한다.
4. README와 GitHub Actions workflow 문서/검증 보강분을 별도 PR로 올린다.
5. API 배포 준비가 끝나면 `api-dev`부터 GitOps Application을 연결한다.
