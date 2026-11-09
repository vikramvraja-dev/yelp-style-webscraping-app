import 'dart:async';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';

/// Shared, policy-aware access to the configured Nominatim service.
///
/// A single queue enforces the public service's app-wide request limit. The
/// in-memory caches avoid duplicate requests without persisting users' search
/// terms or locations to disk.
class NominatimClient {
  static const Duration _minimumRequestGap = Duration(milliseconds: 1100);

  static final Map<String, http.Response> _responseCache = {};
  static final Map<String, Future<http.Response>> _inFlightRequests = {};
  static Future<void> _requestQueue = Future<void>.value();
  static DateTime? _lastRequestAt;

  static Uri buildUri(String endpoint, Map<String, String> parameters) {
    final baseUri = Uri.parse(AppConfig.nominatimBaseUrl);
    final queryParameters = Map<String, String>.of(parameters);
    final contactEmail = AppConfig.nominatimContactEmail.trim();
    if (contactEmail.isNotEmpty) {
      queryParameters['email'] = contactEmail;
    }

    final basePath = baseUri.path == '/'
        ? ''
        : baseUri.path.replaceFirst(RegExp(r'/$'), '');
    final endpointPath = endpoint.startsWith('/') ? endpoint : '/$endpoint';

    return baseUri.replace(
      path: '$basePath$endpointPath',
      queryParameters: queryParameters,
    );
  }

  static Future<http.Response> get(Uri uri) async {
    final cacheKey = uri.toString();
    final cachedResponse = _responseCache[cacheKey];
    if (cachedResponse != null) return cachedResponse;

    final existingRequest = _inFlightRequests[cacheKey];
    if (existingRequest != null) return existingRequest;

    final request = _enqueue(uri);
    _inFlightRequests[cacheKey] = request;

    try {
      return await request;
    } finally {
      if (identical(_inFlightRequests[cacheKey], request)) {
        _inFlightRequests.remove(cacheKey);
      }
    }
  }

  static Future<http.Response> _enqueue(Uri uri) {
    final completer = Completer<http.Response>();

    _requestQueue = _requestQueue.then((_) async {
      try {
        final now = DateTime.now();
        if (_lastRequestAt != null) {
          final elapsed = now.difference(_lastRequestAt!);
          if (elapsed < _minimumRequestGap) {
            await Future<void>.delayed(_minimumRequestGap - elapsed);
          }
        }

        _lastRequestAt = DateTime.now();
        final response = await http.get(uri, headers: _headers());
        if (response.statusCode >= 200 && response.statusCode < 300) {
          _responseCache[uri.toString()] = response;
        }
        completer.complete(response);
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });

    return completer.future;
  }

  static Map<String, String> _headers() {
    return {
      'User-Agent': AppConfig.nominatimUserAgent,
      'Accept': 'application/json,text/plain,*/*',
      'Accept-Language': 'en-US,en;q=0.9',
    };
  }
}
