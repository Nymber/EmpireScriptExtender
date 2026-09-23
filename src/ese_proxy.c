/* ============================================================================
 * ese_proxy.c - Empire Script Extender, proxy-DLL edition.
 *
 * Ships as dinput8.dll in the game root. Windows loads a DLL from the
 * application directory before the system one, so Empire loads US, we forward
 * the five real exports to the system dinput8.dll, and meanwhile we get native
 * code running INSIDE the process before main() - which means our hooks are in
 * place before Lua even initialises. No Cheat Engine, no injection timing race.
 *
 * WHY dinput8: Empire imports it (verified from its import table), it has only
 * five exports, and it is not a protected KnownDLL, so the app-directory
 * override reliably works. tbb/binkw32/mss32 also sit in the game root but have
 * far larger (and C++-mangled) export surfaces.
 *
 * THE POINT OF THIS BUILD: a named pipe that evaluates arbitrary Lua IN THE
 * CAMPAIGN SCRIPTING STATE, on the game's own thread, while the game runs.
 * Iterate without restarting.
 *
 * -------------------------------------------------------------------------
 * EVERYTHING BELOW IS DERIVED FROM VERIFIED RESEARCH - see
 * EmpireScriptExtender\docs\NATIVE_FRAMEWORK_SKETCH.md and the memory notes:
 *   - Empire statically links Lua 5.1; the whole C API sits at known addresses.
 *   - Campaign scripts live in the lua_State that receives the globals
 *     "conditions" and "effect". Its address changes every launch, so we detect
 *     it by watching lua_setfield for a key starting "cond".
 *   - That state's LUA_GLOBALSINDEX is NOT _G. Register through
 *     LUA_GLOBALSINDEX; never verify via _G (a working registration reads back
 *     nil through _G).
 *   - Lua must only be touched on the game's own thread, so the pipe thread
 *     never calls Lua: it queues, and a hook running on the game thread drains.
 *
 * !! UNTESTED: there is no C compiler on the machine this was written on, so
 *    this has never been compiled or run. Treat the first build as a bring-up.
 * ========================================================================= */

#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <setjmp.h>
#include <stdlib.h>   /* strtoul for the memory-read natives */

/* ---------- static (Ghidra) addresses, ImageBase 0x00400000 -------------- */
#define A_lua_getfield      0x00F07420
#define A_lua_setfield      0x00F07E20
#define A_lua_settop        0x00F07F60
#define A_lua_gettop        0x00F07500
#define A_lua_type          0x00F08230
#define A_lua_pushcclosure  0x00F078F0
#define A_lua_pushlstring   0x00F079F0
#define A_lua_tolstring     0x00F080D0
#define A_luaL_loadbuffer   0x00F08B50
#define A_lua_pcall         0x00F07850

#define LUA_GLOBALSINDEX   (-10002)
#define LUA_TFUNCTION        6
#define LUA_TSTRING          4
#define LUA_TTABLE           5

/* both lua_getfield and lua_setfield begin with the same 5 bytes:
 *   83 EC 08   sub esp,8
 *   53         push ebx
 *   56         push esi
 * none of which is position-dependent, so one trampoline shape serves both. */
#define STEAL 5
static const unsigned char kProlog[STEAL] = { 0x83,0xEC,0x08,0x53,0x56 };

typedef void* lua_State;
typedef int (__cdecl *lua_CFunction)(lua_State*);

typedef void (__cdecl *fn_getfield)(lua_State*, int, const char*);
typedef void (__cdecl *fn_setfield)(lua_State*, int, const char*);
typedef void (__cdecl *fn_settop)(lua_State*, int);
typedef int  (__cdecl *fn_gettop)(lua_State*);
typedef int  (__cdecl *fn_type)(lua_State*, int);
typedef void (__cdecl *fn_pushcclosure)(lua_State*, lua_CFunction, int);
typedef void (__cdecl *fn_pushlstring)(lua_State*, const char*, size_t);
typedef const char* (__cdecl *fn_tolstring)(lua_State*, int, size_t*);
typedef int  (__cdecl *fn_loadbuffer)(lua_State*, const char*, size_t, const char*);
typedef int  (__cdecl *fn_pcall)(lua_State*, int, int, int);

static struct {
    fn_getfield     getfield;
    fn_setfield     setfield;
    fn_settop       settop;
    fn_gettop       gettop;
    fn_type         type;
    fn_pushcclosure pushcclosure;
    fn_pushlstring  pushlstring;
    fn_tolstring    tolstring;
    fn_loadbuffer   loadbuffer;
    fn_pcall        pcall;
} L_;

static DWORD      g_delta      = 0;
/* From `raw_resources N` in ese_commodities.txt; 0 = leave the engine alone. */
static int        g_raw_resources = 0;
static lua_State* g_campL      = NULL;   /* the campaign scripting state */
/* Just the campaign UI root. Per-component UI states are transient and holding
 * pointers to them is a use-after-free waiting to happen - see on_setfield. */
static lua_State* g_uiL = NULL;

/* The BATTLE Lua state.
 *
 * Empire has a battle command API of 208 functions - camera, unit orders,
 * formations, abilities - registered by a FOURTH registrar at 0058BD60 that
 * is shaped (desc, name, func) and so was invisible to the campaign dumper.
 * See tools/dump_lua_api.ps1 and docs/battle_lua_api.csv.
 *
 * That registrar only fills internal tables (DAT_0137d028/0137d02c); the
 * functions reach Lua later, when a battle UI state is built. So the state is
 * detected the same way the campaign one is - by watching lua_setfield for a
 * global that exists NOWHERE ELSE. "CameraZoomTo" is that global: unique to
 * battle, and an exact match, not a prefix (see the CampaignUI/CampaignName
 * lesson below).
 *
 * Keyed on L and re-detected, never a one-shot flag: leaving a battle and
 * starting another builds a new state, and a stale pointer is a write into
 * freed memory. */
static lua_State* g_battleL = NULL;
/* CampaignUI-bearing candidates; there are exactly two in practice. */
#define CAND_MAX 4
static lua_State* g_cand[CAND_MAX];
static int        g_cand_n = 0;
static LONG       g_registered = 0;

/* --- per-frame tick state (declared early: the ESE_Tick native is defined
 * well above tick_run(), which lives beside the pump that drives it) */
#define TICK_MAX 2048
static char          g_tick_src[TICK_MAX];
static volatile LONG g_tick_on    = 0;
static DWORD         g_tick_last  = 0;
static DWORD         g_tick_ms    = 16;          /* ~60Hz */
static LONG          g_tick_runs  = 0;
static LONG          g_tick_fault = 0;

/* --- crash-guard state (declared early: both pump() and ESE_Protect use it) */
static volatile LONG  g_guard_armed    = 0;
static jmp_buf        g_guard_jmp;                 /* longjmp target: pump()      */
static jmp_buf        g_prot_jmp;                  /* longjmp target: ESE_Protect */
static volatile LONG  g_guard_use_prot = 0;        /* which target is active      */
static volatile DWORD g_guard_code     = 0;
static PVOID          g_veh            = NULL;

/* Empire runs the UI in SEPARATE lua_States - roughly one per UI component -
 * and the UI API (UIComponent, Component, Address, LuaCall, GlobalExists)
 * exists ONLY there. panelmanager therefore cannot work from the campaign
 * state: SetRootAndEnvironment succeeds (it only stores a handle) but OpenPanel
 * dies on a nil TriggerPanelOpenEvent. Proven by extracting
 * ui\panelmanager.luac from patch2.pack and reading its constants.
 *
 * So to put text on screen we must evaluate in a UI state - specifically the
 * one that receives the CampaignUI global, which is the campaign's UI root and
 * lives as long as the campaign UI. The ~109 per-component states are created
 * and destroyed constantly; storing pointers to those is a use-after-free. */

/* ---- pipe <-> game-thread handoff.
 * The pipe thread NEVER touches Lua. It fills g_req, raises g_pending, and
 * waits; the pump (running on the game thread inside a Lua hook) executes and
 * raises g_done. This is the single most important safety property here:
 * lua_State is not thread-safe and the engine's allocator/GC assume single
 * threaded access. */
#define REQ_MAX 8192
#define RES_MAX 8192
static volatile LONG g_pending = 0;
static volatile LONG g_done    = 0;
static char g_req[REQ_MAX];
static char g_res[RES_MAX];

static void ese_log(const char* fmt, ...) {
    char buf[1024];
    va_list ap; va_start(ap, fmt);
    _vsnprintf(buf, sizeof(buf)-1, fmt, ap); buf[sizeof(buf)-1] = 0;
    va_end(ap);
    FILE* f = fopen("ese_log.txt", "a");
    if (f) { fprintf(f, "%s\n", buf); fclose(f); }
}

/* ======================= trampoline construction ========================= *
 * Built as raw bytes at runtime rather than as a naked function: no inline-asm
 * syntax or symbol-decoration surprises, and total control over the layout.
 *
 *   9C                    pushfd
 *   60                    pushad
 *   8D 44 24 24           lea eax,[esp+0x24]   ; -> original stack frame
 *   50                    push eax             ; handler(stk)
 *   B8 <handler>          mov eax,<handler>
 *   FF D0                 call eax
 *   83 C4 04              add esp,4
 *   61                    popad
 *   9D                    popfd
 *   <STEAL stolen bytes>
 *   68 <ret>              push <hook+STEAL>    ; push/ret avoids computing a
 *   C3                    ret                  ; relative displacement
 *
 * After pushfd(4)+pushad(0x20)=0x24, [esp+0x24] is the original [esp+0], so the
 * handler receives {retaddr, arg1, arg2, arg3, ...}.
 * ========================================================================= */
static void* make_tramp(unsigned char* site, void* handler, int stealLen) {
    unsigned char* t = (unsigned char*)VirtualAlloc(NULL, 64,
                            MEM_COMMIT|MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!t) return NULL;
    int i = 0;
    t[i++] = 0x9C;
    t[i++] = 0x60;
    t[i++] = 0x8D; t[i++] = 0x44; t[i++] = 0x24; t[i++] = 0x24;
    t[i++] = 0x50;
    t[i++] = 0xB8; *(void**)(t+i) = handler;         i += 4;
    t[i++] = 0xFF; t[i++] = 0xD0;
    t[i++] = 0x83; t[i++] = 0xC4; t[i++] = 0x04;
    t[i++] = 0x61;
    t[i++] = 0x9D;
    memcpy(t+i, site, stealLen);                     i += stealLen;
    t[i++] = 0x68; *(void**)(t+i) = (void*)(site + stealLen); i += 4;
    t[i++] = 0xC3;
    return t;
}

/* Patch `site` with E9 rel32 -> tramp. Verifies the prologue first: this guard
 * has already caught two real bugs during development, so it stays. */
static int install_hook_ex(DWORD staticAddr, void* handler, const unsigned char* expect, int stealLen) {
    unsigned char* site = (unsigned char*)(staticAddr + g_delta);
    if (memcmp(site, expect, stealLen) != 0) {
        ese_log("[ese] REFUSING to hook %p: prologue mismatch (%02X %02X %02X %02X %02X)",
                site, site[0], site[1], site[2], site[3], site[4]);
        return 0;
    }
    void* tramp = make_tramp(site, handler, stealLen);
    if (!tramp) { ese_log("[ese] tramp alloc failed"); return 0; }

    DWORD old;
    if (!VirtualProtect(site, stealLen, PAGE_EXECUTE_READWRITE, &old)) return 0;
    site[0] = 0xE9;
    *(DWORD*)(site+1) = (DWORD)tramp - ((DWORD)site + 5);
    VirtualProtect(site, stealLen, old, &old);
    FlushInstructionCache(GetCurrentProcess(), site, stealLen);
    /* NOTE: a >5 byte steal leaves the extra bytes as part of the JMP's tail;
     * they are never executed because the JMP transfers control immediately. */
    ese_log("[ese] hooked %p -> tramp %p (steal %d)", site, tramp, stealLen);
    return 1;
}

static int install_hook(DWORD a, void* h) { return install_hook_ex(a, h, kProlog, STEAL); }

/* ============================ native functions =========================== */

static int __cdecl ese_ping(lua_State* L) {
    L_.pushlstring(L, "pong", 4);
    return 1;
}

/* ESE_Version() -> string */
static int __cdecl ese_version(lua_State* L) {
    const char* v = "ESE proxy 0.1 (Lua 5.1, Empire 1.5.0.0)";
    L_.pushlstring(L, v, strlen(v));
    return 1;
}

/* ESE_Protect(fn) -> true | "NATIVE_FAULT:0x..." | "LUA_ERROR:..."
 *
 * Runs a Lua function with the crash guard ARMED. Without this, only REPL evals
 * are protected - and mod code lives in event handlers, which the engine calls
 * directly. Since the engine's condition functions dereference their arguments
 * without validating (wrong arity or a wrong-scoped context = access violation,
 * NOT a catchable Lua error), unprotected handler code can kill the game.
 *
 * Wrap anything that calls conditions/effect/game_interface:
 *     events.RegionTurnStart[#events.RegionTurnStart+1] = function(context)
 *         ESE_Protect(function() ... end)
 *     end
 *
 * Its own jmp_buf, because a handler can run while a REPL eval is in flight. */
static volatile LONG  g_prot_busy = 0;

static int __cdecl ese_protect(lua_State* L) {
    if (L_.type(L, 1) != LUA_TFUNCTION) {
        const char* m = "ESE_Protect: expected a function";
        L_.pushlstring(L, m, strlen(m));
        return 1;
    }
    /* no nesting: an inner fault would clobber the outer jmp_buf */
    if (InterlockedCompareExchange(&g_prot_busy, 1, 0) != 0) {
        int rc0 = L_.pcall(L, 0, 0, 0);
        const char* m = rc0 ? "LUA_ERROR (nested)" : "true";
        L_.pushlstring(L, m, strlen(m));
        return 1;
    }

    if (setjmp(g_prot_jmp) != 0) {          /* arrived from the VEH */
        char buf[96];
        _snprintf(buf, sizeof(buf)-1, "NATIVE_FAULT:0x%08lX", g_guard_code);
        buf[sizeof(buf)-1] = 0;
        ese_log("[ese] ESE_Protect caught a native fault (0x%08lX)", g_guard_code);
        g_guard_armed = 0;
        InterlockedExchange(&g_prot_busy, 0);
        L_.settop(L, 0);
        L_.pushlstring(L, buf, strlen(buf));
        return 1;
    }

    g_guard_use_prot = 1;
    g_guard_armed    = 1;
    int rc = L_.pcall(L, 0, 0, 0);
    g_guard_armed    = 0;
    g_guard_use_prot = 0;
    InterlockedExchange(&g_prot_busy, 0);

    if (rc != 0) {
        const char* e = L_.tolstring(L, -1, NULL);
        char buf[512];
        _snprintf(buf, sizeof(buf)-1, "LUA_ERROR:%s", e ? e : "?");
        buf[sizeof(buf)-1] = 0;
        L_.settop(L, 0);
        L_.pushlstring(L, buf, strlen(buf));
    } else {
        L_.pushlstring(L, "true", 4);
    }
    return 1;
}

/* ===================== live memory inspection ============================ *
 * Turns ESE into a debugger for the running game: read the engine's own
 * structures (commodity table, trade-manager count fields) while a campaign is
 * loaded, instead of inferring them from a crash dump after the fact.
 *
 * Everything is string in / string out. We only have lua_tolstring and
 * lua_pushlstring bound, not lua_tonumber/pushnumber - and lua_Number is a
 * double, which is awkward to push from here anyway. Lua's tonumber() handles
 * the conversion on the other side.
 *
 * Every read is bounds-checked with VirtualQuery FIRST. A bad address returns
 * "UNREADABLE" rather than faulting: this is meant for poking at unknown
 * structures, so it must never be able to take the game down. */
static int mem_readable(const void* p, size_t n) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!p) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & PAGE_GUARD) return 0;
    DWORD prot = mbi.Protect & 0xFF;
    if (prot == PAGE_NOACCESS || prot == PAGE_EXECUTE) return 0;
    /* the whole span must sit inside this one region */
    size_t avail = (size_t)(((char*)mbi.BaseAddress + mbi.RegionSize) - (char*)p);
    return avail >= n;
}

/* accepts "0x1473A78", "1473A78" (hex assumed), "#12345" for decimal, or
 * "s:00B53A78" for a STATIC (Ghidra) address, which has g_delta added.
 *
 * The static form exists because every address this project researches comes
 * out of Ghidra static, while every address these functions take is live, and
 * nothing about a raw hex string says which it is. Passing a static address
 * where a live one was due is not a harmless mistake: with delta 0x920000 the
 * live image covers roughly 0xD20000-0x1E20000, so a static address often
 * lands INSIDE live code. ESE_Call then happily called into the middle of a
 * function and faulted. Say which kind you mean and the conversion is done
 * here, once. */
static DWORD parse_addr(const char* s) {     /* g_delta is defined above */
    if (!s) return 0;
    while (*s == ' ') s++;
    if ((s[0] == 's' || s[0] == 'S') && s[1] == ':') {
        const char* p = s + 2;
        if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) p += 2;
        return (DWORD)strtoul(p, NULL, 16) + g_delta;
    }
    if (*s == '#') return (DWORD)strtoul(s + 1, NULL, 10);
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) return (DWORD)strtoul(s + 2, NULL, 16);
    return (DWORD)strtoul(s, NULL, 16);
}

static void push_str(lua_State* L, const char* s) { L_.pushlstring(L, s, strlen(s)); }

/* ESE_Delta() -> "0x3F0000"  : add to a Ghidra static address to get a live one */
static int __cdecl ese_delta(lua_State* L) {
    char b[32]; _snprintf(b, sizeof(b)-1, "0x%lX", (unsigned long)g_delta); b[31]=0;
    push_str(L, b); return 1;
}

/* ESE_ReadInt("0x...") -> decimal string, or "UNREADABLE" */
static int __cdecl ese_readint(lua_State* L) {
    DWORD a = parse_addr(L_.tolstring(L, 1, NULL));
    if (!mem_readable((void*)a, 4)) { push_str(L, "UNREADABLE"); return 1; }
    char b[32]; _snprintf(b, sizeof(b)-1, "%ld", (long)*(int*)a); b[31]=0;
    push_str(L, b); return 1;
}

/* ESE_ReadFloat("0x...") -> string */
static int __cdecl ese_readfloat(lua_State* L) {
    DWORD a = parse_addr(L_.tolstring(L, 1, NULL));
    if (!mem_readable((void*)a, 4)) { push_str(L, "UNREADABLE"); return 1; }
    char b[48]; _snprintf(b, sizeof(b)-1, "%f", (double)*(float*)a); b[47]=0;
    push_str(L, b); return 1;
}

/* ESE_WriteFloat("0x...", "1.5") -> "ok" | "UNWRITABLE"
 *
 * The first WRITE primitive in ESE - everything before this was read-only on
 * purpose. Added 2026-09-22 for camera control: CameraZoomTo turned out to set
 * only the camera's ground FOCUS point (its Y argument is ignored - verified
 * live with y=3.7 vs y=302 producing identical views), so a first-person eye
 * position can only come from writing the camera's own state fields.
 *
 * Guarded the same way reads are: VirtualQuery first, and the page must be
 * genuinely writable. That stops a typo'd address from faulting on the game
 * thread - but it CANNOT stop a valid-but-wrong address from corrupting live
 * state, so keep writes to fields whose meaning is established. */
static int __cdecl ese_writefloat(lua_State* L) {
    DWORD a = parse_addr(L_.tolstring(L, 1, NULL));
    const char* v = L_.tolstring(L, 2, NULL);
    if (!v) { push_str(L, "ESE_WriteFloat: (addr, value)"); return 1; }
    MEMORY_BASIC_INFORMATION mbi;
    if (!a || VirtualQuery((void*)a, &mbi, sizeof(mbi)) == 0 ||
        mbi.State != MEM_COMMIT || (mbi.Protect & PAGE_GUARD)) {
        push_str(L, "UNWRITABLE"); return 1;
    }
    DWORD prot = mbi.Protect & 0xFF;
    if (!(prot == PAGE_READWRITE || prot == PAGE_WRITECOPY ||
          prot == PAGE_EXECUTE_READWRITE || prot == PAGE_EXECUTE_WRITECOPY)) {
        push_str(L, "UNWRITABLE"); return 1;
    }
    *(float*)a = (float)atof(v);
    push_str(L, "ok");
    return 1;
}

/* ESE_ReadBytes("0x...", "#16") -> "56 8B F9 ..." (max 64) */
static int __cdecl ese_readbytes(lua_State* L) {
    DWORD a = parse_addr(L_.tolstring(L, 1, NULL));
    int   n = (int)parse_addr(L_.tolstring(L, 2, NULL));
    /* Was capped at 64 purely because the output buffer was 256 chars and each
     * byte costs 3 ("XX "). Dumping a struct therefore had to be chunked, which
     * wasted a lot of round trips. 256 bytes needs 768 chars, so 1024 covers it. */
    if (n <= 0 || n > 256) n = 16;
    if (!mem_readable((void*)a, (size_t)n)) { push_str(L, "UNREADABLE"); return 1; }
    char b[1024]; int w = 0;
    for (int i = 0; i < n && w < (int)sizeof(b)-4; i++)
        w += _snprintf(b+w, sizeof(b)-1-w, "%02X ", ((unsigned char*)a)[i]);
    b[w > 0 ? w-1 : 0] = 0;
    push_str(L, b); return 1;
}

/* ESE_ReadStr("0x...", "#64") -> the C string there, or "UNREADABLE" */
static int __cdecl ese_readstr(lua_State* L) {
    DWORD a = parse_addr(L_.tolstring(L, 1, NULL));
    int   n = (int)parse_addr(L_.tolstring(L, 2, NULL));
    if (n <= 0 || n > 255) n = 64;
    if (!mem_readable((void*)a, 1)) { push_str(L, "UNREADABLE"); return 1; }
    char b[256]; int i = 0;
    for (; i < n; i++) {
        if (!mem_readable((void*)(a+i), 1)) break;
        char c = ((char*)a)[i];
        if (c == 0) break;
        b[i] = (c >= 32 && c < 127) ? c : '.';
    }
    b[i] = 0;
    push_str(L, b); return 1;
}

/* ESE_Log("text") -> writes to ese_log.txt immediately.
 *
 * The point is CRASH SURVIVAL: ese_log opens, writes and closes per line, so
 * anything logged is on disk before the next statement runs. That makes it the
 * only reliable way to get data out of a session that is about to die - the
 * pipe cannot help, because you cannot hand-time a request into the window
 * between campaign-script init and the fault. */
static int __cdecl ese_luaLog(lua_State* L) {
    const char* s = L_.tolstring(L, 1, NULL);
    ese_log("[lua] %s", s ? s : "(nil)");
    push_str(L, "ok");
    return 1;
}

/* ===================== ESE_Say: campaign -> UI bridge =====================
 * Lets the MOD talk to the player on its own, instead of only when a human
 * runs ese.ps1 -Say.
 *
 * The problem it solves: mod code runs in the CAMPAIGN lua_State, but
 * panelmanager (the only way to put text on screen) exists solely in the UI
 * state - they are separate lua_States and neither can call the other.
 *
 * Same queue-and-pump shape as the pipe: ESE_Say() stores the text, and the
 * next time a Lua hook fires we evaluate the panel call IN THE UI STATE.
 * Nothing crosses a thread boundary (both states live on the game thread), and
 * the drain runs the same guarded path as any other eval.
 *
 *     Lua (campaign):  ESE_Say("Embargo: trade down 12% this turn")
 */
#define SAY_MAX 2048
static char          g_say[SAY_MAX];
static volatile LONG g_say_pending = 0;
static int           g_say_retry   = 0;

static int __cdecl ese_say(lua_State* L) {
    const char* s = L_.tolstring(L, 1, NULL);
    if (!s) { push_str(L, "ESE_Say: expected a string"); return 1; }
    if (g_say_pending) { push_str(L, "busy"); return 1; }   /* one at a time */
    _snprintf(g_say, SAY_MAX - 1, "%s", s);
    g_say[SAY_MAX - 1] = 0;
    g_say_pending = 1;
    push_str(L, "queued");
    return 1;
}

/* Drained from the hot hook, but only once a UI state is known. Escapes the
 * text for a Lua single-quoted literal so quotes/newlines in a report cannot
 * break the chunk. */
static void say_pump(void) {
    /* Re-entrancy guard - NOT optional. This runs inside the lua_getfield hook
     * and then calls Lua itself, which calls lua_getfield, which re-enters
     * here. Without the guard a nested loadbuffer corrupts the outer one's
     * stack and every attempt fails to compile. pump() has the same guard for
     * the same reason; omitting it here cost a test cycle. */
    static volatile LONG busy = 0;
    if (!g_say_pending || !g_uiL) return;
    if (InterlockedCompareExchange(&busy, 1, 0) != 0) return;

    /* clear BEFORE running: a failure must not retry on every hook call */
    g_say_pending = 0;

    char esc[SAY_MAX * 2]; int w = 0;
    for (int i = 0; g_say[i] && w < (int)sizeof(esc) - 8; i++) {
        char c = g_say[i];
        if (c == '\\' || c == '\'') { esc[w++] = '\\'; esc[w++] = c; }
        else if (c == '\n') { esc[w++] = '\\'; esc[w++] = 'n'; }
        else if (c == '\r') { }
        else esc[w++] = c;
    }
    esc[w] = 0;

    /* DEFER if the game already has a panel up. Empire's own turn-start
     * messages (War Declared, etc.) use the SAME dialogue_box panel, so
     * opening ours on top either loses our text or interrupts theirs. Ask
     * panelmanager first and retry later if the screen is busy. */
    char chunk[SAY_MAX * 2 + 512];
    _snprintf(chunk, sizeof(chunk) - 1,
        "local ok,pm = pcall(function() return require('Utilities').Require('panelmanager') end) "
        "if not (ok and type(pm)=='table') then return 'nopm' end "
        "local busy = false "
        "for _,p in ipairs({'dialogue_box','events_windowed','message_scroll'}) do "
        "  local o,r = pcall(pm.IsPanelOpen, p) if o and r then busy = true end end "
        "if busy then return 'busy' end "
        "pcall(pm.OpenPanel,'dialogue_box',false,'Initialise','%s') return 'shown'",
        esc);
    chunk[sizeof(chunk) - 1] = 0;

    lua_State* L = g_uiL;
    int top = L_.gettop(L);
    if (L_.loadbuffer(L, chunk, strlen(chunk), "=ese_say") == 0) {
        if (L_.pcall(L, 0, 1, 0) == 0) {
            const char* r = L_.tolstring(L, -1, NULL);
            if (r && r[0]=='b') {              /* "busy" - screen occupied */
                if (++g_say_retry < 600) g_say_pending = 1;   /* try again shortly */
                else ese_log("[ese] ESE_Say gave up after %d retries", g_say_retry);
            } else {
                g_say_retry = 0;
            }
        } else {
            const char* e = L_.tolstring(L, -1, NULL);
            ese_log("[ese] ESE_Say failed: %s", e ? e : "?");
        }
    } else {
        /* log the ACTUAL compiler error and the chunk - "compile failed" with
         * no detail is the same fail-quietly trap this project keeps hitting */
        const char* e = L_.tolstring(L, -1, NULL);
        ese_log("[ese] ESE_Say compile failed: %s", e ? e : "?");
        ese_log("[ese]   chunk was: %.300s", chunk);
    }
    L_.settop(L, top);
    InterlockedExchange(&busy, 0);
}

/* ===================== calling the engine directly ======================= *
 * ESE_Call("<conv>", "0xADDR" [, arg...]) -> "0x<eax>" | "NATIVE_FAULT:0x.."
 *
 * WHY THIS EXISTS
 *   Empire exposes NO command layer to script. The entire mutator surface is
 *   the twelve `effect` members (traits, ancillaries, advice, treasury) -
 *   enumerated statically from the registrar at 00D1FB60, so that is not a
 *   guess. Nothing in script builds, moves, trades or withholds.
 *
 *   The engine obviously does all those things; it just never exposed them.
 *   So the only route to real commands is to call the engine's own functions,
 *   and this is the primitive for that: address in, return value out.
 *
 * CONVENTION MUST BE EXACT, AND SO MUST ARITY.
 *   cdecl is caller-cleaned, so passing too many arguments is harmless. The
 *   others are CALLEE-cleaned: hand a stdcall/thiscall/fastcall function the
 *   wrong number of arguments and it unwinds the wrong amount of stack, and
 *   the caller returns into rubbish. That is not a crash at the call site -
 *   it is a crash somewhere else entirely, minutes later. Hence a separate
 *   typedef per (convention, arity) rather than one variadic cast.
 *
 *   Empire's own code is mostly __fastcall (ECX, EDX, then stack) and cdecl;
 *   C++ methods are __thiscall with `this` in ECX, which here is simply the
 *   first argument.
 *
 * SAFETY
 *   The address is checked executable before the call, and the whole thing
 *   runs under the same VEH crash guard as ESE_Protect - so a bad call
 *   reports NATIVE_FAULT instead of taking the process with it. That guard is
 *   a debugging aid, NOT a licence: a caught fault has already corrupted
 *   whatever the callee was halfway through, and the game may still die
 *   shortly afterwards. Treat every fault as fatal and restart. */
static int mem_executable(const void* p) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!p) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & PAGE_GUARD) return 0;
    DWORD prot = mbi.Protect & 0xFF;
    return prot == PAGE_EXECUTE || prot == PAGE_EXECUTE_READ ||
           prot == PAGE_EXECUTE_READWRITE || prot == PAGE_EXECUTE_WRITECOPY;
}

typedef DWORD (__cdecl    *fc0)(void);
typedef DWORD (__cdecl    *fc1)(DWORD);
typedef DWORD (__cdecl    *fc2)(DWORD,DWORD);
typedef DWORD (__cdecl    *fc3)(DWORD,DWORD,DWORD);
typedef DWORD (__cdecl    *fc4)(DWORD,DWORD,DWORD,DWORD);
typedef DWORD (__cdecl    *fc5)(DWORD,DWORD,DWORD,DWORD,DWORD);
typedef DWORD (__cdecl    *fc6)(DWORD,DWORD,DWORD,DWORD,DWORD,DWORD);
typedef DWORD (__stdcall  *fs0)(void);
typedef DWORD (__stdcall  *fs1)(DWORD);
typedef DWORD (__stdcall  *fs2)(DWORD,DWORD);
typedef DWORD (__stdcall  *fs3)(DWORD,DWORD,DWORD);
typedef DWORD (__stdcall  *fs4)(DWORD,DWORD,DWORD,DWORD);
typedef DWORD (__stdcall  *fs5)(DWORD,DWORD,DWORD,DWORD,DWORD);
typedef DWORD (__stdcall  *fs6)(DWORD,DWORD,DWORD,DWORD,DWORD,DWORD);
typedef DWORD (__fastcall *ff1)(DWORD);
typedef DWORD (__fastcall *ff2)(DWORD,DWORD);
typedef DWORD (__fastcall *ff3)(DWORD,DWORD,DWORD);
typedef DWORD (__fastcall *ff4)(DWORD,DWORD,DWORD,DWORD);
typedef DWORD (__fastcall *ff5)(DWORD,DWORD,DWORD,DWORD,DWORD);
typedef DWORD (__fastcall *ff6)(DWORD,DWORD,DWORD,DWORD,DWORD,DWORD);

static DWORD do_native_call(const char* conv, DWORD a, DWORD* v, int n) {
    int cd = (strcmp(conv, "cdecl")    == 0);
    int st = (strcmp(conv, "stdcall")  == 0);
    /* thiscall with an explicit first argument IS fastcall's ECX slot; the
     * difference (EDX) only matters from the second argument on, so thiscall
     * is expressed as fastcall and the caller passes `this` first. */
    if (cd) {
        switch (n) {
            case 0: return ((fc0)a)();
            case 1: return ((fc1)a)(v[0]);
            case 2: return ((fc2)a)(v[0],v[1]);
            case 3: return ((fc3)a)(v[0],v[1],v[2]);
            case 4: return ((fc4)a)(v[0],v[1],v[2],v[3]);
            case 5: return ((fc5)a)(v[0],v[1],v[2],v[3],v[4]);
            default:return ((fc6)a)(v[0],v[1],v[2],v[3],v[4],v[5]);
        }
    }
    if (st) {
        switch (n) {
            case 0: return ((fs0)a)();
            case 1: return ((fs1)a)(v[0]);
            case 2: return ((fs2)a)(v[0],v[1]);
            case 3: return ((fs3)a)(v[0],v[1],v[2]);
            case 4: return ((fs4)a)(v[0],v[1],v[2],v[3]);
            case 5: return ((fs5)a)(v[0],v[1],v[2],v[3],v[4]);
            default:return ((fs6)a)(v[0],v[1],v[2],v[3],v[4],v[5]);
        }
    }
    switch (n) {                                   /* fastcall / thiscall */
        case 0: return ((fc0)a)();                 /* no args: identical   */
        case 1: return ((ff1)a)(v[0]);
        case 2: return ((ff2)a)(v[0],v[1]);
        case 3: return ((ff3)a)(v[0],v[1],v[2]);
        case 4: return ((ff4)a)(v[0],v[1],v[2],v[3]);
        case 5: return ((ff5)a)(v[0],v[1],v[2],v[3],v[4]);
        default:return ((ff6)a)(v[0],v[1],v[2],v[3],v[4],v[5]);
    }
}

/* ESE_WrapFn("0x...") -> a real callable Lua value wrapping that address as
 * a lua_CFunction(lua_State*).
 *
 * WHY THIS EXISTS: the 208 battle-API functions (CameraZoomTo etc.) are
 * NOT reachable as plain Lua globals from an injected eval - confirmed
 * 2026-09-22, `pcall(CameraZoomTo)` and even `pcall(ElapsedBattleTime)`
 * both return "attempt to call a nil value", and _G has no __index
 * metatable either. The game's own battle script FILES get these names
 * bound some other way (a load-time step specific to its script loader,
 * not a mechanism a bare loadstring'd chunk participates in) - see the
 * empire-battle-control skill. Their addresses are known precisely from
 * docs/battle_lua_api.csv (dump_lua_api.ps1), so the fix is to construct
 * the Lua closure ourselves with pushcclosure - the exact same call
 * register_natives already makes for our own natives - rather than reverse
 * engineer the game's private name-resolution path.
 *
 * Combine with ESE_Protect so a wrong-arity guess is a caught error, not a
 * crash (the lesson from the vtable-slot crash earlier the same day):
 *   local fn = ESE_WrapFn("005F5B30")
 *   return ESE_Protect(function() return fn(x, y, z, facing) end)
 * Lua's own VM pushes the numeric args here - no lua_pushnumber binding
 * needed, unlike a native-side call. */
static int __cdecl ese_wrapfn(lua_State* L) {
    DWORD a = parse_addr(L_.tolstring(L, 1, NULL));
    if (!mem_executable((void*)a)) { push_str(L, "NOT_EXECUTABLE"); return 1; }
    L_.pushcclosure(L, (lua_CFunction)a, 0);
    return 1;
}

/* ===================== generic memory + tracing primitives ================
 * ESE had only ESE_WriteFloat, so patching code (NOPs) or poking an int meant
 * dropping out to Cheat Engine. These close that gap, and ESE_Trace finally
 * exposes the trampoline machinery above - which is the whole point of it.
 * ========================================================================= */

static int mem_write(void* dst, const void* src, size_t n) {
    DWORD old;
    if (!VirtualProtect(dst, n, PAGE_EXECUTE_READWRITE, &old)) return 0;
    memcpy(dst, src, n);
    VirtualProtect(dst, n, old, &old);
    FlushInstructionCache(GetCurrentProcess(), dst, n);
    return 1;
}

static int hexnib(char c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;        /* 0-9 */
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;   /* a-f */
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;   /* A-F */
    return -1;
}

/* ESE_WriteInt(addr, value) - value decimal, or 0x-prefixed hex */
static int __cdecl ese_writeint(lua_State* L) {
    const char* a = L_.tolstring(L, 1, NULL);
    const char* v = L_.tolstring(L, 2, NULL);
    if (!a || !v) { push_str(L, "ESE_WriteInt(addr, value)"); return 1; }
    DWORD addr = parse_addr(a);
    int base10 = 10;
    if (v[0] == 0x30 && (v[1] == 0x78 || v[1] == 0x58)) base10 = 16;
    long val = strtol(v, NULL, base10);
    if (!mem_write((void*)addr, &val, 4)) { push_str(L, "PROTECT_FAILED"); return 1; }
    push_str(L, "ok");
    return 1;
}

/* ESE_WriteBytes(addr, "90 90 90") - how an instruction gets NOPed in place */
static int __cdecl ese_writebytes(lua_State* L) {
    const char* a = L_.tolstring(L, 1, NULL);
    const char* h = L_.tolstring(L, 2, NULL);
    if (!a || !h) { push_str(L, "ESE_WriteBytes(addr, hexbytes)"); return 1; }
    unsigned char buf[256];
    int n = 0;
    const char* q = h;
    while (*q && n < (int)sizeof(buf)) {
        if (*q == 0x20 || *q == 0x2C) { q++; continue; }   /* space, comma */
        int hi = hexnib(*q);
        if (hi < 0) break;
        q++;
        int lo = hexnib(*q);
        if (lo < 0) break;
        q++;
        buf[n++] = (unsigned char)((hi << 4) | lo);
    }
    if (n == 0) { push_str(L, "no bytes parsed"); return 1; }
    DWORD addr = parse_addr(a);
    if (!mem_write((void*)addr, buf, (size_t)n)) { push_str(L, "PROTECT_FAILED"); return 1; }
    char b[64];
    _snprintf(b, sizeof(b) - 1, "wrote %d bytes", n);
    b[63] = 0;
    push_str(L, b);
    return 1;
}

/* ESE_Scan("8B 41 ?? 85 C0") - byte-pattern search of Empire's image.
 * Returns up to 8 STATIC addresses so hits paste straight into Ghidra.
 * Wildcards are ??. This is what lets a found address survive a patch or a
 * different build instead of being hardcoded forever. */
static int __cdecl ese_scan(lua_State* L) {
    const char* pat = L_.tolstring(L, 1, NULL);
    if (!pat) { push_str(L, "ESE_Scan(pattern)"); return 1; }
    unsigned char want[64];
    char mask[64];
    int n = 0;
    const char* q = pat;
    while (*q && n < 64) {
        if (*q == 0x20 || *q == 0x2C) { q++; continue; }
        if (*q == 0x3F) {                                  /* ? wildcard */
            want[n] = 0; mask[n] = 0; n++;
            q += (q[1] == 0x3F) ? 2 : 1;
            continue;
        }
        int hi = hexnib(*q);
        if (hi < 0) break;
        q++;
        int lo = hexnib(*q);
        if (lo < 0) break;
        q++;
        want[n] = (unsigned char)((hi << 4) | lo);
        mask[n] = 1;
        n++;
    }
    if (n == 0) { push_str(L, "empty pattern"); return 1; }

    unsigned char* base = (unsigned char*)(0x00400000 + g_delta);
    unsigned char* end = base + 0x1000000;
    char out[512];
    int used = 0, hits = 0;
    out[0] = 0;
    for (unsigned char* p = base; p + n < end && hits < 8; p++) {
        if (((DWORD)p & 0xFFF) == 0) {
            MEMORY_BASIC_INFORMATION mbi;
            if (!VirtualQuery(p, &mbi, sizeof(mbi)) || mbi.State != MEM_COMMIT) { p += 0xFFF; continue; }
        }
        int ok = 1;
        for (int k = 0; k < n; k++) { if (mask[k] && p[k] != want[k]) { ok = 0; break; } }
        if (ok) {
            int w = _snprintf(out + used, sizeof(out) - used - 1, "%s%08lX",
                              hits ? " " : "", (unsigned long)((DWORD)p - g_delta));
            if (w > 0) used += w;
            hits++;
        }
    }
    if (!hits) push_str(L, "no match"); else push_str(L, out);
    return 1;
}

/* ---- generic call tracer -------------------------------------------------
 * ESE_Trace("s:5F6E40", "on", "4")   arm, capture 4 stack args
 * ESE_Trace("s:5F6E40", "off")       restore the original bytes
 * ESE_Trace("s:5F6E40")              report hit count + last args
 *
 * Each slot gets its OWN trampoline carrying its slot id, so one handler serves
 * them all. Steal is 5 bytes; relative branches inside that range are REFUSED,
 * because relocating them needs a length disassembler and a displacement fixup
 * and neither exists here. Declining to hook is far better than silently
 * corrupting a prologue. */
#define TRACE_MAX 8
#define TRACE_LOG 64          /* ring depth per slot; power of two */
typedef struct {
    DWORD site;
    DWORD statica;
    void* tramp;
    int steal;
    unsigned char orig[16];
    volatile LONG hits;
    DWORD args[6];
    int nargs;
    int used;
    /* Ring of recent calls. Keeping only the LAST args is useless for the job
     * these tracers exist for - mapping an opcode table needs the SEQUENCE of
     * calls, not a snapshot. logw only ever increases; logr is the drain
     * cursor, so ESE_TraceLog returns each call exactly once. */
    DWORD log[TRACE_LOG][4];
    /* Register snapshot from the same call as log[].  Stack-only tracing
     * cannot identify __thiscall objects because `this` arrives in ECX.  Keep
     * the original four leading stack columns in ESE_TraceLog so existing
     * analysis scripts remain compatible, then append these registers. */
    DWORD reglog[TRACE_LOG][4];       /* ECX, EAX, EDX, EBX */
    DWORD lastreg[4];
    volatile LONG logw;
    LONG logr;
    /* vtable-trace variant: no bytes are stolen, so there is no
     * instruction-boundary hazard. Shares this slot array so that
     * ESE_Trace(addr) reporting and ESE_TraceLog(addr) draining work for both,
     * keyed by the ORIGINAL function address. */
    int is_vt;
    void** vt;
    int vindex;
    void* orig_fn;
    void* thunk_vt;
} trace_slot;
static trace_slot g_trace[TRACE_MAX];

static void __cdecl trace_handler(DWORD* stk, int slot, DWORD* saved) {
    if (slot < 0 || slot >= TRACE_MAX) return;
    trace_slot* t = &g_trace[slot];
    InterlockedIncrement(&t->hits);
    int i;
    for (i = 0; i < t->nargs && i < 6; i++) t->args[i] = stk[1 + i];
    /* pushad's image at its final ESP is EDI,ESI,EBP,pre-pushad ESP,
     * EBX,EDX,ECX,EAX.  The trampoline passes that base before adding its own
     * handler arguments. */
    t->lastreg[0] = saved[6];
    t->lastreg[1] = saved[7];
    t->lastreg[2] = saved[5];
    t->lastreg[3] = saved[4];
    /* This runs on the GAME thread inside the hooked function, so it must stay
     * trivial: no allocation, no locks, no Lua. Just stamp the ring. */
    LONG w = InterlockedIncrement(&t->logw) - 1;
    DWORD* rec = t->log[w & (TRACE_LOG - 1)];
    DWORD* rr = t->reglog[w & (TRACE_LOG - 1)];
    for (i = 0; i < 4; i++) rec[i] = (i < t->nargs) ? stk[1 + i] : 0;
    for (i = 0; i < 4; i++) rr[i] = t->lastreg[i];
}

static void* make_trace_tramp(unsigned char* site, int slot, int stealLen) {
    unsigned char* t = (unsigned char*)VirtualAlloc(NULL, 96,
                           MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!t) return NULL;
    int i = 0;
    t[i++] = 0x9C;                                                  /* pushfd */
    t[i++] = 0x60;                                                  /* pushad */
    t[i++] = 0x8B; t[i++] = 0xD4;                                   /* mov edx,esp (saved regs) */
    t[i++] = 0x8D; t[i++] = 0x44; t[i++] = 0x24; t[i++] = 0x24;     /* lea eax,[esp+0x24] */
    t[i++] = 0x52;                                                  /* push edx   (arg3) */
    t[i++] = 0x68; *(int*)(t + i) = slot; i += 4;                   /* push slot  (arg2) */
    t[i++] = 0x50;                                                  /* push eax   (arg1) */
    t[i++] = 0xB8; *(void**)(t + i) = (void*)trace_handler; i += 4;
    t[i++] = 0xFF; t[i++] = 0xD0;                                   /* call eax */
    t[i++] = 0x83; t[i++] = 0xC4; t[i++] = 0x0C;                    /* add esp,12 */
    t[i++] = 0x61;                                                  /* popad */
    t[i++] = 0x9D;                                                  /* popfd */
    memcpy(t + i, site, stealLen); i += stealLen;
    t[i++] = 0x68; *(void**)(t + i) = (void*)(site + stealLen); i += 4;
    t[i++] = 0xC3;
    return t;
}

static int __cdecl ese_trace(lua_State* L) {
    const char* a = L_.tolstring(L, 1, NULL);
    const char* cmd = L_.tolstring(L, 2, NULL);
    const char* ns = L_.tolstring(L, 3, NULL);
    const char* ss = L_.tolstring(L, 4, NULL);
    if (!a) { push_str(L, "ESE_Trace(addr [,on|off] [,nargs] [,steal])"); return 1; }
    DWORD live = parse_addr(a);
    DWORD stat = live - g_delta;

    int slot = -1, freeslot = -1, i;
    for (i = 0; i < TRACE_MAX; i++) {
        if (g_trace[i].used && g_trace[i].site == live) { slot = i; break; }
        if (!g_trace[i].used && freeslot < 0) freeslot = i;
    }

    if (!cmd || !cmd[0]) {
        if (slot < 0) { push_str(L, "not traced"); return 1; }
        trace_slot* t = &g_trace[slot];
        char b[256];
        _snprintf(b, sizeof(b) - 1, "%08lX hits=%ld args=%08lX %08lX %08lX %08lX ecx=%08lX eax=%08lX edx=%08lX ebx=%08lX",
                  (unsigned long)t->statica, (long)t->hits,
                  (unsigned long)t->args[0], (unsigned long)t->args[1],
                  (unsigned long)t->args[2], (unsigned long)t->args[3],
                  (unsigned long)t->lastreg[0], (unsigned long)t->lastreg[1],
                  (unsigned long)t->lastreg[2], (unsigned long)t->lastreg[3]);
        b[255] = 0;
        push_str(L, b);
        return 1;
    }

    if (strcmp(cmd, "off") == 0) {
        if (slot < 0) { push_str(L, "not traced"); return 1; }
        trace_slot* t = &g_trace[slot];
        /* A vtable trace is keyed by the ORIGINAL function address, so it is
         * findable from here - but restoring it means putting the pointer back,
         * not writing bytes. Taking the byte path would leave the thunk live
         * and pointing at a slot that may later be reused by another trace. */
        if (t->is_vt) {
            DWORD old;
            if (VirtualProtect(&t->vt[t->vindex], 4, PAGE_EXECUTE_READWRITE, &old)) {
                t->vt[t->vindex] = t->orig_fn;
                VirtualProtect(&t->vt[t->vindex], 4, old, &old);
            }
            t->used = 0;
            ese_log("[trace] vt[%d] restored after %ld hits", t->vindex, (long)t->hits);
            push_str(L, "removed (vtable)");
            return 1;
        }
        mem_write((void*)t->site, t->orig, (size_t)t->steal);
        t->used = 0;
        ese_log("[trace] %08lX removed after %ld hits", (unsigned long)t->statica, (long)t->hits);
        push_str(L, "removed");
        return 1;
    }

    if (strcmp(cmd, "on") != 0) { push_str(L, "cmd must be on|off"); return 1; }
    if (slot >= 0) { push_str(L, "already traced"); return 1; }
    if (freeslot < 0) { push_str(L, "no free trace slots"); return 1; }
    if (!mem_executable((void*)live)) { push_str(L, "NOT_EXECUTABLE"); return 1; }

    /* Steal MUST end on an instruction boundary. 5 is only a default: every
     * real target checked so far would be SPLIT by 5 - 5B3E00 MOVZX is 7 bytes,
     * 5D0560 SUB ESP,imm32 is 6, 5D02F0 is 3+1+4, 718930 SUB is 6 - and the
     * relative-branch guard below cannot detect a mid-instruction cut. Read the
     * boundary off a disassembly and pass it explicitly. */
    int steal = ss ? (int)strtol(ss, NULL, 10) : 5;
    if (steal < 5) steal = 5;
    if (steal > 15) steal = 15;
    int nargs = ns ? (int)strtol(ns, NULL, 10) : 4;
    if (nargs < 0) nargs = 0;
    if (nargs > 6) nargs = 6;

    unsigned char* site = (unsigned char*)live;
    for (i = 0; i < steal; i++) {
        unsigned char b0 = site[i];
        if (b0 == 0xE8 || b0 == 0xE9 || b0 == 0xEB ||
            (b0 >= 0x70 && b0 <= 0x7F) ||
            (b0 == 0x0F && i + 1 < steal && (site[i + 1] & 0xF0) == 0x80)) {
            char b[128];
            _snprintf(b, sizeof(b) - 1,
                      "REFUSED: relative branch %02X at +%d of the stolen %d bytes", b0, i, steal);
            b[127] = 0;
            push_str(L, b);
            return 1;
        }
    }

    trace_slot* t = &g_trace[freeslot];
    memset(t, 0, sizeof(*t));
    t->site = live; t->statica = stat; t->steal = steal; t->nargs = nargs;
    memcpy(t->orig, site, (size_t)steal);
    t->tramp = make_trace_tramp(site, freeslot, steal);
    if (!t->tramp) { push_str(L, "tramp alloc failed"); return 1; }

    unsigned char jmp[5];
    jmp[0] = 0xE9;
    *(DWORD*)(jmp + 1) = (DWORD)t->tramp - (live + 5);
    if (!mem_write(site, jmp, 5)) { push_str(L, "PROTECT_FAILED"); return 1; }
    t->used = 1;
    ese_log("[trace] %08lX armed -> tramp %p (slot %d, %d args)",
            (unsigned long)stat, t->tramp, freeslot, nargs);
    char b[128];
    _snprintf(b, sizeof(b) - 1, "tracing %08lX (slot %d, %d args)",
              (unsigned long)stat, freeslot, nargs);
    b[127] = 0;
    push_str(L, b);
    return 1;
}

/* ESE_Tick("on", "<lua source>") | ("off") | ("ms","33") | ("status")
 *
 * Arms the per-frame tick (see tick_run above). The snippet runs in the
 * BATTLE state on the game thread, crash-guarded, ~60Hz by default.
 * Keep it SHORT - it is recompiled each run, and it executes inside a hook
 * the whole game depends on. */
static int __cdecl ese_tick(lua_State* L) {
    const char* cmd = L_.tolstring(L, 1, NULL);
    if (!cmd) { push_str(L, "ESE_Tick: (on,src)|(off)|(ms,n)|(status)"); return 1; }

    if (strcmp(cmd, "on") == 0) {
        const char* src = L_.tolstring(L, 2, NULL);
        if (!src || !src[0]) { push_str(L, "ESE_Tick: need source"); return 1; }
        size_t n = strlen(src);
        if (n >= TICK_MAX) { push_str(L, "ESE_Tick: source too long"); return 1; }
        memcpy(g_tick_src, src, n);
        g_tick_src[n] = 0;
        g_tick_last  = 0;
        g_tick_runs  = 0;
        g_tick_fault = 0;
        g_tick_on    = 1;
        ese_log("[tick] armed (%u bytes, every %lums)", (unsigned)n, (unsigned long)g_tick_ms);
        push_str(L, "tick ARMED");
        return 1;
    }
    if (strcmp(cmd, "off") == 0) {
        g_tick_on = 0;
        push_str(L, "tick off");
        return 1;
    }
    if (strcmp(cmd, "ms") == 0) {
        const char* v = L_.tolstring(L, 2, NULL);
        DWORD ms = v ? (DWORD)strtoul(v, NULL, 10) : 16;
        if (ms < 1)    ms = 1;
        if (ms > 5000) ms = 5000;
        g_tick_ms = ms;
        push_str(L, "ok");
        return 1;
    }
    char b[160];
    _snprintf(b, sizeof(b)-1, "tick on=%ld runs=%ld faults=%ld ms=%lu battleL=%s",
              (long)g_tick_on, (long)g_tick_runs, (long)g_tick_fault,
              (unsigned long)g_tick_ms, g_battleL ? "yes" : "NO");
    b[sizeof(b)-1] = 0;
    push_str(L, b);
    return 1;
}

#define ESE_CALL_MAXARG 6

static int __cdecl ese_call(lua_State* L) {
    const char* conv = L_.tolstring(L, 1, NULL);
    const char* addr = L_.tolstring(L, 2, NULL);
    if (!conv || !addr) { push_str(L, "ESE_Call: (convention, address, args...)"); return 1; }
    if (strcmp(conv,"cdecl") && strcmp(conv,"stdcall") &&
        strcmp(conv,"fastcall") && strcmp(conv,"thiscall")) {
        push_str(L, "ESE_Call: convention must be cdecl|stdcall|fastcall|thiscall");
        return 1;
    }
    DWORD a = parse_addr(addr);
    if (!mem_executable((void*)a)) { push_str(L, "NOT_EXECUTABLE"); return 1; }

    DWORD v[ESE_CALL_MAXARG]; int n = 0;
    int top = L_.gettop(L);
    for (int i = 3; i <= top && n < ESE_CALL_MAXARG; i++) {
        v[n++] = parse_addr(L_.tolstring(L, i, NULL));
    }
    if (top - 2 > ESE_CALL_MAXARG) { push_str(L, "ESE_Call: too many arguments (max 6)"); return 1; }

    /* Same guard as ESE_Protect, and the same no-nesting rule: an inner fault
     * would clobber the outer jmp_buf. */
    if (InterlockedCompareExchange(&g_prot_busy, 1, 0) != 0) {
        push_str(L, "ESE_Call: guard busy (already inside ESE_Protect/ESE_Call)");
        return 1;
    }
    if (setjmp(g_prot_jmp) != 0) {
        char buf[96];
        _snprintf(buf, sizeof(buf)-1, "NATIVE_FAULT:0x%08lX", g_guard_code);
        buf[sizeof(buf)-1] = 0;
        ese_log("[ese] ESE_Call(%s, 0x%08lX, %d arg) FAULTED 0x%08lX",
                conv, (unsigned long)a, n, g_guard_code);
        g_guard_armed = 0;
        InterlockedExchange(&g_prot_busy, 0);
        L_.settop(L, 0);
        push_str(L, buf);
        return 1;
    }

    ese_log("[ese] ESE_Call(%s, 0x%08lX, %d arg)", conv, (unsigned long)a, n);
    g_guard_use_prot = 1;
    g_guard_armed    = 1;
    DWORD r = do_native_call(conv, a, v, n);
    g_guard_armed    = 0;
    g_guard_use_prot = 0;
    InterlockedExchange(&g_prot_busy, 0);

    char b[32]; _snprintf(b, sizeof(b)-1, "0x%lX", (unsigned long)r); b[31] = 0;
    push_str(L, b);
    return 1;
}

/* Forward declaration: the impact probe is defined beside the hook it arms,
 * far below this table, but the table has to see it now. */
static int __cdecl ese_impact(lua_State* L);
static int __cdecl ese_fps(lua_State* L);
static int __cdecl ese_mouse(lua_State* L);
static int __cdecl ese_input(lua_State* L);
static int __cdecl ese_view(lua_State* L);
static int __cdecl ese_caps(lua_State* L);
static int __cdecl ese_writeint(lua_State* L);
static int __cdecl ese_writebytes(lua_State* L);
static int __cdecl ese_scan(lua_State* L);
static int __cdecl ese_trace(lua_State* L);
static int __cdecl ese_tracelog(lua_State* L);
static int __cdecl ese_tracevt(lua_State* L);

static const struct { const char* name; lua_CFunction fn; } kNatives[] = {
    { "ESE_Call",      ese_call      },
    /* Defined much further down, beside the impact hook it controls - the
     * table has to see a declaration first. */
    { "ESE_Impact",    ese_impact    },
    { "ESE_FPS",       ese_fps       },
    { "ESE_Mouse",     ese_mouse     },
    { "ESE_Input",     ese_input     },
    { "ESE_View",      ese_view      },
    { "ESE_Caps",      ese_caps      },
    { "ESE_WriteInt",   ese_writeint   },
    { "ESE_WriteBytes", ese_writebytes },
    { "ESE_Scan",       ese_scan       },
    { "ESE_Trace",      ese_trace      },
    { "ESE_TraceLog",   ese_tracelog   },
    { "ESE_TraceVT",    ese_tracevt    },
    { "ESE_Say",       ese_say       },
    { "ESE_Log",       ese_luaLog    },
    { "ESE_Protect",   ese_protect   },
    { "ESE_Delta",     ese_delta     },
    { "ESE_ReadInt",   ese_readint   },
    { "ESE_ReadFloat", ese_readfloat },
    { "ESE_WriteFloat", ese_writefloat },
    { "ESE_ReadBytes", ese_readbytes },
    { "ESE_ReadStr",   ese_readstr   },
    { "ESE_Ping",    ese_ping    },
    { "ESE_Version", ese_version },
    { "ESE_WrapFn",  ese_wrapfn  },
    { "ESE_Tick",    ese_tick    },
    { NULL, NULL }
};

/* Register through LUA_GLOBALSINDEX. NOT via _G - in the campaign state those
 * are different tables, and a _G-based check reports failure on a registration
 * that actually works. */
static void register_natives(lua_State* L) {
    for (int i = 0; kNatives[i].name; i++) {
        L_.pushcclosure(L, kNatives[i].fn, 0);
        L_.setfield(L, LUA_GLOBALSINDEX, kNatives[i].name);
    }
    ese_log("[ese] registered %d native function(s) into state %p",
            (int)(sizeof(kNatives)/sizeof(kNatives[0])) - 1, L);
}

/* ===================== crash guard (added after a real one) ============== *
 * Learned the hard way 2026-09-18: `pcall` does NOT make probing safe. The
 * engine's script functions are native C that take a `context` userdata and
 * dereference it WITHOUT validating, so e.g. conditions.TurnNumber(nil) is a
 * hard access violation, not a catchable Lua error - and it killed the game.
 *
 * A vectored exception handler runs BEFORE normal SEH unwinding, so we can
 * intercept the AV, and longjmp back into pump() to report it as a string
 * instead of losing the session. (Used rather than __try/__except because
 * compiler SEH support is unreliable on the 32-bit MinGW ABI we build against.)
 *
 * HONEST TRADE-OFF: longjmping out of a fault deep inside engine code can leave
 * game state inconsistent - a lock unreleased, an allocation half-finished. It
 * converts a CERTAIN crash into a PROBABLE recovery, which is the right trade
 * for a development tool but is not "safe" in any strong sense. If the game
 * behaves oddly after a guard trip, restart it.
 */

static int safe_rd(DWORD addr, DWORD* out);

/* ===================== single-step instruction trace =====================
 * The one thing nothing else has established: WHICH instruction transfers
 * control into the middle of 0x00951A71. Stack scanning is noise (stale words),
 * entry hooks never fire (the function is never called), and WER only gives the
 * fault offset.
 *
 * So: set the x86 TRAP FLAG and record every EIP into a ring buffer, then dump
 * the ring when the access violation hits. The last entries are the exact
 * instruction sequence leading in, including the bad transfer and its source.
 *
 * Why this is affordable: single-stepping traps on EVERY instruction, which
 * would take forever across a whole campaign load. But the price-engine hook
 * fires SHORTLY before the fault (the Cheat Engine sniffer saw ~5 calls between
 * them), so we arm the trace there and only step the final window.
 *
 * Arming works through the trampoline's own frame: pushfd pushed EFLAGS before
 * pushad, so from the handler's `stk` (= esp+0x24) the saved EFLAGS sits at
 * stk[-1]. Setting bit 8 there means the cave's popfd restores with TF set and
 * stepping begins on the very next instruction.
 */
#define TRACE_RING   512
#define STEP_TRACE_MAX 400000      /* hard cap so a miss cannot hang the game */
#define TF_BIT       0x100

static volatile LONG  g_trace_on  = 0;
static DWORD          g_ring[TRACE_RING];
static DWORD          g_ring_i    = 0;
static DWORD          g_steps     = 0;

static void trace_dump(const char* why) {
    ese_log("=== INSTRUCTION TRACE (%s) - %lu steps, last %d ===",
            why, (unsigned long)g_steps,
            (int)(g_ring_i < TRACE_RING ? g_ring_i : TRACE_RING));

    DWORD n = g_ring_i < TRACE_RING ? g_ring_i : TRACE_RING;
    DWORD start = g_ring_i >= n ? g_ring_i - n : 0;

    /* chronological, static addresses (subtract ASLR delta) so they can be fed
     * straight to Ghidra */
    char line[900]; int w = 0;
    for (DWORD k = 0; k < n; k++) {
        DWORD eip = g_ring[(start + k) % TRACE_RING];
        w += _snprintf(line + w, sizeof(line) - 1 - w, "%08lX ",
                       (unsigned long)(eip - g_delta));
        if (w > (int)sizeof(line) - 16 || (k % 12) == 11) {
            line[w] = 0; ese_log("    %s", line); w = 0;
        }
    }
    if (w > 0) { line[w] = 0; ese_log("    %s", line); }
    ese_log("=== TRACE END ===");
}
   /* defined with the probe below */

/* ================== hardware breakpoint on the fault site =================
 * THE question nothing else has answered: what transfers control into the
 * MIDDLE of the instruction at 0x00951A71?
 *
 * Ruled out already:
 *   - stack scanning              -> stale words, not a real call stack
 *   - hooking FUN_00951A60 entry  -> never fires; the function is never called
 *   - hooking the 0x951A30 loop   -> container always consistent
 *   - single-step tracing         -> steps through ntdll and kills the process
 *   - searching the binary        -> the target is stored NOWHERE (VA or RVA),
 *                                    so it is computed at runtime
 *
 * A HARDWARE breakpoint traps ONCE, before the bad instruction executes, with
 * registers and stack intact - which is exactly the moment we need.
 *
 * ARMING WITHOUT A SECOND THREAD: SetThreadContext on the *current* thread is
 * unreliable for debug registers. But a VEH receives a CONTEXT that is written
 * back to the thread when we return EXCEPTION_CONTINUE_EXECUTION - including
 * Dr0..Dr7. So we raise a private exception, catch it, set the debug registers
 * there, and continue. No suspending, no second thread.
 *
 * DR7 layout used: bit0 = L0 (local enable DR0), bit8 = LE,
 *                  bits16-17 = R/W0 = 00 (execute), bits18-19 = LEN0 = 00 (1 byte).
 */
#define ESE_ARM_HWBP   0xE5E00001u      /* our private "arm it now" exception */
#define DR7_EXEC_DR0   0x00000101u

/* Four hardware breakpoints (DR0..DR3). We use them to find where execution
 * DIVERGES: if the function entry is reached but the instruction after its
 * inner call is not, while the fault site IS, then the divergence happened
 * inside that call. Cheaper and far safer than single-stepping. */
static DWORD         g_bp[4]   = {0,0,0,0};
static const char*   g_bpname[4] = {0,0,0,0};
static volatile LONG g_bphit[4] = {0,0,0,0};
static DWORD         g_hwbp_addr = 0;     /* kept: primary (DR0) */
static volatile LONG g_hwbp_hit = 0;

/* Called from a hook, on the game thread, shortly before the fault. */
static void hwbp_arm(DWORD liveAddr) {
    if (g_hwbp_addr) return;
    g_hwbp_addr = liveAddr;

    /* static addresses of interest, in execution order */
    g_bp[0] = 0x00951A71 + g_delta; g_bpname[0] = "FAULT SITE 951A71";
    g_bp[1] = 0x00951A00 + g_delta; g_bpname[1] = "951A00 entry (inner fn)";
    g_bp[2] = 0x00951A25 + g_delta; g_bpname[2] = "951A25 after inner CALL";
    g_bp[3] = 0x00951A60 + g_delta; g_bpname[3] = "951A60 entry (list fn)";
    ese_log("[hwbp] arming 4 breakpoints: %08lX %08lX %08lX %08lX",
            (unsigned long)g_bp[0], (unsigned long)g_bp[1],
            (unsigned long)g_bp[2], (unsigned long)g_bp[3]);
    RaiseException(ESE_ARM_HWBP, 0, 0, NULL);
}

/* Report everything available at the moment the breakpoint fires. Unlike the
 * post-mortem fault report, the stack here is INTACT - if control arrived via
 * CALL, [ESP] is the caller's return address. */
static void hwbp_report(EXCEPTION_POINTERS* ep) {
    CONTEXT* c = ep->ContextRecord;
    ese_log("*** HW BREAKPOINT HIT at EIP=%08lX (static %08lX) ***",
            (unsigned long)c->Eip, (unsigned long)(c->Eip - g_delta));
    ese_log("    EAX=%08lX EBX=%08lX ECX=%08lX EDX=%08lX",
            (unsigned long)c->Eax, (unsigned long)c->Ebx, (unsigned long)c->Ecx, (unsigned long)c->Edx);
    ese_log("    ESI=%08lX EDI=%08lX EBP=%08lX ESP=%08lX",
            (unsigned long)c->Esi, (unsigned long)c->Edi, (unsigned long)c->Ebp, (unsigned long)c->Esp);

    DWORD v;
    if (safe_rd(c->Esp, &v))
        ese_log("    [ESP]   = %08lX (static %08lX)  <- return address IF we arrived by CALL",
                (unsigned long)v, (unsigned long)(v - g_delta));
    if (safe_rd(c->Ebp, &v)) {
        ese_log("    [EBP]   = %08lX (saved ebp)", (unsigned long)v);
        DWORD ra;
        if (safe_rd(c->Ebp + 4, &ra))
            ese_log("    [EBP+4] = %08lX (static %08lX)  <- caller via a normal frame",
                    (unsigned long)ra, (unsigned long)(ra - g_delta));
    }

    /* first 16 stack words, annotated - lets us spot a plausible frame by eye */
    DWORD lo = g_delta + 0x401000, hi = g_delta + 0x1800000;
    for (int i = 0; i < 16; i++) {
        DWORD sp = c->Esp + i * 4, val;
        if (!safe_rd(sp, &val)) break;
        const char* tag = (val > lo && val < hi) ? "  <- code" : "";
        ese_log("    [ESP+%02X] = %08lX%s%s", i * 4, (unsigned long)val, tag,
                (val > lo && val < hi) ? "" : "");
    }
}

/* ============== THE 9th-COMMODITY FIX (four dead stores) ==================
 * Supersedes the earlier "index clamp", which was WRONG - see the postscript.
 *
 * FUN_00972440 classifies a commodity by scanning a hardcoded 14-entry table
 * of UniStrings at 0x01448254 and returning the matching slot index:
 *
 *   00972459:  MOV ESI,0x1448254
 *   00972460:  PUSH EDI  /  MOV ECX,ESI  /  CALL 0x004b8330   ; strcmp(slot, rec)
 *   0097246f:  CMP ESI,0x144828c                              ; end of table
 *   00972477:  SUB ESI,0x1448254  /  SAR ESI,0x2              ; -> 14 if no match
 *
 * THE TABLE IS DEAD CONTENT. All 14 slots are constructed at 0x00422DE0 from
 * the SAME string literal 0x0125049C = "UnUsEd", and a Ghidra xref sweep of
 * every slot address shows exactly ONE reference each - that constructor call.
 * Nothing in the binary ever writes a commodity name into them. So the scan
 * NEVER matches and this function returns 14 on every call, in vanilla too.
 *
 * Its caller FUN_009153A0 then accumulates through that index with no bounds
 * check, into buffers that hold exactly 14 pairs (zeroed as param_2[0..27]):
 *
 *   009158bc:  ADD [EDI+EAX*8],ESI        ; param_2[28] += ...
 *   009158ea:  ADD [EDI+EAX*8+4],ECX      ; param_2[29] += ...
 *   00915920:  ADD [EAX],ECX              ; param_3[28] += ...
 *   00915952:  ADD [EAX+4],ECX            ; param_3[29] += ...
 *
 * With index 14 every one of these writes ONE PAIR PAST the end. FUN_0098A040
 * calls FUN_009153A0 twice: once on object members (where the overflow lands in
 * padding, harmlessly - which is why vanilla survives), and once on the STACK
 * arrays local_70/local_e0. local_70 sits at ebp-0x70 and is 112 bytes, so it
 * ends exactly at ebp: param_2[28] IS the saved EBP and param_2[29] IS THE
 * RETURN ADDRESS. `ADD` them and the function returns into hyperspace. That is
 * precisely the corrupted return address the hardware breakpoint caught.
 *
 * THE FIX: NOP all four stores.
 *
 * Why this is correct and not merely a suppression: the index is always 14, so
 * these four instructions never once write to a real accumulator slot - they
 * only ever corrupt whatever follows the buffer. The genuine per-turn totals
 * are accumulated by separate instructions the patch does not touch:
 *
 *   00915963:  ADD [EAX],ESI              ; *param_6 += income
 *   00915969:  ADD [ECX],EAX              ; *param_7 += ...
 *
 * so no number the game displays is computed from the stores we remove.
 *
 * POSTSCRIPT - why the previous clamp (CMP imm 0x0144828C -> 0x01448288) was
 * wrong. It made a miss return 13 instead of 14, which IS in bounds, so the
 * campaign loaded. But pair 13 is indices 26/27, and index 26 is a live total:
 * FUN_009153A0 ends with `piVar3[0x1a] += *param_8`. The clamp therefore
 * dumped every commodity's accumulation onto a real figure - which is exactly
 * the garbage trade income (-1847796096) seen in the first test. Reverted here.
 */
#define A_idx_cmp_imm   0x00972471          /* the imm32 of CMP ESI,0x144828C */
#define OLD_TABLE_END   0x0144828Cu         /* the correct, original value */
#define CLAMP_TABLE_END 0x01448288u         /* what the bad clamp wrote */

/* The four out-of-bounds accumulate stores, with their exact encodings. */
static const struct { DWORD addr; int len; unsigned char bytes[4]; const char* what; }
k_oob_stores[] = {
    { 0x009158BC, 3, { 0x01, 0x34, 0xC7, 0x00 }, "ADD [EDI+EAX*8],ESI    (param_2[28] = saved EBP)"     },
    { 0x009158EA, 4, { 0x01, 0x4C, 0xC7, 0x04 }, "ADD [EDI+EAX*8+4],ECX  (param_2[29] = RETURN ADDRESS)" },
    { 0x00915920, 2, { 0x01, 0x08, 0x00, 0x00 }, "ADD [EAX],ECX          (param_3[28])"                 },
    { 0x00915952, 3, { 0x01, 0x48, 0x04, 0x00 }, "ADD [EAX+4],ECX        (param_3[29])"                 },
};

/* Put back the original table-end immediate if a previous build clamped it. */
static void revert_commodity_clamp(void) {
    unsigned char* site = (unsigned char*)(A_idx_cmp_imm + g_delta);
    if (site[-2] != 0x81 || site[-1] != 0xFE) return;      /* not CMP ESI,imm32 */
    /* The immediate is an ABSOLUTE ADDRESS, so the PE loader relocates it: the
     * live value is static + ASLR delta. Comparing the static value would be
     * the same trap that bit the vtable immediate twice. */
    DWORD cur = *(DWORD*)site;
    if (cur != CLAMP_TABLE_END + g_delta) return;          /* nothing to undo */
    DWORD old;
    if (!VirtualProtect(site, 4, PAGE_EXECUTE_READWRITE, &old)) return;
    *(DWORD*)site = OLD_TABLE_END + g_delta;
    VirtualProtect(site, 4, old, &old);
    FlushInstructionCache(GetCurrentProcess(), site, 4);
    ese_log("[fix] reverted the old index clamp at %p (it corrupted trade totals)", site);
}

static int apply_commodity_fix(void) {
    revert_commodity_clamp();

    /* Verify every site BEFORE writing any of them - a half-applied patch is
     * worse than none, and a byte mismatch means this is not the build we
     * analysed. These encodings contain no absolute addresses and no relative
     * branches, so they need no rebasing. */
    for (int i = 0; i < 4; i++) {
        unsigned char* p = (unsigned char*)(k_oob_stores[i].addr + g_delta);
        for (int j = 0; j < k_oob_stores[i].len; j++) {
            if (p[j] == k_oob_stores[i].bytes[j]) continue;
            if (p[j] == 0x90) {                            /* already NOPped */
                ese_log("[fix] site %d at %p already patched", i, p);
                break;
            }
            ese_log("[fix] REFUSING: %p byte %d is %02X, expected %02X (%s)",
                    p, j, p[j], k_oob_stores[i].bytes[j], k_oob_stores[i].what);
            return 0;
        }
    }

    int done = 0;
    for (int i = 0; i < 4; i++) {
        unsigned char* p = (unsigned char*)(k_oob_stores[i].addr + g_delta);
        if (p[0] == 0x90) continue;                        /* already patched */
        DWORD old;
        if (!VirtualProtect(p, k_oob_stores[i].len, PAGE_EXECUTE_READWRITE, &old)) {
            ese_log("[fix] VirtualProtect failed at %p", p);
            return 0;
        }
        for (int j = 0; j < k_oob_stores[i].len; j++) p[j] = 0x90;
        VirtualProtect(p, k_oob_stores[i].len, old, &old);
        FlushInstructionCache(GetCurrentProcess(), p, k_oob_stores[i].len);
        ese_log("[fix] NOPped %p (%d bytes): %s", p, k_oob_stores[i].len, k_oob_stores[i].what);
        done++;
    }
    ese_log("[fix] 9th-commodity fix: %d of 4 out-of-bounds stores removed", done);
    return 1;
}

/* ---- the hardcoded "12 raw resources" -------------------------------------
 *
 * Empire's Trade tab walks resources_table collecting every resource whose unit
 * field is null - the "raw" resources, the ones that are not traded commodities
 * - and it wants exactly TWELVE, because vanilla has exactly twelve:
 *
 *     cattle corn fish gems gold iron rice sheep silver timber wheat wine
 *
 *   00A04B66  xor esi,esi              ; scan from resource 0
 *   loop:
 *   00A04B82  call 00D54B10            ; -> resources_table  ("resources_table")
 *   00A04B87  cmp esi,[eax+0xc]        ; bounds check...
 *   00A04B8A  jae +8
 *   00A04B92  mov eax,[eax+esi*4]
 *   00A04B94  jmp +2
 *   00A04B96  xor eax,eax              ; ...out of range yields NULL
 *   00A04B96  cmp dword [eax+0xc],0    ; and is then dereferenced ANYWAY
 *   00A04BB5  cmp ebx,0x0C             ; <- the twelve
 *   00A04BB8  jnz loop
 *
 * The back-edge is unconditional, so the loop's only exit is finding its
 * twelfth raw resource. Promoting iron, timber and corn to tradeable
 * commodities gives them units, leaves nine, and the scan runs off the end of
 * the table into that unguarded NULL: 0xC0000005 at 00A04B96 the moment the
 * Trade tab opens. (A commodity MUST have a unit - without one the trade UI
 * null-derefs at 00A54682 instead - so the two constraints collide, and the
 * count is the one we can move.)
 *
 * Of the 37 call sites that reach resources_table, this is the ONLY one with a
 * hardcoded count, so a single immediate byte fixes the whole class. The value
 * belongs in ese_commodities.txt because it is a property of the shipped data:
 *
 *     raw_resources 9
 *
 * Absent or zero, nothing is patched and the engine keeps vanilla behaviour. */
#define A_raw_count_imm 0x00A04BB7      /* the 0x0C in `cmp ebx,0x0C` */
#define RAW_COUNT_VANILLA 0x0C

static int apply_raw_resource_count(void) {
    if (g_raw_resources <= 0) return 0;
    if (g_raw_resources > 0x7F) {
        ese_log("[raw] raw_resources %d is out of range for an imm8 - ignored",
                g_raw_resources);
        return 0;
    }

    unsigned char* p = (unsigned char*)(A_raw_count_imm + g_delta);

    /* The two bytes in front must still be `cmp ebx, imm8`, or this is not the
     * instruction we analysed and we must not write. */
    if (p[-2] != 0x83 || p[-1] != 0xFB) {
        ese_log("[raw] REFUSING: %p is not `cmp ebx,imm8` (%02X %02X) - not patching",
                p, p[-2], p[-1]);
        return 0;
    }
    if (p[0] == (unsigned char)g_raw_resources) {
        ese_log("[raw] raw resource count already %d", g_raw_resources);
        return 1;
    }
    if (p[0] != RAW_COUNT_VANILLA) {
        ese_log("[raw] note: raw resource count was %d, not the vanilla %d",
                p[0], RAW_COUNT_VANILLA);
    }

    DWORD old;
    if (!VirtualProtect(p, 1, PAGE_EXECUTE_READWRITE, &old)) {
        ese_log("[raw] VirtualProtect failed at %p", p);
        return 0;
    }
    p[0] = (unsigned char)g_raw_resources;
    VirtualProtect(p, 1, old, &old);
    FlushInstructionCache(GetCurrentProcess(), p, 1);
    ese_log("[raw] raw resource count %d -> %d at %p (Trade tab scan bound)",
            RAW_COUNT_VANILLA, g_raw_resources, p);
    return 1;
}

/* ---- fault reporter -------------------------------------------------------
 * Logs the full context of ANY access violation in Empire.exe, not just ones
 * during our own evals. WER only gives a fault offset; this gives EIP, every
 * register, the faulting address, the read/write direction, and the nearby
 * stack - from inside the process, before the crash completes.
 *
 * It does NOT interfere: it only observes, then returns CONTINUE_SEARCH so the
 * game's own handling proceeds exactly as before. */
static void report_fault(EXCEPTION_POINTERS* ep) {
    EXCEPTION_RECORD* er = ep->ExceptionRecord;
    CONTEXT*          cx = ep->ContextRecord;
    DWORD eip = cx->Eip;

    ese_log("!!! FAULT %08lX at EIP=%08lX  (static %08lX)",
            (unsigned long)er->ExceptionCode, (unsigned long)eip,
            (unsigned long)(eip - g_delta));

    if (er->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && er->NumberParameters >= 2) {
        const char* what = er->ExceptionInformation[0] == 0 ? "READ from"
                         : er->ExceptionInformation[0] == 1 ? "WRITE to"
                         : "EXECUTE at";
        ese_log("    %s %08lX", what, (unsigned long)er->ExceptionInformation[1]);
    }
    ese_log("    EAX=%08lX EBX=%08lX ECX=%08lX EDX=%08lX",
            (unsigned long)cx->Eax, (unsigned long)cx->Ebx,
            (unsigned long)cx->Ecx, (unsigned long)cx->Edx);
    ese_log("    ESI=%08lX EDI=%08lX EBP=%08lX ESP=%08lX",
            (unsigned long)cx->Esi, (unsigned long)cx->Edi,
            (unsigned long)cx->Ebp, (unsigned long)cx->Esp);

    /* Bytes at EIP: confirms which instruction actually faulted, independent of
     * WER's offset (which was one byte off on this 32-bit process earlier). */
    DWORD v;
    char b[64]; int w = 0;
    for (int i = 0; i < 12 && w < (int)sizeof(b) - 4; i++) {
        if (!safe_rd((eip + i) & ~0u, &v)) break;
        w += _snprintf(b + w, sizeof(b) - 1 - w, "%02X ", *(unsigned char*)(eip + i));
    }
    b[w] = 0;
    ese_log("    bytes at EIP: %s", b);

    /* Stack words that look like return addresses into Empire.exe - a poor
     * man's call stack, but enough to identify the caller. */
    char s[600]; w = 0;
    DWORD lo = (DWORD)g_delta + 0x400000, hi = lo + 0x1400000;
    for (int i = 0; i < 48 && w < (int)sizeof(s) - 16; i++) {
        DWORD sp = cx->Esp + i * 4, val;
        if (!safe_rd(sp, &val)) break;
        if (val > lo && val < hi)
            w += _snprintf(s + w, sizeof(s) - 1 - w, "%08lX(s=%08lX) ",
                           (unsigned long)val, (unsigned long)(val - g_delta));
    }
    s[w] = 0;
    ese_log("    return-address candidates: %s", s);
}

static LONG CALLBACK ese_veh(EXCEPTION_POINTERS* ep) {
    DWORD code = ep->ExceptionRecord->ExceptionCode;

    /* our private request to arm the debug registers: the CONTEXT we modify
     * here is written back to the thread when we continue execution */
    if (code == ESE_ARM_HWBP) {
        ep->ContextRecord->Dr0 = g_bp[0];
        ep->ContextRecord->Dr1 = g_bp[1];
        ep->ContextRecord->Dr2 = g_bp[2];
        ep->ContextRecord->Dr3 = g_bp[3];
        /* L0|L1|L2|L3 = bits 0,2,4,6; all execute / 1 byte (R/W and LEN = 0) */
        ep->ContextRecord->Dr7 = 0x00000155u;
        ese_log("[hwbp] debug registers set (Dr7=%08lX)", 0x155UL);
        return EXCEPTION_CONTINUE_EXECUTION;
    }

    /* the breakpoint itself arrives as a single-step with Dr6 bit0 set */
    if (code == EXCEPTION_SINGLE_STEP && g_hwbp_addr) {
        DWORD eip = ep->ContextRecord->Eip;
        for (int i = 0; i < 4; i++) {
            if (!g_bp[i] || eip != g_bp[i]) continue;
            LONG n = InterlockedIncrement(&g_bphit[i]);
            if (n <= 3) {                     /* first few only - avoid spam */
                DWORD sp0 = 0, sp4 = 0;
                safe_rd(ep->ContextRecord->Esp, &sp0);
                safe_rd(ep->ContextRecord->Esp + 4, &sp4);
                ese_log("[hwbp] HIT #%ld %-26s ecx=%08lX [esp]=%08lX [esp+4]=%08lX",
                        n, g_bpname[i], (unsigned long)ep->ContextRecord->Ecx,
                        (unsigned long)sp0, (unsigned long)sp4);
            }
            if (i == 0) {                     /* the fault site: full dump once */
                if (InterlockedCompareExchange(&g_hwbp_hit, 1, 0) == 0) hwbp_report(ep);
                ep->ContextRecord->Dr7 = 0;   /* disarm so we do not loop */
            }
            break;
        }
        ep->ContextRecord->Dr6 = 0;
        return EXCEPTION_CONTINUE_EXECUTION;
    }

    /* Observe every genuine fault, whether or not our guard is armed. Logged
     * first so the record exists even if the process dies immediately after. */
    /* Single-step: record EIP and re-arm TF (the CPU clears it on each trap).
     * CONTINUE_EXECUTION resumes the very next instruction. */
    if (code == EXCEPTION_SINGLE_STEP && g_trace_on) {
        g_ring[g_ring_i++ % TRACE_RING] = ep->ContextRecord->Eip;
        if (++g_steps < STEP_TRACE_MAX) ep->ContextRecord->EFlags |= TF_BIT;
        else { g_trace_on = 0; trace_dump("step cap reached"); }
        return EXCEPTION_CONTINUE_EXECUTION;
    }

    if (code == EXCEPTION_ACCESS_VIOLATION) {
        static LONG reported = 0;
        if (InterlockedCompareExchange(&reported, 1, 0) == 0) {
            report_fault(ep);
            if (g_trace_on) { g_trace_on = 0; trace_dump("fault"); }
        }
    }
    /* Only step in for OUR evaluation, and only for genuine faults - never
     * interfere with exceptions the game raises during normal operation. */
    if (!g_guard_armed) return EXCEPTION_CONTINUE_SEARCH;
    if (code != EXCEPTION_ACCESS_VIOLATION &&
        code != EXCEPTION_ILLEGAL_INSTRUCTION &&
        code != EXCEPTION_PRIV_INSTRUCTION &&
        code != EXCEPTION_INT_DIVIDE_BY_ZERO) return EXCEPTION_CONTINUE_SEARCH;

    g_guard_code  = code;
    g_guard_armed = 0;
    if (g_guard_use_prot) longjmp(g_prot_jmp, 1);   /* back into ESE_Protect */
    longjmp(g_guard_jmp, 1);                        /* back into pump() */
    return EXCEPTION_CONTINUE_SEARCH;   /* not reached */
}

/* Run ese_autoexec.lua (game folder) in a freshly-acquired campaign state.
 *
 * Without this, every Lua-side thing we set up - event handlers, helper
 * functions, the mod itself - would have to be re-sent by hand after every
 * campaign load, because a new campaign means a new lua_State with none of it.
 * This is what makes ESE usable for an actual mod rather than just probing. */
static void run_autoexec_file(lua_State* L, const char* fname) {
    FILE* f = fopen(fname, "rb");
    if (!f) return;                       /* optional file - absent is fine */
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n <= 0 || n > 1024*1024) { fclose(f); ese_log("[ese] autoexec %s: bad size", fname); return; }
    char* buf = (char*)malloc((size_t)n + 1);
    if (!buf) { fclose(f); return; }
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    buf[got] = 0;

    int top = L_.gettop(L);
    int rc = L_.loadbuffer(L, buf, got, "=ese_autoexec");
    if (rc != 0) {
        const char* e = L_.tolstring(L, -1, NULL);
        ese_log("[ese] autoexec %s COMPILE error: %s", fname, e ? e : "?");
    } else {
        rc = L_.pcall(L, 0, 0, 0);
        if (rc != 0) {
            const char* e = L_.tolstring(L, -1, NULL);
            ese_log("[ese] autoexec %s RUNTIME error: %s", fname, e ? e : "?");
        } else {
            ese_log("[ese] autoexec %s ran OK (%ld bytes)", fname, n);
        }

    }
    L_.settop(L, top);
    free(buf);
}

static void run_autoexec(lua_State* L) { run_autoexec_file(L, "ese_autoexec.lua"); }

/* The campaign state is detected the moment `conditions` is assigned, but
 * `events` does not exist yet at that point - so running the autoexec there
 * finds no events table and silently does nothing (observed exactly that).
 * Instead, poll cheaply from the hot getfield hook until `events` appears.
 *
 * Re-entrancy matters here: we call lua_getfield from INSIDE the lua_getfield
 * hook, which would recurse forever without the guard. */
static LONG g_autoexec_pending = 0;

static void try_autoexec(void) {
    static volatile LONG busy = 0;
    if (!g_autoexec_pending || !g_campL) return;
    if (InterlockedCompareExchange(&busy, 1, 0) != 0) return;

    lua_State* L = g_campL;
    int top = L_.gettop(L);
    L_.getfield(L, LUA_GLOBALSINDEX, "events");
    int ty = L_.type(L, -1);
    L_.settop(L, top);

    if (ty == LUA_TTABLE) {          /* ready at last */
        g_autoexec_pending = 0;
        ese_log("[ese] 'events' is now available - running autoexec");
        run_autoexec(L);
    }
    InterlockedExchange(&busy, 0);
}

/* ================================ the TICK =============================== *
 * A stored Lua snippet re-run on the GAME thread at a throttled rate. This is
 * Phase 2 of ROADMAP_FIRST_PERSON: a camera that is set once is a screenshot;
 * to FOLLOW a soldier something must run every frame.
 *
 * WHY HERE AND NOT IN THE D3D9 Present HOOK
 *   Present runs on the render path, where the Lua state may be mid-operation.
 *   The pump already executes on the game thread from inside a Lua API hook -
 *   a point where Lua is provably in a consistent state, since it is Lua
 *   itself that called us. That is the same property every @battle eval
 *   already relies on, so the tick inherits it for free.
 *
 * THROTTLED BY TIME, NOT BY CALL COUNT. lua_getfield is extremely hot (it runs
 * for effectively every global access in the game), so "run every call" would
 * be thousands of executions a second. GetTickCount gives a stable ~60Hz
 * regardless of how hot the hook happens to be in a given scene.
 *
 * DISARMS ITSELF ON A NATIVE FAULT. A tick that faults would otherwise fault
 * again on the very next hook call, turning one bad read into an unstoppable
 * crash loop on the game thread. */
/* A freed lua_State still has a pointer. The crash was calling gettop on one.
 * Readable memory is not proof the state is live, but an unreadable one is
 * proof it is not. Drop it before the call. */
static int state_readable(lua_State* L) {
    if (!L) return 0;
    MEMORY_BASIC_INFORMATION m;
    if (!VirtualQuery(L, &m, sizeof(m))) return 0;
    if (m.State != MEM_COMMIT) return 0;
    if (m.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    return (m.Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_WRITECOPY |
                         PAGE_EXECUTE_WRITECOPY)) != 0;
}

/* Set by the 00580493 fetch hook when BattleUI.CameraZoomTo is a function. */
static lua_State* g_battle_pend = NULL;
static DWORD g_battle_obj = 0;

/* Live while the battle object still points at L and the battle manager exists. */
static int battle_state_live(lua_State* L) {
    DWORD slot = 0, cur = 0, root = 0, mgr = 0;
    if (!L || !g_battle_obj) return 0;
    if (!safe_rd(g_battle_obj + 4, &slot) || !slot) return 0;
    if (!safe_rd(slot, &cur) || cur != (DWORD)L) return 0;
    if (!safe_rd(0x0137D488 + g_delta, &root) || !root) return 0;
    if (!safe_rd(root + 0x31C, &mgr) || !mgr) return 0;
    return state_readable(L);
}

static void tick_run(void) {
    if (!g_tick_on || !g_battleL || !g_tick_src[0]) return;
    if (g_battle_obj && !battle_state_live(g_battleL)) {
        ese_log("[tick] battle state %p no longer held by battle object - dropped", g_battleL);
        g_battleL = NULL;
        return;
    }
    if (!state_readable(g_battleL)) {
        ese_log("[tick] battle state %p unreadable - dropped, tick left armed", g_battleL);
        g_battleL = NULL;
        return;
    }
    DWORD now = GetTickCount();
    if ((now - g_tick_last) < g_tick_ms) return;
    g_tick_last = now;

    /* The snippet will touch globals, which re-enters this very hook. */
    static volatile LONG inTick = 0;
    if (InterlockedCompareExchange(&inTick, 1, 0) != 0) return;

    /* If a pipe eval is already holding the guard, just skip this tick. */
    if (InterlockedCompareExchange(&g_prot_busy, 1, 0) == 0) {
        lua_State* L   = g_battleL;
        if (!state_readable(L)) {
            g_battleL = NULL;
            InterlockedExchange(&g_prot_busy, 0);
            InterlockedExchange(&inTick, 0);
            return;
        }
        int        top = L_.gettop(L);
        if (setjmp(g_prot_jmp) == 0) {
            g_guard_use_prot = 1;
            g_guard_armed    = 1;
            if (L_.loadbuffer(L, g_tick_src, strlen(g_tick_src), "=ese_tick") == 0) {
                L_.pcall(L, 0, 0, 0);
            }
            g_guard_armed    = 0;
            g_guard_use_prot = 0;
        } else {
            g_guard_armed    = 0;
            g_guard_use_prot = 0;
            InterlockedIncrement(&g_tick_fault);
            g_tick_on = 0;
            ese_log("[tick] NATIVE FAULT 0x%08lX - tick disarmed", g_guard_code);
        }
        L_.settop(L, top);
        InterlockedExchange(&g_prot_busy, 0);
        InterlockedIncrement(&g_tick_runs);
    }
    InterlockedExchange(&inTick, 0);
}

/* ================================ the pump =============================== *
 * Runs on the GAME thread (called from a Lua-API hook). Drains one queued
 * request, evaluates it in the campaign state, and stores the result. */
static void native_cmd(const char* p);

static void battle_bind_pump(void) {
    static volatile LONG busy = 0;
    lua_State* L = g_battle_pend;
    if (!L || L == g_battleL) return;
    if (!battle_state_live(L)) return;
    if (InterlockedCompareExchange(&busy, 1, 0) != 0) return;
    g_battle_pend = NULL;
    g_battleL = L;
    ese_log("[ese] BATTLE state bound via BattleUI.CameraZoomTo: %p (object %08lX)",
            (void*)L, (unsigned long)g_battle_obj);
    register_natives(L);
    run_autoexec_file(L, "ese_battle_autoexec.lua");
    InterlockedExchange(&busy, 0);
}

static void pump(void) {
    battle_bind_pump();
    tick_run();
    static volatile LONG reentry = 0;
    /* Do NOT gate on g_campL. A custom battle launched from the main menu has
     * no campaign state at all, so requiring one made "@battle" unreachable
     * in exactly the case it exists for. The target state is checked after
     * routing instead. The pump itself is driven from the lua_getfield hook,
     * which is hot in every state including battle. */
    if (!g_pending) return;

/* Native commands need no Lua state - see native_cmd() for why that
 * matters in a custom battle. */
if (g_req[0] == '@' && g_req[1] == 'n' && g_req[2] == 'a' && g_req[3] == 't') {
    const char* p = g_req + 4;
    while (*p == ' ') p++;
    native_cmd(p);
    g_pending = 0; g_done = 1;
    return;
}
    if (InterlockedCompareExchange(&reentry, 1, 0) != 0) return; /* no recursion */

    /* A request prefixed "@ui " is evaluated in a UI state instead of the
     * campaign one - that is the only place the UI API (and therefore any
     * on-screen text) exists. */
    const char* src = g_req;
    lua_State*  L   = g_campL;

    if (g_req[0]=='@' && g_req[1]=='u' && g_req[2]=='i') {
        const char* p = g_req + 3;

        if (*p == ' ') p++;
        src = p;
        L = g_uiL;
        if (!L) {
            _snprintf(g_res, RES_MAX-1,
                "campaign UI state not acquired yet - load a campaign first");
            g_res[RES_MAX-1] = 0;
            g_pending = 0; g_done = 1;
            InterlockedExchange(&reentry, 0);
            return;
        }
    }
    /* "@battle " evaluates in the battle state, where the 208-function battle
     * API lives (CameraZoomTo, Current_Selection_*, EnableShortcutHandler...).
     * Nothing in that API exists in the campaign or campaign-UI states. */
    else if (g_req[0]=='@' && g_req[1]=='b' && g_req[2]=='a' &&
             g_req[3]=='t' && g_req[4]=='t' && g_req[5]=='l' && g_req[6]=='e') {
        const char* p = g_req + 7;
        if (*p == ' ') p++;
        src = p;
        L = g_battleL;
        if (!L) {
            _snprintf(g_res, RES_MAX-1,
                "battle state not acquired - be IN a battle (it is created per battle)");
            g_res[RES_MAX-1] = 0;
            g_pending = 0; g_done = 1;
            InterlockedExchange(&reentry, 0);
            return;
        }
    }
    /* An unprefixed request targets the campaign state, which may not exist
     * (main menu, or a custom battle launched without a campaign). Say so
     * rather than dereferencing NULL now that the campaign gate is gone. */
    if (!L) {
        _snprintf(g_res, RES_MAX-1,
            "no campaign state - load a campaign, or prefix with @battle / @ui");
        g_res[RES_MAX-1] = 0;
        g_pending = 0; g_done = 1;
        InterlockedExchange(&reentry, 0);
        return;
    }
    int top = L_.gettop(L);

    /* Log the command BEFORE running it. If it kills the game anyway (the guard
     * cannot catch everything), ese_log.txt still names the exact culprit -
     * which is precisely what we lacked when this first happened. */
    ese_log("[ese] eval: %s", g_req);

    if (setjmp(g_guard_jmp) != 0) {
        /* we got here from the vectored handler */
        _snprintf(g_res, RES_MAX-1,
            "NATIVE CRASH (0x%08lX) caught - the call faulted inside engine code. "
            "pcall cannot catch this. The game survived, but its state may be "
            "unreliable; restart if it misbehaves.", g_guard_code);
        g_res[RES_MAX-1] = 0;
        ese_log("[ese] GUARD TRIPPED 0x%08lX on: %s", g_guard_code, g_req);
        L_.settop(L, top);
        g_pending = 0;
        g_done    = 1;
        InterlockedExchange(&reentry, 0);
        return;
    }
    g_guard_armed = 1;

    int rc = L_.loadbuffer(L, src, strlen(src), "=ese");
    if (rc != 0) {
        const char* e = L_.tolstring(L, -1, NULL);
        _snprintf(g_res, RES_MAX-1, "compile error: %s", e ? e : "?");
    } else {
        rc = L_.pcall(L, 0, 1, 0);
        if (rc != 0) {
            const char* e = L_.tolstring(L, -1, NULL);
            _snprintf(g_res, RES_MAX-1, "runtime error: %s", e ? e : "?");
        } else {
            /* tolstring coerces numbers too; nil/other types report their type */
            const char* s = L_.tolstring(L, -1, NULL);
            if (s) _snprintf(g_res, RES_MAX-1, "%s", s);
            else   _snprintf(g_res, RES_MAX-1, "(%s)",
                             L_.type(L,-1) == 0 ? "nil" : "non-string value");
        }
    }
    g_res[RES_MAX-1] = 0;

    g_guard_armed = 0;          /* disarm as soon as our own eval is done, so the
                                 * handler never intercepts the game's own
                                 * exceptions during normal play */
    L_.settop(L, top);          /* always restore the stack we borrowed */
    g_pending = 0;
    g_done    = 1;
    InterlockedExchange(&reentry, 0);
}

/* =============================== handlers ================================ */

/* Detecting the battle state on ANY of the 208 API names was wrong: several
 * of them (Pause, Play, SelectionChanged) also exist in Empire's UI states,
 * so g_battleL flip-flopped between four different lua_States. Globals
 * installed in one were invisible from the next, which looked exactly like
 * "the battle state was wiped". Match only names unique to the real battle
 * state, and never rebind once one is held. */
/* Broad name matching finds candidates, but Pause/Play/SelectionChanged also
 * exist in UI states, so a candidate must be VERIFIED: the real battle state
 * is the one where CameraZoomTo resolves to a function. Guarded because this
 * calls lua_getfield from inside the lua_getfield hook. */
static int is_real_battle_state(lua_State* L) {
    static volatile LONG busy = 0;
    if (InterlockedCompareExchange(&busy, 1, 0) != 0) return 0;
    int ok = 0, top = L_.gettop(L);
    L_.getfield(L, LUA_GLOBALSINDEX, "CameraZoomTo");
    ok = (L_.type(L, -1) == LUA_TFUNCTION);
    L_.settop(L, top);
    InterlockedExchange(&busy, 0);
    return ok;
}

/* Lua type ids: global BattleUI, BattleUI.CameraZoomTo, BattleUI.Current_Selection_Halt. -1 = BattleUI not a table.
 * 005B3770 does createtable + luaI_openlib(DAT_0137d028 list) + setfield "BattleUI". */
static void battle_iface_types(lua_State* L, int* ui, int* zoom, int* halt) {
    int top = L_.gettop(L);
    *zoom = -1; *halt = -1;
    L_.getfield(L, LUA_GLOBALSINDEX, "BattleUI");
    *ui = L_.type(L, -1);
    if (*ui == LUA_TTABLE) {
        L_.getfield(L, -1, "CameraZoomTo");
        *zoom = L_.type(L, -1);
        L_.settop(L, top + 1);
        L_.getfield(L, -1, "Current_Selection_Halt");
        *halt = L_.type(L, -1);
    }
    L_.settop(L, top);
}

static const char* kBattleUniqueNames[] = {
    "CameraZoomTo", "Current_Selection_Halt", "Fire_At_Will",
    "SelectAllCavalry", "DeploymentFinishYesStart", "BattleDetails", NULL
};

/* stk = { retaddr, L, idx, k }
 *
 * The guard keys on L, NOT on a "have I registered yet" flag. Returning to the
 * menu and loading another campaign builds a NEW lua_State; with a one-shot
 * boolean we would keep pointing g_campL at the old, freed state and write into
 * freed memory on the next eval. Comparing L means a new state is detected and
 * re-registered automatically. */
static void __cdecl on_setfield(DWORD* stk) {
    if ((int)stk[2] == LUA_GLOBALSINDEX && stk[3]) {
        const char* k = (const char*)stk[3];
        /* "cond" -> this L is the campaign scripting state */
        /* Track ONLY the state that receives the exact global "CampaignUI".
         *
         * An earlier version collected every state that received "Component".
         * That was wrong and dangerous: Empire creates a lua_State PER UI
         * COMPONENT and destroys them as elements come and go, so a stored
         * pointer is usually a freed state by the time you use it. Evaluating
         * in one produced a native access violation (the crash guard caught
         * it). It also filled a 32-slot table during load, before CampaignUI
         * was ever assigned.
         *
         * The CampaignUI-bearing state is the campaign's own UI root and lives
         * as long as the campaign UI does. Exact match, not a 4-byte prefix:
         * "Camp" would also hit "CampaignName". */
        /* TWO states receive CampaignUI: a minimal one (CampaignUI +
         * decoda_name only) and the real UI root, which ALSO gets Component,
         * Address, UniChar, Localisation. Only the latter can drive panels.
         * CampaignUI arrives first, so: remember the candidates here, then
         * promote whichever one later receives Component. */
        if (strcmp(k, "CampaignUI") == 0) {
            lua_State* L = (lua_State*)stk[1];
            int known = 0;
            for (int i = 0; i < g_cand_n; i++) if (g_cand[i] == L) { known = 1; break; }
            if (!known && g_cand_n < CAND_MAX) {
                g_cand[g_cand_n++] = L;
                if (!g_uiL) g_uiL = L;      /* provisional until one proves better */
                ese_log("[ese] CampaignUI candidate: %p", L);
            }
        }
        /* Promote a candidate that also has the Component API - that is the
         * real UI root. Deliberately NOT tracking every Component state: there
         * are ~109 of them, they are per-component and transient, and holding
         * pointers to those is a use-after-free (confirmed by crashing). */
        if (strcmp(k, "Component") == 0) {
            lua_State* L = (lua_State*)stk[1];
            for (int i = 0; i < g_cand_n; i++) {
                if (g_cand[i] == L && g_uiL != L) {
                    g_uiL = L;
                    ese_log("[ese] UI root confirmed (has Component): %p", L);
                    break;
                }
            }
        }
        /* Battle state: CameraZoomTo is registered only there. */
        if (strcmp(k, "CameraZoomTo") == 0) {
            lua_State* L = (lua_State*)stk[1];
            if (L != g_battleL) {
                g_battleL = L;
                ese_log("[ese] BATTLE state acquired: %p (key 'CameraZoomTo')", L);
                register_natives(L);
                /* The battle Lua state is destroyed and rebuilt for EVERY battle,
                 * silently wiping any globals a previous battle installed. The
                 * tick keeps running and pcall swallows the nil-call, so it looks
                 * healthy while doing nothing. Reinstall automatically instead. */
                run_autoexec_file(L, "ese_battle_autoexec.lua");
            }
        }
        if (k[0]=='c' && k[1]=='o' && k[2]=='n' && k[3]=='d') {
            lua_State* L = (lua_State*)stk[1];
            if (L != g_campL) {
                g_campL = L;
                g_registered = 1;
                ese_log("[ese] campaign state %s: %p (key '%s')",
                        g_registered ? "(re)acquired" : "found", L, k);
                register_natives(L);
                g_autoexec_pending = 1;   /* deferred until 'events' exists */
            }
        }
    }
    pump();
}

/* lua_getfield is extremely hot - it runs for effectively every global/table
 * read - which makes it a reliable heartbeat for draining queued commands even
 * when the player is idle on the campaign map. */
/* ---- 9th-commodity probe, driven from the hot hook -----------------------
 * The autoexec runs BEFORE the world exists (proven: the world pointer read 0
 * there), and the crash lands shortly after. Rather than trying to time a Lua
 * query into that window, poll from here - on_getfield runs constantly on the
 * game thread - and dump the commodity structures the instant they appear.
 * Logged per line, so it survives the fault that follows.
 *
 * Chain (verified previously): DAT_01473a78 -> [+0x924] -> [+0x8] managers
 *                              -> [+0xC84] trade manager -> [+0xB8] count */
static LONG g_probe_done = 0;

static int safe_rd(DWORD addr, DWORD* out) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!addr || VirtualQuery((void*)addr, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT || (mbi.Protect & PAGE_GUARD)) return 0;
    DWORD p = mbi.Protect & 0xFF;
    if (p == PAGE_NOACCESS || p == PAGE_EXECUTE) return 0;
    *out = *(DWORD*)addr;
    return 1;
}

static void probe_commodities(void) {
    if (g_probe_done) return;

    /* The world slot lives in Empire.exe's own .data - always mapped - so read
     * it DIRECTLY and cheaply on every call. The previous version throttled to
     * 1-in-1024 because safe_rd() calls VirtualQuery (a syscall), and that was
     * coarse enough to miss the window between the world appearing and the
     * crash: the probe never fired at all. Only walk the (validated) rest of
     * the chain once this is non-null. */
    DWORD world = *(DWORD*)(0x01473A78 + g_delta);
    if (!world) return;

    DWORD a = 0, mgrs = 0, trade = 0, v = 0;
    /* Log the chain as it resolves. If it stops part-way, WHERE it stops tells
     * us how far campaign construction got before the fault - the diagnosis
     * either way. Announced once per distinct world pointer, so no spam. */
    static DWORD announced = 0;
    if (world != announced) { announced = world; ese_log("[probe] world=%08X", world); }

    if (!safe_rd(world + 0x924, &a) || !a) return;
    if (!safe_rd(a + 0x8, &mgrs) || !mgrs) return;
    if (!safe_rd(mgrs + 0xC84, &trade) || !trade) return;

    g_probe_done = 1;                          /* one shot */
    ese_log("=== COMMODITY PROBE (world is up) ===");
    ese_log("  world=%08X managers=%08X trade_manager=%08X", world, mgrs, trade);
    if (safe_rd(trade + 0xB8, &v)) ese_log("  trade_manager+0xB8 count = %lu", (unsigned long)v);

    /* Any nearby field still holding 8 while the table says 9 IS the overflow. */
    char line[512]; int w = 0;
    for (DWORD off = 0x90; off <= 0xF0 && w < (int)sizeof(line)-24; off += 4) {
        if (safe_rd(trade + off, &v) && v <= 64)
            w += _snprintf(line+w, sizeof(line)-1-w, "+%X=%lu ", (unsigned)off, (unsigned long)v);
    }
    line[w] = 0;
    ese_log("  small ints in trade manager: %s", line);

    /* regions manager sits at +0xC50 - its per-commodity arrays are the other
     * suspect, since they are sized at construction time */
    DWORD regions = 0;
    if (safe_rd(mgrs + 0xC50, &regions) && regions) {
        ese_log("  regions manager = %08X", regions);
        w = 0;
        for (DWORD off = 0x00; off <= 0x60 && w < (int)sizeof(line)-24; off += 4) {
            if (safe_rd(regions + off, &v) && v <= 64)
                w += _snprintf(line+w, sizeof(line)-1-w, "+%X=%lu ", (unsigned)off, (unsigned long)v);
        }
        line[w] = 0;
        ese_log("  small ints in regions manager: %s", line);
    }
    ese_log("=== COMMODITY PROBE END ===");
}

/* ---- price-engine hook: capture the trade manager AT THE MOMENT OF USE -----
 *
 * The global world pointer is not published until after campaign construction,
 * and the crash happens during it - so walking down from DAT_01473a78 can never
 * reach these structures (proven: every probe read 0). The only way in is the
 * way the Cheat Engine sniffer did it - take `this` straight out of a function
 * that is actually executing.
 *
 * Site: static 0x00A65A8C, mid-function inside the price engine FUN_00A65A70.
 * Bytes `8B BE B8 00 00 00` = MOV EDI,[ESI+0xB8], where ESI already holds the
 * trade manager (set from ECX earlier in the function). 6 whole bytes, no
 * relative branch - byte-verified against the exe.
 *
 * MID-FUNCTION, so ECX/EDX mean nothing here; ESI is the object we want, and
 * we read it from the pushad frame at [esp+04] (EDI is [esp+00]).
 */
#define A_price_engine   0x00A65A8C
static const unsigned char kPriceProlog[6] = { 0x8B,0xBE,0xB8,0x00,0x00,0x00 };
static LONG g_pe_done = 0;

static void __cdecl on_price_engine(DWORD* stk) {
    /* CAREFUL: the trampoline passes `lea eax,[esp+0x24]`, i.e. a pointer to
     * the ORIGINAL stack, already past the register frame. The pushad frame
     * therefore sits 0x24 bytes BELOW stk. pushad order puts EDI at [esp+00]
     * and ESI at [esp+04], so: */
    DWORD* regs = (DWORD*)((char*)stk - 0x24);
    if (g_pe_done) return;
    DWORD esi = regs[1];                 /* ESI = the trade manager */
    if (!esi) return;
    g_pe_done = 1;

    DWORD v = 0;
    ese_log("=== PRICE ENGINE REACHED - trade manager = %08X ===", esi);
    if (safe_rd(esi + 0xB8, &v)) ese_log("  +0xB8 commodity count = %lu", (unsigned long)v);

    /* Dump every small integer in the object. With 9 commodities live, any
     * field still reading 8 is a consumer sized before the change - the
     * overflow we have been hunting all evening. */
    char line[900]; int w = 0;
    for (DWORD off = 0; off <= 0x180 && w < (int)sizeof(line) - 24; off += 4) {
        if (safe_rd(esi + off, &v) && v <= 64)
            w += _snprintf(line + w, sizeof(line) - 1 - w, "+%lX=%lu ",
                           (unsigned long)off, (unsigned long)v);
    }
    line[w] = 0;
    ese_log("  small ints 0..0x180: %s", line);

    /* the commodity DATABASE_TABLE: +0x08 count, +0x0C sentinel, +0x10 records */
    DWORD tbl = 0;
    for (DWORD off = 0; off <= 0x180; off += 4) {
        DWORD cand = 0, c8 = 0, c12 = 0;
        if (!safe_rd(esi + off, &cand) || !cand) continue;
        if (!safe_rd(cand + 0x08, &c8) || !safe_rd(cand + 0x0C, &c12)) continue;
        if (c8 == c12 && c8 >= 7 && c8 <= 12) {   /* count == sentinel: the table */
            tbl = cand;
            ese_log("  candidate commodity table at +%lX -> %08X (count=%lu sentinel=%lu)",
                    (unsigned long)off, tbl, (unsigned long)c8, (unsigned long)c12);
        }
    }
    ese_log("=== PRICE ENGINE DUMP END ===");
    /* hwbp_arm(...) - disabled: it found the bug (corrupted return address)
     * and breakpointing the hot functions around it hung the game. */

    /* Arm single-stepping: saved EFLAGS sits at stk[-1] (pushfd ran before
     * pushad), so setting TF there makes the cave's popfd resume in trace mode. */
    /* DISABLED 2026-09-18 - single-step tracing via a VEH is NOT viable here.
     * Arming TF made the thread step through ntdll heap/syscall paths as well
     * as game code, and the process died with an UNHANDLED 0x80000004
     * (EXCEPTION_SINGLE_STEP) inside ntdll at 0x775a7009 before the trace ever
     * dumped - less stable than the bug we were chasing.
     *
     * The viable version is a HARDWARE breakpoint (DR0 = target, DR7 execute),
     * which traps ONCE instead of millions of times. It needs the debug
     * registers set on the game thread, and SetThreadContext on the current
     * thread is unreliable - so it requires duplicating the main thread handle
     * in DllMain and setting DRs from another thread while it is suspended.
     * Left unimplemented deliberately; the machinery below stays for that. */
    /* stk[-1] |= TF_BIT;  g_trace_on = 1; */
}

/* ---- the faulting iteration loop (0x00951A30) ----------------------------
 * for (i = 0; i < [this+0x10]; i++) { ECX = [[this+0x14] + i*4]; dispatch; }
 *
 * The crash is this loop reading PAST its element array and virtually
 * dispatching whatever garbage it finds. Log the container, its count, and how
 * many entries actually look like valid objects - the difference IS the bug.
 *
 * Steal 6: 56 57 8B F9 33 F6 (PUSH ESI; PUSH EDI; MOV EDI,ECX; XOR ESI,ESI) -
 * whole instructions, none position-dependent. ECX (the container) sits at
 * +0x18 in the pushad frame (order: EDI,ESI,EBP,ESP,EBX,EDX,ECX,EAX).
 */
#define A_iter_loop  0x00951A30
static const unsigned char kIterProlog[6] = { 0x56,0x57,0x8B,0xF9,0x33,0xF6 };
static LONG g_iter_seen = 0;

static void __cdecl on_iter_loop(DWORD* stk) {
    DWORD* regs = (DWORD*)((char*)stk - 0x24);
    DWORD self  = regs[6];                      /* ECX */
    DWORD count = 0, arr = 0;
    if (!self || !safe_rd(self + 0x10, &count) || !safe_rd(self + 0x14, &arr)) return;
    if (count == 0 || count > 256) return;

    /* How many entries are plausible object pointers? A healthy container has
     * all of them; the buggy one has count > valid. */
    DWORD good = 0, v = 0, firstBad = 0xFFFFFFFF;
    for (DWORD i = 0; i < count; i++) {
        DWORD e = 0;
        if (safe_rd(arr + i * 4, &e) && e > 0x10000 && safe_rd(e, &v)) good++;
        else if (firstBad == 0xFFFFFFFF) firstBad = i;
    }
    if (good == count) return;                  /* healthy - keep looking */

    if (InterlockedCompareExchange(&g_iter_seen, 1, 0) != 0) return;
    ese_log("!!! BAD ITERATION: container=%08lX count=%lu array=%08lX valid=%lu firstBad=%lu",
            (unsigned long)self, (unsigned long)count, (unsigned long)arr,
            (unsigned long)good, (unsigned long)firstBad);
    char b[400]; int w = 0;
    for (DWORD i = 0; i < count && w < (int)sizeof(b) - 16; i++) {
        DWORD e = 0; safe_rd(arr + i * 4, &e);
        w += _snprintf(b + w, sizeof(b) - 1 - w, "%lu:%08lX ", (unsigned long)i, (unsigned long)e);
    }
    b[w] = 0;
    ese_log("    entries: %s", b);
}

/* ============ THE 9th COMMODITY IN CampaignUI.TradeInfo ==================
 * The World Market panel renders whatever CampaignUI.TradeInfo() returns:
 *
 *   for k, v in pairs(trade_info.prices) do
 *     UIComponent(UIComponent(window:Find(k)):Find("dy_value")):SetStateText(v)
 *   end
 *
 * but that native (FUN_00B1E3F0, registered at 0x00427745 with the name string
 * 0x1267080) does NOT iterate the commodity table. It contains EIGHT inline
 * blocks, each constructing a literal "res_<name>", looking the price up, and
 * storing it under the short key "<name>". Measured live: 8 entries, keyed
 * coffee/cotton/furs/ivory/spices/sugar/tea/tobacco. No data edit can add a
 * ninth - the DB, trade manager, regions, factions and trade routes all carry
 * 9 already and rum still never reaches the UI.
 *
 * So: clone a block. The first one (coffee) is self-contained:
 *
 *   00b1e4bc  LEA ECX,[ESP+0xd8]
 *   00b1e4c3  PUSH 0x12501a0        ; "res_coffee"   <- offset 0x07
 *   00b1e4cf  CALL 0x004b77c0       ; UniString ctor
 *   00b1e4e8  CALL 0x0046e820       ; lookup by name
 *   00b1e54e  CALL 0x009f4520       ; price
 *   00b1e554  PUSH 0x12697a8        ; "coffee"       <- offset 0x98
 *   00b1e560  CALL 0x004419e0       ; store key=value into the prices table
 *   00b1e56c  CALL 0x004b7c10       ; UniString dtor
 *   00b1e571                        ; end - 181 bytes
 *
 * SPLICE at 0x00b1e9a0, immediately after the 8th block's dtor and before the
 * finished table is stored under "prices". EDI/ESI (the commodity table) are
 * intact there because MSVC preserves them across calls, and ESP is identical
 * at both points - pinned by both blocks using LEA ECX,[ESP+0x84] for the
 * prices table, so the block's many ESP-relative locals stay valid.
 *
 * WHY IN MEMORY RATHER THAN IN THE EXE ON DISK: the block contains three
 * ABSOLUTE addresses that the PE loader rebases through the relocation table.
 * A copy written into a file cave would have no .reloc entries, so under ASLR
 * its operands would point at the wrong addresses. Here g_delta is known and
 * every address can simply be written correctly. (The mod already requires this
 * DLL anyway - the crash fix is a runtime patch.)
 */
#define A_ti_block      0x00B1E4BC      /* the coffee block, the one we clone */
#define TI_BLOCK_LEN    0xB5            /* 181 bytes, through the dtor CALL */
#define A_ti_splice     0x00B1E9A0      /* after the 8th block */
#define TI_STEAL        7               /* MOV EAX,[ESP+0x7c] ; SUB ESP,0x14 */

/* Every CALL rel32 inside the block. Recomputed per copy because each copy
 * lives at a different address; the four internal jumps are short and travel
 * with the block, so they need nothing. */
static const int k_ti_calls[] = { 0x13, 0x2C, 0x4F, 0x59, 0x65, 0x8A, 0x92, 0xA4, 0xB0 };
#define TI_OFF_RESNAME  0x07            /* PUSH "res_coffee" -> PUSH "res_<key>" */
#define TI_OFF_KEY      0x98            /* PUSH "coffee"     -> PUSH "<name>"    */

#define TI_MAX_EXTRA    16              /* sanity cap on the config file */
#define TI_STRBUF       64              /* per-string room inside the cave */

static const unsigned char k_ti_splice_bytes[TI_STEAL] = {
    0x8B,0x44,0x24,0x7C, 0x83,0xEC,0x14
};

typedef struct { char key[TI_STRBUF]; char name[TI_STRBUF]; } ti_commodity;

/* Read ese_commodities.txt from beside Empire.exe.
 *   # comments and blank lines are ignored
 *   <db_key> <ui_name>            e.g.   res_rum   rum
 * Returns how many entries were parsed. */
static int ti_read_config(ti_commodity* out, int max) {
    char path[MAX_PATH];
    GetModuleFileNameA(NULL, path, sizeof(path));
    char* slash = strrchr(path, '\\');
    if (!slash) return 0;
    strcpy(slash + 1, "ese_commodities.txt");

    FILE* f = fopen(path, "r");
    if (!f) {
        ese_log("[ti] no ese_commodities.txt beside Empire.exe - no extra commodities");
        return 0;
    }
    int n = 0;
    char line[256];
    while (n < max && fgets(line, sizeof(line), f)) {
        char* p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == ';' || *p == '\r' || *p == '\n' || *p == 0) continue;

        /* Accept commas as separators by turning them into spaces first, then
         * a plain "%s %s" does the rest. (An earlier attempt used a scanset
         * after a space - the space had already eaten the whitespace, so the
         * scanset matched nothing and every line was rejected.) */
        for (char* q = p; *q; q++) if (*q == ',') *q = ' ';

        char a[TI_STRBUF] = {0}, b[TI_STRBUF] = {0};
        if (sscanf(p, "%63s %63s", a, b) != 2) {
            ese_log("[ti] skipping unparseable config line: %s", p);
            continue;
        }
        if (!a[0] || !b[0]) continue;

        /* Directive, not a commodity: how many resources have unit = (none).
         * See apply_raw_resource_count() for why the engine needs telling. */
        if (strcmp(a, "raw_resources") == 0) {
            g_raw_resources = atoi(b);
            continue;
        }

        strncpy(out[n].key,  a, TI_STRBUF - 1);
        strncpy(out[n].name, b, TI_STRBUF - 1);
        n++;
    }
    fclose(f);
    ese_log("[ti] ese_commodities.txt: %d extra commodit%s", n, n == 1 ? "y" : "ies");
    return n;
}

/* Install one cloned block per configured commodity, chained back to back.
 *
 * THE CONFIG FILE IS THE GATE, and that is deliberate. A price whose UI name
 * has no matching component under "world market" makes Find return nil, and
 * UIComponent(nil) raises inside a loop that runs BEFORE the Supply and Exports
 * sections - so a mis-typed name does not merely hide a commodity, it breaks
 * the whole Trade tab. Ship the layout component and the config line together.
 */
static int apply_tradeinfo_extras(void) {
    ti_commodity cfg[TI_MAX_EXTRA];
    int n = ti_read_config(cfg, TI_MAX_EXTRA);
    if (n <= 0) return 0;

    unsigned char* src    = (unsigned char*)(A_ti_block  + g_delta);
    unsigned char* splice = (unsigned char*)(A_ti_splice + g_delta);
    const int ncalls = (int)(sizeof(k_ti_calls) / sizeof(k_ti_calls[0]));

    /* Verify EVERYTHING before writing anything. A half-applied code patch is
     * far worse than none, and a mismatch means this is not the build analysed. */
    if (src[0] != 0x8D) {                      /* LEA ECX,[ESP+0xd8] */
        ese_log("[ti] REFUSING: block does not start with LEA (%02X)", src[0]);
        return 0;
    }
    if (src[TI_OFF_RESNAME] != 0x68 || src[TI_OFF_KEY] != 0x68) {
        ese_log("[ti] REFUSING: expected PUSH imm32 at +%X/+%X, found %02X/%02X",
                TI_OFF_RESNAME, TI_OFF_KEY, src[TI_OFF_RESNAME], src[TI_OFF_KEY]);
        return 0;
    }
    for (int i = 0; i < ncalls; i++) {
        if (src[k_ti_calls[i]] != 0xE8) {
            ese_log("[ti] REFUSING: expected CALL rel32 at block+%X, found %02X",
                    k_ti_calls[i], src[k_ti_calls[i]]);
            return 0;
        }
    }
    if (memcmp(splice, k_ti_splice_bytes, TI_STEAL) != 0) {
        if (splice[0] == 0xE9) { ese_log("[ti] already applied"); return 1; }
        ese_log("[ti] REFUSING: splice site is %02X %02X %02X %02X %02X %02X %02X",
                splice[0], splice[1], splice[2], splice[3], splice[4], splice[5], splice[6]);
        return 0;
    }

    /* Cave: n blocks, then the stolen bytes and the jump home, then the string
     * pool. Strings live in the cave so they need no relocation entries. */
    DWORD codeLen  = (DWORD)n * TI_BLOCK_LEN + TI_STEAL + 5;
    DWORD strBase  = (codeLen + 15) & ~15u;
    DWORD caveSize = strBase + (DWORD)n * 2 * TI_STRBUF;

    unsigned char* cave = (unsigned char*)VirtualAlloc(NULL, caveSize,
                              MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!cave) { ese_log("[ti] cave alloc failed (%lu bytes)", (unsigned long)caveSize); return 0; }
    memset(cave, 0xCC, caveSize);

    for (int i = 0; i < n; i++) {
        unsigned char* blk = cave + (DWORD)i * TI_BLOCK_LEN;
        char* sKey  = (char*)(cave + strBase + (DWORD)i * 2 * TI_STRBUF);
        char* sName = sKey + TI_STRBUF;

        memcpy(blk, src, TI_BLOCK_LEN);

        /* The DB key is the literal the engine looks up; the UI name is the key
         * the Lua side uses to Find the component. Store both in the cave. */
        _snprintf(sKey,  TI_STRBUF - 1, "%s", cfg[i].key);
        _snprintf(sName, TI_STRBUF - 1, "%s", cfg[i].name);

        /* Retarget the two PUSHes. The third absolute (the "In table" assert
         * string at block+0x60) is left alone - it is already the correctly
         * relocated live value. */
        *(DWORD*)(blk + TI_OFF_RESNAME + 1) = (DWORD)sKey;
        *(DWORD*)(blk + TI_OFF_KEY     + 1) = (DWORD)sName;

        /* Each CALL keeps its absolute target, so its displacement shifts by
         * exactly how far THIS copy moved. */
        DWORD shift = (DWORD)src - (DWORD)blk;
        for (int c = 0; c < ncalls; c++)
            *(DWORD*)(blk + k_ti_calls[c] + 1) += shift;

        ese_log("[ti]   block %d: %s -> UI key '%s'", i, cfg[i].key, cfg[i].name);
    }

    /* After the last block: the stolen instructions, then back to the original. */
    unsigned char* tail = cave + (DWORD)n * TI_BLOCK_LEN;
    memcpy(tail, k_ti_splice_bytes, TI_STEAL);
    tail[TI_STEAL] = 0xE9;
    *(DWORD*)(tail + TI_STEAL + 1) =
        (DWORD)(splice + TI_STEAL) - ((DWORD)(tail + TI_STEAL) + 5);

    FlushInstructionCache(GetCurrentProcess(), cave, caveSize);

    DWORD old;
    if (!VirtualProtect(splice, TI_STEAL, PAGE_EXECUTE_READWRITE, &old)) {
        ese_log("[ti] VirtualProtect failed at %p", splice);
        return 0;
    }
    splice[0] = 0xE9;
    *(DWORD*)(splice + 1) = (DWORD)cave - ((DWORD)splice + 5);
    for (int i = 5; i < TI_STEAL; i++) splice[i] = 0x90;   /* pad the remainder */
    VirtualProtect(splice, TI_STEAL, old, &old);
    FlushInstructionCache(GetCurrentProcess(), splice, TI_STEAL);

    ese_log("[ti] %d extra commodit%s wired into TradeInfo: cave=%p (%lu bytes), spliced at %p",
            n, n == 1 ? "y" : "ies", cave, (unsigned long)caveSize, splice);
    return 1;
}

/* ---- the economy accumulator (0x009153A0) -------------------------------
 * DIAGNOSTIC ONLY - reads and logs, changes nothing.
 *
 * With the four out-of-bounds stores NOPped the campaign is stable, but the
 * National Summary still shows garbage: Trade Income -1046798592, which is
 * 0xC19B1F00 - the bit pattern of the FLOAT -19.39. A float has leaked into an
 * integer total, which is what an out-of-range read looks like when the value
 * it lands on happens to be a float.
 *
 * FUN_009153A0 walks commodities `for (i = 0; i != count; i++)` where the count
 * comes from one object field and the DATA from others:
 *
 *   count  = [this + param_11*0x10 + 0x15c]      (9 now that rum exists)
 *   arrayA = [this + param_11*0x10 + 0x160]      (same vector - consistent)
 *   arrayB = [this + 0x130]                      (SEPARATE - suspect)
 *
 * If arrayB was sized from a source we did not extend it still holds 8 entries,
 * and iteration 8 reads whatever follows it. This hook dumps the object's
 * [count][pointer] pairs and the head of each array as both int and float, so
 * the short one names itself.
 *
 * Steal 5: 83 EC 68 53 55 (SUB ESP,0x68; PUSH EBX; PUSH EBP) - whole
 * instructions, no relative branch. ENTRY hook, so ECX is still `this`; it sits
 * at +0x18 in the pushad frame (order EDI,ESI,EBP,ESP,EBX,EDX,ECX,EAX).
 */
#define A_accum  0x009153A0
static const unsigned char kAccumProlog[5] = { 0x83,0xEC,0x68,0x53,0x55 };
static LONG g_accum_seen = 0;

static void dump_array(const char* tag, DWORD ptr, DWORD n) {
    char b[600]; int w = 0;
    for (DWORD i = 0; i < n && w < (int)sizeof(b) - 40; i++) {
        DWORD v = 0;
        if (!safe_rd(ptr + i * 4, &v)) { w += _snprintf(b + w, sizeof(b)-1-w, "%lu:?? ", (unsigned long)i); continue; }
        float f; memcpy(&f, &v, 4);
        /* Print as float too - a plausible small float where an int belongs is
         * the signature of the leak we are chasing. */
        w += _snprintf(b + w, sizeof(b) - 1 - w, "%lu:%ld(%.3g) ",
                       (unsigned long)i, (long)(int)v, (double)f);
    }
    b[w] = 0;
    ese_log("    %s @%08lX: %s", tag, (unsigned long)ptr, b);
}

static void __cdecl on_accum(DWORD* stk) {
    DWORD* regs = (DWORD*)((char*)stk - 0x24);
    DWORD self  = regs[6];                       /* ECX = this */
    if (!self) return;
    /* Log the first TWO calls: FUN_0098A040 calls this twice with param_11 = 0
     * then 1, which selects a DIFFERENT count/array pair (+0x15c vs +0x16c). */
    LONG n = InterlockedIncrement(&g_accum_seen);
    if (n > 4) return;   /* 2 calls per refresh; 4 shows a second pass too */

    ese_log("=== ACCUMULATOR CALL %ld: this=%08lX ===", n, (unsigned long)self);

    /* Every [count][pointer] pair in the object: a small int immediately
     * followed by something that dereferences. That is this engine's vector. */
    for (DWORD off = 0x100; off <= 0x1C0; off += 4) {
        DWORD cnt = 0, ptr = 0, probe = 0;
        if (!safe_rd(self + off, &cnt) || cnt == 0 || cnt > 64) continue;
        if (!safe_rd(self + off + 4, &ptr) || ptr <= 0x10000) continue;
        if (!safe_rd(ptr, &probe)) continue;
        ese_log("  +%lX count=%lu  +%lX array=%08lX",
                (unsigned long)off, (unsigned long)cnt,
                (unsigned long)(off + 4), (unsigned long)ptr);
        dump_array("values", ptr, cnt + 2);      /* +2 to show what follows */
    }

    /* The three offsets the decompile names explicitly, whether or not they
     * matched the pattern above. */
    const DWORD named[] = { 0x12C, 0x15C, 0x16C };
    for (int i = 0; i < 3; i++) {
        DWORD cnt = 0, ptr = 0;
        safe_rd(self + named[i], &cnt);
        safe_rd(self + named[i] + 4, &ptr);
        ese_log("  named +%lX: count=%ld  array=%08lX",
                (unsigned long)named[i], (long)(int)cnt, (unsigned long)ptr);
        if (ptr > 0x10000 && cnt > 0 && cnt <= 64) dump_array("  ->", ptr, cnt + 2);
    }
    /* The income fields FUN_0098A040 works with, on this same object. Call 2's
     * entry therefore shows what call 1 produced. Read in C: the Lua side's
     * string.format('%X') mangles computed addresses (it turned t+8 into t+16),
     * so anything derived that way cannot be trusted. */
    {
        char b[600]; int w = 0;
        for (DWORD off = 0xB0; off <= 0xE8 && w < (int)sizeof(b) - 40; off += 4) {
            DWORD v = 0;
            if (!safe_rd(self + off, &v)) continue;
            float f; memcpy(&f, &v, 4);
            /* Print the float too: a sane float in an int field is the leak. */
            w += _snprintf(b + w, sizeof(b) - 1 - w, "+%lX=%ld(%.4g) ",
                           (unsigned long)off, (long)(int)v, (double)f);
        }
        b[w] = 0;
        ese_log("  income fields: %s", b);
    }
    /* THE ARGUMENTS, read off the stack instead of inferred. This is an ENTRY
     * hook and nothing has been pushed yet, so the frame is exactly:
     *   stk[0] = return address, stk[1] = param_2 ... stk[10] = param_11.
     * Guessing these from `this` produced a dump of unrelated memory once
     * already (assuming ECX == FUN_0098A040's param_1, never verified). */
    ese_log("  ret=%08lX  param_11=%lu  (0 = object-member call, 1 = STACK-buffer call)",
            (unsigned long)(stk[0] - g_delta), (unsigned long)(stk[10] & 0xFF));

    DWORD p2 = stk[1], p3 = stk[2], p4 = stk[3];
    ese_log("  param_2=%08lX param_3=%08lX param_4=%08lX  (p3-p2=%ld, p4-p3=%ld)",
            (unsigned long)p2, (unsigned long)p3, (unsigned long)p4,
            (long)(p3 - p2), (long)(p4 - p3));

    /* param_2 holds 14 pairs = indices 0..27, zeroed at function entry. Print
     * 30 so the out-of-bounds pair 14 (indices 28/29) is visible too - that is
     * the pair the lookup writes when it finds no match, and on the param_11=1
     * call index 29 IS this caller's return address. */
    {
        const DWORD bufs[3] = { p2, p3, p4 };
        const char* nm[3] = { "param_2", "param_3", "param_4" };
        const int  cnt[3] = { 30, 30, 9 };
        for (int k = 0; k < 3; k++) {
            if (!bufs[k]) continue;
            char b[900]; int w = 0;
            for (int i = 0; i < cnt[k] && w < (int)sizeof(b) - 24; i++) {
                DWORD v = 0;
                if (!safe_rd(bufs[k] + i * 4, &v)) break;
                w += _snprintf(b + w, sizeof(b) - 1 - w, "%ld ", (long)(int)v);
            }
            b[w] = 0;
            ese_log("  %s[%d..]: %s", nm[k], 0, b);
        }
    }

    /* The REAL running totals: *param_6 and *param_7 are incremented every
     * iteration by instructions the NOP patch did not touch. If trade income is
     * garbage, it is garbage here or it is not this function's doing. */
    {
        DWORD v6 = 0, v7 = 0, v9 = 0;
        if (safe_rd(stk[5], &v6) && safe_rd(stk[6], &v7)) {
            float f6, f7; memcpy(&f6, &v6, 4); memcpy(&f7, &v7, 4);
            ese_log("  *param_6=%ld(%.6g)  *param_7=%ld(%.6g)",
                    (long)(int)v6, (double)f6, (long)(int)v7, (double)f7);
        }
        if (safe_rd(stk[8], &v9)) {
            float f9; memcpy(&f9, &v9, 4);
            ese_log("  *param_9=%ld(%.6g)", (long)(int)v9, (double)f9);
        }
    }
    ese_log("=== ACCUMULATOR DUMP END ===");
}

/* ---- the vector push_back that crashes on the Trade tab (0x004B3A20) -----
 * DIAGNOSTIC ONLY - reads and logs, changes nothing.
 *
 * Layout: [this+0]=data  [this+4]=size  [this+8]=capacity  [this+0xc]=allocator
 *
 *   004b3a24:  MOV EAX,[EDI+8]      ; capacity
 *   004b3a27:  MOV EBX,[EDI+4]      ; size
 *   004b3a2a:  CMP EBX,EAX
 *   004b3a2c:  JNZ 0x004b3a85       ; room left -> straight to the append
 *   004b3a2e:  ADD EAX,EAX          ; else capacity *= 2 and reallocate
 *   004b3a4f:  CALL 0x004b2410      ; allocate(capacity)
 *   004b3a94:  MOV [EAX+EBX*4],ECX  ; CRASHED here with EAX = 0
 *
 * EAX=0 means the data pointer was NULL. Only two states reach that:
 *   (a) capacity != 0 but data == NULL  - an inconsistent/corrupted vector, or
 *   (b) the grow path ran and allocate() returned NULL - an absurd capacity.
 * This hook distinguishes them, and logs the TRUE return address from [ESP],
 * which the fault report cannot give (its "candidates" are stale stack words).
 *
 * WHY THE CALLER MATTERS: this vector is generic - 14 call sites - and the one
 * that crashed sits in the interned STRING POOL code (FUN_004b9f70, which
 * HeapAllocs a bigger pool and relocates every pointer into it). The UniString
 * constructor FUN_004b77c0 is also a caller. So this is very likely about
 * string-pool capacity, NOT about the trade arithmetic.
 *
 * Steal 7: 53 57 8B F9 8B 47 08 (PUSH EBX; PUSH EDI; MOV EDI,ECX;
 * MOV EAX,[EDI+8]) - whole instructions, no relative branch. ENTRY hook, so
 * ECX is still `this` (pushad slot +0x18) and stk[0] is the return address.
 *
 * PERFORMANCE: this runs on every string construction, so the handler must be
 * nearly free. safe_rd() calls VirtualQuery and is FAR too slow here; instead
 * we range-check the pointer and read directly - exactly what the hooked code
 * itself does two instructions later, so it is no less safe than the original.
 */
#define A_vec_push  0x004B3A20
static const unsigned char kVecPushProlog[7] = { 0x53,0x57,0x8B,0xF9,0x8B,0x47,0x08 };

/* ===================== PROJECTILE IMPACT PROBE ===========================
 * FUN_00D0C5B0 - found via the debug string "\nPROJECTILE IMPACT: Target",
 * which sits inside it. Signature from Ghidra:
 *
 *   FUN_00d0c5b0(int *p1, uint *p2, int *p3, int *p4, char p5, int *p6)
 *   ... (**(code **)*p3)()  ->  unit class  (0 Fixed Artillery, 4 Heavy
 *                               Cavalry, 0x13 Melee Infantry, 0x14 Militia,
 *                               0x19 Brig, 0x1c 1st Rate, ...)
 *
 * WHY THIS SITE MATTERS
 *   Empire's 208-function battle API is entirely UNIT-level - nothing in it
 *   mentions a soldier or an entity. This function, by contrast, is handed a
 *   concrete target every time a shot lands. If those targets turn out to be
 *   individual men it is the per-soldier handle the whole first-person idea
 *   needs; if they are units, that is equally worth knowing before building
 *   on the assumption.
 *
 * THE QUESTION THIS PROBE ANSWERS
 *   Are the pointers distinct per MAN, or one per UNIT? Volleys hit many men
 *   of the same unit, so: record distinct p3 values with their class, and see
 *   whether a single unit under fire produces many pointers or one.
 *
 * LOG ONLY, AND THROTTLED. This fires on every impact in a battle -
 * potentially thousands per second - so it records only pointers it has not
 * seen, caps the table, and never calls back into the engine. The class is
 * read by re-issuing the same virtual call the function itself makes, which
 * is safe only because the function is about to do exactly that.
 *
 * The prologue is 55 8B EC 83 E4 C0 = push ebp / mov ebp,esp / and esp,-64.
 * Six bytes, NOT five: a 5-byte steal would split `83 E4 C0` and corrupt the
 * stack alignment the function relies on. */
#define A_impact 0x00D0C5B0
static const unsigned char kImpactProlog[6] = { 0x55,0x8B,0xEC,0x83,0xE4,0xC0 };

#define IMPACT_MAX 48
#define IMPACT_SNAP   0x100      /* bytes captured per target */
#define IMPACT_SNAP_N 4          /* how many targets get a snapshot */
static BYTE   g_imp_snap[IMPACT_SNAP_N][IMPACT_SNAP];
static BYTE   g_imp_snapped[IMPACT_SNAP_N];
static DWORD  g_imp_seen[IMPACT_MAX];
static DWORD  g_imp_cls [IMPACT_MAX];
static LONG   g_imp_n     = 0;
static LONG   g_imp_total = 0;
static LONG   g_imp_probe = 0;      /* off until armed from Lua */

static void __cdecl on_impact(DWORD* stk) {
    if (!g_imp_probe) return;
    InterlockedIncrement(&g_imp_total);
    DWORD tgt = stk[3];                     /* p3: retaddr, p1, p2, p3 */
    if (!tgt || !mem_readable((void*)tgt, 4)) return;
    for (int i = 0; i < g_imp_n; i++) if (g_imp_seen[i] == tgt) return;
    if (g_imp_n >= IMPACT_MAX) return;

    DWORD cls = 0xFFFFFFFF;
    DWORD vt = *(DWORD*)tgt;                /* the vtable */
    if (mem_readable((void*)vt, 4)) {
        DWORD fn = *(DWORD*)vt;             /* vtable[0] = class getter */
        if (mem_executable((void*)fn)) {
            if (InterlockedCompareExchange(&g_prot_busy, 1, 0) == 0) {
                if (setjmp(g_prot_jmp) == 0) {
                    g_guard_use_prot = 1; g_guard_armed = 1;
                    cls = ((DWORD (__thiscall *)(DWORD))fn)(tgt);
                }
                g_guard_armed = 0; g_guard_use_prot = 0;
                InterlockedExchange(&g_prot_busy, 0);
            }
        }
    }
    int i = g_imp_n++;
    g_imp_seen[i] = tgt;
    g_imp_cls[i]  = cls;

    /* SNAPSHOT THE BYTES NOW, while the pointer is certainly live.
     * Reading a recorded target minutes later returned freed, reused memory -
     * the giveaway was +0x00 == 0, impossible for an object whose vtable this
     * very handler dereferences. A pointer captured here is only meaningful
     * here. */
    if (i < IMPACT_SNAP_N && mem_readable((void*)tgt, IMPACT_SNAP)) {
        memcpy(g_imp_snap[i], (void*)tgt, IMPACT_SNAP);
        g_imp_snapped[i] = 1;
    }
    ese_log("[impact] #%d target=%08lX class=%ld  p1=%08lX p2=%08lX p4=%08lX p6=%08lX",
            i, (unsigned long)tgt, (long)cls,
            (unsigned long)stk[1], (unsigned long)stk[2],
            (unsigned long)stk[4], (unsigned long)stk[6]);
}

/* ===================== D3D9 RENDER INTERCEPTION ==========================
 * Frame timing now; the foundation for stereo later.
 *
 * WHY NO SECOND PROXY DLL
 *   `d3d9.dll` is a STATIC IMPORT of Empire.exe, so a `d3d9.dll` proxy beside
 *   the exe would work - but ESE is already in the process, so hooking
 *   Direct3DCreate9 in the real d3d9 and then patching COM vtables reaches the
 *   same place with one DLL instead of two, and no export-forwarding table to
 *   keep in sync.
 *
 * VTABLE INDICES (d3d9.h, stable since 2004)
 *   IDirect3D9::CreateDevice        = 16
 *   IDirect3DDevice9::Present       = 17
 *   IDirect3DDevice9::Reset         = 16
 *
 * WHY THIS IS THE RIGHT FIRST MEASUREMENT
 *   VR needs 72-90 fps IN STEREO, which roughly doubles GPU cost. Empire is
 *   32-bit and largely CPU-bound. Whether a skirmish holds ~90 fps flat is the
 *   single fact that decides whether VR is reachable on this engine, and
 *   Present is where that number actually lives - not in an overlay that
 *   measures its own compositor.
 *
 * ONLY Present IS HOOKED. Stereo needs the view/projection matrices, which on
 * this engine arrive as VERTEX SHADER CONSTANTS (it uses SM3), i.e.
 * SetVertexShaderConstantF - NOT SetTransform, which a fixed-function game
 * would use. That index must be VERIFIED against d3d9.h before it is hooked;
 * guessing a vtable slot corrupts an unrelated call. */
typedef void* (__stdcall *fn_d3dcreate9)(unsigned int);
typedef long  (__stdcall *fn_createdevice)(void*, unsigned int, unsigned int, void*,
                                           unsigned long, void*, void**);
typedef long  (__stdcall *fn_present)(void*, const void*, const void*, void*, const void*);

static fn_d3dcreate9   o_d3dcreate9  = NULL;
static fn_createdevice o_createdevice = NULL;
static fn_present      o_present      = NULL;

static LONG      g_frames     = 0;
static LONG64    g_fps_qpc    = 0;
static LONG64    g_qpf        = 0;
static double    g_fps_last   = 0.0;
static double    g_fps_min    = 0.0;
static double    g_fps_max    = 0.0;
static LONG      g_fps_probe  = 0;

/* Replace one vtable slot, restoring page protection afterwards. */
static void* patch_vtable(void* obj, int index, void* hook) {
    void** vt = *(void***)obj;
    DWORD old;
    if (!VirtualProtect(&vt[index], sizeof(void*), PAGE_EXECUTE_READWRITE, &old)) return NULL;
    void* prev = vt[index];
    vt[index] = hook;
    VirtualProtect(&vt[index], sizeof(void*), old, &old);
    return prev;
}

/* ============== DirectInput interception - synthetic input =============== *
 * MEASURED 2026-09-22: posting WM_KEYDOWN does NOT move Empire's camera. A
 * held arrow key produced LESS movement than a do-nothing control (idle drift
 * alone), so the camera does not read the window message queue - it reads
 * DirectInput. That is unsurprising: this DLL exists because Empire imports
 * dinput8, and it is also why `@nat mouse` works for UI clicks but not for
 * the camera - the UI is message-driven, the camera is not.
 *
 * Since we ARE dinput8.dll, the device is reachable: wrap the interfaces on
 * the way out and OR our synthetic key state into what the game reads. Same
 * COM vtable-patch technique already proven here for IDirect3DDevice9.
 *
 * IDirectInputDevice8 vtable: IUnknown 0-2, GetCapabilities 3, EnumObjects 4,
 * GetProperty 5, SetProperty 6, Acquire 7, Unacquire 8, GetDeviceState 9,
 * GetDeviceData 10, SetDataFormat 11, ...
 * IDirectInput8 vtable:       IUnknown 0-2, CreateDevice 3, EnumDevices 4, ...
 *
 * KEYS ARE DIK SCAN CODES HERE, NOT VK CODES (DIK_W = 0x11, DIK_UP = 0xC8). */
typedef HRESULT (__stdcall *fn_getdevstate)(void*, DWORD, void*);
typedef HRESULT (__stdcall *fn_di_createdevice)(void*, const void*, void**, void*);

static fn_getdevstate     o_getdevstate     = NULL;
static fn_di_createdevice o_createdevice_di = NULL;
static BYTE               g_synthkey[256];
static volatile LONG      g_synth_on   = 0;
static LONG               g_di_devices = 0;
static LONG               g_di_kbpolls = 0;

/* Real input capture for the first-person control layer. g_kbreal is the last
 * keyboard snapshot the GAME itself received (after any synthetic merge, so
 * Lua sees exactly what the game sees). Mouse deltas accumulate between reads
 * and are drained by ESE_Input - a dropped frame must not make the view lurch. */
static BYTE               g_kbreal[256];
static volatile LONG      g_mb  = 0;
static volatile LONG      g_mdx = 0, g_mdy = 0, g_mdz = 0;
static LONG               g_di_mpolls = 0;
static volatile LONG      g_look_on = 0;   /* mouselook: recentre the cursor each read */
static int                g_lastmx = 0, g_lastmy = 0, g_lastvalid = 0;

/* First-person presentation state. The Lua rig owns the mode switch; native
 * code owns the two things Lua cannot do reliably: drawing after Empire's HUD
 * and balancing Win32's cursor display counter. */
static volatile LONG      g_fp_view = 0;
static LONG               g_cursor_hide_steps = 0;
static volatile LONG      g_crosshair_attempts = 0;
static volatile LONG      g_crosshair_vp_hr = 0;
static volatile LONG      g_crosshair_rt_hr = 0;
static volatile LONG      g_crosshair_rim_hr = 0;
static volatile LONG      g_crosshair_dot_hr = 0;
static volatile LONG      g_crosshair_cx = 0, g_crosshair_cy = 0;
static void d3d_rehook_present(void);

static void fp_cursor_hide(void) {
    if (g_cursor_hide_steps) return;
    /* ShowCursor is a counter, not a boolean. Remember every decrement so the
     * exact pre-FP state can be restored instead of guessing that zero was it. */
    for (int i = 0; i < 32; i++) {
        int n = ShowCursor(FALSE);
        g_cursor_hide_steps++;
        if (n < 0) break;
    }
    g_lastvalid = 0;
}

static void fp_cursor_restore(void) {
    while (g_cursor_hide_steps > 0) {
        ShowCursor(TRUE);
        g_cursor_hide_steps--;
    }
    g_lastvalid = 0;
}

static HRESULT __stdcall hk_getdevstate(void* dev, DWORD cb, void* data) {
    HRESULT hr = o_getdevstate(dev, cb, data);
    /* A 256-byte state buffer is the keyboard format; mouse state is a much
     * smaller struct, so size alone separates them without tracking devices. */
    if (hr == 0 && cb == 256 && data) {
        InterlockedIncrement(&g_di_kbpolls);
        if (g_synth_on) {
            BYTE* k = (BYTE*)data;
            for (int i = 0; i < 256; i++) if (g_synthkey[i]) k[i] |= 0x80;
        }
        memcpy(g_kbreal, data, 256);
    }
    /* DIMOUSESTATE is 16 bytes, DIMOUSESTATE2 is 20: 3 LONG axes then buttons. */
    else if (hr == 0 && data && (cb == 16 || cb == 20)) {
        const LONG* ax = (const LONG*)data;
        const BYTE* bt = (const BYTE*)data + 12;
        int nb = (cb == 16) ? 4 : 8;
        LONG mask = 0;
        for (int i = 0; i < nb; i++) if (bt[i] & 0x80) mask |= (1L << i);
        InterlockedExchange(&g_mb, mask);
        InterlockedExchangeAdd(&g_mdx, ax[0]);
        InterlockedExchangeAdd(&g_mdy, ax[1]);
        InterlockedExchangeAdd(&g_mdz, ax[2]);
        InterlockedIncrement(&g_di_mpolls);
    }
    return hr;
}

/* ESE_Input()     -> "<buttonmask> <dx> <dy> <dz> <kbpolls> <mpolls>"
 * ESE_Input("11") -> "1"/"0" for that DIK scan code being held.
 * Mouse deltas are drained on every no-argument read. */
static int __cdecl ese_input(lua_State* L) {
    const char* which = L_.tolstring(L, 1, NULL);
    if (which && which[0]) {
        if (strcmp(which, "look1") == 0) { g_look_on = 1; g_lastvalid = 0; push_str(L, "look on");  return 1; }
        if (strcmp(which, "look0") == 0) { g_look_on = 0; g_lastvalid = 0; push_str(L, "look off"); return 1; }
        unsigned dik = (unsigned)strtoul(which, NULL, 16);
        push_str(L, (dik < 256 && (g_kbreal[dik] & 0x80)) ? "1" : "0");
        return 1;
    }
    /* Empire never calls GetDeviceState for the mouse (mpolls stays 0), so the
     * DirectInput hook cannot see it. Read it ourselves instead - this works
     * whether the game uses buffered DI data or plain window messages. */
    LONG mask = 0;
    if (GetAsyncKeyState(0x01) & 0x8000) mask |= 1;   /* VK_LBUTTON */
    if (GetAsyncKeyState(0x02) & 0x8000) mask |= 2;   /* VK_RBUTTON */
    if (GetAsyncKeyState(0x04) & 0x8000) mask |= 4;   /* VK_MBUTTON */

    LONG dx = 0, dy = 0;
    POINT pt;
    if (GetCursorPos(&pt)) {
        if (g_lastvalid) { dx = pt.x - g_lastmx; dy = pt.y - g_lastmy; }
        g_lastmx = pt.x; g_lastmy = pt.y; g_lastvalid = 1;
        /* In mouselook, recentre so the pointer can never reach a screen edge
         * and silently clamp the delta to zero mid-turn. */
        if (g_look_on) {
            int cx = GetSystemMetrics(0) / 2, cy = GetSystemMetrics(1) / 2;
            if (pt.x != cx || pt.y != cy) {
                SetCursorPos(cx, cy);
                g_lastmx = cx; g_lastmy = cy;
            }
        }
    }
    LONG dz = InterlockedExchange(&g_mdz, 0);
    char b[128];
    _snprintf(b, sizeof(b) - 1, "%ld %ld %ld %ld %ld %ld",
              (long)mask, (long)dx, (long)dy, (long)dz,
              (long)g_di_kbpolls, (long)g_di_mpolls);
    b[127] = 0;
    push_str(L, b);
    return 1;
}

/* ESE_View("on"|"off"|"status")
 *
 * One switch keeps the native overlay, cursor visibility and Lua camera mode
 * coherent. It deliberately does not decide whether the hooked man is valid;
 * the Lua side performs that ownership/liveness gate before entering FP. */
static int __cdecl ese_view(lua_State* L) {
    const char* cmd = L_.tolstring(L, 1, NULL);
    if (cmd && (strcmp(cmd, "on") == 0 || strcmp(cmd, "1") == 0)) {
        InterlockedExchange(&g_fp_view, 1);
        fp_cursor_hide();
        /* A battle load resets D3D9 and may replace the additional swapchain.
         * Reacquire its Present slot at the moment FP needs frame callbacks. */
        d3d_rehook_present();
    } else if (cmd && (strcmp(cmd, "off") == 0 || strcmp(cmd, "0") == 0)) {
        InterlockedExchange(&g_fp_view, 0);
        fp_cursor_restore();
    } else if (cmd && strcmp(cmd, "status") != 0) {
        push_str(L, "ESE_View(\"on\"|\"off\"|\"status\")");
        return 1;
    }
    char b[224];
    _snprintf(b, sizeof(b)-1,
              "view=%s crosshair=%s cursorHideSteps=%ld draws=%ld vp=%08lX rt=%08lX clear=%08lX/%08lX center=%ld,%ld",
              g_fp_view ? "on" : "off", g_fp_view ? "on" : "off",
              (long)g_cursor_hide_steps, (long)g_crosshair_attempts,
              (unsigned long)g_crosshair_vp_hr,
              (unsigned long)g_crosshair_rt_hr,
              (unsigned long)g_crosshair_rim_hr,
              (unsigned long)g_crosshair_dot_hr,
              (long)g_crosshair_cx, (long)g_crosshair_cy);
    b[223] = 0;
    push_str(L, b);
    return 1;
}

static HRESULT __stdcall hk_createdevice_di(void* self, const void* guid,
                                            void** out, void* aggr) {
    HRESULT hr = o_createdevice_di(self, guid, out, aggr);
    if (hr == 0 && out && *out && !o_getdevstate) {
        void* prev = patch_vtable(*out, 9, (void*)hk_getdevstate);
        if (prev) {
            o_getdevstate = (fn_getdevstate)prev;
            ese_log("[di] device %p: GetDeviceState hooked (orig %p)", *out, prev);
        }
    }
    if (hr == 0) InterlockedIncrement(&g_di_devices);
    return hr;
}

/* ---- paced synthetic input -------------------------------------------------
 * A DRAG cannot be posted as a burst. Empire is a message-pump game: it reads
 * the queue once per frame, so a down/move/move/up posted together is seen as
 * a single jump and the slider handle never tracks. Each step must land on a
 * DIFFERENT frame, and Present is the only place that knows where a frame
 * boundary is.
 *
 * This matters specifically because Empire's scrollbars are DRAG-ONLY -
 * template.vslider_handle.lua reads the handle's own Position() and converts
 * it to a value, and neither slider template has any wheel handler at all. So
 * a VR "touch and scroll" gesture has to become a real drag. */
/* Declared here rather than beside CreateDevice: the frame pump below needs
 * it and runs earlier in the file. */
static HWND g_hwnd = NULL;
static void* g_d3ddev = NULL;

typedef struct { UINT msg; WPARAM wp; int x, y; } inj_ev;
#define INJ_MAX 64
static inj_ev g_inj[INJ_MAX];
static LONG   g_inj_head = 0, g_inj_tail = 0;

static void inj_push(UINT msg, WPARAM wp, int x, int y) {
    LONG n = (g_inj_tail + 1) % INJ_MAX;
    if (n == g_inj_head) return;                 /* full: drop, never block */
    g_inj[g_inj_tail].msg = msg; g_inj[g_inj_tail].wp = wp;
    g_inj[g_inj_tail].x = x;     g_inj[g_inj_tail].y = y;
    g_inj_tail = n;
}

/* One event per frame. */
static void inj_pump(void) {
    if (g_inj_head == g_inj_tail || !g_hwnd) return;
    inj_ev* e = &g_inj[g_inj_head];
    PostMessageW(g_hwnd, e->msg, e->wp, (LPARAM)((e->y << 16) | (e->x & 0xFFFF)));
    g_inj_head = (g_inj_head + 1) % INJ_MAX;
}

static fn_present o_sc_present = NULL;

/* A crosshair dot through IDirect3DDevice9::Clear needs no shaders, buffers,
 * textures or render-state changes. Two tiny rectangles produce a black rim
 * and white centre at the actual viewport centre, including non-native game
 * resolutions and letterboxed modes.
 *
 * IDirect3DDevice9 vtable: Clear=43, GetViewport=48. */
typedef struct {
    DWORD X, Y, Width, Height;
    float MinZ, MaxZ;
} ese_d3dviewport9;
typedef struct { LONG x1, y1, x2, y2; } ese_d3drect;

static void fp_draw_crosshair(void* dev) {
    if (!dev || !g_fp_view) return;
    typedef long (__stdcall *fn_clear)(void*, DWORD, const void*, DWORD, DWORD, float, DWORD);
    typedef long (__stdcall *fn_getviewport)(void*, void*);
    typedef long (__stdcall *fn_setviewport)(void*, const void*);
    typedef long (__stdcall *fn_getbackbuffer)(void*, UINT, UINT, UINT, void**);
    typedef long (__stdcall *fn_getrendertarget)(void*, DWORD, void**);
    typedef long (__stdcall *fn_setrendertarget)(void*, DWORD, void*);
    typedef unsigned long (__stdcall *fn_rel)(void*);
    void** vt = *(void***)dev;
    fn_clear clear = (fn_clear)vt[43];
    fn_getviewport getviewport = (fn_getviewport)vt[48];
    fn_setviewport setviewport = (fn_setviewport)vt[47];
    fn_getbackbuffer getbackbuffer = (fn_getbackbuffer)vt[18];
    fn_getrendertarget getrendertarget = (fn_getrendertarget)vt[38];
    fn_setrendertarget setrendertarget = (fn_setrendertarget)vt[37];
    if (!clear || !getviewport || !setviewport || !getbackbuffer ||
        !getrendertarget || !setrendertarget) return;
    InterlockedIncrement(&g_crosshair_attempts);
    ese_d3dviewport9 oldvp, vp;
    long vphr = getviewport(dev, &oldvp);
    InterlockedExchange(&g_crosshair_vp_hr, vphr);
    if (vphr < 0) return;

    /* At Present, Empire still has its post-processing surface bound. Clear on
     * that surface succeeds but is invisible because it has already been copied
     * to the swapchain. Temporarily bind the real backbuffer, stamp the dot,
     * then restore both target and viewport exactly. */
    void* oldrt = NULL;
    void* backbuffer = NULL;
    long oldhr = getrendertarget(dev, 0, &oldrt);
    long bbhr = getbackbuffer(dev, 0, 0, 0 /* D3DBACKBUFFER_TYPE_MONO */, &backbuffer);
    if (oldhr < 0 || bbhr < 0 || !oldrt || !backbuffer) {
        if (oldrt) ((fn_rel)(*(void***)oldrt)[2])(oldrt);
        if (backbuffer) ((fn_rel)(*(void***)backbuffer)[2])(backbuffer);
        InterlockedExchange(&g_crosshair_rt_hr, oldhr < 0 ? oldhr : bbhr);
        return;
    }
    long rthr = setrendertarget(dev, 0, backbuffer);
    InterlockedExchange(&g_crosshair_rt_hr, rthr);
    if (rthr < 0) {
        ((fn_rel)(*(void***)backbuffer)[2])(backbuffer);
        ((fn_rel)(*(void***)oldrt)[2])(oldrt);
        return;
    }
    vphr = getviewport(dev, &vp);
    InterlockedExchange(&g_crosshair_vp_hr, vphr);
    if (vphr < 0 || vp.Width < 8 || vp.Height < 8) {
        setrendertarget(dev, 0, oldrt);
        setviewport(dev, &oldvp);
        ((fn_rel)(*(void***)backbuffer)[2])(backbuffer);
        ((fn_rel)(*(void***)oldrt)[2])(oldrt);
        return;
    }
    LONG cx = (LONG)vp.X + (LONG)vp.Width / 2;
    LONG cy = (LONG)vp.Y + (LONG)vp.Height / 2;
    InterlockedExchange(&g_crosshair_cx, cx);
    InterlockedExchange(&g_crosshair_cy, cy);
    ese_d3drect rim = { cx-3, cy-3, cx+4, cy+4 };
    ese_d3drect dot = { cx-1, cy-1, cx+2, cy+2 };
    long rimhr = clear(dev, 1, &rim, 1 /* D3DCLEAR_TARGET */, 0xFF000000u, 1.0f, 0);
    long dothr = clear(dev, 1, &dot, 1 /* D3DCLEAR_TARGET */, 0xFFFFFFFFu, 1.0f, 0);
    InterlockedExchange(&g_crosshair_rim_hr, rimhr);
    InterlockedExchange(&g_crosshair_dot_hr, dothr);
    setrendertarget(dev, 0, oldrt);
    setviewport(dev, &oldvp);
    ((fn_rel)(*(void***)backbuffer)[2])(backbuffer);
    ((fn_rel)(*(void***)oldrt)[2])(oldrt);
}

/* Shared by both present paths: whichever one Empire actually uses drives the
 * frame counter and the paced input queue. */
static void on_frame(void) {
    inj_pump();
    if (g_fp_view) {
        /* Empire may answer WM_SETCURSOR after the transition. Keep the active
         * cursor null without touching ShowCursor's balanced counter again. */
        if (!g_hwnd || GetForegroundWindow() == g_hwnd) SetCursor(NULL);
        fp_draw_crosshair(g_d3ddev);
    }
    if (!g_fps_probe) return;
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    g_frames++;
    if (g_fps_qpc == 0) { g_fps_qpc = now.QuadPart; return; }
    LONG64 dt = now.QuadPart - g_fps_qpc;
    if (g_qpf && dt >= g_qpf) {
        double fps = (double)g_frames * (double)g_qpf / (double)dt;
        g_fps_last = fps;
        if (g_fps_min == 0.0 || fps < g_fps_min) g_fps_min = fps;
        if (fps > g_fps_max) g_fps_max = fps;
        ese_log("[fps] %.1f  (min %.1f  max %.1f)", fps, g_fps_min, g_fps_max);
        g_frames = 0;
        g_fps_qpc = now.QuadPart;
    }
}

static long __stdcall hk_sc_present(void* sc, const void* a, const void* b, void* c, const void* d) {
    on_frame();
    return o_sc_present(sc, a, b, c, d);
}

static long __stdcall hk_present(void* dev, const void* a, const void* b, void* c, const void* d) {
    /* Empire normally presents through its swapchain, but keep the device path
     * behavior identical for drivers/configurations that use this method. */
    on_frame();
    return o_present(dev, a, b, c, d);
}

static void d3d_rehook_present(void) {
    if (!g_d3ddev) return;
    void** dvt = *(void***)g_d3ddev;
    if (dvt[17] != (void*)hk_present) {
        void* prev = patch_vtable(g_d3ddev, 17, (void*)hk_present);
        if (prev && prev != (void*)hk_present) o_present = (fn_present)prev;
        ese_log("[d3d9] device Present rehooked (orig %p)", prev);
    }

    typedef long (__stdcall *fn_getsc)(void*, UINT, void**);
    typedef unsigned long (__stdcall *fn_rel)(void*);
    fn_getsc getsc = (fn_getsc)dvt[14];
    void* sc = NULL;
    if (!getsc || getsc(g_d3ddev, 0, &sc) < 0 || !sc) return;
    void** svt = *(void***)sc;
    if (svt[3] != (void*)hk_sc_present) {
        void* prev = patch_vtable(sc, 3, (void*)hk_sc_present);
        if (prev && prev != (void*)hk_sc_present) o_sc_present = (fn_present)prev;
        ese_log("[d3d9] swapchain %p Present rehooked (orig %p)", sc, prev);
    }
    ((fn_rel)(*(void***)sc)[2])(sc);
}

/* The REAL register budget. vs_3_0 guarantees 256 float4 vertex constants,
 * but that is a MINIMUM - a driver may report more, which would loosen the
 * bones-vs-instances budget in weighted.fx. Measure it rather than assume.
 * D3DCAPS9: VertexShaderVersion at +196, MaxVertexShaderConst at +200,
 * PixelShaderVersion at +204. GetDeviceCaps is IDirect3DDevice9 vtable 7. */
static int __cdecl ese_caps(lua_State* L) {
    if (!g_d3ddev) { push_str(L, "no D3D9 device yet"); return 1; }
    typedef long (__stdcall *fn_getcaps)(void*, void*);
    void** vt = *(void***)g_d3ddev;
    fn_getcaps getcaps = (fn_getcaps)vt[7];
    static unsigned char caps[1024];
    memset(caps, 0, sizeof(caps));
    long hr = getcaps(g_d3ddev, caps);
    if (hr < 0) { push_str(L, "GetDeviceCaps failed"); return 1; }
    unsigned vsver  = *(unsigned*)(caps + 196);
    unsigned vsmax  = *(unsigned*)(caps + 200);
    unsigned psver  = *(unsigned*)(caps + 204);
    unsigned blend  = *(unsigned*)(caps + 168);
    unsigned streams= *(unsigned*)(caps + 188);
    char b[256];
    _snprintf(b, sizeof(b)-1,
        "MaxVertexShaderConst=%u vs=%u.%u ps=%u.%u MaxVertexBlendMatrices=%u MaxStreams=%u",
        vsmax, (vsver >> 8) & 0xFF, vsver & 0xFF,
        (psver >> 8) & 0xFF, psver & 0xFF, blend, streams);
    b[255] = 0;
    push_str(L, b);
    return 1;
}

static long __stdcall hk_createdevice(void* self, unsigned int adapter, unsigned int devtype,
                                      void* hwnd, unsigned long flags, void* pp, void** out) {
    long hr = o_createdevice(self, adapter, devtype, hwnd, flags, pp, out);
    if (hr >= 0 && out && *out && !o_present) {
        g_d3ddev = *out;   /* kept so GetDeviceCaps can be queried from Lua */
        o_present = (fn_present)patch_vtable(*out, 17, (void*)hk_present);
        /* The focus window comes free here, and it is what synthetic input
         * must be posted to. Empire has no SetCursorPos/GetCursorPos import -
         * it takes mouse position from WINDOW MESSAGES (PeekMessageW /
         * DispatchMessageW, TrackMouseEvent, SetCapture) - so PostMessage is
         * the right injection point, not the OS cursor. */
        g_hwnd = (HWND)hwnd;
        if (!g_hwnd && pp) g_hwnd = *(HWND*)((BYTE*)pp + 8);  /* pp->hDeviceWindow */
        ese_log("[d3d9] device %p created; Present hooked (orig %p); hwnd=%p",
                *out, o_present, g_hwnd);

        /* EMPIRE DOES NOT PRESENT THROUGH THE DEVICE.
         * Proven live: this whole chain installed correctly and Present was
         * never called once, with the window confirmed foreground and visible.
         * The engine presents through its SWAP CHAIN, so hook that too.
         *
         * IDirect3DDevice9::GetSwapChain      = vtable 14
         * IDirect3DSwapChain9::Present        = vtable 3
         * Index 3 is safe by construction: IUnknown occupies 0-2, so Present
         * is the first interface method. */
        void** dvt = *(void***)(*out);
        typedef long (__stdcall *fn_getsc)(void*, UINT, void**);
        typedef unsigned long (__stdcall *fn_rel)(void*);
        fn_getsc getsc = (fn_getsc)dvt[14];
        void* sc = NULL;
        if (getsc && getsc(*out, 0, &sc) >= 0 && sc) {
            o_sc_present = (fn_present)patch_vtable(sc, 3, (void*)hk_sc_present);
            ese_log("[d3d9] swapchain %p; Present hooked (orig %p)", sc, o_sc_present);
            /* The device keeps its own reference; drop ours so nothing leaks.
             * The vtable patch is per-class and survives the release. */
            ((fn_rel)(*(void***)sc)[2])(sc);
        } else {
            ese_log("[d3d9] GetSwapChain failed - only the device Present is hooked");
        }
    }
    return hr;
}

static void* __stdcall hk_d3dcreate9(unsigned int sdk) {
    void* d3d = o_d3dcreate9(sdk);
    if (d3d && !o_createdevice) {
        o_createdevice = (fn_createdevice)patch_vtable(d3d, 16, (void*)hk_createdevice);
        ese_log("[d3d9] IDirect3D9 %p; CreateDevice hooked (orig %p)", d3d, o_createdevice);
    }
    return d3d;
}

/* Redirect Direct3DCreate9 by patching Empire.exe's IMPORT TABLE entry.
 *
 * Not a code detour: this is a one-shot startup call reached through the IAT,
 * and swapping a function POINTER is both simpler and safer than rewriting
 * bytes inside someone else's DLL - nothing to steal, no prologue to match,
 * and no interaction with the crash guard. */
static void install_d3d9_hook(void) {
    LARGE_INTEGER f;
    QueryPerformanceFrequency(&f);
    g_qpf = f.QuadPart;

    HMODULE base = GetModuleHandleA(NULL);
    if (!base) return;
    IMAGE_DOS_HEADER* dos = (IMAGE_DOS_HEADER*)base;
    IMAGE_NT_HEADERS* nt  = (IMAGE_NT_HEADERS*)((BYTE*)base + dos->e_lfanew);
    DWORD rva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
    if (!rva) { ese_log("[d3d9] no import directory"); return; }

    IMAGE_IMPORT_DESCRIPTOR* imp = (IMAGE_IMPORT_DESCRIPTOR*)((BYTE*)base + rva);
    for (; imp->Name; imp++) {
        const char* dll = (const char*)((BYTE*)base + imp->Name);
        if (_stricmp(dll, "d3d9.dll") != 0) continue;

        IMAGE_THUNK_DATA* names = (IMAGE_THUNK_DATA*)((BYTE*)base +
            (imp->OriginalFirstThunk ? imp->OriginalFirstThunk : imp->FirstThunk));
        IMAGE_THUNK_DATA* addrs = (IMAGE_THUNK_DATA*)((BYTE*)base + imp->FirstThunk);

        for (; names->u1.AddressOfData; names++, addrs++) {
            if (names->u1.Ordinal & IMAGE_ORDINAL_FLAG) continue;   /* by ordinal */
            IMAGE_IMPORT_BY_NAME* n = (IMAGE_IMPORT_BY_NAME*)((BYTE*)base + names->u1.AddressOfData);
            if (strcmp((const char*)n->Name, "Direct3DCreate9") != 0) continue;

            DWORD old;
            if (!VirtualProtect(&addrs->u1.Function, sizeof(void*), PAGE_READWRITE, &old)) {
                ese_log("[d3d9] VirtualProtect failed on the IAT entry");
                return;
            }
            o_d3dcreate9 = (fn_d3dcreate9)(ULONG_PTR)addrs->u1.Function;
            addrs->u1.Function = (ULONG_PTR)hk_d3dcreate9;
            VirtualProtect(&addrs->u1.Function, sizeof(void*), old, &old);
            ese_log("[d3d9] IAT patched: Direct3DCreate9 %p -> %p (qpf=%lld)",
                    o_d3dcreate9, hk_d3dcreate9, (long long)g_qpf);
            return;
        }
    }
    ese_log("[d3d9] d3d9.dll import entry not found");
}

/* ===================== SYNTHETIC UI INPUT ================================
 * ESE_Mouse("move", "x", "y") | ESE_Mouse("click", "x", "y") | ESE_Mouse("hwnd")
 *
 * WHY THIS IS THE FOUNDATION OF VR UI
 *   In VR the 2D interface has to live on a virtual panel: point a controller,
 *   hit the panel, convert the hit to a screen pixel, and CLICK there. That
 *   last step is the only part that touches the game, and it can be proven
 *   now - flat, no headset - which makes it a cheap Stage 0 gate. If Empire
 *   will not respond to synthetic input, every VR UI design is dead and we
 *   learn it before building a renderer.
 *
 * WHY WINDOW MESSAGES, NOT THE OS CURSOR
 *   Empire imports PeekMessageW / DispatchMessageW / TranslateMessage,
 *   TrackMouseEvent, SetCapture and ReleaseCapture - but NOT SetCursorPos or
 *   GetCursorPos. It takes mouse position from the message stream, so posting
 *   messages is the correct injection point. Moving the real cursor would be
 *   both more invasive and less reliable.
 *
 *   Coordinates are CLIENT-space pixels, which is what WM_MOUSEMOVE carries
 *   and what a panel hit maps onto naturally via ScreenSize().
 *
 * A move is posted before a click deliberately: Empire tracks hover state
 * (MouseMovedOntoCard / MouseMovedOffCard exist in the battle API), so a
 * click with no preceding move can land on a widget that never highlighted. */
#ifndef WM_MOUSEMOVE
#define WM_MOUSEMOVE   0x0200
#define WM_LBUTTONDOWN 0x0201
#define WM_LBUTTONUP   0x0202
#define WM_RBUTTONDOWN 0x0204
#define WM_RBUTTONUP   0x0205
#endif

static int __cdecl ese_mouse(lua_State* L) {
    const char* cmd = L_.tolstring(L, 1, NULL);
    if (!g_hwnd) { push_str(L, "no HWND yet - the D3D9 device has not been created"); return 1; }
    if (cmd && strcmp(cmd, "hwnd") == 0) {
        char b[64]; _snprintf(b, sizeof(b)-1, "hwnd=%p", g_hwnd); b[63] = 0;
        push_str(L, b); return 1;
    }
    int x = (int)parse_addr(L_.tolstring(L, 2, NULL));
    int y = (int)parse_addr(L_.tolstring(L, 3, NULL));
    LPARAM lp = (LPARAM)((y << 16) | (x & 0xFFFF));

    if (cmd && strcmp(cmd, "move") == 0) {
        PostMessageW(g_hwnd, WM_MOUSEMOVE, 0, lp);
        push_str(L, "moved");
        return 1;
    }
    if (cmd && (strcmp(cmd, "click") == 0 || strcmp(cmd, "rclick") == 0)) {
        int right = (cmd[0] == 'r');
        PostMessageW(g_hwnd, WM_MOUSEMOVE, 0, lp);
        PostMessageW(g_hwnd, right ? WM_RBUTTONDOWN : WM_LBUTTONDOWN,
                     right ? 0x0002 : 0x0001, lp);
        PostMessageW(g_hwnd, right ? WM_RBUTTONUP : WM_LBUTTONUP, 0, lp);
        char b[96];
        _snprintf(b, sizeof(b)-1, "%s at %d,%d", right ? "rclick" : "click", x, y);
        b[95] = 0;
        push_str(L, b);
        return 1;
    }
    /* ESE_Mouse("drag", x1, y1, x2, y2 [, steps])
     *
     * Queued, ONE EVENT PER FRAME, because Empire reads its message queue once
     * per frame - a burst is seen as a single jump and a slider handle never
     * tracks it. This is the gesture a VR pointer needs: Empire's scrollbars
     * have no wheel handler at all, so "touch and scroll" must become a real
     * drag of the handle. */
    if (cmd && strcmp(cmd, "drag") == 0) {
        int x2 = (int)parse_addr(L_.tolstring(L, 4, NULL));
        int y2 = (int)parse_addr(L_.tolstring(L, 5, NULL));
        const char* ss = L_.tolstring(L, 6, NULL);
        int steps = ss ? (int)parse_addr(ss) : 12;
        if (steps < 2)  steps = 2;
        if (steps > 40) steps = 40;

        inj_push(WM_MOUSEMOVE,   0,      x, y);
        inj_push(WM_LBUTTONDOWN, 0x0001, x, y);
        for (int i = 1; i <= steps; i++) {
            int xi = x + (x2 - x) * i / steps;
            int yi = y + (y2 - y) * i / steps;
            inj_push(WM_MOUSEMOVE, 0x0001, xi, yi);   /* button still held */
        }
        inj_push(WM_LBUTTONUP, 0, x2, y2);

        char b[128];
        _snprintf(b, sizeof(b)-1, "drag queued %d,%d -> %d,%d over %d frames",
                  x, y, x2, y2, steps + 3);
        b[127] = 0;
        push_str(L, b);
        return 1;
    }
    /* ESE_Mouse("wheel", x, y, delta)
     *
     * Included for the CAMERA, not the UI: neither vslider template has a
     * wheel handler, so this will not scroll a panel. NOTE the coordinates -
     * WM_MOUSEWHEEL carries SCREEN coordinates in lParam, unlike WM_MOUSEMOVE
     * which carries client ones. Passing client coords here is a classic and
     * silent mistake. */
    if (cmd && strcmp(cmd, "wheel") == 0) {
        int delta = (int)parse_addr(L_.tolstring(L, 4, NULL));
        POINT pt; pt.x = x; pt.y = y;
        ClientToScreen(g_hwnd, &pt);
        PostMessageW(g_hwnd, 0x020A /* WM_MOUSEWHEEL */,
                     (WPARAM)(delta << 16), (LPARAM)((pt.y << 16) | (pt.x & 0xFFFF)));
        push_str(L, "wheel posted (screen coords) - note: UI sliders have no wheel handler");
        return 1;
    }
    push_str(L, "ESE_Mouse(\"move\"|\"click\"|\"rclick\"|\"drag\"|\"wheel\"|\"hwnd\", ...)");
    return 1;
}

/* ESE_TraceLog(addr [,max]) - drain the ring for a traced site.
 *
 * Returns one record per line: "a0 a1 a2 a3 | ecx=... eax=... edx=... ebx=...",
 * most recent LAST, and advances
 * the drain cursor so each call is reported exactly once. If the ring wrapped
 * before a drain the oldest entries are gone and the reply says how many were
 * lost - silently skipping them would corrupt any opcode sequence built from
 * this, which is the whole reason the ring exists. */
static int __cdecl ese_tracelog(lua_State* L) {
    const char* a = L_.tolstring(L, 1, NULL);
    const char* m = L_.tolstring(L, 2, NULL);
    if (!a) { push_str(L, "ESE_TraceLog(addr [,max])"); return 1; }
    DWORD live = parse_addr(a);

    int slot = -1, i;
    for (i = 0; i < TRACE_MAX; i++) {
        if (g_trace[i].used && g_trace[i].site == live) { slot = i; break; }
    }
    if (slot < 0) { push_str(L, "not traced"); return 1; }
    trace_slot* t = &g_trace[slot];

    LONG w = t->logw;
    LONG avail = w - t->logr;
    int lost = 0;
    if (avail > TRACE_LOG) { lost = (int)(avail - TRACE_LOG); t->logr = w - TRACE_LOG; avail = TRACE_LOG; }
    if (avail <= 0) { push_str(L, lost ? "no new calls" : "no new calls"); return 1; }

    int maxn = m ? (int)strtol(m, NULL, 10) : 24;
    if (maxn <= 0) maxn = 24;
    if (maxn > TRACE_LOG) maxn = TRACE_LOG;
    if (avail > maxn) avail = maxn;

    static char b[4096];
    int used = 0;
    if (lost) {
        used += _snprintf(b + used, sizeof(b) - used - 1, "[lost %d]\n", lost);
    }
    for (i = 0; i < (int)avail; i++) {
        LONG idx = t->logr + i;
        DWORD* r = t->log[idx & (TRACE_LOG - 1)];
        DWORD* rr = t->reglog[idx & (TRACE_LOG - 1)];
        int wr = _snprintf(b + used, sizeof(b) - used - 1,
                           "%08lX %08lX %08lX %08lX | ecx=%08lX eax=%08lX edx=%08lX ebx=%08lX\n",
                           (unsigned long)r[0], (unsigned long)r[1],
                           (unsigned long)r[2], (unsigned long)r[3],
                           (unsigned long)rr[0], (unsigned long)rr[1],
                           (unsigned long)rr[2], (unsigned long)rr[3]);
        if (wr <= 0 || used + wr >= (int)sizeof(b) - 64) break;
        used += wr;
    }
    t->logr += i;
    if (used > 0 && b[used - 1] == 0x0A) b[used - 1] = 0; else b[used] = 0;
    push_str(L, b);
    return 1;
}

/* ---- vtable tracing ------------------------------------------------------
 * ESE_TraceVT(objaddr, index [,"on"|"off"] [,nargs])
 *
 * Strictly safer than ESE_Trace: a vtable entry is a POINTER, so nothing is
 * stolen, nothing can land mid-instruction, and no prologue needs decoding.
 * Given how many interesting engine calls are virtual (camera ctl vt[0x128],
 * entity vtables, D3D/effect interfaces), prefer this whenever a call is
 * reached through a vtable.
 *
 * The thunk logs and then jumps to the original. EAX is caller-scratch at
 * function entry, so using it for the jump is safe; popad restores ECX first,
 * which is what __thiscall needs for `this`.
 *
 * Slots are shared with ESE_Trace, keyed by the ORIGINAL function address, so
 * ESE_Trace(addr) reporting and ESE_TraceLog(addr) draining work unchanged. */
static void* make_vt_thunk(int slot, void* orig) {
    unsigned char* t = (unsigned char*)VirtualAlloc(NULL, 96,
                           MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!t) return NULL;
    int i = 0;
    t[i++] = 0x9C;                                                  /* pushfd */
    t[i++] = 0x60;                                                  /* pushad */
    t[i++] = 0x8B; t[i++] = 0xD4;                                   /* mov edx,esp (saved regs) */
    t[i++] = 0x8D; t[i++] = 0x44; t[i++] = 0x24; t[i++] = 0x24;     /* lea eax,[esp+0x24] */
    t[i++] = 0x52;                                                  /* push edx  */
    t[i++] = 0x68; *(int*)(t + i) = slot; i += 4;                   /* push slot */
    t[i++] = 0x50;                                                  /* push eax  */
    t[i++] = 0xB8; *(void**)(t + i) = (void*)trace_handler; i += 4;
    t[i++] = 0xFF; t[i++] = 0xD0;                                   /* call eax */
    t[i++] = 0x83; t[i++] = 0xC4; t[i++] = 0x0C;                    /* add esp,12 */
    t[i++] = 0x61;                                                  /* popad  */
    t[i++] = 0x9D;                                                  /* popfd  */
    t[i++] = 0xB8; *(void**)(t + i) = orig; i += 4;                 /* mov eax,orig */
    t[i++] = 0xFF; t[i++] = 0xE0;                                   /* jmp eax */
    return t;
}

static int __cdecl ese_tracevt(lua_State* L) {
    const char* a  = L_.tolstring(L, 1, NULL);
    const char* ix = L_.tolstring(L, 2, NULL);
    const char* cmd = L_.tolstring(L, 3, NULL);
    const char* ns = L_.tolstring(L, 4, NULL);
    if (!a || !ix) { push_str(L, "ESE_TraceVT(objaddr, index [,on|off] [,nargs])"); return 1; }

    DWORD objaddr = parse_addr(a);
    int index = (int)strtol(ix, NULL, 0);
    if (index < 0 || index > 512) { push_str(L, "index out of range"); return 1; }
    if (!mem_readable((void*)objaddr, 4)) { push_str(L, "object UNREADABLE"); return 1; }
    void** vt = *(void***)objaddr;
    if (!mem_readable((void*)vt, (size_t)(index + 1) * 4)) { push_str(L, "vtable UNREADABLE"); return 1; }
    void* cur = vt[index];

    int slot = -1, freeslot = -1, i;
    for (i = 0; i < TRACE_MAX; i++) {
        if (g_trace[i].used && g_trace[i].is_vt &&
            g_trace[i].vt == vt && g_trace[i].vindex == index) { slot = i; break; }
        if (!g_trace[i].used && freeslot < 0) freeslot = i;
    }

    if (cmd && strcmp(cmd, "off") == 0) {
        if (slot < 0) { push_str(L, "not traced"); return 1; }
        trace_slot* t = &g_trace[slot];
        DWORD old;
        if (VirtualProtect(&t->vt[t->vindex], 4, PAGE_EXECUTE_READWRITE, &old)) {
            t->vt[t->vindex] = t->orig_fn;
            VirtualProtect(&t->vt[t->vindex], 4, old, &old);
        }
        t->used = 0;
        ese_log("[tracevt] vt[%d] restored after %ld hits", t->vindex, (long)t->hits);
        push_str(L, "removed");
        return 1;
    }

    if (!cmd || !cmd[0]) {
        if (slot < 0) { push_str(L, "not traced"); return 1; }
        trace_slot* t = &g_trace[slot];
        char b[192];
        _snprintf(b, sizeof(b) - 1, "vt[%d] orig=%08lX hits=%ld",
                  t->vindex, (unsigned long)((DWORD)t->orig_fn - g_delta), (long)t->hits);
        b[191] = 0;
        push_str(L, b);
        return 1;
    }

    if (strcmp(cmd, "on") != 0) { push_str(L, "cmd must be on|off"); return 1; }
    if (slot >= 0) { push_str(L, "already traced"); return 1; }
    if (freeslot < 0) { push_str(L, "no free trace slots"); return 1; }
    if (!mem_executable(cur)) { push_str(L, "vtable entry NOT_EXECUTABLE"); return 1; }

    int nargs = ns ? (int)strtol(ns, NULL, 10) : 4;
    if (nargs < 0) nargs = 0;
    if (nargs > 6) nargs = 6;

    trace_slot* t = &g_trace[freeslot];
    memset(t, 0, sizeof(*t));
    t->is_vt = 1;
    t->vt = vt;
    t->vindex = index;
    t->orig_fn = cur;
    t->site = (DWORD)cur;                 /* key the log by the real function */
    t->statica = (DWORD)cur - g_delta;
    t->nargs = nargs;
    t->thunk_vt = make_vt_thunk(freeslot, cur);
    if (!t->thunk_vt) { push_str(L, "thunk alloc failed"); return 1; }

    DWORD old;
    if (!VirtualProtect(&vt[index], 4, PAGE_EXECUTE_READWRITE, &old)) {
        push_str(L, "PROTECT_FAILED"); return 1;
    }
    vt[index] = t->thunk_vt;
    VirtualProtect(&vt[index], 4, old, &old);
    t->used = 1;

    ese_log("[tracevt] vt[%d] %08lX -> thunk %p (slot %d, %d args)",
            index, (unsigned long)t->statica, t->thunk_vt, freeslot, nargs);
    char b[160];
    _snprintf(b, sizeof(b) - 1, "tracing vt[%d] orig %08lX (slot %d, %d args)",
              index, (unsigned long)t->statica, freeslot, nargs);
    b[159] = 0;
    push_str(L, b);
    return 1;
}

/* Commands that touch only ESE's own state, so they work with NO lua_State
 * bound. Everything used to be a Lua native, which meant the control channel
 * went dead in a custom battle - no campaign state, battle state not yet
 * detected - exactly when the frame counter and synthetic input were wanted. */
static void native_cmd(const char* p) {
        g_res[0] = 0;

        if (strncmp(p, "states", 6) == 0) {
            _snprintf(g_res, RES_MAX-1,
                "campaign=%p ui=%p battle=%p hwnd=%p present_hooked=%s",
                g_campL, g_uiL, g_battleL, g_hwnd, o_present ? "yes" : "no");
        } else if (strncmp(p, "fps ", 4) == 0) {
            const char* a = p + 4;
            if (strncmp(a, "on", 2) == 0) {
                g_frames = 0; g_fps_qpc = 0; g_fps_min = 0; g_fps_max = 0;
                g_fps_probe = 1;
                _snprintf(g_res, RES_MAX-1, "fps probe ARMED (present_hooked=%s)",
                          o_present ? "yes" : "NO");
            } else if (strncmp(a, "off", 3) == 0) {
                g_fps_probe = 0;
                _snprintf(g_res, RES_MAX-1, "fps probe off");
            } else {
                _snprintf(g_res, RES_MAX-1, "present_hooked=%s last=%.1f min=%.1f max=%.1f",
                          o_present ? "yes" : "NO", g_fps_last, g_fps_min, g_fps_max);
            }
        } else if (strncmp(p, "impact ", 7) == 0) {
            const char* a = p + 7;
            if (strncmp(a, "on", 2) == 0) {
                g_imp_n = 0; g_imp_total = 0; g_imp_probe = 1;
                _snprintf(g_res, RES_MAX-1, "impact probe ARMED");
            } else if (strncmp(a, "off", 3) == 0) {
                g_imp_probe = 0;
                _snprintf(g_res, RES_MAX-1, "impact probe off");
            } else if (strncmp(a, "dump", 4) == 0) {
                /* Print a snapshot taken AT impact time, as dwords. Safe to
                 * read whenever - it is our copy, not the game's memory. */
                int idx = (int)strtol(a + 4, NULL, 10);
                if (idx < 0 || idx >= IMPACT_SNAP_N || !g_imp_snapped[idx]) {
                    _snprintf(g_res, RES_MAX-1, "no snapshot %d (have %d slots)", idx, IMPACT_SNAP_N);
                } else {
                    DWORD* w = (DWORD*)g_imp_snap[idx];
                    int used = _snprintf(g_res, RES_MAX-1, "snap%d of %08lX class=%ld:",
                                         idx, (unsigned long)g_imp_seen[idx], (long)g_imp_cls[idx]);
                    for (int k = 0; k < IMPACT_SNAP/4 && used < RES_MAX-16; k++)
                        used += _snprintf(g_res+used, RES_MAX-1-used, " %lX", (unsigned long)w[k]);
                }
            } else {
                int used = _snprintf(g_res, RES_MAX-1, "impacts=%ld distinct=%ld snaps=%d :",
                                     (long)g_imp_total, (long)g_imp_n,
                                     g_imp_snapped[0]+g_imp_snapped[1]+g_imp_snapped[2]+g_imp_snapped[3]);
                for (int i = 0; i < g_imp_n && used < RES_MAX-60; i++)
                    used += _snprintf(g_res+used, RES_MAX-1-used, " %08lX/c%ld",
                                      (unsigned long)g_imp_seen[i], (long)g_imp_cls[i]);
            }
        } else if (strncmp(p, "dik", 3) == 0) {
            /* @nat dik <scancode> <0|1>   set/clear one synthetic DI key
             * @nat dik clear              release everything
             * @nat dik status             counters (is the keyboard polled?)
             * Scan codes, NOT VK: DIK_W=0x11(17) A=0x1E(30) S=0x1F(31)
             * D=0x20(32) UP=0xC8(200) DOWN=0xD0(208) LEFT=0xCB(203)
             * RIGHT=0xCD(205). */
            const char* a = p + 3;
            while (*a == ' ') a++;
            if (strncmp(a, "clear", 5) == 0) {
                memset(g_synthkey, 0, sizeof(g_synthkey));
                g_synth_on = 0;
                _snprintf(g_res, RES_MAX-1, "dik cleared");
            } else if (strncmp(a, "status", 6) == 0) {
                int held = 0;
                for (int i = 0; i < 256; i++) if (g_synthkey[i]) held++;
                _snprintf(g_res, RES_MAX-1,
                    "di devices=%ld kbpolls=%ld hooked=%s synth_on=%ld held=%d",
                    (long)g_di_devices, (long)g_di_kbpolls,
                    o_getdevstate ? "yes" : "NO", (long)g_synth_on, held);
            } else {
                int sc = (int)strtol(a, (char**)&a, 10);
                while (*a == ' ') a++;
                int on = (int)strtol(a, NULL, 10);
                if (sc <= 0 || sc > 255) {
                    _snprintf(g_res, RES_MAX-1, "dik: scancode 1-255");
                } else {
                    g_synthkey[sc] = on ? 1 : 0;
                    int held = 0;
                    for (int i = 0; i < 256; i++) if (g_synthkey[i]) held++;
                    g_synth_on = held ? 1 : 0;
                    _snprintf(g_res, RES_MAX-1, "dik %d=%d (held=%d, hooked=%s)",
                              sc, on ? 1 : 0, held, o_getdevstate ? "yes" : "NO");
                }
            }
        } else if (strncmp(p, "key ", 4) == 0) {
            /* @nat key down 87 | key up 87 | key tap 87   (87 = 'W')
             *
             * Synthetic KEYBOARD, added 2026-09-22 for camera control. The
             * camera's state fields are derived and revert when written (see
             * the skill), so driving the debug camera through its normal
             * input path is the remaining route.
             *
             * CAVEAT, TEST THIS BEFORE BUILDING ON IT: Empire reads input
             * through DirectInput (that is why a dinput8 proxy works at all).
             * If the camera is driven from DirectInput rather than the window
             * message queue, posting WM_KEYDOWN will do NOTHING and the real
             * fix is intercepting the DirectInput device instead. The UI does
             * respond to posted messages (that is what @nat mouse was built
             * for), so this is worth one cheap experiment either way. */
            const char* a = p + 4;
            while (*a == ' ') a++;
            const char* q = a;
            while (*q && *q != ' ') q++;
            int vk = (int)strtol(q, NULL, 10);
            if (!g_hwnd) {
                _snprintf(g_res, RES_MAX-1, "no HWND yet");
            } else if (vk <= 0 || vk > 255) {
                _snprintf(g_res, RES_MAX-1, "key: need a VK code 1-255");
            } else {
                /* lParam: repeat=1, scan code, no extended/context bits. */
                UINT sc = MapVirtualKeyA((UINT)vk, 0 /*MAPVK_VK_TO_VSC*/);
                LPARAM down = (LPARAM)(1 | (sc << 16));
                LPARAM up   = (LPARAM)(1 | (sc << 16) | (1u << 30) | (1u << 31));
                if (strncmp(a, "down", 4) == 0) {
                    PostMessageW(g_hwnd, WM_KEYDOWN, (WPARAM)vk, down);
                    _snprintf(g_res, RES_MAX-1, "key down vk=%d sc=%u", vk, sc);
                } else if (strncmp(a, "up", 2) == 0) {
                    PostMessageW(g_hwnd, WM_KEYUP, (WPARAM)vk, up);
                    _snprintf(g_res, RES_MAX-1, "key up vk=%d sc=%u", vk, sc);
                } else {
                    PostMessageW(g_hwnd, WM_KEYDOWN, (WPARAM)vk, down);
                    PostMessageW(g_hwnd, WM_KEYUP,   (WPARAM)vk, up);
                    _snprintf(g_res, RES_MAX-1, "key tap vk=%d sc=%u", vk, sc);
                }
            }
        } else if (strncmp(p, "mouse ", 6) == 0) {
            /* @nat mouse click 640 400   |   @nat mouse drag 900 300 900 500 12 */
            const char* a = p + 6;
            int v[5] = {0,0,0,0,12};
            const char* q = a;
            while (*q && *q != ' ') q++;                 /* skip the verb */
            for (int i = 0; i < 5 && *q; i++) {
                while (*q == ' ') q++;
                if (!*q) break;
                v[i] = (int)strtol(q, (char**)&q, 10);
            }
            if (!g_hwnd) {
                _snprintf(g_res, RES_MAX-1, "no HWND yet");
            } else if (strncmp(a, "click", 5) == 0) {
                inj_push(WM_MOUSEMOVE, 0, v[0], v[1]);
                inj_push(WM_LBUTTONDOWN, 0x0001, v[0], v[1]);
                inj_push(WM_LBUTTONUP, 0, v[0], v[1]);
                _snprintf(g_res, RES_MAX-1, "click queued at %d,%d", v[0], v[1]);
            } else if (strncmp(a, "move", 4) == 0) {
                inj_push(WM_MOUSEMOVE, 0, v[0], v[1]);
                _snprintf(g_res, RES_MAX-1, "move queued to %d,%d", v[0], v[1]);
            } else if (strncmp(a, "drag", 4) == 0) {
                int steps = v[4] < 2 ? 12 : (v[4] > 40 ? 40 : v[4]);
                inj_push(WM_MOUSEMOVE, 0, v[0], v[1]);
                inj_push(WM_LBUTTONDOWN, 0x0001, v[0], v[1]);
                for (int i = 1; i <= steps; i++)
                    inj_push(WM_MOUSEMOVE, 0x0001,
                             v[0] + (v[2]-v[0])*i/steps, v[1] + (v[3]-v[1])*i/steps);
                inj_push(WM_LBUTTONUP, 0, v[2], v[3]);
                _snprintf(g_res, RES_MAX-1, "drag queued %d,%d -> %d,%d over %d frames",
                          v[0], v[1], v[2], v[3], steps + 3);
            } else {
                _snprintf(g_res, RES_MAX-1, "mouse: click|move|drag");
            }
        } else {
            _snprintf(g_res, RES_MAX-1, "@nat: states | fps on|off|report | impact on|off|report | mouse ...");
        }
        g_res[RES_MAX-1] = 0;
}

/* ESE_FPS("on"|"off"|"report") */
static int __cdecl ese_fps(lua_State* L) {
    const char* cmd = L_.tolstring(L, 1, NULL);
    if (cmd && strcmp(cmd, "on") == 0) {
        g_frames = 0; g_fps_qpc = 0; g_fps_min = 0; g_fps_max = 0; g_fps_last = 0;
        g_fps_probe = 1;
        push_str(L, o_present ? "fps probe ARMED" : "fps probe armed, but Present is NOT hooked yet");
        return 1;
    }
    if (cmd && strcmp(cmd, "off") == 0) { g_fps_probe = 0; push_str(L, "fps probe off"); return 1; }
    char b[192];
    _snprintf(b, sizeof(b)-1, "present_hooked=%s last=%.1f min=%.1f max=%.1f",
              o_present ? "yes" : "NO", g_fps_last, g_fps_min, g_fps_max);
    b[sizeof(b)-1] = 0;
    push_str(L, b);
    return 1;
}

/* ESE_Impact("on"|"off"|"report") */
static int __cdecl ese_impact(lua_State* L) {
    const char* cmd = L_.tolstring(L, 1, NULL);
    if (cmd && strcmp(cmd, "on") == 0) {
        g_imp_n = 0; g_imp_total = 0; g_imp_probe = 1;
        push_str(L, "impact probe ARMED (table cleared)");
        return 1;
    }
    if (cmd && strcmp(cmd, "off") == 0) {
        g_imp_probe = 0;
        push_str(L, "impact probe off");
        return 1;
    }
    char b[512];
    int  used = _snprintf(b, sizeof(b)-1, "impacts=%ld distinct=%ld :",
                          (long)g_imp_total, (long)g_imp_n);
    for (int i = 0; i < g_imp_n && used < 460; i++) {
        used += _snprintf(b + used, sizeof(b)-1-used, " %08lX/c%ld",
                          (unsigned long)g_imp_seen[i], (long)g_imp_cls[i]);
    }
    b[sizeof(b)-1] = 0;
    push_str(L, b);
    return 1;
}
static LONG g_vec_logs = 0;

static __inline int plausible_ptr(DWORD p) {
    return p >= 0x10000 && p < 0x7FFF0000 && (p & 3) == 0;
}

static void __cdecl on_vec_push(DWORD* stk) {
    DWORD* regs = (DWORD*)((char*)stk - 0x24);
    DWORD self  = regs[6];                       /* ECX = the vector */
    if (!plausible_ptr(self)) return;

    DWORD data = ((DWORD*)self)[0];
    DWORD size = ((DWORD*)self)[1];
    DWORD cap  = ((DWORD*)self)[2];

    /* Fast path: healthy vector with room, or the ordinary 0 -> 8 first grow. */
    int inconsistent = (data == 0 && cap != 0);
    int wild_grow    = (size == cap && cap > 0x2000000);
    if (!inconsistent && !wild_grow) return;

    if (InterlockedIncrement(&g_vec_logs) > 12) return;
    ese_log("!!! VECTOR PUSH SUSPECT vec=%08lX data=%08lX size=%lu cap=%lu (%s)",
            (unsigned long)self, (unsigned long)data,
            (unsigned long)size, (unsigned long)cap,
            inconsistent ? "data NULL but capacity set" : "about to double a huge capacity");
    ese_log("    caller return address = %08lX (static %08lX)",
            (unsigned long)stk[0], (unsigned long)(stk[0] - g_delta));
}

/* ---- the commodity DATABASE TABLE, read at its consumer (0x00972440) -----
 * DIAGNOSTIC ONLY - reads and logs, changes nothing.
 *
 * The measured split is: trade manager = 9 commodities / 21 resources (our ESF
 * edit landed), faction economy object = 8 / 20 (vanilla numbers, identical in
 * a vanilla run). Something authoritative still says EIGHT.
 *
 * The prime suspect is the DB itself. rum_commodity.pack ships a 29-byte
 * db\commodities_tables\zzz_rum_commodities - a header plus exactly one row -
 * relying on Empire MERGING same-folder tables. If the engine instead ignores
 * it (wrong version byte, say), the DB stays at 8 while the startpos says 9,
 * and everything DB-sized stays 8. That also explains rum never appearing on
 * the trade panel.
 *
 * FUN_00972440(index, table) receives that table as its second argument:
 *   if (index < table[+0xC]) rec = table[+0x10][index];
 * so +0x08 = count, +0x0C = sentinel, +0x10 = record pointer array.
 * COMMODITY_RECORD: +0x00 name (UniString), +0x04 float price,
 * +0x08 float elasticity. The name needs TWO derefs and the characters start
 * at +6 (layout confirmed from FUN_004b8330: [short][short len][short len]
 * [UTF-16 chars][NUL]).
 *
 * Steal 6: 8B 44 24 08 56 57 (MOV EAX,[ESP+8]; PUSH ESI; PUSH EDI) - whole
 * instructions, no relative branch. ENTRY hook, so the stack is untouched:
 * stk[0] = return address, stk[1] = index, stk[2] = the table.
 */
#define A_idx_lookup  0x00972440
static const unsigned char kIdxProlog[6] = { 0x8B,0x44,0x24,0x08,0x56,0x57 };
static LONG g_idx_seen = 0;

/* Decode a UniString reached through `rec` (rec -> handle -> data, chars +6). */
static void unistr_of(DWORD rec, char* out, int cap) {
    out[0] = 0;
    DWORD handle = 0, data = 0;
    if (!safe_rd(rec, &handle) || !safe_rd(handle, &data)) return;
    int w = 0;
    for (int i = 0; i < cap - 1; i++) {
        DWORD ch = 0;
        if (!safe_rd(data + 6 + i * 2, &ch)) break;
        unsigned short c = (unsigned short)(ch & 0xFFFF);
        if (c == 0 || c < 32 || c > 126) break;
        out[w++] = (char)c;
    }
    out[w] = 0;
}

static void __cdecl on_idx_lookup(DWORD* stk) {
    if (InterlockedCompareExchange(&g_idx_seen, 1, 0) != 0) return;

    DWORD table = stk[2];
    DWORD count = 0, sentinel = 0, records = 0;
    if (!safe_rd(table + 0x08, &count) || !safe_rd(table + 0x0C, &sentinel) ||
        !safe_rd(table + 0x10, &records)) {
        ese_log("=== COMMODITY DB TABLE: unreadable at %08lX ===", (unsigned long)table);
        return;
    }
    ese_log("=== COMMODITY DB TABLE %08lX: count=%lu sentinel=%lu records=%08lX ===",
            (unsigned long)table, (unsigned long)count,
            (unsigned long)sentinel, (unsigned long)records);
    ese_log("    >>> THE DB SAYS %lu COMMODITIES <<<", (unsigned long)count);

    if (count > 64) return;
    for (DWORD i = 0; i < count; i++) {
        DWORD rec = 0;
        if (!safe_rd(records + i * 4, &rec)) continue;
        DWORD pr = 0, el = 0;
        safe_rd(rec + 4, &pr);
        safe_rd(rec + 8, &el);
        float fp, fe; memcpy(&fp, &pr, 4); memcpy(&fe, &el, 4);
        char nm[64]; unistr_of(rec, nm, sizeof(nm));
        ese_log("    [%lu] %-16s price=%.3f elasticity=%.3f",
                (unsigned long)i, nm[0] ? nm : "(unnamed)", (double)fp, (double)fe);
    }
    ese_log("=== COMMODITY DB TABLE END ===");
}

/* Log-only. A live battle looked up none of the six unique names as globals,
 * and setfield of CameraZoomTo never fired. The 208 functions are registered
 * into two private tables (DAT_0137d028 / DAT_0137d02c), so the lookup index
 * is not LUA_GLOBALSINDEX. Record index, state, and name. Do not call back
 * into Lua from here, and do not bind. */
static void note_battle_lookup(DWORD* stk) {
    if (!stk[3]) return;
    const char* k = (const char*)stk[3];
    if (k[0] < 'A' || k[0] > 'Z') return;
    int named = 0;
    for (int i = 0; kBattleUniqueNames[i]; i++) {
        if (strcmp(k, kBattleUniqueNames[i]) == 0) { named = 1; break; }
    }
    if (!named) return;
    static char seen[6][48];
    static int seen_n = 0;
    for (int i = 0; i < seen_n; i++) {
        if (strcmp(seen[i], k) == 0) return;
    }
    if (seen_n < 6) {
        strncpy(seen[seen_n], k, 47);
        seen[seen_n][47] = 0;
        seen_n++;
    }
    ese_log("[ese] battle-name lookup idx=%d L=%p key='%s' (log only, not bound)",
            (int)stk[2], (void*)stk[1], k);
}

/* Log-only. The six battle names are not passed to lua_getfield at all.
 * Live bytes at static 00F07850, read from the running process:
 *   8B 44 24 10    mov eax,[esp+10]     ; nresults
 *   83 EC 08       sub esp,8
 * A 5-byte steal splits the sub. Steal 7. Args are unchanged: stk[1] is L.
 * Do not bind, and do not call back into Lua. */
#define A_lua_pcall_site A_lua_pcall
#define PCALL_STEAL 7
static const unsigned char kPcallProlog[PCALL_STEAL] = {
    0x8B, 0x44, 0x24, 0x10, 0x83, 0xEC, 0x08
};
/* A live battle produced 48 distinct pcall states, all nargs=0 nresults=-1,
 * then the cap hid anything later. Those are component states created while
 * the manager already exists. Do not log a state on its first sighting.
 * Check CameraZoomTo only when the same pointer is seen again, so a state
 * freed during construction is never touched. Log only a hit. Do not bind. */
#define PCALL_SEEN_MAX 256
static void* g_pcall_seen[PCALL_SEEN_MAX];
static int   g_pcall_seen_n = 0;
static int   g_pcall_hits = 0;

/* Ghidra: FUN_00580470 is the only battle-side caller of the state getter
 * 00F77880, and it has exactly one caller (0057e2f0). The getter returns
 * *(obj+4), creating it on first touch. CameraZoomTo is not a global, so
 * getfield and pcall never saw this state.
 *
 * The site is a relative CALL. Copying that E8 into a trampoline executes it
 * from the wrong address (fault 04787400, empty page). This trampoline calls
 * the getter at its absolute address instead, then logs ESI (the object, set
 * by MOV ECX,ESI just before the call) and EAX (the return). It does not
 * return to the stolen call. Log only. Do not bind and do not call Lua. */
#define A_battle_state_fetch 0x00580493
#define A_battle_state_getter 0x00F77880
#define BATTLE_FETCH_STEAL 5
static const unsigned char kBattleFetchProlog[BATTLE_FETCH_STEAL] = {
    0xE8, 0xE8, 0x73, 0x9F, 0x00
};
static int g_battle_fetch_n = 0;

static void __cdecl on_battle_state_fetch(DWORD obj, DWORD state, DWORD unused) {
    DWORD slot = 0;
    lua_State* L = (lua_State*)state;
    const char* kind = "unreadable";
    int ui = -1, zoom = -1, halt = -1;
    (void)unused;
    if (obj) safe_rd(obj + 4, &slot);
    if (state_readable(L)) {
        kind = is_real_battle_state(L) ? "CameraZoomTo=function" : "CameraZoomTo=nil";
        battle_iface_types(L, &ui, &zoom, &halt);
        if (ui == LUA_TTABLE && zoom == LUA_TFUNCTION) {
            /* Bind later from pump(): the battle manager may not exist yet mid-construction. */
            g_battle_obj = obj;
            g_battle_pend = L;
        }
    }
    if (g_battle_fetch_n >= 8) return;
    g_battle_fetch_n++;
    ese_log("[ese] battle iface L=%p BattleUI=%d .CameraZoomTo=%d .Current_Selection_Halt=%d%s",
            (void*)L, ui, zoom, halt, g_battle_pend == L ? " (bind pending)" : "");
    ese_log("[ese] battle object %08lX state %08lX slot %08lX %s",
            (unsigned long)obj, (unsigned long)state, (unsigned long)slot, kind);
}

/* FUN_005b3770 registers BattleUI into its cdecl arg L. Hooked at ADD ESP,8 after POP ESI: stack is {local, local, ret, L}. */
#define A_battle_cb_ret 0x005B3808
#define BATTLE_CB_STEAL 6
static const unsigned char kBattleCbProlog[BATTLE_CB_STEAL] = {
    0x83, 0xC4, 0x08, 0xC3, 0xCC, 0xCC
};
static int g_battle_cb_n = 0;

static void __cdecl on_battle_cb_ret(DWORD* stk) {
    lua_State* L = (lua_State*)stk[3];
    if (g_battle_cb_n >= 4) return;
    g_battle_cb_n++;
    ese_log("[ese] battle callback state %p (registered, not bound)", (void*)L);
}

/* Replaces the CALL at 00580493. Layout:
 *   push esi / call getter / push eax,eax,esi / call log / add esp,12 /
 *   pop eax / popfd / popad / push <site+5> / ret
 * The handler runs after the getter, so EAX is the return. ESI is the object.
 * safe_rd of obj+4 is the wrapper slot the getter dereferences. */
static void* make_fetch_tramp(unsigned char* site, void* handler) {
    unsigned char* t = (unsigned char*)VirtualAlloc(NULL, 96,
                            MEM_COMMIT|MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!t) return NULL;
    DWORD getter = A_battle_state_getter + g_delta;
    int i = 0;
    t[i++] = 0x9C;                               /* pushfd */
    t[i++] = 0x60;                               /* pushad */
    t[i++] = 0x56;                               /* push esi (object) */
    t[i++] = 0x89; t[i++] = 0xF1;                /* mov ecx,esi (fastcall this) */
    t[i++] = 0xB8; *(DWORD*)(t+i) = getter; i += 4;
    t[i++] = 0xFF; t[i++] = 0xD0;                /* call getter */
    t[i++] = 0x6A; t[i++] = 0x00;                /* push 0 (unused slot) */
    t[i++] = 0x50;                               /* push eax (state) */
    t[i++] = 0x56;                               /* push esi (object) */
    t[i++] = 0xB8; *(void**)(t+i) = handler; i += 4;
    t[i++] = 0xFF; t[i++] = 0xD0;                /* call handler */
    t[i++] = 0x83; t[i++] = 0xC4; t[i++] = 0x0C; /* add esp,12 */
    t[i++] = 0x58;                               /* pop eax (saved esi) */
    t[i++] = 0x61;                               /* popad */
    t[i++] = 0x9D;                               /* popfd */
    t[i++] = 0x68; *(void**)(t+i) = (void*)(site + BATTLE_FETCH_STEAL); i += 4;
    t[i++] = 0xC3;
    return t;
}

static void __cdecl on_pcall_note(DWORD* stk) {
    lua_State* L = (lua_State*)stk[1];
    int seen = 0, sloti = -1;
    if (!L || g_pcall_hits >= 4) return;
    for (int i = 0; i < g_pcall_seen_n; i++) {
        if (g_pcall_seen[i] == (void*)L) { seen = 1; sloti = i; break; }
    }
    if (!seen) {
        if (g_pcall_seen_n < PCALL_SEEN_MAX)
            g_pcall_seen[g_pcall_seen_n++] = (void*)L;
        return;
    }
    DWORD slot = 0, mgr = 0;
    if (!safe_rd(0x0137D488 + g_delta, &slot) || !slot) return;
    if (!safe_rd(slot + 0x31C, &mgr) || !mgr) return;
    /* Drop it before the Lua call so a miss is not rechecked every pcall. */
    g_pcall_seen[sloti] = g_pcall_seen[--g_pcall_seen_n];
    if (!state_readable(L)) return;
    if (!is_real_battle_state(L)) return;
    g_pcall_hits++;
    ese_log("[ese] battle state candidate L=%p CameraZoomTo=function mgr=%08lX (not bound)",
            (void*)L, (unsigned long)mgr);
}

static void __cdecl on_getfield(DWORD* stk) {
    note_battle_lookup(stk);
    /* Bind only when the looked-up name is unique AND CameraZoomTo is already
     * a function in THIS state. A bare name match is not a battle:
     * SelectionChanged is also looked up from a UI state that is freed as the
     * battle loads. Installing the tick there, then calling lua_gettop, was
     * the fault at 00D27504 (mov eax,[ecx+8], ECX = the dead state).
     *
     * setfield of CameraZoomTo never fired in a live battle. The 208 names are
     * resolved by getfield from a private table, not assigned as globals.
     * Verifying the function exists is what separates that lookup from a UI
     * lookup of a shared name. is_real_battle_state calls getfield, so it is
     * re-entered and must not be called unless the name already matched. */
    if (!g_battleL && (int)stk[2] == LUA_GLOBALSINDEX && stk[3]) {
        const char* k = (const char*)stk[3];
        int named = 0;
        for (int i = 0; kBattleUniqueNames[i]; i++) {
            if (strcmp(k, kBattleUniqueNames[i]) == 0) { named = 1; break; }
        }
        if (named) {
            lua_State* L = (lua_State*)stk[1];
            if (state_readable(L) && is_real_battle_state(L)) {
                g_battleL = L;
                ese_log("[ese] BATTLE state verified via getfield('%s'): %p", k, L);
                register_natives(L);
                run_autoexec_file(L, "ese_battle_autoexec.lua");
            }
        }
    }
    try_autoexec();
    say_pump();
    probe_commodities();
    pump();
}

/* ============================== pipe server ============================== */
static DWORD WINAPI pipe_thread(LPVOID unused) {
    (void)unused;
    for (;;) {
        HANDLE h = CreateNamedPipeA("\\\\.\\pipe\\ese",
                        PIPE_ACCESS_DUPLEX,
                        PIPE_TYPE_MESSAGE|PIPE_READMODE_MESSAGE|PIPE_WAIT,
                        1, RES_MAX, REQ_MAX, 0, NULL);
        if (h == INVALID_HANDLE_VALUE) { Sleep(1000); continue; }
        if (!ConnectNamedPipe(h, NULL) && GetLastError() != ERROR_PIPE_CONNECTED) {
            CloseHandle(h); continue;
        }
        DWORD n = 0;
        if (ReadFile(h, g_req, REQ_MAX-1, &n, NULL) && n > 0) {
            g_req[n] = 0;
            g_res[0] = 0;
            g_done   = 0;

            int wantsUI = (g_req[0]=='@' && g_req[1]=='u' && g_req[2]=='i');
            int wantsNative = (g_req[0]=='@' && g_req[1]=='n' &&
                               g_req[2]=='a' && g_req[3]=='t');
            int wantsBattle = (g_req[0]=='@' && g_req[1]=='b' &&
                               g_req[2]=='a' && g_req[3]=='t' &&
                               g_req[4]=='t' && g_req[5]=='l' && g_req[6]=='e');
            if (wantsNative) {
                /* These commands inspect or change only ESE/Windows state; no
                 * Lua API is called, so service them here even when Lua is idle. */
                const char* p = g_req + 4;
                while (*p == ' ') p++;
                native_cmd(p);
            } else if ((wantsUI && !g_uiL) || (!wantsUI && !wantsBattle && !g_campL)) {
                _snprintf(g_res, RES_MAX-1, wantsUI
                    ? "no UI state acquired yet"
                    : "campaign state not found yet - load a campaign first");
            } else {
                g_pending = 1;
                /* wait for the game thread to drain it */
                for (int i = 0; i < 1000 && !g_done; i++) Sleep(5);
                if (!g_done) _snprintf(g_res, RES_MAX-1,
                    "timeout - no Lua activity on the game thread to pump it");
            }
            DWORD w = 0;
            WriteFile(h, g_res, (DWORD)strlen(g_res), &w, NULL);
            FlushFileBuffers(h);
        }
        DisconnectNamedPipe(h);
        CloseHandle(h);
    }
    return 0;
}

/* ================================= init ================================== */
static DWORD WINAPI init_thread(LPVOID unused) {
    (void)unused;
    HMODULE base = GetModuleHandleA(NULL);
    g_delta = (DWORD)base - 0x00400000;
    ese_log("[ese] ---- start ---- base=%p delta=0x%X", base, g_delta);

    #define BIND(f, A) L_.f = (fn_##f)(A + g_delta)
    BIND(getfield,     A_lua_getfield);
    BIND(setfield,     A_lua_setfield);
    BIND(settop,       A_lua_settop);
    BIND(gettop,       A_lua_gettop);
    BIND(type,         A_lua_type);
    BIND(pushcclosure, A_lua_pushcclosure);
    BIND(pushlstring,  A_lua_pushlstring);
    BIND(tolstring,    A_lua_tolstring);
    BIND(loadbuffer,   A_luaL_loadbuffer);
    BIND(pcall,        A_lua_pcall);
    #undef BIND

    /* FIRST in the chain, so we see faults during our own eval before anything
     * else claims them. Disarmed except while pump() is actually running. */
    g_veh = AddVectoredExceptionHandler(1, ese_veh);
    ese_log("[ese] crash guard %s", g_veh ? "armed" : "FAILED to register");

    apply_commodity_fix();
    apply_tradeinfo_extras();
    /* Must follow apply_tradeinfo_extras: that is what reads the config file
     * and so what sets g_raw_resources. */
    apply_raw_resource_count();

    install_hook(A_lua_setfield, (void*)on_setfield);
    install_hook(A_lua_getfield, (void*)on_getfield);
    install_hook_ex(A_lua_pcall_site, (void*)on_pcall_note, kPcallProlog, PCALL_STEAL);
    {
        unsigned char* site = (unsigned char*)(A_battle_state_fetch + g_delta);
        if (memcmp(site, kBattleFetchProlog, BATTLE_FETCH_STEAL) != 0) {
            ese_log("[ese] REFUSING battle fetch hook %p: prologue mismatch (%02X %02X %02X %02X %02X)",
                    site, site[0], site[1], site[2], site[3], site[4]);
        } else {
            void* tramp = make_fetch_tramp(site, (void*)on_battle_state_fetch);
            DWORD old;
            if (tramp && VirtualProtect(site, BATTLE_FETCH_STEAL, PAGE_EXECUTE_READWRITE, &old)) {
                site[0] = 0xE9;
                *(DWORD*)(site+1) = (DWORD)tramp - ((DWORD)site + 5);
                VirtualProtect(site, BATTLE_FETCH_STEAL, old, &old);
                FlushInstructionCache(GetCurrentProcess(), site, BATTLE_FETCH_STEAL);
                ese_log("[ese] hooked battle fetch %p -> tramp %p (absolute getter)", site, tramp);
            } else {
                ese_log("[ese] battle fetch hook install failed");
            }
        }
    }
    install_hook_ex(A_battle_cb_ret, (void*)on_battle_cb_ret, kBattleCbProlog, BATTLE_CB_STEAL);
    install_hook_ex(A_price_engine, (void*)on_price_engine, kPriceProlog, 6);
    install_hook_ex(A_iter_loop,    (void*)on_iter_loop,    kIterProlog,  6);
    install_hook_ex(A_accum,        (void*)on_accum,        kAccumProlog, 5);
    install_hook_ex(A_vec_push,     (void*)on_vec_push,     kVecPushProlog, 7);
    /* 6-byte steal: the prologue is push ebp / mov ebp,esp / and esp,-64 and a
     * 5-byte steal would split the `and`, wrecking the stack alignment. */
    install_hook_ex(A_impact,       (void*)on_impact,       kImpactProlog,  6);
    install_hook_ex(A_idx_lookup,   (void*)on_idx_lookup,   kIdxProlog,     6);

    /* Render interception. Must come after the log is open; d3d9.dll is a
     * static import so it is already loaded by the time we run. */
    install_d3d9_hook();

    CreateThread(NULL, 0, pipe_thread, NULL, 0, NULL);
    ese_log("[ese] ready; pipe \\\\.\\pipe\\ese");
    return 0;
}

/* ============== DirectInput interception - synthetic input =============== *
 * MEASURED 2026-09-22: posting WM_KEYDOWN does NOT move Empire's camera. A
 * held arrow key produced LESS movement than a do-nothing control (idle drift
 * alone), so the camera does not read the window message queue - it reads
 * DirectInput. That is unsurprising: this DLL exists because Empire imports
 * dinput8, and it is also why `@nat mouse` works for UI clicks but not for
 * the camera - the UI is message-driven, the camera is not.
 *
 * Since we ARE dinput8.dll, the device is reachable: wrap the interfaces on
 * the way out and OR our synthetic key state into what the game reads. Same
 * COM vtable-patch technique already proven here for IDirect3DDevice9.
 *
 * IDirectInputDevice8 vtable: IUnknown 0-2, GetCapabilities 3, EnumObjects 4,
 * GetProperty 5, SetProperty 6, Acquire 7, Unacquire 8, GetDeviceState 9,
 * GetDeviceData 10, SetDataFormat 11, ...
 * IDirectInput8 vtable:       IUnknown 0-2, CreateDevice 3, EnumDevices 4, ...
 *
 * KEYS ARE DIK SCAN CODES HERE, NOT VK CODES (DIK_W = 0x11, DIK_UP = 0xC8).
 * MapVirtualKey(VK,0) converts, which is the same scan code @nat key logged. */
/* ========================= dinput8.dll proxying ========================== *
 * Forward the five real exports to the system DLL. Empire only actually calls
 * DirectInput8Create; the rest exist so nothing else that loads us breaks. */
static HMODULE g_real = NULL;
static void load_real(void) {
    char path[MAX_PATH];
    GetSystemDirectoryA(path, MAX_PATH);      /* SysWOW64 for a 32-bit process */
    strcat(path, "\\dinput8.dll");
    g_real = LoadLibraryA(path);
    if (!g_real) ese_log("[ese] FAILED to load real dinput8 at %s", path);
}

typedef HRESULT (WINAPI *t_DI8Create)(HINSTANCE, DWORD, REFIID, LPVOID*, LPVOID);
typedef HRESULT (WINAPI *t_DllGetClassObject)(REFCLSID, REFIID, LPVOID*);
typedef HRESULT (WINAPI *t_void)(void);

/* NOTE: deliberately NO __declspec(dllexport) on these five.
 * Exports come solely from ese.def, which aliases the undecorated names onto
 * these stdcall-decorated symbols. Using dllexport as well would ALSO export
 * the decorated "Name@N" forms, giving a messy double export table (and it
 * warns, since the SDK headers already declare DllGetClassObject/
 * DllCanUnloadNow without dllexport). */
HRESULT WINAPI DirectInput8Create(
        HINSTANCE h, DWORD v, REFIID r, LPVOID* o, LPVOID u) {
    if (!g_real) load_real();
    t_DI8Create f = (t_DI8Create)GetProcAddress(g_real, "DirectInput8Create");
    if (!f) return E_FAIL;
    HRESULT hr = f(h, v, r, o, u);
    /* Patch CreateDevice on the way out so every device the game makes gets
     * its GetDeviceState hooked - that is where synthetic keys are injected. */
    if (hr == 0 && o && *o && !o_createdevice_di) {
        void* prev = patch_vtable(*o, 3, (void*)hk_createdevice_di);
        if (prev) {
            o_createdevice_di = (fn_di_createdevice)prev;
            ese_log("[di] IDirectInput8 %p; CreateDevice hooked (orig %p)", *o, prev);
        }
    }
    return hr;
}
HRESULT WINAPI DllGetClassObject(REFCLSID c, REFIID r, LPVOID* o) {
    if (!g_real) load_real();
    t_DllGetClassObject f = (t_DllGetClassObject)GetProcAddress(g_real, "DllGetClassObject");
    return f ? f(c, r, o) : E_FAIL;
}
HRESULT WINAPI DllCanUnloadNow(void) {
    if (!g_real) load_real();
    t_void f = (t_void)GetProcAddress(g_real, "DllCanUnloadNow");
    return f ? f() : S_FALSE;
}
HRESULT WINAPI DllRegisterServer(void) {
    if (!g_real) load_real();
    t_void f = (t_void)GetProcAddress(g_real, "DllRegisterServer");
    return f ? f() : E_FAIL;
}
HRESULT WINAPI DllUnregisterServer(void) {
    if (!g_real) load_real();
    t_void f = (t_void)GetProcAddress(g_real, "DllUnregisterServer");
    return f ? f() : E_FAIL;
}

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hinst);
        load_real();
        /* Do NOT do real work inside DllMain (loader lock). Hand off to a
         * thread, which is also why hooks land slightly after load rather than
         * during it - still long before Lua initialises. */
        CreateThread(NULL, 0, init_thread, NULL, 0, NULL);
    }
    return TRUE;
}
