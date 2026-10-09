import SwiftUI

// 編集ツール: 配置 / 削除 / 範囲コピー / 反転 / Slide<->Wipe / BPM / seg 編集

extension EditorState {

    // MARK: - スナップ

    func snapBeat(_ v: Double) -> Beat {
        Beat.nearest(max(0, v), den: snapDen)
    }

    /// 中心x(0...255)と幅から、保存用の (x, w) を決める。
    /// グリッド有効時は「左端・右端」をグリッド線に合わせ、255 が割り切れない分は四捨五入で隙間/重なりを最小化する
    func snapNote(centerX: Double, widthUnits wu: Int) -> (x: Int, w: Int) {
        if gridAlign && gridLines >= 1 {
            let n = Double(gridLines)
            let cell = 255.0 / n
            let cells = min(gridLines, max(1, Int((Double(wu) / cell).rounded())))
            let exactW = cell * Double(cells)
            var k = Int(((centerX - exactW / 2.0) / cell).rounded())
            k = max(0, min(gridLines - cells, k))
            let eL = 255.0 * Double(k) / n
            let eR = 255.0 * Double(k + cells) / n
            return (Int(((eL + eR) / 2.0).rounded()), Int((eR - eL).rounded()))
        } else {
            let w = max(1, min(255, wu))
            var cx = Int(centerX.rounded())
            let half = w / 2
            cx = max(half, min(255 - half, cx))
            return (cx, w)
        }
    }

    var widthCells: Int {
        let cell = 255.0 / Double(max(1, gridLines))
        return min(gridLines, max(1, Int((Double(widthUnits) / cell).rounded())))
    }

    // MARK: - レーン操作 (編集モード)

    func laneDrag(start: CGPoint, current: CGPoint, size: CGSize, ended: Bool) {
        if isPlaying {
            if ended { showToast("再生中は編集できません。停止してから操作してください") }
            return
        }
        let g = geo(size)
        let moved = hypot(current.x - start.x, current.y - start.y) > 10

        switch tool {
        case .unselected, .lasso, .plugin:
            break                           // LASSO は laneTouch の .lasso (lassoTouch)、操作型プラグインは .plugin (pluginTouch) が処理する

        case .order:
            if ended && !moved { orderTap(at: current, g: g) }     // 「順番に選択」: タップしたスライドに番号を付ける

        case .note, .wipe:
            let b = snapBeat(g.beatOf(current.y))
            let p = snapNote(centerX: g.xOf(current.x), widthUnits: widthUnits)
            if ended {
                ghost = nil
                addNote(Note(beat: b, x: p.x, w: p.w, type: tool == .wipe ? 4 : nil))
            } else {
                ghost = Ghost(tool: tool, beat: b, x: p.x, w: p.w)
            }

        case .slide:
            // ドラッグは使わない。1点ずつ、指を離した位置に置く (指を置いている間は、置く位置をゴーストで見せる)
            //   作成中でないとき: 1回目のタップ = 始点
            //   作成中のとき    : タップするたびに seg を足す (時系列の順でなくてよい)。
            //                     始点より前 (beat がマイナス) は、SETTING の「beatがマイナスのsegを置くのを許可する」がオンのときだけ置ける。
            //                     オフのときは、始点より前をタップすると「完」と同じ (seg の配置を終える)
            let b = snapBeat(g.beatOf(current.y))
            if let base = slideDraftBase(), let from = slideDraftLastPoint() {
                let p = snapNote(centerX: g.xOf(current.x), widthUnits: base.w)
                if !allowNegativeSeg && b < base.beat {
                    ghost = nil
                    if ended { finishSlide() }
                } else if ended {
                    ghost = nil
                    appendDraftSeg(beat: b, x: p.x)
                } else {
                    ghost = Ghost(tool: .slide, beat: from.beat, x: from.x, w: base.w, endBeat: b, endX: p.x)
                }
            } else {
                let p = snapNote(centerX: g.xOf(current.x), widthUnits: widthUnits)
                if ended {
                    ghost = nil
                    slideDraft = SlideDraft(beat: b, x: p.x, w: p.w)
                    showToast("始点を置きました。続けて seg をタップしてください (終わるときは「完」)")
                } else {
                    ghost = Ghost(tool: .slide, beat: b, x: p.x, w: p.w)
                }
            }

        case .remove:
            if ended && !moved {
                if let i = hitNote(at: current, g: g) {
                    pushUndo()
                    chart.notes.remove(at: i)
                    chartChanged()
                }
            }

        case .selectRange:
            if ended && !moved {
                let b = snapBeat(g.beatOf(current.y))
                if rangeStart == nil || rangeEnd != nil {
                    rangeStart = b
                    rangeEnd = nil
                    selectedIDs = []
                    showToast("始点を設定しました。終点をタップしてください")
                } else if let s = rangeStart {
                    let lo = min(s, b)
                    let hi = max(s, b)
                    rangeStart = lo
                    rangeEnd = hi
                    selectNotes(lo: lo, hi: hi)
                }
            }

        case .slideModify:
            // 点 (seg) のドラッグは beginTouch で .segDrag になるので、ここに来るのはタップだけ
            if ended && !moved {
                slideModifyTap(at: current, g: g)
            }
        }
    }

    // MARK: - レーン操作: 選択 / 移動 (Note・Wipe・Slide ツール選択中)

    /// 編集ツールを選んでいるとき、レーンに触れている間 LaneView から呼ばれる。
    /// - Note/Wipe/Slide: ノーツに触れたら選択(赤)。選択中のノーツに触れて動かすと、選択中の全ノーツが縦横に移動する。
    ///   ノーツの無い所に触れたら選択解除 (そのタッチでは配置しない)。何も選択していなければ従来どおり配置。
    /// - Remove / Select range / Slide modify: 従来どおり (laneDrag)
    func laneTouch(start: CGPoint, current: CGPoint, size: CGSize, phase: LanePhase) {
        let g = geo(size)

        if phase == .began {
            if dragMode == .moving { finishMove() }      // 前のタッチが途中で途切れていた場合の保険
            if dragMode == .segDrag { finishSegDrag() }
            resetDragState()
            if isPlaying {
                dragMode = .ignore
            } else {
                beginTouch(at: start, g: g)
            }
        }
        if dragMode == .idle { return }

        if hypot(current.x - start.x, current.y - start.y) > 10 { dragMoved = true }

        if dragMode == .pendingMove && dragMoved {
            beginMove()
        }

        switch dragMode {
        case .moving:
            applyMove(start: start, current: current, g: g)
            if phase == .ended { finishMove() }
        case .pendingMove:
            // 動かさずに離した: 選択中のノーツだったなら、そのノーツだけ選択から外す
            if phase == .ended && dragToggleOnTap && !dragMoved, let id = dragTouchedID {
                selectedIDs.remove(id)
            }
        case .segDrag:
            if dragMoved { dragSeg(current: current, g: g) }
            if phase == .ended { finishSegDrag() }
        case .lasso:
            lassoTouch(current: current, g: g, ended: phase == .ended)
        case .plugin:
            pluginTouch(start: start, current: current, g: g, phase: phase)
        case .place, .legacy:
            laneDrag(start: start, current: current, size: size, ended: phase == .ended)
        case .idle, .ignore:
            if phase == .ended && isPlaying { showToast("再生中は編集できません。停止してから操作してください") }
        }

        if phase == .ended { resetDragState() }
    }

    private func resetDragState() {
        dragMode = .idle
        dragMoved = false
        dragTouchedID = nil
        dragToggleOnTap = false
        moveTargets = []
    }

    /// 指を置いた瞬間に、そのタッチが何をするのか決める
    private func beginTouch(at p: CGPoint, g: LaneGeo) {
        switch tool {
        case .note, .wipe, .slide:
            if tool == .slide && slideDraft != nil {
                dragMode = .place                   // スライド作成中は、どこをタップしても seg を置く (ノーツの選択・移動はしない)
            } else if let i = hitNote(at: p, g: g) {
                let id = chart.notes[i].id
                dragTouchedID = id
                if selectedIDs.contains(id) {
                    dragToggleOnTap = true          // 動かさず離したら、このノーツの選択を外す
                } else {
                    selectedIDs.insert(id)          // 触れたノーツを選択に追加 (そのまま動かすこともできる)
                    dragToggleOnTap = false
                }
                dragMode = .pendingMove
            } else if !selectedIDs.isEmpty {
                selectedIDs = []                    // ノーツの無い所に触れたら選択解除 (配置はしない)
                dragMode = .ignore
            } else {
                dragMode = .place
            }
        case .slideModify:
            // 編集中のスライドの点 (seg) に触れたら、その点を動かす。それ以外はタップ (別のスライドを選ぶ / seg を追加)
            if let r = segDeleteRect(g: g), r.contains(p) {
                dragMode = .legacy                  // 「削除」ボタン (離したときに slideModifyTap が消す)
            } else if let id = modifySlideID,
               let i = chart.notes.firstIndex(where: { $0.id == id }),
               let j = hitSeg(note: i, at: p, g: g) {
                let n = chart.notes[i]
                let s = n.segs[j]
                modifySegIndex = j                  // 触れた点を選ぶ (動かさず離せば、隣に「削除」が出たまま)
                segDragNoteID = id
                segDragIndex = j
                segDragOrig = s
                // 点の中心と指のずれを保つ (点が指の下に隠れても、触った瞬間に飛ばないように)
                segDragGrab = CGSize(width: g.px(Double(n.x + s.x)) - p.x,
                                     height: g.py(n.beat.value + s.beat.value) - p.y)
                segDragUndoPushed = false
                dragMode = .segDrag
            } else {
                dragMode = .legacy
            }
        case .lasso:
            lassoPoints = [p]                       // なぞり始め。ここから指を離すまでの線で範囲を囲む
            dragMode = .lasso
        case .remove, .selectRange, .order:
            dragMode = .legacy
        case .plugin:
            dragMode = .plugin
            pluginDragStarted = false
        case .unselected:
            dragMode = .ignore
        }
    }

    /// 10pt 以上動かした時点で、移動を開始する (Undo は1回の移動につき1回分)
    private func beginMove() {
        var targets: [(index: Int, orig: Note)] = []
        for i in chart.notes.indices where selectedIDs.contains(chart.notes[i].id) {
            targets.append((index: i, orig: chart.notes[i]))
        }
        guard let first = targets.first else {
            dragMode = .ignore
            return
        }
        var anchor = first.orig.beat
        if let id = dragTouchedID, let t = targets.first(where: { $0.orig.id == id }) {
            anchor = t.orig.beat
        }
        var minBeat = first.orig.beat
        var left = 255.0
        var right = 0.0
        for t in targets {
            let n = t.orig
            if n.beat < minBeat { minBeat = n.beat }
            for s in n.segs {
                let sb = n.beat + s.beat                    // seg は始点より前 (マイナス側) にもある
                if sb < minBeat { minBeat = sb }
            }
            var minX = n.x
            var maxX = n.x
            for s in n.segs {
                let sx = n.x + s.x
                minX = min(minX, sx)
                maxX = max(maxX, sx)
            }
            left = min(left, Double(minX) - Double(n.w) / 2.0)
            right = max(right, Double(maxX) + Double(n.w) / 2.0)
        }
        moveTargets = targets
        moveAnchorBeat = anchor
        moveMinBeat = minBeat
        moveLeftEdge = left
        moveRightEdge = right
        moveLastDelta = .zero
        moveLastDX = 0
        pushUndo()
        dragMode = .moving
    }

    /// 移動前の位置を基準に、指の移動量ぶんだけ動かす。
    /// 縦: 触れたノーツがスナップ(1/n拍)に乗るよう移動量を決め、選択中の全ノーツを同じ量だけ動かす (ノーツ同士の相対位置は保つ)。
    /// 横: グリッド有効時はグリッド1マス単位。全体が x:0...255 から出ないように止める。
    private func applyMove(start: CGPoint, current: CGPoint, g: LaneGeo) {
        // 対象のノーツが入れ替わっていたら (別の指で Undo された等) 中止する
        for t in moveTargets {
            if t.index >= chart.notes.count || chart.notes[t.index].id != t.orig.id {
                dragMode = .ignore
                moveTargets = []
                return
            }
        }

        let rawBeats = Double(start.y - current.y) / g.ppb          // 上へ動かすほど後ろの拍
        var delta = snapBeat(moveAnchorBeat.value + rawBeats) - moveAnchorBeat
        if !(moveMinBeat < Beat.zero) && (moveMinBeat + delta) < Beat.zero {
            delta = Beat.zero - moveMinBeat                           // 0拍より前へは行かせない
        }

        let rawX = g.xOf(current.x) - g.xOf(start.x)
        var dx = snapDeltaX(rawX)
        let minDX = min(0, Int(ceil(-moveLeftEdge)))
        let maxDX = max(0, Int(floor(255.0 - moveRightEdge)))
        dx = max(minDX, min(maxDX, dx))

        if delta == moveLastDelta && dx == moveLastDX { return }
        moveLastDelta = delta
        moveLastDX = dx
        for t in moveTargets {
            chart.notes[t.index].beat = t.orig.beat + delta
            chart.notes[t.index].x = t.orig.x + dx
        }
    }

    private func snapDeltaX(_ raw: Double) -> Int {
        if gridAlign && gridLines >= 1 {
            let cell = 255.0 / Double(gridLines)
            return Int(((raw / cell).rounded() * cell).rounded())
        }
        return Int(raw.rounded())
    }

    private func finishMove() {
        let changed = !(moveLastDelta == .zero && moveLastDX == 0)
        moveTargets = []
        if changed {
            chartChanged()
        } else {
            dropLastUndo()                  // 元の位置に戻して離した → 何も変わっていないので Undo も積まない
        }
    }

    // MARK: - 幅スライダー → 選択中のノーツの幅

    /// 幅スライダーに指を置いた瞬間。選択中のノーツがあれば、その幅を変える準備をする
    func widthSliderBegan() {
        widthSliderEnded()                  // 前回が取り消されて終わっていなければ、ここで締める
        if isPlaying || selectedIDs.isEmpty { return }
        for i in chart.notes.indices where selectedIDs.contains(chart.notes[i].id) {
            widthTargets.append((index: i, orig: chart.notes[i]))
        }
    }

    /// 幅スライダーの値が変わったとき。選択中のノーツがあれば、その幅も同じ値にする
    func widthSliderMoved(_ v: Int) {
        widthUnits = v
        if widthTargets.isEmpty { return }
        // 対象のノーツが入れ替わっていたら (別の指で Undo された等) 中止する
        for t in widthTargets {
            if t.index >= chart.notes.count || chart.notes[t.index].id != t.orig.id {
                widthTargets = []
                widthUndoPushed = false
                return
            }
        }
        if !widthUndoPushed {
            pushUndo()                      // 変える前の状態を積む (指を離すまでの操作が Undo 1回分)
            widthUndoPushed = true
        }
        for t in widthTargets {
            chart.notes[t.index] = resized(t.orig, widthUnits: v)
        }
    }

    /// 幅スライダーから指を離した瞬間 (何度呼んでも安全)
    func widthSliderEnded() {
        if widthUndoPushed {
            var changed = false
            for t in widthTargets where t.index < chart.notes.count {
                let n = chart.notes[t.index]
                if n.x != t.orig.x || n.w != t.orig.w { changed = true }
            }
            if changed {
                chartChanged()
            } else {
                dropLastUndo()              // 結局何も変わらなかった → Undo も積まない
            }
        }
        widthTargets = []
        widthUndoPushed = false
    }

    /// ノーツの幅を wu にしたノーツを返す (元のノーツは変えない)。
    /// **位置 (x) と seg は一切動かさない**。幅だけを変える。
    /// 左右の端が x:0...255 の枠からはみ出してもよい (譜面の表現としてよくある)。制限があるのは「中心が 0...255 の外に出ない」ことだけで、
    /// 幅を変えても中心は動かないので、ここでは何も止めない
    private func resized(_ orig: Note, widthUnits wu: Int) -> Note {
        var n = orig
        n.w = snapWidth(wu)
        return n
    }

    /// 幅だけを決める (位置は決めない)。グリッド有効時は、snapNote と同じく 1マスの整数倍に丸める
    func snapWidth(_ wu: Int) -> Int {
        if gridAlign && gridLines >= 1 {
            let cell = 255.0 / Double(gridLines)
            let cells = min(gridLines, max(1, Int((Double(wu) / cell).rounded())))
            return max(1, Int((cell * Double(cells)).rounded()))
        }
        return max(1, min(255, wu))
    }

    func toggleTool(_ t: EditTool) {
        tool = (tool == t) ? .unselected : t
    }

    /// EDIT の Remove ボタン。
    /// 選択中のノーツ (赤いノーツ) があれば、それをまとめて削除する (ツールは今のまま。Time range で範囲を選んでから消せる)。
    /// 何も選択していなければ、従来どおり Remove ツール (タップで1個ずつ消す) の ON/OFF
    func removeButtonTapped() {
        if selectedIDs.isEmpty {
            toggleTool(.remove)
        } else {
            removeSelected()
        }
    }

    func removeSelected() {
        if isPlaying {
            showToast("再生中は編集できません。停止してから操作してください")
            return
        }
        let ids = selectedIDs
        let before = chart.notes.count
        if !chart.notes.contains(where: { ids.contains($0.id) }) {
            selectedIDs = []
            return
        }
        pushUndo()                                      // 1回の削除が Undo 1回分
        chart.notes.removeAll(where: { ids.contains($0.id) })
        let removed = before - chart.notes.count
        selectedIDs = []
        chartChanged()
        showToast("ノーツを \(removed) 個削除しました")
    }

    // MARK: - LASSO (なぞって囲んだ範囲のノーツを選択)

    /// LASSO ツールでレーンに触れている間の処理 (laneTouch から呼ばれる)。
    /// - なぞっている間: 指の軌跡を lassoPoints に溜める (Renderers.drawLasso が点線で描く)
    /// - 指を離したとき: 始点と終点を直線で結んで閉じ、中にあるノーツを **今の選択に追加** する
    ///   (レーンは LASSO 中は上下スライドできないので、帯・シークバーで動かしながら何回かに分けて囲める)
    /// - 10pt 以上動かさずに離した (タップ): ノーツの上なら、そのノーツの選択 ON/OFF。何も無い所なら全部の選択を解除
    func lassoTouch(current: CGPoint, g: LaneGeo, ended: Bool) {
        if !ended {
            if let last = lassoPoints.last, hypot(current.x - last.x, current.y - last.y) < 2 { return }
            lassoPoints.append(current)           // 2pt 未満の動きは捨てて、点が増えすぎないようにする
            return
        }
        let poly = lassoPoints
        lassoPoints = []
        if !dragMoved {
            lassoTap(at: current, g: g)
        } else {
            selectInLasso(poly, g: g)
        }
    }

    private func lassoTap(at p: CGPoint, g: LaneGeo) {
        if let i = hitNote(at: p, g: g) {
            let id = chart.notes[i].id
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        } else if !selectedIDs.isEmpty {
            selectedIDs = []
        }
    }

    /// 囲んだ線 (画面座標) の中にあるノーツを、今の選択に追加する。
    /// 「中にある」の判定: タップ / ウィップは中心の点、スライドは始点か seg の点のどれかが中に入っていること。
    /// (スライド全体が選択される。リボンが線をまたいでいるだけでは選ばない)
    func selectInLasso(_ poly: [CGPoint], g: LaneGeo) {
        if poly.count < 3 {
            showToast("範囲内にノーツがありません")
            return
        }
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for q in poly {
            minX = min(minX, q.x); maxX = max(maxX, q.x)
            minY = min(minY, q.y); maxY = max(maxY, q.y)
        }
        let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        func inside(_ q: CGPoint) -> Bool {
            box.contains(q) && Self.windingContains(q, poly)     // 外接する四角で先にふるい落とす (点が多い譜面でも軽い)
        }

        var ids = selectedIDs
        var found = 0
        var added = 0
        for n in chart.notes {
            // タップ / ウィップは、描かれている棒の真ん中 (拍の線より barLift 上) で判定する。スライドは始点の点の位置
            let yHead = g.py(n.beat.value) - (n.isSlide ? 0 : LaneRenderer.barLift)
            var hit = inside(CGPoint(x: g.px(Double(n.x)), y: yHead))
            if !hit {
                for s in n.segs where inside(CGPoint(x: g.px(Double(n.x + s.x)), y: g.py(n.beat.value + s.beat.value))) {
                    hit = true
                    break
                }
            }
            if !hit { continue }
            found += 1
            if ids.insert(n.id).inserted { added += 1 }
        }
        selectedIDs = ids
        if found == 0 {
            showToast("範囲内にノーツがありません")
        } else if added == 0 {
            showToast("範囲内のノーツはすべて選択済みです")
        } else {
            showToast("\(added) 個のノーツを選択に追加しました (選択中 \(ids.count) 個)")
        }
    }

    /// 点 p が多角形の内側か (巻き数が 0 でなければ内側)。
    /// 線が自分と交差しても (始点を少し行き過ぎて閉じた場合など)、囲んだ所はちゃんと内側になる
    static func windingContains(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        var wn = 0
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[j]
            let b = poly[i]
            let cross = (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y)
            if a.y <= p.y {
                if b.y > p.y && cross > 0 { wn += 1 }
            } else if b.y <= p.y && cross < 0 {
                wn -= 1
            }
            j = i
        }
        return wn != 0
    }

    // MARK: - 長押しで選択解除 (ツール未選択のとき)

    /// ツール未選択のレーンに指を置いた瞬間に LaneView から呼ばれる。
    /// 選択中のノーツがあるときだけ、`holdDeselectSec` 秒後に選択を全部解除するタイマーを始める。
    /// 指が 10pt を超えて動いた / 離れた / ピンチが始まったときは `holdCancel` で取り消される (LaneView 側)
    func holdBegan() {
        holdCancel()
        if selectedIDs.isEmpty { return }
        let w = DispatchWorkItem { [weak self] in
            self?.holdWork = nil
            self?.holdFired()
        }
        holdWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDeselectSec, execute: w)
    }

    func holdCancel() {
        holdWork?.cancel()
        holdWork = nil
    }

    private func holdFired() {
        // 押している間にツールを選んだ / 選択が無くなったときは何もしない
        guard !laneToolActive, !selectedIDs.isEmpty else { return }
        selectedIDs = []
        showToast("選択を解除しました")
    }

    /// レーンで編集ツール(配置/選択/削除など)を使う状態か。false のときは、上下スライドとピンチだけ
    var laneToolActive: Bool { editing && tool != .unselected }

    // MARK: - 追加 / 削除

    func addNote(_ n: Note) {
        if n.beat.value < 0 { return }
        for e in chart.notes {
            if e.beat == n.beat && e.x == n.x && e.w == n.w && e.type == n.type && e.segs.isEmpty && n.segs.isEmpty {
                return
            }
        }
        pushUndo()
        chart.notes.append(n)
        chartChanged()
    }

    func hitNote(at p: CGPoint, g: LaneGeo) -> Int? {
        for i in chart.notes.indices.reversed() where noteHit(chart.notes[i], at: p, g: g) {
            return i
        }
        return nil
    }

    /// 1つのノーツ (スライドはリボン・点を含む) の当たり判定
    func noteHit(_ n: Note, at p: CGPoint, g: LaneGeo) -> Bool {
        let y0 = g.py(n.beat.value)
        let cx = g.px(Double(n.x))
        let hw = CGFloat(n.w) / 255.0 * g.trackW / 2.0
        // タップ / ウィップの棒は、拍の線より barLift だけ上に描かれる (LaneRenderer.barLift)。当たり判定も棒に合わせる。
        // スライドの始点には棒が無いので、点の位置 (拍の線の上) のまま
        let yBar = n.isSlide ? y0 : y0 - LaneRenderer.barLift
        if abs(p.y - yBar) <= 14 && abs(p.x - cx) <= hw + 6 { return true }
        if n.isSlide {
            var pts: [CGPoint] = [CGPoint(x: cx, y: y0)]
            for s in n.segs {
                pts.append(CGPoint(x: g.px(Double(n.x + s.x)), y: g.py(n.beat.value + s.beat.value)))
            }
            for k in 0..<(pts.count - 1) {
                let a = pts[k]
                let b = pts[k + 1]
                let poly = [
                    CGPoint(x: a.x - hw, y: a.y), CGPoint(x: a.x + hw, y: a.y),
                    CGPoint(x: b.x + hw, y: b.y), CGPoint(x: b.x - hw, y: b.y)
                ]
                if Self.pointInPolygon(p, poly) { return true }
            }
            for q in pts where hypot(q.x - p.x, q.y - p.y) < 16 { return true }
        }
        return false
    }

    static func pointInPolygon(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i]
            let b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let t = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                if p.x < t { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    // MARK: - 選択 / コピー / ペースト / 反転 / 変換
    // Copy・Flip・Slide to Wipe・Wipe to Slide はすべて「選択状態のノーツ (selectedIDs)」が対象。
    // 選択は、ノーツに触れる (Note / Wipe / Slide ツール) か、Time range で作る。

    /// 選択中のノーツの添字 (譜面上の並び順)
    private func selectedIndices() -> [Int] {
        if selectedIDs.isEmpty { return [] }
        return chart.notes.indices.filter { selectedIDs.contains(chart.notes[$0].id) }
    }

    /// Time range: 始点〜終点の拍 (両端を含む) にあるノーツを選択状態にする (ノーツの先頭の拍で判定)
    func selectNotes(lo: Beat, hi: Beat) {
        var ids = Set<UUID>()
        for n in chart.notes where n.beat >= lo && n.beat <= hi {
            ids.insert(n.id)
        }
        selectedIDs = ids
        showToast(ids.isEmpty ? "範囲内にノーツがありません" : "\(ids.count) 個のノーツを選択しました")
    }

    /// Time range ツールを始める (始点 → 終点の順にレーンをタップ)
    func beginSelectRange() {
        editing = true
        tool = .selectRange
        rangeStart = nil
        rangeEnd = nil
        showToast("範囲の始点の拍をタップしてください")
    }

    /// Copy: 選択中のノーツを保存する。いちばん前のノーツの拍を 0 とした相対位置で持つ
    func copySelection() {
        let idx = selectedIndices()
        if idx.isEmpty {
            showToast("コピーするノーツが選択されていません")
            return
        }
        var base = chart.notes[idx[0]].beat
        for i in idx where chart.notes[i].beat < base {
            base = chart.notes[i].beat
        }
        var list: [Note] = []
        for i in idx {
            var m = chart.notes[i]
            m.beat = m.beat - base
            list.append(m)
        }
        clip = list
        showToast("\(list.count) 個のノーツをコピーしました")
    }

    /// Paste: 保存したノーツを、表示中の位置 (再生ライン) にいちばん前のノーツが来るように貼り付ける。
    /// 貼り付けたノーツは選択状態になるので、そのまま触って動かせる
    func paste() {
        if clip.isEmpty {
            showToast("コピーされたノーツがありません")
            return
        }
        let base = snapBeat(currentBeat())
        pushUndo()
        var pasted = Set<UUID>()
        for n in clip {
            var m = n
            m.beat = base + n.beat
            m.id = UUID()          // 元のノーツと同じ id にならないように付け直す
            pasted.insert(m.id)
            chart.notes.append(m)
        }
        selectedIDs = pasted
        chartChanged()
        showToast("\(clip.count) 個を貼り付けました")
    }

    /// x=127 を中心に左右反転 (x' = 254 - x、seg の相対x は符号反転)。選択が無いときは全ノーツ
    func flipHorizontal() {
        var targets = selectedIndices()
        if targets.isEmpty {
            targets = Array(chart.notes.indices)
            showToast("ノーツが選択されていないため、全ノーツを反転しました")
        }
        if targets.isEmpty { return }
        pushUndo()
        for i in targets {
            chart.notes[i].x = 254 - chart.notes[i].x
            for j in chart.notes[i].segs.indices {
                chart.notes[i].segs[j].x = -chart.notes[i].segs[j].x
            }
        }
        chartChanged()
    }

    /// 選択中のスライドを Wipe に変換する (変換後の Wipe は選択状態)
    func slideToWipe() {
        let r = selectedIndices()
        if r.isEmpty {
            showToast("先にノーツを選択してください (Time range で範囲選択もできます)")
            return
        }
        let slides = r.filter { chart.notes[$0].isSlide }
        if slides.isEmpty {
            showToast("選択中のノーツにスライドがありません")
            return
        }
        pushUndo()
        var created: [Note] = []
        for i in slides {
            let n = chart.notes[i]
            created.append(Note(beat: n.beat, x: n.x, w: n.w, type: 4))
            for s in n.segs {
                created.append(Note(beat: n.beat + s.beat, x: max(0, min(255, n.x + s.x)), w: n.w, type: 4))
            }
        }
        for i in slides.sorted(by: >) { chart.notes.remove(at: i) }
        chart.notes.append(contentsOf: created)
        for n in created { selectedIDs.insert(n.id) }      // 消えたスライドの分は chartChanged の中で選択から外れる
        chartChanged()
        showToast("\(slides.count) 個のスライドをWipeに変換しました")
    }

    /// 選択中の Wipe を、時間順に1本のスライドにつなぐ (変換後のスライドは選択状態)
    func wipeToSlide() {
        let r = selectedIndices()
        if r.isEmpty {
            showToast("先にノーツを選択してください (Time range で範囲選択もできます)")
            return
        }
        let wipes = r.filter { chart.notes[$0].isWipe && !chart.notes[$0].isSlide }
        if wipes.count < 2 {
            showToast("選択中のWipeが2個以上必要です")
            return
        }
        let sorted = wipes.sorted { chart.notes[$0].beat < chart.notes[$1].beat }
        let first = chart.notes[sorted[0]]
        var segs: [Seg] = []
        for i in sorted.dropFirst() {
            let n = chart.notes[i]
            segs.append(Seg(beat: n.beat - first.beat, x: n.x - first.x))
        }
        pushUndo()
        let slide = Note(beat: first.beat, x: first.x, w: first.w, type: nil, segs: segs)
        for i in wipes.sorted(by: >) { chart.notes.remove(at: i) }
        chart.notes.append(slide)
        selectedIDs.insert(slide.id)                       // 消えたWipeの分は chartChanged の中で選択から外れる
        chartChanged()
        showToast("Wipe \(wipes.count) 個を1本のスライドにしました")
    }

    // MARK: - スライド作成 (Slide ツール。タップだけで作る)

    /// 作成中のスライドが、譜面に入っている位置 (最初の seg を置く前は nil)
    private func slideDraftIndex() -> Int? {
        guard let d = slideDraft else { return nil }
        return chart.notes.firstIndex(where: { $0.id == d.noteID })
    }

    /// 作成中のスライドの始点 (絶対位置) と幅。作成中でなければ nil
    func slideDraftBase() -> (beat: Beat, x: Int, w: Int)? {
        guard let d = slideDraft else { return nil }
        if let i = slideDraftIndex() {
            let n = chart.notes[i]
            return (n.beat, n.x, n.w)
        }
        return (d.beat, d.x, d.w)
    }

    /// 作成中のスライドの「いちばん最後に置いた点」(絶対位置)。seg がまだ無ければ始点
    func slideDraftLastPoint() -> (beat: Beat, x: Int)? {
        guard let base = slideDraftBase() else { return nil }
        if let i = slideDraftIndex(), let last = chart.notes[i].segs.last {
            return (base.beat + last.beat, base.x + last.x)
        }
        return (base.beat, base.x)
    }

    /// seg を 1 つ、最後に足す。置いた順がそのまま seg の順番になる (時系列で並べ替えない)。
    /// beat / x は始点からの相対値。始点より前なら beat は負になり、保存のときは [-12, 2, 4] のように整数部にマイナスがつく (Beat.json)
    private func appendDraftSeg(beat b: Beat, x: Int) {
        guard let d = slideDraft, let base = slideDraftBase(), let last = slideDraftLastPoint() else { return }
        if b == last.beat && x == last.x {
            showToast("直前の点と同じ位置です")
            return
        }
        let seg = Seg(beat: b - base.beat, x: x - base.x)
        pushUndo()
        if let i = slideDraftIndex() {
            chart.notes[i].segs.append(seg)
        } else {
            var n = Note(beat: base.beat, x: base.x, w: base.w, type: nil, segs: [seg])
            n.id = d.noteID
            chart.notes.append(n)
        }
        chartChanged()
    }

    /// 「完」: 1つの始点に対する seg の配置を終わる (Slide ツールのまま。次のタップから新しい始点)
    func finishSlide() {
        guard slideDraft != nil else { return }
        let count = slideDraftIndex().map { chart.notes[$0].segs.count } ?? 0
        slideDraft = nil
        ghost = nil
        if count == 0 {
            showToast("seg が無いので、始点を取り消しました")
        } else {
            showToast("スライドを作成しました (seg \(count) 個)")
        }
    }

    // MARK: - Slide modify (レーン上の操作)
    // 窓 (SlideModifyWindow) を出したまま、レーンで直接 seg を編集する。
    //   スライドをタップ            → そのスライドを選ぶ (赤くなる)
    //   選んだスライドの点 (seg) を動かす → ドラッグ (縦は 1/n 拍、横はグリッドに吸着)。ドラッグ1回が Undo 1回分
    //   選んだスライドの点 (seg) をタップ → その点を選ぶ。隣に「削除」が出て、押すとその seg が消える
    //   それ以外の所をタップ        → 点を選んでいるときは選択を外すだけ。選んでいないときは、選んだスライドの最後に seg を追加
    //                              (Slide ツールと同じく、置いた順が seg の順番)

    /// 編集中のスライドの、譜面上のインデックス (無ければ nil)
    var modifySlideIndex: Int? {
        guard let id = modifySlideID else { return nil }
        return chart.notes.firstIndex(where: { $0.id == id })
    }

    func selectModifySlide(_ id: UUID) {
        modifySlideID = id
        modifySegIndex = nil
        selectedIDs = [id]
    }

    /// 選んでいる点 (seg) の隣に出す「削除」ボタンの範囲 (レーンの座標)。描画 (drawSlideModify) と当たり判定で同じものを使う。
    /// 点が右端に近いときは左側に出す。点を動かしている間・再生中・点が画面外のときは出さない (nil)
    func segDeleteRect(g: LaneGeo) -> CGRect? {
        guard tool == .slideModify, !isPlaying,
              !(dragMode == .segDrag && dragMoved),
              let i = modifySlideIndex, let j = modifySegIndex,
              j < chart.notes[i].segs.count else { return nil }
        let n = chart.notes[i]
        let s = n.segs[j]
        let cx = g.px(Double(n.x + s.x))
        let cy = g.py(n.beat.value + s.beat.value)
        if cy < -10 || cy > g.H + 10 { return nil }
        let w: CGFloat = 64
        let h: CGFloat = 36
        var x = cx + 22
        if x + w > g.W - 4 { x = cx - 22 - w }
        let y = max(2, min(g.H - h - 2, cy - h / 2))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 選んでいる点 (seg) を消す。1つしか無い seg は消せない (消すと通常のノーツになってしまうため)
    func deleteModifySeg() {
        guard let i = modifySlideIndex, let j = modifySegIndex else { return }
        removeSeg(note: i, seg: j)
        modifySegIndex = nil
    }

    /// 「完了」: Slide modify を終える (選択は残る)
    func finishSlideModify() {
        tool = .unselected
    }

    /// Slide modify 中にレーンをタップしたとき (点のドラッグ・タップは beginTouch で別に扱う)。
    /// 「削除」ボタンなら、選んでいる点を消す。
    /// 編集中でない別のスライドに触れたら、そちらを選ぶ。
    /// それ以外 (空き / 編集中スライドの帯の上) は、点を選んでいるときは選択を外すだけ (うっかり seg を足さない)。選んでいないときは seg を足す
    func slideModifyTap(at p: CGPoint, g: LaneGeo) {
        if let r = segDeleteRect(g: g), r.contains(p) {
            deleteModifySeg()
            return
        }
        for i in chart.notes.indices.reversed() {
            let n = chart.notes[i]
            if n.isSlide && n.id != modifySlideID && noteHit(n, at: p, g: g) {
                selectModifySlide(n.id)
                return
            }
        }
        guard let i = modifySlideIndex, chart.notes[i].isSlide else {
            showToast("編集するスライドをタップして選んでください")
            return
        }
        if modifySegIndex != nil {
            modifySegIndex = nil
            return
        }
        addSegAt(note: i, point: p, g: g)
    }

    /// タップした位置 (拍は 1/n に吸着、x はグリッドに吸着) に seg を足す
    private func addSegAt(note i: Int, point p: CGPoint, g: LaneGeo) {
        let n = chart.notes[i]
        let b = snapBeat(g.beatOf(p.y))
        if !allowNegativeSeg && b < n.beat {
            finishSlideModify()                         // 始点より前 (beat がマイナス) は置けない設定のとき: 「完了」と同じ
            return
        }
        let q = snapNote(centerX: g.xOf(p.x), widthUnits: n.w)
        var same = (b == n.beat && q.x == n.x)
        for s in n.segs where n.beat + s.beat == b && n.x + s.x == q.x { same = true }
        if same {
            showToast("その位置には、すでに点があります")
            return
        }
        pushUndo()
        chart.notes[i].segs.append(Seg(beat: b - n.beat, x: q.x - n.x))
        chartChanged()
        showToast("seg #\(chart.notes[i].segs.count) を追加しました")
    }

    /// 編集中のスライドの点 (seg) のうち、触れた位置にいちばん近いもの (26pt 以内)
    private func hitSeg(note i: Int, at p: CGPoint, g: LaneGeo) -> Int? {
        let n = chart.notes[i]
        var best: Int? = nil
        var bestD: CGFloat = 26
        for j in n.segs.indices {
            let s = n.segs[j]
            let q = CGPoint(x: g.px(Double(n.x + s.x)), y: g.py(n.beat.value + s.beat.value))
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < bestD {
                bestD = d
                best = j
            }
        }
        return best
    }

    /// 点を指に合わせて動かす (10pt 以上動かしてから)
    private func dragSeg(current: CGPoint, g: LaneGeo) {
        guard let id = segDragNoteID,
              let i = chart.notes.firstIndex(where: { $0.id == id }),
              segDragIndex < chart.notes[i].segs.count else {
            dragMode = .ignore                          // 対象が入れ替わっていたら (別の指で Undo された等) 中止する
            return
        }
        let n = chart.notes[i]
        var b = snapBeat(g.beatOf(current.y + segDragGrab.height))
        if !allowNegativeSeg && b < n.beat { b = n.beat }      // オフのときは始点の位置で止まる
        let q = snapNote(centerX: g.xOf(current.x + segDragGrab.width), widthUnits: n.w)
        let newSeg = Seg(beat: b - n.beat, x: q.x - n.x)
        let cur = n.segs[segDragIndex]
        if newSeg.beat == cur.beat && newSeg.x == cur.x { return }
        if !segDragUndoPushed {
            pushUndo()                                  // 動かす前の状態を積む (指を離すまでが Undo 1回分)
            segDragUndoPushed = true
        }
        chart.notes[i].segs[segDragIndex] = newSeg
    }

    private func finishSegDrag() {
        defer { objectWillChange.send() }               // 動かしている間は消していた「削除」を、離したら出し直す
        let pushed = segDragUndoPushed
        let orig = segDragOrig
        let id = segDragNoteID
        segDragNoteID = nil
        segDragOrig = nil
        segDragUndoPushed = false
        if !pushed { return }
        if let id = id, let o = orig,
           let i = chart.notes.firstIndex(where: { $0.id == id }),
           segDragIndex < chart.notes[i].segs.count {
            let s = chart.notes[i].segs[segDragIndex]
            if s.beat == o.beat && s.x == o.x {
                dropLastUndo()                          // 元の位置に戻して離した → 何も変わっていない
                return
            }
        }
        chartChanged()
    }

    // MARK: - Slide modify (seg の削除)

    /// seg を1つ消す (1つしか無いときは消さない)
    func removeSeg(note i: Int, seg j: Int) {
        guard i < chart.notes.count, j < chart.notes[i].segs.count else { return }
        if chart.notes[i].segs.count <= 1 {
            showToast("seg は1つ以上必要です")
            return
        }
        pushUndo()
        chart.notes[i].segs.remove(at: j)
        chartChanged()
    }

    // MARK: - BPM

    func addOrReplaceBPM(beat: Beat, bpm: Double) {
        if beat.value < 0 { return }
        let v = max(10, min(3000, bpm))
        pushUndo()
        if let idx = chart.times.firstIndex(where: { $0.beat == beat }) {
            chart.times[idx].bpm = v
        } else {
            chart.times.append(TimePoint(beat: beat, bpm: v))
        }
        chart.times.sort { $0.beat < $1.beat }
        chartChanged()
    }

    func removeBPM(at idx: Int) {
        guard idx > 0, idx < chart.times.count else {
            showToast("先頭のBPMは削除できません")
            return
        }
        pushUndo()
        chart.times.remove(at: idx)
        chartChanged()
    }

    // MARK: - Effect (scroll / jump)

    /// 同じ拍・同じ種類の effect があれば値を置き換え、無ければ追加する (scroll と jump は同じ拍に並べてよい)
    func addOrReplaceEffect(beat: Beat, kind: EffectPoint.Kind, value: Double) {
        if beat.value < 0 || !value.isFinite { return }
        pushUndo()
        if let idx = chart.effects.firstIndex(where: { $0.beat == beat && $0.kind == kind }) {
            chart.effects[idx].value = value
        } else {
            chart.effects.append(EffectPoint(beat: beat, kind: kind, value: value))
        }
        chart.effects.sort { $0.beat < $1.beat }
        chartChanged()
    }

    func removeEffect(at idx: Int) {
        guard idx >= 0, idx < chart.effects.count else { return }
        pushUndo()
        chart.effects.remove(at: idx)
        chartChanged()
    }
}
