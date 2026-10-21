/// Only deliberately authored messages may be shown instead of SDK exceptions.
class UserActionError extends StateError {
  UserActionError(super.message);
}
