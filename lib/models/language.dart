enum Language {
  hindi('Hindi', 'हिंदी', 'hi'),
  marathi('Marathi', 'मराठी', 'mr'),
  telugu('Telugu', 'తెలుగు', 'te'),
  english('English', 'English', 'en');

  final String name;
  final String nativeName;
  final String code;

  const Language(this.name, this.nativeName, this.code);
}
