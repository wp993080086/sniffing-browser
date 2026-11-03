#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <dbghelp.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Write the crashing call stack to crash_<timestamp>.dmp next to the exe.
//
// Why this exists: flutter_inappwebview_windows has an unfixed access
// violation in its native layer. Dart-side logging and error handlers never
// see it, so a minidump is the only way to locate the fault. The timestamp
// keeps repeated crashes from overwriting each other.
LONG WINAPI WriteCrashDump(EXCEPTION_POINTERS* info) {
  wchar_t exe_path[MAX_PATH];
  DWORD length = ::GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  std::wstring dir(exe_path, length);
  const size_t slash = dir.find_last_of(L"\\/");
  if (slash != std::wstring::npos) {
    dir = dir.substr(0, slash + 1);
  }

  SYSTEMTIME st;
  ::GetLocalTime(&st);
  wchar_t name[128];
  swprintf_s(name, L"crash_%04d%02d%02d_%02d%02d%02d.dmp", st.wYear, st.wMonth,
             st.wDay, st.wHour, st.wMinute, st.wSecond);

  const std::wstring path = dir + name;
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file != INVALID_HANDLE_VALUE) {
    MINIDUMP_EXCEPTION_INFORMATION mei{};
    mei.ThreadId = ::GetCurrentThreadId();
    mei.ExceptionPointers = info;
    mei.ClientPointers = FALSE;
    ::MiniDumpWriteDump(::GetCurrentProcess(), ::GetCurrentProcessId(), file,
                        MiniDumpNormal, &mei, nullptr, nullptr);
    ::CloseHandle(file);
  }

  // Hand back to the system so the exit code and WER record stay unchanged.
  return EXCEPTION_EXECUTE_HANDLER;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::SetUnhandledExceptionFilter(WriteCrashDump);

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
  if (!window.Create(L"sniffing_browser", origin, size)) {
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
