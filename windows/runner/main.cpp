#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include <app_links/app_links_plugin_c_api.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 自定义协议深链(linplayer://...)单实例转发：
  // 浏览器点链接会以 `linplayer.exe linplayer://...` 再启一个进程。若已有实例在运行，
  // 把链接经 WM_COPYDATA 转发给它(app_links 的 SendAppLink)并立即退出，避免开第二个
  // 窗口；没有运行中实例时则照常启动，由 getInitialLink 处理该链接。
  {
    int argc = 0;
    LPWSTR *argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
    bool has_link = false;
    if (argv != nullptr) {
      for (int i = 1; i < argc; i++) {
        if (std::wstring(argv[i]).rfind(L"linplayer:", 0) == 0) {
          has_link = true;
          break;
        }
      }
      ::LocalFree(argv);
    }
    if (has_link) {
      HWND existing =
          ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Linplayer");
      if (existing != nullptr) {
        // 把运行中的窗口带到前台，再转发链接，体验上即「唤起」。
        if (::IsIconic(existing)) {
          ::ShowWindow(existing, SW_RESTORE);
        }
        ::SetForegroundWindow(existing);
        SendAppLink(existing);
        return EXIT_SUCCESS;
      }
    }
  }

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
  if (!window.Create(L"Linplayer", origin, size)) {
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
