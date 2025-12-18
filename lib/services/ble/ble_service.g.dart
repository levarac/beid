// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_service.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$barnardClientHash() => r'6f104db4f1118bf8e1e2b93796857212cb2274c8';

/// BarnardClient プロバイダー
///
/// Copied from [barnardClient].
@ProviderFor(barnardClient)
final barnardClientProvider = AutoDisposeProvider<BarnardClient>.internal(
  barnardClient,
  name: r'barnardClientProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$barnardClientHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef BarnardClientRef = AutoDisposeProviderRef<BarnardClient>;
String _$bleServiceHash() => r'f6d825290d4a08cc195d4ca242420df0009e5b3e';

/// BLEサービスプロバイダー
///
/// Copied from [BleService].
@ProviderFor(BleService)
final bleServiceProvider =
    AutoDisposeNotifierProvider<BleService, BleServiceState>.internal(
      BleService.new,
      name: r'bleServiceProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$bleServiceHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$BleService = AutoDisposeNotifier<BleServiceState>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
