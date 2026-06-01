# Bootstrap Runbook

이 문서는 새 워크스테이션이나 재개 작업에서 `jjinbbang-lab` 클러스터를
확인하고 Argo CD root Application을 적용하는 절차다.

## 1. 로컬 환경

```bash
cd $JJINBBANG_LAB_PATH
cp .env.example .env
set -a
source .env
set +a
chmod 600 "$JJINBBANG_LAB_SSH_KEY"
```

`.env`는 커밋하지 않는다.

## 2. SSH 확인

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" 'hostname; hostname -I'
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$WORKER_1_PUBLIC_IP" 'hostname; hostname -I'
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$WORKER_2_PUBLIC_IP" 'hostname; hostname -I'
```

예상:

```text
jjinbbang-core
jjinbbang-worker-1
jjinbbang-worker-2
```

## 3. k3s 상태 확인

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" \
  'sudo k3s kubectl get nodes -o wide && sudo k3s kubectl get pods -A -o wide'
```

예상:

```text
jjinbbang-core       Ready control-plane
jjinbbang-worker-1   Ready
jjinbbang-worker-2   Ready
```

## 4. 노드 라벨

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" \
  'sudo k3s kubectl get nodes --show-labels'
```

필수 라벨:

```text
jjinbbang-core       node-role.jjinbbang.dev/core=true
jjinbbang-worker-1   node-role.jjinbbang.dev/app=true,node-role.jjinbbang.dev/edge=true,svccontroller.k3s.cattle.io/enablelb=true
jjinbbang-worker-2   node-role.jjinbbang.dev/ops=true,node-role.jjinbbang.dev/edge=true,svccontroller.k3s.cattle.io/enablelb=true
```

필요하면 적용:

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" '
  sudo k3s kubectl label node jjinbbang-core node-role.jjinbbang.dev/core=true --overwrite
  sudo k3s kubectl label node jjinbbang-worker-1 node-role.jjinbbang.dev/app=true node-role.jjinbbang.dev/edge=true svccontroller.k3s.cattle.io/enablelb=true --overwrite
  sudo k3s kubectl label node jjinbbang-worker-2 node-role.jjinbbang.dev/ops=true node-role.jjinbbang.dev/edge=true svccontroller.k3s.cattle.io/enablelb=true --overwrite
'
```

## 5. OCI 네트워크 확인

worker가 core에 조인하려면 subnet 내부 통신이 열려 있어야 한다.

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$WORKER_1_PUBLIC_IP" \
  "nc -z -w 2 $CORE_PRIVATE_IP 6443 && echo api-open"
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$WORKER_2_PUBLIC_IP" \
  "nc -z -w 2 $CORE_PRIVATE_IP 6443 && echo api-open"
```

OCI security list에는 최소한 아래 ingress가 필요하다.

```text
source: $VCN_CIDR
protocol: all
description: allow private intra-subnet traffic for k3s nodes
```

public 80/443은 worker edge IP에만 열고 core에는 열지 않는다. OCI security
list만 쓰면 subnet 단위로 열리므로, 가능하면 NSG로 worker VNIC만 public edge
그룹에 넣는 구성을 선호한다.

## 6. Argo CD 최초 설치

Argo CD가 아직 없을 때만 실행한다.

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" '
  sudo k3s kubectl create namespace argocd --dry-run=client -o yaml | sudo k3s kubectl apply -f -
  sudo k3s kubectl apply -n argocd --server-side --force-conflicts \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  sudo k3s kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
'
```

기본 install manifest는 scheduler에 배치를 맡기므로, 설치 직후 core에 고정한다.

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" '
  for d in argocd-applicationset-controller argocd-dex-server argocd-notifications-controller argocd-redis argocd-repo-server argocd-server; do
    sudo k3s kubectl -n argocd patch deploy "$d" --type=merge -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"node-role.jjinbbang.dev/core\":\"true\"}}}}}"
  done
  sudo k3s kubectl -n argocd patch statefulset argocd-application-controller --type=merge -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"node-role.jjinbbang.dev/core\":\"true\"}}}}}"
  sudo k3s kubectl -n argocd patch deploy argocd-server --type=json -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"IfNotPresent\"}]"
'
```

확인:

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" \
  'sudo k3s kubectl -n argocd get pods -o wide'
```

모든 Argo CD pod가 `jjinbbang-core`에 있어야 한다.

`argocd-server`를 재시작할 때 registry 일시 장애로 이미지 pull이 막힐 수
있어서 `imagePullPolicy=IfNotPresent`를 적용한다. 2026-06-01에
`quay.io` 504로 새 Pod가 `ImagePullBackOff`에 빠졌고, 캐시된 이미지를
재사용하도록 보정해 rollout을 복구했다.

## 7. cert-manager bootstrap

cert-manager는 root Application 전에 한 번 수동 설치한다. 이 클러스터에서는
`v1.20.2` static manifest로 bootstrap했다. Helm Application으로 다시 만들면
기존 static resource와 ownership 충돌이 날 수 있으므로, migration을 따로
잡기 전에는 root가 cert-manager 자체를 재설치하지 않는다.

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" '
  sudo k3s kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.yaml
  for d in cert-manager cert-manager-cainjector cert-manager-webhook; do
    sudo k3s kubectl -n cert-manager patch deploy "$d" --type=merge -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"node-role.jjinbbang.dev/core\":\"true\"}}}}}"
    sudo k3s kubectl -n cert-manager rollout status deploy/"$d" --timeout=300s
  done
'
```

## 8. Root Application 적용

이 repo 변경이 GitHub `main`에 push된 뒤 적용한다. push 전에는 Argo CD가
원격 repo에서 변경을 볼 수 없다.

초기 root Application은 잠금 방지를 위해 Argo CD OIDC/RBAC 전환 설정을
제외한다. Authentik Provider, `argocd-oidc-secret`, public DNS, TLS가 준비된
뒤 `platform/argocd/sso` overlay를 별도로 적용한다.

Root와 platform child Application은 `selfHeal=true`, `prune=false`로 둔다.
변경 drift는 자동 복구하지만, 삭제성 prune은 초기 랩 안정화 전에는 수동으로
다룬다.

Authentik은 k3s `HelmChart` CR로 부트스트랩했고, GitOps 전환 후에도 Argo CD가
동일한 `kube-system/authentik` HelmChart CR을 관리하게 한다. Argo CD가
Authentik Helm release를 직접 설치하는 구조가 아니므로 k3s helm-controller와
Argo CD가 같은 release를 이중 관리하지 않는다.

```bash
./scripts/apply-root-app.sh --check
./scripts/apply-root-app.sh
```

이 스크립트는 원격 GitHub `main`의 `platform/bootstrap/root-app.yaml`이 로컬
파일과 일치하는지 먼저 확인한다. push/merge 전에는 적용을 거부한다.

## 9. 상태 확인

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" '
  sudo k3s kubectl get applications.argoproj.io -A
  sudo k3s kubectl get ingress -A
  sudo k3s kubectl get certificates -A
  sudo k3s kubectl get clusterissuer letsencrypt-http01
'
```

Cloudflare 위임 직후 public resolver는 정상인데 cert-manager self-check가
`10.43.0.10` CoreDNS에서 NXDOMAIN을 볼 수 있다. 이 클러스터에서는 노드의
`/etc/resolv.conf` upstream이 오래된 DNS를 반환해서 발생했다.

```bash
./scripts/patch-coredns-public-forward.sh --check
./scripts/patch-coredns-public-forward.sh
DNS_SERVER=1.1.1.1 ./scripts/post-dns-readiness.sh
```

`patch-coredns-public-forward.sh`는 적용 전 core 노드 `/tmp`에 CoreDNS ConfigMap
백업을 남긴다. 되돌릴 때는 백업 경로를 넘긴다.

```bash
./scripts/patch-coredns-public-forward.sh --restore /tmp/coredns-before-YYYYMMDD-HHMMSS.yaml
```

DNS와 TLS가 모두 준비된 뒤에는 `./scripts/apply-argocd-sso.sh --check`를
먼저 통과시킨 다음 SSO overlay를 적용한다.

## 10. Authentik Secret 생성

Authentik은 runtime Secret에 DB 접속 환경 변수까지 함께 둔다.

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" '
  AUTHENTIK_SECRET_KEY="$(openssl rand -hex 64)"
  AUTHENTIK_POSTGRES_PASSWORD="$(openssl rand -base64 36)"
  sudo k3s kubectl -n authentik create secret generic authentik \
    --from-literal=AUTHENTIK_SECRET_KEY="$AUTHENTIK_SECRET_KEY" \
    --from-literal=AUTHENTIK_POSTGRESQL__HOST="authentik-postgresql" \
    --from-literal=AUTHENTIK_POSTGRESQL__NAME="authentik" \
    --from-literal=AUTHENTIK_POSTGRESQL__USER="authentik" \
    --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="$AUTHENTIK_POSTGRES_PASSWORD"
  sudo k3s kubectl -n authentik create secret generic authentik-postgresql \
    --from-literal=postgres-password="$AUTHENTIK_POSTGRES_PASSWORD" \
    --from-literal=password="$AUTHENTIK_POSTGRES_PASSWORD"
'
```

Secret을 보강한 뒤 이미 떠 있는 Authentik server/worker Pod가 예전 환경값을
들고 있으면 재기동한다.

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" '
  sudo k3s kubectl -n authentik rollout restart deployment/authentik-server deployment/authentik-worker
  sudo k3s kubectl -n authentik rollout status deployment/authentik-server --timeout=300s
  sudo k3s kubectl -n authentik rollout status deployment/authentik-worker --timeout=300s
'
```

## 11. n8n Secret 생성

n8n encryption key는 바뀌면 기존 credential 복호화가 깨진다. 생성 후 별도
비밀 저장소에 백업한다.

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" '
  N8N_ENCRYPTION_KEY="$(openssl rand -base64 32)"
  sudo k3s kubectl -n n8n create secret generic n8n-secrets \
    --from-literal=encryption-key="$N8N_ENCRYPTION_KEY"
'
```

## 12. Authentik Bootstrap Secret 생성

Secret 값은 화면에 출력하지 않고 core 노드의 임시 env-file로 만든다.

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" '
  set -euo pipefail
  tmpdir="$(mktemp -d)"
  trap "rm -rf \"$tmpdir\"" EXIT

  argocd_secret="$(openssl rand -base64 48)"
  cat >"$tmpdir/authentik-bootstrap.env" <<EOF
AUTHENTIK_BOOTSTRAP_EMAIL=<admin-email>
AUTHENTIK_BOOTSTRAP_PASSWORD=$(openssl rand -base64 36)
EOF

  cat >"$tmpdir/authentik-sso-bootstrap.env" <<EOF
ARGOCD_OIDC_CLIENT_SECRET=$argocd_secret
N8N_PROXY_CLIENT_SECRET=$(openssl rand -base64 48)
N8N_PROXY_COOKIE_SECRET=$(openssl rand -hex 32)
EOF

  cat >"$tmpdir/argocd-oidc.env" <<EOF
clientSecret=$argocd_secret
EOF

  sudo k3s kubectl -n authentik create secret generic authentik-bootstrap \
    --from-env-file="$tmpdir/authentik-bootstrap.env" \
    --dry-run=client -o yaml | sudo k3s kubectl apply -f -
  sudo k3s kubectl -n authentik create secret generic authentik-sso-bootstrap \
    --from-env-file="$tmpdir/authentik-sso-bootstrap.env" \
    --dry-run=client -o yaml | sudo k3s kubectl apply -f -
  sudo k3s kubectl -n argocd create secret generic argocd-oidc-secret \
    --from-env-file="$tmpdir/argocd-oidc.env" \
    --dry-run=client -o yaml | sudo k3s kubectl apply -f -
'
```

초기 admin 비밀번호는 필요할 때만 Secret에서 조회한다.

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" \
  'sudo k3s kubectl -n authentik get secret authentik-bootstrap -o jsonpath="{.data.AUTHENTIK_BOOTSTRAP_PASSWORD}" | base64 -d; echo'
```

## 13. 수동 live 적용 검증

GitHub push 전에는 Argo CD가 repo 변경을 볼 수 없으므로, bootstrap 검증용으로
로컬 manifest를 pipe해서 적용할 수 있다.

```bash
kubectl kustomize platform/authentik | \
  ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" \
    'sudo k3s kubectl apply -f -'

kubectl kustomize platform/workloads/n8n | \
  ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" \
    'sudo k3s kubectl apply -f -'
```

Bootstrap Job이 완료됐는지 확인한다.

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" \
  'sudo k3s kubectl -n authentik wait --for=condition=complete job/authentik-apply-blueprints --timeout=300s'
```

확인:

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" '
  sudo k3s kubectl -n authentik get pods -o wide
  sudo k3s kubectl -n n8n rollout status deployment/n8n --timeout=300s
  sudo k3s kubectl -n n8n get pods,svc,pvc,ingress -o wide
'
```

내부 health 확인:

```bash
ssh -i "$JJINBBANG_LAB_SSH_KEY" ubuntu@"$CORE_PUBLIC_IP" '
  sudo k3s kubectl -n authentik run curl-authentik --rm -i --restart=Never --image=curlimages/curl -- \
    sh -c "curl -sS -o /dev/null -w READY:%{http_code} http://authentik-server.authentik.svc.cluster.local/-/health/ready/; echo"
  sudo k3s kubectl -n n8n run curl-n8n --rm -i --restart=Never --image=curlimages/curl -- \
    sh -c "curl -sS -o /dev/null -w N8N:%{http_code} http://n8n.n8n.svc.cluster.local:5678/healthz; echo"
'
```
