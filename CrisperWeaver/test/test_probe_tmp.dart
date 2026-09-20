
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:jarvisol/services/model_service.dart';
import 'package:jarvisol/services/settings_service.dart';
import 'package:jarvisol/utils/portable_preferences.dart';

void main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final prefs = await PortablePreferences.getInstance();
  final settings = SettingsService(prefs);
  final dio = Dio();
  final svc = ModelService(settings, dio: dio);
  print('ModelService created successfully');
}
