import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class ConnectionInfo {
  final String host;
  final int port;
  final bool isSecure;
  const ConnectionInfo(this.host, this.port, this.isSecure);
}

/// Base class for socket-based clients
abstract class ClientBase {
  static const String initialClient = 'C';
  static const String initialServer = 'S';
  static const String initialApp = 'A';

  String? logName;
  bool isLogEnabled;
  late Socket _socket;
  bool isSocketClosingExpected = false;
  bool isLoggedIn = false;
  bool _isServerGreetingDone = false;
  late ConnectionInfo connectionInfo;
  late Completer<ConnectionInfo> _greetingsCompleter;
  final Duration? defaultWriteTimeout;

  bool _isConnected = false;

  /// [onBadCertificate] is an optional handler for unverifiable certificates. The handler receives the [X509Certificate], and can inspect it and decide (or let the user decide) whether to accept the connection or not.  The handler should return true to continue the [SecureSocket] connection.
  final bool Function(X509Certificate)? onBadCertificate;

  void onDataReceived(Uint8List data);
  void onConnectionEstablished(
      ConnectionInfo connectionInfo, String serverGreeting);
  void onConnectionError(dynamic error);

  late StreamSubscription _socketStreamSubscription;

  /// Creates a new base client
  ///
  /// Set [isLogEnabled] to `true` to see log output.
  /// Set the [logName] for adding the name to each log entry.
  /// Set the [defaultWriteTimeout] in case the connection connection should timeout automatically after the given time.
  /// [onBadCertificate] is an optional handler for unverifiable certificates. The handler receives the [X509Certificate], and can inspect it and decide (or let the user decide) whether to accept the connection or not.  The handler should return true to continue the [SecureSocket] connection.
  ClientBase({
    this.isLogEnabled = false,
    this.logName,
    this.defaultWriteTimeout,
    this.onBadCertificate,
  });

  /// Connects to the specified server.
  ///
  /// Specify [isSecure] if you do not want to connect to a secure service.
  Future<ConnectionInfo> connectToServer(String host, int port,
      {bool isSecure = true}) async {
    log('connecting to server $host:$port - secure: $isSecure',
        initial: initialApp);
    connectionInfo = ConnectionInfo(host, port, isSecure);
    final socket = isSecure
        ? await SecureSocket.connect(
            host,
            port,
            onBadCertificate: onBadCertificate,
          )
        : await Socket.connect(host, port);
    _greetingsCompleter = Completer<ConnectionInfo>();
    _isServerGreetingDone = false;
    connect(socket);
    return _greetingsCompleter.future;
  }

  /// Starts to listen on the given [socket].
  ///
  /// This is mainly useful for testing purposes, ensure to set [connectionInformation] manually in this  case, e.g.
  /// ```dart
  /// await client.connect(socket, connectionInformation: ConnectionInfo(host, port, isSecure));
  /// ```
  void connect(Socket socket, {ConnectionInfo? connectionInformation}) {
    if (connectionInformation != null) {
      connectionInfo = connectionInformation;
      _greetingsCompleter = Completer<ConnectionInfo>();
    }
    _socket = socket;
    _writeFuture = null;
    // if (connectionTimeout != null) {
    //   final timeoutStream = socket.timeout(connectionTimeout!);
    //   _socketStreamSubscription = timeoutStream.listen(
    //     _onDataReceived,
    //     onDone: onConnectionDone,
    //     onError: _onConnectionError,
    //   );
    // } else {
    _socketStreamSubscription = socket.listen(
      _onDataReceived,
      onDone: onConnectionDone,
      onError: _onConnectionError,
    );
    // }
    _isConnected = true;
    isSocketClosingExpected = false;
  }

  void _onConnectionError(Object e, StackTrace s) async {
    log('Socket error: $e $s', initial: initialApp);
    isLoggedIn = false;
    _isConnected = false;
    _writeFuture = null;
    if (!isSocketClosingExpected) {
      isSocketClosingExpected = true;
      try {
        await _socketStreamSubscription.cancel();
      } catch (e, s) {
        log('Unable to cancel stream subscription: $e $s', initial: initialApp);
      }
      try {
        onConnectionError(e);
      } catch (e, s) {
        log('Unable to call onConnectionError: $e, $s', initial: initialApp);
      }
    }
  }

  Future<void> upradeToSslSocket() async {
    _socketStreamSubscription.pause();
    final secureSocket = await SecureSocket.secure(_socket);
    log('now using secure connection.', initial: initialApp);
    await _socketStreamSubscription.cancel();
    isSocketClosingExpected = true;
    _socket.destroy();
    isSocketClosingExpected = false;
    connect(secureSocket);
  }

  void _onDataReceived(Uint8List data) async {
    if (_isServerGreetingDone) {
      onDataReceived(data);
    } else {
      _isServerGreetingDone = true;
      final serverGreeting = String.fromCharCodes(data);
      log(serverGreeting, isClient: false);
      onConnectionEstablished(connectionInfo, serverGreeting);
      _greetingsCompleter.complete(connectionInfo);
    }
  }

  void onConnectionDone() {
    log('Done, connection closed', initial: initialApp);
    isLoggedIn = false;
    _isConnected = false;
    if (!isSocketClosingExpected) {
      isSocketClosingExpected = true;
      onConnectionError('onDone not expected');
    }
  }

  Future<void> disconnect() async {
    if (_isConnected) {
      log('disconnecting', initial: initialApp);
      isLoggedIn = false;
      _isConnected = false;
      isSocketClosingExpected = true;
      try {
        await _socketStreamSubscription.cancel();
      } catch (e) {
        print('unable to cancel subscription $e');
      }
      try {
        await _socket.close();
      } catch (e) {
        print('unable to close socket $e');
      }
    }
  }

  Future? _writeFuture;

  /// Writes the specified [text].
  ///
  /// When the log is enabled it will either log the specified [logObject] or just the [text].
  /// When a [timeout] is specified and occurs, it will either call the [onTimeout] callback or throw a [TimeoutException]
  Future writeText(String text, [dynamic logObject]) async {
    final previousWriteFuture = _writeFuture;
    if (previousWriteFuture != null) {
      try {
        await previousWriteFuture;
      } catch (e, s) {
        print('Unable to await previous write future: $e $s');
        _writeFuture = null;
      }
    }
    if (isLogEnabled) {
      logObject ??= text;
      log(logObject);
    }
    _socket.write(text + '\r\n');
    //TODO A) the generic connectionTimeout is not useful in many cases
    //for example
    // append message / upload message,
    // storing meta data,
    // searching messages,
    // threading messages
    //TODO B) also in some cases the server response is expected in time and requires a timeout
    //options: specify the timeout as parameter
    //   benefits: invidiual timeouts possible
    //   drawbacks: every call must/should be adapted, does not help with b)
    // Differentiate between short- and long-running operations and define commands in the same manner for IMAP, POP and SMTP
    // POP and SMTP are more direct request-response-mechanism, so the below seems quite an overhead just for IMAP
    // Also, when doing a bigger architecture change, how about supporting pipelining IMAP commands?
    // Pipeline for example: LOGIN, CAPABILITY, ID, SELECT (requires to know in advance that those calls work and that LOGIN does not yield capabilities)
    // MailTask<T> {
    // Duration? writeTimeout;
    // Duration? responseTimeout;
    // Completer<T> completer;
    // String? logText;
    // String command;
    // }
    final timeout = defaultWriteTimeout;
    final future = timeout == null
        ? _socket.flush()
        : _socket.flush().timeout(
              timeout,
              //onTimeout: onTimeout,
            );
    _writeFuture = future;
    await future;
    _writeFuture = null;
    if (isLogEnabled) {
      logObject ??= text;
      log('done with writing $logObject');
    }
  }

  // Future<void> onTimeout() async {
  //   log('$logName: timeout', initial: initialApp);
  //   _writeFuture = null;
  //   try {
  //     await _socket.close();
  //   } catch (e, s) {
  //     print('Unable to close socket $e $s');
  //   }
  //   try {
  //     await _socketStreamSubscription.cancel();
  //   } catch (e, s) {
  //     print('Unable to cancel stream subscription $e $s');
  //   }
  // }

  /// Writes the specified [data].
  ///
  /// When the log is enabled it will either log the specified [logObject] or just the length of the data.
  Future writeData(List<int> data, [dynamic logObject]) async {
    final previousWriteFuture = _writeFuture;
    if (previousWriteFuture != null) {
      try {
        await previousWriteFuture;
      } catch (e, s) {
        print('Unable to await previous write future: $e $s');
        _writeFuture = null;
      }
    }
    if (isLogEnabled) {
      logObject ??= '<${data.length} bytes>';
      log(logObject);
    }
    _socket.add(data);
    final future = _socket.flush();
    _writeFuture = future;
    await future;
    _writeFuture = null;
  }

  void log(dynamic logObject, {bool isClient = true, String? initial}) {
    if (isLogEnabled) {
      initial ??= (isClient == true) ? initialClient : initialServer;
      if (logName != null) {
        print('$logName $initial: $logObject');
      } else {
        print('$initial: $logObject');
      }
    }
  }

  void _onTimeout(Completer completer, Duration duration) {
    // print(
    //     '$completer triggers timeout after $duration on $this at ${DateTime.now()}');
    completer.completeError(createClientError('timeout'));
  }

  Object createClientError(String message);
}

extension ExtensionCompleter on Completer {
  void timeout(Duration? duration, ClientBase client) {
    if (duration != null) {
      Future.delayed(duration).then((value) {
        if (!isCompleted) {
          client._onTimeout(this, duration);
        }
      });
    }
  }
}

// class _QueuedText {
//   final String text;
//   final dynamic logObject;
//   _QueuedText(this.text, this.logObject);
// }
