// JustWisper's framed local live-ASR adapter. Built against whisper.cpp 1.9.4.
// Protocol v1: little-endian uint32 sample count + mono float32 16kHz PCM.
// stdout is newline JSON only; zero-length frame closes the session. No paths or commands on stdin.
#include <whisper.h>
#include <ggml-backend.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <iostream>
#include <string>
#include <vector>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

static std::string escaped(const char * input) {
    std::string out = "\"";
    for (const unsigned char * p = (const unsigned char *)input; *p; ++p) {
        if (*p == '"' || *p == '\\') { out += '\\'; out += *p; }
        else if (*p < 32) { char buf[7]; snprintf(buf, sizeof(buf), "\\u%04x", *p); out += buf; }
        else out += *p;
    }
    return out + "\"";
}
int main(int argc, char ** argv) {
#ifdef _WIN32
    // Windows text streams otherwise translate binary PCM newline bytes.
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    if (argc != 3) return 2;
    const std::string language = argv[2];
    if (language != "auto" && whisper_lang_id(language.c_str()) < 0) return 3;
    // Silence library logs (which may include local model paths); stdout belongs to the protocol.
    whisper_log_set([](enum ggml_log_level, const char *, void *) {}, nullptr);
    ggml_backend_load_all();
    auto cp = whisper_context_default_params();
    auto * ctx = whisper_init_from_file_with_params(argv[1], cp);
    if (!ctx) return 4;
    std::cout << "{\"ready\":true,\"protocol\":1}" << std::endl;
    uint32_t n;
    while (std::cin.read(reinterpret_cast<char *>(&n), sizeof(n))) {
        if (n == 0) break;
        if (n > 16 * 16000 || n < 1600) { whisper_free(ctx); return 5; }
        std::vector<float> pcm(n);
        if (!std::cin.read(reinterpret_cast<char *>(pcm.data()), n * sizeof(float))) break;
        bool silent = true;
        for (float value : pcm) {
            if (!std::isfinite(value)) { whisper_free(ctx); return 6; }
            if (std::abs(value) > .00001f) silent = false;
        }
        if (silent) { std::cout << "{\"segments\":[],\"silent\":true}" << std::endl; continue; }
        auto p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        p.n_threads = 4; p.no_context = true;
        p.print_realtime = false; p.print_progress = false; p.print_timestamps = false;
        p.print_special = false; p.language = language.c_str();
        p.translate = false; p.temperature = 0; p.temperature_inc = 0;
        p.token_timestamps = true; p.max_len = 1; p.split_on_word = true; p.max_tokens = 256;
        p.suppress_blank = true; p.suppress_nst = true;
        if (whisper_full(ctx, p, pcm.data(), (int)n) != 0) { whisper_free(ctx); return 7; }
        std::cout << "{\"segments\":[";
        int count = std::min(whisper_full_n_segments(ctx), 256);
        bool comma = false;
        for (int i = 0; i < count; ++i) {
            if (whisper_full_get_segment_t1(ctx, i) <= whisper_full_get_segment_t0(ctx, i)) continue;
            auto text = std::string(whisper_full_get_segment_text(ctx, i));
            if (text.empty()) continue;
            if (text.size() > 512) text.resize(512);
            if (comma) std::cout << ',';
            comma = true;
            std::cout << "{\"start\":" << whisper_full_get_segment_t0(ctx, i) / 100.0
                      << ",\"end\":" << whisper_full_get_segment_t1(ctx, i) / 100.0
                      << ",\"text\":" << escaped(text.c_str()) << '}';
        }
        std::cout << "]}" << std::endl;
    }
    whisper_free(ctx);
    return 0;
}
