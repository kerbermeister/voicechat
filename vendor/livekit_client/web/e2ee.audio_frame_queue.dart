// Audio packets can progress independently: one slow crypto result must not
// hold later packets. A result older than an emitted packet is no longer useful.
class AudioFrameQueue<T> {
  AudioFrameQueue({required this.emit, required this.onError});

  final void Function(T) emit;
  final void Function(Object, StackTrace) onError;
  final _pending = <Future<void>>{};
  var _next = 0, _emitted = 0;
  var _closed = false;

  void add(Future<void> Function(void Function(T)) process) {
    if (_closed) throw StateError('Audio frame queue is closed');
    // Bound retained encoded frames and crypto jobs during a worker stall.
    if (_pending.length >= 32) return;
    final ordinal = ++_next;
    late final Future<void> task;
    task = Future<void>.sync(
      () => process((frame) {
        if (ordinal <= _emitted) return;
        emit(frame);
        _emitted = ordinal;
      }),
    ).catchError(onError).whenComplete(() => _pending.remove(task));
    _pending.add(task);
  }

  Future<void> close() async {
    _closed = true;
    await Future.wait(_pending);
  }
}
