# Malody Slide Editor (Swift Playgrounds / iPad)

## 開き方
1. `MalodySlideEditor.swiftpm` を iPad の「ファイル」に置き、Swift Playgrounds で開く
   (開けない場合: Playgrounds で新規 App を作り、既存の .swift を削除して、このフォルダ内の `*.swift` を全てコピー)
2. **プレビュー欄ではなく、右上の「アプリを実行」でフルスクリーン実行**してください(プレビュー接続エラー回避)
3. 起動画面の「ファイルを選択…」で、mc・音源(ogg など)・背景画像(任意)を**まとめて選ぶ** (拡張子で自動判別。mc だけ / mc と音源だけでもよい)。「エディタを開く」で開始
   - **mcz は「mczを展開して読み込む…」**で選ぶと、展開して中の mc・音源・背景画像をまとめて読み込む (下の「起動画面のファイル選択」)

## ファイル構成 (機能追加の入口)
| ファイル | 役割 |
|---|---|
| Beat.swift | [整数,分子,分母] の拍。0拍始まり |
| ChartModel.swift | mc の読み書き。未知のキーは保存時に温存 / BPM(TimeMap) / effect (`EffectPoint`: scroll / jump) |
| ZipWriter.swift | mcz(zip) 書き出し |
| ZipReader.swift | mcz(zip) 読み込み。無圧縮 (stored) と deflate に対応 (`ZipReader`)。deflate の展開は Apple の Compression (`COMPRESSION_ZLIB` = zip と同じ raw deflate)。ZIP64 / パスワード付きは非対応 |
| MCZImporter.swift | mcz を展開して `Documents/MalodySlideEditor/<mcz名>/` へ全部書き出す (`MCZImporter.unpack`)。譜面を選ぶ画面に出す version / creator もここで読む |
| AudioController.swift | **曲を開くときに 1 回だけ PCM に展開する `SongPCM`** (ogg は ipa では stb_vorbis、Playgrounds では自前デコーダー。ogg 以外は AVAudioFile)。エディタの再生・テストプレイ・曲の長さが、この同じ PCM を共有する。`SongPCMSource` (PCM を `PCMSource` として読む薄い入れ物) と、オーディオセッションの起こし方 `AudioSessionSetup` もここ。以前あった AVAudioPlayer と WebKit (WKWebView) でのデコードは無くした |
| stb_vorbis.c / StbVorbisBridge.c / StbVorbisBridge.h | **ogg Vorbis を読む C のライブラリ (stb_vorbis v1.22。公開ドメイン / MIT) と、Swift への橋渡し**。`stb_vorbis.c` は nothings/stb のコミット `2c980bb59875b0d32144a71867fbdebb2f77cd20` をそのまま置いてあり、書き換えていない。`StbVorbisBridge.c` の `msd_vorbis_decode()` が ogg を丸ごと Float の左右に展開する。**ipa のビルドだけで使う** (`project.yml` の `SWIFT_OBJC_BRIDGING_HEADER` と `HAVE_STB_VORBIS`)。Playgrounds (`Package.swift`) では除外してあり、Swift 側は `#if HAVE_STB_VORBIS` で従来の自前 ogg デコーダーに切り替わる |
| KeySound.swift | ノーツ音(キー音)。`KeySoundData` の波形を読み込んで鳴らす (読めなかったときだけ、鈴くらいの高さの短い音をコードで合成して代わりに鳴らす) |
| KeySoundData.swift | ノーツ音の波形データ (44.1kHz モノラル 16bit PCM を base64 にしたもの。約55ms) |
| EditorState.swift | 状態・再生クロック・Undo・オートセーブ・エクスポート |
| EditorState+Tools.swift | ノーツ配置/削除/範囲コピー/反転/Slide<->Wipe/BPM/effect/seg編集 / **Grid align の吸着** (`snapNote` = 置くとき、`applyCenteredMove` = 動かすとき) |
| Renderers.swift | レーン・縦タイムライン・シークバーの描画 (Canvas) |
| SeekDensity.swift | シークバー (再生ボタンの下) のノーツ密度ヒストグラムの計算 (120 区間 / 20 段階)。描画は `Renderers.swift` の `SeekRenderer` |
| EditorView.swift | 画面レイアウト・右ボタン列・ポップアップ |
| Sheets.swift | `Beat.parse` (拍の入力) だけ。META のシートはやめて、右ボタン列 + 右ウィンドウになった (下の「META / SETTING」) |
| EditorState+Meta.swift | **META の動き**: 列を開く / 閉じる (`openMetaMenu` / `closeMetaMenu`)、More の mcz 共有 (`shareMCZNow` + 共有シート `MCZSharer`)、Review の多重ノーツ探し (`reviewChart`)、Quit (`quitEditor`) |
| MetaMenuIcons.swift | META の列のアイコン (Information = `InfoIcon` / Review = `ReviewIcon` / Quit = `PowerIcon`)。Back と More は EDIT 中と同じ |
| ReviewNotice.swift | Review で多重ノーツが無かったときに、画面の上へ一瞬だけ出る「0 issue found」の札 (`ReviewNoticeLayer`)。Grid settings の枠を縮めた形 (`ReviewNoticeShape`) |
| SideWindow.swift | **BPM list / Effect list / Information / SETTING** の右ウィンドウ。シートではなく EditorView に重ね、右の端から約 0.16 秒で滑って入る (`SidePanelLayer` / `SideWindow`)。ウィンドウより左を触ると、すぐ閉じる。出し入れは `EditorState.openSidePanel(_:)` / `closeSidePanel()` |
| GridSettingsDialog.swift | **Grid settings** (More メニューから)。シートではなく、EditorView に重ねる本家風の中央ダイアログ (`GridSettingsDialog`)。背景のぼかし `BackdropBlur` もここ |
| MoreMenuIcons.swift | More メニューのアイコン (`MoreMenuIcon`)。本家の画面収録から起こした輪郭 (`MoreMenuIconData`) と、自作の Time range (正方形 + 上矢印) |
| RootView.swift | 起動時のファイル選択。**まとめて選んだファイルを拡張子で mc / 音源 / 背景画像に自動で振り分ける** + **mcz の展開読み込み** (下の「起動画面のファイル選択」) |
| TestPlay.swift | テストプレイ。MalodySlideTestplayer の判定・音声・描画をそのまま組み込み (Note→PlayNote に改名) |
| PCMCache.swift | **使わなくなった** (中身は空)。曲を開くときに全部展開する `SongPCM` になったので、背景の先読み展開は要らない。GitHub 上で削除してよい |
| RubberBandPCMSource.swift | **Rubber Band 版の時間伸縮** (0.75 / 0.5 / 0.25 / 0.1 倍の音)。`CRubberBand` (C++) があるビルド = GitHub Actions のときだけ有効。Swift Playgrounds では中身が空になり、`TimeStretch.swift` の自前版で動く。組み込み方は `RubberBand導入手順.md` |
| Effects.swift | effect (scroll / jump) から「表示位置 P(t)」を決める `EffectMap` (テストプレイと、エディタの **FX 表示** の見た目だけが変わる。判定は変わらない) |
| EditorState+FX.swift | **FX 表示 (擬似テストプレイ)** の ON / OFF (`toggleFX` / `setFX`)、FX 表示で使う `EffectMap` の使い回し (`fxEffectMap`)、編集モードを抜ける `leaveEdit` |
| RenderersFX.swift | **FX 表示のレーン描画** (`LaneRenderer.drawFX`)。seg の丸なし・scroll / jump 反映・判定を過ぎたものは出さない・jump で飛んだリボンは画面に切り詰める |
| PluginPanel.swift | **Adv. メニュー** (`AdvPanel`: プラグイン一覧・読み込みボタン・出力欄) と、プラグインが出すダイアログ (`PluginDialogLayer`) |
| PluginStore.swift | プラグイン一覧 (`PluginStore.shared`)。内蔵 + 読み込んだもの (`Documents/Plugins/` にフォルダごと保存・次回起動時に自動で再読み込み。Files アプリから足した / 消したものは、アプリに戻ったときと Adv. を開いたときに `reload()` で読み直す。前の版の `Documents/MalodySlideEditor/Plugins/` にあったものは、起動時に移す)。.lua / .zip / 画像の取り込みもここ |
| PluginFilePicker.swift | 「ファイル」アプリを開くピッカー (UIKit の `UIDocumentPickerViewController` を、いちばん手前の画面から直接出す) |
| PluginSession.swift | **操作型プラグイン (PluginType 2)** の実行 (`PluginSession`)、レーンの上に出す画像 (`PluginSprite`)、画像の読み込み (`PluginImageCache`) |
| PluginBridge.swift | Lua → エディタの橋渡し。`Editor:〇〇()` の中身 (ノーツ・BPM・effect・スプライト・クリック位置) はここ |
| LuaEngine.swift | JavaScriptCore の起動と Lua の実行 (別スレッド・停止可能) |
| LuaEngineSource.swift | **自動生成**。Lua→JavaScript 変換器 + Lua 標準ライブラリ + `Editor` の定義 (JavaScript) を文字列で埋め込んだもの |
| BuiltinPlugins.swift | 内蔵プラグイン 6 つ (`quad_InOut` / `quad_OutIn` / `Join Slides (Fixed)` / `終点と始点を繋げる` / `折り返し敷` / `枝分かれ敷`) |
| EditorState+Plugins.swift | プラグインの実行 (`runPlugin`) / 停止 (`stopPlugin`) と、Order ボタン (「順番に選択」) のタップ処理 (`orderTap`) |

## 起動画面のファイル選択 (RootView.swift)
「ファイルを選択…」1つのボタンで、mc・音源・背景画像を**複数まとめて**選べる。種類は拡張子で決める (`RootView.kind(of:)`)。
- **mc**: `.mc` / **音源**: `ogg mp3 wav m4a aac flac aif aiff caf` (これ以外でも、システムが「音声」と判断する拡張子は音源) / **背景画像**: `png jpg jpeg webp heic heif gif bmp tif tiff` (同じく、システムが「画像」と判断するものは画像)。大文字・小文字は区別しない。足したい拡張子は `RootView.audioExts` / `imageExts` に書く
- どの組み合わせでもよい (mc だけ / mc + 音源 / 3つ全部 / 選ぶ順がバラバラ)。mc だけなら、音源・背景なしで開く
- **今回の選択に mc が入っている** → 別の譜面に切り替えたものとして、前に選んでいた音源・背景は外す (今回いっしょに選んだものだけが付く)。**mc が入っていない** → いまの mc はそのままで、音源 / 背景だけ入れ替える (あとから音源だけ足すこともできる)
- 同じ種類が複数あれば最初の1つだけ使い、その旨を画面に出す。拡張子で判別できないファイルは無視して、理由を画面に出す
- 画面の3行 (譜面 / 音源 / 背景画像) は、読み込み状況の表示だけ

### mcz を展開して読み込む (「mczを展開して読み込む…」)
- mcz を 1 つ選ぶと、`Documents/MalodySlideEditor/<mcz名>/` に**全部展開**して (zip 内のフォルダ階層は取り除く。`__MACOSX` と `._` で始まるファイルは無視)、その中の mc・音源・背景画像を読み込む。Files アプリの「このiPad内 > (アプリ名) > MalodySlideEditor」から展開したファイルが見える
- **展開先の mc を開く**ので、オートセーブはその mc に書き戻される (元の mcz は書き換えない)
- 同じ名前のフォルダがすでにあるときは `<mcz名> 2` のように別のフォルダに展開する (前に編集した mc を上書きしないため)
- mc が複数入っている mcz (難易度ごとなど) は、「開く譜面を選ぶ」画面 (version / creator つき) で 1 つ選ぶ。mc が 1 つならそのまま読み込む
- 音源・背景画像は、選んだ mc に書いてある名前 (曲のファイル = `sound` / 背景ファイル = `meta.background`) と同じファイルを優先する。名前が合うものが無いときは、拡張子で最初に見つかった音源 / 画像を使う
- 「ファイルを選択…」で mcz **だけ**を選んでも、同じ動きになる (mc などと同時に選んだ mcz は無視する)

## 画面の比率 / 背景画像 (iPad Air 4 の横画面 1180×820pt を基準に、本家の画面を測って合わせている)

- **画面の比率 (4:3 / 16:9 / 16:7 など)**: 下の寸法はすべて iPad Air 4 の高さ 820pt を基準にした値。`DesignCanvas` (EditorView.swift) が、画面の高さが 820pt になる倍率 (画面の高さ ÷ 820) で UI 全体を拡大・縮小し、横幅の増減はレーン (中央の大きいビュー) だけが吸収する。左の帯・シークバー・右ボタン列・フォント・ノーツの太さは、どの比率でも高さに対して同じ大きさ。タッチ座標も設計画面の座標で届く。幅の目安: 4:3 → 約 1093pt / iPad Air 4 → 1180pt / 16:9 → 約 1458pt / 16:7 → 約 1875pt。テストプレイ画面は、もともと画面の幅・高さに対する割合で決めているので、この仕組みの対象外
- 左から: **左の帯 145pt** (`StripView.width`。拍の番号と目盛り) → シークバー 66pt → 時刻表示 38pt → レーン (右の余白を含めて 約 873pt。譜面の左端 `LaneGeo.trackL` = 25.2pt、幅 `trackW` = ビューの幅 − 35.4pt (約 837.6pt。左の余白 25.2 + 右の余白 10.2)。どちらも本家の縦線 (32分割) を実測した値) → 右ボタン列 58pt (`RightPanel.width`。本家は左端に細い白線があり、アイコンの中心は列の真ん中)。再生ボタンは本家と同じ六角形 (`SeekPanel` / `PlayToggleButton`)
- **背景画像**: 起動画面で選んだ背景画像を、`EditorBackground` (EditorView.swift) が画面全体 (ホームインジケータの下まで) に敷き、黒を重ねて暗くする。レーン・右ボタン列は背景を塗らず (右ボタン列は半透明の黒)、画像が透けて見える。左の帯とシークバーは、本家と同じ半透明の暗い色 (`StripRenderer.faceColor` = 黒の約58%。背景画像と、レーンからはみ出したノーツが透ける) で塗り、時刻表示の欄からレーンの番号欄までは明るい半透明のパネル (`Color.timePanel`) を敷く。画像が無いときは、これまでどおり黒
  - 暗さは SETTING の **背景画像の暗さ** (0〜95%、初期値 70%。背景画像があるときだけ表示。保存される: UserDefaults `editor.bgDim`。本家の画面を測ると、背景は このエディタの 60% 設定より約 0.72 倍暗い → 70% が近い)。`EditorState.bgDim`
  - 画像は長辺 2048px 以内に縮めて読み込む (`EditorState.makeBackground`)。mcz 書き出しには、元の画像をそのまま入れる (従来どおり)
  - **写真から入れ替える**: META → Information の「背景ファイル」の下の **写真から読み込む** (`PhotosPicker`。「ファイル」アプリではなく写真アプリ)。すでに背景があれば置き換える。HEIC / PNG などは JPEG (画質 0.9) に変換し、すでに向きが正しい JPEG は元のまま使う (`EditorState.backgroundJPEG`)。背景ファイル名は今書いてある名前を引き継ぎ (拡張子が jpg / jpeg 以外なら `.jpg` に直す。空なら `bg.jpg`)、`meta.background` にも書く。Quit しても消えないよう、画像ファイルとしても残す (mc がアプリ内のフォルダにあるときはそのフォルダ、それ以外は `Documents/MalodySlideEditor/<mc名>/`)。Quit して開き直しても、同じ起動画面のあいだは入れ替えた画像が使われる (`EditorState.applyBackground`)
- 拍の番号は、本家と同じく **N 拍目と N+1 拍目の線の真ん中**に置く (左の帯も、レーンも、標準の書体を横に 0.77〜0.78 倍に潰した細長い数字。帯は数字の高さ 約24.5pt、レーンは 約14.5pt。`drawNumber`)。左の帯の細かい目盛りは、左から 約 27pt の長さ
- **左の帯の見た目の倍率は固定**: 本家はレーンのズームに連動せず、1拍 = 約 178pt (高さ 820pt で 約 4.6拍。`EditorState.stripBeats`)。ただし、**帯を上下になぞったときのスクロール量はズームに比例する** (`EditorState.stripScrollBeats` = レーンの表示拍数 `visibleBeats`。帯の高さぶん指を動かすと、レーンの高さぶん譜面が動く。拡大するほど細かく、縮小するほど大きく動く。ピンチ中の小数のズームにもなめらかに追従する。1回のドラッグの間は、始めた時点のズームで固定)。帯の右には暗い側面 (斜めの面取り、約10.5pt) が続く。側面は帯の枠の外なので `SeekRenderer` が描く
- **拡大/縮小ボタン**: 左端が画面の外で切れた五角形 (`ZoomButtonShape`、幅 39 × 高さ 45pt、先端は x=37.7)。塗りは不透明な (127, 131, 138)、縁は白 1.5pt、記号は 25 × 3.3pt の白い棒。上端は − が 10.75pt、＋が 68pt (`ZoomButton` / EditorView.swift)
- **FX ボタン** (`FXButton` / EditorView.swift): 拡大/縮小ボタンの下 (中心が上端から約 160pt)。同じ五角形で、OFF = 灰色 / ON = 選択色 (`Color.panelBlue`) で塗る。文字は「FX」だけ (幅 39pt に「FX ON」は収まらないので、ON / OFF は色で見せる)。押すと **FX 表示 (擬似テストプレイ)** が切り替わる (下の「FX 表示」)
- **右ボタン列のアイコン** (`PanelIcons.swift`): 本家は高さ約 36pt の太い白線 (線の太さ 約 4pt、角は丸い)。EDIT=えんぴつ / BPM=メトロノーム / TEST=カチンコ / META=一覧 は、本家のスクリーンショットから輪郭を起こした (`PanelIconData`)。本家に無い SETTING (歯車) は同じ太さで描いた。EFFECT は文字の「✦」のまま (アイコン未作成)。アイコンは `PanelButton` の `icon:` に `PanelIconView(kind:color:)` を渡す。ボタンに枠と文字 (キャプション) は無く、アイコンだけ。選択中はシアンになる。配置は本家の実測どおり、アイコンの中心どうしが 68.5pt おき (`RightPanel.slotPitch`)、最初のアイコンの中心は画面の上端から 45pt、下の2つ (再生速度 / 分割) は下端から 45pt。EDIT 中はボタンが増えて収まらないので、そのときだけ間隔を詰める。現在の再生速度・分割は、それぞれのポップアップの中で青 (`Color.panelBlue` = 本家の動画から実測した R0 G206 B255) になっている項目で分かる (選択中のアイコンも同じ青)。
  - **右下の2つのアイコン**: 上=再生速度は本家の「メーター」、下=分割 (LFB) は本家の「定規」。どちらも本家の動画から輪郭を起こした (`PanelIconData.speed` / `.divide`)。メニューが開いている間も、アイコンの色は白のまま (本家と同じ)
  - **再生速度 / 分割のメニュー** (`EditorView.popupList`): 本家の動画から実測した値で、幅 57.8pt・1行 51.6pt・上下の余白 10.4pt、背景は黒の 50% (下の譜面が透ける)、縁は白 70% の細い線。画面の下端から 2.5pt 上に下端をそろえて出し (再生速度も分割も同じ)、ボタン列の左端から 10.8pt 空ける。項目は本家より多いまま (再生速度は 0.25x / 0.1x、分割は 1/48 などと「入力…」)。文字は `PanelFont.menu` (本家の字体は iPad に無いので、幅と高さの比が近い DIN Condensed で代用。字体を変えるときはここだけ)
  - **EDIT を押したときの動き** (`AnyTransition.panelSwap`): 古いアイコン列が右へ滑りながら消え (0.08 秒)、そのあと新しい列が右から滑り込む (0.12 秒)。Back のときも同じ。下の2つのアイコンは動かない
  - **EDIT 中の名前** (`PanelEditLabel`): 本家は、各アイコンの左に黒 80% の箱 (高さ 43pt) の上に白い字で Back / Note / Wipe / Slide / Remove / More が出て、EDIT に入って 2.6 秒たつと 0.7 秒かけて消える。同じ動きにしてある (本家に無いボタンは Lasso / Order / Adv. / Undo / Redo)。文字は `PanelFont.label` (Avenir Next Condensed)
  - **EDIT 中のアイコン**: Back (←) / Note (角丸の細長い輪) / Wipe (線とひし形) / Slide (ギザギザの輪) / Remove (ゴミ箱) / More (点3つ) は、本家の動画から輪郭を起こしたもの。Adv. / Undo / Redo は本家に無いので、これまでの文字のまま。Order も本家に無く、縦長の長方形を2つ並べて中に小さく「1」「2」を描いた自作のアイコン (`OrderIcon` / PanelIcons.swift。線の太さ・高さは他のアイコンと同じ)Order で選んだ数だけは、アイコンの右上に小さな数字で出る本家のフロッピー (保存) は、自作では保存が文字表示なので、まだ使っていない
- **時刻表示**: 細い字 (25.5pt) を 1文字 20.25pt の送りで並べ、白くやわらかく光らせる (`TimeLabelRenderer`)。「:」「.」は 3pt の四角で、1文字ぶんの枠を取る。上の時刻 (総時間) は画面の上端から、下の時刻 (現在時刻) は下端から、どちらも 113.5pt が中心。書体は標準の書体なので、本家の字形とは少し違う
- ステータスバー: `MalodySlideEditorApp.swift` の `.statusBarHidden(true)` で隠す指定になっている。Swift Playgrounds の実行中は、Playgrounds 側が出すため消えないことがある

## ノーツの描画 (本家 Malody のスクリーンショットから実測して合わせている)
`Renderers.swift` の `LaneRenderer.drawNotes` と `Color` の拡張 (`tapOuter` など) が、本家の見た目の入口。変えたいときは、この色の数値と下の定数を触る。
- **タップ**: 高さ 約 12pt。外側の明るい水色の縁 (1.5pt) → 濃い青緑の帯 (1.5pt) → 白に近い水色の芯 (5pt)。角は丸く、外側にごく弱い水色のにじみ (`drawTap`)
- **ウィップ**: 左右の端がとがった六角形の棒 (黄色の縁 2pt → オリーブ色の帯 1.5pt → 淡い黄色の芯)。さらに外側に「<」「>」の矢印がつく。ノーツの端 = 矢印の先 (`drawWipe`)
- **スライドの点**: 外側の白い輪 (半径 11.4pt、透明度 α=0.86) → 水色の輪 (〜7.8pt、α=0.60) → 中心の白 (〜4.5pt、α=0.94) (`drawDot`)。本家は輪ごとに透け具合が違うので (23個の点を背景との回帰で実測)、重ねずに輪の形で塗り分けている。リボンは 白に近い水色 を 約 40% の濃さで重ねる (`Color.ribbonFill`。本家の単スライドを実測した値。以前の 55% はスライドが二重に重なった所を測っていた)。点は、リボンを全部描いたあとで重ねるので、いつもリボンの手前に見える
- **選択中**: 水色の部分が赤になる (`selTapOuter` など。形・明るさは通常と同じ)。ただしスライドは、**赤くなるのは始点の点とリボンだけ**で、seg の点は通常の色のまま (本家と同じ)
- `LaneRenderer.barLift` (初期値 8pt): 本家は、タップ / ウィップの棒の下端が拍の線のすぐ上に乗る (棒の真ん中が線に重ならない)。0 にすると、これまでどおり棒の真ん中が線に重なる。当たり判定 (`noteHit`) と LASSO の判定も、この分だけ棒に合わせて動く
- `LaneRenderer.drawSlideHeadBar` (初期値 false): 本家はスライドの始点に棒を描かない (リボンと点だけ)。true にすると、これまでどおり始点にも棒を描く
- 縦の拍の線は、本家に合わせて白く濃くした (背景に対して約 60%)。横の線 (1/2 = シアン / 1/4 = マゼンタ) も濃くした (`lineStyle`)

## シークバーのノーツ密度 (本家のヒストグラム。2360×1640px のスクリーンショットを 1 ピクセルずつ測って合わせている)
再生ボタンの下のシークバーには、曲全体を縦に **120 等分** した 1 本 1 本の赤い棒 (`SeekRenderer` / `SeekDensity`)。
- **本数**: 120 本 (112 ではない)。1 本のピッチ 6.84pt (13.69px)、棒の太さ 5.4pt、棒の上端は区間の上端から 0.14pt 下。曲の頭が下、末が上。曲の頭から数えて何本目かは `SeekDensity.counts` の添字 (0 が頭)
- **高さの基準**: 本家のシークバーは画面より 約0.16% 長い (821.3pt。`SeekRenderer.regionScale`)。再生位置の線も 120 本もこの高さに対して並べ、シークバーのタッチ (`SeekView`) も同じ高さで割る。実測では、再生位置の線の中心が本家の 1378.4px、計算が 1378.7px
- **長さ**: 右端 (幅 − 0.5pt) から左へ、最大 67.4pt (`barMaxW`)。最大の棒は、左の帯の側面 (暗い斜めの面) の左端まで届く。長さは 20 段階 (1 段 = 3.37pt = 6.74px) にそろっている
  - 側面の下に入った部分は、側面が「黒 50% の透明な面」なので、半分の明るさ (棒 (238,102,100) → (119,51,50)) になる。再生位置の線も同じ。側面の縁の細い白線は、棒の手前に出る
- **何を数えるか**: 区間ごとの「ノーツの数」。タップ / ウィップ / スライドの始点 だけ (スライドの seg = 中継点は数えない)。曲の外 (マイナスの時刻 / 曲より後ろ) のノーツは数えない
- **長さの決め方**: 区間の数を **20 で頭打ち** (`SeekDensity.levelCap`) にしてから、いちばん大きい区間を 1.0 (= 最大の長さ) にした割合。本家の画面では、長さが 20 段階の整数倍にそろっていて、しかも最大の棒が 120 本中 19 本もあった (= 上限で頭打ち)。そのため「純粋な最大 = 1.0」ではなく、この形にしてある。純粋に「最大の区間 = 1.0」だけにしたいときは `levelCap` を `Int.max` にする
- **再生位置**: 白い線 (太さ 2.3pt) の両端に、橙色の縦棒 (6 × 12.3pt)。以前の赤い線から変更。ヒストグラムの手前に描く。側面に掛かる部分を暗くする処理は、棒・線・縦棒を 1 つの Path にまとめて 1 回で塗る (別々に塗ると、重なった所が二重に暗くなる)
- 以前あった「いま見えているレーンの範囲」の白い帯は、本家に無いので消した (`SeekRenderer.showViewWindow = true` で戻せる)
- 計算結果は `EditorState.seekDensityRatios()` に置いてあり、譜面・BPM・曲の長さを触ったとき (`recomputeTotal`) だけ作り直す。再生中の毎フレームは、使い回すだけ

## 枠 (レーンの幅) からはみ出したノーツの描画 / ホームバー
- ノーツ (リボン・点・棒) は、レーンの幅の外 (左の帯・シークバー・右のボタン列の下) まで描く。本家と同じ見え方。`LaneView` (EditorView.swift) が、描画用の Canvas だけを左右に広げ (左は画面の左端まで、右はボタン列の幅 `RightPanel.width` ぶん)、座標はこれまでのレーンのまま左へ平行移動して描く。レーンの層は `EditorView` で `zIndex(-1)` にして、左の帯・シークバー・Adv. メニュー・右ボタン列より下に置いている。**当たり判定は変わらない**: タッチを受けるのはレーンの幅と同じ大きさの透明な層だけで、描画の Canvas は `allowsHitTesting(false)`
- テストプレイ画面 (`TestPlay.swift`) のはみ出しは、まだ手を付けていない
- ホームバー (画面下の横棒): `RootView` / `MalodySlideEditorApp` で `defersSystemGestures(on: .bottom)` だけを付けている (下端からの1回目の上スワイプではホームへ戻らず、2回目で戻る)。**バーは隠さない**: 隠す (`persistentSystemOverlays(.hidden)`) と、下端に触れた瞬間に白く出て反応するため。隠さずに遅延にすると、バーは半透明のまま残り、はっきり上へ持ち上げるまで反応しない (本家 Malody と同じ)。ノーツ幅スライダーは、画面の下端 19pt (`LaneWidthSlider.edgeDead`) から始まったタッチを受けない (そこから横になぞり始めると、iPad がホームバーの操作と見なすため)。`TestPlayScreen` は、まだ `persistentSystemOverlays(.hidden)` のまま。iPadOS の「ゲームモード」(Info.plist の `GCSupportsGameMode` / `LSSupportsGameMode`) とは別の機能で、ホームバーには関係しない

## 画面の下端 / 幅スライダー
- `RootView` で、下の安全領域 (ホームインジケータの所) も無視して、UI を画面の下端まで続けている。本家は帯・シークバー・レーン・右ボタン列がすべて下端まで途切れない。再生ライン (シアンの横棒) は画面の高さの 91.3% (`LaneGeo.playY`。本家の実測)。右ボタン列の下の2つのアイコンも、本家と同じ位置 (中心が下端から 45pt) に置く
- **幅スライダー** (`LaneWidthSlider`): 本家と同じ、透明な白 (約 50%) の単色の帯だけ。レーンの左端 (x=0) から、置かれるノーツの幅の位置までを塗る。つまみ・暗い土台・文字は無い。帯は画面の下端から 約 19pt 上、高さ 18pt。指で触れる範囲は、その周りの下端までの 52pt

## Rubber Band による時間伸縮 (うなり・揺らぎ対策)
- 遅い再生 (0.75 / 0.5 / 0.25 / 0.1 倍) の音は、`GameAudio.makeStretcher` (TestPlay.swift) が作る。**Rubber Band を組み込んだビルド (GitHub Actions)** では `RubberBandPCMSource`、**組み込んでいないビルド (Swift Playgrounds)** では自前のフェーズボコーダー (`StretchedPCMSource` / TimeStretch.swift) を使う。`#if canImport(CRubberBand)` で切り替わるので、Playgrounds で開く運用はそのまま変えなくてよい
- どちらで動いているかは、再生したあとの SETTING の下の診断表示「伸ばした音(Rubber Band R3)」/「伸ばした音(自前(窓1024))」で分かる
- SETTING の「立ち上がりをはっきりさせる」: Rubber Band のときは **オン = Faster (R2・短い窓。立ち上がりがはっきり)、オフ = Finer (R3。うなりが少ない高品質)**。自前のときは今までどおり窓 512 / 1024
- 調整できる値 (`RubberBandPCMSource.swift` の先頭)
  - `trimFrames`: 音の位置の微調整 (出力側のフレーム数。正 = 音が早くなる、負 = 遅くなる)。0.25 倍でクリックがノーツとズレて聞こえるときだけ触る
  - `finerMinRate`: この速度より遅いときは Finer をやめて Faster にする (初期値 0 = 常に Finer)。0.1 倍で音が途切れるときは 0.2 などにする
- Rubber Band 本体のソースは **リポジトリに置かず、ビルドのたびに公式から取ってくる** (RubberBand導入手順.md)。ライセンスは GPL v2 以上 (自分用 / ソース公開の範囲ならそのままでよい。ソースを公開せずに ipa を配るなら商用ライセンスが必要)

## 仕様メモ
- 拍表示は mc と同じ 0 始まり。x は中心座標(0〜255)、w は幅
- 音源の同期: 音源位置 = 譜面時間 − offset(ms)  (editor.html と同じ)
- オートセーブ: 編集の1.2秒後に元の .mc へ上書き + アプリ内 Documents/MalodySlideEditor/ にバックアップ
  * **外で書き換えられたファイルは上書きしない**: 保存の直前に、mc の今の中身が「このエディタが最後に読んだ / 書いた中身」(`EditorState.baseline`) と同じか確かめる。違っていたら (Malody など別のアプリが編集して保存した) 書き込まずに止め、このエディタの内容を `<mc名>_editor_copy.mc` としてアプリ内 (Documents/MalodySlideEditor/) に残す
  * アプリに戻ってきたとき (`didBecomeActive`) も同じ確認をする。未保存の変更が無ければ、ファイルの内容を自動で読み込み直す (Undo 履歴は空になる)。未保存の変更があるときは確認ダイアログ: 「Malody側の内容を読み込む」(エディタ側は `_editor_copy.mc` に残る) / 「このエディタの内容で上書き」(上書き前のファイルは `<mc名>_malody_copy.mc` に残る)。ダイアログの返事を待つあいだ、Quit ではエディタを閉じない
- **Files アプリからプラグインを管理する**: Info.plist に `UIFileSharingEnabled` = YES と `LSSupportsOpeningDocumentsInPlace` = YES を入れて作った ipa なら、Files アプリの「このiPad内 > (アプリ名)」に Documents が見える。
  その中の `Plugins/` に .lua (サブフォルダに入れた .lua と画像もよい) を入れると使え、消すと一覧から消える。.zip は自動では展開されないので、アプリの「プラグイン(lua)を読み込む」から入れる。`MalodySlideEditor/` には譜面のバックアップが入る
- mcz は `<mc名>/` フォルダ内に mc・音源・背景を無圧縮zipで格納 (書き出し)。読み込みは deflate の mcz も読める (`ZipReader`)
- 再生中の描画: レーン等の Canvas は `FrameCanvas`(EditorView.swift) 経由で毎フレーム描き直す
- テストプレイ: 右の TEST ボタン。エディタで表示中の位置(2秒前)から始まる。最初から遊ぶときは先頭にシークしてから押す
- **BPM list / Effect list の開き方**: 下から上がるシートではなく、本家と同じく画面の右の端から横に滑って入る右ウィンドウ (幅 445.5pt、高さは画面の上下 23pt を残していっぱい、黒 72% の半透明。右ボタン列の上まで覆い、列のアイコンは開いている間だけ見えなくなる)。本家の「値を入れて Add すると勝手に閉じる」は再現していない。閉じるのは、ウィンドウより左 (範囲外) を触ったとき。キーボードが出ると、ウィンドウの下端がキーボードの上へ上がる
- **Effect (scroll / jump)**: 右ボタン列の **EFFECT** (BPM の下、✦) で右ウィンドウが開く。BPM list と同じ作りで、Beat・種類 (scroll / jump)・値を入れて Add / 更新、一覧から選んで Remove。同じ拍・同じ種類は置き換え、scroll と jump は同じ拍に並べられる。Undo / Redo も効く。mc には `"effect":[{"beat":[..],"scroll":0.01},{"beat":[..],"jump":10000000}]` の形で保存される (読み込んだ mc の effect はそのまま温存する。scroll / jump 以外の形のものも、触らずに書き戻す)
  - **エディタのノーツの並びは、ふだんは変わらない** (今までどおり拍で並ぶ)。effect で見た目が変わるのは **テストプレイ** と、**FX ボタンを ON にしたレーン** (下の「FX 表示」)。判定は時刻で決まるので、effect の影響を受けない
  - effect がある拍には、BPM の黄色い点線と同じように **青い点線** と値 (`scroll 2` / `jump 1000`) が出る。値は **レーンの左側** (BPM の値は右側なので、同じ拍に重なっても読める)。同じ拍に scroll と jump があるときは、線は 1 本で値は 1 行に並ぶ。関連コード: `Renderers.swift` の `drawEffects`
  - scroll: その拍から、譜面の流れる速さが 値 倍になる (1 = 普通 / 0 = 止まる / マイナス = 逆走)。jump: その拍になった瞬間、譜面が先へ一気に飛ぶ。**値は ms で、1000 = 1 秒間に進む距離ぶん**。そのときの **scroll の値に比例**する (scroll 1 で jump 1000 → 1 秒ぶん / scroll 2 → 2 秒ぶん / scroll 0 → 飛ばない)。同じ拍に scroll と jump があるときは、scroll を先に変えてから飛ぶ
  - **仕組み** (`EffectMap` / Effects.swift): ノーツの画面の高さは「その時刻の表示位置 P(t) − 今の表示位置 P(今)」で決まる (effect が無ければ P(t) = t で従来どおり)。scroll は P の傾き、jump は P の段差。**effect が 1 つも無い譜面は、従来のコードがそのまま動く** (見た目も速さも変わらない)
  - **スライドの描き方** (本家の仕様をnoteの解説どおりに再現): リボンは「隣り合う点どうしを、表示位置で結んだ台形」を並べたもの。判定は時刻の位置で決まるので、見た目とずれる
    - jump で中継点を遠くへ飛ばすと、始点から画面の外へ伸びる、ほぼ一直線のリボンになる (点滅スライド)。飛ばした点を判定が過ぎると、そこまでの台形は線の下に落ちて消える
    - 逆走 (scroll がマイナス) では、**区間の終わりの点を判定が過ぎたら、その区間の台形は描かない**。中継点のあるスライドだけ、その点を境に途切れて見える (途切れスライド)。中継点の無いスライドは、逆走しても残る。この「消す」処理は、逆走のある譜面のリボンだけで働く
  - 巨大な値 (jump 10000000 など) でも描画が壊れないよう、リボンの台形は描く範囲に切り詰めてから描く (`RibbonQuad.clipped`)
  - jump の飛ぶ距離は `jump(ms) ÷ 1000 × その時の scroll` 秒ぶん (`EffectMap.make`)。mc の値のまま `MalodyChart.load` から `EffectMap.Event.jumpMs` に渡している
  - 制限: ビットマップ方式 (台形が何百個も重なるリボン) では、逆走で台形を消す処理は働かない。effect のある譜面では、一度に描くノーツは 400 個まで
  - **FX 表示 (擬似テストプレイ)**: 左上のズームボタンの下の **FX** ボタンで切り替える (EditorState+FX.swift / RenderersFX.swift)。ON のあいだ、レーンはテストプレイの見え方になる。見るだけの表示で、編集はできない (ON にすると編集モードを抜ける。EDIT を押すと FX は切れる)。保存はしない (開くたびに OFF)。再生中もそのまま流れる
    - **seg の丸は出さない**。リボンとタップ / ウィップだけを描く
    - **scroll / jump を反映する**。高さの決め方はテストプレイと同じ「P(t) − P(今)」で、`EffectMap` をテストプレイと共有している (scroll 0.65 なら拍の間隔が 0.65 倍、グリッドと拍の番号も一緒に縮む)。**jump がマイナスなら、その時刻を跨いだ瞬間に、その先のノーツが奥側へぴょいんと戻る**。秒 → ピクセルの倍率は最初の BPM で固定 (BPM 変化のある譜面は、テストプレイと同じく時間で決まるので、拍の間隔が BPM に応じて変わる。effect も BPM 変化も無い譜面では、ふだんの表示とぴったり同じ位置)
    - **判定を過ぎたものは出さない** (時刻が今より前のタップ / ウィップ、全体が過ぎたスライド)。スライドは、始点が画面の上端に入ってから出す。逆走のある譜面は、区間の終わりの点を過ぎたら、その区間のリボンを消す (どちらもテストプレイと同じ)
    - jump で遠くへ飛んだ点があっても、リボンは **画面の縦の範囲に切り詰めて**描く (`clipQuad`)。幅の広いスライドを遠くの点へ伸ばして作る、画面全体に広がる半透明の面も、そのまま見える
    - 左上に、いまの再生ラインの scroll (**SC 0.65**) を出す。BPM / effect の線と値も、FX 表示では飛んだあとの位置に出る
    - 仕組み: 通常は「見えている拍の範囲」が 1 つだが、scroll / jump があると時刻の順と画面の順が一致しない。そこで、見える表示位置の範囲を `EffectMap.timeRanges` で時刻の範囲 → 拍の範囲に直し (`LaneRenderer.fxRanges`)、その範囲のノーツだけを描く。`LaneGeo.py` は、FX 表示のときだけ `LaneGeo.fx` (`FXWarp`) を通して高さを返す
    - 制限: 1 画面に描くのは、タップ / ウィップ 600 個、リボンの台形 8000 個まで
  - 未保存の編集内容も含めて、その場で mc を組み立てて遊ぶ (ファイルへは書かない)
  - PAUSE → 終了 でエディタへ戻る。判定/ACCは Testplayer と同じ (PC版C判定)
- ポーズ画面の待ち時間対策: `GameAudio.halt()` がデコードスレッドの完了を待たない作りに変更 (待つのは再開時の `prepare` のみ)。ポーズ画面の上部に「pause処理 〇 ms」を診断用に表示 (不要なら PauseOverlay の Text を削除)

## 編集ツール / ノーツの選択・移動 / 未選択時の操作
- EDIT を押した直後は **どのツールも未選択**。Note / Wipe / Slide / Remove のアイコンは、選択中にもう一度タップすると未選択に戻る
- **未選択のとき**: ノーツの配置・選択はできない。代わりにレーンを上下スライドで移動、ピンチでズームイン/アウト (再生ラインの位置を基準に拡大縮小。ズームは連続値で、−/＋ボタンは1段階ずつ)。EDIT に入っていない閲覧モードでも同じ操作ができる
- **Note / Wipe / Slide を選択中**:
  - 既存のノーツ(スライドはリボン・点を含む)に触れると選択され、青い成分が赤い色になる (Wipe は黄色 → 赤)。続けて別のノーツに触れると選択に追加される
  - 選択中のノーツの当たり判定内に指を置いて上下左右にスライドすると、選択中の全ノーツがまとめて移動する (移動量は1回の操作につき Undo 1回分)
    - 縦: 触れたノーツが 1/n 拍のグリッドに吸着する量で、全ノーツを同じだけ動かす (相対位置は保つ。0拍より前には行かない)
    - 横: グリッド有効時は1マス単位。全体が x:0〜255 の範囲から出ないところで止まる
  - 選択中のノーツに触れて、動かさずに離すと、そのノーツだけ選択から外れる
  - **幅スライダー**: レーン下の幅スライダーは、**EDIT を開いている間は常に表示**される (ツール未選択 / LASSO / Remove / Time range / Slide modify のときも。LASSO などで選んだノーツの幅をその場で変えるため)。ノーツを選択している間にこれを動かすと、選択中の全ノーツの幅がスライダーの値になる (指を離すまでが Undo 1回分)。何も選択していないときは、これから置くノーツの幅を決めるだけ
    - **位置 (x) と seg は動かさない。幅だけ**が変わる。左右の端が x:0〜255 の枠からはみ出してもよい (中心が 0〜255 の外に出ないことだけが条件で、幅を変えても中心は動かない)。グリッド有効時の幅は、新しいノーツを置くときと同じく 1マスの整数倍に丸める (`snapWidth`)。グリッド無効時は 1〜255 の整数
    - 関連コード: `EditorState+Tools.swift` の `widthSliderBegan / widthSliderMoved / widthSliderEnded / resized`、`EditorView.swift` の `LaneWidthSlider`
  - ノーツの当たり判定が無い所に触れると選択が全部解除される (このタッチでは配置しない。選択が無い状態で空きスペースに触れると従来どおり配置)
  - 判定は `EditorState.hitNote` (縦±14pt / 横はノーツ幅の半分+6pt)。選択状態は `EditorState.selectedIDs` (Note.id で管理。mc には書き出さない)
- **Slide ツールでのスライド作成 (ドラッグは使わない。タップだけ)**:
  1. 1回目のタップ = 始点ノート (この時点では譜面に入れず、ゴーストで表示。右の Slide アイコンが「完」になる)
  2. 2回目以降のタップ = seg。**置いた順がそのまま seg の順番**になる (時系列に並べ替えない)。最後に置いた点にはシアンの輪がつく
  3. 「完」を押すと、その始点への seg の配置が終わる (Slide ツールのまま。次のタップが新しい始点)。seg を 1 つも置かずに「完」なら、始点は取り消される
  - **時系列順でない seg** (直前に置いた seg = 終点より前の時間。始点より前 = beat がマイナスも含む) は、SETTING の「beatが時系列順でないsegを置くのを許可する」をオンにしたときだけ置ける (初期値オフ = 本家と同じ。保存される: UserDefaults `editor.allowUnorderedSeg`。前の版の `editor.allowNegativeSeg` の値は、新しい設定が未保存のときだけ引き継ぐ)。オフのときは、**終点の seg より前の時間**をタップすると、Slide ツールでは「完」と同じ扱いで seg の配置を終える。Slide modify では seg は足さずに選択を外す。Slide modify で seg を縦にドラッグ (縦移動を許可しているとき) しても、前後の seg の時間を越えない (もともと順番が崩れている側は縛らない)。保存のときは負の拍を `"beat":[-12,2,4]` (= -11.5 拍。整数部にマイナス、分子は 0 以上) の書き方にする (`Beat.json`)。
    `[0,-2,4]` のように分子にマイナスがある譜面を読み込んだときも、保存のときに直す (本家で不具合になるため)
  - 作成中は、どこをタップしても seg を置く (既存ノーツの選択・移動はしない)。seg 1 個の追加が Undo 1 回分。Undo で最初の seg を戻すと、始点だけの状態に戻る
  - Slide 以外のツールに切り替えると作成中は終わる (置いた seg は残る)
  - レーンの上下スライドは編集ツール選択中は使えないので、別の拍に seg を置くときは、レーン以外のスクロール操作 (帯・シークバー) で動かす
  - 関連コード: `EditorState+Tools.swift` の `slideDraft*` / `appendDraftSeg` / `finishSlide`、`Renderers.swift` の `drawSlideDraft`
- **Remove**:
  - 選択中のノーツ (赤いノーツ) がある時に押すと、そのノーツをまとめて削除して、ツールも Remove に切り替わる (削除は Undo 1回分。再生中は削除を断るので、ツールも選択も今のまま)。More の **Time range** で範囲を選んでから Remove を押せば、範囲の一括削除になる
  - 何も選択していない時は従来どおり Remove ツール (レーンをタップして1個ずつ消す) の ON/OFF。**Slide modify 中は、選択があっても Remove ツールに切り替わる** (掴んだスライドが選択状態になるので、そのまま削除するとスライドごと消えてしまうため。切り替わると選択は外れる)
  - **Remove ツールでスライドをタップ**: タップした位置にいちばん近い点 (始点 / seg) を探す。始点か **1 番目の seg** がいちばん近ければスライド全体を削除。2 番目以降の seg がいちばん近ければ、**その seg とそれ以降の seg** を削除する (「それ以降」は時間の順ではなく、譜面に記録されている seg の並び = 置いた順。削除は Undo 1回分)。近さは、点の高さはそのまま、横はスライドの幅の中なら 0 として測る (`EditorState.removeTapped`)
  - 関連コード: `EditorState+Tools.swift` の `removeButtonTapped` / `removeSelected`
- **LASSO** (**More メニューの Time range の下**。以前は EDIT の右ボタン列にあったが、Time range と同じ「選択の道具」なので More の中に移した。投げ縄の絵のアイコンは `MoreMenuIcons.swift` の `drawLasso`): 指でなぞって囲んだ範囲のノーツを、まとめて選択状態にする (お絵描きソフトの投げ縄と同じ使い方)
  - More メニューの Lasso をもう一度選ぶと未選択に戻る (選択したノーツは残る)。使っている間は、More ボタンが青くなり、メニューの Lasso も青くなる。切り替えたとき、使い方のトーストを1回出す (不要なら `EditorView.swift` の `moreList` の Lasso の `showToast` を削除)
  - レーンを指でなぞると、白い点線 + うす白の塗りで囲む範囲を見せる。**指を離すと、終点と始点を直線で結んで閉じ**、中にあるノーツが赤い選択状態になる
    - 線が自分と交差してもよい (始点を少し行き過ぎて閉じたときなど)。巻き数が 0 でない所を「中」とする (`EditorState.windingContains`)
  - 「中にある」の判定: タップ / ウィップは**中心の点**。スライドは**始点か seg の点のどれか**が中に入っていれば、スライド全体を選ぶ (リボンが線をまたいでいるだけでは選ばない)
  - **今の選択に追加**する (置き換えない)。LASSO 中はレーンを上下スライドできないので、帯・シークバーで拍を動かしながら、何回かに分けて囲める
  - 10pt 以上動かさずに離した (タップ) とき: ノーツの上ならそのノーツの選択 ON/OFF、何も無い所なら**全部の選択を解除**
  - 選択したあとは、そのまま Remove (まとめて削除) / More の Copy・Flip・変換、または Note / Wipe / Slide ツールに切り替えてドラッグ移動 (選択は残る)
  - 再生中は使えない (他のツールと同じ)
  - 関連コード: `EditorState+Tools.swift` の `lassoTouch` / `lassoTap` / `selectInLasso` / `windingContains`、`EditorState.lassoPoints` (なぞっている途中の線)、`Renderers.swift` の `drawLasso`、`EditorView.swift` の `moreList` (Lasso の項目)
- **Slide modify** (More → Slide modify): 本家と同じく、上の窓は無い。**スライドを先に選ぶ操作も要らず**、レーンで直接 seg を編集する。ほかのツールに切り替える (Note / Wipe / Slide などのアイコン、Back) と終わる
  - **点 (seg) をドラッグ**: 掴んだ瞬間に、その点があるスライドが選択状態になり (始点とリボンだけが赤くなる。**seg の点は通常の色のまま**)、そのまま動かせる。重なっているときは、いちばん近い点 (ほぼ同じなら選択中のスライド) を掴む。ドラッグ1回が Undo 1回分 (元の位置に戻して離したら Undo は積まない)。掴んでいる間は、その点に白い太い輪が付く
    - 動くのは **横 (x) だけ** (グリッドに吸着)。縦 (時間) にも動かすには、SETTING の「slide modifyでのsegの移動で縦方向の移動を許可する」をオンにする (初期値オフ。保存される: UserDefaults `editor.allowSegVerticalMove`。オンのときは 1/n 拍に吸着)
  - **選択中のスライドの上をタップ** (始点・リボン・点のどこでも): 選択が外れる (「完了」ボタンの代わり)。点を掴んだ場合はドラッグになるので、選択は外れない
  - **別のスライドをタップ**: そちらを選び直す
  - **空いている所をタップ**: 選択中のスライドがあれば、その最後に seg を追加 (Slide ツールと同じく、置いた順が seg の順番。すでに点がある位置には足さない)。ただし終点の seg より前の時間は、上の設定がオフなら追加せず選択を外す。選択中のスライドが無ければ何もしない
  - seg の**削除は Remove ツール** (上の「Remove ツールでスライドをタップ」)。Slide modify には「削除」ボタンも上の窓も無い
  - 選択中のスライドの seg には、動かせる目印のシアンの輪が付く。本家には無いので、消したいときは `LaneRenderer.drawSegRings = false`
  - レーンの上下スライドはツール選択中は使えないので、拍を移動するときは左の帯 (タイムライン) かシークバーを使う
  - Slide modify に入るとき、選択がスライド1つだけなら、そのスライドがそのまま編集対象になる
  - 関連コード: `EditorState+Tools.swift` の `slideModifyTap` `addSegAt` `hitSegAny` `dragSeg` `removeTapped` / `Renderers.swift` の `drawSlideModify` `drawNotes` (選択中の色)
- **長押しで選択解除**: ツール未選択 (EDIT 直後 / 選択中のツールをもう一度タップして外したあと / 閲覧モード) のとき、レーンを**動かさずに押し続ける**と、選択中のノーツが全部解除される (トーストで知らせる)
  - 秒数は SETTING の「長押しで選択解除」で **1.0〜5.0 秒** (0.1 秒刻み、初期値 2.0 秒)。値は次回起動時も保存される (UserDefaults: `editor.holdDeselectSec`)
  - 指が 10pt を超えて動いた (= 上下スライドになった) / 指を離した / ピンチが始まったときは取り消される。選択が無いときは何もしない。押している間にツールを選んだときも解除しない
  - 関連コード: `EditorView.swift` の `LaneView` (タッチの始まり=`holdBegan` / 動き・離す・ピンチ=`holdCancel`) と `SideWindow.swift` の `SettingWindowContent.holdRow`、`EditorState+Tools.swift` の `holdBegan / holdCancel / holdFired`、`EditorState.holdDeselectSec`
- 選択は、Back を押したときに解除される (未選択に戻しただけでは残るので、パン・ズームしてからコピーや貼り付けができる)

## Adv. (Malody V の Lua プラグインを動かす)
EDIT の右ボタン列、**Order の下・More の上**に **Adv.** (λ) がある。

- **開き方**: Adv. を押すと、レーンの**右端を固定したまま左端が右へ動いて横に縮み**、再生ボタン (シークバー) とレーンの間にプラグインのメニュー (幅 196pt、`AdvPanel.width`) が出る。もう一度 Adv. を押す (またはメニュー右上の ✕ / Back) と閉じる
- **プラグインは縦にスクロール**する (`ScrollView` + `LazyVStack`)。何百個並んでも使える
- **実行**: 並んでいるプラグインを押すと、その `Run()` を実行する。実行中は別スレッドで動くので画面は固まらず、メニュー右上の**停止**で止められる (Lua のループの途中で止まる)
- **プラグイン(lua)を読み込む**: メニューの一番下のボタンで「ファイル」アプリが開く。**.lua / .zip / 画像を、複数まとめて**選べる
  - `.zip` (Malody V のプラグインの配り方: .lua + 画像) は、中身を `Plugins/<zip の名前>/` に展開する。`.lua` は `Plugins/<ファイル名>/` に入れ、一緒に選んだ画像もそこに入る。画像 (`PluginIcon` や `AddSprite` の画像) は、その .lua と同じフォルダから探す
  - 読み込むときにプラグインの先頭 (`PluginName` / `PluginMode` / `PluginType` / `PluginRequire` / `PluginIcon`) を読む。構文エラーのファイルや、`Run()` も `OnActive()` も無いファイルは追加せず、理由を表示する
  - 保存されたものは、次回起動時も並ぶ。**長押し → 削除**で消せる (内蔵は消せない)。そのフォルダに .lua が無くなったら、画像ごと消える
  - ファイルアプリを SwiftUI の `.fileImporter` ではなく UIKit のピッカーで開くのは、外側の画面 (RootView) にも `.fileImporter` があると、内側のものが開かないことがあるため
- **Undo**: 1回の実行 = Undo 1回分。↶ で実行前に丸ごと戻る
- **print() の出力**はメニュー下部の「出力」欄に出る。エラーは「ファイル名:行番号: 内容」でダイアログに出る
- **内蔵プラグイン** (`BuiltinPlugins.swift`): `quad_InOut` / `quad_OutIn` / `Join Slides (Fixed)` (添付された Malody V 用プラグイン) と、editor.html から移植した `終点と始点を繋げる` / `折り返し敷` / `枝分かれ敷` が最初から入っている (結合系は、上の Order ボタンの「順番に選択」を使う)

### 操作型プラグイン (PluginType 2。例: GizaSlide)
`Run()` を1回実行する型とは別に、**押すと「アクティブ」になり、レーンのタッチを受け取り続ける**型に対応している。Adv. メニューでは、行に **ON** と出て、アイコン (`PluginIcon`) が付く。

- **使い方 (GizaSlide の例)**: スライドを1本選ぶ → Adv. で GizaSlide を押す (ON) → レーンの真ん中に**つまみ**が出る → つまみを横にドラッグすると、スライドがギザギザの形になる → もう一度押す (OFF) か、別のツール・Back でつまみが消えて終わる
- **イベント**: アクティブの間、レーンのタッチが次のように渡る。`OnActive` (押した瞬間) / `OnDeactive` (終わるとき) / `OnClick` (動かさずに離した) / `OnDragStart` (動かし始め。位置は指を置いたところ) / `OnDragMove` (動くたび) / `OnDragEnd` (離したとき)。プラグインに無いイベントは何もしない
- **位置**: イベントの中で `Editor:GetClickX()` (レーン上の x: 0〜255)、`GetClickBeat()` (いまの分割に合わせた拍)、`GetClickBeatFree()` (合わせない拍) が、触れている位置を返す
- **スプライト**: `Editor:AddSprite(名前, 画像のファイル名)` で、レーンの上に画像を出す。戻り値のモジュールの `.Beat` (縦の位置の拍) / `.X` (中心の横位置。レーン幅に対する %) / `.Width` (幅。レーン幅に対する %。高さは画像の縦横比のまま) を書き換えると、すぐ画面に反映される。同じ名前で `AddSprite` をもう一度呼ぶと、新しい画像を作らずに同じモジュールを使う。`RemoveModule(名前)` で消す。`FindModule(名前)` で探せる。アクティブが終わると、残っていても消える
- **Undo**: 1回のドラッグ (または1回のクリック) = Undo 1回分
- **メインスレッドで動く**: 1つのイベントは短く終わるので、タッチ処理の中で、そのまま実行する (書き換えの途中が一瞬映ることがない)。1つのイベントは2秒まで (超えると止める)。そのかわり、操作型の中では `ShowMessage` は表示だけして待たず、`GetUserInput` は使えない (nil が返る)。エラーは画面の下に表示される
- 実装: `PluginSession` (エンジンを起動・イベントを1つずつ呼ぶ) / `EditorState.pluginTouch` (タッチの振り分け) / `EditTool.plugin` / `Renderers.drawSprites` (画像の描画)

### 順番に選択 (Order ボタン)
EDIT の右ボタン列、**Remove の下・Adv. の上**に **Order** (①②) がある。スライドを**タップした順に番号を付けて**記録するツールで、結合系プラグインがこの順番を使う (editor.html の「順番に選択」と同じ)。

- **使い方**: Order を押してから、スライドをタップする。1番目は**赤**、2番目以降は**水色**で、始点に番号が出る。ほかのツールに切り替えても順番は残る (ボタンの文字が `Order 3` のように、選んだ数になる)。もう一度 Order を押すと、ツールだけ OFF (順番は残る)
- **重なったスライド**: 順番に入れたスライドは、タップの当たり判定から外れる。同じ場所をもう一度タップすると、下に重なっているスライドが選べる
- **リセット**: スライドの無い所をタップすると、順番を全部リセットする (ほかのツールの「何も無い所をタップで選択解除」と同じ)。結合系プラグインを実行すると、結合したあとにリセットされる
- LASSO などの通常の選択とは**別**に記録される (併用できる)。Undo の対象ではない。消えたスライドは順番から外れ、番号が詰まる
- `EditorState.orderIDs` (順番) / `EditorState.orderTap` (タップの処理) / `Renderers.drawOrder` (番号の表示)
- Lua からは `Editor:GetOrderNotes()` (順番に並んだノーツ。`.Length` と 0 始まりの添字) と `Editor:ClearOrderNotes()` (リセット)。**このエディタ独自の API** なので、本物の Malody V では存在しない (プラグイン側で `Editor.GetOrderNotes ~= nil` を調べて使う)

### 結合系プラグイン (editor.html から移植)
スライドを選んでから、メニューのプラグインを押す。選ぶのは**スライドだけ** (タップ・ウィップが混ざっていても無視される)。結合したあと、本体以外のスライドは消えて、順番はリセットされる。

| プラグイン | 順番に選択 **2本以上** (手動) | 順番に選択 **1本** + 選択中のスライド (自動) | 順番に選択 **なし** (選択中のスライド) |
|---|---|---|---|
| **終点と始点を繋げる** | 選んだスライドを、始点 beat の早い順に、前の終点 → 次の始点を一直線に繋ぐ (同じ beat は選んだ順) | (1本だけでは、2個以上選ぶよう表示) | 選択中のスライドを、始点 beat の早い順に繋ぐ |
| **折り返し敷** | **選んだ順どおり**に、行ったり来たりしながら一筆書きで結合 (1番目が本体。順行 → 逆走 → 順行…) | 1番目が本体。選択中のほかのスライドを、始点 beat の早い順に結合 | 始点がいちばん早いスライドが本体。残りは始点 beat の早い順 |
| **枝分かれ敷** | 選んだスライドのうち、始点がいちばん早いものが幹 (同じ beat は選んだ順の早いほう)。残りが枝 | 1番目が幹。選択中のほかのスライドが枝 (始点 beat の早い順) | 始点がいちばん早いスライドが幹 |

- 各スライド内部の seg の並び (逆走・折り返し・マイナス beat) は変えない。枝分かれ敷は、枝を幹の seg の通り道の上の、その枝の終点にあたる位置から差し込む
- **枝分かれ敷 (新しい仕様)**: 枝は、幹の上のその枝の終点にあたる位置から、枝を逆走して始点へ → 枝を順行して終点へ → 幹へ戻る、とたどる。
  * 幹にも枝にも、**すでに枝分かれ敷を使ったスライド**を使える。幹: いま付いている枝の周回はそのまま残して、新しい枝を「幹の通り道」(beat が前の seg より先へ進む seg だけを拾った折れ線。beat が戻る周回は入れない) の正しい位置へ差し込む。枝: 枝の中の周回ごと、逆走 → 順行でたどる (枝が終点より先まで周回しているときは、いちばん遅い beat を幹との接続点にする)
  * 装飾の始点が本体より早くてもよい。その部分は、マイナス beat (整数部がマイナス、分子は 0 以上) の seg になる
  * **速さ**: seg が何万個もあるときは、下の `GetNoteSlideBodyAll` / `ReplaceNoteSlideBody` / `DeleteNotes` を使って、スライド1本につき1回の往復で読み書きする (以前は seg ごとに往復して、30分ほどかかることがあった)。これらが無い環境 (本物の Malody V など) では、従来どおり seg を1個ずつ読み書きする。seg は Lua の表を作らず、「整数部, 分子, 分母, x」を4つずつ並べた平らな配列で持つ
- **バグスライド (beat の重複) は常に許す**: このエディタは beat が重複しても描画が崩れないので、境目の自動ずらし (結合順 × 1/8477 拍) も、重複 seg の自動修復 (1/9001 拍ずつ) も行わない (editor.html の「バグスライドを許す」を常に ON にしたのと同じ)。結合のたびに beat が動かず、境目が直角のまま残る
- 「順番に選択」が1本だけで、ほかに選んだスライドも無いとき (折り返し敷・枝分かれ敷) は、何もせず、選び方を表示する。元の editor.html にあった「1本だけでバグ修復」は、重複を常に許すようにしたので無くなった
- 「終点と始点を繋げる」「折り返し敷」のロジックは editor.html の `mergeSequentialInto` / `mergeJoinInto` と補助関数を1対1で移植したもの (枝分かれ敷は、上の新しい仕様で作り直したので、editor.html の `mergeBranchesInto` とは結果が変わる)。元の関数を (`allowDupBeat = true` で) そのまま実行した結果と、ランダムな譜面 1800 通り (順番なし / 1本 + 装飾 / 手動の3パターン) で出力が完全に一致することを確認している (`lua-engine-src/test_html_diff.js`)

### 仕組み
Swift Playgrounds のアプリには Lua 本体 (C 言語) を組み込めないため、**Lua → JavaScript の変換器と Lua 標準ライブラリを JavaScript で書き、iOS 標準の JavaScriptCore で動かしている** (`LuaEngineSource.swift`)。
- 対応する Lua: 5.1〜5.3 の主要な文法 (クロージャ・可変長引数・多値・メタテーブル・`goto continue` など前方への goto・`//` とビット演算)、`string` (Lua パターン・`format`)、`table`、`math`、`os`、`bit32`、`pcall` / `error` など。**非対応**: coroutine、後ろ向きの goto、`require` / `dofile`、`io` のファイル操作。文字列は UTF-16 で扱うので、日本語の `#文字列` はバイト数ではなく文字数になる
- 数値は 5.1/5.2 と同じく倍精度のみ (`3.0` は `3` と表示される)
- プラグインごとにグローバル環境が別なので、プラグイン同士で変数が混ざらない。`Run()` のたびに最初から読み直す
- `LuaEngineSource.swift` は自動生成のファイル。直すときは元の JavaScript (別フォルダ `lua-engine-src/`: ソース・テスト・`build.py`) を直して、`python3 build.py ../LuaEngineSource.swift` で作り直す

### Editor の API (APIリファレンス.txt との対応)
`Editor:関数名(...)` の形で呼ぶ。ノーツは**番号** (1, 2, 3…。本物の Malody と同じく数値なので、`'m-' .. note .. 'grip'` のように文字列と連結できる)、`GetSelectNotes()` などの一覧は `.Length` と 0 始まりの添字 (`Notes[0]`)。拍は `{beat=, numor=, denom=}` の表。

| 状態 | 関数 |
|---|---|
| **実装済み (添付プラグインで使用・動作確認済み)** | `GetSelectNotes` `GetNoteTime` `GetNoteBeat` `GetNoteX` `GetNoteWidth` `GetNoteType` `GetNoteSlideBodyCount` `GetNoteSlideBodyBeat` `GetNoteSlideBodyX` `AddNote` `DeleteNote` `SetNoteBeat` `SetNoteX` `SetNoteWidth` `AddNoteSlideBody` `SetNoteSlideBodyX` `DeleteNoteSlideBody` `BeatAdd` `BeatMinus` `StartBatch` `FinishBatch` `ShowMessage` `ShowTip` |
| **実装済み (操作型プラグイン GizaSlide で使用・動作確認済み)** | `GetClickX` `GetClickBeat` `GetClickBeatFree` `AddSprite` `RemoveModule` `FindModule` `MakeBeat` `GetNoteBeat(note, false)` (終点) |
| **このエディタ独自 (本物の Malody V には無い)** | `GetOrderNotes` (Order ボタンで選んだ順のスライド) `ClearOrderNotes` (その順番をリセット) `GetNoteSlideBodyAll` (スライドの seg を全部、1回の往復で読む。戻り値は 1 始まりの平らな表で、`[整数部, 分子, 分母, x]` が seg の数だけ並び、`.Length` が seg の数) `ReplaceNoteSlideBody` (スライドの seg を、同じ形の平らな表で丸ごと置き換える。並べ替えない) `DeleteNotes` (ノーツの番号を並べた表を渡して、まとめて消す) `AppendNoteSlideBody` (seg を並べ替えず、足した順のまま末尾に足す。beat が行ったり来たりするバグスライド用) |
| **実装済み (使い方は推測。実際のプラグインで確かめて調整)** | `GetCurrentTime` (ms) `GetSystemTime` `GetCurrentBeat` `GetCurrentDivide` `GetNoteCount` `GetNoteAt` `GetTimeCount` `GetTimeAt` `GetEffectCount` `GetEffectAt` `AddTime` `DeleteTime` `AddEffect` `DeleteEffect` `SelectNote` `SetGridLine` `SeekTo` `MakeBeat` `GetUserInput` |
| **未対応 (呼ばれると、何もせず通過して、実行後にどれが呼ばれたかを表示)** | `GetNoteFlag` `GetNoteGroup` (どちらも 0 を返す) `SetNoteFlag` `SetNoteGroup` `WriteFilePlugin` `ReadFileSelect` `ReadBytesSelect` `ReadData` `WriteData` `WriteChartCustom` `CallShortcut` `GetUserSelect` `GetUserOption` `AddText` `AddSpriteUndo` `AddTextUndo` `RemoveSpriteUndo` |

- `GetUserInput(題, 初期値, コールバック)`: OK を押したときだけ、答えの文字列を `コールバック(値)` に渡して呼ぶ (キャンセルでは呼ばない)。戻り値でも同じ文字列を返すので、コールバックを使わない書き方もできる。`(題, コールバック)` のように初期値を省いてもよい。`wipe2hold` のようにコールバックで受け取るプラグインは、この対応で動く (操作型プラグインの中では、これまでどおり nil が返り、コールバックは呼ばれない)
- `GetNoteBeat(note, true)` は始点、`GetNoteBeat(note, false)` は終点 (スライドは、始点 + 最後の seg の相対 beat)。`GetNoteTime` も同じ
- ノーツの種類は `Tap = 1` / `Wipe = 1024` / `Slide = 2048` (`GetNoteType` の戻り値、`AddNote` の引数)。スライドは「seg を持つノーツ」なので、`AddNote(2048)` で作ったノーツは、`AddNoteSlideBody` で seg を足すまではタップとして保存される
- `AddNoteSlideBody(note, beat)` は、seg を **beat の順になる位置に挿入**して、その位置 (0 始まり) を返す (本物の Malody と同じ。同じ beat なら、あとから足したほうが後ろ)。`SetNoteSlideBodyX` などの添字は、この並び順
- スライドの seg の beat / x は、始点からの**相対値** (mc と同じ)。`DeleteNoteSlideBody(note)` は seg を全部消し、`DeleteNoteSlideBody(note, i)` は i 番目 (0 始まり) だけ消す
- 拍の分母は約分して保存する。分母が 2^22 を超える拍や、極端に遠い拍は 1/1048576 拍に丸める。負の拍は 0 拍に直す
- `SetNoteX` は 0〜255、`SetNoteWidth` は 1〜255 に収める
- API を足す場所: ① `LuaEngineSource.swift` の元になっている JavaScript の `makeEditor` に `def('関数名', ...)` を足す → ② 譜面を触る処理が必要なら `PluginBridge.swift` の `handleMain` に `case "コマンド名"` を足す (JavaScript 側は `native('コマンド名', 引数…)` で呼ぶ) → ③ `LuaEngineSource.swift` を作り直す

## More メニュー: コピー / 範囲選択 / 変換
コピー・反転・変換はすべて「選択状態のノーツ (赤いノーツ)」が対象。
- **見た目 (本家の画面収録から実測)**: 幅 275pt・1行 45.6pt。黒 50% の半透明 + 白の細い縁で、下の譜面や背景が透けて見える。各項目は「アイコン + 文字」(本家と同じ機能の項目は本家のアイコン。Time range だけ、正方形の中に上矢印の自作アイコン)。選択中のツール (Time range / Slide modify) は青 (`Color.panelBlue`)
- **位置**: 本家は、メニューの上端が More ボタンの中心の 263pt 上。自作は More ボタンが本家より下にある (EDIT のボタンが多い) ので、メニューもその分下に出る (`EditorView.moreMenuTop` / `RightPanel.moreCenterY`)。画面の下にはみ出すときだけ上へ寄せる
- 本家の「Cut」は未実装なので、その行は無い (本家の下側にある、項目の無い空白も省いてある)。アイコンの輪郭を直したいときは `MoreMenuIcons.swift` の `MoreMenuIconData`
- **Copy**: 選択中のノーツを保存する (いちばん前のノーツの拍を基準にした相対位置で持つ)。何も選択していないときはトーストで知らせる
- **Paste**: 保存したノーツを、再生ラインの位置にいちばん前のノーツが来るように貼り付ける。貼り付けたノーツは選択状態になる
- **Time range**: 始点の拍 → 終点の拍の順にレーンをタップすると、その間 (両端を含む。ノーツの先頭の拍で判定) のノーツが選択状態になる。3回目のタップで始点からやり直し。Time range を抜けると範囲の表示は消えるが、選択は残る (Note / Wipe / Slide を選べば、そのまま動かせる)
- **Flip notes horizontal**: 選択中のノーツを左右反転。何も選択していないときは全ノーツ。鏡の軸はレーンの真ん中 (x=127.5。x' = 255 - x)。グリッド線の上にあった中心 (スライドは始点と各 seg の点それぞれ) は、反転後もグリッド線 (j → 線の数 - j) の上に来る (`EditorState+Tools.swift` の `flippedX`)。以前は軸が x=127 (254 - x) で、反転後が 1 ずれていた
- **Grid settings**: 押した瞬間に、画面の真ん中に本家風のダイアログが出る (下から上がるシートの待ち時間なし)。背景は `UIVisualEffectView` で強くぼかし、枠は黒 50% の半透明。Grid lines はバーを触る / なぞって 1〜64 を決める。Grid align はチェックボックス。「完了」で反映、「戻る」で破棄。表示の切り替えは `EditorState.showGridDialog`
- **Grid align ON のときのノーツ位置 (本家と同じ)**: 幅は 1マスの整数倍。**ノーツの中心** が、いちばん近いグリッド線に合う (`EditorState.snapNote`)。幅が偶数マスなら両端もグリッド線の上、奇数マス (例: 32 Grid で 7マス) は両端がマスの半分ずれる。ノーツがレーン (0〜255) の外にはみ出さない範囲で線を選ぶので、奇数マスのノーツは左右の壁から半マス以上内側になる。スライドの seg を置く / 動かすときも同じ規則 (seg の x は中心)。ノーツを移動するときは、中心をマスの整数倍だけ動かす (`snapDeltaX`)
- **Slide to Wipe / Wipe to Slide**: 選択中のノーツだけを変換する (Wipe to Slide は選択中の Wipe が2個以上必要)。変換後のノーツは選択状態になる
- 関連コード: タッチ処理 `EditorState+Tools.swift` の `laneTouch` / ジェスチャ `EditorView.swift` の `LaneView` / 描画色 `Renderers.swift` の `selTap*` `selWipe*` `selRibbon` `selDot`

## META / SETTING (右ボタン列 + 右ウィンドウ。シートはやめた)
BPM list / Effect list と同じ作りに統一した。`SidePanel` に `.information` / `.setting` を足して、`SidePanelLayer` / `SideWindow` がそのまま出し入れする (右の端から滑って入る・ウィンドウより左を触ると閉じる・右ボタン列は開いている間だけ見えなくなる)。

- **META** (`EditorState.metaOpen`): 押すと、右ボタン列が EDIT と同じ動き (`panelSwap`) で **Back / Information / More / Review / Quit** に入れ替わる。アイコンの左の名前 (Back / Information / More / Review / Quit) も EDIT と同じく、2.6 秒たつと消える。本家の Delete all / Upload は使わない。階層は無い
  - **Information**: 右ウィンドウ (`InformationWindowContent`)。曲名 / Original Title / アーティスト / Original Artist / Version / Creator (入力欄。打つたびに譜面へ反映してオートセーブ)、**曲のファイル / 背景ファイル (mc に書くファイル名の入力欄。書き換えられる。付属の音源・画像のファイル名そのものは変わらず、mc の記述だけが変わる。mcz に書き出すときは新しい名前で入る。曲のファイルを空にすると、読み込んだ音源のファイル名が使われる)**、背景ファイルの下の **写真から読み込む**、オフセット (ms。入力欄 + −10 / +10 ボタン。マイナスも打てる)。縦にスクロールでき、入力欄以外を触るとキーボードが下がる
  - **More (•••)**: 押した瞬間に mcz を作って、共有シート (保存 / AirDrop / ファイルなど) を出す。もう 1 回タップする必要は無い (`EditorState.shareMCZNow` → `MCZSharer`)。失敗したときはトーストで知らせる
  - **Review** (自作。More の下、Quit の上。アイコンは正方形の中に小さい正方形 = `ReviewIcon`): 多重ノーツ探し (`EditorState.reviewChart`)。**同じ拍・同じ中心 x** に「tap と tap」または「tap と wipe」が重なっているところを探す (wipe と wipe、スライドの始点・seg は調べない。幅 w は見ない)。見つかったら、再生中なら止めて、いちばん早い拍へ飛ぶ (複数あっても時系列で最初の 1 か所。直さずにもう一度押すと、同じところへ飛ぶ)。META の列は開いたまま。見つからなければ、画面の上に半透明の黒い札「0 issue found」が一瞬だけ出て勝手に消える (`ReviewNoticeLayer`。Grid settings と同じ濃さ・縁・形を縮めたもの。0.08 秒で出て、0.4 秒見せて、0.22 秒で消える)
  - **Quit**: 押した瞬間に、再生を止めて・保存して・エディタを閉じてファイル選択へ戻る (`EditorState.quitEditor`)。確認ダイアログは出さない (保存してから閉じるので、編集は失われない)
  - **Back**: いつもの列 (EDIT / BPM / EFFECT / TEST / META / SETTING) に戻る
- **SETTING**: 右ウィンドウ (`SettingWindowContent`)。項目は、これまでの SETTING と同じ (曲の音量 / ノーツサウンドの音量 / 背景画像の暗さ / 立ち上がりをはっきりさせる / beatが時系列順でないsegを置くのを許可する / slide modifyでのsegの移動で縦方向の移動を許可する / 現在位置を分割(LFB)の線にスナップする / 長押しで選択解除)。文字・縁取り・選んでいる色 (`Color.panelBlue`) を他の右ウィンドウにそろえ、縦にスクロールできる。チェックボックスは白い縁取りの四角

## SETTING / キー音
- 右ボタン列の META の下の **SETTING** で、BPM list / Effect list と同じ右ウィンドウが開く (閉じるのは、ウィンドウより左を触ったとき。中身は「META / SETTING」を参照)
  - 曲の音量 / ノーツサウンドの音量 (0〜100%、5%刻み)。値は次回起動時も保存される (UserDefaults: `editor.musicVolume` / `editor.noteVolume`)
  - 曲を再生したまま開いて、音量を調整できる (開いても再生は止まらない。ウィンドウより左を触ると閉じる)
  - ノーツサウンドのスライダーは、指を離した時に1発鳴って音量を確かめられる。0% でキー音オフ
- キー音が鳴るタイミング
  - エディタ再生中: ノーツ先頭が再生ライン(シアンの横棒)に触れる瞬間。同時押し(1ms以内)は1発にまとめる
  - テストプレイ: tap / wipe / スライド始点を捌いた瞬間 (`GameCore.onHit`)
  - 再生中のキー音は「鳴る時刻を指定して先行予約」(0.25秒先まで)。フレームレートに依存せず、曲と同じ時計から予約する (下の「再生クロック」参照)
- キー音の音色を変えたいとき: `KeySoundData.pcm16Base64` を、同じ形式 (44.1kHz / モノラル / 16bit PCM / リトルエンディアン) の base64 に置き換える。長さは波形から自動で決まる
  * 現在の波形は、画面収録した音 (AAC) の前後を切り、末尾の急な切れ目を 12ms のフェードにして、真のピーク -1 dBTP に音量をそろえたもの。自然な音なので、以前のコード合成音 (tanh で矩形波近くまで潰していた) より **約 10dB 小さく聞こえる**。音量が足りないときは、曲の音量を下げるか、`KeySound.softClipDrive` を 1.0〜3.0 にする (+1.5〜+6dB。音は少し硬くなる。0 = 自然な音)
  * 波形が読めなかったときのフォールバック (従来のコード合成音) は `KeySound.makeBuffer`。`base`(高さ Hz) = 6600 / `drive`(潰し具合) = 100 / `dur`(長さ) = 0.02

## 再生ボタンの反応速度
- 再生ボタンを押してから動き出すまでの余裕は `EditorState.playLead` (現在 0.05 秒)。短いほど反応が速いが、短すぎると曲の頭出しがずれる
- 再生開始では「曲の下ごしらえ(`GameAudio.begin`)→ 鳴らす時刻の予約 → 画面の時計を開始」の順にする。順序を逆にすると、下ごしらえに掛かった分だけ曲が譜面より遅れて始まる
- 停止中、表示位置が 0.04 秒止まると `GameAudio.warm` が次の再生位置を先に用意する。位置が合っていれば再生ボタンの瞬間の下ごしらえを省く (曲は展開済みのメモリを読むだけなので、普通の速度ではほとんど効果が要らない。伸ばした音で効く)

## 再生/停止の遅延対策 と 曲の長さの異常 (修正メモ)
- **停止の遅れ**: `KeySound.cancelScheduled` が、停止のたびに 8 ノード全部へ `stop()`+`play()` (計16回の同期呼び出し) をしていた。
  今は「まだ鳴っていない予約を持つノード」だけを `stop()` し、再生状態への復帰は次に鳴らす時 (`ensureRunning`) に回す
- (以前ここにあった AVAudioPlayer の停止 / 再生やり直しの対策は、AVAudioPlayer の経路ごと無くした。曲の再生は `GameAudio` (AVAudioEngine) だけで、割り込み・イヤホンの抜き差しのあとは `GameAudio.begin` がエンジンを起こし直す)
- **ボタン**: 再生/停止ボタンは「指が触れた瞬間」に切り替わる (`PlayToggleButton`)。従来の「離した時」に戻す方法はそのファイルのコメント参照
- **再生ボタンの形と位置**: 本家と同じ正六角形 (左右が尖る。頂点から頂点まで 100pt、高さ 86.6pt、白い縁 2.8pt、中は不透明なグレー)。中心は画面の左端から 205pt (`SeekPanel.hexCenterX` = 60pt)、縦は画面の真ん中。左の頂点が現在位置の白い線にとどくよう、線を 11pt だけ伸ばしている。**押せる範囲は従来どおりの縦長の長方形** (幅 102pt = `SeekPanel.totalWidth` − 2、高さ = 画面の約1/5。本家の六角形だと小さくて、シークバーを誤って触って現在位置がずれるため、わざと大きくしてある)。六角形の絵はタッチを受けず、透明な長方形が受ける。`SeekPanel` (EditorView.swift) が、シークバー(66pt) + 時刻表示(38pt) + 再生ボタンを重ねて作る。
  ボタンの当たり判定の外 (上側・下側) のシークバーを触ってドラッグすると曲の位置を動かせる。その間だけボタンは透明になる (`SeekView` の `seeking` → `PlayToggleButton` の `dimmed`)。
  大きさを変えるときは `SeekPanel` の `btnH` / `btnW`、アイコンの大きさは `PlayToggleButton` の `size: 44`
- **描画**: スライドの描画は、画面に掛かっている区間だけを描き、表示範囲に切り詰める (seg が数万個ある譜面でも再生が重くならない)
- **tick**: 1フレームに Canvas が4つあるため、同じフレーム内の2回目以降の `tick()` は省く
- **曲の長さが異常に長くなる**: 譜面に壊れた値 (例: `[0, 1983827953, 1]` = 約20億拍先の seg) があると、曲の長さがそれに引きずられていた
  (03.mc は 824 拍のスライドに 4 個ある。約757万分になる)。
  今は「曲の長さ + 60秒 (音源が無ければ3時間)」より遠い点を長さの計算から除き、読み込み時にトーストで件数を知らせる。
  譜面データ自体は書き換えない (保存時もそのまま)

## 再生クロック (曲・レーン・キー音を同じ時計で動かす)
再生中の画面は、CADisplayLink (`EditorState.onFrame`) が1フレームに1回、「そのフレームが画面に出る時刻 `frameHost`」を取り、
`currentSec()` はその時刻から譜面時刻を返す。レーン・縦タイムライン・シークバー・時刻表示は同じフレームなら必ず同じ値になる。
(以前は Canvas ごとに `CACurrentMediaTime()` を読み、`AVAudioPlayer.currentTime` との差が60msを超えるたびに時計を丸ごと飛ばしていた → レーンのワープ。今は AVAudioPlayer を使っていない)

- **エンジン方式** (音源あり。全部の速度): テストプレイと同じ `GameAudio` (TestPlay.swift) を使う。
  `lastRenderTime` から得た「実際に鳴っているサンプル位置」で毎フレーム時計を合わせ直す。出力遅延も込みで「聞こえる位置」を譜面時刻にする。
  キー音は `GameAudio.uptime(atChartTime:)` − `outputLatency` の時刻に予約する (曲のサンプルと同じタイミングで聞こえる)
- **壁時計** (音源なしで開いたとき・オーディオエンジンを起動できなかったとき): 動き出した時刻からの経過時間だけで進める (曲が無いので、合わせる相手がいない)。以前あった「AVAudioPlayer + 推測航法」の従来方式は、曲を `SongPCM` に展開するようにして無くした
- 速度の切り替え・ポーズ・シークで毎回 `play()` が時計を作り直すので、ズレは蓄積しない
- **再生ボタンの反応 (エンジン方式)**: 停止中、表示位置が0.1秒止まると `GameAudio.warm` が、次の再生位置のシーク・デコード・最初のバッファ投入を別スレッドで済ませておく。
  再生ボタンでは `begin` が「用意済みの位置と20ms以内で合っているか」を見て、合っていれば再生の予約だけで始める (合っていなければ従来どおりその場でシーク)。
  SETTING の下に「再生開始の下ごしらえ ○ ms (先読み済み / 先読みなし)」を出している (不要なら `SideWindow.swift` の `SettingWindowContent.playInfoText` を削除)。
  位置を動かして0.04秒以内に再生を押したときは「先読みなし」になるが、曲は展開済みのメモリなので、その場のシークでも待ちはほとんど無い (伸ばした音のときは少し待たされる)
- **曲の展開 (SongPCM。再生ボタンの待ち時間対策と、曲を開く時間の短縮)**: 曲は、エディタを開くときに **1 回だけ** Float の左右 PCM に展開する (`SongPCM.decode` / AudioController.swift。`RootView.openEditor` が別スレッドで呼ぶ)。
  エディタの再生 (`GameAudio(song:)`)・テストプレイ (`startTestPlay`)・曲の長さ (`recomputeTotal`) は、その同じ PCM を読むだけ。以前のように、曲を開くたびに WKWebView で WAV へ変換したり、`GameAudio` で自前デコーダーによりもう一度全部展開したり、テストプレイのたびにファイルを書き直してまたデコードしたりしない。
  - ogg は、ipa では **stb_vorbis** で展開する (PC での測定は 185 秒の曲で約 0.3 秒。iPad での実測は SETTING の「音源読込」の行に出る。展開した結果は、libvorbis と float の誤差 (約 2e-7) の範囲で一致することを PC で確認済み)。stb_vorbis が読めない ogg (Opus など) は、自前の ogg デコーダー → AVAudioFile の順に試す。ogg 以外 (mp3 / wav / m4a) は AVAudioFile
  - Playgrounds (Package.swift) では C が入らないので、ogg は自前の Swift デコーダーで展開する。最適化なしのビルドなので、曲を開くときに数十秒待たされる (ipa では起きない)
  - 展開済みの PCM はメモリを読むだけなので、シーク・最初の buffer 作りは `memcpy` だけで一瞬。`GameAudio.warm` の先読みが間に合わなくても、再生ボタンで待たされない
  - 使うメモリは 曲の長さ × 約 21MB/分 (44.1kHz ステレオ。モノラルの曲は半分)。上限は 20 分 (`SongPCM.maxFrames`)。超える曲は読み込まず、音なしで開く
  - 0.75 倍などの伸ばした音 (`RubberBandPCMSource` / `StretchedPCMSource`) も、元の曲を読む部分がこの展開済みの曲 (`SongPCMSource`) になる (伸ばす計算そのものは従来どおり)
  - SETTING の「音源読込」の行に、どの方法で何 ms で展開したかが出る (「stb_vorbis で展開 (44100 Hz・2ch・350 ms)」など)
  - `GameAudio` の先読み・世代管理 (`warm` / `generation` / `idleQueued`) は、まだ残している。`AVAudioPlayerNode` に buffer を積む作りが同じなのと、伸ばした音 (Rubber Band) は作るのに時間が掛かるため。これらを無くすには、曲とキー音を 1 つのレンダーコールバックでミックスする作りに替える必要がある (音ズレに直結するので、まだやっていない)
- 譜面を触ったあとのキー音の表 (`keyTimes`) は、止まっている間の先読み (`scheduleWarm`) の中で作り直す。以前は再生開始の最初のフレームで作っていたので、ノーツが多い譜面で再生の出だしが引っ掛かっていた

## 再生速度 / 分割 (右下のボタン)
- ⏱ (再生速度): **1.0x / 0.75x / 0.5x / 0.25x / 0.1x** から選ぶ。数値入力はない (音が合うことを優先して、一覧の値だけにしている)
- ▤ (分割): 一覧の最後にある **入力…** で 1/2〜1/1024 を入力できる ("48" でも "1/48" でも可)。mc の `test.divide` にも保存される
  - 分割が細かいときは、レーンの横線は画面に収まる細かさまでしか描かない (吸着は入力した分割のまま)
- 再生は全部の速度でエンジン方式 (`GameAudio`)。エンジンを作れなかったときは、音なしの壁時計で進む
  - 1.0 倍: 曲をそのまま流す
  - 1.0 倍未満 (0.75 / 0.5 / 0.25 / 0.1): **自前の時間伸縮** (`StretchedPCMSource` / TimeStretch.swift) で伸ばした音を流す。音程は変えない
    - 以前の 0.5〜0.75 倍は AVAudioPlayer で鳴らしていたが、音が大きくズレたため、同じ方式にそろえた
    - 以前は `AVAudioUnitTimePitch` を使っていたが、その内部遅延は速度によって大きく変わり、正しく補正できなかった (0.5倍未満で曲と譜面が大きくズレる原因)
    - 今は、速度に伸ばした音そのものをデコード時に作って、ふつうの速度の PCM として player → mixer に直結で流す。
      出力 n フレーム目 = 元の曲の (開始位置 + n × 速度) フレーム付近、と作り方で決まっているので、遅延の見積もりが要らない
    - 時計は速度 1.0 と同じ仕組み (`refreshAnchor` が実際に鳴っているサンプル位置で毎フレーム合わせ直す。経過時間 × 速度 が曲の進み)
    - 方式はフェーズボコーダー (窓 1024、位相ロックつき)。音の重心は曲と同じ位置に来る。ドラムなど鋭い音の立ち上がりは少しにじむ (実測: 3ms のクリックで、0.25倍は前後 約15〜20ms、0.1倍は前 約50ms・後 約70ms。いずれも「伸ばした後の時間」での幅)
    - **音が途切れる問題 (0.5倍未満で同じところを細切れに鳴らす)** への対策: 伸ばした音は再生に間に合う速さで作り続ける必要がある。
      以前の実装は、最適化なしのビルドだと実時間の約2倍の速さでしか作れず、少し忙しくなっただけで間に合わなくなっていた。
      今は FFT を Float + ポインタに書き直し、左右を 1 本の複素 FFT にまとめて (FFT は 1 ホップ 2 回)、作業領域を使い回すことで、同じ音を最適化なしでも約 40 倍の速さで作れる (音は以前と同じ。対数スペクトル距離 0.01dB)。
      あわせて、伸ばした音は先に作っておく量を 10 個 → 24 個 (約 4.5 秒ぶん) に増やした (`GameAudio.stretchedQueued`)。
    - SETTING の下のチェックボックス (保存される。次の再生から反映):
      - **立ち上がりをはっきりさせる**: 伸ばす窓を 1024 → 512 にする (`GameAudio.setStretchSize`)。実測でにじみがほぼ半分 (0.1倍: 前46ms・後74ms → 前26ms・後36ms、0.25倍: 前22ms・後17ms → 前9ms・後15ms)。代わりに 60Hz 付近の低音の振幅が ±14% ゆらぐ (100Hz 以上は変わらない)
    - **再生ボタンの反応**: 停止中は、位置が止まって 0.04 秒たつと、その位置の音を先に用意する (`EditorState.scheduleWarm` → `GameAudio.warm`)。
      用意するのは最初の数個 (`idleQueued` = 4) だけにして、再生が始まってから目標 (伸ばした音は 24 個) まで増やす。
      以前は用意のたびに 24 個ぶんを作り続けて (最適化なしのビルドで約 1 秒)、その間 CPU を使っていた
    - 診断: 再生を止めると、SETTING の下の表示に「先読みの残り最小 x/24」が出る。x が 0〜2 なら作成が再生に間に合っていない。10 以上なら十分余裕がある
    - 音が合わないと感じたら: `GameAudio.begin` の `latency` (出力遅延) と、`StretchedPCMSource` の窓の大きさ (`fftSize`。小さいほど立ち上がりがはっきりするが音は粗くなる) を見る
