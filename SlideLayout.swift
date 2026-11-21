// スライドモードの画面の幾何 (UIKit に依存しない計算だけ)。
//
// 本家の画面は、レイアウトスクリプト (slide-play.txt) の @apply 3d / @angle 45 で「フィールド全体が手前に倒れた台形」に見える。
// 本家のカメラの数式は分からないので、本家の画面収録 (1920×1334) から次の値を測って当てはめている (§10.0 の補足):
//   ・判定線 (平面の Y = 0) は画面の高さの 0.886 の位置
//   ・フィールドの上端 (平面の Y = 1080) は画面のすぐ上 (高さの −0.030)
//   ・左右の縁は、画面の高さの −0.369 の位置 (消失点) で 1 点に集まる
//   ・判定線での縁の半幅は画面の幅の 0.5135 倍 (縁は画面の外に少しはみ出す)
// 平面は「幅 fw = 1080 × 画面の幅 / 高さ、高さ 1080」の単位の板 (スクリプトの @unit 1080 と同じ)。

import Foundation

struct SlidePoint { var x: Double; var y: Double }

struct SlidePlane {
    // 実測値 (画面の高さ H を 1 としたとき)
    static let judgeY = 0.886                 // 判定線 (Y = 0) の画面 y
    static let vanishY = -0.3688              // 消失点の画面 y
    static let invGap0 = 0.7969               // 1 / (y − vanishY) = invGap0 + invGapSlope × Y
    static let invGapSlope = 0.001998
    static let halfWidthAtJudge = 0.5135      // 判定線での縁の半幅 / 画面の幅

    static let planeHeight = 1080.0           // 平面の高さ (単位)
    static let windowP = 632.5                // P 空間での窓の高さ (§10.0)
    static let tiltScale = 0.7                // 3D 傾斜のときの表示スケール (§10.0)

    let width: Double                         // 画面の幅 (pt)
    let height: Double                        // 画面の高さ (pt)

    /// 平面の幅 (単位)
    var fieldWidth: Double { SlidePlane.planeHeight * width / height }
    /// 1 単位あたりの pt (フラットな部品。HUD など)
    var unit: Double { height / SlidePlane.planeHeight }

    // 横方向: x = W/2 + (X − fw/2) × kx × H / D(Y)
    private var kx: Double { 2 * SlidePlane.halfWidthAtJudge * SlidePlane.invGap0 / SlidePlane.planeHeight }

    private func d(_ Y: Double) -> Double { SlidePlane.invGap0 + SlidePlane.invGapSlope * Y }

    /// 平面の点 (X, Y。Y は判定線から上向き) → 画面の点 (pt)
    func screen(_ X: Double, _ Y: Double) -> SlidePoint {
        let dd = d(Y)
        let y = height * (SlidePlane.vanishY + 1 / dd)
        let x = width / 2 + (X - fieldWidth / 2) * kx * height / dd
        return SlidePoint(x: x, y: y)
    }

    /// 平面の 1 単位の、その高さでの画面上の大きさ (横方向。pt)
    func horizontalScale(atY Y: Double) -> Double { kx * height / d(Y) }

    /// CALayer 用の 4×4 行列 (行ベクトル形式: [x y z w] × M)。
    /// レイヤーの座標は (lx, ly) = (X, 1080 − Y) (UIKit と同じ「上が 0、下向きが +」)。原点は平面の左上
    var layerMatrix: [Double] {
        let H = height, W = width
        let m = SlidePlane.invGapSlope
        let g0 = SlidePlane.invGap0 + SlidePlane.planeHeight * m      // ly = 0 (Y = 1080) での D
        let kxH = kx * H
        let vy = SlidePlane.vanishY
        // w = g0 − m·ly
        // x·w = kxH·(lx − fw/2) + W/2·w
        // y·w = H·(vy·w + 1)
        let m11 = kxH
        let m21 = -(W / 2) * m
        let m41 = (W / 2) * g0 - kxH * fieldWidth / 2
        let m12 = 0.0
        let m22 = -H * vy * m
        let m42 = H * (vy * g0 + 1)
        let m14 = 0.0
        let m24 = -m
        let m44 = g0
        // 配列は m11 m12 m13 m14 / m21 m22 m23 m24 / m31 m32 m33 m34 / m41 m42 m43 m44
        return [m11, m12, 0, m14,
                m21, m22, 0, m24,
                0,   0,   1, 0,
                m41, m42, 0, m44]
    }

    /// レイヤー座標 (lx, ly) → 画面 (行列で計算したもの。screen() と一致するはず)
    func screenFromLayer(_ lx: Double, _ ly: Double) -> SlidePoint {
        let a = layerMatrix
        let x = lx * a[0] + ly * a[4] + a[12]
        let y = lx * a[1] + ly * a[5] + a[13]
        let w = lx * a[3] + ly * a[7] + a[15]
        return SlidePoint(x: x / w, y: y / w)
    }
}

// MARK: - スクロール速度

enum SlideScroll {
    /// ユーザー速度 n (整数。−20...20) → 速度係数 (§10.1: exp(n × 0.05) × 表示スケール 1.0 × 3D の 0.7)
    static func speedFactor(n: Int) -> Double { exp(Double(n) * 0.05) * SlidePlane.tiltScale }
    /// P 1 単位あたりの平面の長さ (単位)。窓 (632.5 / 速度係数) がちょうど平面の高さ 1080 に当たる
    static func planeUnitsPerP(n: Int) -> Double { speedFactor(n: n) * SlidePlane.planeHeight / SlidePlane.windowP }
    /// P の距離がこの値以下のノーツから、スプライトを作る (§10.1)
    static func spawnDistance(n: Int) -> Double { SlidePlane.windowP / speedFactor(n: n) }
}

// MARK: - 数字の並べ方 (HUD)
// 画面収録の測定 (1334 高): 数字は等間隔に並び、各字は自分の枠の中央に置かれる。
//   score / acc (font-number): 字の大きさ 0.27 単位/px、間隔 16.8 単位
//   combo (font-combo)       : 字の大きさ 0.314 単位/px、間隔 55.8 単位

enum SlideHUD {
    struct Font {
        var glyphScale: Double      // 元の画像 1px あたりの単位
        var pitch: Double           // 字の中心から次の字の中心まで (単位)
    }
    static let number = Font(glyphScale: 0.27, pitch: 16.8)
    static let combo = Font(glyphScale: 0.314, pitch: 55.8)

    // 位置 (上端からの距離。単位)
    static let scoreY = 100.0
    static let comboY = 138.0
    static let accY = 178.0

    // 文字コード → font-number の番号 (0-9 = 数字, 10 = "%", 11 = ".", 12 = "-")
    static func glyphIndex(_ ch: Character) -> Int? {
        switch ch {
        case "0"..."9": return Int(String(ch))
        case "%": return 10
        case ".": return 11
        case "-": return 12
        default: return nil
        }
    }

    /// 表示する文字列 → 字の番号の列
    static func indices(_ text: String) -> [Int] { text.compactMap { glyphIndex($0) } }

    /// 文字列の i 番目の字の中心 x (中央揃え。中心 x = 0 からの距離。単位)
    static func glyphCenterX(index i: Int, count n: Int, font: Font) -> Double {
        (Double(i) - Double(n - 1) / 2) * font.pitch
    }
}

// MARK: - 判定文字

enum SlideJudgeText {
    /// ui-play-score の番号 (0 = BEST 赤, 1 = COOL 黄, 2 = GOOD 緑, 3 = MISS 灰)
    static func frame(grade: Int) -> Int {
        switch grade {
        case 2: return 0
        case 4: return 1
        case 8: return 2
        default: return 3
        }
    }
    static let size = (w: 575.0, h: 150.0)      // 単位。平面の (中央, Y = 100)
    static let centerY = 100.0
}

// MARK: - ヒット光

enum SlideHitLight {
    static let size2 = (w: 900.0, h: 600.0)     // light2 (横に流れる光)。単位
    static let size = (w: 900.0, h: 900.0)      // light (六角形)。単位
    /// 画面収録の測定: 六角形の見た目は 900 単位 × 0.53 (位置は判定線の画面位置)
    static let visualScale = 0.53
    static let frameMs2 = 24.0                  // light2 の 1 枚あたり (ms)
    static let frameMs = 16.67                  // light の 1 枚あたり (ms)
    static let count2 = 13                      // light2-0 ... 12
    static let count = 16                       // light-0 ... 15
    static let holdLoopFrom = 5                 // 保持中 (hit-3) は light-5 ... 15 をくり返す
}
