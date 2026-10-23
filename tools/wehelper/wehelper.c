/*
 * wehelper.exe — runs under Wine next to Steam and drives the Steam Workshop for
 * Wallpaper Engine (appid 431960) through Wallpaper Engine's own steam_api64.dll,
 * so Open Wallpaper Engine can subscribe/unsubscribe without a Web API key.
 *
 *   wehelper subscribe <id>      subscribe, then report download progress until installed
 *   wehelper unsubscribe <id>
 *   wehelper status <id>...      one JSON line per item
 *   wehelper list                subscribed item ids
 *
 * Output: one JSON object per line on stdout.
 * Build:  x86_64-w64-mingw32-gcc -O2 -o wehelper.exe wehelper.c   (Wine, steam_api64.dll)
 *         clang -O2 -o wehelper-mac wehelper.c                     (native Steam for Mac,
 *                                                                    libsteam_api.dylib next to it)
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#define DEFAULT_DLL "C:\\Program Files (x86)\\Steam\\steamapps\\common\\wallpaper_engine\\bin\\steam_api64.dll"
#define WE_CDECL __cdecl
typedef HMODULE Library;
static Library open_library(const char *path) { return LoadLibraryA(path); }
static void *symbol(Library lib, const char *name) { return (void *)GetProcAddress(lib, name); }
static void set_env(const char *name, const char *value) { SetEnvironmentVariableA(name, value); }
static void sleep_ms(int ms) { Sleep(ms); }
#else
#include <dlfcn.h>
#include <unistd.h>
#define DEFAULT_DLL "@executable_path/libsteam_api.dylib"
#define WE_CDECL
typedef void *Library;
static Library open_library(const char *path) { return dlopen(path, RTLD_NOW); }
static void *symbol(Library lib, const char *name) { return dlsym(lib, name); }
static void set_env(const char *name, const char *value) { setenv(name, value, 1); }
static void sleep_ms(int ms) { usleep(ms * 1000); }
#define _strtoui64 strtoull
#endif

enum { STATE_SUBSCRIBED = 1, STATE_INSTALLED = 4, STATE_NEEDS_UPDATE = 8, STATE_DOWNLOADING = 16, STATE_DOWNLOAD_PENDING = 32 };

typedef int      (WE_CDECL *InitFlat_t)(char *errMsg);
typedef void     (WE_CDECL *Void_t)(void);
typedef void *   (WE_CDECL *GetUGC_t)(void);
typedef uint64_t (WE_CDECL *ItemCall_t)(void *ugc, uint64_t id);
typedef uint32_t (WE_CDECL *ItemState_t)(void *ugc, uint64_t id);
typedef int      (WE_CDECL *DownloadInfo_t)(void *ugc, uint64_t id, uint64_t *done, uint64_t *total);
typedef int      (WE_CDECL *InstallInfo_t)(void *ugc, uint64_t id, uint64_t *size, char *folder, uint32_t folderSize, uint32_t *timestamp);
typedef int      (WE_CDECL *DownloadItem_t)(void *ugc, uint64_t id, int highPriority);
typedef uint32_t (WE_CDECL *NumSubscribed_t)(void *ugc, int includeLocallyDisabled);
typedef uint32_t (WE_CDECL *Subscribed_t)(void *ugc, uint64_t *ids, uint32_t max, int includeLocallyDisabled);

static Library dll;
static void *ugc;
static Void_t RunCallbacks;
static ItemState_t GetItemState;
static DownloadInfo_t GetItemDownloadInfo;
static InstallInfo_t GetItemInstallInfo;

static void *need(const char *name) {
    void *p = symbol(dll, name);
    if (!p) { printf("{\"error\":\"missing export %s\"}\n", name); fflush(stdout); exit(3); }
    return p;
}

static void json_escape(const char *in, char *out, size_t size) {
    size_t o = 0;
    for (; *in && o + 2 < size; in++) {
        if (*in == '\\' || *in == '"') out[o++] = '\\';
        out[o++] = *in;
    }
    out[o] = 0;
}

static uint32_t report(uint64_t id) {
    uint32_t state = GetItemState(ugc, id);
    uint64_t done = 0, total = 0, size = 0;
    uint32_t stamp = 0;
    char folder[1024] = "", escaped[2048] = "";
    GetItemDownloadInfo(ugc, id, &done, &total);
    if (state & STATE_INSTALLED) GetItemInstallInfo(ugc, id, &size, folder, sizeof folder, &stamp);
    json_escape(folder, escaped, sizeof escaped);
    printf("{\"id\":\"%llu\",\"state\":%u,\"downloaded\":%llu,\"total\":%llu,\"folder\":\"%s\"}\n",
           (unsigned long long)id, state, (unsigned long long)done, (unsigned long long)total, escaped);
    fflush(stdout);
    return state;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: wehelper subscribe|unsubscribe|status|list [ids]\n"); return 1; }

    set_env("SteamAppId", "431960");
    set_env("SteamGameId", "431960");
    const char *path = getenv("WE_STEAM_API");
    dll = open_library(path && *path ? path : DEFAULT_DLL);
    if (!dll) { printf("{\"error\":\"Steam API library not found\"}\n"); return 2; }

    char err[1024] = "";
    if (((InitFlat_t)need("SteamAPI_InitFlat"))(err) != 0) {
        char escaped[2048]; json_escape(err, escaped, sizeof escaped);
        printf("{\"error\":\"Steam is not running or not logged in: %s\"}\n", escaped);
        return 4;
    }
    ugc = ((GetUGC_t)need("SteamAPI_SteamUGC_v020"))();
    RunCallbacks = (Void_t)need("SteamAPI_RunCallbacks");
    GetItemState = (ItemState_t)need("SteamAPI_ISteamUGC_GetItemState");
    GetItemDownloadInfo = (DownloadInfo_t)need("SteamAPI_ISteamUGC_GetItemDownloadInfo");
    GetItemInstallInfo = (InstallInfo_t)need("SteamAPI_ISteamUGC_GetItemInstallInfo");
    Void_t Shutdown = (Void_t)need("SteamAPI_Shutdown");

    const char *cmd = argv[1];
    int status = 0;
    if (!strcmp(cmd, "list")) {
        uint32_t n = ((NumSubscribed_t)need("SteamAPI_ISteamUGC_GetNumSubscribedItems"))(ugc, 0);
        uint64_t *ids = calloc(n ? n : 1, sizeof *ids);
        n = ((Subscribed_t)need("SteamAPI_ISteamUGC_GetSubscribedItems"))(ugc, ids, n, 0);
        for (uint32_t i = 0; i < n; i++) report(ids[i]);
        free(ids);
    } else if (!strcmp(cmd, "status")) {
        for (int i = 2; i < argc; i++) report(_strtoui64(argv[i], NULL, 10));
    } else if (!strcmp(cmd, "unsubscribe") && argc > 2) {
        uint64_t id = _strtoui64(argv[2], NULL, 10);
        ((ItemCall_t)need("SteamAPI_ISteamUGC_UnsubscribeItem"))(ugc, id);
        for (int i = 0; i < 100 && (GetItemState(ugc, id) & STATE_SUBSCRIBED); i++) { RunCallbacks(); sleep_ms(100); }
        report(id);
    } else if (!strcmp(cmd, "subscribe") && argc > 2) {
        uint64_t id = _strtoui64(argv[2], NULL, 10);
        ((ItemCall_t)need("SteamAPI_ISteamUGC_SubscribeItem"))(ugc, id);
        DownloadItem_t DownloadItem = (DownloadItem_t)need("SteamAPI_ISteamUGC_DownloadItem");
        int asked = 0;
        /* Up to 2 hours: big video wallpapers can take a while */
        for (int tick = 0; tick < 7200 * 4; tick++) {
            RunCallbacks();
            uint32_t state = GetItemState(ugc, id);
            if ((state & STATE_SUBSCRIBED) && !asked) { DownloadItem(ugc, id, 1); asked = 1; }
            if (tick % 4 == 0) state = report(id);
            if ((state & STATE_INSTALLED) && !(state & (STATE_DOWNLOADING | STATE_DOWNLOAD_PENDING | STATE_NEEDS_UPDATE))) {
                report(id);
                break;
            }
            sleep_ms(250);
        }
    } else {
        fprintf(stderr, "unknown command\n");
        status = 1;
    }
    Shutdown();
    return status;
}
