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
WRITE_BUFFER_SIZE="64"
MAX_WRITE_BUFFER_NUMBER=8
TARGET_FILE_SIZE_BASE="64"

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

# ========================================
# 모니터링 시스템
# ========================================

# 모니터링 프로세스 PID 저장용
declare -A MONITOR_PIDS

# 모니터링 프로세스 정리
cleanup_monitors() {
    log_info "실행 중인 모니터링 프로세스 정리 중..."
    
    # 저장된 PID들 종료
    for pid in "${MONITOR_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    
    # 일반적인 모니터링 프로세스들 정리
    pkill -f "iostat.*rocksdb_monitor" 2>/dev/null || true
    pkill -f "vmstat.*rocksdb_monitor" 2>/dev/null || true
    pkill -f "sar.*rocksdb_monitor" 2>/dev/null || true
    
    # PID 배열 초기화
    MONITOR_PIDS=()
    
    sleep 1
}

# 시스템 리소스 모니터링 시작
start_system_monitoring() {
    local sub_value=$1
    local log_prefix="${LOG_DIR}/monitor_sub_${sub_value}"
    
    log_info "시스템 리소스 모니터링 시작 (subcompactions=${sub_value})"
    
    # 전체 시스템 상태 기록 시작
    record_system_baseline "${log_prefix}_baseline.log"
    
    # CPU 및 메모리 모니터링 (간소화)
    vmstat ${MONITOR_INTERVAL} > "${log_prefix}_vmstat.log" 2>&1 &
    MONITOR_PIDS["vmstat"]=$!
    
    # I/O 모니터링 (주요 디스크만)
    iostat -x ${MONITOR_INTERVAL} > "${log_prefix}_iostat.log" 2>&1 &
    MONITOR_PIDS["iostat"]=$!
    
    # 시스템 로드 모니터링
    nohup bash -c "
        while true; do
            echo \"\$(date '+%Y-%m-%d %H:%M:%S'),\$(uptime | awk -F'load average:' '{print \$2}' | tr -d ' ')\" >> \"${log_prefix}_load.csv\"
            sleep ${MONITOR_INTERVAL}
        done
    " &
    MONITOR_PIDS["load"]=$!
    
    sleep 1  # 모니터링 시스템 안정화 대기
}

# db_bench 프로세스 전용 모니터링
start_process_monitoring() {
    local sub_value=$1
    local db_bench_pid=$2
    local log_prefix="${LOG_DIR}/process_sub_${sub_value}"
    
    if [ -z "$db_bench_pid" ]; then
        log_warn "db_bench PID가 제공되지 않아 프로세스 모니터링을 건너뜁니다"
        return
    fi
    
    log_info "db_bench 프로세스 모니터링 시작 (PID: ${db_bench_pid})"
    
    # 프로세스별 리소스 사용량 모니터링
    nohup bash -c "
        echo 'timestamp,pid,cpu_percent,memory_percent,vss_kb,rss_kb' > \"${log_prefix}_resource.csv\"
        while kill -0 $db_bench_pid 2>/dev/null; do
            ps_output=\$(ps -p $db_bench_pid -o pid,%cpu,%mem,vsz,rss --no-headers 2>/dev/null)
            if [ ! -z \"\$ps_output\" ]; then
                echo \"\$(date '+%Y-%m-%d %H:%M:%S'),\$ps_output\" >> \"${log_prefix}_resource.csv\"
            fi
            sleep ${MONITOR_INTERVAL}
        done
    " &
    MONITOR_PIDS["process_$db_bench_pid"]=$!
    
    # 프로세스 I/O 모니터링 (가능한 경우)
    if [ -d "/proc/$db_bench_pid" ]; then
        nohup bash -c "
            echo 'timestamp,read_bytes,write_bytes' > \"${log_prefix}_io.csv\"
            while kill -0 $db_bench_pid 2>/dev/null; do
                if [ -f \"/proc/$db_bench_pid/io\" ]; then
                    read_bytes=\$(grep 'read_bytes' /proc/$db_bench_pid/io 2>/dev/null | awk '{print \$2}' || echo '0')
                    write_bytes=\$(grep 'write_bytes' /proc/$db_bench_pid/io 2>/dev/null | awk '{print \$2}' || echo '0')
                    echo \"\$(date '+%Y-%m-%d %H:%M:%S'),\$read_bytes,\$write_bytes\" >> \"${log_prefix}_io.csv\"
                fi
                sleep ${MONITOR_INTERVAL}
            done
        " &
        MONITOR_PIDS["io_$db_bench_pid"]=$!
    fi
}

# 시스템 기준 상태 기록
record_system_baseline() {
    local output_file=$1
    
    cat > "$output_file" << EOF
=== 시스템 기준 상태 ($(date)) ===
CPU 정보: $(nproc) cores, $(cat /proc/cpuinfo | grep "model name" | head -1 | cut -d: -f2 | xargs)
메모리 정보: $(free -h | grep Mem | awk '{print $2 " total, " $3 " used, " $7 " available"}')
디스크 사용량: $(df -h / | tail -1 | awk '{print $2 " total, " $3 " used, " $4 " available"}')
현재 로드: $(uptime | awk -F'load average:' '{print $2}')
네트워크 연결 수: $(ss -tuln | wc -l)

=== 실행 중인 프로세스 (메모리 사용량 상위 10개) ===
$(ps aux --sort=-%mem | head -11)
EOF
}

# 모니터링 중지
stop_all_monitoring() {
    log_info "모든 모니터링 중지"
    cleanup_monitors
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
Subcompactions,Throughput_MBps,CPU_Usage_Percent,Memory_GB,Compaction_Time_Sec,IO_Read_MBps,IO_Write_MBps,System_Load_Average
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
        
        # 시스템 모니터링 시작
        start_system_monitoring ${sub_value}
        
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
            --statistics \
            --histogram \
            --report_interval_seconds=${REPORT_INTERVAL} \
            > "${result_file}" 2>&1 &
        
        local db_bench_pid=$!
        
        # db_bench 프로세스 전용 모니터링 시작
        start_process_monitoring ${sub_value} ${db_bench_pid}
        
        # db_bench 완료 대기
        wait ${db_bench_pid}
        local exit_code=$?
        
        local end_time=$(date +%s)
        local total_time=$((end_time - start_time))
        
        # 모든 모니터링 중지
        stop_all_monitoring
        
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
    local fillrandom_throughput=$(grep -E "fillrandom.*ops/sec" "${result_file}" | tail -1 | awk '{
        for(i=1;i<=NF;i++) {
            if($i ~ /^[0-9.]+$/ && $(i+1) == "ops/sec") {
                print $i; break
            }
        }
    }' || echo "0")
    
    # 컴팩션 처리량 추출 (MB/s)
    local compact_throughput=$(grep -E "compact.*MB/s" "${result_file}" | tail -1 | awk '{
        for(i=1;i<=NF;i++) {
            if($i ~ /^[0-9.]+$/ && $(i+1) == "MB/s") {
                print $i; break
            }
        }
    }' || echo "0")
    
    # 새로운 모니터링 로그 파일 경로
    local vmstat_log="${LOG_DIR}/monitor_sub_${sub_value}_vmstat.log"
    local iostat_log="${LOG_DIR}/monitor_sub_${sub_value}_iostat.log"
    local process_log="${LOG_DIR}/process_sub_${sub_value}_resource.csv"
    local load_log="${LOG_DIR}/monitor_sub_${sub_value}_load.csv"
    
    # CPU 사용률 계산 (vmstat에서 idle 값을 이용)
    local cpu_usage="0"
    if [ -f "$vmstat_log" ]; then
        cpu_usage=$(tail -10 "$vmstat_log" 2>/dev/null | \
                   grep -v "procs\|r\|free" | \
                   awk '{if(NF>=15) idle+=$15; count++} END {
                       if(count>0) print 100-(idle/count); else print "0"
                   }' || echo "0")
    fi
    
    # 메모리 사용량 계산 (GB) - vmstat의 사용된 메모리
    local memory_usage="0"
    if [ -f "$vmstat_log" ]; then
        memory_usage=$(tail -10 "$vmstat_log" 2>/dev/null | \
                      grep -v "procs\|r\|free" | \
                      awk '{if(NF>=6) used+=$4; count++} END {
                          if(count>0) print (used/count)/1024/1024; else print "0"
                      }' || echo "0")
    fi
    
    # I/O 통계 (MB/s) - iostat에서 주요 디스크 읽기/쓰기 속도
    local io_read="0"
    local io_write="0"
    if [ -f "$iostat_log" ]; then
        # 첫 번째 디스크 장치의 평균 I/O 속도 계산
        io_read=$(tail -20 "$iostat_log" 2>/dev/null | \
                 grep -E "sda|nvme|xvd" | tail -10 | \
                 awk '{if(NF>=7) read+=$6; count++} END {
                     if(count>0) print (read/count)/1024; else print "0"
                 }' || echo "0")
        
        io_write=$(tail -20 "$iostat_log" 2>/dev/null | \
                  grep -E "sda|nvme|xvd" | tail -10 | \
                  awk '{if(NF>=7) write+=$7; count++} END {
                      if(count>0) print (write/count)/1024; else print "0"
                  }' || echo "0")
    fi
    
    # 시스템 로드 평균
    local avg_load="0"
    if [ -f "$load_log" ]; then
        avg_load=$(tail -10 "$load_log" 2>/dev/null | \
                  cut -d',' -f2 | \
                  awk -F',' '{sum+=$1; count++} END {
                      if(count>0) print sum/count; else print "0"
                  }' || echo "0")
    fi
    
    # 프로세스별 최대 메모리 사용량 (GB)
    local peak_process_memory="0"
    if [ -f "$process_log" ]; then
        peak_process_memory=$(tail -n +2 "$process_log" 2>/dev/null | \
                             cut -d',' -f6 | \
                             awk 'BEGIN{max=0} {if($1>max) max=$1} END {print max/1024/1024}' || echo "0")
    fi
    
    # CSV에 결과 추가 (헤더 순서에 맞게)
    echo "${sub_value},${compact_throughput},${cpu_usage},${memory_usage},${total_time},${io_read},${io_write},${avg_load}" >> "${RESULTS_DIR}/compaction_results.csv"
    
    # 상세 정보 로그
    log_info "결과 저장 완료:"
    log_info "  - Fillrandom 처리량: ${fillrandom_throughput} ops/sec"
    log_info "  - Compact 처리량: ${compact_throughput} MB/s"
    log_info "  - 평균 CPU 사용률: ${cpu_usage}%"
    log_info "  - 평균 메모리 사용량: ${memory_usage} GB"
    log_info "  - 최대 프로세스 메모리: ${peak_process_memory} GB"
    log_info "  - 총 실행 시간: ${total_time}초"
}



# Phase 3: 결과 분석 및 리포트 생성
phase3_analysis() {
    log_phase "Phase 3: 결과 분석 및 리포트 생성"
    
    # Python 스크립트로 결과 분석 (있는 경우)
    if command -v python3 &> /dev/null; then
        generate_analysis_report
    fi
    
    # 간단한 요약 리포트 생성
    generate_summary_report
    
    log_info "Phase 3 완료"
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
    stop_all_monitoring
    
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
    echo "  - 예상 소요 시간: $(( ${#SUBCOMPACTION_VALUES[@]} * 10 )) - $(( ${#SUBCOMPACTION_VALUES[@]} * 20 ))분"
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
    phase3_analysis
    
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
  Phase 3: 결과 분석 및 리포트 생성

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