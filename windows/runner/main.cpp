#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include <app_links/app_links_plugin_c_api.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// 取某进程的可执行映像完整路径（用于校验目标窗口的归属进程）。
std::wstring ProcessImagePath(DWORD pid) {
  std::wstring path;
  HANDLE h = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (h != nullptr) {
    wchar_t buf[MAX_PATH];
    DWORD len = MAX_PATH;
    if (::QueryFullProcessImageNameW(h, 0, buf, &len)) {
      path.assign(buf, len);
    }
    ::CloseHandle(h);
  }
  return path;
}

std::wstring SelfImagePath() {
  wchar_t buf[MAX_PATH];
  DWORD len = ::GetModuleFileNameW(nullptr, buf, MAX_PATH);
  return std::wstring(buf, len);
}

struct EnumCtx {
  std::wstring exe_path;
  DWORD self_pid;
  HWND found;
};

BOOL CALLBACK EnumProc(HWND hwnd, LPARAM lparam) {
  auto *ctx = reinterpret_cast<EnumCtx *>(lparam);
  wchar_t cls[256] = {0};
  if (::GetClassNameW(hwnd, cls, 256) == 0) return TRUE;
  if (std::wstring(cls) != L"FLUTTER_RUNNER_WIN32_WINDOW") return TRUE;
  wchar_t title[256] = {0};
  ::GetWindowTextW(hwnd, title, 256);
  if (std::wstring(title) != L"Linplayer") return TRUE;
  DWORD pid = 0;
  ::GetWindowThreadProcessId(hwnd, &pid);
  if (pid == 0 || pid == ctx->self_pid) return TRUE;
  // L8：必须确认该窗口归属的进程确实是同一个 LinPlayer.exe，否则可能是本地
  // 恶意进程伪造同类同标题窗口企图拦截被转发的(可能含凭据的)深链。
  if (_wcsicmp(ProcessImagePath(pid).c_str(), ctx->exe_path.c_str()) == 0) {
    ctx->found = hwnd;
    return FALSE;  // 命中，停止枚举
  }
  return TRUE;
}

// 找到「另一个运行中的本程序实例」的主窗口；找不到/只有伪造窗口则返回 nullptr。
HWND FindOurInstanceWindow() {
  EnumCtx ctx{SelfImagePath(), ::GetCurrentProcessId(), nullptr};
  ::EnumWindows(EnumProc, reinterpret_cast<LPARAM>(&ctx));
  return ctx.found;
}

}  // namespace

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
      HWND existing = FindOurInstanceWindow();
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
