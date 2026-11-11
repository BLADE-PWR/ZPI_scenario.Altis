// ZPI telemetry extension: records out of the game over UDP, without stalling it.
//
// callExtension is synchronous - the game thread blocks until RVExtension
// returns - so this only copies the record into a queue and returns. A sender
// thread drains the queue into UDP datagrams. The game therefore never waits
// for a socket, and records reach a listener in well under a millisecond on
// localhost instead of waiting out Arma's ~0.5 s RPT flush cycle.
//
// A datagram is the same "ZPI|<type>|<json>" line that goes to the RPT, so the
// receiving side can reuse the RPT parser unchanged.
//
// From SQF:
//   "zpi_telemetry" callExtension "udp:127.0.0.1:5005"    set the target
//   "zpi_telemetry" callExtension "ZPI|tel|{...}"          queue a record -> ""
//
// Build: extension\build.bat  (needs the MSVC build tools)
// Install: copy zpi_telemetry_x64.dll next to Arma3_x64.exe. Arma appends the
// _x64 suffix itself, so SQF always names it "zpi_telemetry". BattlEye refuses
// unsigned extensions, so it has to be off.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

#pragma comment(lib, "ws2_32.lib")

namespace {

const char *const VERSION = "zpi_telemetry 1.0";
const char *const RECORD_PREFIX = "ZPI|";     // anything else is a command
const size_t MAX_QUEUE = 8192;                // ~2.5 min of 60 Hz telemetry
const size_t MAX_RECORD = 60000;              // a datagram has to fit in one packet

std::mutex g_queue_mutex;                     // guards g_queue
std::condition_variable g_wake;
std::deque<std::string> g_queue;

std::mutex g_target_mutex;                    // guards g_sock and g_addr
SOCKET g_sock = INVALID_SOCKET;
sockaddr_in g_addr{};

std::atomic<bool> g_running{false};
std::thread g_sender;
std::once_flag g_once;

void reply(char *output, int outputSize, const char *text) {
    if (output && outputSize > 0) {
        _snprintf_s(output, outputSize, _TRUNCATE, "%s", text);
    }
}

// Drain the queue into datagrams. Sends outside the queue lock, so a slow or
// unreachable socket never holds up the game thread's enqueue.
void sender_loop() {
    std::deque<std::string> batch;
    while (g_running.load(std::memory_order_relaxed)) {
        {
            std::unique_lock<std::mutex> lock(g_queue_mutex);
            g_wake.wait_for(lock, std::chrono::milliseconds(100), [] {
                return !g_queue.empty() || !g_running.load(std::memory_order_relaxed);
            });
            batch.swap(g_queue);
        }
        if (batch.empty()) {
            continue;
        }
        SOCKET sock;
        sockaddr_in addr;
        {
            std::lock_guard<std::mutex> lock(g_target_mutex);
            sock = g_sock;
            addr = g_addr;
        }
        for (const std::string &record : batch) {
            if (sock != INVALID_SOCKET) {
                sendto(sock, record.data(), static_cast<int>(record.size()), 0,
                        reinterpret_cast<const sockaddr *>(&addr), sizeof(addr));
            }
        }
        batch.clear();
    }
}

// Threads must not start in DllMain (the loader lock), so this runs on the
// first call instead.
void start_once() {
    std::call_once(g_once, [] {
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
            return;
        }
        g_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        g_addr.sin_family = AF_INET;
        g_addr.sin_port = htons(5005);
        InetPtonA(AF_INET, "127.0.0.1", &g_addr.sin_addr);
        g_running.store(true, std::memory_order_relaxed);
        g_sender = std::thread(sender_loop);
    });
}

void set_target(const char *spec, char *output, int outputSize) {
    const char *colon = std::strrchr(spec, ':');
    if (colon == nullptr || colon == spec) {
        reply(output, outputSize, "error: expected udp:<ipv4>:<port>");
        return;
    }
    const std::string host(spec, colon - spec);
    const int port = std::atoi(colon + 1);
    if (port <= 0 || port > 65535) {
        reply(output, outputSize, "error: port out of range");
        return;
    }
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<unsigned short>(port));
    if (InetPtonA(AF_INET, host.c_str(), &addr.sin_addr) != 1) {
        reply(output, outputSize, "error: not an IPv4 address");
        return;
    }
    {
        std::lock_guard<std::mutex> lock(g_target_mutex);
        g_addr = addr;
    }
    char text[64];
    _snprintf_s(text, sizeof(text), _TRUNCATE, "ok %s:%d", host.c_str(), port);
    reply(output, outputSize, text);
}

// Newest records matter most, so a full queue drops the oldest rather than
// the one being written.
void enqueue(const char *record) {
    const size_t length = std::strlen(record);
    if (length == 0 || length > MAX_RECORD) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(g_queue_mutex);
        while (g_queue.size() >= MAX_QUEUE) {
            g_queue.pop_front();
        }
        g_queue.emplace_back(record, length);
    }
    g_wake.notify_one();
}

}  // namespace

extern "C" {

__declspec(dllexport) void __stdcall RVExtensionVersion(char *output, int outputSize) {
    reply(output, outputSize, VERSION);
}

__declspec(dllexport) void __stdcall RVExtension(char *output, int outputSize, const char *function) {
    reply(output, outputSize, "");
    if (function == nullptr) {
        return;
    }
    start_once();

    if (std::strncmp(function, RECORD_PREFIX, std::strlen(RECORD_PREFIX)) == 0) {
        enqueue(function);
        return;
    }
    if (std::strncmp(function, "udp:", 4) == 0) {
        set_target(function + 4, output, outputSize);
        return;
    }
    if (std::strcmp(function, "version") == 0) {
        reply(output, outputSize, VERSION);
        return;
    }
    reply(output, outputSize, "error: unknown command");
}

}  // extern "C"

BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_DETACH) {
        g_running.store(false, std::memory_order_relaxed);
        g_wake.notify_all();
        // std::thread's destructor calls std::terminate on a thread that is
        // still joinable, which would abort the host process on exit. Joining
        // here could deadlock on the loader lock, so hand it to the OS.
        if (g_sender.joinable()) {
            g_sender.detach();
        }
    }
    return TRUE;
}
