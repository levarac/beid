#!/usr/bin/env python3
"""
Beid Timeline Analyzer - センシングログの時系列分析

Usage:
    python analyze_timeline.py                      # 全ログを分析
    python analyze_timeline.py --rssi <file.csv>   # RSSIログを分析
    python analyze_timeline.py --edges <file.csv>  # エッジイベントを分析
    python analyze_timeline.py --stats <file.csv>  # 統計ログを分析
"""

import argparse
from datetime import datetime, timedelta
from pathlib import Path
import sys

try:
    import pandas as pd
    import matplotlib.pyplot as plt
    import matplotlib.dates as mdates
except ImportError:
    print("Required packages not found. Install with:")
    print("  pip install pandas matplotlib")
    sys.exit(1)


DEFAULT_LOG_DIR = Path(__file__).parent.parent / "logs"


def analyze_rssi_log(filepath: Path, output_dir: Path | None = None):
    """RSSIログの時系列分析"""
    print(f"\nAnalyzing RSSI log: {filepath}")

    df = pd.read_csv(filepath, parse_dates=["timestamp"])

    print(f"  Records: {len(df)}")
    print(f"  Time range: {df['timestamp'].min()} to {df['timestamp'].max()}")
    print(f"  Unique reporters: {df['reporter_id'].nunique()}")
    print(f"  Unique detected: {df['detected_id'].nunique()}")

    # RSSI統計
    print(f"\n  RSSI Statistics:")
    print(f"    Mean: {df['rssi'].mean():.2f} dBm")
    print(f"    Std:  {df['rssi'].std():.2f} dBm")
    print(f"    Min:  {df['rssi'].min()} dBm")
    print(f"    Max:  {df['rssi'].max()} dBm")

    # 相互検知率
    mutual_rate = df['is_mutual'].mean() * 100
    print(f"\n  Mutual detection rate: {mutual_rate:.1f}%")

    # 可視化
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))

    # 1. RSSI時系列
    ax1 = axes[0, 0]
    for reporter in df['reporter_id'].unique()[:5]:  # 最大5ユーザー
        subset = df[df['reporter_id'] == reporter]
        ax1.scatter(subset['timestamp'], subset['rssi'], alpha=0.5, s=10, label=reporter[:8])
    ax1.set_xlabel('Time')
    ax1.set_ylabel('RSSI (dBm)')
    ax1.set_title('RSSI over Time (by reporter)')
    ax1.legend(loc='upper right', fontsize=8)
    ax1.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))

    # 2. RSSI分布
    ax2 = axes[0, 1]
    ax2.hist(df['rssi'], bins=30, edgecolor='black', alpha=0.7)
    ax2.axvline(df['rssi'].mean(), color='red', linestyle='--', label=f'Mean: {df["rssi"].mean():.1f}')
    ax2.set_xlabel('RSSI (dBm)')
    ax2.set_ylabel('Count')
    ax2.set_title('RSSI Distribution')
    ax2.legend()

    # 3. 距離推定の分布
    ax3 = axes[1, 0]
    ax3.hist(df['distance_estimate'], bins=30, edgecolor='black', alpha=0.7, color='green')
    ax3.set_xlabel('Estimated Distance (m)')
    ax3.set_ylabel('Count')
    ax3.set_title('Distance Estimate Distribution')

    # 4. レポート頻度（時間帯別）
    ax4 = axes[1, 1]
    df['minute'] = df['timestamp'].dt.floor('1min')
    report_freq = df.groupby('minute').size()
    ax4.plot(report_freq.index, report_freq.values, color='purple')
    ax4.set_xlabel('Time')
    ax4.set_ylabel('Reports per Minute')
    ax4.set_title('Report Frequency')
    ax4.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))

    plt.tight_layout()

    if output_dir:
        output_path = output_dir / f"rssi_analysis_{datetime.now().strftime('%Y%m%d_%H%M%S')}.png"
        plt.savefig(output_path, dpi=150)
        print(f"\n  Saved: {output_path}")
    else:
        plt.show()


def analyze_edge_events(filepath: Path, output_dir: Path | None = None):
    """エッジイベントの時系列分析"""
    print(f"\nAnalyzing edge events: {filepath}")

    df = pd.read_csv(filepath, parse_dates=["timestamp"])

    print(f"  Total events: {len(df)}")

    # イベントタイプ別集計
    event_counts = df['event_type'].value_counts()
    print(f"\n  Event types:")
    for event_type, count in event_counts.items():
        print(f"    {event_type}: {count}")

    # エッジ持続時間（dissolved のみ）
    dissolved = df[df['event_type'] == 'edge_dissolved']
    if len(dissolved) > 0 and 'edge_duration_ms' in dissolved.columns:
        durations = dissolved['edge_duration_ms'].dropna() / 1000  # 秒に変換
        print(f"\n  Edge Duration Statistics:")
        print(f"    Mean: {durations.mean():.1f} sec")
        print(f"    Median: {durations.median():.1f} sec")
        print(f"    Max: {durations.max():.1f} sec")

    # 相互検知率
    if 'mutual' in df.columns:
        mutual_edges = df[df['mutual'] == True]
        mutual_rate = len(mutual_edges) / len(df) * 100 if len(df) > 0 else 0
        print(f"\n  Mutual edge rate: {mutual_rate:.1f}%")

    # 可視化
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))

    # 1. イベントタイムライン
    ax1 = axes[0, 0]
    colors = {'edge_established': 'green', 'edge_updated': 'blue', 'edge_dissolved': 'red'}
    for event_type in df['event_type'].unique():
        subset = df[df['event_type'] == event_type]
        ax1.scatter(subset['timestamp'], [event_type] * len(subset),
                   alpha=0.6, s=20, c=colors.get(event_type, 'gray'), label=event_type)
    ax1.set_xlabel('Time')
    ax1.set_title('Edge Events Timeline')
    ax1.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))
    ax1.legend()

    # 2. イベントタイプ分布
    ax2 = axes[0, 1]
    event_counts.plot(kind='bar', ax=ax2, color=['green', 'blue', 'red'][:len(event_counts)])
    ax2.set_ylabel('Count')
    ax2.set_title('Event Type Distribution')
    ax2.tick_params(axis='x', rotation=45)

    # 3. RSSI平均の推移
    ax3 = axes[1, 0]
    if 'rssi_avg' in df.columns:
        df_with_rssi = df[df['rssi_avg'].notna()]
        ax3.scatter(df_with_rssi['timestamp'], df_with_rssi['rssi_avg'], alpha=0.5, s=15)
        ax3.set_xlabel('Time')
        ax3.set_ylabel('Average RSSI (dBm)')
        ax3.set_title('Edge RSSI over Time')
        ax3.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))

    # 4. エッジ持続時間分布
    ax4 = axes[1, 1]
    if len(dissolved) > 0 and 'edge_duration_ms' in dissolved.columns:
        durations = dissolved['edge_duration_ms'].dropna() / 1000
        ax4.hist(durations, bins=20, edgecolor='black', alpha=0.7, color='orange')
        ax4.set_xlabel('Duration (sec)')
        ax4.set_ylabel('Count')
        ax4.set_title('Edge Duration Distribution')

    plt.tight_layout()

    if output_dir:
        output_path = output_dir / f"edge_analysis_{datetime.now().strftime('%Y%m%d_%H%M%S')}.png"
        plt.savefig(output_path, dpi=150)
        print(f"\n  Saved: {output_path}")
    else:
        plt.show()


def analyze_stats_log(filepath: Path, output_dir: Path | None = None):
    """統計ログの時系列分析"""
    print(f"\nAnalyzing stats log: {filepath}")

    df = pd.read_csv(filepath, parse_dates=["timestamp"])

    print(f"  Records: {len(df)}")
    print(f"  Time range: {df['timestamp'].min()} to {df['timestamp'].max()}")

    # 主要統計
    print(f"\n  Node count - Mean: {df['node_count'].mean():.1f}, Max: {df['node_count'].max()}")
    print(f"  Edge count - Mean: {df['edge_count'].mean():.1f}, Max: {df['edge_count'].max()}")
    print(f"  Density - Mean: {df['density'].mean():.4f}, Max: {df['density'].max():.4f}")

    # 可視化
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))

    # 1. ノード・エッジ数の推移
    ax1 = axes[0, 0]
    ax1.plot(df['timestamp'], df['node_count'], label='Nodes', color='blue', marker='o', markersize=3)
    ax1.plot(df['timestamp'], df['edge_count'], label='Edges', color='green', marker='s', markersize=3)
    ax1.plot(df['timestamp'], df['mutual_edge_count'], label='Mutual Edges', color='orange', marker='^', markersize=3)
    ax1.set_xlabel('Time')
    ax1.set_ylabel('Count')
    ax1.set_title('Graph Size over Time')
    ax1.legend()
    ax1.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))

    # 2. 密度の推移
    ax2 = axes[0, 1]
    ax2.plot(df['timestamp'], df['density'], color='purple', marker='o', markersize=3)
    ax2.fill_between(df['timestamp'], df['density'], alpha=0.3, color='purple')
    ax2.set_xlabel('Time')
    ax2.set_ylabel('Density')
    ax2.set_title('Graph Density over Time')
    ax2.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))
    ax2.set_ylim(0, 1)

    # 3. 平均RSSI・距離の推移
    ax3 = axes[1, 0]
    if 'avg_rssi' in df.columns:
        ax3_rssi = ax3
        ax3_rssi.plot(df['timestamp'], df['avg_rssi'], color='red', label='Avg RSSI')
        ax3_rssi.set_xlabel('Time')
        ax3_rssi.set_ylabel('RSSI (dBm)', color='red')
        ax3_rssi.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))

        if 'avg_distance' in df.columns:
            ax3_dist = ax3.twinx()
            ax3_dist.plot(df['timestamp'], df['avg_distance'], color='blue', label='Avg Distance')
            ax3_dist.set_ylabel('Distance (m)', color='blue')

    ax3.set_title('Average RSSI & Distance')

    # 4. 連結成分数
    ax4 = axes[1, 1]
    ax4.plot(df['timestamp'], df['connected_components'], color='teal', marker='o', markersize=3)
    ax4.set_xlabel('Time')
    ax4.set_ylabel('Connected Components')
    ax4.set_title('Connected Components over Time')
    ax4.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))
    ax4.yaxis.set_major_locator(plt.MaxNLocator(integer=True))

    plt.tight_layout()

    if output_dir:
        output_path = output_dir / f"stats_analysis_{datetime.now().strftime('%Y%m%d_%H%M%S')}.png"
        plt.savefig(output_path, dpi=150)
        print(f"\n  Saved: {output_path}")
    else:
        plt.show()


def find_latest_log(log_dir: Path, prefix: str) -> Path | None:
    """最新のログファイルを検索"""
    pattern = f"{prefix}*.csv"
    files = sorted(log_dir.glob(pattern), reverse=True)
    return files[0] if files else None


def main():
    parser = argparse.ArgumentParser(description="Analyze BLE sensing logs")

    parser.add_argument("--rssi", type=Path, help="RSSI log CSV file")
    parser.add_argument("--edges", type=Path, help="Edge events CSV file")
    parser.add_argument("--stats", type=Path, help="Graph stats CSV file")
    parser.add_argument("--log-dir", type=Path, default=DEFAULT_LOG_DIR, help="Log directory")
    parser.add_argument("--output-dir", type=Path, help="Output directory for images")
    parser.add_argument("--all", action="store_true", help="Analyze all latest logs")

    args = parser.parse_args()

    output_dir = args.output_dir
    if output_dir:
        output_dir.mkdir(parents=True, exist_ok=True)

    analyzed = False

    if args.rssi:
        analyze_rssi_log(args.rssi, output_dir)
        analyzed = True

    if args.edges:
        analyze_edge_events(args.edges, output_dir)
        analyzed = True

    if args.stats:
        analyze_stats_log(args.stats, output_dir)
        analyzed = True

    if args.all or not analyzed:
        # 最新ログを自動検索
        log_dir = args.log_dir

        rssi_log = find_latest_log(log_dir, "rssi_log_")
        if rssi_log:
            analyze_rssi_log(rssi_log, output_dir)

        edge_log = find_latest_log(log_dir, "edge_events_")
        if edge_log:
            analyze_edge_events(edge_log, output_dir)

        stats_log = find_latest_log(log_dir, "graph_stats_")
        if stats_log:
            analyze_stats_log(stats_log, output_dir)

        if not rssi_log and not edge_log and not stats_log:
            print(f"No log files found in {log_dir}")
            sys.exit(1)


if __name__ == "__main__":
    main()
