/// Result型の基底クラス
/// 成功または失敗を表現するためのsealed class
sealed class Result<T, E> {
  const Result();

  bool get isSuccess => this is Success<T, E>;
  bool get isFailure => this is Failure<T, E>;

  T? get valueOrNull => switch (this) {
        Success(:final value) => value,
        Failure() => null,
      };

  E? get errorOrNull => switch (this) {
        Success() => null,
        Failure(:final error) => error,
      };

  R fold<R>({
    required R Function(T value) onSuccess,
    required R Function(E error) onFailure,
  }) {
    return switch (this) {
      Success(:final value) => onSuccess(value),
      Failure(:final error) => onFailure(error),
    };
  }

  Result<U, E> map<U>(U Function(T value) transform) {
    return switch (this) {
      Success(:final value) => Success(transform(value)),
      Failure(:final error) => Failure(error),
    };
  }

  Result<T, F> mapError<F>(F Function(E error) transform) {
    return switch (this) {
      Success(:final value) => Success(value),
      Failure(:final error) => Failure(transform(error)),
    };
  }

  Future<Result<U, E>> flatMap<U>(
    Future<Result<U, E>> Function(T value) transform,
  ) async {
    return switch (this) {
      Success(:final value) => await transform(value),
      Failure(:final error) => Failure(error),
    };
  }
}

/// 成功を表すクラス
final class Success<T, E> extends Result<T, E> {
  const Success(this.value);

  final T value;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Success<T, E> && other.value == value;
  }

  @override
  int get hashCode => value.hashCode;
}

/// 失敗を表すクラス
final class Failure<T, E> extends Result<T, E> {
  const Failure(this.error);

  final E error;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Failure<T, E> && other.error == error;
  }

  @override
  int get hashCode => error.hashCode;
}
