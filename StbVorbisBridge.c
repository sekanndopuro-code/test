// stb_vorbis をこの 1 ファイルの中で取り込んで、ogg を丸ごと展開する関数 (msd_vorbis_decode) を 1 つだけ公開する。
// 公開ドメイン / MIT の stb_vorbis.c は、nothings/stb の取得元 (コミット) をそのまま置いてある (書き換えていない)。
//   取得元: https://github.com/nothings/stb  (コミット 2c980bb59875b0d32144a71867fbdebb2f77cd20 / v1.22)

#include "StbVorbisBridge.h"

#include <stdlib.h>
#include <string.h>

// 使わない機能は外して、コードを小さくする (ファイル入出力・プッシュ API・16bit 変換)
#define STB_VORBIS_NO_STDIO 1
#define STB_VORBIS_NO_PUSHDATA_API 1
#define STB_VORBIS_NO_INTEGER_CONVERSION 1
#include "stb_vorbis.c"

int msd_vorbis_decode(const unsigned char *data, int length,
                      float **outLeft, float **outRight,
                      int *outFrames, int *outSampleRate, int *outChannels,
                      int maxFrames)
{
    if (!outLeft || !outRight || !outFrames || !outSampleRate || !outChannels) return -1;
    *outLeft = NULL;
    *outRight = NULL;
    *outFrames = 0;
    *outSampleRate = 0;
    *outChannels = 0;
    if (!data || length <= 0 || maxFrames <= 0) return -1;

    int err = 0;
    stb_vorbis *v = stb_vorbis_open_memory(data, length, &err, NULL);
    if (!v) return err != 0 ? err : -1;

    stb_vorbis_info info = stb_vorbis_get_info(v);
    int channels = info.channels;
    int rate = (int)info.sample_rate;
    if (channels < 1 || rate <= 0) {
        stb_vorbis_close(v);
        return -1;
    }

    // 長さがわかれば、その長さぶんを先に確保する (わからなければ 60 秒ぶんから始めて、足りなければ増やす)
    unsigned int total = stb_vorbis_stream_length_in_samples(v);
    size_t cap = total > 0 ? (size_t)total + 8192 : (size_t)rate * 60;
    if (cap > (size_t)maxFrames) cap = (size_t)maxFrames + 8192;
    int stereo = channels > 1;
    float *L = (float *)malloc(cap * sizeof(float));
    float *R = stereo ? (float *)malloc(cap * sizeof(float)) : NULL;
    if (!L || (stereo && !R)) {
        free(L);
        free(R);
        stb_vorbis_close(v);
        return -3;
    }

    size_t n = 0;
    int result = 0;
    for (;;) {
        float **outs = NULL;
        int c = 0;
        int k = stb_vorbis_get_frame_float(v, &c, &outs);
        if (k <= 0 || !outs) break;                      // 曲の終わり (stb_vorbis 自身の decode_memory と同じ終わり方)
        if (n + (size_t)k > (size_t)maxFrames) {
            result = -2;
            break;
        }
        if (n + (size_t)k > cap) {
            size_t ncap = cap + cap / 2 + (size_t)k;
            float *nl = (float *)realloc(L, ncap * sizeof(float));
            if (!nl) { result = -3; break; }
            L = nl;
            if (stereo) {
                float *nr = (float *)realloc(R, ncap * sizeof(float));
                if (!nr) { result = -3; break; }
                R = nr;
            }
            cap = ncap;
        }
        memcpy(L + n, outs[0], (size_t)k * sizeof(float));
        if (stereo) memcpy(R + n, outs[1], (size_t)k * sizeof(float));   // 3ch 以上は、最初の 2ch だけ使う
        n += (size_t)k;
    }
    stb_vorbis_close(v);

    if (result != 0 || n == 0) {
        free(L);
        free(R);
        return result != 0 ? result : -1;
    }
    *outLeft = L;
    *outRight = R;
    *outFrames = (int)n;
    *outSampleRate = rate;
    *outChannels = channels;
    return 0;
}
