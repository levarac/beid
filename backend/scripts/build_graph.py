#!/usr/bin/env python3
"""
Beid Graph Builder - BLEセンシングデータから無向グラフを構築・分析・可視化

Usage:
    python build_graph.py                           # 最新スナップショットからグラフ構築
    python build_graph.py --snapshot <file>         # 特定のスナップショットを使用（JSON/JSONL対応）
    python build_graph.py --snapshot <file.jsonl> --index 5   # JSONL内の特定インデックスを使用
    python build_graph.py --list <file.jsonl>       # JSONLファイル内のスナップショット一覧を表示
    python build_graph.py --timeline <file.jsonl>   # スナップショットの時系列グラフを表示
    python build_graph.py --csv <edge_events.csv>   # エッジイベントCSVから構築
    python build_graph.py --live                    # APIからリアルタイム取得
    python build_graph.py --output graph.gexf       # グラフをファイルに出力
"""

import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path

try:
    import networkx as nx
    import matplotlib.pyplot as plt
    import matplotlib.dates as mdates
    import pandas as pd
except ImportError:
    print("Required packages not found. Install with:")
    print("  pip install networkx matplotlib pandas requests")
    sys.exit(1)

try:
    import requests
    HAS_REQUESTS = True
except ImportError:
    HAS_REQUESTS = False


# デフォルトパス
DEFAULT_LOG_DIR = Path(__file__).parent.parent / "logs"
DEFAULT_SNAPSHOT_DIR = DEFAULT_LOG_DIR / "snapshots"
DEFAULT_API_URL = "http://localhost:3000"


def load_snapshot(filepath: Path, index: int = -1) -> dict:
    """スナップショットを読み込む（JSON/JSONL両対応）

    Args:
        filepath: ファイルパス
        index: JSONLの場合、どのスナップショットを読むか（-1で最新）

    Returns:
        スナップショットデータ
    """
    if filepath.suffix == ".jsonl":
        return load_jsonl_snapshot(filepath, index)
    else:
        with open(filepath, "r") as f:
            return json.load(f)


def load_jsonl_snapshot(filepath: Path, index: int = -1) -> dict:
    """JSONLファイルから指定インデックスのスナップショットを読み込む

    Args:
        filepath: JSONLファイルパス
        index: 読み込むスナップショットのインデックス（-1で最新）

    Returns:
        スナップショットデータ
    """
    with open(filepath, "r") as f:
        lines = [line.strip() for line in f if line.strip()]

    if not lines:
        raise ValueError(f"Empty JSONL file: {filepath}")

    if index < 0:
        index = len(lines) + index

    if index < 0 or index >= len(lines):
        raise ValueError(f"Index {index} out of range (0-{len(lines)-1})")

    return json.loads(lines[index])


def load_all_snapshots(filepath: Path) -> list[dict]:
    """JSONLファイルから全スナップショットを読み込む

    Args:
        filepath: JSONLファイルパス

    Returns:
        スナップショットデータのリスト
    """
    if filepath.suffix == ".jsonl":
        with open(filepath, "r") as f:
            return [json.loads(line) for line in f if line.strip()]
    else:
        # 単一JSONファイルの場合はリストで返す
        with open(filepath, "r") as f:
            return [json.load(f)]


def get_latest_snapshot(snapshot_dir: Path) -> Path | None:
    """最新のスナップショットファイルを取得（JSONL優先）"""
    if not snapshot_dir.exists():
        return None

    # 新形式（JSONL）を優先
    jsonl_files = sorted(snapshot_dir.glob("snapshots_*.jsonl"), reverse=True)
    if jsonl_files:
        return jsonl_files[0]

    # 旧形式（JSON）にフォールバック
    json_files = sorted(snapshot_dir.glob("snapshot_*.json"), reverse=True)
    return json_files[0] if json_files else None


def list_snapshots_in_file(filepath: Path) -> list[dict]:
    """ファイル内のスナップショット一覧を取得

    Returns:
        各スナップショットのサマリ情報リスト
    """
    snapshots = load_all_snapshots(filepath)
    return [
        {
            "index": i,
            "timestamp": s.get("timestamp"),
            "snapshot_id": s.get("snapshot_id"),
            "node_count": s.get("node_count"),
            "edge_count": s.get("edge_count"),
        }
        for i, s in enumerate(snapshots)
    ]


def visualize_timeline(filepath: Path, output_path: Path | None = None):
    """スナップショットの時系列グラフを作成

    Args:
        filepath: JSONLファイルパス
        output_path: 出力画像パス（Noneの場合は表示）
    """
    print(f"Loading snapshots from: {filepath}")
    snapshots = load_all_snapshots(filepath)

    if not snapshots:
        print("No snapshots found")
        return

    print(f"Found {len(snapshots)} snapshots")

    # DataFrameに変換
    data = []
    for s in snapshots:
        stats = s.get("statistics", {})
        data.append({
            "timestamp": pd.to_datetime(s.get("timestamp")),
            "node_count": s.get("node_count", 0),
            "edge_count": s.get("edge_count", 0),
            "mutual_edge_count": s.get("mutual_edge_count", 0),
            "density": stats.get("density", 0),
            "avg_rssi": stats.get("avg_rssi"),
            "avg_distance": stats.get("avg_distance"),
            "avg_degree": stats.get("avg_degree", 0),
            "max_degree": stats.get("max_degree", 0),
            "connected_components": stats.get("connected_components", 0),
            "is_connected": stats.get("is_connected", False),
        })

    df = pd.DataFrame(data)
    df = df.sort_values("timestamp")

    # 可視化
    fig, axes = plt.subplots(3, 2, figsize=(14, 12))
    fig.suptitle(f"Graph Timeline: {filepath.name}", fontsize=14, fontweight="bold")

    # 1. ノード・エッジ数の推移
    ax1 = axes[0, 0]
    ax1.plot(df["timestamp"], df["node_count"], label="Nodes", color="blue", marker="o", markersize=3)
    ax1.plot(df["timestamp"], df["edge_count"], label="Edges", color="green", marker="s", markersize=3)
    ax1.plot(df["timestamp"], df["mutual_edge_count"], label="Mutual Edges", color="orange", marker="^", markersize=3)
    ax1.set_xlabel("Time")
    ax1.set_ylabel("Count")
    ax1.set_title("Graph Size over Time")
    ax1.legend()
    ax1.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M:%S"))
    ax1.tick_params(axis="x", rotation=45)
    ax1.grid(True, alpha=0.3)

    # 2. 密度の推移
    ax2 = axes[0, 1]
    ax2.plot(df["timestamp"], df["density"], color="purple", marker="o", markersize=3)
    ax2.fill_between(df["timestamp"], df["density"], alpha=0.3, color="purple")
    ax2.set_xlabel("Time")
    ax2.set_ylabel("Density")
    ax2.set_title("Graph Density over Time")
    ax2.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M:%S"))
    ax2.tick_params(axis="x", rotation=45)
    ax2.set_ylim(0, max(1, df["density"].max() * 1.1))
    ax2.grid(True, alpha=0.3)

    # 3. 平均RSSI
    ax3 = axes[1, 0]
    rssi_valid = df[df["avg_rssi"].notna()]
    if len(rssi_valid) > 0:
        ax3.plot(rssi_valid["timestamp"], rssi_valid["avg_rssi"], color="red", marker="o", markersize=3)
        ax3.fill_between(rssi_valid["timestamp"], rssi_valid["avg_rssi"], alpha=0.3, color="red")
    ax3.set_xlabel("Time")
    ax3.set_ylabel("RSSI (dBm)")
    ax3.set_title("Average RSSI over Time")
    ax3.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M:%S"))
    ax3.tick_params(axis="x", rotation=45)
    ax3.grid(True, alpha=0.3)

    # 4. 平均距離
    ax4 = axes[1, 1]
    dist_valid = df[df["avg_distance"].notna()]
    if len(dist_valid) > 0:
        ax4.plot(dist_valid["timestamp"], dist_valid["avg_distance"], color="teal", marker="o", markersize=3)
        ax4.fill_between(dist_valid["timestamp"], dist_valid["avg_distance"], alpha=0.3, color="teal")
    ax4.set_xlabel("Time")
    ax4.set_ylabel("Distance (m)")
    ax4.set_title("Average Distance over Time")
    ax4.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M:%S"))
    ax4.tick_params(axis="x", rotation=45)
    ax4.grid(True, alpha=0.3)

    # 5. 次数（平均・最大）
    ax5 = axes[2, 0]
    ax5.plot(df["timestamp"], df["avg_degree"], label="Avg Degree", color="navy", marker="o", markersize=3)
    ax5.plot(df["timestamp"], df["max_degree"], label="Max Degree", color="darkred", marker="s", markersize=3)
    ax5.set_xlabel("Time")
    ax5.set_ylabel("Degree")
    ax5.set_title("Node Degree over Time")
    ax5.legend()
    ax5.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M:%S"))
    ax5.tick_params(axis="x", rotation=45)
    ax5.grid(True, alpha=0.3)

    # 6. 連結成分数
    ax6 = axes[2, 1]
    ax6.plot(df["timestamp"], df["connected_components"], color="brown", marker="o", markersize=3)
    # 連結グラフの場合は背景色を変更
    for i in range(len(df) - 1):
        if df.iloc[i]["is_connected"]:
            ax6.axvspan(df.iloc[i]["timestamp"], df.iloc[i + 1]["timestamp"], alpha=0.2, color="green")
    ax6.set_xlabel("Time")
    ax6.set_ylabel("Components")
    ax6.set_title("Connected Components over Time (green = fully connected)")
    ax6.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M:%S"))
    ax6.tick_params(axis="x", rotation=45)
    ax6.yaxis.set_major_locator(plt.MaxNLocator(integer=True))
    ax6.grid(True, alpha=0.3)

    plt.tight_layout()

    if output_path:
        plt.savefig(output_path, dpi=150, bbox_inches="tight")
        print(f"Timeline visualization saved to: {output_path}")
    else:
        plt.show()

    # サマリ表示
    print("\n" + "=" * 60)
    print("TIMELINE SUMMARY")
    print("=" * 60)
    print(f"Time range:     {df['timestamp'].min()} to {df['timestamp'].max()}")
    print(f"Duration:       {df['timestamp'].max() - df['timestamp'].min()}")
    print(f"Snapshots:      {len(df)}")
    print(f"\nNode count:     {df['node_count'].min()} - {df['node_count'].max()} (avg: {df['node_count'].mean():.1f})")
    print(f"Edge count:     {df['edge_count'].min()} - {df['edge_count'].max()} (avg: {df['edge_count'].mean():.1f})")
    print(f"Density:        {df['density'].min():.4f} - {df['density'].max():.4f} (avg: {df['density'].mean():.4f})")
    if len(rssi_valid) > 0:
        print(f"Avg RSSI:       {rssi_valid['avg_rssi'].min():.1f} - {rssi_valid['avg_rssi'].max():.1f} dBm")
    if len(dist_valid) > 0:
        print(f"Avg Distance:   {dist_valid['avg_distance'].min():.2f} - {dist_valid['avg_distance'].max():.2f} m")
    print(f"Fully connected: {df['is_connected'].sum()} / {len(df)} snapshots ({df['is_connected'].mean() * 100:.1f}%)")
    print("=" * 60)


def fetch_graph_from_api(api_url: str) -> dict:
    """APIから現在のグラフ状態を取得"""
    if not HAS_REQUESTS:
        raise ImportError("requests package required for --live mode")

    response = requests.get(f"{api_url}/api/graph/current")
    response.raise_for_status()
    return response.json()


def load_edge_events_csv(filepath: Path) -> pd.DataFrame:
    """エッジイベントCSVを読み込む"""
    return pd.read_csv(filepath)


def build_graph_from_snapshot(data: dict, mutual_only: bool = True) -> nx.Graph:
    """スナップショットデータからNetworkXグラフを構築"""
    G = nx.Graph()

    # ノード追加
    for node_id in data.get("nodes", []):
        G.add_node(node_id)

    # エッジ追加
    for edge in data.get("edges", []):
        if mutual_only and not edge.get("mutual", False):
            continue

        G.add_edge(
            edge["source"],
            edge["target"],
            rssi_avg=edge.get("rssi_avg"),
            rssi_a_to_b=edge.get("rssi_a_to_b"),
            rssi_b_to_a=edge.get("rssi_b_to_a"),
            distance=edge.get("distance"),
            mutual=edge.get("mutual", False)
        )

    return G


def build_graph_from_edge_csv(df: pd.DataFrame, mutual_only: bool = True) -> nx.Graph:
    """エッジイベントCSVから最終状態のグラフを構築"""
    G = nx.Graph()

    # 最新のエッジ状態を取得（dissolvedを除く）
    latest_edges = {}

    for _, row in df.iterrows():
        key = tuple(sorted([row["node_a"], row["node_b"]]))
        event_type = row["event_type"]

        if event_type == "edge_dissolved":
            latest_edges.pop(key, None)
        else:
            latest_edges[key] = row

    # グラフに追加
    for (node_a, node_b), row in latest_edges.items():
        if mutual_only and not row.get("mutual", False):
            continue

        G.add_node(node_a)
        G.add_node(node_b)
        G.add_edge(
            node_a,
            node_b,
            rssi_avg=row.get("rssi_avg"),
            distance=row.get("distance_estimate"),
            mutual=row.get("mutual", False)
        )

    return G


def analyze_graph(G: nx.Graph) -> dict:
    """グラフの統計情報を計算"""
    stats = {
        "node_count": G.number_of_nodes(),
        "edge_count": G.number_of_edges(),
        "density": nx.density(G) if G.number_of_nodes() > 1 else 0,
        "is_connected": nx.is_connected(G) if G.number_of_nodes() > 0 else False,
        "connected_components": nx.number_connected_components(G),
    }

    if G.number_of_nodes() > 0:
        degrees = dict(G.degree())
        stats["avg_degree"] = sum(degrees.values()) / len(degrees)
        stats["max_degree"] = max(degrees.values())
        stats["min_degree"] = min(degrees.values())
        stats["degree_distribution"] = dict(sorted(degrees.items(), key=lambda x: x[1], reverse=True))

    if stats["is_connected"] and G.number_of_nodes() > 1:
        stats["diameter"] = nx.diameter(G)
        stats["radius"] = nx.radius(G)
        stats["center"] = list(nx.center(G))

    # RSSI統計
    rssi_values = [d.get("rssi_avg") for _, _, d in G.edges(data=True) if d.get("rssi_avg")]
    if rssi_values:
        stats["rssi_avg"] = sum(rssi_values) / len(rssi_values)
        stats["rssi_min"] = min(rssi_values)
        stats["rssi_max"] = max(rssi_values)

    # 距離統計
    distances = [d.get("distance") for _, _, d in G.edges(data=True) if d.get("distance")]
    if distances:
        stats["distance_avg"] = sum(distances) / len(distances)
        stats["distance_min"] = min(distances)
        stats["distance_max"] = max(distances)

    return stats


def visualize_graph(G: nx.Graph, output_path: Path | None = None, title: str = "BLE Sensing Graph"):
    """グラフを可視化"""
    if G.number_of_nodes() == 0:
        print("No nodes in graph, skipping visualization")
        return

    plt.figure(figsize=(12, 8))

    # レイアウト計算
    if G.number_of_nodes() <= 10:
        pos = nx.spring_layout(G, k=2, iterations=50)
    else:
        pos = nx.kamada_kawai_layout(G)

    # エッジの太さ（RSSIベース）
    edge_widths = []
    edge_colors = []
    for u, v, d in G.edges(data=True):
        rssi = d.get("rssi_avg", -70)
        # RSSI -40 to -100 -> width 3 to 0.5
        width = max(0.5, min(3, (rssi + 100) / 20))
        edge_widths.append(width)

        # 相互検知は青、片方向は灰色
        color = "#2196F3" if d.get("mutual", False) else "#9E9E9E"
        edge_colors.append(color)

    # ノードサイズ（次数ベース）
    node_sizes = [300 + 100 * G.degree(n) for n in G.nodes()]

    # 描画
    nx.draw_networkx_edges(G, pos, width=edge_widths, edge_color=edge_colors, alpha=0.7)
    nx.draw_networkx_nodes(G, pos, node_size=node_sizes, node_color="#4CAF50", alpha=0.9)
    nx.draw_networkx_labels(G, pos, font_size=8, font_weight="bold")

    # エッジラベル（距離）
    edge_labels = {}
    for u, v, d in G.edges(data=True):
        dist = d.get("distance")
        if dist:
            edge_labels[(u, v)] = f"{dist:.1f}m"
    nx.draw_networkx_edge_labels(G, pos, edge_labels, font_size=6, alpha=0.7)

    plt.title(title)
    plt.axis("off")
    plt.tight_layout()

    if output_path:
        plt.savefig(output_path, dpi=150, bbox_inches="tight")
        print(f"Graph visualization saved to: {output_path}")
    else:
        plt.show()


def export_graph(G: nx.Graph, output_path: Path):
    """グラフを各種形式でエクスポート"""
    suffix = output_path.suffix.lower()

    if suffix == ".gexf":
        nx.write_gexf(G, output_path)
    elif suffix == ".graphml":
        nx.write_graphml(G, output_path)
    elif suffix == ".json":
        data = nx.node_link_data(G)
        with open(output_path, "w") as f:
            json.dump(data, f, indent=2)
    elif suffix == ".edgelist":
        nx.write_edgelist(G, output_path)
    elif suffix == ".adjlist":
        nx.write_adjlist(G, output_path)
    else:
        raise ValueError(f"Unsupported format: {suffix}")

    print(f"Graph exported to: {output_path}")


def export_adjacency_matrix(G: nx.Graph, output_path: Path):
    """隣接行列をCSVでエクスポート"""
    nodes = sorted(G.nodes())
    matrix = nx.to_numpy_array(G, nodelist=nodes)

    df = pd.DataFrame(matrix, index=nodes, columns=nodes)
    df.to_csv(output_path)
    print(f"Adjacency matrix exported to: {output_path}")


def print_stats(stats: dict):
    """統計情報を表示"""
    print("\n" + "=" * 50)
    print("GRAPH STATISTICS")
    print("=" * 50)
    print(f"Nodes:              {stats['node_count']}")
    print(f"Edges:              {stats['edge_count']}")
    print(f"Density:            {stats['density']:.4f}")
    print(f"Connected:          {stats['is_connected']}")
    print(f"Components:         {stats['connected_components']}")

    if "avg_degree" in stats:
        print(f"Avg Degree:         {stats['avg_degree']:.2f}")
        print(f"Max Degree:         {stats['max_degree']}")
        print(f"Min Degree:         {stats['min_degree']}")

    if "diameter" in stats:
        print(f"Diameter:           {stats['diameter']}")
        print(f"Radius:             {stats['radius']}")
        print(f"Center:             {', '.join(stats['center'])}")

    if "rssi_avg" in stats:
        print(f"\nRSSI (avg/min/max): {stats['rssi_avg']:.1f} / {stats['rssi_min']:.1f} / {stats['rssi_max']:.1f} dBm")

    if "distance_avg" in stats:
        print(f"Distance (avg/min/max): {stats['distance_avg']:.2f} / {stats['distance_min']:.2f} / {stats['distance_max']:.2f} m")

    if "degree_distribution" in stats:
        print("\nDegree Distribution:")
        for node, degree in stats["degree_distribution"].items():
            print(f"  {node}: {degree}")

    print("=" * 50)


def main():
    parser = argparse.ArgumentParser(description="Build and analyze graphs from BLE sensing data")

    # 入力ソース
    source_group = parser.add_mutually_exclusive_group()
    source_group.add_argument("--snapshot", type=Path, help="Path to snapshot file (JSON or JSONL)")
    source_group.add_argument("--csv", type=Path, help="Path to edge_events CSV file")
    source_group.add_argument("--live", action="store_true", help="Fetch current graph from API")
    source_group.add_argument("--list", type=Path, help="List snapshots in a JSONL file")
    source_group.add_argument("--timeline", type=Path, help="Show timeline graph from JSONL file")

    # オプション
    parser.add_argument("--api-url", type=str, default=DEFAULT_API_URL, help="API base URL (for --live)")
    parser.add_argument("--log-dir", type=Path, default=DEFAULT_LOG_DIR, help="Log directory path")
    parser.add_argument("--index", type=int, default=-1, help="Snapshot index in JSONL file (-1 for latest)")
    parser.add_argument("--include-unilateral", action="store_true", help="Include non-mutual edges")
    parser.add_argument("--no-visualize", action="store_true", help="Skip visualization")
    parser.add_argument("--no-stats", action="store_true", help="Skip statistics output")

    # 出力
    parser.add_argument("--output", "-o", type=Path, help="Export graph to file (gexf, graphml, json)")
    parser.add_argument("--output-image", type=Path, help="Save visualization to image file")
    parser.add_argument("--output-matrix", type=Path, help="Export adjacency matrix to CSV")
    parser.add_argument("--output-stats", type=Path, help="Export statistics to JSON")

    args = parser.parse_args()

    mutual_only = not args.include_unilateral

    # --list オプション: スナップショット一覧を表示
    if args.list:
        print(f"Listing snapshots in: {args.list}")
        try:
            summaries = list_snapshots_in_file(args.list)
            print(f"\nFound {len(summaries)} snapshots:\n")
            print(f"{'Index':>6}  {'Timestamp':<26}  {'Nodes':>6}  {'Edges':>6}  Snapshot ID")
            print("-" * 80)
            for s in summaries:
                print(f"{s['index']:>6}  {s['timestamp'] or 'N/A':<26}  {s['node_count'] or 0:>6}  {s['edge_count'] or 0:>6}  {s['snapshot_id'] or 'N/A'}")
        except Exception as e:
            print(f"Error: {e}")
            sys.exit(1)
        return

    # --timeline オプション: 時系列グラフを表示
    if args.timeline:
        try:
            visualize_timeline(args.timeline, args.output_image)
        except Exception as e:
            print(f"Error: {e}")
            sys.exit(1)
        return

    # グラフ構築
    print("Loading graph data...")

    if args.live:
        print(f"Fetching from API: {args.api_url}")
        data = fetch_graph_from_api(args.api_url)
        G = build_graph_from_snapshot(data, mutual_only)
        title = f"Live Graph ({datetime.now().strftime('%Y-%m-%d %H:%M:%S')})"

    elif args.csv:
        print(f"Loading CSV: {args.csv}")
        df = load_edge_events_csv(args.csv)
        G = build_graph_from_edge_csv(df, mutual_only)
        title = f"Graph from {args.csv.name}"

    elif args.snapshot:
        print(f"Loading snapshot: {args.snapshot}")
        if args.snapshot.suffix == ".jsonl":
            print(f"  (JSONL file, using index {args.index})")
        data = load_snapshot(args.snapshot, args.index)
        G = build_graph_from_snapshot(data, mutual_only)
        snapshot_id = data.get("snapshot_id", args.snapshot.name)
        title = f"Graph from {snapshot_id}"

    else:
        # デフォルト: 最新スナップショット
        snapshot_dir = args.log_dir / "snapshots"
        latest = get_latest_snapshot(snapshot_dir)

        if latest:
            print(f"Loading latest snapshot: {latest}")
            if latest.suffix == ".jsonl":
                print(f"  (JSONL file, using index {args.index})")
            data = load_snapshot(latest, args.index)
            G = build_graph_from_snapshot(data, mutual_only)
            snapshot_id = data.get("snapshot_id", latest.name)
            title = f"Graph from {snapshot_id}"
        else:
            print(f"No snapshots found in {snapshot_dir}")
            print("Use --live to fetch from API, or --csv/--snapshot to specify a file")
            sys.exit(1)

    print(f"Graph built: {G.number_of_nodes()} nodes, {G.number_of_edges()} edges")

    # 統計分析
    if not args.no_stats:
        stats = analyze_graph(G)
        print_stats(stats)

        if args.output_stats:
            with open(args.output_stats, "w") as f:
                json.dump(stats, f, indent=2, default=str)
            print(f"Statistics exported to: {args.output_stats}")

    # エクスポート
    if args.output:
        export_graph(G, args.output)

    if args.output_matrix:
        export_adjacency_matrix(G, args.output_matrix)

    # 可視化
    if not args.no_visualize:
        visualize_graph(G, args.output_image, title)


if __name__ == "__main__":
    main()
