# PVE Toolbox

Proxmox VE API를 통해 Proxmox VE 클러스터의 모든 노드를 조회하는 작은 Bash 유틸리티입니다.

## 요구사항

- `bash`
- `curl`
- `jq`
- `util-linux`의 `column`

## 설정

샘플 환경 변수 파일을 복사한 뒤 클러스터 인증 정보를 입력합니다.

```bash
cp .env.sample .env
chmod 600 .env
```

`.env`를 수정합니다.

```bash
PVE_ENDPOINT="https://pve.example.com:8006"
PVE_USER_ID="root@pam"
PVE_PASSWORD="your-password"
PVE_INSECURE="true"
```

`.env`에는 민감한 엔드포인트와 인증 정보가 들어 있으므로 Git에서 무시됩니다.

## 사용법

클러스터 노드를 조회합니다.

```bash
./list-nodes.sh
```

원본 노드 JSON 배열을 출력합니다.

```bash
./list-nodes.sh --json
```

다른 환경 변수 파일을 사용합니다.

```bash
./list-nodes.sh --env-file ./prod.env
```

## 출력

기본 표에는 다음 항목이 포함됩니다.

- `NODE`
- `STATUS`
- `UPTIME_SECONDS`
- `CPU_USAGE`
- `MEM_USAGE`

`CPU_USAGE`와 `MEM_USAGE`는 현재 API 응답에서 반환된 백분율 값입니다.
