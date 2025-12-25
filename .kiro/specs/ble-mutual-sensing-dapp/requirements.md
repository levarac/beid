# Requirements Document

## Introduction
本ドキュメントは、独自BLEライブラリを使用してユーザー間で相互センシングした結果をスマートコントラクトに書き込むFlutterアプリの要件を定義する。Flutter 3.38.4を使用し、BLE通信による近接検知とブロックチェーン連携を実現するシンプルなモバイルアプリケーションを構築する。

## Requirements

### Requirement 1: BLEスキャン・アドバタイズ機能
**Objective:** As a ユーザー, I want 他のユーザーの存在をBLEで検知したい, so that 近くにいる相手を自動的に発見できる

#### Acceptance Criteria
1. When ユーザーがセンシング開始ボタンをタップした時, the BLE Service shall BLEアドバタイズとスキャンを開始する
2. When ユーザーがセンシング停止ボタンをタップした時, the BLE Service shall BLEアドバタイズとスキャンを停止する
3. When 他ユーザーのBLE信号を検知した時, the アプリ shall 検知したデバイスIDと信号強度（RSSI）を取得する
4. If BLE機能が無効な場合, then the アプリ shall ユーザーにBLE有効化を促すメッセージを表示する
5. If BLEパーミッションが未許可の場合, then the アプリ shall パーミッション許可を要求する

### Requirement 2: 相互センシング検証
**Objective:** As a ユーザー, I want 相手も自分を検知したことを確認したい, so that 双方向のセンシングが成立したことを保証できる

#### Acceptance Criteria
1. When 自デバイスが他デバイスを検知した時, the アプリ shall 検知情報を一時的に保存する
2. When 双方のデバイスが互いを検知した時, the アプリ shall 相互センシング成立として記録する
3. While センシング結果を検証中, the アプリ shall 検証中であることを示すインジケータを表示する
4. The アプリ shall センシング結果にタイムスタンプを付与する

### Requirement 3: POAP発行連携
**Objective:** As a ユーザー, I want 相互センシングの証明としてPOAPを受け取りたい, so that 出会いの証跡をNFTとして保持できる

#### Acceptance Criteria
1. When 相互センシングが成立した時, the アプリ shall センシングデータの検証をスマートコントラクトに送信する
2. When センシングデータが検証に合格した時, the スマートコントラクト shall 両ユーザーにPOAPを発行する
3. When POAP発行が完了した時, the アプリ shall 発行完了を通知する
4. If センシングデータの検証が失敗した場合, then the アプリ shall 検証失敗の理由を表示する
5. If POAP発行が失敗した場合, then the アプリ shall エラーメッセージを表示し再試行オプションを提供する
6. The アプリ shall POAP自体の表示機能は提供しない（外部POAPアプリで確認）

### Requirement 4: ユーザーインターフェース
**Objective:** As a ユーザー, I want シンプルで直感的なUIを使いたい, so that 操作に迷わずアプリを利用できる

#### Acceptance Criteria
1. The アプリ shall センシング開始/停止ボタンを提供する
2. The アプリ shall センシング状態（スキャン中/待機中）を視覚的に表示する
3. The アプリ shall レーダービューで検知した周囲のユーザーを視覚的に表示する
4. The アプリ shall 相互センシング・POAP発行履歴を一覧表示する
5. When ユーザーが履歴項目をタップした時, the アプリ shall POAP発行ステータスを表示する
6. The アプリ shall ヘッダー左端に検知履歴ページへのボタンを配置し、ボタン内に検知ユーザー数を表示する
7. The アプリ shall ヘッダー右端にマイページへのアバターアイコンボタンを配置する
8. The アプリ shall ボトムナビゲーションを使用しない（シングルページレイアウト）
9. The アプリ shall ヘッダーにサービス名やウォレットアドレスを表示しない

### Requirement 9: 検知履歴ページ（拡張）
**Objective:** As a ユーザー, I want 検知履歴とデバッグ情報にアクセスしたい, so that センシング状況を確認できる

#### Acceptance Criteria
1. When ユーザーがヘッダー左端のボタンをタップした時, the アプリ shall 検知履歴ページに遷移する
2. The 検知履歴ページ shall デバッグ画面へのリンクを提供する
3. The 検知履歴ページ shall 戻るナビゲーションを提供する

### Requirement 10: マイページ
**Objective:** As a ユーザー, I want 自分のプロフィール情報を確認したい, so that ウォレット接続状態やアカウント情報を管理できる

#### Acceptance Criteria
1. When ユーザーがマイページボタンをタップし、ウォレット未接続の場合, the アプリ shall ウォレット接続を開始する
2. When ユーザーがマイページボタンをタップし、ウォレット接続済みの場合, the アプリ shall マイページに遷移する
3. The マイページ shall 接続中のウォレットアドレスを表示する
4. The マイページ shall ウォレット切断ボタンを提供する
5. The マイページ shall 戻るナビゲーションを提供する

### Requirement 5: データ管理
**Objective:** As a ユーザー, I want センシング履歴をローカルに保存したい, so that オフライン時も履歴を確認できる

#### Acceptance Criteria
1. The アプリ shall センシング履歴をローカルストレージに保存する
2. When アプリが再起動した時, the アプリ shall 保存された履歴を復元する
3. The アプリ shall 古い履歴データを自動的にクリーンアップする設定を提供する

### Requirement 6: 認証（ウォレット接続）
**Objective:** As a ユーザー, I want ウォレットを接続してログインしたい, so that 自分のアドレスでPOAPを受け取れる

#### Acceptance Criteria
1. When ユーザーがウォレット接続ボタンをタップした時, the アプリ shall WalletConnect経由でウォレット接続を開始する
2. When ウォレット接続が成功した時, the アプリ shall ユーザーのウォレットアドレスを保存しログイン状態にする
3. When ユーザーが切断ボタンをタップした時, the アプリ shall ウォレット接続を解除しログアウト状態にする
4. While ウォレット未接続の状態, the アプリ shall センシング機能は利用可能だがPOAP発行は不可とする
5. If ウォレット接続が失敗した場合, then the アプリ shall エラーメッセージを表示し再試行オプションを提供する
6. The アプリ shall 接続中のウォレットアドレスを表示する

### Requirement 7: 相対位置可視化（三点測位）
**Objective:** As a ユーザー, I want 検知したユーザーの方角も知りたい, so that レーダー上でより直感的に周囲のユーザーを把握できる

#### Acceptance Criteria
1. When 3人以上のユーザーが同時にセンシング中の時, the バックエンド shall 各ユーザー間の距離行列から相対位置を計算する
2. When 相対位置が計算された時, the アプリ shall レーダー上でユーザーを計算された角度に配置する
3. While 3人未満のユーザーのみセンシング中, the アプリ shall 距離のみに基づいて配置する（角度はハッシュ値から決定）
4. The バックエンド shall RSSIデータを定期的に収集する（5秒間隔）
5. The バックエンド shall 計算した位置情報をWebSocket経由でリアルタイムに配信する
6. If 三点測位の計算が失敗した場合, then the アプリ shall 距離のみの表示にフォールバックする

### Requirement 8: リアルタイム同期
**Objective:** As a ユーザー, I want 他ユーザーの検知状態をリアルタイムで確認したい, so that 周囲の変化を即座に把握できる

#### Acceptance Criteria
1. The アプリ shall バックエンドとWebSocket接続を維持する
2. When 他ユーザーが自分を検知した時, the バックエンド shall WebSocket経由で通知する
3. When センシング中のユーザーが増減した時, the バックエンド shall 全ユーザーに位置情報を再配信する
4. If WebSocket接続が切断された場合, then the アプリ shall 自動再接続を試みる
5. While オフライン状態, the アプリ shall ローカルのRSSIデータのみでレーダー表示を継続する
