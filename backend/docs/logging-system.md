# Beid Backend Logging System

BLE相互センシングデータを収集し、無向グラフ構築に必要なデータを記録するログシステムのドキュメント。

## 概要

このログシステムは以下の目的で設計されています：

1. **センシングデータの詳細記録** - RSSI値、距離推定、信号品質
2. **グラフ構造の追跡** - ノード（デバイス）とエッジ（検知関係）のイベント
3. **相互検知の判定** - 双方向検知による無向グラフエッジの確立
4. **グラフ状態のスナップショット** - 任意時点でのグラフ全体状態の保存
5. **統計情報の時系列記録** - グラフ密度、連結成分数などの推移

## アーキテクチャ

```
┌─────────────────────────────────────────────────────────────┐
│                     WebSocket Service                        │
│  (クライアント接続・RSSIレポート受信)                          │
└─────────────────┬───────────────────────────────────────────┘
                  │
    ┌─────────────┼─────────────┬─────────────┐
    ▼             ▼             ▼             ▼
┌────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐
│ RSSI   │  │  Edge    │  │  Node    │  │   Session    │
│ Logger │  │  Logger  │  │  Logger  │  │   Manager    │
└────┬───┘  └────┬─────┘  └────┬─────┘  └──────┬───────┘
     │           │             │               │
     ▼           ▼             ▼               │
┌────────┐  ┌──────────┐  ┌──────────┐         │
│rssi_log│  │edge_event│  │node_event│         │
│ *.csv  │  │  *.csv   │  │  *.csv   │         │
└────────┘  └──────────┘  └──────────┘         │
                                               │
    ┌──────────────────────────────────────────┘
    │
    ▼
┌───────────────────┐     ┌───────────────────┐
│  Graph Snapshot   │     │   Stats Logger    │
│    Service        │     │                   │
└────────┬──────────┘     └─────────┬─────────┘
         │                          │
         ▼                          ▼
┌───────────────────┐     ┌───────────────────┐
│ snapshots/*.json  │     │ graph_stats_*.csv │
└───────────────────┘     └───────────────────┘
```

## ログファイル形式

### 1. RSSI Log (`rssi_log_*.csv`)

センシングレポートの詳細記録。

| カラム | 型 | 説明 |
|--------|-----|------|
| `timestamp` | ISO8601 | 記録時刻 |
| `session_id` | string | セッション識別子 |
| `report_seq` | int | レポート連番 |
| `reporter_id` | string | 報告者のデバイスID |
| `detected_id` | string | 検知されたデバイスID |
| `rssi` | int | RSSI値（dBm） |
| `heading` | float | コンパス方位（度、0-360） |
| `distance_estimate` | float | 推定距離（メートル） |
| `tx_power` | int | 送信電力（dBm、キャリブレーション用） |
| `signal_quality` | float | 信号品質スコア（0-1） |
| `is_mutual` | bool | 相互検知が成立しているか |

**例:**
```csv
timestamp,session_id,report_seq,reporter_id,detected_id,rssi,heading,distance_estimate,tx_power,signal_quality,is_mutual
2026-01-08T10:00:00.000Z,m123abc-def456,1,user-a,user-b,-65,45.5,2.512,-59,0.58,true
```

### 2. Edge Events (`edge_events_*.csv`)

エッジ（検知関係）の確立・更新・消滅イベント。

| カラム | 型 | 説明 |
|--------|-----|------|
| `timestamp` | ISO8601 | イベント時刻 |
| `session_id` | string | セッション識別子 |
| `event_type` | enum | `edge_established`, `edge_updated`, `edge_dissolved` |
| `node_a` | string | ノードA（辞書順で先） |
| `node_b` | string | ノードB |
| `rssi_a_to_b` | int | A→BのRSSI値 |
| `rssi_b_to_a` | int | B→AのRSSI値 |
| `rssi_avg` | float | 平均RSSI |
| `distance_estimate` | float | 推定距離（メートル） |
| `mutual` | bool | 双方向検知か |
| `edge_duration_ms` | int | エッジ持続時間（dissolve時のみ） |

**例:**
```csv
timestamp,session_id,event_type,node_a,node_b,rssi_a_to_b,rssi_b_to_a,rssi_avg,distance_estimate,mutual,edge_duration_ms
2026-01-08T10:00:00.000Z,m123abc,edge_established,user-a,user-b,-65,,-65,2.512,false,
2026-01-08T10:00:05.000Z,m123abc,edge_updated,user-a,user-b,-65,-62,-63.5,2.114,true,
2026-01-08T10:00:30.000Z,m123abc,edge_dissolved,user-a,user-b,-65,-62,-63.5,2.114,true,25000
```

### 3. Node Events (`node_events_*.csv`)

ノード（デバイス）の参加・離脱イベント。

| カラム | 型 | 説明 |
|--------|-----|------|
| `timestamp` | ISO8601 | イベント時刻 |
| `session_id` | string | セッション識別子 |
| `event_type` | enum | `node_joined`, `node_left`, `node_updated` |
| `node_id` | string | デバイスID |
| `device_type` | string | デバイス種別（ios, android等） |
| `session_duration_ms` | int | セッション参加時間（leave時のみ） |
| `total_reports` | int | 送信したレポート数 |
| `metadata` | JSON | 追加メタデータ |

**例:**
```csv
timestamp,session_id,event_type,node_id,device_type,session_duration_ms,total_reports,metadata
2026-01-08T10:00:00.000Z,m123abc,node_joined,user-a,ios,,0,{'deviceType':'ios'}
2026-01-08T10:05:00.000Z,m123abc,node_left,user-a,ios,300000,45,{'deviceType':'ios'}
```

### 4. Graph Stats (`graph_stats_*.csv`)

グラフ全体の統計情報（定期記録）。

| カラム | 型 | 説明 |
|--------|-----|------|
| `timestamp` | ISO8601 | 記録時刻 |
| `session_id` | string | セッション識別子 |
| `node_count` | int | ノード数 |
| `edge_count` | int | エッジ数 |
| `mutual_edge_count` | int | 相互検知エッジ数 |
| `density` | float | グラフ密度（0-1） |
| `avg_rssi` | float | 平均RSSI |
| `avg_distance` | float | 平均距離 |
| `avg_degree` | float | 平均次数 |
| `max_degree` | int | 最大次数 |
| `min_degree` | int | 最小次数 |
| `connected_components` | int | 連結成分数 |
| `is_fully_connected` | bool | 完全連結か |

**例:**
```csv
timestamp,session_id,node_count,edge_count,mutual_edge_count,density,avg_rssi,avg_distance,avg_degree,max_degree,min_degree,connected_components,is_fully_connected
2026-01-08T10:00:00.000Z,m123abc,5,8,6,0.8000,-65.50,2.345,3.20,4,2,1,true
```

### 5. Graph Snapshots (`snapshots/snapshot_*.json`)

グラフ全体状態のスナップショット。

```json
{
  "timestamp": "2026-01-08T10:00:00.000Z",
  "session_id": "m123abc-def456",
  "snapshot_id": "m123abc-def456-5",
  "nodes": ["user-a", "user-b", "user-c"],
  "node_count": 3,
  "edges": [
    {
      "source": "user-a",
      "target": "user-b",
      "rssi_a_to_b": -65,
      "rssi_b_to_a": -62,
      "rssi_avg": -63.5,
      "distance": 2.114,
      "mutual": true,
      "established_at": "2026-01-08T09:55:00.000Z",
      "last_update": "2026-01-08T10:00:00.000Z"
    }
  ],
  "edge_count": 2,
  "mutual_edge_count": 2,
  "adjacency_list": {
    "user-a": ["user-b", "user-c"],
    "user-b": ["user-a"],
    "user-c": ["user-a"]
  },
  "statistics": {
    "density": 0.6667,
    "avg_rssi": -65.25,
    "avg_distance": 2.345,
    "avg_degree": 1.33,
    "max_degree": 2,
    "min_degree": 1,
    "connected_components": 1,
    "is_connected": true
  }
}
```

## API エンドポイント

### ログ管理

| メソッド | エンドポイント | 説明 |
|----------|----------------|------|
| GET | `/api/logs` | 全ログファイル一覧 |
| GET | `/api/logs/rssi` | RSSIログ一覧 |
| GET | `/api/logs/rssi/:filename` | RSSIログダウンロード |
| GET | `/api/logs/edges` | エッジログ一覧 |
| GET | `/api/logs/edges/:filename` | エッジログダウンロード |
| GET | `/api/logs/nodes` | ノードログ一覧 |
| GET | `/api/logs/nodes/:filename` | ノードログダウンロード |
| GET | `/api/logs/stats` | 統計ログ一覧 |
| GET | `/api/logs/stats/:filename` | 統計ログダウンロード |
| GET | `/api/logs/snapshots` | スナップショット一覧 |
| GET | `/api/logs/snapshots/latest` | 最新スナップショット |
| GET | `/api/logs/snapshots/:filename` | スナップショット取得 |
| POST | `/api/logs/rotate` | 全ログローテーション |
| POST | `/api/logs/enable` | ログ有効化 |
| POST | `/api/logs/disable` | ログ無効化 |
| POST | `/api/logs/cleanup` | 古いスナップショット削除 |

### グラフデータ

| メソッド | エンドポイント | 説明 |
|----------|----------------|------|
| GET | `/api/graph/current` | 現在のグラフ状態（スナップショット形式） |
| GET | `/api/graph/stats` | 現在のグラフ統計 |
| GET | `/api/graph/edges` | 現在のエッジ一覧 |
| GET | `/api/graph/nodes` | 現在のノード一覧 |
| POST | `/api/graph/snapshot` | 手動スナップショット作成 |

### セッション管理

| メソッド | エンドポイント | 説明 |
|----------|----------------|------|
| GET | `/api/session/current` | 現在のセッション情報 |
| GET | `/api/session/history` | セッション履歴 |
| POST | `/api/session/start` | 新規セッション開始（ログローテーション含む） |
| POST | `/api/session/end` | セッション終了 |

## 設定

### 環境変数

| 変数 | デフォルト | 説明 |
|------|------------|------|
| `PORT` | 3000 | サーバーポート |
| `LOG_DIR` | ./logs | ログ出力ディレクトリ |

### 定期実行間隔

| 処理 | 間隔 | 説明 |
|------|------|------|
| グラフスナップショット | 30秒 | `snapshots/*.json`に出力 |
| 統計ログ | 10秒 | `graph_stats_*.csv`に追記 |
| エッジタイムアウト | 10秒 | 更新がないエッジを削除 |
| 位置計算ブロードキャスト | 5秒 | クライアントへ位置情報送信 |

## 距離推定モデル

RSSI値から距離への変換には Log-distance Path Loss Model を使用：

```
distance = 10 ^ ((TxPower - RSSI) / (10 * n))
```

| パラメータ | 値 | 説明 |
|------------|-----|------|
| TxPower | -59 dBm | 1メートル地点での参照RSSI |
| n | 2.5 | 経路損失指数（2-4、障害物が多いほど大） |

## 信号品質スコア

RSSI値を0-1のスコアに正規化：

```
quality = max(0, min(1, (rssi + 100) / 60))
```

| RSSI | 品質 | 評価 |
|------|------|------|
| -40 dBm | 1.0 | 優秀 |
| -60 dBm | 0.67 | 良好 |
| -80 dBm | 0.33 | 普通 |
| -100 dBm | 0.0 | 弱い |

## 無向グラフ構築

### エッジ確立条件

1. **片方向検知**: A→BのRSSIが記録されるとエッジが`edge_established`
2. **相互検知**: B→AのRSSIも記録されると`mutual: true`に更新
3. **タイムアウト**: 10秒間更新がないとエッジが`edge_dissolved`

### 隣接リスト形式

スナップショットの`adjacency_list`は無向グラフとして構築：

```json
{
  "user-a": ["user-b", "user-c"],
  "user-b": ["user-a"],
  "user-c": ["user-a"]
}
```

## 使用例

### グラフデータの取得

```bash
# 現在のグラフを取得してPythonで処理
curl -s http://localhost:3000/api/graph/current | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f'Nodes: {data[\"node_count\"]}')
print(f'Edges: {data[\"edge_count\"]}')
print(f'Mutual: {data[\"mutual_edge_count\"]}')
print(f'Density: {data[\"statistics\"][\"density\"]:.2%}')
"
```

### CSVデータの分析

```python
import pandas as pd

# RSSIログ読み込み
df = pd.read_csv('logs/rssi_log_2026-01-08_*.csv')

# セッション別の統計
df.groupby('session_id').agg({
    'rssi': ['mean', 'std'],
    'distance_estimate': 'mean',
    'is_mutual': 'sum'
})
```

### NetworkXでのグラフ構築

```python
import json
import networkx as nx

# スナップショット読み込み
with open('logs/snapshots/snapshot_*.json') as f:
    data = json.load(f)

# 無向グラフ構築
G = nx.Graph()
G.add_nodes_from(data['nodes'])
for edge in data['edges']:
    if edge['mutual']:  # 相互検知のみ
        G.add_edge(edge['source'], edge['target'],
                   weight=edge['distance'],
                   rssi=edge['rssi_avg'])

# グラフ分析
print(f'Nodes: {G.number_of_nodes()}')
print(f'Edges: {G.number_of_edges()}')
print(f'Connected: {nx.is_connected(G)}')
print(f'Diameter: {nx.diameter(G) if nx.is_connected(G) else "N/A"}')
```

## トラブルシューティング

### ログが出力されない

1. `LOG_DIR`のディレクトリが存在するか確認
2. `/api/logs`でログが有効か確認
3. `POST /api/logs/enable`でログを有効化

### エッジがすぐ消える

- エッジタイムアウト（10秒）より高頻度でRSSIレポートを送信する
- `edge-logger.js`の`edgeTimeoutMs`を調整

### スナップショットが大きすぎる

- `POST /api/logs/cleanup`で古いスナップショットを削除
- `keepCount`パラメータで保持数を指定

## 分析スクリプト

ログデータからグラフを構築・分析・可視化するPythonスクリプトを `scripts/` ディレクトリに用意しています。

### セットアップ

```bash
cd backend/scripts
pip install -r requirements.txt
```

### スクリプト一覧

| スクリプト | 説明 |
|------------|------|
| `build_graph.py` | グラフ構築・統計分析・可視化・エクスポート |
| `analyze_timeline.py` | ログの時系列分析・可視化 |

---

### build_graph.py

センシングデータから無向グラフ（NetworkX）を構築し、統計分析・可視化・エクスポートを行う。

#### 基本的な使い方

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

#### オプション

| オプション | 説明 |
|------------|------|
| `--snapshot <file>` | スナップショットJSONを指定 |
| `--csv <file>` | エッジイベントCSVを指定 |
| `--live` | APIから現在のグラフを取得 |
| `--api-url <url>` | APIのURL（デフォルト: http://localhost:3000） |
| `--include-unilateral` | 片方向エッジも含める（デフォルトは相互検知のみ） |
| `--no-visualize` | 可視化をスキップ |
| `--no-stats` | 統計出力をスキップ |

#### エクスポートオプション

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

#### 出力例

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

### analyze_timeline.py

ログファイルの時系列分析と可視化を行う。

#### 基本的な使い方

```bash
# 全ログを自動検出して分析
python analyze_timeline.py --all

# RSSIログを分析
python analyze_timeline.py --rssi ../logs/rssi_log_2026-01-08_1234567890.csv

# エッジイベントを分析
python analyze_timeline.py --edges ../logs/edge_events_2026-01-08_1234567890.csv

# 統計ログを分析
python analyze_timeline.py --stats ../logs/graph_stats_2026-01-08_1234567890.csv

# 画像を保存
python analyze_timeline.py --all --output-dir ./reports/
```

#### オプション

| オプション | 説明 |
|------------|------|
| `--rssi <file>` | RSSIログCSVを指定 |
| `--edges <file>` | エッジイベントCSVを指定 |
| `--stats <file>` | 統計ログCSVを指定 |
| `--log-dir <dir>` | ログディレクトリ（デフォルト: ../logs） |
| `--output-dir <dir>` | 画像出力先ディレクトリ |
| `--all` | 全ログを分析 |

#### 生成されるグラフ

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

#### 出力例

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

---

### 活用例

#### グラフをGephiで可視化

```bash
# GEXFファイルを生成
python build_graph.py --live --output sensing_graph.gexf

# Gephiで開く（macOS）
open sensing_graph.gexf
```

#### 定期レポート生成

```bash
#!/bin/bash
# generate_report.sh

REPORT_DIR="./reports/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$REPORT_DIR"

# グラフ構築・エクスポート
python build_graph.py --live \
    --output-image "$REPORT_DIR/graph.png" \
    --output-stats "$REPORT_DIR/stats.json" \
    --output "$REPORT_DIR/graph.gexf"

# 時系列分析
python analyze_timeline.py --all --output-dir "$REPORT_DIR/"

echo "Report generated: $REPORT_DIR"
```

#### バッチ処理（全スナップショット）

```bash
# 全スナップショットの統計を抽出
for f in ../logs/snapshots/snapshot_*.json; do
    python build_graph.py --snapshot "$f" \
        --no-visualize \
        --output-stats "${f%.json}_stats.json"
done
```

---

### スクリプトのトラブルシューティング

#### `No snapshots found`

```bash
# バックエンドが起動しているか確認
curl http://localhost:3000/health

# --live オプションでAPIから取得
python build_graph.py --live
```

#### `ModuleNotFoundError`

```bash
# 依存パッケージをインストール
pip install -r requirements.txt
```

#### グラフが空になる

- `--include-unilateral` オプションで片方向エッジも含める
- ログにデータがあるか確認:
  ```bash
  wc -l ../logs/edge_events_*.csv
  ```
