// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ble_service.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$bleLibraryHash() => r'f7c9cba0d183550feffa6789dd44a0c14ea8bf10';

/// BLEライブラリプロバイダー
///
/// Copied from [bleLibrary].
@ProviderFor(bleLibrary)
final bleLibraryProvider = AutoDisposeProvider<BleLibraryInterface>.internal(
  bleLibrary,
  name: r'bleLibraryProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$bleLibraryHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef BleLibraryRef = AutoDisposeProviderRef<BleLibraryInterface>;
String _$bleServiceHash() => r'd97d55e80783ed17a055421f274b7f8e68d8108e';

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
