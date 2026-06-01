# Apps

찐빵 서비스 애플리케이션 manifest를 두는 영역이다.

초기 platform bootstrap과 SSO 구성이 끝난 뒤 아래 구조로 추가한다.

```text
apps/jjinbbang-api/base
apps/jjinbbang-api/overlays/dev
apps/jjinbbang-api/overlays/prod
platform/applications/apps
```

원칙:

- app repo는 image를 빌드해 GHCR에 push한다.
- 이 repo는 image tag와 Kubernetes desired state만 기록한다.
- dev는 Argo CD auto sync, prod는 수동 승인 sync를 기본값으로 둔다.
- secret 원문은 넣지 않고 SealedSecret 또는 live Secret 계약으로 분리한다.

Current app scaffold:

- `base` defines the shared Spring Boot Deployment, Service, Ingress, and non-secret ConfigMap.
- `dev` targets namespace `jjinbbang-dev`, host `api-dev.jjinbbang.kr`, and one replica.
- `prod` targets namespace `jjinbbang-prod`, host `api.jjinbbang.kr`, two replicas, and a PodDisruptionBudget.
- Both overlays expect a live Secret named `jjinbbang-api-secrets` in the target namespace.
- API pods avoid the control-plane node by excluding `node-role.jjinbbang.dev/core`.
- Optional Argo CD Applications live under `platform/applications/apps` and are not referenced by `platform/kustomization.yaml` yet.
