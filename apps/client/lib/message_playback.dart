/// A single playback lane for messages and drafts, independent of live calls.
class MessagePlayback {
  Object? _owner, _requested;
  Future<void> Function()? _pause;
  Future<void> _transitions = Future.value();
  int _request = 0;

  int request(Object owner) {
    _requested = owner;
    return ++_request;
  }

  Future<bool> start(
    Object owner,
    int request,
    Future<void> Function() play,
    Future<void> Function() pause,
  ) {
    final result = _transitions.catchError((Object _) {}).then((_) async {
      if (request != _request || _requested != owner) return false;
      if (_owner != null && _owner != owner) {
        await _pause!(); // Never start another player if the previous one cannot stop.
        _owner = null;
        _pause = null;
      }
      if (request != _request || _requested != owner) return false;
      _owner = owner;
      _pause = pause;
      try {
        await play();
        if (request != _request) {
          await pause();
          if (_owner == owner) {
            _owner = null;
            _pause = null;
          }
          return false;
        }
        return true;
      } catch (_) {
        // A failed start may already have handed audio to the platform.
        await pause();
        if (_owner == owner) {
          _owner = null;
          _pause = null;
        }
        rethrow;
      }
    });
    _transitions = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  /// Call only after the native resource has finished closing.
  void closed(Object owner) {
    if (_owner == owner) {
      _owner = null;
      _pause = null;
    }
    if (_requested == owner) {
      _requested = null;
      _request++;
    }
  }

  Future<void> pause(Object owner) {
    if (_requested == owner) {
      _requested = null;
      _request++;
    }
    if (_owner != owner) return Future.value();
    final result = _transitions.catchError((Object _) {}).then((_) async {
      if (_owner != owner) return;
      await _pause!();
      _owner = null;
      _pause = null;
    });
    _transitions = result.catchError((Object _) {});
    return result;
  }
}

final messagePlayback = MessagePlayback();
