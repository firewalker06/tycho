#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

int wmain(int argc, wchar_t **argv) {
  if (argc > 1 && !wcscmp(argv[1], L"--child")) { Sleep(120000); return 0; }
  if (argc != 3) return 8;
  printf("fixture-start\nserver-token=%s\nprototype-env=%s\n",
      getenv("TYCHO_REMOTE_TOKEN") ? getenv("TYCHO_REMOTE_TOKEN") : "unset",
      getenv("TYCHO_PROTO_STATE") ? getenv("TYCHO_PROTO_STATE") : "unset");
  fprintf(stderr, "stderr-visible\n");
  if (!wcscmp(argv[1], L"HOLD") || !wcscmp(argv[1], L"LEADER_EXITS")) {
    wchar_t path[32768], command[32780];
    GetModuleFileNameW(NULL, path, 32768);
    swprintf(command, 32780, L"\"%ls\" --child", path);
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION process = {0};
    startup.cb = sizeof(startup);
    if (!CreateProcessW(path, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process)) return 9;
    FILE *pid = fopen("child.pid", "w");
    fprintf(pid, "%lu", process.dwProcessId);
    fclose(pid);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    fflush(stdout);
    if (!wcscmp(argv[1], L"HOLD")) Sleep(120000);
  }
  int size = WideCharToMultiByte(CP_UTF8, 0, argv[1], -1, NULL, 0, NULL, NULL);
  char *prompt = calloc((size_t)size, 1);
  WideCharToMultiByte(CP_UTF8, 0, argv[1], -1, prompt, size, NULL, NULL);
  FILE *result = _wfopen(argv[2], L"wb");
  if (!result) return 10;
  fwrite(prompt, 1, (size_t)size - 1, result);
  fclose(result);
  free(prompt);
  puts("fixture-complete");
  return !wcscmp(argv[1], L"FAIL") ? 7 : 0;
}
