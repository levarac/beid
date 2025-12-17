# Research & Design Decisions

## Summary
- **Feature**: `ble-mutual-sensing-dapp`
- **Discovery Scope**: New Feature (greenfield)
- **Key Findings**:
  - BLEスキャン・アドバタイズは別リポジトリで並行開発中の独自ライブラリを使用
  - WalletConnectはReown AppKitにリブランド済み、Flutter向けにreown_appkitを使用
  - POAPはGnosis Chain上で発行され、公式APIを通じてミント可能

## Research Log

### BLEライブラリ
- **Context**: BLEスキャンとアドバタイズの両方を行う必要がある
- **Decision**: 別リポジトリで並行開発中の**独自BLEライブラリ**を使用
- **Rationale**:
  - 既存のFlutter BLEライブラリ（flutter_reactive_ble, ble_peripheral等）はスキャンとアドバタイズで別々のライブラリが必要
  - 独自ライブラリでCentral/Peripheral両方の機能を統一インターフェースで提供
  - プロジェクト固有の要件に最適化可能
- **Implications**:
  - 本アプリは独自BLEライブラリのインターフェースに依存
  - ライブラリの開発進捗と並行してアプリ側の実装を進める
  - インターフェース定義は両リポジトリで合意が必要

### WalletConnect / Reown AppKit
- **Context**: FlutterでWalletConnect経由のウォレット接続を実装
- **Sources Consulted**:
  - [Reown AppKit Flutter Docs](https://docs.reown.com/appkit/flutter/core/usage)
  - [WalletConnect/Web3ModalFlutter GitHub](https://github.com/WalletConnect/Web3ModalFlutter)
- **Findings**:
  - WalletConnect Inc.はReown Inc.にリブランド
  - web3modal_flutterは非推奨、reown_appkitが後継
  - AppKitはEVM、Solana、Bitcoin等マルチチェーン対応
  - 事前構築済みUIコンポーネント提供（ConnectButton、AccountButton等）
  - Project ID取得が必要（Reownダッシュボードから）
- **Implications**:
  - reown_appkit（またはweb3modal_flutter最新版）を使用
  - Gnosis Chainをサポートするネットワーク設定が必要

### POAP発行連携
- **Context**: 相互センシング成立時にPOAPを発行
- **Sources Consulted**:
  - [POAP Smart Contract Reference](https://documentation.poap.tech/docs/smart-contract-reference)
  - [POAP GitHub](https://github.com/poapxyz/poap)
- **Findings**:
  - POAPコントラクトアドレス: `0x22C1f6050E56d2876009903609a2cC3fEf83B415`
  - 対応チェーン: Ethereum, Gnosis, Base, Arbitrum, Polygon等
  - ERC-721準拠のNFT
  - POAP APIを通じてドロップ作成・ミント可能
  - Mainnetへのミントはminting-configエンドポイント経由で設定不可（別手段必要）
- **Implications**:
  - ガス代節約のためGnosis Chainを主要ミントチェーンとして使用
  - POAP API認証のためのバックエンドサーバーが必要（APIキー保護）
  - または独自スマートコントラクトでPOAP類似のNFT発行も検討可能

### ローカルストレージ選定
- **Context**: センシング履歴のローカル保存
- **Sources Consulted**:
  - [Flutter Data Storage Comparison](https://medium.com/@dobri.kostadinov/flutter-data-storage-sharedpreferences-room-and-datastore-compared-69bb529803de)
  - [Best Local Database for Flutter](https://dinkomarinac.dev/best-local-database-for-flutter-apps-a-complete-guide)
- **Findings**:
  - SharedPreferences: 軽量、設定値向け、大量データ不向き
  - Hive: 高速NoSQL、AES-256暗号化対応、オリジナルはメンテナンス停止→hive_ceが後継
  - SQLite (sqflite/Drift): リレーショナル、複雑なクエリ向け
  - パフォーマンス: Hive >> SharedPreferences/SQLite
- **Implications**:
  - センシング履歴はHive（hive_ce）を使用（高速、暗号化対応）
  - ウォレットアドレス等の設定はSharedPreferencesまたはflutter_secure_storage

### BLE相互センシング検証プロトコル
- **Context**: 双方のデバイスが互いを検知したことを検証する仕組み
- **Sources Consulted**:
  - [BLE Proximity Detection Research (PMC)](https://pmc.ncbi.nlm.nih.gov/articles/PMC11031693/)
  - [BLE Proximity Control IEEE](https://ieeexplore.ieee.org/document/10157704/)
- **Findings**:
  - RSSI（受信信号強度）ベースの近接検出が一般的
  - 環境要因（温度、湿度）による変動あり
  - 双方向検知には両デバイスがアドバタイズ+スキャンを行う必要
  - リレー攻撃対策にはUWB併用が推奨されるが、今回はシンプル実装を優先
- **Implications**:
  - 各デバイスにユニークなUUID（ウォレットアドレス由来）を割り当て
  - アドバタイズパケットにUUIDを含める
  - スキャンで検出したUUIDをサーバー/P2Pで突合して相互検知を確認
  - タイムスタンプと署名でセンシングデータの真正性を担保

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| クライアント-サーバー型 | センシングデータをバックエンドで集約・検証 | 相互検知の確実な検証、APIキー保護 | サーバー運用コスト、レイテンシ | POAP API連携に最適 |
| P2P型 | デバイス間で直接検証・署名 | サーバー不要、リアルタイム性 | 相互検知の検証が複雑、セキュリティ課題 | オフライン対応可能 |
| ハイブリッド型 | BLE検知はローカル、POAP発行はサーバー経由 | バランスが良い | 両方の実装が必要 | 推奨アプローチ |

**選定**: ハイブリッド型
- BLE検知・一時保存はクライアント側で完結
- 相互検知成立後、バックエンドAPI経由でセンシングデータを検証しPOAPを発行
- バックエンドはPOAP APIキーを保護し、不正発行を防止

## Design Decisions

### Decision: 独自BLEライブラリの採用
- **Context**: Flutterで同時にスキャン（Central）とアドバタイズ（Peripheral）を行う必要
- **Alternatives Considered**:
  1. flutter_reactive_ble + ble_peripheral — 2つの既存ライブラリ併用
  2. 独自BLEライブラリ — 別リポジトリで並行開発
- **Selected Approach**: 独自BLEライブラリ
- **Rationale**: Central/Peripheral両方を統一インターフェースで提供でき、プロジェクト固有の要件に最適化可能
- **Trade-offs**: ライブラリ開発の工数が追加で必要だが、長期的には保守性と拡張性が向上
- **Follow-up**: ライブラリ側のインターフェース定義と本アプリ側の連携方法を早期に合意

### Decision: センシングデータの検証方式
- **Context**: 相互センシングの成立を信頼性高く検証する必要
- **Alternatives Considered**:
  1. クライアント側のみで検証（タイムスタンプ比較）
  2. バックエンドで検証（両者のセンシングレポートを突合）
  3. スマートコントラクトで検証（オンチェーン検証）
- **Selected Approach**: バックエンドで検証
- **Rationale**:
  - クライアント側のみでは偽装リスクがある
  - オンチェーン検証はガス代が高くリアルタイム性に欠ける
  - バックエンドなら両者のレポートを確実に突合可能
- **Trade-offs**: バックエンドサーバーの運用が必要
- **Follow-up**: センシングレポートに署名を付与し、改ざん防止

### Decision: POAP発行方式
- **Context**: POAPをプログラマティックに発行する方法
- **Alternatives Considered**:
  1. 公式POAP API経由 — Drop作成→Claim Link配布→ミント
  2. 独自NFTコントラクト — POAP類似のERC-721を独自発行
- **Selected Approach**: 公式POAP API経由（初期）、将来的に独自コントラクトも検討
- **Rationale**: POAPエコシステムとの互換性、ユーザーがPOAPアプリで確認可能
- **Trade-offs**: APIレート制限、Drop事前作成の手間
- **Follow-up**: POAP API認証フロー、Drop自動作成の可否を確認

### Decision: ローカルストレージ
- **Context**: センシング履歴の永続化
- **Selected Approach**: hive_ce（Hive Community Edition）
- **Rationale**: 高速、暗号化対応、構造化データに適している
- **Trade-offs**: Dart専用のため移植性は低いが、Flutterアプリでは問題なし

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| 独自BLEライブラリの開発遅延 | インターフェース定義を先行合意、モック実装で並行開発 |
| BLE同時スキャン+アドバタイズのバッテリー消費 | センシング中のみ有効化、バックグラウンド制限 |
| 相互検知のなりすまし | ウォレット署名付きセンシングレポート |
| POAP API認証情報の漏洩 | バックエンドでAPIキー管理、クライアントに露出させない |
| ネットワーク障害時のPOAP発行失敗 | ローカルキューイング、後続リトライ機構 |

## References

- 独自BLEライブラリ（別リポジトリ）— BLEスキャン+アドバタイズ
- [Reown AppKit Flutter Docs](https://docs.reown.com/appkit/flutter/core/usage) — WalletConnect後継
- [POAP Smart Contract Reference](https://documentation.poap.tech/docs/smart-contract-reference) — POAP公式ドキュメント
- [hive_ce pub.dev](https://pub.dev/packages/hive_ce) — Hive Community Edition
- [flutter_reactive_ble pub.dev](https://pub.dev/packages/flutter_reactive_ble) — 参考: 既存BLEスキャンライブラリ
- [ble_peripheral pub.dev](https://pub.dev/packages/ble_peripheral) — 参考: 既存BLEアドバタイズライブラリ
