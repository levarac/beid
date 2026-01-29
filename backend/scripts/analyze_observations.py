#!/usr/bin/env python3
"""
Beid Observation Analyzer - 各ユーザーが何人から観測されたかを分析

Usage:
    python analyze_observations.py                           # 最新のスナップショットを分析
    python analyze_observations.py --snapshot <file.jsonl>   # 特定のスナップショットを分析
    python analyze_observations.py --rssi <file.csv>         # RSSIログから分析
    python analyze_observations.py --event-code ABC123       # イベントコードでフィルタ
    python analyze_observations.py --same-event-only         # 同一イベント内の観測のみ
    python analyze_observations.py --output-dir ./results    # 結果を保存
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from datetime import datetime
from pathlib import Path
import sys
from typing import Optional

try:
    import pandas as pd
    import matplotlib.pyplot as plt
    import numpy as np
except ImportError:
    print("Required packages not found. Install with:")
    print("  pip install pandas matplotlib numpy")
    sys.exit(1)


DEFAULT_LOG_DIR = Path(__file__).parent.parent / "logs"
DEFAULT_SNAPSHOT_DIR = DEFAULT_LOG_DIR / "snapshots"


def load_snapshots_from_jsonl(filepath: Path) -> list[dict]:
    """JSONLファイルからスナップショットを読み込む"""
    snapshots = []
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if line:
                snapshots.append(json.loads(line))
    return snapshots


def analyze_from_snapshots(snapshots: list[dict], event_code: str | None = None) -> dict:
    """
    スナップショットから観測データを集計

    Args:
        snapshots: スナップショットのリスト
        event_code: フィルタするイベントコード（Noneの場合はフィルタなし）

    Returns:
        {
            'observed_by': {user_id: set(observer_ids)},  # 各ユーザーを観測した人
            'observing': {user_id: set(observed_ids)},     # 各ユーザーが観測した人
            'total_edges': int,
            'mutual_edges': int,
            'event_codes': set,  # 観測されたイベントコード一覧
            'user_event_codes': dict,  # ユーザー別イベントコード
        }
    """
    observed_by = defaultdict(set)  # 各ユーザーを観測した人のセット
    observing = defaultdict(set)    # 各ユーザーが観測した人のセット
    all_users = set()
    total_edges = 0
    mutual_edges = 0
    event_codes = set()
    user_event_codes = {}  # user_id -> event_code

    for snapshot in snapshots:
        edges = snapshot.get('edges', [])
        nodes = snapshot.get('nodes', [])
        node_event_codes = snapshot.get('node_event_codes', {})
        event_code_groups = snapshot.get('event_code_groups', {})

        # イベントコード情報を収集
        for code in event_code_groups.keys():
            if code:
                event_codes.add(code)

        for node_id, code in node_event_codes.items():
            if code:
                user_event_codes[node_id] = code

        # イベントコードでフィルタする対象ノードを決定
        if event_code:
            target_nodes = set(event_code_groups.get(event_code, []))
        else:
            target_nodes = None  # フィルタなし

        # ノードを追加（フィルタ適用）
        for node in nodes:
            if target_nodes is None or node in target_nodes:
                all_users.add(node)

        for edge in edges:
            source = edge.get('source')  # 観測者
            target = edge.get('target')  # 観測された人
            is_mutual = edge.get('mutual', False)

            if source and target:
                # イベントコードでフィルタ
                if target_nodes is not None:
                    if source not in target_nodes or target not in target_nodes:
                        continue

                observed_by[target].add(source)
                observing[source].add(target)
                all_users.add(source)
                all_users.add(target)
                total_edges += 1
                if is_mutual:
                    mutual_edges += 1

    return {
        'observed_by': dict(observed_by),
        'observing': dict(observing),
        'all_users': all_users,
        'total_edges': total_edges,
        'mutual_edges': mutual_edges,
        'event_codes': event_codes,
        'user_event_codes': user_event_codes,
    }


def analyze_from_rssi_csv(filepath: Path, event_code: str | None = None, same_event_only: bool = False) -> dict:
    """
    RSSI CSVログから観測データを集計

    Args:
        filepath: CSVファイルパス
        event_code: フィルタするイベントコード
        same_event_only: 同一イベント内の観測のみを対象とする
    """
    df = pd.read_csv(filepath)

    observed_by = defaultdict(set)
    observing = defaultdict(set)
    all_users = set()
    event_codes = set()
    user_event_codes = {}

    # イベントコード列があるか確認
    has_event_code = 'event_code' in df.columns
    has_same_event = 'is_same_event' in df.columns
    has_resolved_id = 'resolved_display_id' in df.columns

    for _, row in df.iterrows():
        reporter = row['reporter_id']
        detected = row['detected_id']
        row_event_code = row.get('event_code', None) if has_event_code else None
        is_same_event = row.get('is_same_event', False) if has_same_event else False
        resolved_id = row.get('resolved_display_id', None) if has_resolved_id else None

        # イベントコード情報を収集
        if row_event_code and pd.notna(row_event_code) and row_event_code != '':
            event_codes.add(row_event_code)
            user_event_codes[reporter] = row_event_code

        # イベントコードでフィルタ
        if event_code:
            if row_event_code != event_code:
                continue

        # 同一イベントのみフィルタ
        if same_event_only:
            if not is_same_event and not (resolved_id and pd.notna(resolved_id) and resolved_id != ''):
                continue

        observed_by[detected].add(reporter)
        observing[reporter].add(detected)
        all_users.add(reporter)
        all_users.add(detected)

    mutual_count = 0
    for _, row in df.iterrows():
        if row.get('is_mutual', False):
            # フィルタ条件を再チェック
            if event_code:
                row_event_code = row.get('event_code', None) if has_event_code else None
                if row_event_code != event_code:
                    continue
            if same_event_only:
                is_same_event = row.get('is_same_event', False) if has_same_event else False
                resolved_id = row.get('resolved_display_id', None) if has_resolved_id else None
                if not is_same_event and not (resolved_id and pd.notna(resolved_id) and resolved_id != ''):
                    continue
            mutual_count += 1

    return {
        'observed_by': dict(observed_by),
        'observing': dict(observing),
        'all_users': all_users,
        'total_edges': sum(len(v) for v in observed_by.values()),
        'mutual_edges': mutual_count,
        'event_codes': event_codes,
        'user_event_codes': user_event_codes,
    }


def print_observation_report(data: dict, title: str = "Observation Analysis"):
    """観測データのレポートを出力"""
    observed_by = data['observed_by']
    observing = data['observing']
    all_users = data['all_users']
    event_codes = data.get('event_codes', set())
    user_event_codes = data.get('user_event_codes', {})

    print(f"\n{'='*60}")
    print(f"  {title}")
    print(f"{'='*60}")

    print(f"\nTotal unique users: {len(all_users)}")
    print(f"Total edges: {data['total_edges']}")
    print(f"Mutual edges: {data['mutual_edges']}")

    # イベントコード情報を表示
    if event_codes:
        print(f"\n{'-'*60}")
        print("  Event Codes Found")
        print(f"{'-'*60}")
        for code in sorted(event_codes):
            users_in_event = [u for u, c in user_event_codes.items() if c == code]
            print(f"  {code}: {len(users_in_event)} users")

    # 各ユーザーが何人から観測されたか
    print(f"\n{'-'*60}")
    print("  Users observed by others (被観測数)")
    print(f"{'-'*60}")
    print(f"{'User ID':<12} {'Observed By':<12} {'Observers'}")
    print(f"{'-'*60}")

    # 被観測数でソート
    sorted_users = sorted(
        all_users,
        key=lambda u: len(observed_by.get(u, set())),
        reverse=True
    )

    for user in sorted_users:
        observers = observed_by.get(user, set())
        observer_count = len(observers)
        observer_list = ', '.join(sorted(observers)[:5])
        if len(observers) > 5:
            observer_list += f'... (+{len(observers)-5})'
        print(f"{user:<12} {observer_count:<12} {observer_list}")

    # 各ユーザーが何人を観測したか
    print(f"\n{'-'*60}")
    print("  Users observing others (観測数)")
    print(f"{'-'*60}")
    print(f"{'User ID':<12} {'Observing':<12} {'Observed Users'}")
    print(f"{'-'*60}")

    sorted_observers = sorted(
        all_users,
        key=lambda u: len(observing.get(u, set())),
        reverse=True
    )

    for user in sorted_observers:
        observed = observing.get(user, set())
        observed_count = len(observed)
        observed_list = ', '.join(sorted(observed)[:5])
        if len(observed) > 5:
            observed_list += f'... (+{len(observed)-5})'
        print(f"{user:<12} {observed_count:<12} {observed_list}")

    # 統計サマリー
    obs_counts = [len(observed_by.get(u, set())) for u in all_users]
    if obs_counts:
        print(f"\n{'-'*60}")
        print("  Statistics (被観測数)")
        print(f"{'-'*60}")
        print(f"  Mean:   {np.mean(obs_counts):.2f}")
        print(f"  Median: {np.median(obs_counts):.2f}")
        print(f"  Max:    {max(obs_counts)}")
        print(f"  Min:    {min(obs_counts)}")
        print(f"  Std:    {np.std(obs_counts):.2f}")


def plot_observation_chart(data: dict, output_path: Path | None = None, title: str = "Observation Analysis"):
    """観測データのグラフを作成"""
    observed_by = data['observed_by']
    observing = data['observing']
    all_users = data['all_users']

    fig, axes = plt.subplots(2, 2, figsize=(14, 10))
    fig.suptitle(title, fontsize=14, fontweight='bold')

    # 1. 被観測数の棒グラフ (何人から観測されたか)
    ax1 = axes[0, 0]
    users_sorted = sorted(all_users, key=lambda u: len(observed_by.get(u, set())), reverse=True)
    obs_counts = [len(observed_by.get(u, set())) for u in users_sorted]
    user_labels = [u[:8] for u in users_sorted]

    bars1 = ax1.bar(range(len(users_sorted)), obs_counts, color='steelblue', edgecolor='black')
    ax1.set_xticks(range(len(users_sorted)))
    ax1.set_xticklabels(user_labels, rotation=45, ha='right', fontsize=9)
    ax1.set_xlabel('User ID')
    ax1.set_ylabel('Number of Observers')
    ax1.set_title('How many users observed each user')

    # 値ラベル
    for bar, count in zip(bars1, obs_counts):
        if count > 0:
            ax1.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.1,
                    str(count), ha='center', va='bottom', fontsize=9)

    # 2. 観測数の棒グラフ (何人を観測したか)
    ax2 = axes[0, 1]
    users_sorted_obs = sorted(all_users, key=lambda u: len(observing.get(u, set())), reverse=True)
    observing_counts = [len(observing.get(u, set())) for u in users_sorted_obs]
    user_labels_obs = [u[:8] for u in users_sorted_obs]

    bars2 = ax2.bar(range(len(users_sorted_obs)), observing_counts, color='forestgreen', edgecolor='black')
    ax2.set_xticks(range(len(users_sorted_obs)))
    ax2.set_xticklabels(user_labels_obs, rotation=45, ha='right', fontsize=9)
    ax2.set_xlabel('User ID')
    ax2.set_ylabel('Number of Observed Users')
    ax2.set_title('How many users each user observed')

    for bar, count in zip(bars2, observing_counts):
        if count > 0:
            ax2.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.1,
                    str(count), ha='center', va='bottom', fontsize=9)

    # 3. 被観測数の分布ヒストグラム
    ax3 = axes[1, 0]
    ax3.hist(obs_counts, bins=max(1, max(obs_counts) - min(obs_counts) + 1) if obs_counts else 1,
             edgecolor='black', alpha=0.7, color='steelblue')
    ax3.set_xlabel('Number of Observers')
    ax3.set_ylabel('Number of Users')
    ax3.set_title('Distribution of Observation Counts')
    ax3.axvline(np.mean(obs_counts), color='red', linestyle='--', label=f'Mean: {np.mean(obs_counts):.1f}')
    ax3.legend()

    # 4. 観測関係マトリックス (小規模な場合のみ)
    ax4 = axes[1, 1]
    if len(all_users) <= 15:
        users_list = sorted(all_users)
        matrix = np.zeros((len(users_list), len(users_list)))

        for i, observer in enumerate(users_list):
            for j, observed_user in enumerate(users_list):
                if observed_user in observing.get(observer, set()):
                    matrix[i, j] = 1

        im = ax4.imshow(matrix, cmap='Blues', aspect='auto')
        ax4.set_xticks(range(len(users_list)))
        ax4.set_yticks(range(len(users_list)))
        ax4.set_xticklabels([u[:6] for u in users_list], rotation=45, ha='right', fontsize=8)
        ax4.set_yticklabels([u[:6] for u in users_list], fontsize=8)
        ax4.set_xlabel('Observed User')
        ax4.set_ylabel('Observer')
        ax4.set_title('Observation Matrix (row observes column)')
        plt.colorbar(im, ax=ax4, shrink=0.8)
    else:
        # ユーザー数が多い場合は散布図
        ax4.scatter(obs_counts, observing_counts, alpha=0.6, s=100, c='purple', edgecolors='black')
        for i, user in enumerate(users_sorted):
            ax4.annotate(user[:6], (obs_counts[i], observing_counts[i]), fontsize=8, alpha=0.7)
        ax4.set_xlabel('Observed By')
        ax4.set_ylabel('Observing')
        ax4.set_title('Observation Balance per User')
        ax4.plot([0, max(max(obs_counts), max(observing_counts))],
                [0, max(max(obs_counts), max(observing_counts))],
                'r--', alpha=0.5, label='Balanced line')
        ax4.legend()

    plt.tight_layout()

    if output_path:
        plt.savefig(output_path, dpi=150, bbox_inches='tight')
        print(f"\nChart saved: {output_path}")
    else:
        plt.show()


def find_latest_snapshot(snapshot_dir: Path) -> Path | None:
    """最新のスナップショットファイルを検索"""
    files = sorted(snapshot_dir.glob("snapshots_*.jsonl"), reverse=True)
    return files[0] if files else None


def find_latest_rssi_log(log_dir: Path) -> Path | None:
    """最新のRSSIログを検索"""
    files = sorted(log_dir.glob("rssi_log_*.csv"), reverse=True)
    return files[0] if files else None


def main():
    parser = argparse.ArgumentParser(description="Analyze user observation patterns")

    parser.add_argument("--snapshot", type=Path, help="Snapshot JSONL file")
    parser.add_argument("--rssi", type=Path, help="RSSI log CSV file")
    parser.add_argument("--log-dir", type=Path, default=DEFAULT_LOG_DIR, help="Log directory")
    parser.add_argument("--output-dir", type=Path, help="Output directory for results")
    parser.add_argument("--event-code", type=str, help="Filter by event code")
    parser.add_argument("--same-event-only", action="store_true", help="Only include same-event observations")
    parser.add_argument("--no-plot", action="store_true", help="Skip plotting")

    args = parser.parse_args()

    output_dir = args.output_dir
    if output_dir:
        output_dir.mkdir(parents=True, exist_ok=True)

    data = None
    source_name = ""
    filter_info = ""

    if args.event_code:
        filter_info = f" [Event: {args.event_code}]"
    elif args.same_event_only:
        filter_info = " [Same Event Only]"

    if args.snapshot:
        print(f"Loading snapshot: {args.snapshot}")
        snapshots = load_snapshots_from_jsonl(args.snapshot)
        data = analyze_from_snapshots(snapshots, event_code=args.event_code)
        source_name = args.snapshot.stem
    elif args.rssi:
        print(f"Loading RSSI log: {args.rssi}")
        data = analyze_from_rssi_csv(args.rssi, event_code=args.event_code, same_event_only=args.same_event_only)
        source_name = args.rssi.stem
    else:
        # 最新のスナップショットを自動検索
        snapshot_dir = args.log_dir / "snapshots"
        latest = find_latest_snapshot(snapshot_dir)

        if latest:
            print(f"Using latest snapshot: {latest}")
            snapshots = load_snapshots_from_jsonl(latest)
            data = analyze_from_snapshots(snapshots, event_code=args.event_code)
            source_name = latest.stem
        else:
            # スナップショットがなければRSSIログを検索
            latest_rssi = find_latest_rssi_log(args.log_dir)
            if latest_rssi:
                print(f"Using latest RSSI log: {latest_rssi}")
                data = analyze_from_rssi_csv(latest_rssi, event_code=args.event_code, same_event_only=args.same_event_only)
                source_name = latest_rssi.stem
            else:
                print(f"No snapshot or RSSI log files found in {args.log_dir}")
                sys.exit(1)

    if not data or not data['all_users']:
        print("No observation data found")
        sys.exit(1)

    # レポート出力
    title = f"Observation Analysis - {source_name}{filter_info}"
    print_observation_report(data, title)

    # グラフ出力
    if not args.no_plot:
        output_path = None
        if output_dir:
            timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            output_path = output_dir / f"observation_analysis_{timestamp}.png"

        plot_observation_chart(data, output_path, title)


if __name__ == "__main__":
    main()
