import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import 'config/app_config.dart';
import 'services/nominatim_client.dart';

class Restaurant {
  final String id;
  final String name;
  final String rating;
  final String location;
  final String imageUrl;
  final double latitude;
  final double longitude;
  final String url;
  String dateAdded;
  String? localImagePath;
  String? notes;

  Restaurant({
    required this.id,
    required this.name,
    required this.rating,
    required this.location,
    required this.imageUrl,
    required this.latitude,
    required this.longitude,
    required this.url,
    required this.dateAdded,
    this.localImagePath,
    this.notes,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'rating': rating,
      'location': location,
      'imageUrl': imageUrl,
      'latitude': latitude,
      'longitude': longitude,
      'url': url,
      'dateAdded': dateAdded,
      'localImagePath': localImagePath,
      'notes': notes,
    };
  }

  factory Restaurant.fromMap(Map<String, dynamic> map) {
    return Restaurant(
      id: map['id'],
      name: map['name'],
      rating: map['rating'],
      location: map['location'],
      imageUrl: map['imageUrl'],
      latitude: map['latitude'],
      longitude: map['longitude'],
      url: map['url'] ?? '',
      dateAdded: map['dateAdded'],
      localImagePath: map['localImagePath'],
      notes: map['notes'],
    );
  }
}

class MasterRestaurantService {
  // Register your active scrapers here
  final List<RestaurantScraper> scrapers = [
    //back up API
    YelpFusionAPI(),
    //being blocked by cloudflare
    RestaurantJiScraper(),
    TripAdvisorScraper(),
    // Add GoogleMapsScraper(), TripadvisorScraper(), etc. later
  ];

  Future<List<Restaurant>> getRestaurants({
    required String location,
    String term = 'restaurants',
  }) async {
    final futures = scrapers.map((scraper) async {
      try {
        return await scraper.getRestaurants(location: location, term: term);
      } catch (e) {

        print('${scraper.runtimeType} encountered an error: $e');
        return <Restaurant>[];
      }
    });

    final List<List<Restaurant>> resultsList = await Future.wait(futures);

    final allRestaurants = resultsList.expand((list) => list).toList();

    return allRestaurants;
  }

  Future<List<Restaurant>> getRestaurantsByLocation({
    required double latitude,
    required double longitude,
    String term = 'restaurants',
  }) async {
    final futures = scrapers.map((scraper) async {
      try {
        return await scraper.getRestaurantsByLocation(
            latitude: latitude, longitude: longitude, term: term);
      } catch (e) {
        print('${scraper.runtimeType} encountered an error: $e');
        return <Restaurant>[];
      }
    });

    final resultsList = await Future.wait(futures);
    return resultsList.expand((list) => list).toList();
  }
}

abstract class RestaurantScraper {
  Future<List<Restaurant>> getRestaurants({
    required String location,
    String term = 'restaurants',
  });

  Future<List<Restaurant>> getRestaurantsByLocation({
    required double latitude,
    required double longitude,
    String term = 'restaurants',
  });
}

class RestaurantJiScraper implements RestaurantScraper {
  static const String _placeholderImage = 'https://via.placeholder.com/400';
  static const int _resultLimit = 20;
  static const int _detailInspectionLimit = 30;
  static const int _minPreferredResults = 8;
  static const String _appUserAgent = AppConfig.applicationUserAgent;

  final Map<String, List<double>> _geocodeCache = {};
  final Map<String, _CityInfo> _cityCache = {};
  final Map<String, _ScrapedRestaurant?> _detailCache = {};
  final Map<String, List<Restaurant>> _searchCache = {};

  @override
  Future<List<Restaurant>> getRestaurants({
    required String location,
    String term = 'restaurants',
  }) async {
    final cityInfo = await _resolveLocation(location);
    if (cityInfo == null) {
      print('Could not resolve location: $location');
      return [];
    }
    return _scrapeRestaurantJiCity(cityInfo, term);
  }

  @override
  Future<List<Restaurant>> getRestaurantsByLocation({
    required double latitude,
    required double longitude,
    String term = 'restaurants',
  }) async {
    final cityInfo = await _reverseResolveLocation(latitude, longitude);
    if (cityInfo == null) {
      print('Could not reverse resolve location: $latitude,$longitude');
      return [];
    }
    return _scrapeRestaurantJiCity(cityInfo, term);
  }

  Future<List<Restaurant>> _scrapeRestaurantJiCity(
    _CityInfo cityInfo,
    String term,
  ) async {
    final normalizedTerm = term.trim().toLowerCase();
    final cacheKey = '${cityInfo.restaurantJiUrl}|$normalizedTerm';
    final cached = _searchCache[cacheKey];
    if (cached != null) {
      return cached.map(_cloneRestaurant).toList();
    }

    final cityUri = Uri.parse(cityInfo.restaurantJiUrl);

    try {
      final response = await http.get(cityUri, headers: _browserHeaders());
      if (response.statusCode != 200) {
        print(
          'Restaurantji city page error: ${response.statusCode} ${cityUri.toString()}',
        );
        return [];
      }

      final doc = html_parser.parse(response.body);
      final candidates = _extractCityCandidates(doc, cityInfo);
      if (candidates.isEmpty) {
        print(
          'Restaurantji city page parsed but no restaurant cards were found: ${cityUri.toString()}',
        );
        return [];
      }

      final quickMatches = candidates
          .where((candidate) => _matchesTerm(candidate.searchText, normalizedTerm))
          .toList();

      final matchingCandidates = <_CityCandidate>[];
      matchingCandidates.addAll(quickMatches.take(_resultLimit));

      if (normalizedTerm.isNotEmpty &&
          normalizedTerm != 'restaurants' &&
          matchingCandidates.length < _minPreferredResults) {
        final moreMatches = await _fallbackMatchByDetail(
          candidates,
          normalizedTerm,
          exclude: matchingCandidates.map((candidate) => candidate.detailUrl).toSet(),
          limit: _resultLimit - matchingCandidates.length,
        );
        for (final candidate in moreMatches) {
          if (matchingCandidates.any(
            (existing) => existing.detailUrl == candidate.detailUrl,
          )) {
            continue;
          }
          matchingCandidates.add(candidate);
          if (matchingCandidates.length >= _resultLimit) break;
        }
      }

      if (matchingCandidates.isEmpty) {
        _searchCache[cacheKey] = const [];
        print(
          'Restaurantji parsed 0 restaurants for ${cityInfo.cityDisplay}, ${cityInfo.stateAbbrev} / $term',
        );
        return [];
      }

      final results = await _hydrateCandidates(
        matchingCandidates.take(_resultLimit).toList(),
        cityInfo,
      );
      _searchCache[cacheKey] = results.map(_cloneRestaurant).toList();
      final mappedCount =
          results.where((r) => r.latitude != 0 && r.longitude != 0).length;
      print(
        'Restaurantji parsed ${results.length} restaurants for ${cityInfo.cityDisplay}, ${cityInfo.stateAbbrev} / $term',
      );
      print(
        'Restaurantji mapped $mappedCount / ${results.length} restaurants for ${cityInfo.cityDisplay}, ${cityInfo.stateAbbrev} / $term',
      );
      return results;
    } catch (e) {
      print('Restaurantji scrape error: $e');
      return [];
    }
  }

  List<_CityCandidate> _extractCityCandidates(dom.Document doc, _CityInfo cityInfo) {
    final seen = <String>{};
    final candidates = <_CityCandidate>[];
    final cityPrefix = '/${cityInfo.stateSlug}/${cityInfo.citySlug}/';

    for (final anchor in doc.querySelectorAll('a[href]')) {
      final href = anchor.attributes['href']?.trim() ?? '';
      if (!_isRestaurantDetailHref(href, cityPrefix)) continue;

      final name = _collapseWhitespace(anchor.text);
      if (name.isEmpty) continue;

      final detailUrl = _normalizeUrl(href, base: 'https://www.restaurantji.com');
      if (!seen.add(detailUrl)) continue;

      final cardText = _extractCardText(anchor, cityPrefix);
      final ratingValue = _extractCardRating(cardText);
      final searchText =
          '$name $cardText ${cityInfo.cityDisplay} ${cityInfo.stateAbbrev}'
              .toLowerCase();

      candidates.add(
        _CityCandidate(
          name: name,
          detailUrl: detailUrl,
          rating: ratingValue,
          searchText: searchText,
        ),
      );
    }

    return candidates;
  }

  bool _isRestaurantDetailHref(String href, String cityPrefix) {
    if (!href.startsWith(cityPrefix) || href == cityPrefix) return false;
    if (href.contains('/page/') ||
        href.contains('/menu/') ||
        href.contains('/photos/')) {
      return false;
    }

    final path = Uri.parse(href).path;
    final segments =
        path.split('/').where((segment) => segment.isNotEmpty).toList();
    if (segments.length != 3) return false;

    final slug = segments.last;
    return !_isCategorySlug(slug);
  }

  String _extractCardText(dom.Element anchor, String cityPrefix) {
    dom.Element? current = anchor.parent;
    String best = _collapseWhitespace(anchor.parent?.text ?? anchor.text);

    for (int depth = 0; current != null && depth < 6; depth++) {
      final text = _collapseWhitespace(current.text);
      if (text.isEmpty) {
        current = current.parent;
        continue;
      }

      final nestedRestaurantLinks = current
          .querySelectorAll('a[href]')
          .where((candidate) => _isRestaurantDetailHref(
                candidate.attributes['href']?.trim() ?? '',
                cityPrefix,
              ))
          .length;

      if (text.length >= 60 &&
          text.length <= 1800 &&
          nestedRestaurantLinks <= 2) {
        best = text;
        break;
      }

      if (text.length > best.length &&
          text.length <= 2200 &&
          nestedRestaurantLinks <= 4) {
        best = text;
      }

      current = current.parent;
    }

    return best;
  }

  String _extractCardRating(String cardText) {
    final reviewPattern = RegExp(
      r'(\d\.\d)\s+(?:Superb|Good|Average|Poor|ratings?)',
      caseSensitive: false,
    );
    final match = reviewPattern.firstMatch(cardText);
    if (match != null) return match.group(1)!;

    final simple = RegExp(r'\b(\d\.\d)\b').firstMatch(cardText);
    return simple?.group(1) ?? '0.0';
  }

  Future<List<_CityCandidate>> _fallbackMatchByDetail(
    List<_CityCandidate> candidates,
    String normalizedTerm, {
    Set<String>? exclude,
    int? limit,
  }) async {
    final matches = <_CityCandidate>[];
    final excluded = exclude ?? <String>{};
    final maxResults = limit ?? _resultLimit;

    final unmatched = candidates
        .where((candidate) => !excluded.contains(candidate.detailUrl))
        .toList();

    for (final candidate in unmatched.take(_detailInspectionLimit)) {
      final detail = await _scrapeRestaurantDetail(
        candidate.detailUrl,
        geocodeAddress: false,
        fallbackName: candidate.name,
        fallbackRating: candidate.rating,
      );

      if (detail != null && _matchesTerm(detail.searchText, normalizedTerm)) {
        matches.add(candidate);
      }

      if (matches.length >= maxResults) break;
    }

    return matches;
  }

  Future<List<Restaurant>> _hydrateCandidates(
    List<_CityCandidate> candidates,
    _CityInfo cityInfo,
  ) async {
    final hydrated = <Restaurant>[];
    final cityFallback = '${cityInfo.cityDisplay}, ${cityInfo.stateAbbrev}';

    for (final candidate in candidates) {
      final detail = await _scrapeRestaurantDetail(
        candidate.detailUrl,
        geocodeAddress: true,
        fallbackName: candidate.name,
        fallbackRating: candidate.rating,
        fallbackLocation: cityFallback,
      );

      if (detail != null) {
        hydrated.add(detail.restaurant);
      } else {
        hydrated.add(
          Restaurant(
            id: _makeId(candidate.detailUrl, candidate.name),
            name: candidate.name,
            rating: '⭐ ${candidate.rating}',
            location: cityFallback,
            imageUrl: _placeholderImage,
            latitude: 0.0,
            longitude: 0.0,
            url: candidate.detailUrl,
            dateAdded: 'Not added yet',
          ),
        );
      }
    }

    return hydrated;
  }

  bool _isCategorySlug(String slug) {
    const categorySlugs = {
      'american',
      'asian',
      'bakery',
      'bar',
      'bbq',
      'breakfast',
      'brunch',
      'burgers',
      'cafe',
      'chicken',
      'chinese',
      'coffee',
      'desserts',
      'fast-food',
      'hot-dogs',
      'ice-cream',
      'indian',
      'italian',
      'japanese',
      'korean',
      'mexican',
      'middle-eastern',
      'pizza',
      'seafood',
      'steakhouse',
      'sushi',
      'thai',
      'vegan',
      'vegetarian',
    };
    return categorySlugs.contains(slug);
  }

  Future<_ScrapedRestaurant?> _scrapeRestaurantDetail(
    String detailUrl, {
    required bool geocodeAddress,
    String? fallbackName,
    String? fallbackRating,
    String? fallbackLocation,
  }) async {
    if (_detailCache.containsKey(detailUrl)) {
      final cached = _detailCache[detailUrl];
      if (cached == null) return null;
      final hasCoords =
          cached.restaurant.latitude != 0 || cached.restaurant.longitude != 0;
      if (!geocodeAddress ||
          hasCoords ||
          cached.restaurant.location == fallbackLocation) {
        return cached;
      }
    }

    try {
      final response =
          await http.get(Uri.parse(detailUrl), headers: _browserHeaders());
      if (response.statusCode != 200) {
        print('Restaurantji detail error: ${response.statusCode} $detailUrl');
        _detailCache[detailUrl] = null;
        return null;
      }

      final doc = html_parser.parse(response.body);
      final bodyText = _collapseWhitespace(doc.body?.text ?? '');
      final name = doc.querySelector('h1')?.text.trim() ?? fallbackName ?? '';
      if (name.isEmpty) {
        _detailCache[detailUrl] = null;
        return null;
      }

      final ratingValue = RegExp(
            r'\b(\d\.\d)\b\s+\d+\s+ratings',
            caseSensitive: false,
          ).firstMatch(bodyText)?.group(1) ??
          fallbackRating ??
          '0.0';
      final cuisine = _extractCuisineLine(bodyText, name);
      final rawAddress = _extractAddress(doc, bodyText);
      final address = _normalizeAddress(rawAddress, fallbackLocation);
      final websiteUrl = _extractWebsite(doc) ?? detailUrl;
      final imageUrl = _extractImage(doc);

      List<double> coords = _extractCoordinates(doc, bodyText);
      if (coords[0] == 0.0 && coords[1] == 0.0 && geocodeAddress) {
        coords = await _geocodeRestaurant(
          name: name,
          address: address,
          fallbackLocation: fallbackLocation,
        );
      }

      final restaurant = Restaurant(
        id: _makeId(detailUrl, name),
        name: name,
        rating: '⭐ $ratingValue',
        location:
            address.isNotEmpty ? address : (fallbackLocation ?? 'Unknown Location'),
        imageUrl: imageUrl,
        latitude: coords[0],
        longitude: coords[1],
        url: websiteUrl,
        dateAdded: 'Not added yet',
      );

      final scraped = _ScrapedRestaurant(
        restaurant: restaurant,
        searchText:
            '${restaurant.name} ${restaurant.location} $cuisine $bodyText'
                .toLowerCase(),
      );
      _detailCache[detailUrl] = scraped;
      return scraped;
    } catch (e) {
      print('Restaurantji detail parse error: $e ($detailUrl)');
      _detailCache[detailUrl] = null;
      return null;
    }
  }

  List<double> _extractCoordinates(dom.Document doc, String bodyText) {
    double? lat;
    double? lon;

    for (final meta in doc.querySelectorAll('meta')) {
      final property =
          (meta.attributes['property'] ?? meta.attributes['name'] ?? '')
              .toLowerCase();
      final content = meta.attributes['content']?.trim() ?? '';
      if (content.isEmpty) continue;

      if (property.contains('latitude')) {
        lat ??= double.tryParse(content);
      } else if (property.contains('longitude') || property.contains('lon')) {
        lon ??= double.tryParse(content);
      }
    }

    if (lat != null && lon != null) return [lat, lon];

    for (final script in doc.querySelectorAll('script[type="application/ld+json"]')) {
      final coords = _extractCoordinatesFromJsonLike(script.text);
      if (coords[0] != 0.0 || coords[1] != 0.0) return coords;
    }

    for (final element in doc.querySelectorAll('[href], [src], [data-src], iframe')) {
      final candidates = [
        element.attributes['href'],
        element.attributes['src'],
        element.attributes['data-src'],
      ].whereType<String>();

      for (final value in candidates) {
        final coords = _extractCoordinatesFromText(value);
        if (coords[0] != 0.0 || coords[1] != 0.0) return coords;
      }
    }

    final scriptText = doc.querySelectorAll('script').map((script) => script.text).join(' ');

    final coordsFromScripts = _extractCoordinatesFromText(scriptText);
    if (coordsFromScripts[0] != 0.0 || coordsFromScripts[1] != 0.0) {
      return coordsFromScripts;
    }

    final coordsFromBody = _extractCoordinatesFromText(bodyText);
    if (coordsFromBody[0] != 0.0 || coordsFromBody[1] != 0.0) {
      return coordsFromBody;
    }

    return const [0.0, 0.0];
  }

  List<double> _extractCoordinatesFromJsonLike(String input) {
    try {
      final dynamic decoded = jsonDecode(input);
      final coords = _walkForCoordinates(decoded);
      if (coords[0] != 0.0 || coords[1] != 0.0) return coords;
    } catch (_) {}
    return _extractCoordinatesFromText(input);
  }

  List<double> _walkForCoordinates(dynamic value) {
    if (value is Map) {
      final lat = _toDouble(value['latitude'] ?? value['lat']);
      final lon = _toDouble(value['longitude'] ?? value['lng'] ?? value['lon']);
      if (lat != null && lon != null && _looksLikeCoordinatePair(lat, lon)) {
        return [lat, lon];
      }
      for (final child in value.values) {
        final coords = _walkForCoordinates(child);
        if (coords[0] != 0.0 || coords[1] != 0.0) return coords;
      }
    } else if (value is List) {
      for (final child in value) {
        final coords = _walkForCoordinates(child);
        if (coords[0] != 0.0 || coords[1] != 0.0) return coords;
      }
    }
    return const [0.0, 0.0];
  }

  List<double> _extractCoordinatesFromText(String text) {
    if (text.isEmpty) return const [0.0, 0.0];

    final patterns = <RegExp>[
      RegExp(
        r'latitude[^\d-]*(-?\d{1,2}\.\d+)[^\d-]+longitude[^\d-]*(-?\d{1,3}\.\d+)',
        caseSensitive: false,
      ),
      RegExp(
        r'lat[^\d-:=]*[:=]\s*(-?\d{1,2}\.\d+)[^\d-]+(?:lng|lon|longitude)[^\d-:=]*[:=]\s*(-?\d{1,3}\.\d+)',
        caseSensitive: false,
      ),
      RegExp(r'@(-?\d{1,2}\.\d+),(-?\d{1,3}\.\d+)', caseSensitive: false),
      RegExp(r'query=(-?\d{1,2}\.\d+),(-?\d{1,3}\.\d+)', caseSensitive: false),
      RegExp(r'center=(-?\d{1,2}\.\d+),(-?\d{1,3}\.\d+)', caseSensitive: false),
      RegExp(r'(-?\d{1,2}\.\d+)\s*,\s*(-?\d{1,3}\.\d+)'),
    ];

    for (final pattern in patterns) {
      for (final match in pattern.allMatches(text)) {
        final a = double.tryParse(match.group(1) ?? '');
        final b = double.tryParse(match.group(2) ?? '');
        if (a != null && b != null && _looksLikeCoordinatePair(a, b)) {
          return [a, b];
        }
      }
    }

    return const [0.0, 0.0];
  }

  bool _looksLikeCoordinatePair(double lat, double lon) {
    return lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180;
  }

  double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  bool _matchesTerm(String haystack, String normalizedTerm) {
    if (normalizedTerm.isEmpty || normalizedTerm == 'restaurants') return true;

    final normalizedHaystack = haystack.toLowerCase();
    if (normalizedHaystack.contains(normalizedTerm)) return true;

    final tokens = _termTokens(normalizedTerm);
    if (tokens.isEmpty) return true;

    final expandedTokens = <String>{};
    for (final token in tokens) {
      expandedTokens.add(token);
      expandedTokens.addAll(_termSynonyms[token] ?? const <String>[]);
    }

    final tokenMatches =
        expandedTokens.where((token) => normalizedHaystack.contains(token)).length;

    if (tokens.length == 1) {
      return tokenMatches > 0;
    }

    return tokenMatches >= tokens.length;
  }

  List<String> _termTokens(String normalizedTerm) {
    return normalizedTerm
        .split(RegExp(r'[^a-z0-9]+'))
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty && !_ignoredSearchTerms.contains(token))
        .toList();
  }

  String _extractCuisineLine(String text, String name) {
    final escapedName = RegExp.escape(name);
    final match = RegExp(
      '$escapedName\\s+(.+?)\\s+Hours:',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(text);

    final line = match?.group(1) ?? '';
    return line.replaceAll('•', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _extractAddress(dom.Document doc, String text) {
    final pageText = _collapseWhitespace(text);
    final sectionPattern = RegExp(
      r'Location\s*&\s*Contact\s+(.+?)(?:\(\d{3}\)|Website|Order Online|Suggest an Edit|Take-Out/Delivery Options)',
      caseSensitive: false,
      dotAll: true,
    );
    final sectionMatch = sectionPattern.firstMatch(pageText);
    if (sectionMatch != null) {
      final inSection = _extractAddressLike(sectionMatch.group(1) ?? '');
      if (inSection.isNotEmpty) return inSection;
    }

    final hoursMatch = RegExp(
      r'Hours:\s+(.+?)(?:\(\d{3}\)|Menu|Order Online|About)',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(pageText);
    if (hoursMatch != null) {
      final afterHours = _extractAddressLike(hoursMatch.group(1) ?? '');
      if (afterHours.isNotEmpty) return afterHours;
    }

    for (final element in doc.querySelectorAll('a[href], span, div, p')) {
      final candidate = _collapseWhitespace(element.text);
      final address = _extractAddressLike(candidate);
      if (address.isNotEmpty) return address;
    }

    return '';
  }

  String _extractAddressLike(String input) {
    final value = _collapseWhitespace(input);
    if (value.isEmpty) return '';

    final patterns = <RegExp>[
      RegExp(
        r'''\b\d{1,6}\s+[A-Za-z0-9.#&\- ]+?,\s*[A-Za-z .\-']+?,\s*[A-Z]{2}\s*\d{5}(?:-\d{4})?\b''',
      ),
      RegExp(
        r'''\b\d{1,6}\s+[A-Za-z0-9.#&\- ]+?,\s*[A-Za-z .\-']+\s*\d{5}(?:-\d{4})?\b''',
      ),
      RegExp(
        r'''\b\d{1,6}\s+[A-Za-z0-9.#&\- ]+?,\s*[A-Za-z .\-']+\b''',
      ),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(value);
      if (match != null) {
        return _collapseWhitespace(match.group(0) ?? '');
      }
    }
    return '';
  }

  String _normalizeAddress(String rawAddress, String? fallbackLocation) {
    final address = _collapseWhitespace(rawAddress);
    if (address.isEmpty) return '';

    if (RegExp(r',\s*[A-Z]{2}\s*\d{5}(?:-\d{4})?$').hasMatch(address)) {
      return address;
    }

    if (fallbackLocation == null || fallbackLocation.trim().isEmpty) {
      return address;
    }

    final fallback = _collapseWhitespace(fallbackLocation);
    if (address.toLowerCase().contains(fallback.toLowerCase())) {
      return address;
    }

    String? state;
    String? city;
    final fullFallbackMatch = RegExp(r'^(.+?),\s*([A-Z]{2})$').firstMatch(fallback);
    if (fullFallbackMatch != null) {
      city = fullFallbackMatch.group(1);
      state = fullFallbackMatch.group(2);
    }

    if (state != null && city != null) {
      final cityZipPattern = RegExp(
        ',\\s*${RegExp.escape(city)}\\s+(\\d{5}(?:-\\d{4})?)\$',
        caseSensitive: false,
      );
      if (cityZipPattern.hasMatch(address)) {
        return address.replaceFirst(
          cityZipPattern,
          ', $city, $state ${cityZipPattern.firstMatch(address)!.group(1)!}',
        );
      }
      if (address.toLowerCase().endsWith(city.toLowerCase())) {
        return '$address, $state';
      }
    }

    return '$address, $fallback';
  }

  Future<List<double>> _geocodeRestaurant({
    required String name,
    required String address,
    String? fallbackLocation,
  }) async {
    final queries = <String>[];
    final cleanName = _collapseWhitespace(name);
    final cleanAddress = _collapseWhitespace(address);
    final cleanFallback = _collapseWhitespace(fallbackLocation ?? '');

    if (cleanAddress.isNotEmpty) {
      queries.add(cleanAddress);
      queries.add('$cleanAddress, USA');
      if (cleanName.isNotEmpty) {
        queries.add('$cleanName, $cleanAddress');
        queries.add('$cleanName, $cleanAddress, USA');
      }
    }

    if (cleanName.isNotEmpty && cleanFallback.isNotEmpty) {
      queries.add('$cleanName, $cleanFallback');
      queries.add('$cleanName, $cleanFallback, USA');
    }

    if (cleanFallback.isNotEmpty) {
      queries.add('$cleanFallback, USA');
    }

    for (final query in queries.toSet()) {
      final coords = await _geocodeAddress(query);
      if (coords[0] != 0.0 || coords[1] != 0.0) {
        return coords;
      }
    }

    return const [0.0, 0.0];
  }

  String? _extractWebsite(dom.Document doc) {
    for (final anchor in doc.querySelectorAll('a[href]')) {
      final text = anchor.text.trim().toLowerCase();
      final href = anchor.attributes['href']?.trim() ?? '';
      if (text == 'website' && href.isNotEmpty) {
        return _normalizeUrl(href, base: 'https://www.restaurantji.com');
      }
    }
    return null;
  }

  String _extractImage(dom.Document doc) {
    final ogImage = doc
        .querySelector('meta[property="og:image"]')
        ?.attributes['content']
        ?.trim();
    if (ogImage != null && ogImage.isNotEmpty) return ogImage;

    for (final image in doc.querySelectorAll('img[src]')) {
      final src = image.attributes['src']?.trim() ?? '';
      if (src.isEmpty || src.contains('logo')) continue;
      return _normalizeUrl(src, base: 'https://www.restaurantji.com');
    }
    return _placeholderImage;
  }

  Future<_CityInfo?> _resolveLocation(String rawLocation) async {
    final key = rawLocation.trim().toLowerCase();
    if (_cityCache.containsKey(key)) return _cityCache[key];

    final geocoded = await _searchPlace(rawLocation);
    if (geocoded != null) {
      _cityCache[key] = geocoded;
      return geocoded;
    }

    final parsed = _parseCityState(rawLocation);
    if (parsed != null) {
      _cityCache[key] = parsed;
      return parsed;
    }

    return null;
  }

  Future<_CityInfo?> _reverseResolveLocation(double lat, double lng) async {
    final key = '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
    if (_cityCache.containsKey(key)) return _cityCache[key];

    try {
      final uri = NominatimClient.buildUri('/reverse', {
        'lat': '$lat',
        'lon': '$lng',
        'format': 'jsonv2',
        'zoom': '12',
        'addressdetails': '1',
      });

      final response = await _queuedNominatimGet(uri);
      if (response.statusCode != 200) {
        print('Reverse geocode status ${response.statusCode}: $lat,$lng');
        return null;
      }

      final Map<String, dynamic> data = jsonDecode(response.body);
      final address = data['address'];
      if (address is! Map<String, dynamic>) return null;

      final city = (address['city'] ??
              address['town'] ??
              address['village'] ??
              address['municipality'] ??
              '')
          .toString();
      final state = (address['state_code'] ?? address['state'] ?? '').toString();

      if (city.isEmpty || state.isEmpty) return null;

      final info = _cityInfoFromParts(city, state);
      if (info != null) _cityCache[key] = info;
      return info;
    } catch (e) {
      print('Reverse geocode error: $e');
      return null;
    }
  }

  Future<_CityInfo?> _searchPlace(String query) async {
    try {
      final uri = NominatimClient.buildUri('/search', {
        'q': query,
        'format': 'jsonv2',
        'limit': '1',
        'addressdetails': '1',
        'countrycodes': 'us',
      });

      final response = await _queuedNominatimGet(uri);
      if (response.statusCode != 200) {
        print('Place search status ${response.statusCode}: $query');
        return null;
      }

      final List<dynamic> data = jsonDecode(response.body);
      if (data.isEmpty) return null;

      final address = data.first['address'];
      if (address is! Map<String, dynamic>) return null;

      final city = (address['city'] ??
              address['town'] ??
              address['village'] ??
              address['municipality'] ??
              '')
          .toString();
      final state = (address['state_code'] ?? address['state'] ?? '').toString();

      if (city.isEmpty || state.isEmpty) return null;

      return _cityInfoFromParts(city, state);
    } catch (e) {
      print('Place search error: $e');
      return null;
    }
  }

  _CityInfo? _parseCityState(String raw) {
    final cleaned = raw.trim();
    if (cleaned.isEmpty) return null;

    final parts = cleaned
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.length < 2) return null;
    return _cityInfoFromParts(parts.first, parts[1]);
  }

  _CityInfo? _cityInfoFromParts(String city, String state) {
    String? stateAbbrev;
    if (state.trim().length == 2) {
      stateAbbrev = state.trim().toUpperCase();
    } else {
      stateAbbrev = _stateNameToAbbrev[state.trim().toLowerCase()];
    }
    if (stateAbbrev == null) return null;

    return _CityInfo(
      cityDisplay: city.trim(),
      stateAbbrev: stateAbbrev,
      citySlug: _slugify(city),
      stateSlug: stateAbbrev.toLowerCase(),
    );
  }

  Future<List<double>> _geocodeAddress(String address) async {
    if (_geocodeCache.containsKey(address)) return _geocodeCache[address]!;

    try {
      final uri = NominatimClient.buildUri('/search', {
        'q': address,
        'format': 'jsonv2',
        'limit': '1',
        'countrycodes': 'us',
        'addressdetails': '1',
      });

      final response = await _queuedNominatimGet(uri);

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        if (data.isNotEmpty) {
          final lat =
              double.tryParse(data.first['lat']?.toString() ?? '') ?? 0.0;
          final lon =
              double.tryParse(data.first['lon']?.toString() ?? '') ?? 0.0;
          final coords = [lat, lon];
          _geocodeCache[address] = coords;
          return coords;
        }
      } else {
        print('Address geocode status ${response.statusCode}: $address');
      }
    } catch (e) {
      print('Address geocode error: $e ($address)');
    }

    const coords = [0.0, 0.0];
    _geocodeCache[address] = coords;
    return coords;
  }

  Future<http.Response> _queuedNominatimGet(Uri uri) async {
    return NominatimClient.get(uri);
  }

  Map<String, String> _browserHeaders() {
    return {
      'User-Agent': _appUserAgent,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'en-US,en;q=0.9',
      'Cache-Control': 'no-cache',
      'Pragma': 'no-cache',
    };
  }

  String _normalizeUrl(String url, {required String base}) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    if (url.startsWith('//')) return 'https:$url';
    if (url.startsWith('/')) return '$base$url';
    return url;
  }

  String _makeId(String url, String name) {
    final parsed = Uri.tryParse(url);
    if (parsed != null && parsed.pathSegments.isNotEmpty) {
      return parsed.pathSegments.lastWhere(
        (segment) => segment.isNotEmpty,
        orElse: () => name,
      );
    }
    return name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  }

  String _slugify(String input) {
    return input
        .trim()
        .toLowerCase()
        .replaceAll('&', ' and ')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  String _collapseWhitespace(String input) {
    return input.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Restaurant _cloneRestaurant(Restaurant restaurant) {
    return Restaurant(
      id: restaurant.id,
      name: restaurant.name,
      rating: restaurant.rating,
      location: restaurant.location,
      imageUrl: restaurant.imageUrl,
      latitude: restaurant.latitude,
      longitude: restaurant.longitude,
      url: restaurant.url,
      dateAdded: restaurant.dateAdded,
    );
  }

  dom.Document parseHtml(String source) => html_parser.parse(source);
}

class YelpFusionAPI implements RestaurantScraper {
  static const String _baseUrl = 'https://api.yelp.com/v3/businesses/search';

  String get _apiKey {
    final key = AppConfig.yelpApiKey;
    if (key.isEmpty) {
      throw StateError(
        'YELP_API_KEY is not configured. Pass it with --dart-define.',
      );
    }
    return key;
  }

  Map<String, String> _apiHeaders() {
    return {
      'Authorization': 'Bearer $_apiKey',
      'Accept': 'application/json',
    };
  }

  @override
  Future<List<Restaurant>> getRestaurants({
    required String location,
    String term = 'restaurants',
  }) async {
    final uri = Uri.parse('$_baseUrl?term=${Uri.encodeComponent(term)}&location=${Uri.encodeComponent(location)}&limit=20');

    try {
      final response = await http.get(uri, headers: _apiHeaders());

      if (response.statusCode != 200) {
        print('Yelp API error: HTTP ${response.statusCode}');
        return [];
      }

      final data = jsonDecode(response.body);
      return _parseYelpResponse(data['businesses'] as List);
    } catch (e) {
      print('Yelp Fusion API Error: $e');
      return [];
    }
  }

  @override
  Future<List<Restaurant>> getRestaurantsByLocation({
    required double latitude,
    required double longitude,
    String term = 'restaurants',
  }) async {
    final uri = Uri.parse('$_baseUrl?term=${Uri.encodeComponent(term)}&latitude=$latitude&longitude=$longitude&limit=20');

    try {
      final response = await http.get(uri, headers: _apiHeaders());

      if (response.statusCode != 200) {
        print('Yelp API error: HTTP ${response.statusCode}');
        return [];
      }

      final data = jsonDecode(response.body);
      return _parseYelpResponse(data['businesses'] as List);
    } catch (e) {
      print('Yelp Fusion API Error: $e');
      return [];
    }
  }

  List<Restaurant> _parseYelpResponse(List dynamicBusinesses) {
    final results = <Restaurant>[];

    for (final b in dynamicBusinesses) {
      try {
        final locationMap = b['location'] ?? {};
        final displayAddress = (locationMap['display_address'] as List?)?.join(', ') ?? 'Unknown Location';

        final coordinates = b['coordinates'] ?? {};
        final lat = (coordinates['latitude'] ?? 0.0).toDouble();
        final lon = (coordinates['longitude'] ?? 0.0).toDouble();

        // handle missing images
        String imageUrl = b['image_url'] ?? '';
        if (imageUrl.isEmpty) {
          imageUrl = 'https://via.placeholder.com/400';
        }

        results.add(Restaurant(
          id: b['id'] ?? b['alias'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
          name: b['name'] ?? 'Unknown Restaurant',
          rating: '⭐ ${b['rating'] ?? '0.0'}',
          location: displayAddress,
          imageUrl: imageUrl,
          latitude: lat,
          longitude: lon,
          url: b['url'] ?? '',
          dateAdded: DateTime.now().toIso8601String(),
        ));
      } catch (e) {
        print('Error parsing individual Yelp restaurant: $e');
        continue;
      }
    }

    return results;
  }
}


class TripAdvisorScraper implements RestaurantScraper {
  static const String _placeholderImage = 'https://via.placeholder.com/400';
  static const int _resultLimit = 20;
  static const int _detailInspectionLimit = 30;
  static const int _minPreferredResults = 8;
  static const String _appUserAgent = AppConfig.applicationUserAgent;

  final Map<String, List<double>> _geocodeCache = {};
  final Map<String, _CityInfo> _cityCache = {};
  final Map<String, _ScrapedRestaurant?> _detailCache = {};
  final Map<String, List<Restaurant>> _searchCache = {};

  @override
  Future<List<Restaurant>> getRestaurants({
    required String location,
    String term = 'restaurants',
  }) async {
    final cityInfo = await _resolveLocation(location);
    if (cityInfo == null) {
      print('Could not resolve location: $location');
      return [];
    }
    return _scrapeTripAdvisorCity(cityInfo, term);
  }

  @override
  Future<List<Restaurant>> getRestaurantsByLocation({
    required double latitude,
    required double longitude,
    String term = 'restaurants',
  }) async {
    final cityInfo = await _reverseResolveLocation(latitude, longitude);
    if (cityInfo == null) {
      print('Could not reverse resolve location: $latitude,$longitude');
      return [];
    }
    return _scrapeTripAdvisorCity(cityInfo, term);
  }

  Future<List<Restaurant>> _scrapeTripAdvisorCity(
    _CityInfo cityInfo,
    String term,
  ) async {
    final normalizedTerm = term.trim().toLowerCase();
    final searchQuery = '${normalizedTerm == 'restaurants' ? '' : '$normalizedTerm '}restaurants in ${cityInfo.cityDisplay}, ${cityInfo.stateAbbrev}';
    final cacheKey = 'TA|$searchQuery';

    final cached = _searchCache[cacheKey];
    if (cached != null) {
      return cached.map(_cloneRestaurant).toList();
    }

    final typeaheadUri = Uri.https('www.tripadvisor.com', '/TypeAheadJson', {
      'action': 'API',
      'types': 'geo',
      'query': '${cityInfo.cityDisplay} ${cityInfo.stateAbbrev}'
    });

    try {
      final taResponse = await http.get(typeaheadUri, headers: _browserHeaders());
      if (taResponse.statusCode != 200) {
        print('TripAdvisor typeahead error: ${taResponse.statusCode}');
        return [];
      }

      final taJson = jsonDecode(taResponse.body);
      final results = taJson['results'] as List?;

      if (results == null || results.isEmpty) {
        print('TripAdvisor found no geo match for ${cityInfo.cityDisplay}');
        return [];
      }

      final geoUrl = results[0]['url'] as String;

      final match = RegExp(r'-g(\d+-[^-.]+)').firstMatch(geoUrl);

      if (match == null) {
        print('Could not parse geo ID from $geoUrl');
        return [];
      }

      final geoString = match.group(1);

      final searchUri = Uri.https('www.tripadvisor.com', '/Restaurants-g$geoString.html');

      final response = await http.get(searchUri, headers: _browserHeaders());
      if (response.statusCode != 200) {
        print(
          'TripAdvisor direct page error: ${response.statusCode} ${searchUri.toString()}',
        );
        return [];
      }

      final doc = html_parser.parse(response.body);
      final candidates = _extractCityCandidates(doc, cityInfo);

      if (candidates.isEmpty) {
        print(
          'TripAdvisor search page parsed but no restaurant cards were found: ${searchUri.toString()}',
        );
        return [];
      }

      final quickMatches = candidates
          .where((candidate) => _matchesTerm(candidate.searchText, normalizedTerm))
          .toList();

      final matchingCandidates = <_CityCandidate>[];
      matchingCandidates.addAll(quickMatches.take(_resultLimit));

      if (normalizedTerm.isNotEmpty &&
          normalizedTerm != 'restaurants' &&
          matchingCandidates.length < _minPreferredResults) {
        final moreMatches = await _fallbackMatchByDetail(
          candidates,
          normalizedTerm,
          exclude: matchingCandidates.map((candidate) => candidate.detailUrl).toSet(),
          limit: _resultLimit - matchingCandidates.length,
        );
        for (final candidate in moreMatches) {
          if (matchingCandidates.any(
            (existing) => existing.detailUrl == candidate.detailUrl,
          )) {
            continue;
          }
          matchingCandidates.add(candidate);
          if (matchingCandidates.length >= _resultLimit) break;
        }
      }

      if (matchingCandidates.isEmpty) {
        _searchCache[cacheKey] = const [];
        print(
          'TripAdvisor parsed 0 restaurants for ${cityInfo.cityDisplay}, ${cityInfo.stateAbbrev} / $term',
        );
        return [];
      }

      final resultsList = await _hydrateCandidates(
        matchingCandidates.take(_resultLimit).toList(),
        cityInfo,
      );

      _searchCache[cacheKey] = resultsList.map(_cloneRestaurant).toList();
      final mappedCount =
          resultsList.where((r) => r.latitude != 0 && r.longitude != 0).length;

      print('TripAdvisor parsed ${resultsList.length} restaurants for ${cityInfo.cityDisplay}, ${cityInfo.stateAbbrev} / $term');
      print('TripAdvisor mapped $mappedCount / ${resultsList.length} restaurants for ${cityInfo.cityDisplay}, ${cityInfo.stateAbbrev} / $term');

      return resultsList;
    } catch (e) {
      print('TripAdvisor scrape error: $e');
      return [];
    }
  }

  List<_CityCandidate> _extractCityCandidates(dom.Document doc, _CityInfo cityInfo) {
    final seen = <String>{};
    final candidates = <_CityCandidate>[];

    for (final anchor in doc.querySelectorAll('a[href]')) {
      final href = anchor.attributes['href']?.trim() ?? '';
      if (!_isRestaurantDetailHref(href)) continue;

      String name = _collapseWhitespace(anchor.text);
      name = name.replaceFirst(RegExp(r'^\d+\.\s*'), '').trim();

      if (name.isEmpty) continue;

      final detailUrl = _normalizeUrl(href, base: 'https://www.tripadvisor.com');

      // Strip out hash fragments to avoid duplicates
      final cleanUrl = detailUrl.split('#')[0];
      if (!seen.add(cleanUrl)) continue;

      final cardText = _extractCardText(anchor);
      final ratingValue = _extractCardRating(cardText, anchor);
      final searchText =
          '$name $cardText ${cityInfo.cityDisplay} ${cityInfo.stateAbbrev}'
              .toLowerCase();

      candidates.add(
        _CityCandidate(
          name: name,
          detailUrl: cleanUrl,
          rating: ratingValue,
          searchText: searchText,
        ),
      );
    }

    return candidates;
  }

  bool _isRestaurantDetailHref(String href) {
    return href.contains('/Restaurant_Review-g') && href.endsWith('.html');
  }

  String _extractCardText(dom.Element anchor) {
    dom.Element? current = anchor.parent;
    String best = _collapseWhitespace(anchor.parent?.text ?? anchor.text);

    for (int depth = 0; current != null && depth < 5; depth++) {
      final text = _collapseWhitespace(current.text);
      if (text.isEmpty) {
        current = current.parent;
        continue;
      }
      if (text.length >= 40 && text.length <= 1500) {
        best = text;
      }

      current = current.parent;
    }

    return best;
  }

  String _extractCardRating(String cardText, dom.Element anchor) {
    dom.Element? parent = anchor.parent;
    for (int i = 0; i < 4; i++) {
      if (parent == null) break;
      final svg = parent.querySelector('svg[aria-label*="bubbles"]');
      if (svg != null) {
        final aria = svg.attributes['aria-label'] ?? '';
        final match = RegExp(r'(\d\.\d|\d)\s+of').firstMatch(aria);
        if (match != null) return match.group(1)!;
      }
      parent = parent.parent;
    }

    // Fallback regex
    final simple = RegExp(r'\b(\d\.\d|\d)\s+of\s+5\b').firstMatch(cardText) ??
                   RegExp(r'\b(\d\.\d)\b').firstMatch(cardText);
    return simple?.group(1) ?? '0.0';
  }

  Future<List<_CityCandidate>> _fallbackMatchByDetail(
    List<_CityCandidate> candidates,
    String normalizedTerm, {
    Set<String>? exclude,
    int? limit,
  }) async {
    final matches = <_CityCandidate>[];
    final excluded = exclude ?? <String>{};
    final maxResults = limit ?? _resultLimit;

    final unmatched = candidates
        .where((candidate) => !excluded.contains(candidate.detailUrl))
        .toList();

    for (final candidate in unmatched.take(_detailInspectionLimit)) {
      final detail = await _scrapeRestaurantDetail(
        candidate.detailUrl,
        geocodeAddress: false,
        fallbackName: candidate.name,
        fallbackRating: candidate.rating,
      );

      if (detail != null && _matchesTerm(detail.searchText, normalizedTerm)) {
        matches.add(candidate);
      }

      if (matches.length >= maxResults) break;
    }

    return matches;
  }

  Future<List<Restaurant>> _hydrateCandidates(
    List<_CityCandidate> candidates,
    _CityInfo cityInfo,
  ) async {
    final hydrated = <Restaurant>[];
    final cityFallback = '${cityInfo.cityDisplay}, ${cityInfo.stateAbbrev}';

    for (final candidate in candidates) {
      final detail = await _scrapeRestaurantDetail(
        candidate.detailUrl,
        geocodeAddress: true,
        fallbackName: candidate.name,
        fallbackRating: candidate.rating,
        fallbackLocation: cityFallback,
      );

      if (detail != null) {
        hydrated.add(detail.restaurant);
      } else {
        hydrated.add(
          Restaurant(
            id: _makeId(candidate.detailUrl, candidate.name),
            name: candidate.name,
            rating: '⭐ ${candidate.rating}',
            location: cityFallback,
            imageUrl: _placeholderImage,
            latitude: 0.0,
            longitude: 0.0,
            url: candidate.detailUrl,
            dateAdded: 'Not added yet',
          ),
        );
      }
    }

    return hydrated;
  }

  Future<_ScrapedRestaurant?> _scrapeRestaurantDetail(
    String detailUrl, {
    required bool geocodeAddress,
    String? fallbackName,
    String? fallbackRating,
    String? fallbackLocation,
  }) async {
    if (_detailCache.containsKey(detailUrl)) {
      final cached = _detailCache[detailUrl];
      if (cached == null) return null;
      final hasCoords =
          cached.restaurant.latitude != 0 || cached.restaurant.longitude != 0;
      if (!geocodeAddress ||
          hasCoords ||
          cached.restaurant.location == fallbackLocation) {
        return cached;
      }
    }

    try {
      final response =
          await http.get(Uri.parse(detailUrl), headers: _browserHeaders());
      if (response.statusCode != 200) {
        print('TripAdvisor detail error: ${response.statusCode} $detailUrl');
        _detailCache[detailUrl] = null;
        return null;
      }

      final doc = html_parser.parse(response.body);
      final bodyText = _collapseWhitespace(doc.body?.text ?? '');

      final h1 = doc.querySelector('h1[data-test-target="top-info-header"]')?.text ??
                 doc.querySelector('h1')?.text;
      final name = h1?.trim() ?? fallbackName ?? '';
      if (name.isEmpty) {
        _detailCache[detailUrl] = null;
        return null;
      }

      final ratingValue = RegExp(
            r'(\d\.\d|\d)\s+of\s+5\s+bubbles',
            caseSensitive: false,
          ).firstMatch(bodyText)?.group(1) ??
          fallbackRating ??
          '0.0';

      final rawAddress = _extractAddress(doc, bodyText);
      final address = _normalizeAddress(rawAddress, fallbackLocation);
            //  look for common patterns in their UI.
      final websiteUrl = _extractWebsite(doc) ?? detailUrl;
      final imageUrl = _extractImage(doc);

      List<double> coords = _extractCoordinates(doc, bodyText);
      if (coords[0] == 0.0 && coords[1] == 0.0 && geocodeAddress) {
        coords = await _geocodeRestaurant(
          name: name,
          address: address,
          fallbackLocation: fallbackLocation,
        );
      }

      final restaurant = Restaurant(
        id: _makeId(detailUrl, name),
        name: name,
        rating: '⭐ $ratingValue',
        location:
            address.isNotEmpty ? address : (fallbackLocation ?? 'Unknown Location'),
        imageUrl: imageUrl,
        latitude: coords[0],
        longitude: coords[1],
        url: websiteUrl,
        dateAdded: 'Not added yet',
      );

      final scraped = _ScrapedRestaurant(
        restaurant: restaurant,
        searchText:
            '${restaurant.name} ${restaurant.location} $bodyText'
                .toLowerCase(),
      );
      _detailCache[detailUrl] = scraped;
      return scraped;
    } catch (e) {
      print('TripAdvisor detail parse error: $e ($detailUrl)');
      _detailCache[detailUrl] = null;
      return null;
    }
  }

  String _extractAddress(dom.Document doc, String text) {
    final addressAnchor = doc.querySelector('a[href*="#MAPVIEW"]');
    if (addressAnchor != null && addressAnchor.text.trim().isNotEmpty) {
      return _collapseWhitespace(addressAnchor.text);
    }

    final pageText = _collapseWhitespace(text);
    final sectionMatch = RegExp(
      r'Location and contact\s+(.+?)(?:Website|Email|Call|\(\d{3}\))',
      caseSensitive: false,
    ).firstMatch(pageText);

    if (sectionMatch != null) {
      final inSection = _extractAddressLike(sectionMatch.group(1) ?? '');
      if (inSection.isNotEmpty) return inSection;
    }

    return '';
  }

  String _extractAddressLike(String input) {
    final value = _collapseWhitespace(input);
    if (value.isEmpty) return '';

    final patterns = <RegExp>[
      RegExp(r'''\b\d{1,6}\s+[A-Za-z0-9.#&\- ]+?,\s*[A-Za-z .\-']+?,\s*[A-Z]{2}\s*\d{5}(?:-\d{4})?\b'''),
      RegExp(r'''\b\d{1,6}\s+[A-Za-z0-9.#&\- ]+?,\s*[A-Za-z .\-']+\s*\d{5}(?:-\d{4})?\b'''),
      RegExp(r'''\b\d{1,6}\s+[A-Za-z0-9.#&\- ]+?,\s*[A-Za-z .\-']+\b'''),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(value);
      if (match != null) {
        return _collapseWhitespace(match.group(0) ?? '');
      }
    }
    return '';
  }

  String? _extractWebsite(dom.Document doc) {
    for (final anchor in doc.querySelectorAll('a[href]')) {
      final text = anchor.text.trim().toLowerCase();
      final href = anchor.attributes['href']?.trim() ?? '';

      if ((text == 'website' || text == 'menu') && href.isNotEmpty) {
        if (href.contains('/ExternalLinkInterstitial')) {
          final uri = Uri.tryParse(href);
          if (uri != null && uri.queryParameters.containsKey('url')) {
            return uri.queryParameters['url'];
          }
        }
        return _normalizeUrl(href, base: 'https://www.tripadvisor.com');
      }
    }
    return null;
  }

  String _extractImage(dom.Document doc) {
    final ogImage = doc
        .querySelector('meta[property="og:image"]')
        ?.attributes['content']
        ?.trim();
    if (ogImage != null && ogImage.isNotEmpty) return ogImage;

    // Look for hero images in the picture elements
    final heroImg = doc.querySelector('picture img[src]');
    if (heroImg != null) {
      final src = heroImg.attributes['src']?.trim() ?? '';
      if (src.isNotEmpty) return src;
    }

    return _placeholderImage;
  }

  List<double> _extractCoordinates(dom.Document doc, String bodyText) {
    double? lat;
    double? lon;

    for (final script in doc.querySelectorAll('script[type="application/ld+json"]')) {
      final coords = _extractCoordinatesFromJsonLike(script.text);
      if (coords[0] != 0.0 || coords[1] != 0.0) return coords;
    }

    final scriptText = doc.querySelectorAll('script').map((script) => script.text).join(' ');
    final coordsFromScripts = _extractCoordinatesFromText(scriptText);
    if (coordsFromScripts[0] != 0.0 || coordsFromScripts[1] != 0.0) {
      return coordsFromScripts;
    }

    final coordsFromBody = _extractCoordinatesFromText(bodyText);
    if (coordsFromBody[0] != 0.0 || coordsFromBody[1] != 0.0) {
      return coordsFromBody;
    }

    return const [0.0, 0.0];
  }

  List<double> _extractCoordinatesFromJsonLike(String input) {
    try {
      final dynamic decoded = jsonDecode(input);
      final coords = _walkForCoordinates(decoded);
      if (coords[0] != 0.0 || coords[1] != 0.0) return coords;
    } catch (_) {}
    return _extractCoordinatesFromText(input);
  }

  List<double> _walkForCoordinates(dynamic value) {
    if (value is Map) {
      final lat = _toDouble(value['latitude'] ?? value['lat']);
      final lon = _toDouble(value['longitude'] ?? value['lng'] ?? value['lon']);
      if (lat != null && lon != null && _looksLikeCoordinatePair(lat, lon)) {
        return [lat, lon];
      }
      for (final child in value.values) {
        final coords = _walkForCoordinates(child);
        if (coords[0] != 0.0 || coords[1] != 0.0) return coords;
      }
    } else if (value is List) {
      for (final child in value) {
        final coords = _walkForCoordinates(child);
        if (coords[0] != 0.0 || coords[1] != 0.0) return coords;
      }
    }
    return const [0.0, 0.0];
  }

  List<double> _extractCoordinatesFromText(String text) {
    if (text.isEmpty) return const [0.0, 0.0];
    final patterns = <RegExp>[
      RegExp(r'lat[^\d-:=]*[:=]\s*(-?\d{1,2}\.\d+)[^\d-]+(?:lng|lon|longitude)[^\d-:=]*[:=]\s*(-?\d{1,3}\.\d+)', caseSensitive: false),
      RegExp(r'@(-?\d{1,2}\.\d+),(-?\d{1,3}\.\d+)', caseSensitive: false),
    ];
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(text)) {
        final a = double.tryParse(match.group(1) ?? '');
        final b = double.tryParse(match.group(2) ?? '');
        if (a != null && b != null && _looksLikeCoordinatePair(a, b)) {
          return [a, b];
        }
      }
    }
    return const [0.0, 0.0];
  }

  bool _looksLikeCoordinatePair(double lat, double lon) {
    return lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180;
  }

  double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  bool _matchesTerm(String haystack, String normalizedTerm) {
    if (normalizedTerm.isEmpty || normalizedTerm == 'restaurants') return true;
    final normalizedHaystack = haystack.toLowerCase();
    if (normalizedHaystack.contains(normalizedTerm)) return true;
    final tokens = normalizedTerm.split(RegExp(r'[^a-z0-9]+')).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return true;
    final tokenMatches = tokens.where((token) => normalizedHaystack.contains(token)).length;
    return tokens.length == 1 ? tokenMatches > 0 : tokenMatches >= tokens.length;
  }

  String _normalizeAddress(String rawAddress, String? fallbackLocation) {
    final address = _collapseWhitespace(rawAddress);
    if (address.isEmpty) return fallbackLocation ?? '';
    if (RegExp(r',\s*[A-Z]{2}\s*\d{5}').hasMatch(address)) return address;
    if (fallbackLocation == null || fallbackLocation.trim().isEmpty) return address;
    return '$address, $fallbackLocation';
  }

  Future<List<double>> _geocodeRestaurant({
    required String name,
    required String address,
    String? fallbackLocation,
  }) async {
    final cleanAddress = _collapseWhitespace(address);
    if (cleanAddress.isNotEmpty) {
      final coords = await _geocodeAddress(cleanAddress);
      if (coords[0] != 0.0 || coords[1] != 0.0) return coords;
    }
    return const [0.0, 0.0];
  }

  Future<_CityInfo?> _resolveLocation(String rawLocation) async {
    final key = rawLocation.trim().toLowerCase();
    if (_cityCache.containsKey(key)) return _cityCache[key];

    final uri = NominatimClient.buildUri('/search', {
      'q': rawLocation,
      'format': 'jsonv2',
      'limit': '1',
      'addressdetails': '1',
      'countrycodes': 'us',
    });

    final response = await _queuedNominatimGet(uri);
    if (response.statusCode != 200) return null;

    final List<dynamic> data = jsonDecode(response.body);
    if (data.isEmpty) return null;

    final address = data.first['address'];
    final city = (address['city'] ?? address['town'] ?? address['village'] ?? '').toString();
    final state = (address['state_code'] ?? address['state'] ?? '').toString();

    if (city.isEmpty || state.isEmpty) return null;

    final info = _CityInfo(
      cityDisplay: city.trim(),
      stateAbbrev: state.length == 2 ? state.toUpperCase() : state,
      citySlug: _slugify(city),
      stateSlug: state.toLowerCase(),
    );
    _cityCache[key] = info;
    return info;
  }

  Future<_CityInfo?> _reverseResolveLocation(double lat, double lng) async {
    final uri = NominatimClient.buildUri('/reverse', {
      'lat': '$lat',
      'lon': '$lng',
      'format': 'jsonv2',
      'zoom': '12',
      'addressdetails': '1',
    });

    final response = await _queuedNominatimGet(uri);
    if (response.statusCode != 200) return null;

    final Map<String, dynamic> data = jsonDecode(response.body);
    final address = data['address'];
    final city = (address['city'] ?? address['town'] ?? address['village'] ?? '').toString();
    final state = (address['state_code'] ?? address['state'] ?? '').toString();

    if (city.isEmpty || state.isEmpty) return null;

    return _CityInfo(
      cityDisplay: city.trim(),
      stateAbbrev: state.length == 2 ? state.toUpperCase() : state,
      citySlug: _slugify(city),
      stateSlug: state.toLowerCase(),
    );
  }

  Future<List<double>> _geocodeAddress(String address) async {
    if (_geocodeCache.containsKey(address)) return _geocodeCache[address]!;
    final uri = NominatimClient.buildUri('/search', {
      'q': address,
      'format': 'jsonv2',
      'limit': '1',
      'countrycodes': 'us',
    });
    final response = await _queuedNominatimGet(uri);
    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      if (data.isNotEmpty) {
        final lat = double.tryParse(data.first['lat']?.toString() ?? '') ?? 0.0;
        final lon = double.tryParse(data.first['lon']?.toString() ?? '') ?? 0.0;
        final coords = [lat, lon];
        _geocodeCache[address] = coords;
        return coords;
      }
    }
    const coords = [0.0, 0.0];
    _geocodeCache[address] = coords;
    return coords;
  }

  Future<http.Response> _queuedNominatimGet(Uri uri) async {
    return NominatimClient.get(uri);
  }

  Map<String, String> _browserHeaders() {
    return {
      'User-Agent': _appUserAgent,
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
      'Accept-Language': 'en-US,en;q=0.9',
      'Cache-Control': 'max-age=0',
      'Sec-Fetch-Dest': 'document',
      'Sec-Fetch-Mode': 'navigate',
      'Sec-Fetch-Site': 'none',
      'Sec-Fetch-User': '?1',
      'Upgrade-Insecure-Requests': '1',
    };
  }

  String _normalizeUrl(String url, {required String base}) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    if (url.startsWith('//')) return 'https:$url';
    if (url.startsWith('/')) return '$base$url';
    return url;
  }

  String _makeId(String url, String name) {
    final parsed = Uri.tryParse(url);
    if (parsed != null && parsed.pathSegments.isNotEmpty) {
      final taId = RegExp(r'g\d+-d\d+').firstMatch(url);
      if (taId != null) return taId.group(0)!;
    }
    return name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  }

  String _slugify(String input) {
    return input.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');
  }

  String _collapseWhitespace(String input) {
    return input.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Restaurant _cloneRestaurant(Restaurant restaurant) {
    return Restaurant(
      id: restaurant.id,
      name: restaurant.name,
      rating: restaurant.rating,
      location: restaurant.location,
      imageUrl: restaurant.imageUrl,
      latitude: restaurant.latitude,
      longitude: restaurant.longitude,
      url: restaurant.url,
      dateAdded: restaurant.dateAdded,
    );
  }
}

class _CityCandidate {
  final String name;
  final String detailUrl;
  final String rating;
  final String searchText;

  const _CityCandidate({
    required this.name,
    required this.detailUrl,
    required this.rating,
    required this.searchText,
  });
}

class _ScrapedRestaurant {
  final Restaurant restaurant;
  final String searchText;

  const _ScrapedRestaurant({
    required this.restaurant,
    required this.searchText,
  });
}

class _CityInfo {
  final String cityDisplay;
  final String stateAbbrev;
  final String citySlug;
  final String stateSlug;

  const _CityInfo({
    required this.cityDisplay,
    required this.stateAbbrev,
    required this.citySlug,
    required this.stateSlug,
  });

  String get restaurantJiUrl => 'https://www.restaurantji.com/$stateSlug/$citySlug/';
}

const Set<String> _ignoredSearchTerms = {
  'restaurant',
  'restaurants',
  'food',
  'place',
  'places',
  'near',
  'me',
};

const Map<String, List<String>> _termSynonyms = {
  'sushi': ['japanese', 'roll', 'rolls', 'sashimi'],
  'japanese': ['sushi', 'ramen', 'hibachi'],
  'ramen': ['japanese', 'noodle'],
  'pizza': ['pizzeria', 'italian'],
  'burger': ['burgers', 'american'],
  'burgers': ['burger', 'american'],
  'bbq': ['barbecue', 'smokehouse'],
  'barbecue': ['bbq', 'smokehouse'],
  'mexican': ['taco', 'taqueria', 'burrito'],
  'taco': ['mexican', 'taqueria'],
  'thai': ['noodle', 'curry'],
  'indian': ['curry', 'biryani'],
  'chinese': ['dim sum', 'noodle'],
  'korean': ['bbq', 'kimchi'],
  'vegan': ['vegetarian', 'plant'],
  'vegetarian': ['vegan', 'plant'],
  'coffee': ['cafe', 'espresso'],
  'cafe': ['coffee', 'bakery'],
  'bakery': ['cafe', 'dessert'],
  'dessert': ['bakery', 'ice cream'],
  'seafood': ['fish', 'crab', 'oyster'],
};

const Map<String, String> _stateNameToAbbrev = {
  'alabama': 'AL',
  'alaska': 'AK',
  'arizona': 'AZ',
  'arkansas': 'AR',
  'california': 'CA',
  'colorado': 'CO',
  'connecticut': 'CT',
  'delaware': 'DE',
  'district of columbia': 'DC',
  'florida': 'FL',
  'georgia': 'GA',
  'hawaii': 'HI',
  'idaho': 'ID',
  'illinois': 'IL',
  'indiana': 'IN',
  'iowa': 'IA',
  'kansas': 'KS',
  'kentucky': 'KY',
  'louisiana': 'LA',
  'maine': 'ME',
  'maryland': 'MD',
  'massachusetts': 'MA',
  'michigan': 'MI',
  'minnesota': 'MN',
  'mississippi': 'MS',
  'missouri': 'MO',
  'montana': 'MT',
  'nebraska': 'NE',
  'nevada': 'NV',
  'new hampshire': 'NH',
  'new jersey': 'NJ',
  'new mexico': 'NM',
  'new york': 'NY',
  'north carolina': 'NC',
  'north dakota': 'ND',
  'ohio': 'OH',
  'oklahoma': 'OK',
  'oregon': 'OR',
  'pennsylvania': 'PA',
  'rhode island': 'RI',
  'south carolina': 'SC',
  'south dakota': 'SD',
  'tennessee': 'TN',
  'texas': 'TX',
  'utah': 'UT',
  'vermont': 'VT',
  'virginia': 'VA',
  'washington': 'WA',
  'west virginia': 'WV',
  'wisconsin': 'WI',
  'wyoming': 'WY',
};
