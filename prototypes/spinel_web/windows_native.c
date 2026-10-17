/* Windows-only boundary, statically linked into the Spinel executable. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <aclapi.h>
#include <shellapi.h>
#include <stdlib.h>

static wchar_t *wide_path(const char *path) {
  int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
  if (!length) return NULL;
  wchar_t *wide = calloc((size_t)length, sizeof(wchar_t));
  if (!wide) return NULL;
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, length)) {
    free(wide);
    return NULL;
  }
  return wide;
}

static TOKEN_USER *current_user(void) {
  HANDLE token = NULL;
  DWORD size = 0;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return NULL;
  GetTokenInformation(token, TokenUser, NULL, 0, &size);
  TOKEN_USER *user = calloc(1, size);
  if (user && !GetTokenInformation(token, TokenUser, user, size, &size)) {
    free(user);
    user = NULL;
  }
  CloseHandle(token);
  return user;
}

/* Reject permissive ACLs, alternate owners, junctions and symlinks. Never
   repair an existing directory: its old files may already have been exposed. */
static int verify_private(wchar_t *path, PSID user, int directory) {
  DWORD attributes = GetFileAttributesW(path);
  if (attributes == INVALID_FILE_ATTRIBUTES) return 1;
  if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) return 1;
  if (!!(attributes & FILE_ATTRIBUTE_DIRECTORY) != directory) return 1;
  PSID owner = NULL;
  PACL acl = NULL;
  PSECURITY_DESCRIPTOR descriptor = NULL;
  DWORD error = GetNamedSecurityInfoW(path, SE_FILE_OBJECT,
      OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
      &owner, NULL, &acl, NULL, &descriptor);
  BYTE admin_sid[SECURITY_MAX_SID_SIZE];
  DWORD admin_size = sizeof(admin_sid);
  int admin_owner = CreateWellKnownSid(WinBuiltinAdministratorsSid, NULL, admin_sid, &admin_size) &&
      owner && EqualSid(owner, admin_sid);
  int valid = error == ERROR_SUCCESS && owner && (EqualSid(owner, user) || admin_owner) && acl && acl->AceCount > 0;
  if (valid) {
    for (DWORD i = 0; i < acl->AceCount; i++) {
      ACCESS_ALLOWED_ACE *ace = NULL;
      if (!GetAce(acl, i, (void **)&ace) || ace->Header.AceType != ACCESS_ALLOWED_ACE_TYPE ||
          !EqualSid((PSID)&ace->SidStart, user) ||
          (ace->Mask & FILE_ALL_ACCESS) != FILE_ALL_ACCESS ||
          (ace->Header.AceFlags & INHERIT_ONLY_ACE) ||
          (directory && (ace->Header.AceFlags & (OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE)) !=
              (OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE))) {
        valid = 0;
        break;
      }
    }
  }
  if (descriptor) LocalFree(descriptor);
  return valid ? 0 : 1;
}

int tycho_private_directory(const char *path) {
  wchar_t *wide = wide_path(path);
  TOKEN_USER *user = current_user();
  PACL acl = NULL;
  int result = 1;
  if (!wide || !user) goto done;
  if (GetFileAttributesW(wide) == INVALID_FILE_ATTRIBUTES) {
    if (GetLastError() != ERROR_FILE_NOT_FOUND && GetLastError() != ERROR_PATH_NOT_FOUND) goto done;
    EXPLICIT_ACCESSW access = {0};
    access.grfAccessPermissions = FILE_ALL_ACCESS;
    access.grfAccessMode = SET_ACCESS;
    access.grfInheritance = SUB_CONTAINERS_AND_OBJECTS_INHERIT;
    access.Trustee.TrusteeForm = TRUSTEE_IS_SID;
    access.Trustee.TrusteeType = TRUSTEE_IS_USER;
    access.Trustee.ptstrName = (wchar_t *)user->User.Sid;
    if (SetEntriesInAclW(1, &access, NULL, &acl) != ERROR_SUCCESS) goto done;
    SECURITY_DESCRIPTOR descriptor;
    if (!InitializeSecurityDescriptor(&descriptor, SECURITY_DESCRIPTOR_REVISION) ||
        !SetSecurityDescriptorOwner(&descriptor, user->User.Sid, FALSE) ||
        !SetSecurityDescriptorDacl(&descriptor, TRUE, acl, FALSE) ||
        !SetSecurityDescriptorControl(&descriptor, SE_DACL_PROTECTED, SE_DACL_PROTECTED)) goto done;
    SECURITY_ATTRIBUTES security = {sizeof(SECURITY_ATTRIBUTES), &descriptor, FALSE};
    if (!CreateDirectoryW(wide, &security)) goto done;
  }
  result = verify_private(wide, user->User.Sid, 1);
done:
  if (acl) LocalFree(acl);
  free(user);
  free(wide);
  return result;
}

int tycho_private_file(const char *path) {
  wchar_t *wide = wide_path(path);
  TOKEN_USER *user = current_user();
  int result = 1;
  if (wide && user) {
    if (GetFileAttributesW(wide) == INVALID_FILE_ATTRIBUTES && GetLastError() == ERROR_FILE_NOT_FOUND)
      result = 0;
    else result = verify_private(wide, user->User.Sid, 0);
  }
  free(user);
  free(wide);
  return result;
}

int tycho_worker_job(void) {
  /* A non-inheritable handle held only by the worker. Configure before the
     worker creates any agent child, to avoid an assignment race. */
  HANDLE job = CreateJobObjectW(NULL, NULL);
  if (!job) return 1;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) ||
      !AssignProcessToJobObject(job, GetCurrentProcess())) {
    CloseHandle(job);
    return 1;
  }
  /* Keep it open until process exit. Do not enable either breakaway flag. */
  return 0;
}

const char *tycho_executable(void) {
  static char path[131072];
  wchar_t wide[32768];
  DWORD length = GetModuleFileNameW(NULL, wide, 32768);
  if (!length || length >= 32768 || !WideCharToMultiByte(CP_UTF8, 0, wide, -1, path, sizeof(path), NULL, NULL))
    return "";
  return path;
}

/* The pinned compiler's narrow main(argc, argv) loses characters outside the
   Windows ANSI code page. Read the original UTF-16 arguments at this boundary. */
const char *tycho_argument(int index) {
  static char result[131072];
  int count = 0;
  wchar_t **arguments = CommandLineToArgvW(GetCommandLineW(), &count);
  result[0] = 0;
  if (arguments && index >= 0 && index < count)
    WideCharToMultiByte(CP_UTF8, 0, arguments[index], -1, result, sizeof(result), NULL, NULL);
  if (arguments) LocalFree(arguments);
  return result;
}
