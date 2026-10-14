// stb_vorbis (公開ドメイン / MIT。Sean Barrett) を Swift から使うための、ごく小さな入口です。
// Swift には、この .h だけが見える (project.yml の SWIFT_OBJC_BRIDGING_HEADER)。
// 実装は StbVorbisBridge.c (中で stb_vorbis.c をそのまま取り込む)。
//
// Swift Playgrounds (Package.swift) のビルドには、この C は入らない。
// Swift 側は #if HAVE_STB_VORBIS で囲んであり、project.yml が HAVE_STB_VORBIS を定義する (= ipa のときだけ有効)。

#ifndef StbVorbisBridge_h
#define StbVorbisBridge_h

#ifdef __cplusplus
extern "C" {
#endif

// ogg Vorbis を、ファイルの最初から最後まで 1 回で float の左右に展開する。
//   data / length : ogg ファイルの中身 (全部)
//   outLeft / outRight : malloc された左右の波形 (Swift 側で free する)。モノラルのときは outRight が NULL
//   outFrames : 1 チャンネルあたりのフレーム数 / outSampleRate : サンプルレート / outChannels : 元のチャンネル数
//   maxFrames : これを超える長さは受け付けない (メモリを使い切らないための上限)
// 戻り値: 0 = 成功
//         1以上 = stb_vorbis のエラー番号 (stb_vorbis.c の enum STBVorbisError。VORBIS_invalid_setup など)
//         -1 = 引数が不正 / -2 = maxFrames を超えた / -3 = メモリが足りない
int msd_vorbis_decode(const unsigned char *data, int length,
                      float **outLeft, float **outRight,
                      int *outFrames, int *outSampleRate, int *outChannels,
                      int maxFrames);

#ifdef __cplusplus
}
#endif

#endif /* StbVorbisBridge_h */
