#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <DbgHelp.h>

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace fs = std::filesystem;

static LONG WINAPI JarvisolUnhandledExceptionFilter(EXCEPTION_POINTERS* pExceptionPointers) {
  try {
    wchar_t exePath[MAX_PATH];
    if (::GetModuleFileNameW(nullptr, exePath, MAX_PATH) != 0) {
      fs::path appDir = fs::path(exePath).parent_path();
      fs::path dataDir = appDir / "data";
      fs::path logsDir = dataDir / "logs";
      fs::path crashDumpsDir = dataDir / "crash_dumps";

      std::error_code ec;
      fs::create_directories(logsDir, ec);
      fs::create_directories(crashDumpsDir, ec);

      auto now = std::chrono::system_clock::now();
      auto in_time_t = std::chrono::system_clock::to_time_t(now);
      std::tm bt{};
      localtime_s(&bt, &in_time_t);

      std::ostringstream ssTime;
      ssTime << std::put_time(&bt, "%Y%m%d_%H%M%S");
      std::string timestampStr = ssTime.str();

      // Write fatal crash entry in data/logs/crash_fatal.log
      fs::path fatalLog = logsDir / "crash_fatal.log";
      std::ofstream ofs(fatalLog, std::ios::app);
      if (ofs.is_open()) {
        DWORD code = (pExceptionPointers && pExceptionPointers->ExceptionRecord)
                         ? pExceptionPointers->ExceptionRecord->ExceptionCode
                         : 0;
        void* address = (pExceptionPointers && pExceptionPointers->ExceptionRecord)
                            ? pExceptionPointers->ExceptionRecord->ExceptionAddress
                            : nullptr;
        ofs << "[" << timestampStr << "] FATAL UNHANDLED NATIVE EXCEPTION: 0x"
            << std::hex << std::uppercase << code << " at address 0x" << address
            << std::dec << " (PID: " << ::GetCurrentProcessId() << ")\n";
        ofs.flush();
      }

      // Max 3 minidumps retention: remove oldest if count >= 3
      std::vector<fs::directory_entry> dmpFiles;
      for (const auto& entry : fs::directory_iterator(crashDumpsDir, ec)) {
        if (entry.is_regular_file(ec) && entry.path().extension() == ".dmp") {
          dmpFiles.push_back(entry);
        }
      }
      if (dmpFiles.size() >= 3) {
        std::sort(dmpFiles.begin(), dmpFiles.end(), [](const auto& a, const auto& b) {
          std::error_code ec1, ec2;
          return a.last_write_time(ec1) < b.last_write_time(ec2);
        });
        size_t toDelete = dmpFiles.size() - 2; // leave 2 so newly created one makes 3
        for (size_t i = 0; i < toDelete && i < dmpFiles.size(); ++i) {
          fs::remove(dmpFiles[i].path(), ec);
        }
      }

      // Generate MiniDump
      fs::path dumpPath = crashDumpsDir / ("crash_" + timestampStr + ".dmp");
      HANDLE hFile = ::CreateFileW(dumpPath.c_str(), GENERIC_WRITE, FILE_SHARE_READ,
                                   nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
      if (hFile != INVALID_HANDLE_VALUE) {
        MINIDUMP_EXCEPTION_INFORMATION mei;
        mei.ThreadId = ::GetCurrentThreadId();
        mei.ExceptionPointers = pExceptionPointers;
        mei.ClientPointers = FALSE;

        ::MiniDumpWriteDump(::GetCurrentProcess(), ::GetCurrentProcessId(), hFile,
                            MiniDumpNormal, &mei, nullptr, nullptr);
        ::CloseHandle(hFile);
      }
    }
  } catch (...) {
    // Gracefully handle any failure in the exception filter
  }
  return EXCEPTION_CONTINUE_SEARCH;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  ::SetUnhandledExceptionFilter(JarvisolUnhandledExceptionFilter);

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Jarvisol", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
