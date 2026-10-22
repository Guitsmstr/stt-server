// stt-adapter-echo — fake model adapter for the stt-adapter/1 protocol.
//
// It validates the wire contract end to end without any ML model:
//   - emits the "ready" handshake
//   - reads length-prefixed PCM frames (uint32 LE + payload)
//   - emits one "final" event per frame with canned text
//   - on stdin EOF emits "bye" with byte count and FNV-1a checksum
//
// Test hooks:
//   - env STT_ECHO_CRASH_AFTER=N exits abruptly after N frames,
//     used to verify the nucleus restart policy.
//   - env STT_ECHO_PARTIALS=1 announces the "partial" capability and emits
//     one partial event before each final, used to verify [output] partials.
//
// Build: make -C adapters/echo

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static uint64_t fnv1a(const unsigned char *p, size_t n, uint64_t h) {
    for (size_t i = 0; i < n; i++) {
        h ^= (uint64_t)p[i];
        h *= 1099511628211ULL;
    }
    return h;
}

static bool read_full(FILE *f, void *buf, size_t n) {
    return fread(buf, 1, n, f) == n;
}

int main(int argc, char **argv) {
    std::string model = "echo";
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--model") == 0 && i + 1 < argc) {
            model = argv[++i];
        }
    }
    int crash_after = 0;
    if (const char *e = getenv("STT_ECHO_CRASH_AFTER")) {
        crash_after = atoi(e);
    }
    int partials = 0;
    if (const char *e = getenv("STT_ECHO_PARTIALS")) {
        partials = atoi(e);
    }

    // Header line (JSON) — consumed but unused by the echo adapter.
    char line[4096];
    if (!fgets(line, sizeof line, stdin)) {
        fprintf(stderr, "stt-adapter-echo: missing protocol header\n");
        return 1;
    }

    printf("{\"type\":\"ready\",\"protocol\":\"stt-adapter/1\",\"name\":\"echo\","
           "\"model\":\"%s\",\"audio\":{\"rate\":16000,\"channels\":1,\"format\":\"s16le\"},"
           "\"capabilities\":[%s]}\n",
           model.c_str(), partials ? "\"final\",\"partial\"" : "\"final\"");
    fflush(stdout);

    uint64_t h = 14695981039346656037ULL; // FNV-1a offset basis
    long long total = 0;
    int frame = 0;

    unsigned char lenbuf[4];
    std::string payload;
    while (read_full(stdin, lenbuf, 4)) {
        uint32_t n = (uint32_t)lenbuf[0] | ((uint32_t)lenbuf[1] << 8) |
                     ((uint32_t)lenbuf[2] << 16) | ((uint32_t)lenbuf[3] << 24);
        payload.resize(n);
        if (n > 0 && !read_full(stdin, &payload[0], n)) {
            fprintf(stderr, "stt-adapter-echo: truncated frame payload\n");
            return 1;
        }
        h = fnv1a((const unsigned char *)payload.data(), n, h);
        total += n;

        double t1 = (double)total / 32000.0; // 16 kHz mono s16le
        double t0 = t1 - (double)n / 32000.0;
        if (partials) {
            printf("{\"type\":\"partial\",\"text\":\"echo partial %d\",\"frame\":%d}\n",
                   frame, frame);
        }
        printf("{\"type\":\"final\",\"text\":\"echo frame %d\",\"frame\":%d,"
               "\"t0\":%.3f,\"t1\":%.3f,\"rtf\":0.0}\n",
               frame, frame, t0, t1);
        fflush(stdout);
        frame++;

        if (crash_after > 0 && frame >= crash_after) {
            fprintf(stderr, "stt-adapter-echo: intentional crash after %d frames\n", frame);
            return 2;
        }
    }

    printf("{\"type\":\"bye\",\"bytes\":%lld,\"fnv1a\":\"%016llx\"}\n",
           total, (unsigned long long)h);
    fflush(stdout);
    return 0;
}
