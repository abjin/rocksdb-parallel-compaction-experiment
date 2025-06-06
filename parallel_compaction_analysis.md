# 🚀 **Parallel Compaction 최적화: Subcompaction의 스케일링 효과 분석**

## 1. 실험 동기 및 목표

### **실험 동기**
- **멀티코어 시대의 성능 병목**: 현대 서버는 16-64코어가 일반적이지만, 기존 RocksDB 컴팩션은 단일 스레드 기반으로 CPU 자원을 충분히 활용하지 못함
- **클라우드 환경의 비용 최적화**: AWS/GCP 등에서 vCPU 비용을 지불하면서도 실제 활용률이 낮은 문제
- **대용량 데이터 처리**: 테라바이트급 데이터에서 컴팩션이 전체 시스템 성능의 주요 병목이 되는 현실

### **실험 목표**
1. **스케일링 효과 정량화**: Subcompaction 수에 따른 처리량 개선 효과 측정
2. **최적 설정값 도출**: 하드웨어 스펙별 최적 subcompaction 수 결정
3. **자원 활용도 분석**: CPU, 메모리, I/O 자원의 효율적 활용 방안 제시
4. **실무 가이드라인**: 프로덕션 환경 적용을 위한 구체적 설정 권장사항 도출

---

## 2. 실험 가설

### **주요 가설**
**H1**: Subcompaction 수가 증가할수록 컴팩션 처리량이 선형적으로 향상될 것이다.

**H2**: 최적 subcompaction 수는 물리적 CPU 코어 수와 강한 양의 상관관계를 가질 것이다.

**H3**: 병렬 컴팩션은 I/O 대역폭이 충분한 환경에서 더 큰 성능 향상을 보일 것이다.

**H4**: 과도한 병렬화는 메모리 사용량 증가와 컨텍스트 스위칭 오버헤드로 인해 성능 저하를 초래할 것이다.

### **세부 예측**
- 4코어 시스템: subcompaction 2-4개에서 최적점
- 16코어 시스템: subcompaction 8-12개에서 최적점  
- 메모리 사용량: subcompaction 수에 비례하여 증가
- CPU 활용률: 병렬도 증가에 따라 향상되다가 특정 지점에서 수렴

---

## 3. 실험 설계

### **실험 환경**
```bash
# 하드웨어 구성
- CPU: Intel Xeon 16-core (32 threads)
- Memory: 64GB RAM
- Storage: NVMe SSD 2TB
- OS: Ubuntu 22.04 LTS
```

### **실험 변수**
**독립변수**: 

- `--subcompactions`: 1, 2, 4, 8, 12, 16, 24, 32
- `--max_background_jobs`: 4, 8, 16, 24

**종속변수**:
- 컴팩션 처리량 (MB/s)
- CPU 사용률 (%)
- 메모리 사용량 (GB)
- 컴팩션 완료 시간 (초)
- I/O 대역폭 활용률 (MB/s)

### **실험 단계**

#### Phase 1: 기본 데이터 준비
```bash
# 10GB 데이터 생성 (컴팩션 트리거를 위한 충분한 크기)
./db_bench --benchmarks=fillrandom \
    --num=100000000 \
    --value_size=100 \
    --write_buffer_size=64MB \
    --max_write_buffer_number=8 \
    --target_file_size_base=64MB \
    --statistics
```

#### Phase 2: Subcompaction 변수별 실험
```bash
# 각 subcompaction 설정별 실험
for sub in 1 2 4 8 12 16 24 32; do
    echo "Testing subcompactions=$sub"
    
    # 데이터 재생성 (일관된 초기 상태)
    rm -rf /tmp/rocksdb_test_$sub
    
    # 컴팩션 성능 측정
    ./db_bench --benchmarks=fillrandom,compact \
        --db=/tmp/rocksdb_test_$sub \
        --num=50000000 \
        --subcompactions=$sub \
        --max_background_jobs=16 \
        --statistics \
        --histogram \
        --report_interval_seconds=10 > results_sub_$sub.txt
done
```

#### Phase 3: 시스템 리소스 모니터링
```bash
# 실험 중 시스템 메트릭 수집
nohup iostat -x 1 > iostat_sub_$sub.log &
nohup vmstat 1 > vmstat_sub_$sub.log &
nohup top -b -d1 -p $(pidof db_bench) > cpu_sub_$sub.log &
```

#### Phase 4: 워크로드별 검증
```bash
# 읽기 성능에 미치는 영향 분석
./db_bench --benchmarks=readrandom \
    --db=/tmp/rocksdb_test_optimal \
    --num=10000000 \
    --threads=16 \
    --statistics
```

### **통제 변수**
- 데이터 크기: 5GB (일관된 워크로드)
- 키 크기: 16 bytes
- 값 크기: 100 bytes  
- 압축: Snappy (동일한 조건)
- 캐시 크기: 1GB (고정)

---

## 4. 실험 결과 (예상)

### **컴팩션 처리량 결과**
```markdown
Subcompactions | Throughput(MB/s) | CPU Usage(%) | Memory(GB) | Time(sec)
1             | 85.2            | 18.5        | 2.1       | 642
2             | 156.8           | 34.2        | 2.8       | 349
4             | 287.4           | 62.1        | 4.2       | 190
8             | 445.6           | 78.9        | 6.8       | 123
12            | 512.3           | 84.7        | 9.1       | 107
16            | 518.7           | 87.2        | 11.5      | 105
24            | 503.1           | 89.8        | 15.2      | 109
32            | 478.9           | 91.4        | 18.9      | 114
```

### **시스템 자원 활용도**
```markdown
Configuration | I/O Read(MB/s) | I/O Write(MB/s) | Context Switches/s | Memory Bandwidth
Sub=1        | 245.3         | 85.2           | 1,245            | 2.1 GB/s
Sub=8        | 1,892.4       | 445.6          | 8,967            | 6.8 GB/s  
Sub=16       | 2,156.8       | 518.7          | 15,432           | 11.5 GB/s
Sub=32       | 2,089.3       | 478.9          | 28,754           | 18.9 GB/s
```

### **최적화 지점 분석**
- **Peak Performance**: Subcompaction=16에서 최고 처리량 달성
- **Cost-Efficiency**: Subcompaction=8에서 성능 대비 자원 효율성 최적
- **Memory Threshold**: Subcompaction>20에서 메모리 사용량 급격히 증가

---

## 5. 실험 결과 해석 (예상)

### **핵심 발견사항**

#### **1. 성능 스케일링 패턴**
- **선형 구간 (1-8)**: Subcompaction 증가에 따라 거의 선형적 성능 향상
- **수렴 구간 (8-16)**: 성능 향상률이 점진적으로 감소하며 최적점 도달
- **포화 구간 (16+)**: 과도한 병렬화로 인한 오버헤드로 성능 저하 시작

#### **2. 하드웨어 상관관계**
```
최적 Subcompaction 수 ≈ Physical CPU Cores × 0.75
```
- 16코어 시스템에서 12-16개 subcompaction이 최적
- 하이퍼스레딩 고려 시 논리 코어 수의 50% 수준

#### **3. 메모리 사용 패턴**
- **Base Memory**: 2.1GB (single compaction)
- **Scaling Factor**: 약 0.6GB per additional subcompaction
- **Critical Point**: 16GB 메모리 시스템에서 subcompaction=20이 한계점

### **실무적 인사이트**

#### **최적화 가이드라인**
1. **4-8코어 시스템**: `--subcompactions=4 --max_background_jobs=8`
2. **16코어+ 시스템**: `--subcompactions=12 --max_background_jobs=16`  
3. **메모리 제약 환경**: 가용 메모리의 30% 이하로 subcompaction 조절

#### **성능 vs 비용 트레이드오프**
- **High Performance**: Subcompaction=16 (최대 518.7 MB/s, 메모리 11.5GB)
- **Balanced**: Subcompaction=8 (445.6 MB/s, 메모리 6.8GB) ← **권장**
- **Resource Constrained**: Subcompaction=4 (287.4 MB/s, 메모리 4.2GB)

#### **예외 상황 분석**
- **SSD 대역폭 포화**: NVMe 대역폭(3GB/s) 근접 시 성능 수렴
- **메모리 스와핑**: 물리 메모리 부족 시 급격한 성능 저하
- **네트워크 복제**: 분산 환경에서는 네트워크 대역폭이 추가 병목

### **실무 권장사항**

#### **프로덕션 환경 설정**
```bash
# 일반적인 프로덕션 서버 (16코어, 32GB RAM)
--subcompactions=12
--max_background_jobs=16
--max_subcompactions=12

# 메모리 제약 환경 (8GB RAM)  
--subcompactions=4
--max_background_jobs=8
--max_subcompactions=4
```

#### **모니터링 포인트**
1. **CPU 사용률**: 85% 이하 유지 (컨텍스트 스위칭 오버헤드 방지)
2. **메모리 사용률**: 물리 메모리의 80% 이하 
3. **I/O 대기시간**: SSD IOPS 한계 도달 여부 확인

### **한계점 및 향후 연구 방향**

#### **실험의 한계**
- 단일 하드웨어 구성에서의 테스트 (다양한 CPU 아키텍처 미반영)
- 합성 워크로드 중심 (실제 애플리케이션 패턴과 차이 가능)
- 단기간 실험 (장기 운영 시 성능 특성 변화 미고려)

#### **향후 연구 과제**
1. **클라우드 환경**: AWS/GCP 인스턴스별 최적화 가이드라인
2. **이기종 워크로드**: OLTP/OLAP 혼합 환경에서의 적응적 설정
3. **자동 튜닝**: 런타임 메트릭 기반 동적 subcompaction 조절 알고리즘

---

## 결론

이 실험을 통해 **멀티코어 시대의 RocksDB 성능 최적화**에 대한 과학적 근거를 제시하고, 실무진이 바로 적용할 수 있는 **구체적인 설정 가이드라인**을 도출할 수 있습니다.

핵심 발견사항:
1. **최적 병렬도**: 물리 CPU 코어 수의 75% 수준에서 최적 성능
2. **비용 효율성**: 과도한 병렬화는 메모리 비용 증가 대비 성능 이득 미미
3. **실무 적용**: 하드웨어와 워크로드 특성을 고려한 단계적 튜닝 필요

이러한 인사이트는 **프로덕션 환경에서 RocksDB의 컴팩션 성능을 최적화**하는 데 직접적으로 활용될 수 있으며, 특히 **클라우드 환경에서의 비용 효율적인 성능 튜닝**에 중요한 가이드라인을 제공합니다. 