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
- 일반 app은 dev Argo CD auto sync, prod 수동 승인 sync를 기본값으로 둔다.
- 관리자 API는 server `main` 반영을 승인 경계로 삼고, 검증된 dispatch 이후
  prod Argo CD auto sync를 사용한다.
- secret 원문은 넣지 않고 SealedSecret 또는 live Secret 계약으로 분리한다.

Current app scaffold:

- `base` defines the shared Spring Boot Deployment, Service, Ingress, and non-secret ConfigMap.
- `dev` targets namespace `jjinbbang-dev`, host `api-dev.jjinbbang.kr`, and one replica.
- `prod` targets namespace `jjinbbang-prod`, host `api.jjinbbang.kr`, two replicas, and a PodDisruptionBudget.
- Both overlays expect a live Secret named `jjinbbang-api-secrets` in the target namespace.
- API pods avoid the control-plane node by excluding `node-role.jjinbbang.dev/core`.
- Optional Argo CD Applications live under `platform/applications/apps` and are not referenced by `platform/kustomization.yaml` yet.

Admin API:

- `apps/jjinbbang-admin/base`는 관리자 Spring 서버 공통 리소스를 정의한다.
- `apps/jjinbbang-admin/overlays/dev`는 `jjinbbang-admin-dev` namespace와
  `dev.admin.jjinbbang.kr`을 사용한다.
- `apps/jjinbbang-admin/overlays/prod`는 `jjinbbang-admin` namespace와
  `admin.jjinbbang.kr`을 사용한다.
- 관리자 프론트엔드 Deployment와 루트 경로는 프론트 담당 범위이므로 포함하지 않는다.
- 각 환경의 서버 replica는 해당 환경의 MySQL-backed Spring Session을 사용한다.
- dev와 prod는 Authentik client/redirect URI, Secret, DB/schema를 분리한다.
- `platform/applications/apps/jjinbbang-admin-dev.yaml`과
  `platform/applications/apps/jjinbbang-admin.yaml`이 각각의 overlay를 가리킨다.
- repository dispatch payload의 `environment`가 `dev` 또는 `prod`일 때 해당
  overlay의 GHCR digest만 갱신하며, Argo CD는 prune 없이 동기화한다.
