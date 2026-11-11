#ifndef ClassicOgg_h
#define ClassicOgg_h

#include <stddef.h>
#include <stdint.h>

// Ogg Vorbis and Ogg Opus files cannot be opened by AVFoundation, so the app reads their
// structure and decodes them to PCM itself.

typedef struct {
    int kind;            // 1 = Vorbis, 2 = Opus, 0 = not a supported Ogg file
    int channels;
    int sampleRate;      // rate of the decoded output (48000 for Opus)
    double duration;     // seconds
    double bitrateKbps;  // average over the file
    // The Vorbis-comment payload (vendor string, then NAME=value entries) in the layout of a FLAC
    // VORBIS_COMMENT block, so one parser serves FLAC, Vorbis and Opus. Release with ct_ogg_free.
    uint8_t *comments;
    size_t commentsLength;
} CTOggInfo;

// Returns 0 on success. On failure `error` holds a short description.
int ct_ogg_scan(const char *path, CTOggInfo *info, char *error, size_t errorLength);

// Decodes the whole file to a 16-bit PCM WAV at `outputPath`.
int ct_ogg_decode_to_wav(const char *path, const char *outputPath, char *error, size_t errorLength);

void ct_ogg_free(uint8_t *pointer);

#endif
