// stt-adapter-sherpa — sherpa-onnx streaming zipformer model adapter.
//
// Implements the model side of stt-adapter/1 (docs/CONTRATOS.md):
//   - reads the JSON protocol header from stdin
//   - loads a streaming zipformer (ONNX, sherpa-onnx C API)
//   - emits "ready" declaring capabilities final + partial
//   - reads length-prefixed PCM frames (s16le / 16 kHz / mono)
//   - while decoding: emits "partial" whenever the interim text changes
//   - at the end of each frame: emits one "final" with the text newly
//     decoded during that frame (same cadence as the moonshine adapter)
//   - on sherpa endpoint detection: emits the whole utterance as "final"
//     and resets the decoder (long-pause boundary)
//   - on stdin EOF flushes the tail, emits "bye" and exits 0
//
// Model directory (--model DIR) must contain tokens.txt plus encoder,
// decoder and joiner .onnx files (int8 variants preferred when present;
// auto-detected, overridable with --encoder/--decoder/--joiner/--tokens).
//
// sherpa-onnx is built from source against the system libonnxruntime
// (no Alpine package; prebuilt tarballs are glibc — see PLAN §Stage 5,
// D14): make -C var/tmp/sherpa-onnx/build && make -C adapters/sherpa
//
// Build: make -C adapters/sherpa

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
    std::string encoder, decoder, joiner, tokens;
    int threads = 2;
    bool endpoint = true;
    float rule1 = 2.4f; // trailing silence (s) with speech before it
    float rule2 = 1.2f; // trailing silence (s) after decoded utterance
    float rule3 = 20.0f; // utterance length (s) regardless of silence
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

// Defensive UTF-8 sanitize (tokens are UTF-8 clean; same policy as the
// moonshine adapter so stt-events/1 never carries invalid UTF-8).
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
    return p.substr(s == std::string::npos ? 0 : s + 1, end - (s == std::string::npos ? 0 : s + 1) + 1);
}

// ------------------------------------------------------------ model lookup

// Lists *.onnx / *.txt entries of dir (plain filenames, no recursion).
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

// Picks the file whose name contains the must-substring; when int8 variants
// exist they win (deterministic pick in dirs holding several exports).
bool pick_file(const std::vector<std::string> &files, const std::string &must,
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

bool resolve_model(const Options &o, std::string *enc, std::string *dec,
                   std::string *join, std::string *toks, std::string *err) {
    if (o.model_dir.empty()) {
        *err = "--model DIR is required (tokens.txt + encoder/decoder/joiner .onnx)";
        return false;
    }
    const auto files = list_dir(o.model_dir);
    std::string name;
    if (!o.encoder.empty()) {
        *enc = o.encoder;
    } else if (pick_file(files, "encoder", &name)) {
        *enc = o.model_dir + "/" + name;
    } else {
        *err = "no encoder .onnx in " + o.model_dir;
        return false;
    }
    if (!o.decoder.empty()) {
        *dec = o.decoder;
    } else if (pick_file(files, "decoder", &name)) {
        *dec = o.model_dir + "/" + name;
    } else {
        *err = "no decoder .onnx in " + o.model_dir;
        return false;
    }
    if (!o.joiner.empty()) {
        *join = o.joiner;
    } else if (pick_file(files, "joiner", &name)) {
        *join = o.model_dir + "/" + name;
    } else {
        *err = "no joiner .onnx in " + o.model_dir;
        return false;
    }
    if (!o.tokens.empty()) {
        *toks = o.tokens;
    } else {
        *toks = o.model_dir + "/tokens.txt";
        FILE *f = std::fopen(toks->c_str(), "rb");
        if (!f) {
            *err = "no tokens.txt in " + o.model_dir;
            return false;
        }
        std::fclose(f);
    }
    return true;
}

void usage(FILE *f) {
    std::fputs("usage: stt-adapter-sherpa --model DIR [--encoder FILE] [--decoder FILE]\n"
               "       [--joiner FILE] [--tokens FILE] [--threads N] [--no-endpoint]\n"
               "       [--rule1 S] [--rule2 S] [--rule3 S]\n",
               f);
}

// ---------------------------------------------------------------- main loop

// Drains the decoder and emits a partial whenever the interim text changes.
// Returns the current full utterance text.
std::string drain(const SherpaOnnxOnlineRecognizer *rec,
                  const SherpaOnnxOnlineStream *stream, int frame,
                  std::string *last_partial, double *infer_s) {
    const auto t0 = std::chrono::steady_clock::now();
    while (SherpaOnnxIsOnlineStreamReady(rec, stream)) {
        SherpaOnnxDecodeOnlineStream(rec, stream);
        const auto *r = SherpaOnnxGetOnlineStreamResult(rec, stream);
        std::string text = utf8_sanitize(r->text ? r->text : "");
        SherpaOnnxDestroyOnlineRecognizerResult(r);
        if (!text.empty() && text != *last_partial) {
            std::string body = "{\"type\":\"partial\",\"text\":\"";
            json_cat(&body, text);
            body += "\",\"frame\":" + std::to_string(frame) + "}";
            emit_event(stdout, body);
            *last_partial = text;
        }
    }
    *infer_s += std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    const auto *r = SherpaOnnxGetOnlineStreamResult(rec, stream);
    std::string text = utf8_sanitize(r->text ? r->text : "");
    SherpaOnnxDestroyOnlineRecognizerResult(r);
    return text;
}

void emit_final(const std::string &text, int frame, double infer_s, double dur_s) {
    const double rtf = dur_s > 0.0 ? infer_s / dur_s : 0.0;
    std::string body = "{\"type\":\"final\",\"text\":\"";
    json_cat(&body, text);
    body += "\",\"frame\":" + std::to_string(frame);
    body += ",\"rtf\":" + num(rtf);
    body += "}";
    emit_event(stdout, body);
}

} // namespace

int main(int argc, char **argv) {
    Options o;
    for (int i = 1; i < argc; ++i) {
        auto need = [&](const char *flag) -> const char * {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "stt-adapter-sherpa: %s needs a value\n", flag);
                std::exit(2);
            }
            return argv[++i];
        };
        if (std::strcmp(argv[i], "--model") == 0) o.model_dir = need("--model");
        else if (std::strcmp(argv[i], "--encoder") == 0) o.encoder = need("--encoder");
        else if (std::strcmp(argv[i], "--decoder") == 0) o.decoder = need("--decoder");
        else if (std::strcmp(argv[i], "--joiner") == 0) o.joiner = need("--joiner");
        else if (std::strcmp(argv[i], "--tokens") == 0) o.tokens = need("--tokens");
        else if (std::strcmp(argv[i], "--threads") == 0) o.threads = std::atoi(need("--threads"));
        else if (std::strcmp(argv[i], "--no-endpoint") == 0) o.endpoint = false;
        else if (std::strcmp(argv[i], "--rule1") == 0) o.rule1 = std::atof(need("--rule1"));
        else if (std::strcmp(argv[i], "--rule2") == 0) o.rule2 = std::atof(need("--rule2"));
        else if (std::strcmp(argv[i], "--rule3") == 0) o.rule3 = std::atof(need("--rule3"));
        else if (std::strcmp(argv[i], "-h") == 0 || std::strcmp(argv[i], "--help") == 0) {
            usage(stdout);
            return 0;
        } else {
            std::fprintf(stderr, "stt-adapter-sherpa: unknown argument: %s\n", argv[i]);
            usage(stderr);
            return 2;
        }
    }
    if (o.threads <= 0) o.threads = 2;

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
        emit_error("audio", "unsupported audio format: sherpa adapter needs s16le/16000/mono",
                   true);
        return 1;
    }

    std::string enc, dec, join, toks, err;
    if (!resolve_model(o, &enc, &dec, &join, &toks, &err)) {
        emit_error("model", err, true);
        return 1;
    }

    SherpaOnnxOnlineRecognizerConfig cfg;
    std::memset(&cfg, 0, sizeof(cfg));
    cfg.feat_config.sample_rate = kSampleRate;
    cfg.feat_config.feature_dim = 80;
    cfg.model_config.transducer.encoder = enc.c_str();
    cfg.model_config.transducer.decoder = dec.c_str();
    cfg.model_config.transducer.joiner = join.c_str();
    cfg.model_config.tokens = toks.c_str();
    cfg.model_config.num_threads = o.threads;
    cfg.model_config.provider = "cpu";
    cfg.decoding_method = "greedy_search";
    cfg.enable_endpoint = o.endpoint ? 1 : 0;
    cfg.rule1_min_trailing_silence = o.rule1;
    cfg.rule2_min_trailing_silence = o.rule2;
    cfg.rule3_min_utterance_length = o.rule3;

    const auto t_load = std::chrono::steady_clock::now();
    const SherpaOnnxOnlineRecognizer *rec = SherpaOnnxCreateOnlineRecognizer(&cfg);
    if (!rec) {
        emit_error("model", "sherpa-onnx: failed to load model from " + o.model_dir, true);
        return 1;
    }
    const double load_s =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - t_load).count();
    const SherpaOnnxOnlineStream *stream = SherpaOnnxCreateOnlineStream(rec);
    if (!stream) {
        emit_error("model", "sherpa-onnx: failed to create stream", true);
        SherpaOnnxDestroyOnlineRecognizer(rec);
        return 1;
    }
    std::fprintf(stderr,
                 "stt-adapter-sherpa: loaded %s in %.2fs (threads=%d, endpoint=%d)\n",
                 o.model_dir.c_str(), load_s, o.threads, o.endpoint ? 1 : 0);

    emit_event(stdout,
               "{\"type\":\"ready\",\"protocol\":\"stt-adapter/1\",\"name\":\"sherpa\","
               "\"model\":\"" +
                   basename_of(o.model_dir) +
                   "\",\"audio\":{\"rate\":16000,\"channels\":1,\"format\":\"s16le\"},"
                   "\"capabilities\":[\"final\",\"partial\"]}");

    std::string last_partial; // interim text already sent as partial
    std::string baseline;     // utterance text already covered by a final
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

        const double dur_s = static_cast<double>(n_samples) / kSampleRate;
        double infer_s = 0.0;

        if (n_samples > 0) {
            // s16le -> f32 in [-1, 1) (sherpa expects normalized floats).
            samples.resize(n_samples);
            for (size_t i = 0; i < n_samples; ++i)
                samples[i] = static_cast<float>(pcm[i]) / 32768.0f;
            SherpaOnnxOnlineStreamAcceptWaveform(stream, kSampleRate, samples.data(),
                                                 static_cast<int32_t>(n_samples));
        }
        std::string text = drain(rec, stream, frame, &last_partial, &infer_s);
        total_infer += infer_s;

        if (o.endpoint && SherpaOnnxOnlineStreamIsEndpoint(rec, stream)) {
            // Silence boundary: the whole in-progress utterance is final.
            if (!text.empty()) emit_final(text, frame, infer_s, dur_s);
            SherpaOnnxOnlineStreamReset(rec, stream);
            last_partial.clear();
            baseline.clear();
        } else if (text.size() >= baseline.size() &&
                   text.compare(0, baseline.size(), baseline) == 0) {
            // Normal path: the text grows monotonically; report the new tail.
            std::string delta = text.substr(baseline.size());
            if (!delta.empty() && delta[0] == ' ') delta.erase(0, 1);
            if (!delta.empty()) {
                emit_final(delta, frame, infer_s, dur_s);
                baseline = text;
            }
        } else {
            // Text shrank/diverged without an endpoint (should not happen);
            // fall back to reporting the full text to stay consistent.
            if (!text.empty()) emit_final(text, frame, infer_s, dur_s);
            baseline = text;
        }

        total_bytes += n;
        ++frame;
    }

    // EOF: flush the tail of the stream (padding) and emit what is left.
    SherpaOnnxOnlineStreamInputFinished(stream);
    double tail_infer = 0.0;
    std::string text = drain(rec, stream, frame > 0 ? frame - 1 : 0, &last_partial,
                             &tail_infer);
    total_infer += tail_infer;
    if (text.size() > baseline.size() &&
        text.compare(0, baseline.size(), baseline) == 0) {
        std::string delta = text.substr(baseline.size());
        if (!delta.empty() && delta[0] == ' ') delta.erase(0, 1);
        if (!delta.empty() && frame > 0) emit_final(delta, frame - 1, tail_infer, 0.0);
    }

    SherpaOnnxDestroyOnlineStream(stream);
    SherpaOnnxDestroyOnlineRecognizer(rec);

    const double audio_s = static_cast<double>(total_bytes) / (kSampleRate * kBytesPerSample);
    struct rusage ru {};
    if (getrusage(RUSAGE_SELF, &ru) != 0) ru.ru_maxrss = 0;
    emit_event(stdout,
               "{\"type\":\"bye\",\"frames\":" + std::to_string(frame) +
                   ",\"audio_s\":" + num(audio_s) +
                   ",\"infer_s\":" + num(total_infer) +
                   ",\"rss_kb\":" + std::to_string(static_cast<long>(ru.ru_maxrss)) + "}");
    return 0;
}
