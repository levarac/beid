// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sensing_repository.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$sensingHistoryHash() => r'b1b10dad24b053ab8b62f935de0f170f3d77f464';

/// 履歴リストプロバイダー
///
/// Copied from [sensingHistory].
@ProviderFor(sensingHistory)
final sensingHistoryProvider =
    AutoDisposeStreamProvider<List<SensingRecord>>.internal(
      sensingHistory,
      name: r'sensingHistoryProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$sensingHistoryHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef SensingHistoryRef = AutoDisposeStreamProviderRef<List<SensingRecord>>;
String _$sensingRepositoryHash() => r'63abb90c9f586bacf1077791a2b440d7be4df545';

/// センシングリポジトリプロバイダー
///
/// Copied from [SensingRepository].
@ProviderFor(SensingRepository)
final sensingRepositoryProvider =
    AsyncNotifierProvider<SensingRepository, void>.internal(
      SensingRepository.new,
      name: r'sensingRepositoryProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$sensingRepositoryHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$SensingRepository = AsyncNotifier<void>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
