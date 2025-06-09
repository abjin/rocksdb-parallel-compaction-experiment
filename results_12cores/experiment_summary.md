# Parallel Compaction 실험 결과 요약

## 실험 정보
- 실험 시간: Mon Jun  9 06:25:25 UTC 2025
- 테스트된 Subcompaction 값: 1 2 4 8 12 16 24 32
- 키 개수: 50000000
- 값 크기: 100 bytes

## 최적 성능 결과

### 최고 처리량
- Subcompactions: 8
- 처리량:  MB/s

## 상세 결과
Subcompactions,Throughput_MBps,CPU_Usage_Percent,Memory_GB,Compaction_Time_Sec,IO_Read_MBps,IO_Write_MBps,System_Load_Average
1,,9,21.8919,564,0,0,1.439
2,,21.375,19.5834,546,0,0,2.38
4,,33.2,15.1932,545,0,0,2.418
8,,61,13.1212,531,0,0,2.499
12,,65.2,11.3085,539,0,0,2.748
16,,59.7,9.36023,542,0,0,2.455
24,,73.875,7.45028,529,0,0,2.62
32,,64,5.38861,537,0,0,2.031

## 파일 위치
- 상세 결과: ./results_20250609_050855/
- 로그 파일: ./results_20250609_050855/logs/
- CSV 데이터: ./results_20250609_050855/compaction_results.csv
