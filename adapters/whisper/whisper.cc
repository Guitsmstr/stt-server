// stt-adapter-whisper — sherpa-onnx offline Whisper model adapter.
//
// Implements the model side of stt-adapter/1 (docs/CONTRATOS.md):
//   - reads the JSON protocol header from stdin
//   - loads a Whisper encoder/decoder pair (ONNX, sherpa-onnx C API,
//     OfflineRecognizer with model_type=whisper)
//   - emits "ready" declaring the single capability "final"
//   - reads length-prefixed PCM frames (s16le / 16 kHz / mono) and
//     transcribes each frame as one complete utterance (same cadence as
//     the moonshine adapter): one "final" per frame, no partials —
//     Whisper is non-streaming, so interim output would be a lie
//   - on stdin EOF emits "bye" and exits 0
//
// Why this adapter exists: Whisper-small trades latency for accuracy.
// It is NOT a live dictation engine on this device (RTF > 1 on a phone
// CPU); it is for accuracy evaluation and offline second passes over
// saved audio (see docs/PLAN.md / the model ladder in the session log).
//
// Model directory (--model DIR) must contain encoder/decoder .onnx and a
// tokens file (int8 variants preferred when present; auto-detected,
// overridable with --encoder/--decoder/--tokens).
//
// Language is auto-detected per frame by default (sherpa-onnx detects the
// language token); pin one with --language es / --language en when the
// input language is known (fewer detection mistakes, slightly faster).
//
// Build: make -C adapters/whisper   (same sherpa-onnx static build as
// adapters/sherpa: var/tmp/sherpa-onnx, see adapters/sherpa/Makefile).

#include "sherpa-onnx/c-api/c-api.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <string>
#include <sys/resource.h>
#include <vector>

namespace {

constexpr int kSampleRate = 16000;
constexpr int kChannels = 1;
constexpr int kBytesPerSample = 2;

struct Options {
    std::string model_dir;
    std::string encoder, decoder, tokens;
    int threads = 2;
    std::string language; // empty = auto-detect per utterance
    std::string task = "transcribe"; // or "translate" (to English)
    int tail_paddings = 800; // mel frames of trailing silence (whisper CLI default)
};

// ---------------------------------------------------------------- utilities

bool read_full(FILE *f, void *buf, size_t n) {
    return n == 0 || std::fread(buf, 1, n, f) == n;
}

bool read_line(FILE *f, std::string &line) {
    line.clear();
    int c;
    bool any = false;
    while ((c = std::fgetc(f)) != EOF) {
        any = true;
        if (c == '\n') return true;
        line.push_back(static_cast<char>(c));
        if (line.size() > (1u << 20)) return false;
    }
    return any;
}

// Extracts the integer that follows `"key":` in a single-line JSON object.
bool json_int(const std::string &json, const std::string &key, long *out) {
    size_t p = json.find("\"" + key + "\"");
    if (p == std::string::npos) return false;
    p = json.find(':', p + key.size() + 2);
    if (p == std::string::npos) return false;
    const char *s = json.c_str() + p + 1;
    char *end = nullptr;
    long v = std::strtol(s, &end, 10);
    if (end == s) return false;
    *out = v;
    return true;
}

void emit_event(FILE *f, const std::string &body) {
    std::fputs(body.c_str(), f);
    std::fputc('\n', f);
    std::fflush(f);
}

// Appends s as a JSON string body (UTF-8 passthrough, control chars escaped).
void json_cat(std::string *body, const std::string &s) {
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') body->push_back('\\');
        if (c >= 0x20) {
            body->push_back(static_cast<char>(c));
        } else {
            char buf[8];
            std::snprintf(buf, sizeof(buf), "\\u%04x", c);
            *body += buf;
        }
    }
}

std::string num(double v) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%.3f", v);
    return buf;
}

void emit_error(const std::string &code, const std::string &message, bool fatal) {
    std::string body = "{\"type\":\"error\",\"code\":\"" + code +
                       "\",\"message\":\"";
    json_cat(&body, message);
    body += "\",\"fatal\":";
    body += fatal ? "true" : "false";
    body += "}";
    emit_event(stdout, body);
}

// Defensive UTF-8 sanitize (same policy as the moonshine/sherpa adapters so
// stt-events/1 never carries invalid UTF-8).
std::string utf8_sanitize(const std::string &in) {
    std::string out;
    out.reserve(in.size());
    size_t i = 0, n = in.size();
    while (i < n) {
        unsigned char c = static_cast<unsigned char>(in[i]);
        if (c < 0x80) {
            out.push_back(static_cast<char>(c));
            ++i;
            continue;
        }
        int len = 0;
        if (c >= 0xC2 && c <= 0xDF) len = 2;
        else if (c >= 0xE0 && c <= 0xEF) len = 3;
        else if (c >= 0xF0 && c <= 0xF4) len = 4;
        bool ok = len > 0 && i + static_cast<size_t>(len) <= n;
        if (ok) {
            for (int k = 1; k < len; ++k) {
                if ((static_cast<unsigned char>(in[i + k]) & 0xC0) != 0x80) {
                    ok = false;
                    break;
                }
            }
        }
        if (ok && len == 3) {
            unsigned char c1 = static_cast<unsigned char>(in[i + 1]);
            if (c == 0xE0 && c1 < 0xA0) ok = false;
            if (c == 0xED && c1 >= 0xA0) ok = false;
        }
        if (ok && len == 4) {
            unsigned char c1 = static_cast<unsigned char>(in[i + 1]);
            if (c == 0xF0 && c1 < 0x90) ok = false;
            if (c == 0xF4 && c1 >= 0x90) ok = false;
        }
        if (ok) {
            out.append(in, i, static_cast<size_t>(len));
            i += static_cast<size_t>(len);
        } else {
            out += "\xEF\xBF\xBD"; // U+FFFD
            ++i;
        }
    }
    return out;
}

std::string basename_of(const std::string &p) {
    size_t end = p.find_last_not_of('/');
    if (end == std::string::npos) return p;
    size_t s = p.find_last_of('/', end);
    return p.substr(s == std::string::npos ? 0 : s + 1,
                    end - (s == std::string::npos ? 0 : s + 1) + 1);
}

long rss_kb() {
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) != 0) return 0;
    return static_cast<long>(ru.ru_maxrss);
}

// ------------------------------------------------------------ model lookup

// Lists dir entries (plain filenames, no recursion).
std::vector<std::string> list_dir(const std::string &dir) {
    std::vector<std::string> out;
    DIR *d = opendir(dir.c_str());
    if (!d) return out;
    while (struct dirent *e = readdir(d)) {
        std::string n = e->d_name;
        if (n == "." || n == "..") continue;
        out.push_back(n);
    }
    closedir(d);
    return out;
}

// Picks the .onnx whose name contains must; int8 variants win (deterministic
// pick in dirs holding several exports).
bool pick_onnx(const std::vector<std::string> &files, const std::string &must,
               std::string *out) {
    const std::string *best = nullptr;
    for (const auto &f : files) {
        if (f.find(must) == std::string::npos ||
            f.find(".onnx") == std::string::npos)
            continue;
        if (f.find("int8") != std::string::npos) {
            *out = f;
            return true;
        }
        if (!best) best = &f;
    }
    if (!best) return false;
    *out = *best;
    return true;
}

// Tokens file: "tokens.txt" wins, else any "*tokens*.txt".
bool pick_tokens(const std::vector<std::string> &files, std::string *out) {
    const std::string *best = nullptr;
    for (const auto &f : files) {
        if (f == "tokens.txt") {
            *out = f;
            return true;
        }
        if (f.find("tokens") != std::string::npos &&
            f.find(".txt") != std::string::npos && !best)
            best = &f;
    }
    if (!best) return false;
    *out = *best;
    return true;
}

bool resolve_model(const Options &o, std::string *enc, std::string *dec,
                   std::string *toks, std::string *err) {
    if (o.model_dir.empty()) {
        *err = "--model DIR is required (encoder/decoder .onnx + tokens file)";
        return false;
    }
    const auto files = list_dir(o.model_dir);
    std::string name;
    if (!o.encoder.empty()) {
        *enc = o.encoder;
    } else if (pick_onnx(files, "encoder", &name)) {
        *enc = o.model_dir + "/" + name;
    } else {
        *err = "no encoder .onnx in " + o.model_dir;
        return false;
    }
    if (!o.decoder.empty()) {
        *dec = o.decoder;
    } else if (pick_onnx(files, "decoder", &name)) {
        *dec = o.model_dir + "/" + name;
    } else {
        *err = "no decoder .onnx in " + o.model_dir;
        return false;
    }
    if (!o.tokens.empty()) {
        *toks = o.tokens;
    } else if (pick_tokens(files, &name)) {
        *toks = o.model_dir + "/" + name;
    } else {
        *err = "no tokens file in " + o.model_dir;
        return false;
    }
    return true;
}

void usage(FILE *f) {
    std::fputs(
        "usage: stt-adapter-whisper --model DIR [--encoder FILE] [--decoder FILE]\n"
        "       [--tokens FILE] [--threads N] [--language CODE] [--task transcribe|translate]\n"
        "       [--tail-paddings N]\n"
        "  Whisper is non-streaming: every input frame is transcribed as one\n"
        "  complete utterance and emitted as a single final. Expect RTF > 1\n"
        "  on phone CPUs — this adapter is for accuracy, not live captions.\n"
        "  --language: pin the input language (es, en, ...). Empty (default)\n"
        "      = auto-detect per utterance.\n"
        "  --task: transcribe (default) or translate (into English).\n"
        "  --tail-paddings: mel frames of trailing silence appended before\n"
        "      decoding (default 800). Higher = more hallucination guard on\n"
        "      short clips, slower.\n",
        f);
}

} // namespace

int main(int argc, char **argv) {
    Options o;
    for (int i = 1; i < argc; ++i) {
        auto need = [&](const char *flag) -> const char * {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "stt-adapter-whisper: %s needs a value\n", flag);
                std::exit(2);
            }
            return argv[++i];
        };
        if (std::strcmp(argv[i], "--model") == 0) o.model_dir = need("--model");
        else if (std::strcmp(argv[i], "--encoder") == 0) o.encoder = need("--encoder");
        else if (std::strcmp(argv[i], "--decoder") == 0) o.decoder = need("--decoder");
        else if (std::strcmp(argv[i], "--tokens") == 0) o.tokens = need("--tokens");
        else if (std::strcmp(argv[i], "--threads") == 0) o.threads = std::atoi(need("--threads"));
        else if (std::strcmp(argv[i], "--language") == 0) o.language = need("--language");
        else if (std::strcmp(argv[i], "--task") == 0) o.task = need("--task");
        else if (std::strcmp(argv[i], "--tail-paddings") == 0)
            o.tail_paddings = std::atoi(need("--tail-paddings"));
        else if (std::strcmp(argv[i], "-h") == 0 || std::strcmp(argv[i], "--help") == 0) {
            usage(stdout);
            return 0;
        } else {
            std::fprintf(stderr, "stt-adapter-whisper: unknown argument: %s\n", argv[i]);
            usage(stderr);
            return 2;
        }
    }
    if (o.threads <= 0) o.threads = 2;
    if (o.task != "transcribe" && o.task != "translate") {
        emit_error("model", "--task: only transcribe and translate are supported", true);
        return 1;
    }
    if (o.tail_paddings < 0) o.tail_paddings = 0;
    if (o.tail_paddings > 3000) o.tail_paddings = 3000;

    // Protocol header must be read before anything else (nucleus sends it
    // immediately after spawn; see CONTRATOS §2.2).
    std::string header;
    if (!read_line(stdin, header) || header.find('{') == std::string::npos) {
        emit_error("protocol", "missing stt-adapter/1 header line", true);
        return 1;
    }
    long rate = 0, channels = 0;
    json_int(header, "rate", &rate);
    if (!json_int(header, "channels", &channels)) channels = 1;
    if (rate != kSampleRate || channels != kChannels) {
        emit_error("audio", "unsupported audio format: whisper adapter needs s16le/16000/mono",
                   true);
        return 1;
    }

    std::string enc, dec, toks, err;
    if (!resolve_model(o, &enc, &dec, &toks, &err)) {
        emit_error("model", err, true);
        return 1;
    }

    SherpaOnnxOfflineRecognizerConfig cfg;
    std::memset(&cfg, 0, sizeof(cfg));
    cfg.feat_config.sample_rate = kSampleRate;
    cfg.feat_config.feature_dim = 80; // whisper log-mel
    cfg.model_config.tokens = toks.c_str();
    cfg.model_config.num_threads = o.threads;
    cfg.model_config.provider = "cpu";
    cfg.model_config.model_type = "whisper";
    cfg.model_config.whisper.encoder = enc.c_str();
    cfg.model_config.whisper.decoder = dec.c_str();
    cfg.model_config.whisper.language = o.language.c_str(); // "" = auto-detect
    cfg.model_config.whisper.task = o.task.c_str();
    cfg.model_config.whisper.tail_paddings = o.tail_paddings;
    cfg.decoding_method = "greedy_search";

    const auto t_load = std::chrono::steady_clock::now();
    const SherpaOnnxOfflineRecognizer *rec = SherpaOnnxCreateOfflineRecognizer(&cfg);
    if (!rec) {
        emit_error("model", "sherpa-onnx: failed to load whisper model from " + o.model_dir,
                   true);
        return 1;
    }
    const double load_s =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - t_load).count();
    std::fprintf(stderr,
                 "stt-adapter-whisper: loaded %s in %.2fs (threads=%d, task=%s, "
                 "language=%s, tail_paddings=%d)\n",
                 o.model_dir.c_str(), load_s, o.threads, o.task.c_str(),
                 o.language.empty() ? "auto" : o.language.c_str(), o.tail_paddings);

    emit_event(stdout,
               "{\"type\":\"ready\",\"protocol\":\"stt-adapter/1\",\"name\":\"whisper\","
               "\"model\":\"" +
                   basename_of(o.model_dir) +
                   "\",\"audio\":{\"rate\":16000,\"channels\":1,\"format\":\"s16le\"},"
                   "\"capabilities\":[\"final\"]}");

    unsigned char lenbuf[4];
    std::vector<int16_t> pcm;
    std::vector<float> samples;
    long long total_bytes = 0;
    int frame = 0;
    double total_infer = 0.0;

    while (read_full(stdin, lenbuf, 4)) {
        const uint32_t n = static_cast<uint32_t>(lenbuf[0]) |
                           (static_cast<uint32_t>(lenbuf[1]) << 8) |
                           (static_cast<uint32_t>(lenbuf[2]) << 16) |
                           (static_cast<uint32_t>(lenbuf[3]) << 24);
        if (n % kBytesPerSample != 0) {
            emit_error("protocol", "PCM frame payload is not a whole number of s16 samples",
                       true);
            return 1;
        }
        const size_t n_samples = n / kBytesPerSample;
        pcm.resize(n_samples);
        if (n > 0 && !read_full(stdin, pcm.data(), n)) {
            emit_error("protocol", "truncated PCM frame payload", true);
            return 1;
        }
        total_bytes += n;

        // One fresh offline stream per frame: every frame is a complete
        // utterance (stt-adapter/1 §2.2) and Whisper carries no state
        // between calls by design.
        const auto t0 = std::chrono::steady_clock::now();
        if (n_samples > 0) {
            samples.resize(n_samples);
            for (size_t i = 0; i < n_samples; ++i)
                samples[i] = static_cast<float>(pcm[i]) / 32768.0f;

            const SherpaOnnxOfflineStream *s = SherpaOnnxCreateOfflineStream(rec);
            if (!s) {
                emit_error("model", "sherpa-onnx: failed to create offline stream", true);
                return 1;
            }
            SherpaOnnxAcceptWaveformOffline(s, kSampleRate, samples.data(),
                                            static_cast<int32_t>(n_samples));
            SherpaOnnxDecodeOfflineStream(rec, s);
            const SherpaOnnxOfflineRecognizerResult *r = SherpaOnnxGetOfflineStreamResult(s);
            std::string text = utf8_sanitize(r && r->text ? r->text : "");
            SherpaOnnxDestroyOfflineRecognizerResult(r);
            SherpaOnnxDestroyOfflineStream(s);

            const double infer_s =
                std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
            total_infer += infer_s;
            const double dur_s = static_cast<double>(n_samples) / kSampleRate;

            if (!text.empty()) {
                // Trim surrounding whitespace (whisper emits leading spaces).
                size_t b = text.find_first_not_of(" \t");
                size_t e = text.find_last_not_of(" \t");
                if (b != std::string::npos) text = text.substr(b, e - b + 1);
            }
            if (!text.empty()) {
                const double rtf = dur_s > 0.0 ? infer_s / dur_s : 0.0;
                std::string body = "{\"type\":\"final\",\"text\":\"";
                json_cat(&body, text);
                body += "\",\"frame\":" + std::to_string(frame);
                body += ",\"rtf\":" + num(rtf);
                body += "}";
                emit_event(stdout, body);
            }
        }
        ++frame;
    }

    const double audio_s = static_cast<double>(total_bytes) / (kSampleRate * kBytesPerSample);
    std::string bye = "{\"type\":\"bye\",\"frames\":" + std::to_string(frame);
    bye += ",\"bytes\":" + std::to_string(total_bytes);
    bye += ",\"audio_s\":" + num(audio_s);
    bye += ",\"infer_s\":" + num(total_infer);
    bye += ",\"rss_kb\":" + std::to_string(rss_kb());
    bye += "}";
    emit_event(stdout, bye);

    SherpaOnnxDestroyOfflineRecognizer(rec);
    return 0;
}
