import 'dart:async';
import 'dart:convert';
import 'dart:html';
import 'dart:typed_data';

import '../adapter.dart';
import '../dio_error.dart';
import '../headers.dart';
import '../options.dart';

HttpClientAdapter createAdapter() => BrowserHttpClientAdapter();

class BrowserHttpClientAdapter implements HttpClientAdapter {
  /// These are aborted if the client is closed.
  final _xhrs = <HttpRequest>{};

  /// Whether to send credentials such as cookies or authorization headers for
  /// cross-site requests.
  ///
  /// Defaults to `false`.
  ///
  /// You can also override this value in
  /// Options.extra['withCredentials'] for each request
  bool withCredentials = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future? cancelFuture,
  ) async {
    final xhr = HttpRequest();
    _xhrs.add(xhr);
    xhr
      ..open(options.method, '${options.uri}')
      ..responseType = 'arraybuffer';

    final _withCredentials = options.extra['withCredentials'];

    if (_withCredentials != null) {
      xhr.withCredentials = _withCredentials == true;
    } else {
      xhr.withCredentials = withCredentials;
    }

    options.headers.remove(Headers.contentLengthHeader);
    options.headers.forEach((key, v) => xhr.setRequestHeader(key, '$v'));

    final completer = Completer<ResponseBody>();
    Completer<void>? connectTO;
    Completer<void>? sendTO;
    Completer<void>? receiveTO;

    xhr.onLoad.first.then((_) {
      completer.complete(
        ResponseBody.fromBytes(
          (xhr.response as ByteBuffer).asUint8List(),
          xhr.status,
          headers: xhr.responseHeaders.map((k, v) => MapEntry(k, v.split(','))),
          statusMessage: xhr.statusText,
          isRedirect: xhr.status == 302 || xhr.status == 301,
        ),
      );
    });

    connectTO ??= _handleConnectTimeOut(xhr, options, completer);

    xhr.upload.onProgress.listen((event) {
      _completeTimeOuts([connectTO]);
      sendTO ??= _handleSendTimeOut(xhr, options, completer);

      if (options.onSendProgress != null &&
          event.loaded != null &&
          event.total != null) {
        options.onSendProgress!(event.loaded!, event.total!);
      }
    });

    xhr.onProgress.listen((event) {
      _completeTimeOuts([connectTO, sendTO]);
      receiveTO ??= _handleReceiveTimeOut(xhr, options, completer);

      if (options.onReceiveProgress != null &&
          event.loaded != null &&
          event.total != null) {
        options.onReceiveProgress!(event.loaded!, event.total!);
      }
    });

    xhr.onError.first.then((_) {
      // Unfortunately, the underlying XMLHttpRequest API doesn't expose any
      // specific information about the error itself.
      completer.completeError(
        DioError(
          type: DioErrorType.response,
          error: 'XMLHttpRequest error.',
          requestOptions: options,
        ),
        StackTrace.current,
      );
    });

    cancelFuture?.then((err) {
      if (xhr.readyState < 4 && xhr.readyState > 0) {
        try {
          xhr.abort();
        } catch (e) {
          // ignore
        }

        // xhr.onError will not triggered when xhr.abort() called.
        // so need to manual throw the cancel error to avoid Future hang ups.
        // or added xhr.onAbort like axios did
        // https://github.com/axios/axios/blob/master/lib/adapters/xhr.js#L102-L111
        if (!completer.isCompleted) {
          completer.completeError(err);
        }
      }
    });

    if (requestStream != null) {
      final _completer = Completer<Uint8List>();
      final sink = ByteConversionSink.withCallback(
        (bytes) => _completer.complete(Uint8List.fromList(bytes)),
      );
      requestStream.listen(
        sink.add,
        onError: _completer.completeError,
        onDone: sink.close,
        cancelOnError: true,
      );
      final bytes = await _completer.future;
      xhr.send(bytes);
    } else {
      xhr.send();
    }

    return completer.future.whenComplete(() {
      _completeTimeOuts([connectTO, sendTO, receiveTO]);

      _xhrs.remove(xhr);
    });
  }

  /// Closes the client.
  ///
  /// This terminates all active requests.
  @override
  void close({bool force = false}) {
    if (force) {
      for (var xhr in _xhrs) {
        xhr.abort();
      }
    }
    _xhrs.clear();
  }

  Completer<void>? _handleConnectTimeOut(
    HttpRequest xhr,
    RequestOptions options,
    Completer<ResponseBody> completer,
  ) {
    if (options.connectTimeout <= 0) return null;

    return Completer<void>()
      ..future.timeout(Duration(milliseconds: options.connectTimeout)).then(
        (value) {
          if (!completer.isCompleted) {
            completer.completeError(
              DioError(
                requestOptions: options,
                error: 'Connecting timed out [${options.connectTimeout}ms]',
                type: DioErrorType.connectTimeout,
              ),
              StackTrace.current,
            );
            xhr.abort();
          }
        },
      );
  }

  Completer<void>? _handleSendTimeOut(
    HttpRequest xhr,
    RequestOptions options,
    Completer<ResponseBody> completer,
  ) {
    if (options.sendTimeout <= 0) return null;

    return Completer<void>()
      ..future.timeout(Duration(milliseconds: options.sendTimeout)).then(
        (value) {
          if (!completer.isCompleted) {
            completer.completeError(
              DioError(
                requestOptions: options,
                error: 'Sending timed out [${options.sendTimeout}ms]',
                type: DioErrorType.sendTimeout,
              ),
              StackTrace.current,
            );
            xhr.abort();
          }
        },
      );
  }

  Completer<void>? _handleReceiveTimeOut(
    HttpRequest xhr,
    RequestOptions options,
    Completer<ResponseBody> completer,
  ) {
    if (options.receiveTimeout <= 0) return null;

    return Completer<void>()
      ..future.timeout(Duration(milliseconds: options.receiveTimeout)).then(
        (value) {
          if (!completer.isCompleted) {
            completer.completeError(
              DioError(
                requestOptions: options,
                error: 'Receiving timed out [${options.receiveTimeout}ms]',
                type: DioErrorType.receiveTimeout,
              ),
              StackTrace.current,
            );
            xhr.abort();
          }
        },
      );
  }

  void _completeTimeOuts(List<Completer<void>?> completers) {
    for (var completer in completers) {
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
    }
  }
}
