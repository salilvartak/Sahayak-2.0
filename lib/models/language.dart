enum Language {
  hindi('Hindi', 'हिंदी', 'hi'),
  marathi('Marathi', 'मराठी', 'mr'),
  telugu('Telugu', 'తెలుగు', 'te'),
  english('English', 'English', 'en'),
  tamil('Tamil', 'தமிழ்', 'ta'),
  kannada('Kannada', 'ಕನ್ನಡ', 'kn'),
  malayalam('Malayalam', 'മലയാളം', 'ml'),
  gujarati('Gujarati', 'ગુજરાતી', 'gu'),
  punjabi('Punjabi', 'ਪੰਜਾਬੀ', 'pa'),
  bengali('Bengali', 'বাংলা', 'bn'),
  odia('Odia', 'ଓଡ଼ିଆ', 'or'),
  assamese('Assamese', 'অসমীয়া', 'as'),
  urdu('Urdu', 'اردو', 'ur');

  final String name;
  final String nativeName;
  final String code;

  const Language(this.name, this.nativeName, this.code);

  /// BCP-47 tag used for TTS and STT APIs.
  String get bcp47 => code == 'en' ? 'en-US' : '$code-IN';

  /// Resolve a BCP-47 tag (e.g. 'hi-IN', 'mr-IN') to a [Language].
  /// Falls back to [Language.hindi] for unrecognised codes.
  static Language fromBcp47(String bcp47Code) {
    final lang = bcp47Code.split('-').first.toLowerCase();
    for (final l in Language.values) {
      if (l.code == lang) return l;
    }
    return Language.hindi;
  }
}
