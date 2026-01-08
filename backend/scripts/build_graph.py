#!/usr/bin/env python3
"""
Beid Graph Builder - BLEセンシングデータから無向グラフを構築・分析・可視化

Usage:
    python build_graph.py                           # 最新スナップショットからグラフ構築
    python build_graph.py --snapshot <filename>     # 特定のスナップショットを使用
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


def load_snapshot(filepath: Path) -> dict:
    """スナップショットJSONを読み込む"""
    with open(filepath, "r") as f:
        return json.load(f)


def get_latest_snapshot(snapshot_dir: Path) -> Path | None:
    """最新のスナップショットファイルを取得"""
    if not snapshot_dir.exists():
        return None

    snapshots = sorted(snapshot_dir.glob("snapshot_*.json"), reverse=True)
    return snapshots[0] if snapshots else None


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
    source_group.add_argument("--snapshot", type=Path, help="Path to snapshot JSON file")
    source_group.add_argument("--csv", type=Path, help="Path to edge_events CSV file")
    source_group.add_argument("--live", action="store_true", help="Fetch current graph from API")

    # オプション
    parser.add_argument("--api-url", type=str, default=DEFAULT_API_URL, help="API base URL (for --live)")
    parser.add_argument("--log-dir", type=Path, default=DEFAULT_LOG_DIR, help="Log directory path")
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
        data = load_snapshot(args.snapshot)
        G = build_graph_from_snapshot(data, mutual_only)
        title = f"Graph from {args.snapshot.name}"

    else:
        # デフォルト: 最新スナップショット
        snapshot_dir = args.log_dir / "snapshots"
        latest = get_latest_snapshot(snapshot_dir)

        if latest:
            print(f"Loading latest snapshot: {latest}")
            data = load_snapshot(latest)
            G = build_graph_from_snapshot(data, mutual_only)
            title = f"Graph from {latest.name}"
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
