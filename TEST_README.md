# 🚀 Parallel Compaction 테스트 스크립트 사용법

## 📋 개요

이 스크립트는 RocksDB의 `subcompactions` 설정이 컴팩션 성능에 미치는 영향을 체계적으로 분석하기 위한 자동화 도구입니다.

## 🛠 준비사항

### 1. RocksDB 빌드
```bash
# RocksDB 컴파일 (아직 안 했다면)
make static_lib
make db_bench

# 또는 Release 모드로 빌드
make -j$(nproc) release
```

### 2. 시스템 요구사항
- **CPU**: 4코어 이상 (16코어 권장)
- **메모리**: 8GB 이상 (32GB 권장)  
- **저장공간**: 20GB 이상 여유공간
- **OS**: Linux (Ubuntu 18.04+, CentOS 7+)

### 3. 필수 도구 설치
```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install sysstat python3 python3-pip

# CentOS/RHEL  
sudo yum install sysstat python3 python3-pip

# Python 패키지 (선택사항 - 그래프 생성용)
pip3 install pandas matplotlib numpy
```

## 🚀 실행 방법

### 기본 실행
```bash
# 기본 설정으로 실행
./parallel_compaction_test.sh

# 도움말 확인
./parallel_compaction_test.sh --help
```

### 고급 옵션
```bash
# db_bench 경로 지정
./parallel_compaction_test.sh -d /path/to/db_bench

# 결과 저장 위치 지정
./parallel_compaction_test.sh -o ./my_results

# 키 개수 조정 (빠른 테스트)
./parallel_compaction_test.sh -n 10000000

# 특정 subcompaction 값만 테스트
./parallel_compaction_test.sh -s "1,4,8,16"

# 환경변수로 RocksDB 경로 지정
ROCKSDB_PATH=/opt/rocksdb ./parallel_compaction_test.sh
```

## ⚙️ 설정 커스터마이징

`test_config.conf` 파일을 수정하여 실험 파라미터를 조정할 수 있습니다:

```bash
# 빠른 테스트 (약 30분)
NUM_KEYS=10000000
SUBCOMPACTION_VALUES="1 4 8 16"

# 표준 테스트 (약 2-3시간)  
NUM_KEYS=50000000
SUBCOMPACTION_VALUES="1 2 4 8 12 16 24 32"

# 심화 분석 (약 4-6시간)
NUM_KEYS=100000000
SUBCOMPACTION_VALUES="1 2 3 4 6 8 10 12 16 20 24 28 32"
```

## 📊 실험 단계

### Phase 1: 환경 준비
- 시스템 정보 수집
- 결과 디렉토리 생성
- db_bench 실행파일 확인

### Phase 2: 성능 테스트
각 subcompaction 설정에 대해:
- 데이터 생성 (`fillrandom`)
- 컴팩션 실행 (`compact`)
- 시스템 리소스 모니터링

### Phase 3: 읽기 성능 분석
- 최적 설정들에서 읽기 성능 측정
- 컴팩션이 읽기에 미치는 영향 분석

### Phase 4: 결과 분석
- CSV 데이터 생성
- 요약 리포트 작성
- 그래프 생성 (Python 사용 가능 시)

## 📈 결과 파일 구조

```
results_YYYYMMDD_HHMMSS/
├── experiment_summary.md          # 실험 요약
├── compaction_results.csv         # 주요 지표 CSV
├── analysis_output.txt            # Python 분석 결과
├── performance_analysis.png       # 성능 그래프
├── system_info.txt               # 시스템 정보
├── logs/                         # 상세 로그들
│   ├── iostat_sub_*.log         # I/O 통계
│   ├── vmstat_sub_*.log         # CPU/메모리 통계
│   ├── sar_sub_*.log            # 시스템 통계
│   └── db_bench_*.log           # db_bench 로그
└── results_sub_*.txt            # 각 설정별 상세 결과
```

## 🔍 결과 해석

### CSV 데이터 컬럼 설명
- `Subcompactions`: 테스트된 subcompaction 수
- `Throughput_MBps`: 컴팩션 처리량 (MB/초)
- `CPU_Usage_Percent`: 평균 CPU 사용률
- `Memory_GB`: 평균 메모리 사용량 (GB)
- `Compaction_Time_Sec`: 컴팩션 완료 시간 (초)
- `IO_Read_MBps`: 평균 읽기 I/O (MB/초)
- `IO_Write_MBps`: 평균 쓰기 I/O (MB/초)

### 최적 설정 찾기
1. **최고 성능**: 가장 높은 `Throughput_MBps`
2. **효율성**: `Throughput_MBps / Memory_GB` 비율이 높은 설정
3. **비용 효율**: CPU와 메모리 사용량 대비 성능이 좋은 설정

## 🛠 문제 해결

### 자주 발생하는 문제

#### 1. db_bench를 찾을 수 없음
```bash
# 해결방법 1: 경로 지정
./parallel_compaction_test.sh -d /path/to/your/db_bench

# 해결방법 2: 환경변수 설정
export ROCKSDB_PATH=/path/to/rocksdb
./parallel_compaction_test.sh

# 해결방법 3: RocksDB 빌드
make db_bench
```

#### 2. 권한 부족
```bash
# 스크립트 실행 권한 부여
chmod +x parallel_compaction_test.sh

# /tmp 디렉토리 권한 확인
sudo chmod 755 /tmp
```

#### 3. 메모리 부족
```bash
# 키 개수 줄이기
./parallel_compaction_test.sh -n 10000000

# 또는 설정 파일 수정
NUM_KEYS=5000000  # test_config.conf에서
```

#### 4. 디스크 공간 부족
```bash
# 여유 공간 확인
df -h

# 임시 파일 정리
rm -rf /tmp/rocksdb_*

# 다른 위치 사용
BASE_DIR="/path/to/large/disk/rocksdb_test"
```

### 모니터링 프로세스 문제
```bash
# 남은 모니터링 프로세스 정리
pkill -f "iostat.*sub_"
pkill -f "vmstat.*sub_"
pkill -f "sar.*sub_"
```

## 📝 팁과 권장사항

### 1. 실험 환경 최적화
```bash
# 다른 무거운 프로세스 종료
# 시스템 업데이트나 백그라운드 작업 중지
# 가능하면 전용 테스트 서버 사용
```

### 2. 결과 신뢰성 향상
```bash
# 여러 번 실행하여 평균 내기
for i in {1..3}; do
    ./parallel_compaction_test.sh -o results_run_$i
done

# 시스템 재부팅 후 실행 (캐시 효과 제거)
```

### 3. 사용자 정의 분석
```bash
# CSV 데이터를 Excel이나 다른 도구로 분석
# 추가 그래프 생성
# 특정 워크로드에 맞는 설정 찾기
```

## 📞 지원

문제가 발생하거나 추가 기능이 필요한 경우:
1. 실험 로그 파일 확인 (`results_*/logs/`)
2. 시스템 요구사항 재확인
3. RocksDB 빌드 상태 점검

## 🔗 관련 자료

- [RocksDB 공식 문서](https://rocksdb.org/)
- [db_bench 사용법](https://github.com/facebook/rocksdb/wiki/Benchmarking-tools)
- [RocksDB 튜닝 가이드](https://rocksdb.org/docs/tuning-guide.html) 