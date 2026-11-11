#include "ClassicOgg.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"
#include "opus.h"

static void fail(char *error, size_t length, const char *message) {
    if (error && length) {
        strncpy(error, message, length - 1);
        error[length - 1] = 0;
    }
}

// MARK: - Ogg page reader

typedef struct {
    FILE *file;
    uint32_t serial;
    int haveSerial;
    uint8_t *packet;     // packet being assembled across lacing values and pages
    size_t packetLength;
    size_t packetCapacity;
    int64_t lastGranule;
    uint8_t segments[255];
    int segmentCount;
    int segmentIndex;
    uint8_t *page;       // body of the current page
    size_t pageLength;
    size_t pagePosition;
    int endOfStream;
} OggReader;

static int read_page(OggReader *r) {
    for (;;) {
        uint8_t header[27];
        if (fread(header, 1, 27, r->file) != 27) return 0;
        if (memcmp(header, "OggS", 4) != 0) return 0;
        int64_t granule = 0;
        for (int i = 7; i >= 0; i--) granule = (granule << 8) | header[6 + i];
        uint32_t serial = header[14] | header[15] << 8 | header[16] << 16 | (uint32_t)header[17] << 24;
        int count = header[26];
        if (fread(r->segments, 1, count, r->file) != (size_t)count) return 0;
        size_t body = 0;
        for (int i = 0; i < count; i++) body += r->segments[i];
        free(r->page);
        r->page = malloc(body ? body : 1);
        if (!r->page || fread(r->page, 1, body, r->file) != body) return 0;
        // Only the first logical stream is read; chained or multiplexed streams are ignored.
        if (!r->haveSerial) { r->serial = serial; r->haveSerial = 1; }
        if (serial != r->serial) continue;
        if (granule >= 0) r->lastGranule = granule;
        r->endOfStream = header[5] & 4;
        r->segmentCount = count;
        r->segmentIndex = 0;
        r->pageLength = body;
        r->pagePosition = 0;
        return 1;
    }
}

// The next complete packet, valid until the following call. Returns 0 at the end of the stream.
static int next_packet(OggReader *r, uint8_t **data, size_t *length) {
    r->packetLength = 0;
    for (;;) {
        while (r->segmentIndex < r->segmentCount) {
            int lace = r->segments[r->segmentIndex++];
            if (r->packetLength + lace > r->packetCapacity) {
                r->packetCapacity = (r->packetLength + lace) * 2 + 256;
                r->packet = realloc(r->packet, r->packetCapacity);
                if (!r->packet) return 0;
            }
            memcpy(r->packet + r->packetLength, r->page + r->pagePosition, lace);
            r->packetLength += lace;
            r->pagePosition += lace;
            if (lace < 255) {
                *data = r->packet;
                *length = r->packetLength;
                return 1;
            }
        }
        if (r->endOfStream) return 0;
        if (!read_page(r)) return 0;
    }
}

static void reader_close(OggReader *r) {
    if (r->file) fclose(r->file);
    free(r->packet);
    free(r->page);
}

// MARK: - Scan

typedef struct { int channels; int preSkip; int gainQ8; int family; } OpusHead;

static int parse_opus_head(const uint8_t *p, size_t n, OpusHead *head) {
    if (n < 19 || memcmp(p, "OpusHead", 8) != 0) return 0;
    head->channels = p[9];
    head->preSkip = p[10] | p[11] << 8;
    head->gainQ8 = (int16_t)(p[16] | p[17] << 8);
    head->family = p[18];
    return 1;
}

int ct_ogg_scan(const char *path, CTOggInfo *info, char *error, size_t errorLength) {
    memset(info, 0, sizeof *info);
    OggReader r;
    memset(&r, 0, sizeof r);
    r.file = fopen(path, "rb");
    if (!r.file) { fail(error, errorLength, "The file could not be opened."); return 1; }

    uint8_t *data; size_t length;
    int result = 1;
    OpusHead opus = {0};
    int vorbisRate = 0, nominalBitrate = 0;
    if (!next_packet(&r, &data, &length)) { fail(error, errorLength, "Not an Ogg file."); goto done; }

    if (length >= 30 && data[0] == 1 && memcmp(data + 1, "vorbis", 6) == 0) {
        info->kind = 1;
        info->channels = data[11];
        vorbisRate = data[12] | data[13] << 8 | data[14] << 16 | (uint32_t)data[15] << 24;
        nominalBitrate = (int32_t)(data[20] | data[21] << 8 | data[22] << 16 | (uint32_t)data[23] << 24);
        info->sampleRate = vorbisRate;
    } else if (parse_opus_head(data, length, &opus)) {
        info->kind = 2;
        info->channels = opus.channels;
        info->sampleRate = 48000;
    } else {
        fail(error, errorLength, "This Ogg file is not Vorbis or Opus audio.");
        goto done;
    }

    if (!next_packet(&r, &data, &length)) { fail(error, errorLength, "The file ends before its tags."); goto done; }
    size_t skip = info->kind == 1 ? 7 : 8;
    int valid = info->kind == 1 ? (length >= 7 && data[0] == 3 && memcmp(data + 1, "vorbis", 6) == 0)
                                : (length >= 8 && memcmp(data, "OpusTags", 8) == 0);
    if (valid && length > skip) {
        info->comments = malloc(length - skip);
        if (info->comments) {
            memcpy(info->comments, data + skip, length - skip);
            info->commentsLength = length - skip;
        }
    }

    // Duration comes from the final page's granule position. Only the end of the file is read, so
    // scanning a large library doesn't mean reading all of it.
    int64_t finalGranule = -1;
    {
        fseek(r.file, 0, SEEK_END);
        long size = ftell(r.file);
        long start = size > 65536 ? size - 65536 : 0;
        fseek(r.file, start, SEEK_SET);
        uint8_t *tail = malloc((size_t)(size - start) + 1);
        size_t got = tail ? fread(tail, 1, (size_t)(size - start), r.file) : 0;
        for (long i = (long)got - 27; i >= 0; i--) {
            if (memcmp(tail + i, "OggS", 4) != 0) continue;
            uint32_t serial = tail[i + 14] | tail[i + 15] << 8 | tail[i + 16] << 16 | (uint32_t)tail[i + 17] << 24;
            int64_t granule = 0;
            for (int b = 7; b >= 0; b--) granule = (granule << 8) | tail[i + 6 + b];
            if (serial == r.serial && granule >= 0) { finalGranule = granule; break; }
        }
        free(tail);
    }
    if (finalGranule < 0) {
        // No usable page in the tail: walk the file page by page instead.
        fseek(r.file, 0, SEEK_SET);
        OggReader walker;
        memset(&walker, 0, sizeof walker);
        walker.file = r.file;
        while (read_page(&walker)) {}
        finalGranule = walker.lastGranule;
        free(walker.page);
        free(walker.packet);
    }
    r.lastGranule = finalGranule;
    double samples = (double)r.lastGranule - (info->kind == 2 ? opus.preSkip : 0);
    if (samples < 0) samples = 0;
    info->duration = info->sampleRate > 0 ? samples / info->sampleRate : 0;
    if (info->duration > 0) {
        fseek(r.file, 0, SEEK_END);
        info->bitrateKbps = (double)ftell(r.file) * 8.0 / info->duration / 1000.0;
    } else if (nominalBitrate > 0) {
        info->bitrateKbps = nominalBitrate / 1000.0;
    }
    result = 0;
done:
    reader_close(&r);
    return result;
}

void ct_ogg_free(uint8_t *pointer) { free(pointer); }

// MARK: - WAV output

static void put_le(uint8_t *p, uint32_t value, int bytes) {
    for (int i = 0; i < bytes; i++) p[i] = (value >> (8 * i)) & 0xFF;
}

static int write_wav_header(FILE *f, int channels, int rate, uint32_t dataBytes) {
    uint8_t h[44];
    memcpy(h, "RIFF", 4); put_le(h + 4, 36 + dataBytes, 4);
    memcpy(h + 8, "WAVEfmt ", 8); put_le(h + 16, 16, 4); put_le(h + 20, 1, 2);
    put_le(h + 22, channels, 2); put_le(h + 24, rate, 4);
    put_le(h + 28, rate * channels * 2, 4); put_le(h + 32, channels * 2, 2); put_le(h + 34, 16, 2);
    memcpy(h + 36, "data", 4); put_le(h + 40, dataBytes, 4);
    return fwrite(h, 1, 44, f) == 44;
}

static void store_samples(uint8_t *dest, const int16_t *src, size_t count) {
    for (size_t i = 0; i < count; i++) put_le(dest + 2 * i, (uint16_t)src[i], 2);
}

// MARK: - Decode

static int decode_vorbis(const char *path, FILE *out, char *error, size_t errorLength, uint64_t *bytes, int *channelsOut, int *rateOut);
static int decode_opus(const char *path, FILE *out, char *error, size_t errorLength, uint64_t *bytes, int *channelsOut, int64_t totalFrames);

int ct_ogg_decode_to_wav(const char *path, const char *outputPath, char *error, size_t errorLength) {
    CTOggInfo info;
    if (ct_ogg_scan(path, &info, error, errorLength) != 0) return 1;
    ct_ogg_free(info.comments);
    if (info.channels < 1) { fail(error, errorLength, "The file has no audio."); return 1; }

    FILE *out = fopen(outputPath, "wb");
    if (!out) { fail(error, errorLength, "The decoded file could not be created."); return 1; }
    write_wav_header(out, info.channels, info.sampleRate, 0);
    uint64_t bytes = 0;
    int channels = info.channels, rate = info.sampleRate;
    int result = info.kind == 1 ? decode_vorbis(path, out, error, errorLength, &bytes, &channels, &rate)
                                : decode_opus(path, out, error, errorLength, &bytes, &channels, (int64_t)(info.duration * 48000.0 + 0.5));
    if (result == 0) {
        fseek(out, 0, SEEK_SET);
        write_wav_header(out, channels, rate, (uint32_t)(bytes > 0xFFFFFFF0u ? 0xFFFFFFF0u : bytes));
    }
    fclose(out);
    if (result != 0) remove(outputPath);
    return result;
}

static int decode_vorbis(const char *path, FILE *out, char *error, size_t errorLength, uint64_t *bytes, int *channelsOut, int *rateOut) {
    int code = 0;
    stb_vorbis *v = stb_vorbis_open_filename(path, &code, NULL);
    if (!v) { fail(error, errorLength, "The Vorbis stream could not be opened."); return 1; }
    stb_vorbis_info info = stb_vorbis_get_info(v);
    *channelsOut = info.channels;
    *rateOut = (int)info.sample_rate;
    const int frames = 4096;
    int16_t *pcm = malloc(sizeof(int16_t) * frames * info.channels);
    uint8_t *raw = malloc(2 * (size_t)frames * info.channels);
    int result = 0;
    for (;;) {
        int got = stb_vorbis_get_samples_short_interleaved(v, info.channels, pcm, frames * info.channels);
        if (got <= 0) break;
        size_t count = (size_t)got * info.channels;
        store_samples(raw, pcm, count);
        if (fwrite(raw, 2, count, out) != count) { fail(error, errorLength, "Writing the decoded audio failed."); result = 1; break; }
        *bytes += count * 2;
    }
    free(pcm); free(raw);
    stb_vorbis_close(v);
    return result;
}

// `totalFrames` is the stream's true length: the last packet usually carries padding past it.
static int decode_opus(const char *path, FILE *out, char *error, size_t errorLength, uint64_t *bytes, int *channelsOut, int64_t totalFrames) {
    OggReader r;
    memset(&r, 0, sizeof r);
    r.file = fopen(path, "rb");
    if (!r.file) { fail(error, errorLength, "The file could not be opened."); return 1; }
    uint8_t *data; size_t length;
    OpusHead head = {0};
    int result = 1;
    OpusDecoder *decoder = NULL;
    int16_t *pcm = NULL;
    uint8_t *raw = NULL;

    if (!next_packet(&r, &data, &length) || !parse_opus_head(data, length, &head)) { fail(error, errorLength, "Not an Opus stream."); goto done; }
    if (head.family != 0 || head.channels < 1 || head.channels > 2) { fail(error, errorLength, "Only mono and stereo Opus files are supported."); goto done; }
    if (!next_packet(&r, &data, &length)) { fail(error, errorLength, "The file ends before its audio."); goto done; }

    int err = 0;
    decoder = opus_decoder_create(48000, head.channels, &err);
    if (!decoder || err != OPUS_OK) { fail(error, errorLength, "The Opus decoder could not be created."); goto done; }
    opus_decoder_ctl(decoder, OPUS_SET_GAIN(head.gainQ8));
    *channelsOut = head.channels;

    const int maxFrames = 5760;
    pcm = malloc(sizeof(int16_t) * maxFrames * head.channels);
    raw = malloc(2 * (size_t)maxFrames * head.channels);
    // The first preSkip samples are encoder delay and are not part of the audio.
    int64_t toSkip = head.preSkip;
    while (next_packet(&r, &data, &length)) {
        int frames = opus_decode(decoder, data, (opus_int32)length, pcm, maxFrames, 0);
        if (frames < 0) continue; // a corrupt packet is dropped rather than failing the file
        int offset = 0;
        if (toSkip > 0) {
            int drop = toSkip < frames ? (int)toSkip : frames;
            toSkip -= drop;
            offset = drop;
        }
        int64_t usable = frames - offset;
        if (totalFrames > 0) {
            int64_t remaining = totalFrames - (int64_t)(*bytes / (2 * head.channels));
            if (remaining <= 0) break;
            if (usable > remaining) usable = remaining;
        }
        size_t count = (size_t)usable * head.channels;
        if (count == 0) continue;
        store_samples(raw, pcm + (size_t)offset * head.channels, count);
        if (fwrite(raw, 2, count, out) != count) { fail(error, errorLength, "Writing the decoded audio failed."); goto done; }
        *bytes += count * 2;
    }
    result = 0;
done:
    if (decoder) opus_decoder_destroy(decoder);
    free(pcm); free(raw);
    reader_close(&r);
    return result;
}
