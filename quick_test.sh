#!/bin/bash

# 🚀 빠른 Parallel Compaction 테스트 (약 20-30분 소요)
# 주요 subcompaction 값들만 테스트하여 빠른 결과 확인

set -e

# 기본 설정
ROCKSDB_PATH="${ROCKSDB_PATH:-./}"
DB_BENCH="${ROCKSDB_PATH}/db_bench"
RESULTS_DIR="./quick_results_$(date +%Y%m%d_%H%M%S)"

# 빠른 테스트용 설정
SUBCOMPACTION_VALUES=(1 4 8 16)  # 핵심 값들만
NUM_KEYS=10000000                # 1천만 키 (약 1GB)
VALUE_SIZE=100
MAX_BACKGROUND_JOBS=8

# 색상
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%H:%M:%S') - $1"
}

log_phase() {
    echo -e "${BLUE}[PHASE]${NC} $1"
}

# 환경 확인
if [ ! -f "${DB_BENCH}" ]; then
    echo "❌ db_bench를 찾을 수 없습니다: ${DB_BENCH}"
    echo "RocksDB를 빌드하거나 ROCKSDB_PATH를 설정하세요:"
    echo "  make db_bench"
    echo "  또는 ROCKSDB_PATH=/path/to/rocksdb $0"
    exit 1
fi

# 결과 디렉토리 생성
mkdir -p "${RESULTS_DIR}"

log_phase "🚀 빠른 Parallel Compaction 테스트 시작"
echo "테스트 설정:"
echo "  - Subcompaction 값: ${SUBCOMPACTION_VALUES[*]}"
echo "  - 키 개수: ${NUM_KEYS}"
echo "  - 예상 소요시간: 20-30분"
echo "  - 결과 저장: ${RESULTS_DIR}"
echo ""

# CSV 헤더 생성
echo "Subcompactions,Throughput_MBps,Time_Sec,CPU_Avg,Memory_Peak" > "${RESULTS_DIR}/quick_results.csv"

for sub_value in "${SUBCOMPACTION_VALUES[@]}"; do
    log_info "=== Subcompactions=${sub_value} 테스트 ==="
    
    test_db_dir="/tmp/quick_rocksdb_sub_${sub_value}"
    rm -rf "${test_db_dir}"
    
    start_time=$(date +%s)
    
    # 리소스 모니터링 시작
    vmstat 1 > "${RESULTS_DIR}/vmstat_${sub_value}.log" &
    vmstat_pid=$!
    
    # db_bench 실행
    log_info "db_bench 실행 중..."
    if ${DB_BENCH} \
        --benchmarks=fillrandom,compact \
        --db="${test_db_dir}" \
        --num=${NUM_KEYS} \
        --value_size=${VALUE_SIZE} \
        --subcompactions=${sub_value} \
        --max_background_jobs=${MAX_BACKGROUND_JOBS} \
        --compression_type=snappy \
        --statistics \
        > "${RESULTS_DIR}/output_${sub_value}.txt" 2>&1; then
        
        end_time=$(date +%s)
        total_time=$((end_time - start_time))
        
        # 모니터링 중지
        kill $vmstat_pid 2>/dev/null || true
        wait $vmstat_pid 2>/dev/null || true
        
        # 결과 파싱
        throughput=$(grep -E "compact.*MB/s" "${RESULTS_DIR}/output_${sub_value}.txt" | tail -1 | awk '{print $NF}' | sed 's/MB\/s//' || echo "0")
        cpu_avg=$(tail -5 "${RESULTS_DIR}/vmstat_${sub_value}.log" | grep -v "procs\|r" | awk '{sum+=$(NF-2)} END {if(NR>0) print sum/NR; else print "0"}' || echo "0")
        memory_peak=$(tail -10 "${RESULTS_DIR}/vmstat_${sub_value}.log" | grep -v "procs\|r" | awk '{max = $4 > max ? $4 : max} END {print max/1024/1024}' || echo "0")
        
        # CSV에 결과 추가
        echo "${sub_value},${throughput},${total_time},${cpu_avg},${memory_peak}" >> "${RESULTS_DIR}/quick_results.csv"
        
        log_info "완료 - 처리량: ${throughput} MB/s, 시간: ${total_time}초"
    else
        log_info "❌ 테스트 실패"
        kill $vmstat_pid 2>/dev/null || true
    fi
    
    # 정리
    rm -rf "${test_db_dir}" 2>/dev/null || true
done

# 간단한 결과 요약
log_phase "📊 테스트 결과 요약"
echo ""
echo "상세 결과: ${RESULTS_DIR}/quick_results.csv"
echo ""
echo "Subcompactions | Throughput (MB/s) | Time (sec) | CPU (%) | Memory (GB)"
echo "---------------|-------------------|------------|---------|------------"

tail -n +2 "${RESULTS_DIR}/quick_results.csv" | while IFS=',' read -r sub throughput time cpu memory; do
    printf "%-14s | %-17s | %-10s | %-7s | %-10s\n" "$sub" "$throughput" "$time" "$cpu" "$memory"
done

# 최적 설정 추천
best_line=$(tail -n +2 "${RESULTS_DIR}/quick_results.csv" | sort -t',' -k2 -nr | head -1)
best_sub=$(echo "$best_line" | cut -d',' -f1)
best_throughput=$(echo "$best_line" | cut -d',' -f2)

echo ""
log_info "🏆 최고 성능: Subcompactions=${best_sub} (${best_throughput} MB/s)"

# 효율성 계산 (처리량/메모리)
echo ""
echo "효율성 순위 (처리량/메모리 사용량):"
tail -n +2 "${RESULTS_DIR}/quick_results.csv" | awk -F',' '{print $1","$2/$5","$2","$5}' | sort -t',' -k2 -nr | head -3 | while IFS=',' read -r sub efficiency throughput memory; do
    printf "  %s: %.2f MB/s per GB (처리량: %s MB/s, 메모리: %s GB)\n" "$sub" "$efficiency" "$throughput" "$memory"
done

echo ""
log_info "✅ 빠른 테스트 완료! 상세 분석을 원하면 full 테스트를 실행하세요:"
echo "  ./parallel_compaction_test.sh"

# 정리
rm -f "${RESULTS_DIR}/vmstat_*.log" 2>/dev/null || true 