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

모든 노드의 system journal 로그를 가져옵니다.

```bash
./fetch-system-logs.sh
```

시간 범위를 지정하지 않으면 기본으로 1시간 전부터 현재 시각까지 가져옵니다.

시간 범위로 가져올 수도 있습니다.

```bash
./fetch-system-logs.sh --since "1 hour ago" --until "now"
./fetch-system-logs.sh --since "2026-07-03 10:00:00" --until "2026-07-03 11:00:00"
```

원본 journal API JSON을 파일로 남기려면 `--json`을 사용합니다.

```bash
./fetch-system-logs.sh --since "today 00:00" --until "now" --json
```

`--since`와 `--until`은 epoch 초 또는 GNU `date -d`가 해석할 수 있는 문자열을 받습니다. 스크립트가 Proxmox VE journal API에 맞게 epoch 초로 변환해서 요청합니다.

특정 노드의 RRD 데이터를 조회합니다.

```bash
./fetch-node-rrddata.sh pve1
./fetch-node-rrddata.sh --node pve1 --timeframe day
./fetch-node-rrddata.sh --node pve1 --timeframe week --cf MAX --json
```

`--timeframe`은 기본값이 `hour`이며 일반적으로 `hour`, `day`, `week`, `month`, `year`를 사용할 수 있습니다. `--cf`는 기본값이 `AVERAGE`이며 `MAX`도 사용할 수 있습니다.

## 출력

기본 표에는 다음 항목이 포함됩니다.

- `NODE`
- `STATUS`
- `UPTIME_SECONDS`
- `CPU_USAGE`
- `MEM_USAGE`

`CPU_USAGE`와 `MEM_USAGE`는 현재 API 응답에서 반환된 백분율 값입니다.
