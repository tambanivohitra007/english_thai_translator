import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const String _apiKeyKey = 'openai_api_key';
  static const String _voiceKey = 'openai_voice';

  final SharedPreferences _prefs;

  SettingsService(this._prefs);

  static Future<SettingsService> init() async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsService(prefs);
  }

  String? getApiKey() {
    return _prefs.getString(_apiKeyKey);
  }

  Future<void> setApiKey(String apiKey) async {
    await _prefs.setString(_apiKeyKey, apiKey);
  }

  String getVoice() {
    return _prefs.getString(_voiceKey) ?? 'alloy';
  }

  Future<void> setVoice(String voice) async {
    await _prefs.setString(_voiceKey, voice);
  }
}
