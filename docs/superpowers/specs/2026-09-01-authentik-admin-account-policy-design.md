# Authentik 관리자 계정 정책 설계

## 목표

찐빵 관리자 페이지는 Authentik 계정 보유만으로 접근시키지 않고, 사람별 계정과
환경별 관리자 그룹을 통해 승인한다. 공용 계정은 일상 로그인에서 제외하고 비상
복구용으로만 유지한다.

## 설계

- 신규 사용자는 만료 시간이 있는 일회용 초대 링크로만 등록한다.
- 초대 등록은 일반 internal 사용자를 만들며 관리자 그룹을 자동 부여하지 않는다.
- 관리자는 사용자 신원과 MFA 등록을 확인한 뒤 필요한 그룹만 수동 부여한다.
- dev 접근은 `jjinbbang-backoffice-admins-dev`, prod 접근은
  `jjinbbang-backoffice-admins` 그룹으로 분리한다.
- `authentik Admins`는 Authentik 시스템 운영자에게만 부여한다.
- 공용 계정은 1Password `찐빵` Vault에 보관하고 비상 복구에만 사용한다.
- 초대 링크는 계정마다 하나씩 만들고 48시간 이내 만료, single-use를 기본으로 한다.

## 범위

- Authentik bootstrap에 초대 전용 enrollment flow를 선언한다.
- application의 기존 그룹 binding과 백엔드 그룹 검사는 유지한다.
- 실제 사용자 초대는 대상 이메일을 받은 뒤 운영자가 별도로 생성한다.
- SMTP 자동 발송, 자동 관리자 승인, 장기 다중 사용 초대 링크는 만들지 않는다.

## 검증

- 초대 토큰이 없는 enrollment 접근은 거부된다.
- enrollment flow는 어떤 관리자 그룹도 자동 부여하지 않는다.
- dev/prod application은 각각의 관리자 그룹에만 연결된다.
- blueprint 적용 후 flow와 stage가 live Authentik에 존재한다.
