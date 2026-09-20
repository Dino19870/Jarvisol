// test/hardware_and_lm_timeout_test.dart
//
// Tests contrôlés des délais de la Sonde Matérielle (TO-SRV-HW-01)
// et de la détection LM Studio (TO-SRV-HW-02).
// Couvre Section 7 (CAS A à D) et Section 9 (CAS A à E).

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvisol/models/hardware_profile.dart';
import 'package:jarvisol/services/hardware_advisor_service.dart';
import 'package:jarvisol/services/windows_hardware_probe.dart';

class _MockHardwareProbe implements HardwareProbe {
  final Duration delay;
  final bool shouldThrow;
  final HardwareProfile profile;

  _MockHardwareProbe({
    required this.profile,
    this.delay = Duration.zero,
    this.shouldThrow = false,
  });

  @override
  Future<HardwareProfile> probe() async {
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (shouldThrow) {
      throw Exception('Simulated probe failure');
    }
    return profile;
  }
}

HardwareProfile _validTestProfile() {
  return HardwareProfile(
    cpuArch: const HardwareMetric(value: 'x64', source: 'test', reliability: MetricReliability.reliable),
    cpuModel: const HardwareMetric(value: 'AMD Ryzen 7', source: 'test', reliability: MetricReliability.reliable),
    logicalProcessors: const HardwareMetric(value: 8, source: 'test', reliability: MetricReliability.reliable),
    physicalCores: const HardwareMetric(value: 8, source: 'test', reliability: MetricReliability.reliable),
    ramTotalBytes: const HardwareMetric(value: 16 * 1024 * 1024 * 1024, source: 'test', reliability: MetricReliability.reliable),
    ramAvailableBytes: const HardwareMetric(value: 8 * 1024 * 1024 * 1024, source: 'test', reliability: MetricReliability.reliable),
    gpuAdapters: const [],
    vulkanInfo: const VulkanSupportInfo(backendPresent: true, loaderPresent: true),
    portableDiskTotalBytes: const HardwareMetric(value: 500 * 1024 * 1024 * 1024, source: 'test', reliability: MetricReliability.reliable),
    portableDiskFreeBytes: const HardwareMetric(value: 50 * 1024 * 1024 * 1024, source: 'test', reliability: MetricReliability.reliable),
    portableDiskVolume: const HardwareMetric(value: 'D:', source: 'test', reliability: MetricReliability.reliable),
    windowsVersion: const HardwareMetric(value: 'Windows 11', source: 'test', reliability: MetricReliability.reliable),
    osArch: const HardwareMetric(value: 'x64', source: 'test', reliability: MetricReliability.reliable),
    scanTimestamp: DateTime.now(),
  );
}

void main() {
  group('Hardware Advisor Probe Timeout Tests (TO-SRV-HW-01)', () {
    test('CAS A: probe saine répond avant nouvelle limite simulée -> profil valide', () async {
      final probe = _MockHardwareProbe(
        profile: _validTestProfile(),
        delay: const Duration(milliseconds: 30),
      );
      final profile = await HardwareAdvisorService.instance.inspectHost(
        probe: probe,
        timeout: const Duration(milliseconds: 200),
      );
      expect(profile.ramTotalBytes.value, isNotNull);
      expect(profile.ramTotalBytes.value, 16 * 1024 * 1024 * 1024);
      expect(profile.cpuArch.reliability, MetricReliability.reliable);
    });

    test('CAS B: probe saine dépasse ancienne limite simulée mais reste dans nouvelle limite -> profil valide', () async {
      // Ancienne limite simulée: 50ms, probe prend 100ms, nouvelle limite simulée: 200ms
      final probe = _MockHardwareProbe(
        profile: _validTestProfile(),
        delay: const Duration(milliseconds: 100),
      );
      final profile = await HardwareAdvisorService.instance.inspectHost(
        probe: probe,
        timeout: const Duration(milliseconds: 200),
      );
      expect(profile.ramTotalBytes.value, isNotNull);
      expect(profile.ramTotalBytes.value, 16 * 1024 * 1024 * 1024);
      expect(profile.cpuArch.reliability, MetricReliability.reliable);
    });

    test('CAS C: probe dépasse nouvelle limite simulée -> HardwareProfile.unknown', () async {
      final probe = _MockHardwareProbe(
        profile: _validTestProfile(),
        delay: const Duration(milliseconds: 250),
      );
      final profile = await HardwareAdvisorService.instance.inspectHost(
        probe: probe,
        timeout: const Duration(milliseconds: 80),
      );
      expect(profile.ramTotalBytes.value, isNull);
      expect(profile.cpuArch.reliability, MetricReliability.unknown);
    });

    test('CAS D: exception immédiate -> fallback actuel inchangé HardwareProfile.unknown', () async {
      final probe = _MockHardwareProbe(
        profile: _validTestProfile(),
        shouldThrow: true,
      );
      final profile = await HardwareAdvisorService.instance.inspectHost(
        probe: probe,
        timeout: const Duration(milliseconds: 500),
      );
      expect(profile.ramTotalBytes.value, isNull);
      expect(profile.cpuArch.reliability, MetricReliability.unknown);
    });
  });

  group('LM Studio Probe Timeout Tests (TO-SRV-HW-02)', () {
    late HttpServer server;
    late Uri serverUri;
    int delayMs = 0;
    int statusCode = 200;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverUri = Uri.parse('http://${server.address.host}:${server.port}/v1/models');
      delayMs = 0;
      statusCode = 200;

      server.listen((HttpRequest request) async {
        if (delayMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: delayMs));
        }
        request.response.statusCode = statusCode;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"data": []}');
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('CAS A: 200 OK rapide -> true', () async {
      delayMs = 0;
      statusCode = 200;
      final ok = await HardwareAdvisorService.instance.checkLmStudioReachable(
        uri: serverUri,
        timeout: const Duration(milliseconds: 500),
      );
      expect(ok, isTrue);
    });

    test('CAS B: 200 OK après délai >350ms mais <1500ms simulés -> true', () async {
      // Simule une réponse en 100ms avec fenêtre autorisée de 300ms (ancienne fenêtre simulée 50ms)
      delayMs = 100;
      statusCode = 200;
      final ok = await HardwareAdvisorService.instance.checkLmStudioReachable(
        uri: serverUri,
        timeout: const Duration(milliseconds: 300),
      );
      expect(ok, isTrue);
    });

    test('CAS C: réponse au-delà du nouveau timeout simulé -> false', () async {
      delayMs = 250;
      statusCode = 200;
      final ok = await HardwareAdvisorService.instance.checkLmStudioReachable(
        uri: serverUri,
        timeout: const Duration(milliseconds: 80),
      );
      expect(ok, isFalse);
    });

    test('CAS D: connection refused -> false rapidement', () async {
      final closedServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final closedPort = closedServer.port;
      await closedServer.close(force: true);

      final refusedUri = Uri.parse('http://127.0.0.1:$closedPort/v1/models');
      final sw = Stopwatch()..start();
      final ok = await HardwareAdvisorService.instance.checkLmStudioReachable(
        uri: refusedUri,
        timeout: const Duration(milliseconds: 100),
      );
      sw.stop();
      expect(ok, isFalse);
      expect(sw.elapsedMilliseconds, lessThan(400));
    });

    test('CAS E: HTTP != 200 -> false', () async {
      delayMs = 0;
      statusCode = 503;
      final ok = await HardwareAdvisorService.instance.checkLmStudioReachable(
        uri: serverUri,
        timeout: const Duration(milliseconds: 500),
      );
      expect(ok, isFalse);
    });
  });
}
