# Cloudflare DNS Runbook

도메인은 Gabia에서 구입했고, 운영 DNS는 Cloudflare Free DNS를 기준으로
둔다.

## 1. Gabia nameserver 위임

Cloudflare에서 `jjinbbang.kr` zone을 만들고, Gabia 관리 화면에서
Cloudflare가 제시한 nameserver 2개로 변경한다.

확인:

```bash
dig +short NS jjinbbang.kr
```

응답 nameserver가 Cloudflare nameserver여야 한다.

이전 DNS provider에서 Cloudflare로 옮길 때는 기존 nameserver와 레코드를 먼저
확인한다.

```text
ns-1416.awsdns-49.org.
ns-175.awsdns-21.com.
ns-1002.awsdns-61.net.
ns-2040.awsdns-63.co.uk.
```

Cloudflare로 운영하려면 Gabia 또는 현재 DNS 관리 권한에서 nameserver 위임부터
바꿔야 한다.

이 Mac에서 확인한 현재 상태:

- `aws` CLI 없음
- Cloudflare CLI/token 없음
- `~/.aws` credential/config 없음

그래서 현재 세션에서는 DNS 변경을 직접 제출할 자격증명 경로가 없다.

## 2. 초기 DNS 레코드

처음에는 wildcard를 쓰지 않는다. 모든 레코드는 `DNS only`로 둔다.

| Name | Type | Value |
| --- | --- | --- |
| `auth` | A | `$WORKER_1_PUBLIC_IP` |
| `auth` | A | `$WORKER_2_PUBLIC_IP` |
| `argo` | A | `$WORKER_1_PUBLIC_IP` |
| `argo` | A | `$WORKER_2_PUBLIC_IP` |
| `n8n` | A | `$WORKER_1_PUBLIC_IP` |
| `n8n` | A | `$WORKER_2_PUBLIC_IP` |

core public IP `$CORE_PUBLIC_IP`는 public HTTP/HTTPS DNS target으로 쓰지 않는다.

Cloudflare API token이 있으면 아래 스크립트로 같은 레코드를 생성/갱신할 수
있다.

```bash
set -a
source .env
set +a
./scripts/cloudflare-upsert-dns.sh
./scripts/check-dns.sh
```

필요 권한:

```text
Zone:DNS:Edit
Zone:Zone:Read
```

`check-dns.sh`는 현재 nameserver 위임, `auth/argo/n8n` A record, worker edge
80/443 포트를 함께 확인한다.

API ingress까지 활성화할 때는 같은 worker edge IP로 앱 레코드를 추가한다.

```bash
JJINBBANG_DNS_RECORDS="auth argo n8n api-dev" ./scripts/cloudflare-upsert-dns.sh
JJINBBANG_DNS_RECORDS="auth argo n8n api-dev" ./scripts/check-dns.sh
```

`api.jjinbbang.kr`은 기존 AWS load balancer로 연결되어 있다. `api` 레코드는
기존 API 트래픽을 옮기는 컷오버 작업이므로 platform bootstrap과 분리해서
승인 후 변경한다.
스크립트도 `ALLOW_API_CUTOVER=true`가 없으면 `api` record 변경을 거부한다.

## 2.1. Route53 임시 경로

Cloudflare 위임 전에는 Route53 권한으로 `auth/argo/n8n` record를 임시로 만들
수 있다. 이 경로는 Cloudflare 전환 전 fallback이다.

필요한 것:

```text
aws CLI
AWS credentials with route53:ListHostedZonesByName and route53:ChangeResourceRecordSets
optional AWS_PROFILE
optional ROUTE53_HOSTED_ZONE_ID
```

실행:

```bash
set -a
source .env
set +a
./scripts/route53-upsert-dns.sh
./scripts/check-dns.sh
```

`api-dev`까지 만들 때:

```bash
JJINBBANG_DNS_RECORDS="auth argo n8n api-dev" ./scripts/route53-upsert-dns.sh
JJINBBANG_DNS_RECORDS="auth argo n8n api-dev" ./scripts/check-dns.sh
```

`api.jjinbbang.kr` cutover는 별도 승인 후에만 한다.

## 3. public edge 보안 규칙

OCI에서는 worker edge VNIC에만 TCP 80/443을 열어야 한다.

권장:

- `jjinbbang-public-edge` NSG 생성
- `jjinbbang-worker-1`, `jjinbbang-worker-2` VNIC만 연결
- ingress TCP 80/443 from `0.0.0.0/0`
- `jjinbbang-core` VNIC는 연결하지 않음

현재 bootstrap에서는 빠른 검증을 위해 default Security List에 TCP 80/443
ingress를 추가했다. Traefik LoadBalancer external IP가 worker 두 대만
가리키므로 실제 80/443 접속은 worker에서만 열리고 core는 닫힌 상태로
검증됐다. 장기적으로는 위 NSG 구성으로 좁히는 편이 더 명확하다.

검증:

```bash
nc -z -G 2 $WORKER_1_PUBLIC_IP 80
nc -z -G 2 $WORKER_1_PUBLIC_IP 443
nc -z -G 2 $WORKER_2_PUBLIC_IP 80
nc -z -G 2 $WORKER_2_PUBLIC_IP 443
nc -z -G 2 $CORE_PUBLIC_IP 80
nc -z -G 2 $CORE_PUBLIC_IP 443
```

worker는 open, core는 closed가 기대값이다.

2026-06-01 검증값:

```text
$WORKER_1_PUBLIC_IP:80  open
$WORKER_1_PUBLIC_IP:443 open
$WORKER_2_PUBLIC_IP:80  open
$WORKER_2_PUBLIC_IP:443 open
$CORE_PUBLIC_IP:80     closed
$CORE_PUBLIC_IP:443    closed
```

## 4. TLS 발급 확인

cert-manager 적용 후:

```bash
./scripts/post-dns-readiness.sh
```

이 스크립트는 `auth/argo/n8n` DNS, cert-manager Certificate `Ready=True`,
public HTTPS endpoint, Argo CD SSO preflight를 순서대로 확인한다. 인증서가
`Ready=True`가 되기 전에는 Cloudflare proxy를 켜지 않는다.

로컬 resolver가 이전 Route53 응답을 캐시하고 있으면 공용 resolver를 지정해
검증한다.

```bash
DNS_SERVER=1.1.1.1 ./scripts/check-dns.sh
DNS_SERVER=1.1.1.1 ./scripts/post-dns-readiness.sh
```

DNS가 아직 없으면 cert-manager HTTP-01 challenge는 아래처럼 pending으로
남는다.

```text
lookup auth.jjinbbang.kr: no such host
lookup n8n.jjinbbang.kr: no such host
lookup argo.jjinbbang.kr: no such host
```
