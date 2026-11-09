class AppConfig {
  static const String applicationUserAgent = 'LocalHubFoodFinder/1.0';

  static const String yelpApiKey = String.fromEnvironment('YELP_API_KEY');

  static const String nominatimBaseUrl = String.fromEnvironment(
    'NOMINATIM_BASE_URL',
    defaultValue: 'https://nominatim.openstreetmap.org',
  );

  static const String nominatimContactEmail = String.fromEnvironment(
    'NOMINATIM_CONTACT_EMAIL',
  );

  static String get nominatimUserAgent {
    final contact = nominatimContactEmail.trim();
    if (contact.isEmpty) return applicationUserAgent;
    return '$applicationUserAgent (contact: $contact)';
  }
}
