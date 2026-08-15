import 'dart:io';
import 'package:http/http.dart' as http;

class SteamAuthService {
  static const _steamLogin = 'https://steamcommunity.com/openid/login';
  static const _openIdNs = 'http://specs.openid.net/auth/2.0';
  static const _identifierSelect =
      'http://specs.openid.net/auth/2.0/identifier_select';

  /// Custom scheme the backend redirects to once Steam has responded. The
  /// mobile auth session watches for it and closes the browser on sight.
  static const callbackScheme = 'backlogforge';

  HttpServer? _server;

  /// Login URL for the mobile flow, where Steam redirects to the backend
  /// rather than a loopback server. The backend forwards the OpenID params on
  /// to `[callbackScheme]://auth`, which ends the auth session.
  ///
  /// The hop exists because Steam requires an http(s) realm and rejects custom
  /// schemes in `return_to`, so the app cannot be the redirect target itself.
  Uri buildBackendLoginUrl(String backendUrl) {
    final base = backendUrl.endsWith('/')
        ? backendUrl.substring(0, backendUrl.length - 1)
        : backendUrl;
    return Uri.parse(_steamLogin).replace(
      queryParameters: {
        'openid.ns': _openIdNs,
        'openid.mode': 'checkid_setup',
        'openid.return_to': '$base/auth/steam/callback',
        'openid.realm': base,
        'openid.identity': _identifierSelect,
        'openid.claimed_id': _identifierSelect,
      },
    );
  }

  /// Binds to a free local port, then constructs the Steam OpenID 2.0 login URL.
  /// Uses port 0 so the OS picks an available port instead of failing on a busy fixed port.
  Future<Uri> buildLoginUrl() async {
    // Bind the InternetAddress directly rather than the string '127.0.0.1':
    // the string form goes through an address lookup, which can fail with a
    // SocketException on Android.
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = _server!.port;
    return Uri.parse(_steamLogin).replace(
      queryParameters: {
        'openid.ns': 'http://specs.openid.net/auth/2.0',
        'openid.mode': 'checkid_setup',
        'openid.return_to': 'http://127.0.0.1:$port/auth',
        'openid.realm': 'http://127.0.0.1:$port',
        'openid.identity': 'http://specs.openid.net/auth/2.0/identifier_select',
        'openid.claimed_id': 'http://specs.openid.net/auth/2.0/identifier_select',
      },
    );
  }

  /// Waits for Steam's redirect on the server started by [buildLoginUrl].
  /// Skips any browser prefetch / favicon requests until the real /auth arrives.
  Future<Uri> awaitRedirect() async {
    final server = _server!;
    try {
      await for (final request in server) {
        if (request.uri.path != '/auth') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          continue;
        }
        final redirectUri = request.requestedUri;
        request.response
          ..headers.contentType = ContentType.html
          ..write(
            '<html><body style="font-family:sans-serif;text-align:center;'
            'padding:40px"><h2>Signed in!</h2>'
            '<p>Returning to BacklogForge…</p></body></html>',
          );
        await request.response.close();
        return redirectUri;
      }
      throw StateError('Sign-in server closed before receiving Steam redirect');
    } finally {
      _server = null;
      await server.close(force: true);
    }
  }

  /// Verifies the Steam OpenID response signature via check_authentication,
  /// then extracts and returns the Steam ID. Returns null if invalid.
  Future<String?> extractAndVerifySteamId(Uri redirect) async {
    const prefix = 'https://steamcommunity.com/openid/id/';
    final claimedId = redirect.queryParameters['openid.claimed_id'];
    if (claimedId == null || !claimedId.startsWith(prefix)) return null;

    // Ask Steam to confirm the signed response is authentic.
    final params = Map<String, String>.from(redirect.queryParameters);
    params['openid.mode'] = 'check_authentication';
    final res = await http
        .post(Uri.parse(_steamLogin), body: params)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200 || !res.body.contains('is_valid:true')) return null;

    return claimedId.substring(prefix.length);
  }
}
