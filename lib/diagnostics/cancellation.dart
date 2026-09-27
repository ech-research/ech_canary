import 'dart:async';

class ScanCancelled implements Exception {
  const ScanCancelled();
  @override
  String toString() => '检测已取消';
}

class Cancellation {
  final _done = Completer<void>();
  final _callbacks = <void Function()>{};
  bool get cancelled => _done.isCompleted;
  void check() {
    if (cancelled) throw const ScanCancelled();
  }

  void Function() register(void Function() callback) {
    check();
    _callbacks.add(callback);
    return () => _callbacks.remove(callback);
  }

  void cancel() {
    if (cancelled) return;
    _done.complete();
    for (final callback in _callbacks.toList()) {
      callback();
    }
    _callbacks.clear();
  }

  Future<T> bind<T>(Future<T> future, Duration timeout) {
    check();
    return Future.any<T>([
      future,
      _done.future.then<T>((_) => throw const ScanCancelled()),
    ]).timeout(timeout);
  }
}
