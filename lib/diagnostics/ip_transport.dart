import 'dart:async';
import 'dart:convert';
import 'dart:io';

class IpResponse {
  const IpResponse(this.statusCode, this.headers);
  final int statusCode;
  final Map<String, String> headers;
}

/// Tests plain TLS against an IP while preserving SNI and certificate checks.
class IpTransport {
  IpTransport({required this.address, required this.timeout, this.proxy});
  final String address;
  final Duration timeout;
  final Uri? proxy;
  RawSocket? _tcp;
  RawSecureSocket? _tls;
  ConnectionTask<RawSocket>? _task;
  final _aborted = Completer<void>();
  bool _closed = false;

  Future<IpResponse> getHeaders(Uri uri) async {
    if (uri.scheme != 'https') throw ArgumentError('HTTPS required');
    try {
      return await Future.any<IpResponse>([
        _get(uri),
        _aborted.future.then<IpResponse>(
          (_) => throw const SocketException('Client closed'),
        ),
      ]).timeout(timeout);
    } finally {
      close();
    }
  }

  Future<IpResponse> _get(Uri uri) async {
    _check();
    final task = await RawSocket.startConnect(
      proxy?.host ?? address,
      proxy?.port ?? uri.port,
    );
    _task = task;
    if (_closed) {
      task.cancel();
      _check();
    }
    final tcp = await task.socket;
    _tcp = tcp;
    if (_closed) {
      tcp.close();
      _check();
    }
    StreamSubscription<RawSocketEvent>? subscription;
    if (proxy != null) {
      final authority =
          '${address.contains(':') ? '[$address]' : address}:${uri.port}';
      final connect = await _exchange(
        tcp,
        'CONNECT $authority HTTP/1.1\r\nHost: $authority\r\nProxy-Connection: keep-alive\r\n\r\n',
      );
      subscription = connect.subscription;
      if (connect.response.statusCode != 200) {
        throw HttpException(
          'Proxy CONNECT rejected: ${connect.response.statusCode}',
        );
      }
    }
    _check();
    // Keep the TCP handle so cancellation can interrupt a stalled TLS handshake.
    final tls = await RawSecureSocket.secure(
      tcp,
      subscription: subscription,
      host: uri.host,
      supportedProtocols: ['http/1.1'],
    );
    _tls = tls;
    if (_closed) {
      tls.close();
      _check();
    }
    final path =
        '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    final response = await _exchange(
      tls,
      'GET $path HTTP/1.1\r\nHost: ${uri.authority}\r\n'
      'User-Agent: ECH-Canary/1.0 (connectivity diagnostics)\r\n'
      'Accept-Encoding: identity\r\nConnection: close\r\n\r\n',
    );
    return response.response;
  }

  static Future<
    ({IpResponse response, StreamSubscription<RawSocketEvent> subscription})
  >
  _exchange(RawSocket socket, String request) {
    final done =
        Completer<
          ({
            IpResponse response,
            StreamSubscription<RawSocketEvent> subscription,
          })
        >();
    final outgoing = utf8.encode(request);
    var offset = 0, received = 0;
    var head = '';
    late StreamSubscription<RawSocketEvent> subscription;
    void fail(Object error) {
      if (!done.isCompleted) done.completeError(error);
    }

    void write() {
      if (offset < outgoing.length) offset += socket.write(outgoing, offset);
      socket.writeEventsEnabled = offset < outgoing.length;
    }

    subscription = socket.listen(
      (event) {
        if (done.isCompleted) return;
        try {
          if (event == RawSocketEvent.write) write();
          if (event == RawSocketEvent.read) {
            final chunk = socket.read(32768);
            if (chunk == null) return;
            received += chunk.length;
            if (received > 65536) {
              throw const HttpException('HTTP headers exceed 64 KiB');
            }
            head += latin1.decode(chunk);
            while (head.contains('\r\n\r\n')) {
              final boundary = head.indexOf('\r\n\r\n');
              final lines = head.substring(0, boundary).split('\r\n');
              final match = RegExp(r'^HTTP/1\.[01] (\d{3})(?: |$)')
                  .firstMatch(lines.first);
              if (match == null) {
                throw const HttpException('Invalid HTTP status line');
              }
              final status = int.parse(match.group(1)!);
              head = head.substring(boundary + 4);
              if (status >= 100 && status < 200 && status != 101) continue;
              final headers = <String, String>{};
              for (final line in lines.skip(1)) {
                final colon = line.indexOf(':');
                if (colon <= 0) {
                  throw const HttpException('Invalid HTTP header');
                }
                final key = line.substring(0, colon).trim().toLowerCase();
                final value = line.substring(colon + 1).trim();
                headers.update(
                  key,
                  (old) => '$old, $value',
                  ifAbsent: () => value,
                );
              }
              socket.readEventsEnabled = false;
              done.complete((
                response: IpResponse(status, headers),
                subscription: subscription,
              ));
              return;
            }
          }
          if (event == RawSocketEvent.readClosed ||
              event == RawSocketEvent.closed) {
            fail(
              const HttpException(
                'Connection closed before complete HTTP headers',
              ),
            );
          }
        } catch (error) {
          fail(error);
        }
      },
      onError: fail,
      onDone: () => fail(const HttpException('Connection closed')),
    );
    socket.readEventsEnabled = true;
    write();
    return done.future;
  }

  void _check() {
    if (_closed) throw const SocketException('Client closed');
  }

  void close() {
    _closed = true;
    if (!_aborted.isCompleted) _aborted.complete();
    _task?.cancel();
    _tls?.close();
    _tcp?.close();
  }
}
