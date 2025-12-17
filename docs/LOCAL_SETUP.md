# ローカル動作確認ガイド

このドキュメントでは、Beid Appをローカル環境でセットアップし、動作確認を行う手順を説明します。

## 前提条件

### 必須ツール

| ツール | バージョン | 確認コマンド |
|--------|-----------|-------------|
| Flutter | 3.38.4以上 | `flutter --version` |
| Dart | 3.8.1以上 | `dart --version` |
| Xcode | 15.0以上（iOS） | `xcodebuild -version` |
| Android Studio | 最新版（Android） | - |
| Java | 17以上（Android） | `java -version` |
| CocoaPods | 1.14以上（iOS） | `pod --version` |

### Flutter環境の確認

```bash
flutter doctor -v
```

すべてのチェックが通っていることを確認してください。

## セットアップ手順

### 1. リポジトリのクローン

```bash
git clone <repository-url>
cd beid
```

### 2. 依存パッケージのインストール

```bash
flutter pub get
```

### 3. コード生成の実行

Riverpod と Hive のコード生成を実行します：

```bash
dart run build_runner build --delete-conflicting-outputs
```

### 4. 環境変数の設定

`.env`ファイルを編集し、必要な値を設定します：

```bash
# .env ファイルを編集
```

```env
# Reown (WalletConnect) Configuration
# Reown Cloud (https://cloud.reown.com/) でプロジェクトを作成し、Project IDを取得
REOWN_PROJECT_ID=your_project_id_here

# Backend API Configuration
# ローカルでバックエンドを起動する場合
API_BASE_URL=http://localhost:3000/api

# iOS Simulatorで実行する場合
# API_BASE_URL=http://127.0.0.1:3000/api

# Android Emulatorで実行する場合
# API_BASE_URL=http://10.0.2.2:3000/api
```

#### Reown Project IDの取得方法

1. [Reown Cloud](https://cloud.reown.com/) にアクセス
2. アカウントを作成またはログイン
3. 新しいプロジェクトを作成
4. Project IDをコピーして`.env`に設定

## iOS向けセットアップ

### 1. CocoaPodsの依存関係をインストール

```bash
cd ios
pod install
cd ..
```

### 2. Xcodeでの設定（実機テストの場合）

```bash
open ios/Runner.xcworkspace
```

Xcodeで以下を設定：
- Signing & Capabilities でチームを選択
- Bundle Identifierを一意の値に変更（例: `com.yourname.beidapp`）

### 3. iOSシミュレーターで実行

```bash
flutter run -d "iPhone 15 Pro"
```

**注意**: BLE機能はシミュレーターでは動作しません。モック実装でUIの確認のみ可能です。

### 4. iOS実機で実行

```bash
# 接続されているデバイスの確認
flutter devices

# 実機で実行
flutter run -d <device-id>
```

## Android向けセットアップ

### 1. Java 17の設定

Android Gradle Pluginには Java 17 が必要です：

```bash
# Homebrewでインストール（macOS）
brew install openjdk@17

# Flutterに設定
flutter config --jdk-dir="/opt/homebrew/opt/openjdk@17"
```

### 2. Android Emulatorで実行

```bash
# エミュレーターの起動
flutter emulators --launch <emulator-id>

# アプリの実行
flutter run -d <emulator-id>
```

**注意**: BLE機能はエミュレーターでは動作しません。モック実装でUIの確認のみ可能です。

### 3. Android実機で実行

1. デバイスの開発者オプションを有効化
2. USBデバッグを有効化
3. デバイスをPCに接続

```bash
flutter run -d <device-id>
```

## 動作確認手順

### 1. アプリの起動確認

アプリが起動し、ホーム画面が表示されることを確認：

- [ ] AppBarに「Beid」タイトルが表示される
- [ ] ウォレット接続ボタンが表示される
- [ ] 履歴ボタンが表示される
- [ ] 「センシング開始」ボタンが表示される
- [ ] 「センシングを開始してください」メッセージが表示される

### 2. ウォレット接続の確認

**前提**: `REOWN_PROJECT_ID`が設定されていること

1. ウォレット接続ボタンをタップ
2. WalletConnectモーダルが表示されることを確認
3. ウォレットアプリ（MetaMask等）でQRコードをスキャン
4. 接続を承認
5. AppBarにウォレットアドレス（短縮形）が表示されることを確認

### 3. センシング機能の確認（モック）

**注意**: 実際のBLE通信はモック実装のため、ダミーデータが表示されます。

1. ウォレットを接続した状態で「センシング開始」をタップ
2. パーミッションダイアログが表示されたら許可
3. センシング状態が「センシング中」に変わることを確認
4. 数秒後にモックの検知ユーザーがリストに表示される
5. 「センシング停止」をタップして停止を確認

### 4. 履歴画面の確認

1. 履歴ボタンをタップ
2. 履歴画面が表示されることを確認
3. （センシング後）履歴アイテムをタップして詳細ボトムシートを確認

## バックエンドAPIなしでの動作

現在のモック実装では、バックエンドAPIなしでも以下が動作します：

| 機能 | 動作 |
|------|------|
| ウォレット接続 | 動作（Reown Project ID必須） |
| BLEセンシング | モックデータで動作 |
| 検知ユーザー表示 | モックデータで動作 |
| 履歴保存 | ローカルストレージに保存 |
| POAP発行 | バックエンドAPI必要 |

## トラブルシューティング

### CocoaPodsのエラー

```
Error running pod install
```

**解決策**:
```bash
cd ios
pod deintegrate
pod cache clean --all
pod install --repo-update
cd ..
```

### Java 17のエラー（Android）

```
Android Gradle plugin requires Java 17 to run
```

**解決策**:
```bash
# Java 17をインストール
brew install openjdk@17

# Flutterに設定
flutter config --jdk-dir="/opt/homebrew/opt/openjdk@17"

# 確認
flutter doctor -v
```

### Reown接続エラー

```
Reown Project IDが設定されていません
```

**解決策**:
1. `.env`ファイルに`REOWN_PROJECT_ID`を設定
2. アプリを再起動

### BLEパーミッションエラー

```
パーミッションが永久に拒否されました
```

**解決策（iOS）**:
1. 設定アプリを開く
2. Beid Appを選択
3. Bluetoothと位置情報を許可

**解決策（Android）**:
1. 設定アプリを開く
2. アプリ → Beid App → 権限
3. Bluetoothと位置情報を許可

### ビルドエラー

```bash
# クリーンビルド
flutter clean
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

## 開発時のコマンド

```bash
# コード変更後の自動リビルド
dart run build_runner watch

# 静的解析
flutter analyze

# テスト実行
flutter test

# リリースビルド（iOS）
flutter build ios --release

# リリースビルド（Android）
flutter build apk --release
```

## 実機テストのチェックリスト

### 2台のデバイスでの相互センシングテスト

1. [ ] 両デバイスでアプリをインストール
2. [ ] 両デバイスでウォレットを接続（異なるアドレス）
3. [ ] 両デバイスでBluetoothと位置情報を有効化
4. [ ] 両デバイスでセンシングを開始
5. [ ] 互いの検知ユーザーリストに相手が表示されることを確認
6. [ ] RSSI（信号強度）が距離に応じて変化することを確認

**注意**: 現在はモック実装のため、実際のBLE相互検知には独自BLEライブラリの実装が必要です。

## 次のステップ

1. **独自BLEライブラリの統合**
   - `lib/services/ble/ble_library_mock.dart`を実際のライブラリ実装に置き換え

2. **バックエンドAPIの実装**
   - タスク5のNode.js/Expressバックエンドを実装
   - POAP発行連携を有効化

3. **本番環境の設定**
   - 本番用のReown Project IDを取得
   - 本番用のAPIエンドポイントを設定
