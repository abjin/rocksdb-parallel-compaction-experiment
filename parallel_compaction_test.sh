#!/bin/bash

# 🚀 Parallel Compaction 최적화: Subcompaction 스케일링 효과 분석 테스트 스크립트
# 작성일: $(date +%Y-%m-%d)
# 목적: RocksDB subcompaction 설정별 성능 분석 자동화

set -e  # 에러 발생 시 스크립트 중단

# ========================================
# 설정 변수
# ========================================

# 실험 설정
ROCKSDB_PATH="${ROCKSDB_PATH:-./}"
DB_BENCH="${ROCKSDB_PATH}/db_bench"
BASE_DIR="/tmp/rocksdb_subcompaction_test"
RESULTS_DIR="./results_$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${RESULTS_DIR}/logs"

# Subcompaction 테스트 값들
SUBCOMPACTION_VALUES=(1 2 4 8 12 16 24 32)
MAX_BACKGROUND_JOBS=16

# 데이터 설정
NUM_KEYS=50000000           # 5천만 키 (약 5GB)
VALUE_SIZE=100
KEY_SIZE=16
WRITE_BUFFER_SIZE="64MB"
MAX_WRITE_BUFFER_NUMBER=8
TARGET_FILE_SIZE_BASE="64MB"

# 모니터링 설정
MONITOR_INTERVAL=1
REPORT_INTERVAL=10

# 색상 코드
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ========================================
# 유틸리티 함수
# ========================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_phase() {
    echo -e "${BLUE}[PHASE]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# 시스템 정보 수집
collect_system_info() {
    log_info "시스템 정보 수집 중..."
    
    cat > "${RESULTS_DIR}/system_info.txt" << EOF
=== 시스템 정보 ===
실험 시작 시간: $(date)
운영체제: $(uname -a)
CPU 정보: $(cat /proc/cpuinfo | grep "model name" | head -1 | cut -d: -f2 | xargs)
CPU 코어 수: $(nproc)
메모리 정보: $(free -h | grep Mem)
디스크 정보: $(df -h | grep -E "/$|/tmp")

=== RocksDB 설정 ===
DB_BENCH 경로: ${DB_BENCH}
기본 디렉토리: ${BASE_DIR}
키 개수: ${NUM_KEYS}
값 크기: ${VALUE_SIZE} bytes
키 크기: ${KEY_SIZE} bytes
Write Buffer 크기: ${WRITE_BUFFER_SIZE}
Max Background Jobs: ${MAX_BACKGROUND_JOBS}
EOF
}

# 프로세스 정리 함수
cleanup_monitors() {
    log_info "모니터링 프로세스 정리 중..."
    pkill -f "iostat.*sub_" 2>/dev/null || true
    pkill -f "vmstat.*sub_" 2>/dev/null || true
    pkill -f "top.*db_bench" 2>/dev/null || true
    sleep 2
}

# 시스템 리소스 모니터링 시작
start_monitoring() {
    local sub_value=$1
    local monitor_suffix="sub_${sub_value}"
    
    log_info "리소스 모니터링 시작 (subcompactions=${sub_value})"
    
    # I/O 모니터링
    nohup iostat -x ${MONITOR_INTERVAL} > "${LOG_DIR}/iostat_${monitor_suffix}.log" 2>&1 &
    
    # 메모리 및 CPU 모니터링  
    nohup vmstat ${MONITOR_INTERVAL} > "${LOG_DIR}/vmstat_${monitor_suffix}.log" 2>&1 &
    
    # 시스템 전체 모니터링
    nohup sar -u -r ${MONITOR_INTERVAL} > "${LOG_DIR}/sar_${monitor_suffix}.log" 2>&1 &
    
    sleep 2  # 모니터링 프로세스 시작 대기
}

# 모니터링 중지
stop_monitoring() {
    log_info "리소스 모니터링 중지"
    cleanup_monitors
}

# DB 벤치 프로세스 모니터링
monitor_db_bench() {
    local sub_value=$1
    local db_bench_pid=$2
    local monitor_suffix="sub_${sub_value}"
    
    if [ ! -z "$db_bench_pid" ]; then
        # db_bench 프로세스 전용 모니터링
        nohup top -b -d${MONITOR_INTERVAL} -p ${db_bench_pid} > "${LOG_DIR}/db_bench_top_${monitor_suffix}.log" 2>&1 &
        
        # 메모리 사용량 세부 모니터링
        while kill -0 $db_bench_pid 2>/dev/null; do
            echo "$(date '+%Y-%m-%d %H:%M:%S'),$(ps -p $db_bench_pid -o pid,ppid,%cpu,%mem,vsz,rss --no-headers)" >> "${LOG_DIR}/db_bench_memory_${monitor_suffix}.csv"
            sleep ${MONITOR_INTERVAL}
        done &
    fi
}

# ========================================
# 실험 단계별 함수
# ========================================

# Phase 1: 환경 준비
phase1_setup() {
    log_phase "Phase 1: 환경 준비 및 초기 설정"
    
    # 결과 디렉토리 생성
    mkdir -p "${RESULTS_DIR}" "${LOG_DIR}" "${BASE_DIR}"
    
    # db_bench 존재 확인
    if [ ! -f "${DB_BENCH}" ]; then
        log_error "db_bench를 찾을 수 없습니다: ${DB_BENCH}"
        log_info "RocksDB를 빌드하거나 ROCKSDB_PATH 환경변수를 설정하세요"
        exit 1
    fi
    
    # 권한 확인
    if [ ! -x "${DB_BENCH}" ]; then
        log_error "db_bench 실행 권한이 없습니다: ${DB_BENCH}"
        exit 1
    fi
    
    # 시스템 정보 수집
    collect_system_info
    
    # CSV 결과 파일 헤더 생성
    cat > "${RESULTS_DIR}/compaction_results.csv" << EOF
Subcompactions,Throughput_MBps,CPU_Usage_Percent,Memory_GB,Compaction_Time_Sec,IO_Read_MBps,IO_Write_MBps,Context_Switches_Per_Sec
EOF
    
    log_info "환경 준비 완료"
}

# Phase 2: Subcompaction별 성능 테스트
phase2_performance_test() {
    log_phase "Phase 2: Subcompaction별 성능 테스트 시작"
    
    for sub_value in "${SUBCOMPACTION_VALUES[@]}"; do
        log_info "=== Subcompactions=${sub_value} 테스트 시작 ==="
        
        local test_db_dir="${BASE_DIR}/rocksdb_test_sub_${sub_value}"
        local result_file="${RESULTS_DIR}/results_sub_${sub_value}.txt"
        
        # 이전 테스트 데이터 정리
        rm -rf "${test_db_dir}"
        mkdir -p "${test_db_dir}"
        
        # 리소스 모니터링 시작
        start_monitoring ${sub_value}
        
        # RocksDB 성능 테스트 실행
        log_info "db_bench 실행 중... (subcompactions=${sub_value})"
        
        local start_time=$(date +%s)
        
        ${DB_BENCH} \
            --benchmarks=fillrandom,compact \
            --db="${test_db_dir}" \
            --num=${NUM_KEYS} \
            --value_size=${VALUE_SIZE} \
            --key_size=${KEY_SIZE} \
            --subcompactions=${sub_value} \
            --max_background_jobs=${MAX_BACKGROUND_JOBS} \
            --write_buffer_size=${WRITE_BUFFER_SIZE} \
            --max_write_buffer_number=${MAX_WRITE_BUFFER_NUMBER} \
            --target_file_size_base=${TARGET_FILE_SIZE_BASE} \
            --compression_type=snappy \
            --cache_size=1073741824 \
            --statistics \
            --histogram \
            --report_interval_seconds=${REPORT_INTERVAL} \
            > "${result_file}" 2>&1 &
        
        local db_bench_pid=$!
        
        # db_bench 프로세스 모니터링 시작
        monitor_db_bench ${sub_value} ${db_bench_pid}
        
        # db_bench 완료 대기
        wait ${db_bench_pid}
        local exit_code=$?
        
        local end_time=$(date +%s)
        local total_time=$((end_time - start_time))
        
        # 리소스 모니터링 중지
        stop_monitoring
        
        if [ $exit_code -eq 0 ]; then
            log_info "Subcompactions=${sub_value} 테스트 완료 (${total_time}초)"
            
            # 결과 파싱 및 저장
            parse_and_save_results ${sub_value} "${result_file}" ${total_time}
        else
            log_error "Subcompactions=${sub_value} 테스트 실패 (exit code: ${exit_code})"
        fi
        
        # 다음 테스트 전 대기 (시스템 안정화)
        log_info "시스템 안정화 대기 (30초)..."
        sleep 30
    done
    
    log_info "Phase 2 완료"
}

# 결과 파싱 및 CSV 저장
parse_and_save_results() {
    local sub_value=$1
    local result_file=$2
    local total_time=$3
    
    log_info "결과 파싱 중... (subcompactions=${sub_value})"
    
    # db_bench 결과에서 처리량 추출
    local throughput=$(grep -E "fillrandom.*ops/sec" "${result_file}" | tail -1 | awk '{print $5}' | sed 's/ops\/sec//' || echo "0")
    
    # 컴팩션 처리량 추출 (MB/s)
    local compact_throughput=$(grep -E "compact.*MB/s" "${result_file}" | tail -1 | awk '{print $NF}' | sed 's/MB\/s//' || echo "0")
    
    # 시스템 리소스 정보 파싱
    local monitor_suffix="sub_${sub_value}"
    local cpu_usage=$(tail -10 "${LOG_DIR}/vmstat_${monitor_suffix}.log" 2>/dev/null | grep -v "procs\|r" | awk '{sum+=$(NF-2)} END {if(NR>0) print sum/NR; else print "0"}' || echo "0")
    
    # 메모리 사용량 계산 (GB)
    local memory_usage=$(tail -10 "${LOG_DIR}/vmstat_${monitor_suffix}.log" 2>/dev/null | grep -v "procs\|r" | awk '{sum+=$4} END {if(NR>0) print sum/NR/1024/1024; else print "0"}' || echo "0")
    
    # I/O 통계
    local io_read=$(tail -10 "${LOG_DIR}/iostat_${monitor_suffix}.log" 2>/dev/null | grep -E "sda|nvme" | awk '{sum+=$6} END {if(NR>0) print sum/NR/1024; else print "0"}' || echo "0")
    local io_write=$(tail -10 "${LOG_DIR}/iostat_${monitor_suffix}.log" 2>/dev/null | grep -E "sda|nvme" | awk '{sum+=$7} END {if(NR>0) print sum/NR/1024; else print "0"}' || echo "0")
    
    # Context Switches
    local context_switches=$(tail -10 "${LOG_DIR}/vmstat_${monitor_suffix}.log" 2>/dev/null | grep -v "procs\|r" | awk '{sum+=$12} END {if(NR>0) print sum/NR; else print "0"}' || echo "0")
    
    # CSV에 결과 추가
    echo "${sub_value},${compact_throughput},${cpu_usage},${memory_usage},${total_time},${io_read},${io_write},${context_switches}" >> "${RESULTS_DIR}/compaction_results.csv"
    
    log_info "결과 저장 완료 - Throughput: ${compact_throughput} MB/s, CPU: ${cpu_usage}%, Memory: ${memory_usage} GB"
}

# Phase 3: 읽기 성능 영향 분석
phase3_read_performance() {
    log_phase "Phase 3: 읽기 성능 영향 분석"
    
    # 최적 설정으로 추정되는 값들로 읽기 테스트
    local optimal_configs=(4 8 16)
    
    for sub_value in "${optimal_configs[@]}"; do
        local test_db_dir="${BASE_DIR}/rocksdb_test_sub_${sub_value}"
        
        if [ -d "${test_db_dir}" ]; then
            log_info "읽기 성능 테스트 (subcompactions=${sub_value})"
            
            ${DB_BENCH} \
                --benchmarks=readrandom \
                --db="${test_db_dir}" \
                --num=10000000 \
                --threads=16 \
                --use_existing_db \
                --statistics \
                --histogram \
                > "${RESULTS_DIR}/read_performance_sub_${sub_value}.txt" 2>&1
        fi
    done
    
    log_info "Phase 3 완료"
}

# Phase 4: 결과 분석 및 리포트 생성
phase4_analysis() {
    log_phase "Phase 4: 결과 분석 및 리포트 생성"
    
    # Python 스크립트로 결과 분석 (있는 경우)
    if command -v python3 &> /dev/null; then
        generate_analysis_report
    fi
    
    # 간단한 요약 리포트 생성
    generate_summary_report
    
    log_info "Phase 4 완료"
}

# 요약 리포트 생성
generate_summary_report() {
    local summary_file="${RESULTS_DIR}/experiment_summary.md"
    
    cat > "${summary_file}" << EOF
# Parallel Compaction 실험 결과 요약

## 실험 정보
- 실험 시간: $(date)
- 테스트된 Subcompaction 값: ${SUBCOMPACTION_VALUES[*]}
- 키 개수: ${NUM_KEYS}
- 값 크기: ${VALUE_SIZE} bytes

## 최적 성능 결과
EOF

    # CSV에서 최고 처리량 찾기
    local best_throughput_line=$(tail -n +2 "${RESULTS_DIR}/compaction_results.csv" | sort -t',' -k2 -nr | head -1)
    if [ ! -z "$best_throughput_line" ]; then
        local best_sub=$(echo "$best_throughput_line" | cut -d',' -f1)
        local best_throughput=$(echo "$best_throughput_line" | cut -d',' -f2)
        
        cat >> "${summary_file}" << EOF

### 최고 처리량
- Subcompactions: ${best_sub}
- 처리량: ${best_throughput} MB/s

## 상세 결과
$(cat "${RESULTS_DIR}/compaction_results.csv")

## 파일 위치
- 상세 결과: ${RESULTS_DIR}/
- 로그 파일: ${LOG_DIR}/
- CSV 데이터: ${RESULTS_DIR}/compaction_results.csv
EOF
    fi
    
    log_info "요약 리포트 생성: ${summary_file}"
}

# Python 분석 리포트 생성 (옵션)
generate_analysis_report() {
    cat > "${RESULTS_DIR}/analyze_results.py" << 'EOF'
#!/usr/bin/env python3
import pandas as pd
import matplotlib.pyplot as plt
import sys
import os

def analyze_results(csv_file):
    try:
        df = pd.read_csv(csv_file)
        
        # 기본 통계
        print("=== 실험 결과 분석 ===")
        print(f"테스트된 Subcompaction 설정: {sorted(df['Subcompactions'].tolist())}")
        print(f"최고 처리량: {df['Throughput_MBps'].max():.2f} MB/s (Subcompactions={df.loc[df['Throughput_MBps'].idxmax(), 'Subcompactions']})")
        print(f"최저 처리량: {df['Throughput_MBps'].min():.2f} MB/s (Subcompactions={df.loc[df['Throughput_MBps'].idxmin(), 'Subcompactions']})")
        
        # 효율성 계산 (처리량/메모리 사용량)
        df['Efficiency'] = df['Throughput_MBps'] / df['Memory_GB']
        best_efficiency_idx = df['Efficiency'].idxmax()
        print(f"최고 효율성: Subcompactions={df.loc[best_efficiency_idx, 'Subcompactions']} (처리량: {df.loc[best_efficiency_idx, 'Throughput_MBps']:.2f} MB/s, 메모리: {df.loc[best_efficiency_idx, 'Memory_GB']:.2f} GB)")
        
        # 그래프 생성 (matplotlib 사용 가능한 경우)
        try:
            plt.figure(figsize=(15, 10))
            
            # 1. 처리량 vs Subcompactions
            plt.subplot(2, 2, 1)
            plt.plot(df['Subcompactions'], df['Throughput_MBps'], 'b-o')
            plt.xlabel('Subcompactions')
            plt.ylabel('Throughput (MB/s)')
            plt.title('처리량 vs Subcompactions')
            plt.grid(True)
            
            # 2. CPU 사용률
            plt.subplot(2, 2, 2)
            plt.plot(df['Subcompactions'], df['CPU_Usage_Percent'], 'r-o')
            plt.xlabel('Subcompactions')
            plt.ylabel('CPU Usage (%)')
            plt.title('CPU 사용률 vs Subcompactions')
            plt.grid(True)
            
            # 3. 메모리 사용량
            plt.subplot(2, 2, 3)
            plt.plot(df['Subcompactions'], df['Memory_GB'], 'g-o')
            plt.xlabel('Subcompactions')
            plt.ylabel('Memory Usage (GB)')
            plt.title('메모리 사용량 vs Subcompactions')
            plt.grid(True)
            
            # 4. 효율성
            plt.subplot(2, 2, 4)
            plt.plot(df['Subcompactions'], df['Efficiency'], 'm-o')
            plt.xlabel('Subcompactions')
            plt.ylabel('Efficiency (MB/s per GB)')
            plt.title('효율성 vs Subcompactions')
            plt.grid(True)
            
            plt.tight_layout()
            plt.savefig(os.path.join(os.path.dirname(csv_file), 'performance_analysis.png'), dpi=300, bbox_inches='tight')
            print(f"그래프 저장됨: {os.path.dirname(csv_file)}/performance_analysis.png")
            
        except ImportError:
            print("matplotlib를 사용할 수 없어 그래프 생성을 건너뜁니다.")
            
    except Exception as e:
        print(f"분석 중 오류 발생: {e}")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        analyze_results(sys.argv[1])
    else:
        print("사용법: python3 analyze_results.py <csv_file>")
EOF

    # Python 분석 실행
    if python3 "${RESULTS_DIR}/analyze_results.py" "${RESULTS_DIR}/compaction_results.csv" > "${RESULTS_DIR}/analysis_output.txt" 2>&1; then
        log_info "Python 분석 완료: ${RESULTS_DIR}/analysis_output.txt"
    else
        log_warn "Python 분석 실행 실패"
    fi
}

# 정리 함수
cleanup() {
    log_info "실험 정리 중..."
    cleanup_monitors
    
    # 임시 파일 정리 (선택적)
    # rm -rf "${BASE_DIR}"
    
    log_info "실험 완료! 결과는 ${RESULTS_DIR}에 저장되었습니다."
    echo -e "${GREEN}주요 결과 파일:${NC}"
    echo "  - 요약: ${RESULTS_DIR}/experiment_summary.md"
    echo "  - CSV 데이터: ${RESULTS_DIR}/compaction_results.csv"
    echo "  - 로그: ${LOG_DIR}/"
    
    if [ -f "${RESULTS_DIR}/performance_analysis.png" ]; then
        echo "  - 그래프: ${RESULTS_DIR}/performance_analysis.png"
    fi
}

# 신호 핸들러 설정
trap cleanup EXIT
trap 'log_error "실험이 중단되었습니다."; exit 1' INT TERM

# ========================================
# 메인 실행 함수
# ========================================

main() {
    log_info "🚀 Parallel Compaction 스케일링 효과 분석 시작"
    log_info "결과 저장 위치: ${RESULTS_DIR}"
    
    # 사용자 확인
    echo -e "${YELLOW}실험 설정:${NC}"
    echo "  - Subcompaction 값: ${SUBCOMPACTION_VALUES[*]}"
    echo "  - 키 개수: ${NUM_KEYS}"
    echo "  - 값 크기: ${VALUE_SIZE} bytes"
    echo "  - 예상 소요 시간: $(( ${#SUBCOMPACTION_VALUES[@]} * 15 )) - $(( ${#SUBCOMPACTION_VALUES[@]} * 30 ))분"
    echo ""
    
    read -p "실험을 시작하시겠습니까? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "실험이 취소되었습니다."
        exit 0
    fi
    
    # 실험 단계별 실행
    phase1_setup
    phase2_performance_test
    phase3_read_performance
    phase4_analysis
    
    log_info "✅ 모든 실험이 성공적으로 완료되었습니다!"
}

# 도움말 함수
show_help() {
    cat << EOF
🚀 Parallel Compaction 스케일링 효과 분석 스크립트

사용법: $0 [옵션]

옵션:
  -h, --help              이 도움말 표시
  -d, --db-bench PATH     db_bench 실행파일 경로 지정 (기본: ./db_bench)
  -o, --output DIR        결과 저장 디렉토리 지정
  -n, --num-keys NUM      테스트 키 개수 (기본: 50000000)
  -s, --subcompactions    테스트할 subcompaction 값들 (예: "1,2,4,8")

환경변수:
  ROCKSDB_PATH           RocksDB 빌드 디렉토리 (db_bench 위치)

예제:
  $0                                    # 기본 설정으로 실행
  $0 -d /path/to/db_bench               # db_bench 경로 지정
  $0 -s "1,2,4,8,16"                    # 특정 subcompaction 값만 테스트
  ROCKSDB_PATH=/opt/rocksdb $0          # 환경변수로 경로 지정

실험 단계:
  Phase 1: 환경 준비 및 초기 설정
  Phase 2: Subcompaction별 성능 테스트 
  Phase 3: 읽기 성능 영향 분석
  Phase 4: 결과 분석 및 리포트 생성

EOF
}

# 명령행 인자 처리
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -d|--db-bench)
            DB_BENCH="$2"
            shift 2
            ;;
        -o|--output)
            RESULTS_DIR="$2"
            LOG_DIR="${RESULTS_DIR}/logs"
            shift 2
            ;;
        -n|--num-keys)
            NUM_KEYS="$2"
            shift 2
            ;;
        -s|--subcompactions)
            IFS=',' read -ra SUBCOMPACTION_VALUES <<< "$2"
            shift 2
            ;;
        *)
            log_error "알 수 없는 옵션: $1"
            show_help
            exit 1
            ;;
    esac
done

# 메인 함수 실행
main "$@" 