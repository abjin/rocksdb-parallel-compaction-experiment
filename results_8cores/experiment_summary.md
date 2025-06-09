# Parallel Compaction 실험 결과 요약

## 실험 정보
- 실험 시간: Mon Jun  9 05:33:23 UTC 2025
- 테스트된 Subcompaction 값: 1 2 4 8 12 16 24 32
- 키 개수: 50000000
- 값 크기: 100 bytes

## 최적 성능 결과

### 최고 처리량
- Subcompactions: 8
- 처리량:  MB/s

## 상세 결과
Subcompactions,Throughput_MBps,CPU_Usage_Percent,Memory_GB,Compaction_Time_Sec,IO_Read_MBps,IO_Write_MBps,System_Load_Average
1,,13.875,0.902213,760,0,0,1.31
2,,25.9,1.26348,686,0,0,2.24
4,,47,1.18509,682,0,0,2.675
8,,80.25,1.10907,675,0,0,2.881
12,,84.8,0.731298,647,0,0,3.113
16,,78,0.759982,758,0,0,3.581
24,,84.5,0.677701,699,0,0,3.788
32,,75.5,0.816422,698,0,0,3.429

## 파일 위치
- 상세 결과: ./results_20250609_035534/
- 로그 파일: ./results_20250609_035534/logs/
- CSV 데이터: ./results_20250609_035534/compaction_results.csv
