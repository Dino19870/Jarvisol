import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import '../models/hardware_profile.dart';
import '../utils/app_paths.dart';
import 'log_service.dart';

abstract class HardwareProbe {
  Future<HardwareProfile> probe();
}

// ── Structures Win32 FFI ─────────────────────────────────────────────────────

final class _MEMORYSTATUSEX extends Struct {
  @Uint32()
  external int dwLength;
  @Uint32()
  external int dwMemoryLoad;
  @Uint64()
  external int ullTotalPhys;
  @Uint64()
  external int ullAvailPhys;
  @Uint64()
  external int ullTotalPageFile;
  @Uint64()
  external int ullAvailPageFile;
  @Uint64()
  external int ullTotalVirtual;
  @Uint64()
  external int ullAvailVirtual;
  @Uint64()
  external int ullAvailExtendedVirtual;
}

typedef _GlobalMemoryStatusExC = Int32 Function(Pointer<_MEMORYSTATUSEX>);
typedef _GlobalMemoryStatusExDart = int Function(Pointer<_MEMORYSTATUSEX>);

typedef _GetDiskFreeSpaceExWC = Int32 Function(
  Pointer<Utf16> lpDirectoryName,
  Pointer<Uint64> lpFreeBytesAvailableToCaller,
  Pointer<Uint64> lpTotalNumberOfBytes,
  Pointer<Uint64> lpTotalNumberOfFreeBytes,
);
typedef _GetDiskFreeSpaceExWDart = int Function(
  Pointer<Utf16> lpDirectoryName,
  Pointer<Uint64> lpFreeBytesAvailableToCaller,
  Pointer<Uint64> lpTotalNumberOfBytes,
  Pointer<Uint64> lpTotalNumberOfFreeBytes,
);

// ignore: camel_case_types
final class _DXGI_ADAPTER_DESC extends Struct {
  @Array(128)
  external Array<Uint16> description;
  @Uint32()
  external int vendorId;
  @Uint32()
  external int deviceId;
  @Uint32()
  external int subSysId;
  @Uint32()
  external int revision;
  @IntPtr()
  external int dedicatedVideoMemory;
  @IntPtr()
  external int dedicatedSystemMemory;
  @IntPtr()
  external int sharedSystemMemory;
  @Int64()
  external int adapterLuid;
}

typedef _CreateDXGIFactory1C = Int32 Function(
  Pointer<Uint8> riid,
  Pointer<Pointer<IntPtr>> ppFactory,
);
typedef _CreateDXGIFactory1Dart = int Function(
  Pointer<Uint8> riid,
  Pointer<Pointer<IntPtr>> ppFactory,
);

// ── Registry FFI pour lecture cpuModel sans subprocess ───────────────────────

typedef _RegOpenKeyExWC = Int32 Function(
  IntPtr hKey,
  Pointer<Utf16> lpSubKey,
  Uint32 ulOptions,
  Uint32 samDesired,
  Pointer<IntPtr> phkResult,
);
typedef _RegOpenKeyExWDart = int Function(
  int hKey,
  Pointer<Utf16> lpSubKey,
  int ulOptions,
  int samDesired,
  Pointer<IntPtr> phkResult,
);

typedef _RegQueryValueExWC = Int32 Function(
  IntPtr hKey,
  Pointer<Utf16> lpValueName,
  Pointer<Uint32> lpReserved,
  Pointer<Uint32> lpType,
  Pointer<Uint8> lpData,
  Pointer<Uint32> lpcbData,
);
typedef _RegQueryValueExWDart = int Function(
  int hKey,
  Pointer<Utf16> lpValueName,
  Pointer<Uint32> lpReserved,
  Pointer<Uint32> lpType,
  Pointer<Uint8> lpData,
  Pointer<Uint32> lpcbData,
);

typedef _RegCloseKeyC = Int32 Function(IntPtr hKey);
typedef _RegCloseKeyDart = int Function(int hKey);

/// Sonde matérielle native Windows basée exclusivement sur Win32 FFI & DXGI
class WindowsHardwareProbe implements HardwareProbe {
  const WindowsHardwareProbe();

  @override
  Future<HardwareProfile> probe() async {
    // 1. Architecture & CPU
    final cpuArch = Platform.version.contains('x64') || Platform.version.contains('x86_64')
        ? 'x86_64'
        : (Platform.version.contains('arm64') ? 'arm64' : 'unknown');

    final cpuModelString = _probeCpuModel();
    final logicalProcs = Platform.numberOfProcessors;

    // 2. Mémoire vive (RAM) via GlobalMemoryStatusEx
    int ramTotal = 0;
    int ramAvail = 0;
    MetricReliability ramReliability = MetricReliability.unknown;

    try {
      if (Platform.isWindows) {
        final kernel32 = DynamicLibrary.open('kernel32.dll');
        final globalMemoryStatusEx = kernel32
            .lookupFunction<_GlobalMemoryStatusExC, _GlobalMemoryStatusExDart>('GlobalMemoryStatusEx');

        final memStatus = calloc<_MEMORYSTATUSEX>();
        memStatus.ref.dwLength = sizeOf<_MEMORYSTATUSEX>();

        final ok = globalMemoryStatusEx(memStatus);
        if (ok != 0) {
          ramTotal = memStatus.ref.ullTotalPhys;
          ramAvail = memStatus.ref.ullAvailPhys;
          ramReliability = MetricReliability.reliable;
        }
        calloc.free(memStatus);
      }
    } catch (e) {
      Log.instance.w('hw-probe', 'Erreur sonde RAM Win32: ');
    }

    // 3. Stockage portable
    int diskFree = 0;
    int diskTotal = 0;
    String volumeName = 'Jarvisol';
    MetricReliability diskReliability = MetricReliability.unknown;

    try {
      if (Platform.isWindows) {
        final appDirPath = AppPaths.appDir.path;
        final root = p.rootPrefix(appDirPath);
        volumeName = root.isNotEmpty ? root : 'Portable';

        final kernel32 = DynamicLibrary.open('kernel32.dll');
        final getDiskFreeSpaceExW = kernel32
            .lookupFunction<_GetDiskFreeSpaceExWC, _GetDiskFreeSpaceExWDart>('GetDiskFreeSpaceExW');

        final pDir = appDirPath.toNativeUtf16();
        final pFreeAvailable = calloc<Uint64>();
        final pTotal = calloc<Uint64>();
        final pTotalFree = calloc<Uint64>();

        final ok = getDiskFreeSpaceExW(pDir, pFreeAvailable, pTotal, pTotalFree);
        if (ok != 0) {
          diskFree = pFreeAvailable.value;
          diskTotal = pTotal.value;
          diskReliability = MetricReliability.reliable;
        }

        calloc.free(pDir);
        calloc.free(pFreeAvailable);
        calloc.free(pTotal);
        calloc.free(pTotalFree);
      }
    } catch (e) {
      Log.instance.w('hw-probe', 'Erreur sonde disque Win32: ');
    }

    // 4. GPU & VRAM via DXGI FFI
    final gpuAdapters = <GpuAdapterInfo>[];
    try {
      if (Platform.isWindows) {
        gpuAdapters.addAll(_probeDxgiGpus());
      }
    } catch (e) {
      Log.instance.w('hw-probe', 'Erreur sonde DXGI GPU: ');
    }

    // 5. Vulkan distincts concepts
    bool backendPresent = false;
    bool loaderPresent = false;
    try {
      final vulkanSys = File('C:\\\\Windows\\\\System32\\\\vulkan-1.dll');
      loaderPresent = vulkanSys.existsSync();
      final vulkanLocal = File(p.join(AppPaths.appDir.path, 'sd_vulkan', 'ggml-vulkan.dll'));
      backendPresent = vulkanLocal.existsSync();
    } catch (_) {}

    // 6. OS & Windows Version
    final osVerRaw = Platform.operatingSystemVersion;
    final osVer = osVerRaw.isNotEmpty && !osVerRaw.contains('(build )')
        ? osVerRaw
        : null;

    return HardwareProfile(
      cpuArch: HardwareMetric(
        value: cpuArch,
        source: 'Platform.version',
        reliability: MetricReliability.reliable,
      ),
      cpuModel: cpuModelString != null && cpuModelString.isNotEmpty
          ? HardwareMetric(
              value: cpuModelString,
              source: 'HKLM\\Hardware\\CentralProcessor',
              reliability: MetricReliability.reliable,
            )
          : const HardwareMetric.unknown('none'),
      logicalProcessors: HardwareMetric(
        value: logicalProcs,
        source: 'Platform.numberOfProcessors',
        reliability: MetricReliability.reliable,
      ),
      physicalCores: const HardwareMetric.unknown('none'), // Règle 4: Si non mesurable sans info étendue -> UNKNOWN
      ramTotalBytes: ramReliability == MetricReliability.reliable
          ? HardwareMetric(
              value: ramTotal,
              source: 'GlobalMemoryStatusEx',
              reliability: MetricReliability.reliable,
            )
          : const HardwareMetric.unknown('none'),
      ramAvailableBytes: ramReliability == MetricReliability.reliable
          ? HardwareMetric(
              value: ramAvail,
              source: 'GlobalMemoryStatusEx',
              reliability: MetricReliability.reliable,
            )
          : const HardwareMetric.unknown('none'),
      gpuAdapters: gpuAdapters,
      vulkanInfo: VulkanSupportInfo(
        backendPresent: backendPresent,
        loaderPresent: loaderPresent,
        deviceSupportReliability: MetricReliability.unknown,
        deviceSupported: null,
      ),
      portableDiskTotalBytes: diskReliability == MetricReliability.reliable
          ? HardwareMetric(
              value: diskTotal,
              source: 'GetDiskFreeSpaceExW',
              reliability: MetricReliability.reliable,
            )
          : const HardwareMetric.unknown('none'),
      portableDiskFreeBytes: diskReliability == MetricReliability.reliable
          ? HardwareMetric(
              value: diskFree,
              source: 'GetDiskFreeSpaceExW',
              reliability: MetricReliability.reliable,
            )
          : const HardwareMetric.unknown('none'),
      portableDiskVolume: HardwareMetric(
        value: volumeName,
        source: 'AppPaths.appDir',
        reliability: MetricReliability.reliable,
      ),
      windowsVersion: osVer != null
          ? HardwareMetric(
              value: osVer,
              source: 'Platform.operatingSystemVersion',
              reliability: MetricReliability.reliable,
            )
          : const HardwareMetric.unknown('none'),
      osArch: const HardwareMetric(
        value: 'windows-x64',
        source: 'Platform.operatingSystem',
        reliability: MetricReliability.heuristic,
      ),
      scanTimestamp: DateTime.now(),
    );
  }

  String? _probeCpuModel() {
    try {
      if (!Platform.isWindows) return null;
      final advapi32 = DynamicLibrary.open('advapi32.dll');
      final regOpenKeyExW = advapi32.lookupFunction<_RegOpenKeyExWC, _RegOpenKeyExWDart>('RegOpenKeyExW');
      final regQueryValueExW = advapi32.lookupFunction<_RegQueryValueExWC, _RegQueryValueExWDart>('RegQueryValueExW');
      final regCloseKey = advapi32.lookupFunction<_RegCloseKeyC, _RegCloseKeyDart>('RegCloseKey');

      const hkeyLocalMachine = 0x80000002;
      const keyRead = 0x20019;
      final subKey = 'HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0'.toNativeUtf16();
      final phk = calloc<IntPtr>();

      final res = regOpenKeyExW(hkeyLocalMachine, subKey, 0, keyRead, phk);
      calloc.free(subKey);
      if (res != 0) {
        calloc.free(phk);
        return null;
      }

      final hKey = phk.value;
      calloc.free(phk);

      final valName = 'ProcessorNameString'.toNativeUtf16();
      final pType = calloc<Uint32>();
      final pCbData = calloc<Uint32>();
      pCbData.value = 256;
      final pData = calloc<Uint8>(256);

      final queryRes = regQueryValueExW(hKey, valName, nullptr, pType, pData, pCbData);
      calloc.free(valName);
      calloc.free(pType);

      String? result;
      if (queryRes == 0) {
        result = pData.cast<Utf16>().toDartString().trim();
      }

      calloc.free(pCbData);
      calloc.free(pData);
      regCloseKey(hKey);

      return result;
    } catch (_) {
      return null;
    }
  }

  List<GpuAdapterInfo> _probeDxgiGpus() {
    final list = <GpuAdapterInfo>[];
    try {
      final dxgi = DynamicLibrary.open('dxgi.dll');
      final createDXGIFactory1 = dxgi
          .lookupFunction<_CreateDXGIFactory1C, _CreateDXGIFactory1Dart>('CreateDXGIFactory1');

      // IID_IDXGIFactory1 = 770aae78-f26f-4dba-a829-253c83d1b387
      final iidBytes = [
        0x78, 0xae, 0x0a, 0x77,
        0x6f, 0xf2,
        0xba, 0x4d,
        0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87
      ];
      final pIID = calloc<Uint8>(16);
      for (int i = 0; i < 16; i++) {
        pIID[i] = iidBytes[i];
      }

      final ppFactory = calloc<Pointer<IntPtr>>();
      final hr = createDXGIFactory1(pIID, ppFactory);
      calloc.free(pIID);

      if (hr == 0 && ppFactory.value != nullptr) {
        final factory = ppFactory.value;
        final factoryVtable = factory.value;

        // EnumAdapters (index 7)
        final enumAdaptersAddr = (Pointer<IntPtr>.fromAddress(factoryVtable) + 7).value;
        final enumAdapters = Pointer<NativeFunction<Int32 Function(Pointer<IntPtr>, Uint32, Pointer<Pointer<IntPtr>>)>>.fromAddress(
          enumAdaptersAddr,
        ).asFunction<int Function(Pointer<IntPtr>, int, Pointer<Pointer<IntPtr>>)>();

        int index = 0;
        while (true) {
          final ppAdapter = calloc<Pointer<IntPtr>>();
          final hrEnum = enumAdapters(factory, index, ppAdapter);
          if (hrEnum != 0 || ppAdapter.value == nullptr) {
            calloc.free(ppAdapter);
            break;
          }

          final adapter = ppAdapter.value;
          final adapterVtable = adapter.value;

          // GetDesc (index 8)
          final getDescAddr = (Pointer<IntPtr>.fromAddress(adapterVtable) + 8).value;
          final getDesc = Pointer<NativeFunction<Int32 Function(Pointer<IntPtr>, Pointer<_DXGI_ADAPTER_DESC>)>>.fromAddress(
            getDescAddr,
          ).asFunction<int Function(Pointer<IntPtr>, Pointer<_DXGI_ADAPTER_DESC>)>();

          final desc = calloc<_DXGI_ADAPTER_DESC>();
          final hrDesc = getDesc(adapter, desc);
          if (hrDesc == 0) {
            final nameUnits = <int>[];
            for (int k = 0; k < 128; k++) {
              final code = desc.ref.description[k];
              if (code == 0) break;
              nameUnits.add(code);
            }
            final name = String.fromCharCodes(nameUnits);
            final vendorId = desc.ref.vendorId;
            final deviceId = desc.ref.deviceId;
            final vram = desc.ref.dedicatedVideoMemory;
            final shared = desc.ref.sharedSystemMemory;
            final isBasic = vendorId == 0x1414 || name.contains('Basic Render');

            // Règle 6: Si pilote basique/logiciel -> software.
            // Sinon -> unknown (ne pas conclure discrete uniquement car VRAM >= 2 Go, les UMA pouvant déclarer de la VRAM).
            final adapterType = isBasic ? GpuAdapterType.software : GpuAdapterType.unknown;

            list.add(GpuAdapterInfo(
              name: name,
              vendorId: vendorId,
              deviceId: deviceId,
              dedicatedVideoMemoryBytes: vram,
              sharedSystemMemoryBytes: shared,
              isBasicRenderDriver: isBasic,
              adapterType: adapterType,
            ));
          }
          calloc.free(desc);

          // Release adapter (index 2)
          final releaseAddr = (Pointer<IntPtr>.fromAddress(adapterVtable) + 2).value;
          final releaseAdapter = Pointer<NativeFunction<Uint32 Function(Pointer<IntPtr>)>>.fromAddress(
            releaseAddr,
          ).asFunction<int Function(Pointer<IntPtr>)>();
          releaseAdapter(adapter);
          calloc.free(ppAdapter);

          index++;
        }

        // Release factory (index 2)
        final releaseFactoryAddr = (Pointer<IntPtr>.fromAddress(factoryVtable) + 2).value;
        final releaseFactory = Pointer<NativeFunction<Uint32 Function(Pointer<IntPtr>)>>.fromAddress(
          releaseFactoryAddr,
        ).asFunction<int Function(Pointer<IntPtr>)>();
        releaseFactory(factory);
      }
      calloc.free(ppFactory);
    } catch (e) {
      Log.instance.w('hw-probe', 'Erreur DXGI enumeration: ');
    }
    return list;
  }
}
