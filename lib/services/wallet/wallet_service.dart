import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:reown_appkit/reown_appkit.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/core.dart';
import '../../providers/app_providers.dart';

part 'wallet_service.g.dart';

/// ウォレット接続状態
enum WalletConnectionState {
  /// 未接続
  disconnected,

  /// 接続中
  connecting,

  /// 接続済み
  connected,

  /// 切断中
  disconnecting,
}

/// ウォレットサービスの状態
class WalletServiceState {
  const WalletServiceState({
    this.connectionState = WalletConnectionState.disconnected,
    this.walletAddress,
    this.chainId,
    this.error,
  });

  final WalletConnectionState connectionState;
  final String? walletAddress;
  final int? chainId;
  final AppError? error;

  bool get isConnected => connectionState == WalletConnectionState.connected;

  String? get shortAddress {
    if (walletAddress == null) return null;
    if (walletAddress!.length <= 10) return walletAddress;
    return '${walletAddress!.substring(0, 6)}...${walletAddress!.substring(walletAddress!.length - 4)}';
  }

  WalletServiceState copyWith({
    WalletConnectionState? connectionState,
    String? walletAddress,
    int? chainId,
    AppError? error,
  }) {
    return WalletServiceState(
      connectionState: connectionState ?? this.connectionState,
      walletAddress: walletAddress ?? this.walletAddress,
      chainId: chainId ?? this.chainId,
      error: error,
    );
  }
}

/// Gnosis Chainの定義
final _gnosisChain = ReownAppKitModalNetworkInfo(
  name: 'Gnosis',
  chainId: '100',
  chainIcon: null,
  currency: 'xDAI',
  rpcUrl: 'https://rpc.gnosischain.com',
  explorerUrl: 'https://gnosisscan.io',
  isTestNetwork: false,
);

/// ウォレットサービスプロバイダー
@Riverpod(keepAlive: true)
class WalletService extends _$WalletService {
  ReownAppKitModal? _appKitModal;

  @override
  WalletServiceState build() {
    ref.onDispose(() {
      _appKitModal?.dispose();
    });
    return const WalletServiceState();
  }

  /// AppKitModalを初期化する
  Future<Result<void, AppError>> initialize() async {
    try {
      final env = ref.read(envProvider);
      final projectId = env.reownProjectId;

      if (projectId.isEmpty) {
        return Failure(WalletError(
          message: 'Reown Project IDが設定されていません',
          type: WalletErrorType.connectionFailed,
        ));
      }

      // AppKitModalの設定は context が必要なため、
      // 実際の初期化は openModal() で行う
      return const Success(null);
    } catch (e, st) {
      return Failure(WalletError(
        message: 'ウォレットサービスの初期化に失敗しました: $e',
        cause: e,
        stackTrace: st,
        type: WalletErrorType.connectionFailed,
      ));
    }
  }

  /// ウォレット接続モーダルを開く
  Future<Result<void, AppError>> openModal(dynamic context) async {
    try {
      state = state.copyWith(connectionState: WalletConnectionState.connecting);

      final env = ref.read(envProvider);
      final projectId = env.reownProjectId;

      if (projectId.isEmpty) {
        state =
            state.copyWith(connectionState: WalletConnectionState.disconnected);
        return Failure(WalletError(
          message: 'Reown Project IDが設定されていません',
          type: WalletErrorType.connectionFailed,
        ));
      }

      // AppKitModalを作成
      _appKitModal = ReownAppKitModal(
        context: context,
        projectId: projectId,
        metadata: const PairingMetadata(
          name: 'Beid App',
          description: 'BLE相互センシングdApp',
          url: 'https://beid.app',
          icons: ['https://beid.app/icon.png'],
          redirect: Redirect(
            native: 'beid://',
            universal: 'https://beid.app',
          ),
        ),
        featuresConfig: FeaturesConfig(
          socials: [],
          showMainWallets: true,
        ),
      );

      // Gnosis Chainのサポートを追加
      ReownAppKitModalNetworks.addSupportedNetworks('eip155', [_gnosisChain]);

      await _appKitModal!.init();

      // イベントリスナーを設定
      _setupEventListeners();

      // 既存のセッションを確認
      if (_appKitModal!.isConnected) {
        _updateConnectionState();
      } else {
        // モーダルを開く
        _appKitModal!.openModalView();
      }

      return const Success(null);
    } catch (e, st) {
      state =
          state.copyWith(connectionState: WalletConnectionState.disconnected);
      return Failure(WalletError(
        message: 'ウォレット接続に失敗しました: $e',
        cause: e,
        stackTrace: st,
        type: WalletErrorType.connectionFailed,
      ));
    }
  }

  void _setupEventListeners() {
    _appKitModal?.onModalConnect.subscribe((event) {
      debugPrint('WalletService: onModalConnect');
      _updateConnectionState();
    });

    _appKitModal?.onModalDisconnect.subscribe((event) {
      debugPrint('WalletService: onModalDisconnect');
      state = const WalletServiceState();
    });

    _appKitModal?.onModalError.subscribe((event) {
      final errorMessage = event.message;
      debugPrint('WalletService: onModalError - $errorMessage');
      state = state.copyWith(
        error: WalletError(
          message: errorMessage,
          type: WalletErrorType.connectionFailed,
        ),
      );
    });
  }

  void _updateConnectionState() {
    if (_appKitModal == null) return;

    final session = _appKitModal!.session;
    if (session != null) {
      final address = session.getAddress('eip155');
      final selectedChain = _appKitModal!.selectedChain;
      final chainId = selectedChain != null
          ? int.tryParse(selectedChain.chainId)
          : 100;

      state = state.copyWith(
        connectionState: WalletConnectionState.connected,
        walletAddress: address,
        chainId: chainId,
      );
    }
  }

  /// ウォレットを切断する
  Future<Result<void, AppError>> disconnect() async {
    if (!state.isConnected) {
      return const Success(null);
    }

    try {
      state =
          state.copyWith(connectionState: WalletConnectionState.disconnecting);

      await _appKitModal?.disconnect();

      state = const WalletServiceState();
      return const Success(null);
    } catch (e, st) {
      return Failure(WalletError(
        message: 'ウォレット切断に失敗しました: $e',
        cause: e,
        stackTrace: st,
        type: WalletErrorType.connectionFailed,
      ));
    }
  }

  /// メッセージに署名する（EIP-191 personal_sign）
  Future<Result<String, AppError>> signMessage(String message) async {
    if (!state.isConnected || state.walletAddress == null) {
      return Failure(WalletError(
        message: 'ウォレットが接続されていません',
        type: WalletErrorType.connectionFailed,
      ));
    }

    try {
      final signature = await _appKitModal!.request(
        topic: _appKitModal!.session!.topic,
        chainId: 'eip155:${state.chainId ?? 100}',
        request: SessionRequestParams(
          method: 'personal_sign',
          params: [message, state.walletAddress],
        ),
      );

      if (signature == null) {
        return Failure(WalletError(
          message: '署名がキャンセルされました',
          type: WalletErrorType.signatureCancelled,
        ));
      }

      return Success(signature.toString());
    } catch (e, st) {
      return Failure(WalletError(
        message: '署名に失敗しました: $e',
        cause: e,
        stackTrace: st,
        type: WalletErrorType.signatureFailed,
      ));
    }
  }

  /// AppKitModalを取得する（UI用）
  ReownAppKitModal? get appKitModal => _appKitModal;
}
