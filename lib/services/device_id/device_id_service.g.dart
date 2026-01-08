// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'device_id_service.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$deviceIdServiceHash() => r'c1b5e1d17e86566202426465fdc0ce1e9a24600d';

/// デバイスID管理サービス
///
/// アプリインストール時にUUIDを自動生成し、セキュアストレージに永続化する
///
/// Copied from [DeviceIdService].
@ProviderFor(DeviceIdService)
final deviceIdServiceProvider =
    NotifierProvider<DeviceIdService, DeviceIdState>.internal(
      DeviceIdService.new,
      name: r'deviceIdServiceProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$deviceIdServiceHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$DeviceIdService = Notifier<DeviceIdState>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
