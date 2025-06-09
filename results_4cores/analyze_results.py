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
