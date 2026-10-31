import Foundation

// ============================================================
// アプリに内蔵しているプラグイン。
//   ・quad_InOut / quad_OutIn / join_slides_fixed: 添付された Malody V 用 Lua プラグインをそのまま収録
//   ・bm_ease / bm_img2hold / bm_select: 添付された BetterMalody 用 Lua プラグイン (ease effects / 画像から hold / 条件で選択) をそのまま収録
//     (GetUserOption / ReadBytesSelect / DecodeImage / ChartInfo / ClearSelection を使う。PluginBridge / LuaEngineSource に実装)
//   ・join_end_to_start / fold_join / branch_join: editor.html の「終点と始点を繋げる」「折り返し敷」「枝分かれ敷」を Lua にしたもの
//     (branch_join は、新しい仕様の版 (幹・枝とも、すでに枝分かれ敷を使ったスライドでよい / 装飾の始点が本体より早くてもよい)。
//      join_end_to_start / fold_join / branch_join は、seg が多いときも速いように、PluginBridge の segAll / setSegs / deleteNotes
//      (まとめて読み書き) を使い、seg は平らな配列で持つ)
//     (Order ボタンの「順番に選択」を使う。バグスライド = beat の重複は、常に許す)
// 追加したいプラグインは、Adv. メニューの「プラグイン(lua)を読み込む」から入れられます (.lua / .zip / 画像)。
// ============================================================
enum BuiltinPlugins {
    struct Entry {
        let fileName: String
        let source: String
    }

    static let all: [Entry] = [
        Entry(fileName: "quad_InOut.lua", source: ##"""
--Plugin Made By Nisemono_
--Modified: quad_InOut (In -> Out -> In -> Out ...)
--Modified2: BEAT_DENOM=1048576 + 同一beatタイミングのX平均マージ
--Modified3: 区間内で 1/128beat 未満の間隔になるsegを間引く(貪欲フィルタ)
--Modified4: wipefill と同じ視覚曲線になるよう "inverse easing" 化 (X-driven, time-smooth)

PluginName='quad_InOut'
PluginMode=7
PluginType=0
PluginRequire="5.2.6"

wipe=1024
BEAT_DENOM=1048576

MIN_INTERVAL=1/48

function lerp(a,b,t)
	return a+(b-a)*t
end

-- ====================================================================
-- ここが本質:
--   ratio = inverseEase( x進行度 )
--
--   wipefill 系プラグインは t を等分割し X = ease(t)*dx を配置する。
--   本プラグインは X を 1px 刻みで配置したいので、逆関数を使い
--   「その X に到達する時刻 t」を求める。 dt/dx が発散する点でも
--   時間軸で見た dx/dt はちゃんと 0 に落ちるため、視覚的に滑らか。
-- ====================================================================

-- Quadratic EaseIn  X(t)=t^2  の逆関数:  t = sqrt(x)
local function inverseEaseIn(x)
	if x<=0 then return 0 end
	if x>=1 then return 1 end
	return math.sqrt(x)
end

-- Quadratic EaseOut X(t)=1-(1-t)^2 の逆関数: t = 1-sqrt(1-x)
local function inverseEaseOut(x)
	if x<=0 then return 0 end
	if x>=1 then return 1 end
	return 1-math.sqrt(1-x)
end

local function beatToValue(b)
	return b.beat + b.numor/b.denom
end

local function valueToBeat(val,template)
	local beatInt=math.floor(val)
	local frac=val-beatInt
	local numor=math.floor(frac*BEAT_DENOM+0.5)
	if numor>=BEAT_DENOM then
		beatInt=beatInt+1
		numor=numor-BEAT_DENOM
	end
	template.beat=beatInt
	template.numor=numor
	template.denom=BEAT_DENOM
	return template
end

function Run()

	local Notes=Editor:GetSelectNotes()

	if Notes.Length<2 then
		Editor:ShowMessage("2つ以上のwipeを選択してください")
		return
	end

	local list={}
	for i=0,Notes.Length-1 do
		local n=Notes[i]
		list[#list+1]={
			note=n,
			time=Editor:GetNoteTime(n,true),
		}
	end

	table.sort(list,function(a,b) return a.time<b.time end)

	local segCount=#list-1
	local sameXCount=0
	local skippedByIntervalCount=0

	local buffer={}
	local index={}

	local function pushCandidate(beatInt,numor,x,width)
		local key=beatInt*(BEAT_DENOM+1)+numor
		local idx=index[key]
		if idx==nil then
			buffer[#buffer+1]={
				key=key,
				beatInt=beatInt,
				numor=numor,
				xSum=x,
				wSum=width,
				cnt=1,
			}
			index[key]=#buffer
		else
			local e=buffer[idx]
			e.xSum=e.xSum+x
			e.wSum=e.wSum+width
			e.cnt=e.cnt+1
		end
	end

	for i=1,#list do
		local n=list[i].note
		local b=Editor:GetNoteBeat(n,true)
		local key=b.beat*(BEAT_DENOM+1)+b.numor
		if index[key]==nil then
			buffer[#buffer+1]={
				key=key,
				beatInt=b.beat,
				numor=b.numor,
				xSum=0,
				wSum=0,
				cnt=0,
				isEndpoint=true,
			}
			index[key]=#buffer
		else
			buffer[index[key]].isEndpoint=true
		end
	end

	for s=1,segCount do
		local startNote=list[s].note
		local endNote  =list[s+1].note

		local startBeat=Editor:GetNoteBeat(startNote,true)
		local endBeat  =Editor:GetNoteBeat(endNote,true)

		local startX=Editor:GetNoteX(startNote)
		local endX  =Editor:GetNoteX(endNote)

		local startWidth=Editor:GetNoteWidth(startNote)
		local endWidth  =Editor:GetNoteWidth(endNote)

		local dx=endX-startX

		if dx==0 then
			sameXCount=sameXCount+1
		else
			local dir=1
			if dx<0 then dir=-1 end
			local count=math.abs(dx)

			local startBeatValue=beatToValue(startBeat)
			local endBeatValue  =beatToValue(endBeat)

			local useEaseIn=(s%2==1)

			local lastBeatValue=startBeatValue

			for i=1,count-1 do
				local x=startX+i*dir
				local xProgress=i/count   -- X 進行度 (0..1)

				-- ratio = 対応する時刻 t (0..1)
				local ratio
				if useEaseIn then
					ratio=inverseEaseIn(xProgress)
				else
					ratio=inverseEaseOut(xProgress)
				end

				local beatValue=
					startBeatValue+
					(endBeatValue-startBeatValue)*ratio

				if (beatValue-lastBeatValue)>=MIN_INTERVAL then
					local tmp={beat=0,numor=0,denom=BEAT_DENOM}
					valueToBeat(beatValue,tmp)

					local width=lerp(startWidth,endWidth,ratio)

					pushCandidate(tmp.beat,tmp.numor,x,width)
					lastBeatValue=beatValue
				else
					skippedByIntervalCount=skippedByIntervalCount+1
				end
			end
		end
	end

	Editor:StartBatch()

	local mergedCount=0
	local droppedByEndpoint=0

	for _,e in ipairs(buffer) do
		if e.isEndpoint then
			if e.cnt>0 then
				droppedByEndpoint=droppedByEndpoint+e.cnt
			end
		else
			if e.cnt>1 then
				mergedCount=mergedCount+(e.cnt-1)
			end
			local avgX=math.floor(e.xSum/e.cnt+0.5)
			local avgW=math.floor(e.wSum/e.cnt+0.5)
			if avgW<1 then avgW=1 end

			local beat={beat=e.beatInt,numor=e.numor,denom=BEAT_DENOM}

			local id=Editor:AddNote(wipe)
			Editor:SetNoteBeat(id,beat,true)
			Editor:SetNoteX(id,avgX)
			Editor:SetNoteWidth(id,avgW)
		end
	end

	Editor:FinishBatch()

	local msg=""
	if sameXCount>0 then
		msg=msg..sameXCount.."個の区間でX座標が同じためスキップしました\n"
	end
	if mergedCount>0 then
		msg=msg..mergedCount.."個の重複タイミングをX平均でマージしました\n"
	end
	if droppedByEndpoint>0 then
		msg=msg..droppedByEndpoint.."個が端点と同beatのため除外されました\n"
	end
	if skippedByIntervalCount>0 then
		msg=msg..skippedByIntervalCount.."個が間隔1/48未満のため間引かれました\n"
	end
	if msg~="" then
		Editor:ShowMessage(msg)
	end

end
"""##),
        Entry(fileName: "quad_OutIn.lua", source: ##"""
--Plugin Made By Nisemono_
--Modified: quad_OutIn (Out -> In -> Out -> In ...)
--Modified2: BEAT_DENOM=1048576 + 同一beatタイミングのX平均マージ
--Modified3: 区間内で 1/128beat 未満の間隔になるsegを間引く(貪欲フィルタ)
--Modified4: wipefill と同じ視覚曲線になるよう "inverse easing" 化 (X-driven, time-smooth)

PluginName='quad_OutIn'
PluginMode=7
PluginType=0
PluginRequire="5.2.6"

wipe=1024
BEAT_DENOM=1048576

MIN_INTERVAL=1/48

function lerp(a,b,t)
	return a+(b-a)*t
end

-- Quadratic EaseIn  X(t)=t^2       -> t = sqrt(x)
local function inverseEaseIn(x)
	if x<=0 then return 0 end
	if x>=1 then return 1 end
	return math.sqrt(x)
end

-- Quadratic EaseOut X(t)=1-(1-t)^2 -> t = 1-sqrt(1-x)
local function inverseEaseOut(x)
	if x<=0 then return 0 end
	if x>=1 then return 1 end
	return 1-math.sqrt(1-x)
end

local function beatToValue(b)
	return b.beat + b.numor/b.denom
end

local function valueToBeat(val,template)
	local beatInt=math.floor(val)
	local frac=val-beatInt
	local numor=math.floor(frac*BEAT_DENOM+0.5)
	if numor>=BEAT_DENOM then
		beatInt=beatInt+1
		numor=numor-BEAT_DENOM
	end
	template.beat=beatInt
	template.numor=numor
	template.denom=BEAT_DENOM
	return template
end

function Run()

	local Notes=Editor:GetSelectNotes()

	if Notes.Length<2 then
		Editor:ShowMessage("2つ以上のwipeを選択してください")
		return
	end

	local list={}
	for i=0,Notes.Length-1 do
		local n=Notes[i]
		list[#list+1]={
			note=n,
			time=Editor:GetNoteTime(n,true),
		}
	end

	table.sort(list,function(a,b) return a.time<b.time end)

	local segCount=#list-1
	local sameXCount=0
	local skippedByIntervalCount=0

	local buffer={}
	local index={}

	local function pushCandidate(beatInt,numor,x,width)
		local key=beatInt*(BEAT_DENOM+1)+numor
		local idx=index[key]
		if idx==nil then
			buffer[#buffer+1]={
				key=key,
				beatInt=beatInt,
				numor=numor,
				xSum=x,
				wSum=width,
				cnt=1,
			}
			index[key]=#buffer
		else
			local e=buffer[idx]
			e.xSum=e.xSum+x
			e.wSum=e.wSum+width
			e.cnt=e.cnt+1
		end
	end

	for i=1,#list do
		local n=list[i].note
		local b=Editor:GetNoteBeat(n,true)
		local key=b.beat*(BEAT_DENOM+1)+b.numor
		if index[key]==nil then
			buffer[#buffer+1]={
				key=key,
				beatInt=b.beat,
				numor=b.numor,
				xSum=0,
				wSum=0,
				cnt=0,
				isEndpoint=true,
			}
			index[key]=#buffer
		else
			buffer[index[key]].isEndpoint=true
		end
	end

	for s=1,segCount do
		local startNote=list[s].note
		local endNote  =list[s+1].note

		local startBeat=Editor:GetNoteBeat(startNote,true)
		local endBeat  =Editor:GetNoteBeat(endNote,true)

		local startX=Editor:GetNoteX(startNote)
		local endX  =Editor:GetNoteX(endNote)

		local startWidth=Editor:GetNoteWidth(startNote)
		local endWidth  =Editor:GetNoteWidth(endNote)

		local dx=endX-startX

		if dx==0 then
			sameXCount=sameXCount+1
		else
			local dir=1
			if dx<0 then dir=-1 end
			local count=math.abs(dx)

			local startBeatValue=beatToValue(startBeat)
			local endBeatValue  =beatToValue(endBeat)

			-- Out -> In -> Out -> In ...
			local useEaseOut=(s%2==1)

			local lastBeatValue=startBeatValue

			for i=1,count-1 do
				local x=startX+i*dir
				local xProgress=i/count

				local ratio
				if useEaseOut then
					ratio=inverseEaseOut(xProgress)
				else
					ratio=inverseEaseIn(xProgress)
				end

				local beatValue=
					startBeatValue+
					(endBeatValue-startBeatValue)*ratio

				if (beatValue-lastBeatValue)>=MIN_INTERVAL then
					local tmp={beat=0,numor=0,denom=BEAT_DENOM}
					valueToBeat(beatValue,tmp)

					local width=lerp(startWidth,endWidth,ratio)

					pushCandidate(tmp.beat,tmp.numor,x,width)
					lastBeatValue=beatValue
				else
					skippedByIntervalCount=skippedByIntervalCount+1
				end
			end
		end
	end

	Editor:StartBatch()

	local mergedCount=0
	local droppedByEndpoint=0

	for _,e in ipairs(buffer) do
		if e.isEndpoint then
			if e.cnt>0 then
				droppedByEndpoint=droppedByEndpoint+e.cnt
			end
		else
			if e.cnt>1 then
				mergedCount=mergedCount+(e.cnt-1)
			end
			local avgX=math.floor(e.xSum/e.cnt+0.5)
			local avgW=math.floor(e.wSum/e.cnt+0.5)
			if avgW<1 then avgW=1 end

			local beat={beat=e.beatInt,numor=e.numor,denom=BEAT_DENOM}

			local id=Editor:AddNote(wipe)
			Editor:SetNoteBeat(id,beat,true)
			Editor:SetNoteX(id,avgX)
			Editor:SetNoteWidth(id,avgW)
		end
	end

	Editor:FinishBatch()

	local msg=""
	if sameXCount>0 then
		msg=msg..sameXCount.."個の区間でX座標が同じためスキップしました\n"
	end
	if mergedCount>0 then
		msg=msg..mergedCount.."個の重複タイミングをX平均でマージしました\n"
	end
	if droppedByEndpoint>0 then
		msg=msg..droppedByEndpoint.."個が端点と同beatのため除外されました\n"
	end
	if skippedByIntervalCount>0 then
		msg=msg..skippedByIntervalCount.."個が間隔1/48未満のため間引かれました\n"
	end
	if msg~="" then
		Editor:ShowMessage(msg)
	end

end
"""##),
        Entry(fileName: "join_slides_fixed.lua", source: ##"""
-- =========================================================
-- Author: Physic (revised, fix v1.2.0)
-- Base  : Join.lua (v1.0.0) / join_slides_revised.lua (v1.1.0)
-- Version: 1.2.0
--
-- v1.1.0 からの変更点:
--   境目でXが異なる同一Beat点が「3点以上連続するクラスタ」に
--   なった場合、または元々の中継点間隔が1/96拍未満だった場合に、
--   安全チェック(shiftedY > prevPrevY)に引っかかってシフトが
--   丸ごとキャンセルされ、ガチ直角(未シフトの完全重複Beat)が
--   残ってしまう不具合を修正。
--
--   修正方針:
--     ・同一Beatが連続する「クラスタ」をまとめて検出する
--     ・クラスタ内の点数(n)に応じて、1/96拍という幅を
--       均等に分割して各点へ割り振る(合計シフト幅は従来と同じ)
--     ・手前の点との間隔がそれより狭い場合は、間隔に収まる範囲
--       まで動的にステップ幅を縮小する(丸ごと諦めない)
--     ・間隔が実質ゼロで安全にずらせない極限ケースのみ、
--       警告を出してシフト無しのまま並べる(クラッシュ・逆転防止)
-- =========================================================

------------------------------------------------------------
-- プラグイン情報
------------------------------------------------------------
PluginName = 'Join Slides (Fixed)'
PluginMode = 7
PluginType = 0
PluginRequire = '6.4.2'

------------------------------------------------------------
-- グローバル変数定義
------------------------------------------------------------
local NoteType = {
    Tap = 1,
    Wipe = 1024,
    Slide = 2048
}

-- 疑似直角を作るための基本オフセット幅の分母(1/96拍相当)
local BASE_EPSILON_DENOM = 96
local TOLERANCE = 1e-6


function Run()
    local selectedNotes = Editor:GetSelectNotes()
    local notesCount = selectedNotes == nil and 0 or selectedNotes.Length
    local mainSlide = nil
    local segmentsList = {}

    if notesCount < 2 then
        Editor:ShowMessage('Please select two or more slide notes.')
        return
    end

    mainSlide = selectedNotes[0]
    for i = 0, notesCount - 1 do
        local note = selectedNotes[i]
        if Editor:GetNoteType(note) ~= NoteType.Slide then
            Editor:ShowMessage('Only slide notes can be joined.')
            return
        end
        if BeatToPoint(Editor:GetNoteBeat(note, true)) < BeatToPoint(Editor:GetNoteBeat(mainSlide, true)) then
            mainSlide = note
        end
    end

    Editor:StartBatch()

    local mainStartBeat = Editor:GetNoteBeat(mainSlide, true)

    for i = 0, notesCount - 1 do
        local note = selectedNotes[i]
        local segmentsCount = Editor:GetNoteSlideBodyCount(note)
        local noteStartBeat = Editor:GetNoteBeat(note, true)

        -- セグメント情報を保存 (Rank=0: 経路上の点/終点)
        for seg = 0, segmentsCount - 1 do
            local segBeat = Editor:BeatAdd(noteStartBeat, Editor:GetNoteSlideBodyBeat(note, seg))
            table.insert(segmentsList, {
                X = Editor:GetNoteX(note) + Editor:GetNoteSlideBodyX(note, seg),
                Beat = segBeat,
                Y = BeatToPoint(segBeat),
                Rank = 0
            })
        end

        -- メインのスライド以外は始点の情報も保存 (Rank=1: 次ノーツの開始点)
        if note ~= mainSlide then
            table.insert(segmentsList, {
                X = Editor:GetNoteX(note),
                Beat = noteStartBeat,
                Y = BeatToPoint(noteStartBeat),
                Rank = 1
            })
            Editor:DeleteNote(note)
        else
            Editor:DeleteNoteSlideBody(mainSlide)
        end
    end

    -- Y(Beat)昇順。Yが同値の場合はRank昇順
    -- (前のノーツの終点 → 次のノーツの始点、の順番になるように)
    table.sort(segmentsList, function(a, b)
        if math.abs(a.Y - b.Y) > TOLERANCE then
            return a.Y < b.Y
        end
        return a.Rank < b.Rank
    end)

    ------------------------------------------------------------
    -- パス1: 完全に同一の点(拍もXも同じ)のみスキップする。
    -- 拍が同じでXが異なる点は、この時点では消さずに全て残す。
    ------------------------------------------------------------
    local merged = {}
    for i = 1, #segmentsList do
        local seg = segmentsList[i]
        if #merged == 0 then
            table.insert(merged, seg)
        else
            local prev = merged[#merged]
            local isTrueDup = (math.abs(seg.Y - prev.Y) <= TOLERANCE)
                           and (math.abs(seg.X - prev.X) <= TOLERANCE)
            if not isTrueDup then
                table.insert(merged, seg)
            end
        end
    end

    ------------------------------------------------------------
    -- パス2: 同一Beatが連続する「クラスタ」ごとに、疑似直角用の
    -- 微小オフセットをクラスタ内の点数に応じて均等に割り振る。
    -- (クラスタが2点なら従来通り1点だけ1/96ずれるのと同じ結果になる)
    ------------------------------------------------------------
    local finalized = {}
    local i = 1
    while i <= #merged do
        local j = i
        while j < #merged and math.abs(merged[j + 1].Y - merged[i].Y) <= TOLERANCE do
            j = j + 1
        end
        local clusterSize = j - i + 1

        if clusterSize == 1 then
            table.insert(finalized, merged[i])
        else
            -- クラスタ手前の点との実際の間隔(拍のPoint換算)
            local prevY = (#finalized > 0) and finalized[#finalized].Y or -math.huge
            local availableGap = merged[i].Y - prevY

            -- 基本の合計シフト幅は1/96拍。安全マージンとして
            -- 利用可能な間隔の半分までしか使わないようにする。
            local baseTotalShift = 1 / BASE_EPSILON_DENOM
            local safeTotalShift = math.min(baseTotalShift, math.max(0, availableGap - TOLERANCE) * 0.5)

            if safeTotalShift <= TOLERANCE then
                -- 手前の点と間隔がほぼゼロで、安全にずらせない極限ケース。
                -- シフトはせず、そのまま並べる(順序崩壊やクラッシュだけは防ぐ)。
                Editor:ShowTip('Join Slides: some overlapping points could not be offset safely (spacing too tight).')
                for k = i, j do
                    table.insert(finalized, merged[k])
                end
            else
                -- クラスタ内の(clusterSize-1)個の間隔ぶん、
                -- safeTotalShiftを均等に分割した分母を作る
                local stepDenom = math.ceil((clusterSize - 1) / safeTotalShift)
                if stepDenom < 1 then stepDenom = 1 end

                for k = i, j do
                    local offsetSteps = (j - k) -- 最後の点(=真の境界Beat)は0
                    local seg = merged[k]
                    if offsetSteps == 0 then
                        table.insert(finalized, seg)
                    else
                        local shiftBeat = { beat = 0, numor = offsetSteps, denom = stepDenom }
                        local shiftedBeat = Editor:BeatMinus(seg.Beat, shiftBeat)
                        table.insert(finalized, {
                            X = seg.X,
                            Beat = shiftedBeat,
                            Y = BeatToPoint(shiftedBeat),
                            Rank = seg.Rank
                        })
                    end
                end
            end
        end
        i = j + 1
    end

    local mainX = Editor:GetNoteX(mainSlide)
    for idx = 1, #finalized do
        local seg = finalized[idx]
        local relBeat = Editor:BeatMinus(seg.Beat, mainStartBeat)
        Editor:AddNoteSlideBody(mainSlide, relBeat)
        Editor:SetNoteSlideBodyX(mainSlide, idx - 1, seg.X - mainX)
    end

    Editor:FinishBatch()
end

------------------------------------------------------------
-- Utilities
------------------------------------------------------------

function BeatToPoint(beat)
    return beat.beat + (beat.numor / beat.denom)
end

function PointToBeat(point)
    local beat = math.floor(point)
    local numor = math.floor((point - beat) * 1000)
    local denom = 1000
    return { beat = beat, numor = numor, denom = denom }
end
"""##),
        Entry(fileName: "join_end_to_start.lua", source: ##"""
--[[
  終点と始点を繋げる  (editor.html の「終点と始点を繋げる」をプラグイン化)

  使い方: 結合したいスライドを2個以上選んで実行する。
    ・「順番に選択」(Order ボタン) で選んだスライドがあれば、それを使う。無ければ、選択中 (LASSO・タップ) のスライドを使う
  選んだスライドを「始点 beat が早い順」に並べて (同じ beat のときは、選んだ並びのまま)、
  前のスライドの終点 → 次のスライドの始点 を一直線に繋いで、最も早いスライド1本にまとめる (ほかのスライドは消える)。
  各スライドの中の seg の並び (逆走・折り返し・マイナス beat) には一切手を付けない。
  境目の beat が重複しても、そのまま残す (バグスライドを許す)。

  速さ (seg が何万個もあるとき):
    ・Editor の呼び出しを seg ごとにやると、往復が多すぎて遅い。
      このエディタ独自の GetNoteSlideBodyAll / ReplaceNoteSlideBody / DeleteNotes があれば、スライド1本につき1回の往復で済ませる。
      (本物の Malody V などでは、これらが無いので、従来どおり seg を1個ずつ読み書きする)
    ・seg ごとに Lua の表を作ると重いので、seg は「整数部, 分子, 分母, x」を4つずつ並べた平らな配列で持つ
]]
PluginName='終点と始点を繋げる'
PluginMode=7
PluginType=0

local SLIDE = 2048            -- GetNoteType の戻り値 (スライド)
local MAX_BEAT_DEN = 1048576  -- beat の分母の上限 (これを超える分母は 1/1048576 拍に丸める)
local EPS = 1e-10

-- ---- beat 計算 (beat は {整数部, 分子, 分母}。seg は「整数部, 分子, 分母, x」を並べた平らな配列で持つ) ----
local function gcd(a, b)
  a = math.abs(a)
  b = math.abs(b)
  while b ~= 0 do
    a, b = b, a % b
  end
  if a == 0 then return 1 end
  return a
end

-- beat (m + n/d) を約分して、buf[o+1], buf[o+2], buf[o+3] に書き込む。
-- 分母が上限を超えるときは 1/1048576 拍に丸める
local function capBeatInto(buf, o, m, n, d)
  if d <= 0 then d = 1 end
  if d <= MAX_BEAT_DEN then
    if n == 0 then
      buf[o + 1] = m
      buf[o + 2] = 0
      buf[o + 3] = 1
      return
    end
    local g = gcd(n, d)
    buf[o + 1] = m
    buf[o + 2] = n / g
    buf[o + 3] = d / g
    return
  end
  local newNum = math.floor(n / d * MAX_BEAT_DEN + 0.5)
  if newNum >= MAX_BEAT_DEN then
    m = m + 1
    newNum = 0
  end
  if newNum == 0 then
    buf[o + 1] = m
    buf[o + 2] = 0
    buf[o + 3] = 1
    return
  end
  local g = gcd(newNum, MAX_BEAT_DEN)
  buf[o + 1] = m
  buf[o + 2] = newNum / g
  buf[o + 3] = MAX_BEAT_DEN / g
end

local function capBeat(m, n, d)
  local t = {}
  capBeatInto(t, 0, m, n, d)
  return t
end

local function beatPoint(b) return b[1] + b[2] / b[3] end

-- b1 - b2 (結果が負になるときは 0)
local function beatDiff(b1, b2)
  local m1, n1, d1 = b1[1], b1[2], b1[3]
  local m2, n2, d2 = b2[1], b2[2], b2[3]
  local num1 = (m1 * d1 + n1) * d2
  local num2 = (m2 * d2 + n2) * d1
  local den = d1 * d2
  local diff = num1 - num2
  if diff < 0 then diff = 0 end
  local n = diff % den
  local m = (diff - n) / den
  return capBeat(m, n, den)
end

-- (m1 n1/d1) + (m2 n2/d2) を buf[o+1..o+3] に書き込む (b1 が負の相対 beat でもよい。seg の点ごとに表を作らない)
local function beatAddInto(buf, o, m1, n1, d1, m2, n2, d2)
  local den = d1 * d2
  local num = n1 * d2 + n2 * d1
  local n = num % den
  local m = m1 + m2 + (num - n) / den
  capBeatInto(buf, o, m, n, den)
end

-- ---- エディタとのやりとり ----
local function readBeat(t)
  local d = t.denom
  if d == nil or d < 1 then d = 1 end
  return { t.beat or 0, t.numor or 0, d }
end

-- Editor の「ノーツの配列」(.Length と 0 始まりの添字) を、Lua の普通の配列にする
local function toList(arr)
  local list = {}
  if arr ~= nil then
    for i = 0, arr.Length - 1 do
      list[#list + 1] = arr[i]
    end
  end
  return list
end

-- このエディタ独自の「まとめて読み書きする」API があるか (無い環境では、seg を1個ずつ読み書きする)
local HAS_BULK_READ = Editor.GetNoteSlideBodyAll ~= nil
local HAS_BULK_WRITE = Editor.ReplaceNoteSlideBody ~= nil
local HAS_BULK_DELETE = Editor.DeleteNotes ~= nil

-- 「順番に選択」(Order ボタン) でタップした順のノーツ。この機能が無い環境では空
local function orderNotes()
  if Editor.GetOrderNotes == nil then return {} end
  return toList(Editor:GetOrderNotes())
end

local function clearOrder()
  if Editor.ClearOrderNotes ~= nil then Editor:ClearOrderNotes() end
end

-- スライド1本の seg を全部読む。戻り値は (平らな配列, seg の数)。
-- 平らな配列は「整数部, 分子, 分母, x」を seg の数だけ並べたもの
local function readSegs(note)
  if HAS_BULK_READ then
    -- 1回の往復で受け取る (seg を1個ずつ読むと、何万個もあるとき遅い)
    local flat = Editor:GetNoteSlideBodyAll(note)
    return flat, flat.Length
  end
  local flat = {}
  local o = 0
  local segCount = Editor:GetNoteSlideBodyCount(note)
  for k = 0, segCount - 1 do
    local b = readBeat(Editor:GetNoteSlideBodyBeat(note, k))
    flat[o + 1] = b[1]
    flat[o + 2] = b[2]
    flat[o + 3] = b[3]
    flat[o + 4] = Editor:GetNoteSlideBodyX(note, k)
    o = o + 4
  end
  return flat, segCount
end

-- ノーツの一覧から、スライドだけを読み出す。同じノーツは1回だけ。
-- 始点・x は数値にして持つ。seg は平らな配列 (flat) と seg の数 (cnt)。order = 一覧の中での位置
local function readSlides(notes)
  local list = {}
  local seen = {}
  for i = 1, #notes do
    local note = notes[i]
    if not seen[note] then
      seen[note] = true
      if Editor:GetNoteType(note) == SLIDE then
        local startBeat = readBeat(Editor:GetNoteBeat(note, true))
        local flat, cnt = readSegs(note)
        list[#list + 1] = {
          note = note,
          beat = startBeat,
          point = beatPoint(startBeat),
          x = Editor:GetNoteX(note),
          flat = flat,
          cnt = cnt,
          order = #list + 1
        }
      end
    end
  end
  return list
end

-- 始点 beat の早い順に並べる (同じ beat なら、一覧での並びのまま)
local function sortByStart(list)
  table.sort(list, function(a, b)
    if a.point ~= b.point then return a.point < b.point end
    return a.order < b.order
  end)
end

-- list から main を除いたもの
local function without(list, main)
  local out = {}
  for i = 1, #list do
    if list[i].note ~= main.note then out[#out + 1] = list[i] end
  end
  return out
end

-- 本体スライドの seg を out (平らな配列。seg が count 個) に置き換えて、本体以外のスライドを消す。「順番に選択」はリセットする
local function commit(main, out, count, slides)
  if HAS_BULK_WRITE then
    -- 並べ替えずに、1回の往復で丸ごと置き換える (beat が行ったり来たりする seg も、そのまま残る)
    Editor:ReplaceNoteSlideBody(main.note, out)
  else
    Editor:DeleteNoteSlideBody(main.note)
    -- 並べ替えずに、足した順のまま末尾に足す (beat が行ったり来たりする seg も、そのまま残る)
    local add = Editor.AppendNoteSlideBody ~= nil and Editor.AppendNoteSlideBody or Editor.AddNoteSlideBody
    local o = 0
    for i = 1, count do
      add(Editor, main.note, { beat = out[o + 1], numor = out[o + 2], denom = out[o + 3] })
      Editor:SetNoteSlideBodyX(main.note, i - 1, out[o + 4])
      o = o + 4
    end
  end
  local doomed = {}
  for i = 1, #slides do
    if slides[i] ~= main then doomed[#doomed + 1] = slides[i].note end
  end
  if HAS_BULK_DELETE then
    if #doomed > 0 then Editor:DeleteNotes(doomed) end
  else
    for i = 1, #doomed do Editor:DeleteNote(doomed[i]) end
  end
  clearOrder()
end

local function mergeSequential(ordered)
  local main = ordered[1]
  local out = {}
  local o = 0
  local count = 0
  for i = 1, #ordered do
    local slide = ordered[i]
    local offsetX = slide.x - main.x
    local base = beatDiff(slide.beat, main.beat)
    local bm, bn, bd = base[1], base[2], base[3]
    if i > 1 then
      -- 前のスライドの終点 → このスライドの始点、を繋ぐ点
      out[o + 1] = bm
      out[o + 2] = bn
      out[o + 3] = bd
      out[o + 4] = offsetX
      o = o + 4
      count = count + 1
    end
    local flat = slide.flat
    local f = 0
    for j = 1, slide.cnt do
      beatAddInto(out, o, flat[f + 1], flat[f + 2], flat[f + 3], bm, bn, bd)
      out[o + 4] = flat[f + 4] + offsetX
      o = o + 4
      f = f + 4
    end
    count = count + slide.cnt
  end
  commit(main, out, count, ordered)
end

function Run()
  -- 「順番に選択」があればそれを、無ければ選択中のスライドを使う
  local orderList = orderNotes()
  local slides
  if #orderList >= 1 then
    slides = readSlides(orderList)
  else
    slides = readSlides(toList(Editor:GetSelectNotes()))
  end
  if #slides < 2 then
    Editor:ShowTip('スライドを2個以上選んでください（「順番に選択」または選択で）')
    return
  end
  sortByStart(slides)
  Editor:StartBatch()
  local ok, err = pcall(mergeSequential, slides)
  Editor:FinishBatch()
  if not ok then
    Editor:ShowTip('❌ 終点と始点を繋げるのに失敗しました: ' .. tostring(err))
    return
  end
  Editor:ShowTip('✅ 終点と始点を繋げる: ' .. #slides .. '個を時系列順に結合しました')
end
"""##),
        Entry(fileName: "fold_join.lua", source: ##"""
--[[
  折り返し敷  (editor.html の「折り返し敷」をプラグイン化)

  行ったり来たりしながら、一筆書きでスライドを1本に結合する (1本目は順行、2本目は逆走して始点へ、3本目はまた順行…)。
  結合したスライドのうち、1番目が「本体」(判定が残る)で、ほかのスライドは消える。

  使い方 (どれか):
    ・「順番に選択」(Order ボタン) でスライドを2本以上選ぶ → 選んだ順どおりに結合する (1番目が本体)
    ・「順番に選択」で本体を1本選んで、LASSO などで装飾にするスライドも選ぶ → 装飾は始点 beat の早い順に結合する
    ・「順番に選択」を使わず、LASSO などでスライドを2本以上選ぶ → 始点がいちばん早いスライドが本体、残りは始点 beat の早い順
  境目の beat が重複しても、そのまま残す (バグスライドを許す)。

  速さ (seg が何万個もあるとき):
    ・Editor の呼び出しを seg ごとにやると、往復が多すぎて遅い。
      このエディタ独自の GetNoteSlideBodyAll / ReplaceNoteSlideBody / DeleteNotes があれば、スライド1本につき1回の往復で済ませる。
      (本物の Malody V などでは、これらが無いので、従来どおり seg を1個ずつ読み書きする)
    ・seg ごとに Lua の表を作ると重いので、seg は「整数部, 分子, 分母, x」を4つずつ並べた平らな配列で持つ
]]
PluginName='折り返し敷'
PluginMode=7
PluginType=0

local SLIDE = 2048            -- GetNoteType の戻り値 (スライド)
local MAX_BEAT_DEN = 1048576  -- beat の分母の上限 (これを超える分母は 1/1048576 拍に丸める)
local EPS = 1e-10

-- ---- beat 計算 (beat は {整数部, 分子, 分母}。seg は「整数部, 分子, 分母, x」を並べた平らな配列で持つ) ----
local function gcd(a, b)
  a = math.abs(a)
  b = math.abs(b)
  while b ~= 0 do
    a, b = b, a % b
  end
  if a == 0 then return 1 end
  return a
end

-- beat (m + n/d) を約分して、buf[o+1], buf[o+2], buf[o+3] に書き込む。
-- 分母が上限を超えるときは 1/1048576 拍に丸める
local function capBeatInto(buf, o, m, n, d)
  if d <= 0 then d = 1 end
  if d <= MAX_BEAT_DEN then
    if n == 0 then
      buf[o + 1] = m
      buf[o + 2] = 0
      buf[o + 3] = 1
      return
    end
    local g = gcd(n, d)
    buf[o + 1] = m
    buf[o + 2] = n / g
    buf[o + 3] = d / g
    return
  end
  local newNum = math.floor(n / d * MAX_BEAT_DEN + 0.5)
  if newNum >= MAX_BEAT_DEN then
    m = m + 1
    newNum = 0
  end
  if newNum == 0 then
    buf[o + 1] = m
    buf[o + 2] = 0
    buf[o + 3] = 1
    return
  end
  local g = gcd(newNum, MAX_BEAT_DEN)
  buf[o + 1] = m
  buf[o + 2] = newNum / g
  buf[o + 3] = MAX_BEAT_DEN / g
end

local function capBeat(m, n, d)
  local t = {}
  capBeatInto(t, 0, m, n, d)
  return t
end

local function beatPoint(b) return b[1] + b[2] / b[3] end

-- b1 - b2 (結果が負になるときは 0)
local function beatDiff(b1, b2)
  local m1, n1, d1 = b1[1], b1[2], b1[3]
  local m2, n2, d2 = b2[1], b2[2], b2[3]
  local num1 = (m1 * d1 + n1) * d2
  local num2 = (m2 * d2 + n2) * d1
  local den = d1 * d2
  local diff = num1 - num2
  if diff < 0 then diff = 0 end
  local n = diff % den
  local m = (diff - n) / den
  return capBeat(m, n, den)
end

-- (m1 n1/d1) + (m2 n2/d2) を buf[o+1..o+3] に書き込む (b1 が負の相対 beat でもよい。seg の点ごとに表を作らない)
local function beatAddInto(buf, o, m1, n1, d1, m2, n2, d2)
  local den = d1 * d2
  local num = n1 * d2 + n2 * d1
  local n = num % den
  local m = m1 + m2 + (num - n) / den
  capBeatInto(buf, o, m, n, den)
end

-- ---- エディタとのやりとり ----
local function readBeat(t)
  local d = t.denom
  if d == nil or d < 1 then d = 1 end
  return { t.beat or 0, t.numor or 0, d }
end

-- Editor の「ノーツの配列」(.Length と 0 始まりの添字) を、Lua の普通の配列にする
local function toList(arr)
  local list = {}
  if arr ~= nil then
    for i = 0, arr.Length - 1 do
      list[#list + 1] = arr[i]
    end
  end
  return list
end

-- このエディタ独自の「まとめて読み書きする」API があるか (無い環境では、seg を1個ずつ読み書きする)
local HAS_BULK_READ = Editor.GetNoteSlideBodyAll ~= nil
local HAS_BULK_WRITE = Editor.ReplaceNoteSlideBody ~= nil
local HAS_BULK_DELETE = Editor.DeleteNotes ~= nil

-- 「順番に選択」(Order ボタン) でタップした順のノーツ。この機能が無い環境では空
local function orderNotes()
  if Editor.GetOrderNotes == nil then return {} end
  return toList(Editor:GetOrderNotes())
end

local function clearOrder()
  if Editor.ClearOrderNotes ~= nil then Editor:ClearOrderNotes() end
end

-- スライド1本の seg を全部読む。戻り値は (平らな配列, seg の数)。
-- 平らな配列は「整数部, 分子, 分母, x」を seg の数だけ並べたもの
local function readSegs(note)
  if HAS_BULK_READ then
    -- 1回の往復で受け取る (seg を1個ずつ読むと、何万個もあるとき遅い)
    local flat = Editor:GetNoteSlideBodyAll(note)
    return flat, flat.Length
  end
  local flat = {}
  local o = 0
  local segCount = Editor:GetNoteSlideBodyCount(note)
  for k = 0, segCount - 1 do
    local b = readBeat(Editor:GetNoteSlideBodyBeat(note, k))
    flat[o + 1] = b[1]
    flat[o + 2] = b[2]
    flat[o + 3] = b[3]
    flat[o + 4] = Editor:GetNoteSlideBodyX(note, k)
    o = o + 4
  end
  return flat, segCount
end

-- ノーツの一覧から、スライドだけを読み出す。同じノーツは1回だけ。
-- 始点・x は数値にして持つ。seg は平らな配列 (flat) と seg の数 (cnt)。order = 一覧の中での位置
local function readSlides(notes)
  local list = {}
  local seen = {}
  for i = 1, #notes do
    local note = notes[i]
    if not seen[note] then
      seen[note] = true
      if Editor:GetNoteType(note) == SLIDE then
        local startBeat = readBeat(Editor:GetNoteBeat(note, true))
        local flat, cnt = readSegs(note)
        list[#list + 1] = {
          note = note,
          beat = startBeat,
          point = beatPoint(startBeat),
          x = Editor:GetNoteX(note),
          flat = flat,
          cnt = cnt,
          order = #list + 1
        }
      end
    end
  end
  return list
end

-- 始点 beat の早い順に並べる (同じ beat なら、一覧での並びのまま)
local function sortByStart(list)
  table.sort(list, function(a, b)
    if a.point ~= b.point then return a.point < b.point end
    return a.order < b.order
  end)
end

-- list から main を除いたもの
local function without(list, main)
  local out = {}
  for i = 1, #list do
    if list[i].note ~= main.note then out[#out + 1] = list[i] end
  end
  return out
end

-- 本体スライドの seg を out (平らな配列。seg が count 個) に置き換えて、本体以外のスライドを消す。「順番に選択」はリセットする
local function commit(main, out, count, slides)
  if HAS_BULK_WRITE then
    -- 並べ替えずに、1回の往復で丸ごと置き換える (beat が行ったり来たりする seg も、そのまま残る)
    Editor:ReplaceNoteSlideBody(main.note, out)
  else
    Editor:DeleteNoteSlideBody(main.note)
    -- 並べ替えずに、足した順のまま末尾に足す (beat が行ったり来たりする seg も、そのまま残る)
    local add = Editor.AppendNoteSlideBody ~= nil and Editor.AppendNoteSlideBody or Editor.AddNoteSlideBody
    local o = 0
    for i = 1, count do
      add(Editor, main.note, { beat = out[o + 1], numor = out[o + 2], denom = out[o + 3] })
      Editor:SetNoteSlideBodyX(main.note, i - 1, out[o + 4])
      o = o + 4
    end
  end
  local doomed = {}
  for i = 1, #slides do
    if slides[i] ~= main then doomed[#doomed + 1] = slides[i].note end
  end
  if HAS_BULK_DELETE then
    if #doomed > 0 then Editor:DeleteNotes(doomed) end
  else
    for i = 1, #doomed do Editor:DeleteNote(doomed[i]) end
  end
  clearOrder()
end

local function mergeJoin(targets)
  local main = targets[1]
  local out = {}
  local o = 0
  local count = 0
  for i = 1, #targets do
    local slide = targets[i]
    local offsetX = slide.x - main.x
    local base = beatDiff(slide.beat, main.beat)
    local bm, bn, bd = base[1], base[2], base[3]
    local flat, cnt = slide.flat, slide.cnt
    if (i - 1) % 2 == 0 then
      -- 順行
      if i > 1 then
        out[o + 1] = bm
        out[o + 2] = bn
        out[o + 3] = bd
        out[o + 4] = offsetX
        o = o + 4
        count = count + 1
      end
      local f = 0
      for j = 1, cnt do
        beatAddInto(out, o, flat[f + 1], flat[f + 2], flat[f + 3], bm, bn, bd)
        out[o + 4] = flat[f + 4] + offsetX
        o = o + 4
        f = f + 4
      end
    else
      -- 逆走して、このスライドの始点へ戻る
      local f = (cnt - 1) * 4
      for j = cnt, 1, -1 do
        beatAddInto(out, o, flat[f + 1], flat[f + 2], flat[f + 3], bm, bn, bd)
        out[o + 4] = flat[f + 4] + offsetX
        o = o + 4
        f = f - 4
      end
      out[o + 1] = bm
      out[o + 2] = bn
      out[o + 3] = bd
      out[o + 4] = offsetX
      o = o + 4
      count = count + 1
    end
    count = count + cnt
  end
  commit(main, out, count, targets)
end

function Run()
  local orderList = orderNotes()
  local targets
  if #orderList >= 2 then
    -- 手動: 「順番に選択」で選んだ順どおり (1番目が本体)
    targets = readSlides(orderList)
  else
    local selected = readSlides(toList(Editor:GetSelectNotes()))
    sortByStart(selected)
    if #orderList == 1 then
      -- 自動: 「順番に選択」の1本が本体。選択中のほかのスライドが装飾 (始点 beat の早い順)
      local ordered = readSlides(orderList)
      if #ordered == 0 then
        Editor:ShowTip('本体のスライドが見つかりません')
        return
      end
      local main = ordered[1]
      targets = { main }
      local decos = without(selected, main)
      for i = 1, #decos do targets[#targets + 1] = decos[i] end
    else
      -- 「順番に選択」なし: 選択中のスライド。いちばん始点が早いものが本体
      targets = selected
    end
  end
  if #targets < 2 then
    Editor:ShowTip('結合するスライドを2本以上選んでください（「順番に選択」で順番を付けるか、本体のほかに装飾も選ぶ）')
    return
  end
  Editor:StartBatch()
  local ok, err = pcall(mergeJoin, targets)
  Editor:FinishBatch()
  if not ok then
    Editor:ShowTip('❌ 折り返し結合に失敗しました: ' .. tostring(err))
    return
  end
  Editor:ShowTip('✅ 折り返し結合: ' .. #targets .. '本を処理しました')
end
"""##),
        Entry(fileName: "branch_join.lua", source: ##"""
--[[
  枝分かれ敷  (editor.html の「枝分かれ敷」をプラグイン化)

  「本体(幹)」に、ほかのスライドを「枝(装飾)」として、一筆書きで結合する。
  枝は、幹の上のその枝の終点にあたる位置から、枝を逆走して始点へ → 枝を順行して終点へ → 幹へ戻る、とたどる。
  枝を差し込む位置は、幹の seg の通り道の上で自動で計算される。ほかのスライドは消える。

  使い方 (どれか):
    ・「順番に選択」(Order ボタン) でスライドを2本以上選ぶ → 始点がいちばん早いスライドが幹、残りが枝
      (同じ beat のときは、選んだ順の早いほうが幹)
    ・「順番に選択」で本体を1本選んで、LASSO などで装飾にするスライドも選ぶ → 選んだ本体が幹、装飾は始点 beat の早い順
      (装飾の始点が本体より早くてもよい。その部分はマイナス beat の seg になる)
    ・「順番に選択」を使わず、LASSO などでスライドを2本以上選ぶ → 始点がいちばん早いスライドが幹
  境目の beat が重複しても、そのまま残す (バグスライドを許す)。

  速さ (seg が何万個もあるとき):
    ・Editor の呼び出しを seg ごとにやると、往復が多すぎて遅い (30分かかることもあった)。
      このエディタ独自の GetNoteSlideBodyAll / ReplaceNoteSlideBody / DeleteNotes があれば、スライド1本につき1回の往復で済ませる。
      (本物の Malody V などでは、これらが無いので、従来どおり seg を1個ずつ読み書きする)
    ・seg ごとに Lua の表を作ると重いので、seg は「整数部, 分子, 分母, x」を4つずつ並べた平らな配列で持つ
      (seg の k 番目 (1 始まり) は、添字 4*(k-1)+1 〜 4*(k-1)+4)。

  すでに枝分かれ敷を使ったスライドも、幹にも枝にもできる。
    ・幹: いま付いている枝の周回はそのまま残して、新しい枝を幹の通り道の正しい位置へ差し込む
      (幹の通り道 = beat が前の seg より先へ進む seg だけを拾った折れ線。beat が戻る周回は通り道に入れない)
    ・枝: 枝の中の周回ごと、逆走 → 順行でたどる
]]
PluginName='枝分かれ敷'
PluginMode=7
PluginType=0
PluginRequire='6.4.2'

local SLIDE = 2048            -- GetNoteType の戻り値 (スライド)
local MAX_BEAT_DEN = 1048576  -- beat の分母の上限 (これを超える分母は 1/1048576 拍に丸める)
local EPS = 1e-10

-- ---- beat 計算 (beat は {整数部, 分子, 分母} の配列。API とやりとりするときだけ表にする) ----
local function gcd(a, b)
  a = math.abs(a)
  b = math.abs(b)
  while b ~= 0 do
    a, b = b, a % b
  end
  if a == 0 then return 1 end
  return a
end

-- beat (m + n/d) を約分して、buf[o+1], buf[o+2], buf[o+3] に書き込む。
-- 分母が上限を超えるときは 1/1048576 拍に丸める
local function capBeatInto(buf, o, m, n, d)
  if d <= 0 then d = 1 end
  if d <= MAX_BEAT_DEN then
    if n == 0 then
      buf[o + 1] = m
      buf[o + 2] = 0
      buf[o + 3] = 1
      return
    end
    local g = gcd(n, d)
    buf[o + 1] = m
    buf[o + 2] = n / g
    buf[o + 3] = d / g
    return
  end
  local newNum = math.floor(n / d * MAX_BEAT_DEN + 0.5)
  if newNum >= MAX_BEAT_DEN then
    m = m + 1
    newNum = 0
  end
  if newNum == 0 then
    buf[o + 1] = m
    buf[o + 2] = 0
    buf[o + 3] = 1
    return
  end
  local g = gcd(newNum, MAX_BEAT_DEN)
  buf[o + 1] = m
  buf[o + 2] = newNum / g
  buf[o + 3] = MAX_BEAT_DEN / g
end

local function capBeat(m, n, d)
  local t = {}
  capBeatInto(t, 0, m, n, d)
  return t
end

local function beatPoint(b) return b[1] + b[2] / b[3] end

-- b1 - b2 (結果が負になってもよい。整数部がマイナス、分子は 0 以上の「マイナス beat」の形で返す)
-- 装飾の始点が本体より早いとき、相対 beat はマイナスになる。0 に丸めると枝の形が変わってしまう
local function beatDiff(b1, b2)
  local m1, n1, d1 = b1[1], b1[2], b1[3]
  local m2, n2, d2 = b2[1], b2[2], b2[3]
  local num1 = (m1 * d1 + n1) * d2
  local num2 = (m2 * d2 + n2) * d1
  local den = d1 * d2
  local diff = num1 - num2
  local n = diff % den
  local m = (diff - n) / den
  return capBeat(m, n, den)
end

-- b1 + b2 (b1 が負の相対 beat でもよい)
local function beatAdd(b1, b2)
  local m1, n1, d1 = b1[1], b1[2], b1[3]
  local m2, n2, d2 = b2[1], b2[2], b2[3]
  local den = d1 * d2
  local num = n1 * d2 + n2 * d1
  local n = num % den
  local m = m1 + m2 + (num - n) / den
  return capBeat(m, n, den)
end

-- (m1 n1/d1) + (m2 n2/d2) を buf[o+1..o+3] に書き込む。beatAdd と同じ計算 (seg の点ごとに表を作らないための版)
local function beatAddInto(buf, o, m1, n1, d1, m2, n2, d2)
  local den = d1 * d2
  local num = n1 * d2 + n2 * d1
  local n = num % den
  local m = m1 + m2 + (num - n) / den
  capBeatInto(buf, o, m, n, den)
end

-- ---- エディタとのやりとり ----
local function readBeat(t)
  local d = t.denom
  if d == nil or d < 1 then d = 1 end
  return { t.beat or 0, t.numor or 0, d }
end

-- Editor の「ノーツの配列」(.Length と 0 始まりの添字) を、Lua の普通の配列にする
local function toList(arr)
  local list = {}
  if arr ~= nil then
    for i = 0, arr.Length - 1 do
      list[#list + 1] = arr[i]
    end
  end
  return list
end

-- このエディタ独自の「まとめて読み書きする」API があるか (無い環境では、seg を1個ずつ読み書きする)
local HAS_BULK_READ = Editor.GetNoteSlideBodyAll ~= nil
local HAS_BULK_WRITE = Editor.ReplaceNoteSlideBody ~= nil
local HAS_BULK_DELETE = Editor.DeleteNotes ~= nil

-- 「順番に選択」(Order ボタン) でタップした順のノーツ。この機能が無い環境では空
local function orderNotes()
  if Editor.GetOrderNotes == nil then return {} end
  return toList(Editor:GetOrderNotes())
end

local function clearOrder()
  if Editor.ClearOrderNotes ~= nil then Editor:ClearOrderNotes() end
end

-- スライド1本の seg を全部読む。戻り値は (平らな配列, seg の数)。
-- 平らな配列は「整数部, 分子, 分母, x」を seg の数だけ並べたもの
local function readSegs(note)
  if HAS_BULK_READ then
    -- 1回の往復で受け取る (seg を1個ずつ読むと、何万個もあるとき遅い)
    local flat = Editor:GetNoteSlideBodyAll(note)
    return flat, flat.Length
  end
  local flat = {}
  local o = 0
  local segCount = Editor:GetNoteSlideBodyCount(note)
  for k = 0, segCount - 1 do
    local b = readBeat(Editor:GetNoteSlideBodyBeat(note, k))
    flat[o + 1] = b[1]
    flat[o + 2] = b[2]
    flat[o + 3] = b[3]
    flat[o + 4] = Editor:GetNoteSlideBodyX(note, k)
    o = o + 4
  end
  return flat, segCount
end

-- ノーツの一覧から、スライドだけを読み出す。同じノーツは1回だけ。
-- 始点・x は数値にして持つ。seg は平らな配列 (flat) と seg の数 (cnt)。order = 一覧の中での位置
local function readSlides(notes)
  local list = {}
  local seen = {}
  for i = 1, #notes do
    local note = notes[i]
    if not seen[note] then
      seen[note] = true
      if Editor:GetNoteType(note) == SLIDE then
        local startBeat = readBeat(Editor:GetNoteBeat(note, true))
        local flat, cnt = readSegs(note)
        list[#list + 1] = {
          note = note,
          beat = startBeat,
          point = beatPoint(startBeat),
          x = Editor:GetNoteX(note),
          flat = flat,
          cnt = cnt,
          order = #list + 1
        }
      end
    end
  end
  return list
end

-- 始点 beat の早い順に並べる (同じ beat なら、一覧での並びのまま)
local function sortByStart(list)
  table.sort(list, function(a, b)
    if a.point ~= b.point then return a.point < b.point end
    return a.order < b.order
  end)
end

-- list から main を除いたもの
local function without(list, main)
  local out = {}
  for i = 1, #list do
    if list[i].note ~= main.note then out[#out + 1] = list[i] end
  end
  return out
end

-- 本体スライドの seg を out (平らな配列。seg が count 個) に置き換えて、本体以外のスライドを消す。「順番に選択」はリセットする
local function commit(main, out, count, slides)
  if HAS_BULK_WRITE then
    -- 並べ替えずに、1回の往復で丸ごと置き換える (beat が行ったり来たりする seg も、そのまま残る)
    Editor:ReplaceNoteSlideBody(main.note, out)
  else
    Editor:DeleteNoteSlideBody(main.note)
    -- 並べ替えずに、足した順のまま末尾に足す (beat が行ったり来たりする seg も、そのまま残る)
    local add = Editor.AppendNoteSlideBody ~= nil and Editor.AppendNoteSlideBody or Editor.AddNoteSlideBody
    local o = 0
    for i = 1, count do
      add(Editor, main.note, { beat = out[o + 1], numor = out[o + 2], denom = out[o + 3] })
      Editor:SetNoteSlideBodyX(main.note, i - 1, out[o + 4])
      o = o + 4
    end
  end
  local doomed = {}
  for i = 1, #slides do
    if slides[i] ~= main then doomed[#doomed + 1] = slides[i].note end
  end
  if HAS_BULK_DELETE then
    if #doomed > 0 then Editor:DeleteNotes(doomed) end
  else
    for i = 1, #doomed do Editor:DeleteNote(doomed[i]) end
  end
  clearOrder()
end

-- ---- 幹の通り道 ----

-- 幹の「通り道(骨格)」: beat が、それまでの最大より先へ進む seg だけを拾った、時系列順の折れ線。
-- head は point 0 / relX 0。idx = 元の seg の番号 (head は 0)。n = 点の数。
-- すでに枝が付いている幹でも、枝の周回(beat が戻る部分)は通り道に入らない。
-- 点ごとに表を作らず、point / relX / idx を別々の配列で持つ
local function buildSkeleton(flat, cnt)
  local sp, sx, si = { 0 }, { 0 }, { 0 }
  local n = 1
  local frontier = 0
  local o = 0
  for i = 1, cnt do
    local p = flat[o + 1] + flat[o + 2] / flat[o + 3]
    if p > frontier + EPS then
      n = n + 1
      sp[n] = p
      sx[n] = flat[o + 4]
      si[n] = i
      frontier = p
    end
    o = o + 4
  end
  return { point = sp, relX = sx, idx = si, n = n }
end

-- 幹の相対 x を、任意の point (相対 beat) で補間して求める
-- (通り道の point は先へ進む一方なので、target 以上になる最初の点を二分探索で探す)
local function getRelXAt(sk, target)
  local n = sk.n
  local sp, sx = sk.point, sk.relX
  if n == 1 then return sx[1] end
  if target <= sp[1] then return sx[1] end
  if target >= sp[n] then return sx[n] end
  local lo, hi = 2, n
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if sp[mid] >= target then hi = mid else lo = mid + 1 end
  end
  local p1, p2 = sp[lo - 1], sp[lo]
  if math.abs(p2 - p1) < EPS then return sx[lo] end
  local t = (target - p1) / (p2 - p1)
  return sx[lo - 1] + (sx[lo] - sx[lo - 1]) * t
end

-- 枝の周回を差し込む位置。「元の seg の slot 番目の直前」に入れる (segCount + 1 なら末尾)。
--   ・幹の途中            : その point を含む区間の、次に進む seg の直前
--                           (その手前に付いている既存の周回のあと)
--   ・幹の終点ちょうど    : 終点の seg の直後 (終点にぶら下がっている既存の周回の前)
--   ・幹の終点より未来    : 末尾 (既存の周回のあと)
local function findSlot(sk, point, segCount)
  local sp = sk.point
  -- point + EPS 以下の、いちばん後ろの点 (二分探索。無ければ 1)
  local k = 1
  local lo, hi = 1, sk.n
  local limit = point + EPS
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if sp[mid] <= limit then
      k = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  if k < sk.n then
    return sk.idx[k + 1]
  end
  if point > sp[k] + EPS then
    return segCount + 1
  end
  return sk.idx[k] + 1
end

-- 枝 1 本ぶんの周回を作る
local function makeLoop(main, br, sk, segCount)
  local flat, cnt = br.flat, br.cnt
  local offsetX = br.x - main.x
  local offsetBeat = beatDiff(br.beat, main.beat)   -- マイナスになることもある

  local lastBeat = { 0, 0, 1 }
  local endX = 0
  if cnt > 0 then
    local g = (cnt - 1) * 4
    lastBeat = { flat[g + 1], flat[g + 2], flat[g + 3] }
    endX = flat[g + 4]
  end

  -- 枝の中でいちばん遅い beat。ふつうは終点と同じ。
  -- すでに枝分かれ敷を使った枝は、終点より先まで周回していることがある。
  -- そのときは、いちばん遅い beat を幹との接続点にして、周回が幹の「未来」にはみ出さないようにする
  local topBeat = lastBeat
  local topPoint = beatPoint(lastBeat)
  local o = 0
  for j = 1, cnt do
    local p = flat[o + 1] + flat[o + 2] / flat[o + 3]
    if p > topPoint + EPS then
      topBeat = { flat[o + 1], flat[o + 2], flat[o + 3] }
      topPoint = p
    end
    o = o + 4
  end
  if topPoint < -EPS then
    topBeat = { 0, 0, 1 }
    topPoint = 0
  end
  local stub = topPoint > beatPoint(lastBeat) + EPS

  local attachBeat = beatAdd(offsetBeat, topBeat)
  local point = beatPoint(attachBeat)
  return {
    br = br,
    offsetX = offsetX,
    offsetBeat = offsetBeat,
    endX = offsetX + endX,
    attachBeat = attachBeat,
    point = point,
    trunkX = math.floor(getRelXAt(sk, point)),
    stub = stub,
    slot = findSlot(sk, point, segCount)
  }
end

-- 周回を out の o+1 以降に書き出して、書き終えた位置を返す (out は平らな配列。tmp は作業用の平らな配列)
-- 幹の上の枝の終点へ → 枝を逆走 → 枝の始点 → 枝を順行 → 幹へ戻る
local function emitLoop(out, o, lp, tmp)
  local br = lp.br
  local flat, cnt = br.flat, br.cnt
  local ob, ox = lp.offsetBeat, lp.offsetX
  local obm, obn, obd = ob[1], ob[2], ob[3]
  local ab = lp.attachBeat
  local abm, abn, abd = ab[1], ab[2], ab[3]
  local trunkX, endX = lp.trunkX, lp.endX
  local stub = lp.stub

  out[o + 1] = abm
  out[o + 2] = abn
  out[o + 3] = abd
  out[o + 4] = trunkX
  o = o + 4
  if stub then
    out[o + 1] = abm
    out[o + 2] = abn
    out[o + 3] = abd
    out[o + 4] = endX
    o = o + 4
  end

  -- 枝の点は、逆走でも順行でも同じ位置なので、1回だけ計算して tmp に置く
  local t = 0
  local f = 0
  for j = 1, cnt do
    beatAddInto(tmp, t, obm, obn, obd, flat[f + 1], flat[f + 2], flat[f + 3])
    tmp[t + 4] = ox + flat[f + 4]
    t = t + 4
    f = f + 4
  end

  -- 枝を逆走
  t = (cnt - 1) * 4
  for j = cnt, 1, -1 do
    out[o + 1] = tmp[t + 1]
    out[o + 2] = tmp[t + 2]
    out[o + 3] = tmp[t + 3]
    out[o + 4] = tmp[t + 4]
    o = o + 4
    t = t - 4
  end

  -- 枝の始点
  out[o + 1] = obm
  out[o + 2] = obn
  out[o + 3] = obd
  out[o + 4] = ox
  o = o + 4

  -- 枝を順行
  t = 0
  for j = 1, cnt do
    out[o + 1] = tmp[t + 1]
    out[o + 2] = tmp[t + 2]
    out[o + 3] = tmp[t + 3]
    out[o + 4] = tmp[t + 4]
    o = o + 4
    t = t + 4
  end

  if stub then
    out[o + 1] = abm
    out[o + 2] = abn
    out[o + 3] = abd
    out[o + 4] = endX
    o = o + 4
  end
  out[o + 1] = abm
  out[o + 2] = abn
  out[o + 3] = abd
  out[o + 4] = trunkX
  return o + 4
end

-- 幹の seg 列に、枝の周回を差し込んだ新しい seg 列 (平らな配列) と、その seg の数を作る
-- 元の seg は、並びも中身もそのまま (すでに付いている枝の周回も含めて) 残る
local function buildNewSegs(main, branches)
  local flat, segCount = main.flat, main.cnt
  local sk = buildSkeleton(flat, segCount)
  local trunkEnd = sk.point[sk.n]

  local loops = {}
  local needCap = false
  for i = 1, #branches do
    local lp = makeLoop(main, branches[i], sk, segCount)
    lp.seq = i
    loops[#loops + 1] = lp
    if segCount > 0 and lp.point > trunkEnd + EPS then needCap = true end
  end

  -- 差し込み位置の順。同じ位置なら、幹の上で早いほうから
  table.sort(loops, function(a, b)
    if a.slot ~= b.slot then return a.slot < b.slot end
    if math.abs(a.point - b.point) > EPS then return a.point < b.point end
    return a.seq < b.seq
  end)

  local out = {}
  local tmp = {}
  local o = 0
  local f = 0
  local li = 1
  for i = 1, segCount + 1 do
    while li <= #loops and loops[li].slot == i do
      o = emitLoop(out, o, loops[li], tmp)
      li = li + 1
    end
    if i <= segCount then
      out[o + 1] = flat[f + 1]
      out[o + 2] = flat[f + 2]
      out[o + 3] = flat[f + 3]
      out[o + 4] = flat[f + 4]
      o = o + 4
      f = f + 4
    end
  end
  -- 枝が幹の終点より未来にあるときは、最後に元の終点で蓋をする
  if needCap then
    local g = (segCount - 1) * 4
    out[o + 1] = flat[g + 1]
    out[o + 2] = flat[g + 2]
    out[o + 3] = flat[g + 3]
    out[o + 4] = flat[g + 4]
    o = o + 4
  end
  return out, o / 4
end

local function mergeBranches(main, branches)
  local out, count = buildNewSegs(main, branches)
  local all = { main }
  for _, br in ipairs(branches) do all[#all + 1] = br end
  commit(main, out, count, all)
end

function Run()
  local orderList = orderNotes()
  local main
  local branches
  if #orderList >= 2 then
    -- 手動: 「順番に選択」で選んだスライドのうち、始点がいちばん早いものが幹 (同じ beat なら選んだ順の早いほう)
    local slides = readSlides(orderList)
    sortByStart(slides)
    main = slides[1]
    branches = {}
    for i = 2, #slides do branches[#branches + 1] = slides[i] end
  else
    local selected = readSlides(toList(Editor:GetSelectNotes()))
    sortByStart(selected)
    if #orderList == 1 then
      -- 自動: 「順番に選択」の1本が幹。選択中のほかのスライドが枝 (始点 beat の早い順)
      local ordered = readSlides(orderList)
      if #ordered == 0 then
        Editor:ShowTip('本体のスライドが見つかりません')
        return
      end
      main = ordered[1]
      branches = without(selected, main)
    else
      -- 「順番に選択」なし: 選択中のスライド。いちばん始点が早いものが幹
      main = selected[1]
      branches = {}
      for i = 2, #selected do branches[#branches + 1] = selected[i] end
    end
  end
  if main == nil or #branches < 1 then
    Editor:ShowTip('スライドを2本以上選んでください（本体 + 装飾。「順番に選択」で本体を選び、LASSO で装飾を選んでもよい）')
    return
  end
  Editor:StartBatch()
  local ok, err = pcall(mergeBranches, main, branches)
  Editor:FinishBatch()
  if not ok then
    Editor:ShowTip('❌ 枝分かれ結合に失敗しました: ' .. tostring(err))
    return
  end
  Editor:ShowTip('✅ 枝分かれ結合: ' .. (#branches + 1) .. '本を処理しました')
end
"""##),
        Entry(fileName: "bm_ease.lua", source: ##"""
--BetterMalody built-in: ease effects (scroll / hs) between two values along a curve, from the cursor position
PluginName='BM Ease effects'
PluginType=0
PluginRequire="5.0.1"

local function mk(inf)   -- inf: ease-in 関数 → { In, Out, In-Out }
	return {
		function(t) return inf(t) end,
		function(t) return 1 - inf(1 - t) end,
		function(t) if t < 0.5 then return 0.5 * inf(2 * t) end return 1 - 0.5 * inf(2 * (1 - t)) end,
	}
end
local quad  = mk(function(t) return t * t end)
local cubic = mk(function(t) return t * t * t end)
local sine  = mk(function(t) return 1 - math.cos(t * math.pi / 2) end)
local expo  = mk(function(t) if t <= 0 then return 0 end return 2 ^ (10 * (t - 1)) end)
local circ  = mk(function(t) return 1 - math.sqrt(1 - t * t) end)
local CURVES = {
	{ 'Linear', function(t) return t end },
	{ 'Quad In', quad[1] }, { 'Quad Out', quad[2] }, { 'Quad In-Out', quad[3] },
	{ 'Cubic In', cubic[1] }, { 'Cubic Out', cubic[2] }, { 'Cubic In-Out', cubic[3] },
	{ 'Sine In', sine[1] }, { 'Sine Out', sine[2] }, { 'Sine In-Out', sine[3] },
	{ 'Expo In', expo[1] }, { 'Expo Out', expo[2] }, { 'Expo In-Out', expo[3] },
	{ 'Circ In', circ[1] }, { 'Circ Out', circ[2] }, { 'Circ In-Out', circ[3] },
}

local function parse(s)
	local f = {}
	for w in tostring(s):gmatch('[^,%s]+') do f[#f + 1] = w end
	local kind = 'scroll'
	if f[1] == 'scroll' or f[1] == 'hs' then kind = f[1]; table.remove(f, 1) end
	local v0, v1, len, div = tonumber(f[1]), tonumber(f[2]), tonumber(f[3]), tonumber(f[4]) or 16
	if not v0 or not v1 or not len or len <= 0 or div < 1 then return nil end
	return kind, v0, v1, len, math.floor(div)
end

local function apply(kind, v0, v1, len, div, curve)
	local n = math.floor(len * div + 0.5)
	if n < 1 then n = 1 end
	if n > 1000 then Editor:ShowMessage('Too many points (' .. n .. '). Max 1000: shorten the range or lower the points per beat') return end
	local start = Editor:GetCurrentBeat()
	local f = CURVES[curve][2]
	Editor:StartBatch()
	for i = 0, n do
		local t = i / n
		local v = v0 + (v1 - v0) * f(t)
		local b = Editor:BeatAdd(start, Editor:MakeBeat(i // div, i % div, div))
		Editor:AddEffect(b, kind, v)
	end
	Editor:FinishBatch()
	Editor:ShowMessage(string.format('%s: %d points, %g -> %g over %g beats (%s)', kind, n + 1, v0, v1, n / div, CURVES[curve][1]))
end

function Run()
	local def = 'scroll, 1, 0.5, 4, 16'
	if tostring(Editor:ChartInfo('mode')) == '5' then def = 'hs, 1, 0.5, 4, 16' end   -- Taiko は hs を使う
	Editor:GetUserInput('Ease effects from the cursor.  [scroll|hs], start, end, length(beats), points per beat\n e.g.  ' .. def, def,
		function(s)
			local kind, v0, v1, len, div = parse(s)
			if not kind then Editor:ShowMessage('Invalid input. Example: scroll, 1, 0.5, 4, 16') return end
			local names = {}
			for i, c in ipairs(CURVES) do names[i] = c[1] end
			Editor:GetUserOption('Curve', names, function(idx)
				apply(kind, v0, v1, len, div, (idx or 0) + 1)
			end)
		end)
end
"""##),
        Entry(fileName: "bm_img2hold.lua", source: ##"""
--BetterMalody built-in: img2hold (Slide) - turn an image into a field of 1-wide holds
-- Same idea as the web Slide editor's img2hold: the image is stretched to 256 (x) by height (ticks), every vertical run of dark pixels becomes one hold.
-- The first row of ticks starts at the current beat (move the cursor to where the picture should start).
-- Image source: Photos app or Files app.  After picking, a preview shows the resized black/white result
-- (length / ticks-per-beat / threshold / invert can be changed while looking at it).  The preview needs Editor:ShowImagePreview
-- (this editor only); other editors fall back to typing "length ticks threshold invert".
PluginName='BM Image to holds (img2hold)'
PluginType=0
PluginRequire="5.0.1"

local HELP = 'length(beats) ticks-per-beat threshold(0-255) invert(0/1)\n e.g. "4 32 128 0"  (dark pixels = holds)'

local function beat_of(t, ompu) return { beat = t // ompu, numor = t % ompu, denom = ompu } end

-- add one 1-wide hold: head tick (absolute, in 1/ompu beats), x (0-255), duration in ticks
local function add_hold(head, x, dur, ompu)
	local id = Editor:AddNote(2048)
	Editor:SetNoteBeat(id, beat_of(head, ompu), true)
	Editor:SetNoteX(id, x)
	Editor:SetNoteWidth(id, 1)
	Editor:AddNoteSlideBody(id, beat_of(dur, ompu))
	return id
end

local function build(mode, bytes, len, ompu, shiki, inv)
	local cb = Editor:GetCurrentBeat()
	local base = math.floor((cb.beat + cb.numor / cb.denom) * ompu + 0.5)
	local h = math.floor(len * ompu + 0.5)
	if h < 1 then Editor:ShowMessage('Length is too short') return end
	local W = 256
	local count = 0
	if mode == 1 or mode == 2 then      -- ignore the image: one hold at x=0, or every lane
		local dur = math.max(1, h)
		local from, to = 0, 0
		if mode == 2 then to = W - 1 end
		for x = from, to do add_hold(base, x, dur, ompu) count = count + 1 end
	else
		local gray = Editor:DecodeImage(bytes, W, h)
		if not gray then Editor:ShowMessage('Could not read the image') return end
		local byte = string.byte
		for x = 0, W - 1 do
			local runStart, runEnd = nil, nil            -- rows (from the top) of the current run, scanning bottom to top
			for i = h - 1, -1, -1 do
				local dark = false
				if i >= 0 then
					local v = byte(gray, i * W + x + 1)
					dark = (v < shiki)
					if inv then dark = not dark end
				end
				if dark then
					if not runStart then runStart = i end
					runEnd = i
				elseif runStart then
					local head = (h - runStart) - 1 + base
					local d = runStart - runEnd
					if d < 1 then d = 1 end
					add_hold(head, x, d, ompu) count = count + 1
					runStart = nil
				end
			end
		end
	end
	if count == 0 then Editor:ShowMessage('No dark pixels found (try the threshold or invert)') return end
	Editor:ShowMessage('Added ' .. count .. ' holds')
end

local function ask_params(mode, bytes)
	if mode ~= 0 then
		Editor:GetUserInput('length(beats) ticks-per-beat\n e.g. "4 32"', '4 32', function(s)
			local len, ompu = s:match('^%s*([%d%.]+)%s+(%d+)')
			len, ompu = tonumber(len), tonumber(ompu)
			if not len or not ompu or ompu < 1 then Editor:ShowMessage('Bad input') return end
			build(mode, nil, len, math.floor(ompu), 128, false)
		end)
		return
	end
	-- preview dialog: look at the resized result while changing length / ticks / threshold / invert
	if Editor.ShowImagePreview then
		Editor:ShowImagePreview('Preview', bytes, 4, 32, 128, false, function(len, ompu, shiki, inv)
			if not len or not ompu or ompu < 1 then Editor:ShowMessage('Bad input') return end
			build(0, bytes, len, math.floor(ompu), shiki, inv)
		end)
		return
	end
	-- editors without the preview: type the numbers
	Editor:GetUserInput(HELP, '4 32 128 0', function(s)
		local a, b, c, d = s:match('^%s*([%d%.]+)%s+(%d+)%s+(%d+)%s*(%d*)')
		local len, ompu, shiki = tonumber(a), tonumber(b), tonumber(c)
		if not len or not ompu or not shiki or ompu < 1 then Editor:ShowMessage('Bad input') return end
		build(0, bytes, len, math.floor(ompu), shiki, d == '1')
	end)
end

-- source: 'photo' = Photos app, 'file' = Files app  (the 3rd argument is ignored by editors that do not know it -> Files app)
local function pick_image(source)
	Editor:ReadBytesSelect('Choose an image', function(bytes)
		if not bytes then return end
		ask_params(0, bytes)
	end, source)
end

function Run()
	Editor:GetUserOption('img2hold', {
		'Image to holds - from Photos (写真)',
		'Image to holds - from Files (ファイル)',
		'One hold at x=0 (no image)',
		'Fill every lane with holds (no image)'
	}, function(sel)
		if sel == 0 then
			pick_image('photo')
		elseif sel == 1 then
			pick_image('file')
		else
			ask_params(sel - 1, nil)        -- 2 -> mode 1 (one hold), 3 -> mode 2 (every lane)
		end
	end)
end
"""##),
        Entry(fileName: "bm_select.lua", source: ##"""
--BetterMalody built-in: select notes by a filter (type / lane / x / width / beat range)
PluginName='BM Select by filter'
PluginType=0
PluginRequire="5.0.1"

-- terms (AND).  A term is  name[,name...]  (OR)  or  key=list  (list: 1,3,5-7)
--  Key/Taiko: tap long | Slide: wipe slide | Taiko: don ka big small roll balloon
--  lane=1,3 (Key, 1-based)   x=10-50 (Slide)   w=3-8 (Slide width)   beat=4-8 (head beat)
--  a leading ! negates a term
local HELP = 'Filter terms (all must match):\n tap long | wipe slide | don ka big small roll balloon\n lane=1,3 | x=10-50 | w=3-8 | beat=4-8   ( ! = not )\n e.g.  long lane=1,2'

local function inlist(v, list)
	for part in tostring(list):gmatch('[^,]+') do
		local a, b = part:match('^(-?[%d%.]+)%-(-?[%d%.]+)$')
		if a then if v >= tonumber(a) and v <= tonumber(b) then return true end
		elseif tonumber(part) == v then return true end
	end
	return false
end
local NAMES = {
	tap = function(n) return n.type == 1 end, long = function(n) return n.type == 128 end,
	wipe = function(n) return n.type == 1024 end, slide = function(n) return n.type == 2048 end,
	don = function(n) return n.flag == 0 or n.flag == 1 end, ka = function(n) return n.flag == 2 or n.flag == 3 end,
	big = function(n) return n.flag == 1 or n.flag == 3 or n.flag == 5 or n.flag == 7 end,
	small = function(n) return n.flag == 0 or n.flag == 2 or n.flag == 4 or n.flag == 6 end,
	roll = function(n) return n.flag == 4 or n.flag == 5 end, balloon = function(n) return n.flag == 6 or n.flag == 7 end,
}
local function compile(s)
	local terms = {}
	for w in tostring(s):gmatch('%S+') do
		local neg = false
		if w:sub(1, 1) == '!' then neg = true; w = w:sub(2) end
		local k, v = w:match('^(%a+)=(.+)$')
		local fn
		if k then
			if k == 'lane' then fn = function(n) return inlist(n.x + 1, v) end
			elseif k == 'x' then fn = function(n) return inlist(n.x, v) end
			elseif k == 'w' then fn = function(n) return inlist(n.w, v) end
			elseif k == 'beat' then fn = function(n) return inlist(n.beat, v) end end
		else
			local alts = {}
			for name in w:gmatch('[^,]+') do alts[#alts + 1] = NAMES[name:lower()] end
			for _, a in ipairs(alts) do if not a then alts = nil break end end
			if alts and #alts > 0 then fn = function(n) for _, a in ipairs(alts) do if a(n) then return true end end return false end end
		end
		if not fn then return nil, w end
		terms[#terms + 1] = neg and function(n) return not fn(n) end or fn
	end
	if #terms == 0 then return nil, '' end
	return terms
end
local function info(id)
	local b = Editor:GetNoteBeat(id, true)
	return { id = id, type = Editor:GetNoteType(id), flag = Editor:GetNoteFlag(id), x = Editor:GetNoteX(id), w = Editor:GetNoteWidth(id), beat = b.beat + b.numor / b.denom }
end
local function match(n, terms)
	for _, t in ipairs(terms) do if not t(n) then return false end end
	return true
end

function Run()
	Editor:GetUserInput(HELP, '', function(s)
		local terms, bad = compile(s)
		if not terms then Editor:ShowMessage('Unknown term: "' .. tostring(bad) .. '"') return end
		Editor:GetUserOption('Apply', { 'Replace selection', 'Add to selection', 'Keep only (narrow selection)' }, function(mode)
			local ids = {}
			if mode == 2 then
				local sel = Editor:GetSelectNotes()
				for i = 0, sel.Length - 1 do ids[#ids + 1] = sel[i] end
			else
				for i = 0, Editor:GetNoteCount() - 1 do ids[#ids + 1] = Editor:GetNoteAt(i) end
			end
			local hit = {}
			for _, id in ipairs(ids) do if match(info(id), terms) then hit[#hit + 1] = id end end
			if mode ~= 1 then Editor:ClearSelection() end
			for _, id in ipairs(hit) do Editor:SelectNote(id) end
			Editor:ShowMessage('Selected ' .. #hit .. ' note(s)')
		end)
	end)
end
"""##)
    ]
}
