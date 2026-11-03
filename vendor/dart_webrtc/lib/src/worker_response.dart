// SPDX-License-Identifier: MIT
class WorkerResponse {
  WorkerResponse(this.msgId, this.data);
  String msgId;
  dynamic data;

  void ensureSuccess() {
    if (data is! Map || (data as Map).containsKey('error')) {
      // Worker diagnostics may contain internal or sensitive data.
      throw StateError('Frame encryption worker rejected the request');
    }
  }
}
