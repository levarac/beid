# Beid Graph Analysis Scripts

BLEセンシングデータからグラフを構築・分析・可視化するPythonスクリプト集。

## セットアップ

```bash
cd backend/scripts
pip install -r requirements.txt
```

## スクリプト一覧

| スクリプト | 説明 |
|------------|------|
| `build_graph.py` | グラフ構築・可視化・エクスポート |
| `analyze_timeline.py` | ログの時系列分析・可視化 |

---

## build_graph.py

センシングデータから無向グラフを構築し、分析・可視化・エクスポートを行う。

### 基本的な使い方

```bash
# 最新スナップショットからグラフ構築（デフォルト）
python build_graph.py

# APIからリアルタイムでグラフ取得
python build_graph.py --live

# 特定のスナップショットを使用
python build_graph.py --snapshot ../logs/snapshots/snapshot_2026-01-08T10-00-00-000Z.json

# エッジイベントCSVからグラフ構築
python build_graph.py --csv ../logs/edge_events_2026-01-08_1234567890.csv
```

### オプション

| オプション | 説明 |
|------------|------|
| `--snapshot <file>` | スナップショットJSONを指定 |
| `--csv <file>` | エッジイベントCSVを指定 |
| `--live` | APIから現在のグラフを取得 |
| `--api-url <url>` | APIのURL（デフォルト: http://localhost:3000） |
| `--include-unilateral` | 片方向エッジも含める（デフォルトは相互検知のみ） |
| `--no-visualize` | 可視化をスキップ |
| `--no-stats` | 統計出力をスキップ |

### エクスポート

```bash
# GEXF形式（Gephiで開ける）
python build_graph.py --output graph.gexf

# GraphML形式
python build_graph.py --output graph.graphml

# JSON形式（NetworkX node-link format）
python build_graph.py --output graph.json

# 隣接行列をCSV出力
python build_graph.py --output-matrix adjacency.csv

# 可視化を画像保存
python build_graph.py --output-image graph.png

# 統計をJSON出力
python build_graph.py --output-stats stats.json
```

### 出力例

```
Loading graph data...
Loading latest snapshot: ../logs/snapshots/snapshot_2026-01-08T10-00-00-000Z.json
Graph built: 5 nodes, 8 edges

==================================================
GRAPH STATISTICS
==================================================
Nodes:              5
Edges:              8
Density:            0.8000
Connected:          True
Components:         1
Avg Degree:         3.20
Max Degree:         4
Min Degree:         2
Diameter:           2
Radius:             1
Center:             user-c

RSSI (avg/min/max): -65.5 / -72.0 / -58.0 dBm
Distance (avg/min/max): 2.34 / 1.12 / 4.56 m

Degree Distribution:
  user-c: 4
  user-a: 3
  user-b: 3
  user-d: 2
  user-e: 2
==================================================
```

---

## analyze_timeline.py

ログファイルの時系列分析と可視化を行う。

### 基本的な使い方

```bash
# 全ログを自動検出して分析
python analyze_timeline.py --all

# RSSIログを分析
python analyze_timeline.py --rssi ../logs/rssi_log_2026-01-08_1234567890.csv

# エッジイベントを分析
python analyze_timeline.py --edges ../logs/edge_events_2026-01-08_1234567890.csv

# 統計ログを分析
python analyze_timeline.py --stats ../logs/graph_stats_2026-01-08_1234567890.csv
```

### オプション

| オプション | 説明 |
|------------|------|
| `--rssi <file>` | RSSIログCSVを指定 |
| `--edges <file>` | エッジイベントCSVを指定 |
| `--stats <file>` | 統計ログCSVを指定 |
| `--log-dir <dir>` | ログディレクトリ（デフォルト: ../logs） |
| `--output-dir <dir>` | 画像出力先ディレクトリ |
| `--all` | 全ログを分析 |

### 出力例（RSSIログ分析）

```
Analyzing RSSI log: ../logs/rssi_log_2026-01-08_1234567890.csv
  Records: 1523
  Time range: 2026-01-08 10:00:00 to 2026-01-08 10:30:00
  Unique reporters: 5
  Unique detected: 5

  RSSI Statistics:
    Mean: -65.23 dBm
    Std:  8.45 dBm
    Min:  -92 dBm
    Max:  -48 dBm

  Mutual detection rate: 78.5%
```

### 生成されるグラフ

**RSSIログ分析:**
- RSSI時系列（ユーザー別）
- RSSI分布ヒストグラム
- 距離推定分布
- レポート頻度

**エッジイベント分析:**
- イベントタイムライン
- イベントタイプ分布
- エッジRSSI推移
- エッジ持続時間分布

**統計ログ分析:**
- ノード・エッジ数推移
- グラフ密度推移
- 平均RSSI・距離推移
- 連結成分数推移

---

## 使用例

### グラフをGephiで可視化

```bash
# GEXFファイルを生成
python build_graph.py --live --output sensing_graph.gexf

# Gephiで開く
open sensing_graph.gexf  # macOS
```

### 定期的なスナップショット分析

```bash
# 全スナップショットを処理
for f in ../logs/snapshots/snapshot_*.json; do
    python build_graph.py --snapshot "$f" --no-visualize --output-stats "${f%.json}_stats.json"
done
```

### レポート生成

```bash
# 出力ディレクトリを作成
mkdir -p reports

# グラフ画像と統計を生成
python build_graph.py --live \
    --output-image reports/graph.png \
    --output-stats reports/stats.json \
    --output reports/graph.gexf

# 時系列分析
python analyze_timeline.py --all --output-dir reports/
```

---

## トラブルシューティング

### `No snapshots found`

```bash
# バックエンドが起動しているか確認
curl http://localhost:3000/health

# --live オプションでAPIから取得
python build_graph.py --live
```

### `requests package required`

```bash
pip install requests
```

### グラフが空になる

- `--include-unilateral` オプションで片方向エッジも含める
- ログにデータがあるか確認: `cat ../logs/edge_events_*.csv | wc -l`
