import Foundation

// ============================================================
// アプリに内蔵しているプラグイン。
//   ・quad_InOut / quad_OutIn / join_slides_fixed: 添付された Malody V 用 Lua プラグインをそのまま収録
//   ・join_end_to_start / fold_join / branch_join: editor.html の「終点と始点を繋げる」「折り返し敷」「枝分かれ敷」を Lua にしたもの
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
]]
PluginName='終点と始点を繋げる'
PluginMode=7
PluginType=0

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

local function capBeat(m, n, d)
  if d <= 0 then d = 1 end
  if d <= MAX_BEAT_DEN then
    if n == 0 then return { m, 0, 1 } end
    local g = gcd(n, d)
    return { m, n / g, d / g }
  end
  local newNum = math.floor(n / d * MAX_BEAT_DEN + 0.5)
  if newNum >= MAX_BEAT_DEN then
    m = m + 1
    newNum = 0
  end
  if newNum == 0 then return { m, 0, 1 } end
  local g = gcd(newNum, MAX_BEAT_DEN)
  return { m, newNum / g, MAX_BEAT_DEN / g }
end

local function copyBeat(b) return { b[1], b[2], b[3] } end

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

-- ---- エディタとのやりとり ----
local function readBeat(t)
  local d = t.denom
  if d == nil or d < 1 then d = 1 end
  return { t.beat or 0, t.numor or 0, d }
end

local function toBeatTable(b)
  return { beat = b[1], numor = b[2], denom = b[3] }
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

-- 「順番に選択」(Order ボタン) でタップした順のノーツ。この機能が無い環境では空
local function orderNotes()
  if Editor.GetOrderNotes == nil then return {} end
  return toList(Editor:GetOrderNotes())
end

local function clearOrder()
  if Editor.ClearOrderNotes ~= nil then Editor:ClearOrderNotes() end
end

-- ノーツの一覧から、スライドだけを読み出す。同じノーツは1回だけ。
-- 始点・x・seg の beat と x は、すべて数値にして持つ。order = 一覧の中での位置
local function readSlides(notes)
  local list = {}
  local seen = {}
  for i = 1, #notes do
    local note = notes[i]
    if not seen[note] then
      seen[note] = true
      if Editor:GetNoteType(note) == SLIDE then
        local segs = {}
        local segCount = Editor:GetNoteSlideBodyCount(note)
        for k = 0, segCount - 1 do
          segs[#segs + 1] = {
            beat = readBeat(Editor:GetNoteSlideBodyBeat(note, k)),
            x = Editor:GetNoteSlideBodyX(note, k)
          }
        end
        list[#list + 1] = {
          note = note,
          beat = readBeat(Editor:GetNoteBeat(note, true)),
          x = Editor:GetNoteX(note),
          segs = segs,
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
    local pa, pb = beatPoint(a.beat), beatPoint(b.beat)
    if pa ~= pb then return pa < pb end
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

-- 本体スライドの seg を newSeg に置き換えて、本体以外のスライドを消す。「順番に選択」はリセットする
local function commit(main, newSeg, slides)
  Editor:DeleteNoteSlideBody(main.note)
  -- 並べ替えずに、足した順のまま末尾に足す (beat が行ったり来たりする seg も、そのまま残る)
  local add = Editor.AppendNoteSlideBody ~= nil and Editor.AppendNoteSlideBody or Editor.AddNoteSlideBody
  for i = 1, #newSeg do
    local s = newSeg[i]
    add(Editor, main.note, toBeatTable(s.beat))
    Editor:SetNoteSlideBodyX(main.note, i - 1, s.x)
  end
  for i = 1, #slides do
    if slides[i] ~= main then
      Editor:DeleteNote(slides[i].note)
    end
  end
  clearOrder()
end

local function mergeSequential(ordered)
  local main = ordered[1]
  local newSeg = {}
  for i = 1, #ordered do
    local slide = ordered[i]
    local offsetX = slide.x - main.x
    local baseBeat = beatDiff(slide.beat, main.beat)
    if i > 1 then
      -- 前のスライドの終点 → このスライドの始点、を繋ぐ点
      newSeg[#newSeg + 1] = { beat = copyBeat(baseBeat), x = offsetX }
    end
    for j = 1, #slide.segs do
      local s = slide.segs[j]
      newSeg[#newSeg + 1] = { beat = beatAdd(s.beat, baseBeat), x = s.x + offsetX }
    end
  end
  commit(main, newSeg, ordered)
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
  mergeSequential(slides)
  Editor:FinishBatch()
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
]]
PluginName='折り返し敷'
PluginMode=7
PluginType=0

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

local function capBeat(m, n, d)
  if d <= 0 then d = 1 end
  if d <= MAX_BEAT_DEN then
    if n == 0 then return { m, 0, 1 } end
    local g = gcd(n, d)
    return { m, n / g, d / g }
  end
  local newNum = math.floor(n / d * MAX_BEAT_DEN + 0.5)
  if newNum >= MAX_BEAT_DEN then
    m = m + 1
    newNum = 0
  end
  if newNum == 0 then return { m, 0, 1 } end
  local g = gcd(newNum, MAX_BEAT_DEN)
  return { m, newNum / g, MAX_BEAT_DEN / g }
end

local function copyBeat(b) return { b[1], b[2], b[3] } end

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

-- ---- エディタとのやりとり ----
local function readBeat(t)
  local d = t.denom
  if d == nil or d < 1 then d = 1 end
  return { t.beat or 0, t.numor or 0, d }
end

local function toBeatTable(b)
  return { beat = b[1], numor = b[2], denom = b[3] }
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

-- 「順番に選択」(Order ボタン) でタップした順のノーツ。この機能が無い環境では空
local function orderNotes()
  if Editor.GetOrderNotes == nil then return {} end
  return toList(Editor:GetOrderNotes())
end

local function clearOrder()
  if Editor.ClearOrderNotes ~= nil then Editor:ClearOrderNotes() end
end

-- ノーツの一覧から、スライドだけを読み出す。同じノーツは1回だけ。
-- 始点・x・seg の beat と x は、すべて数値にして持つ。order = 一覧の中での位置
local function readSlides(notes)
  local list = {}
  local seen = {}
  for i = 1, #notes do
    local note = notes[i]
    if not seen[note] then
      seen[note] = true
      if Editor:GetNoteType(note) == SLIDE then
        local segs = {}
        local segCount = Editor:GetNoteSlideBodyCount(note)
        for k = 0, segCount - 1 do
          segs[#segs + 1] = {
            beat = readBeat(Editor:GetNoteSlideBodyBeat(note, k)),
            x = Editor:GetNoteSlideBodyX(note, k)
          }
        end
        list[#list + 1] = {
          note = note,
          beat = readBeat(Editor:GetNoteBeat(note, true)),
          x = Editor:GetNoteX(note),
          segs = segs,
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
    local pa, pb = beatPoint(a.beat), beatPoint(b.beat)
    if pa ~= pb then return pa < pb end
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

-- 本体スライドの seg を newSeg に置き換えて、本体以外のスライドを消す。「順番に選択」はリセットする
local function commit(main, newSeg, slides)
  Editor:DeleteNoteSlideBody(main.note)
  -- 並べ替えずに、足した順のまま末尾に足す (beat が行ったり来たりする seg も、そのまま残る)
  local add = Editor.AppendNoteSlideBody ~= nil and Editor.AppendNoteSlideBody or Editor.AddNoteSlideBody
  for i = 1, #newSeg do
    local s = newSeg[i]
    add(Editor, main.note, toBeatTable(s.beat))
    Editor:SetNoteSlideBodyX(main.note, i - 1, s.x)
  end
  for i = 1, #slides do
    if slides[i] ~= main then
      Editor:DeleteNote(slides[i].note)
    end
  end
  clearOrder()
end

local function mergeJoin(targets)
  local main = targets[1]
  local newSeg = {}
  for i = 1, #targets do
    local slide = targets[i]
    local offsetX = slide.x - main.x
    local baseBeat = beatDiff(slide.beat, main.beat)
    local segs = slide.segs
    if (i - 1) % 2 == 0 then
      if i > 1 then
        newSeg[#newSeg + 1] = { beat = copyBeat(baseBeat), x = offsetX }
      end
      for j = 1, #segs do
        local s = segs[j]
        newSeg[#newSeg + 1] = { beat = beatAdd(s.beat, baseBeat), x = s.x + offsetX }
      end
    else
      for j = #segs, 1, -1 do
        local s = segs[j]
        newSeg[#newSeg + 1] = { beat = beatAdd(s.beat, baseBeat), x = s.x + offsetX }
      end
      newSeg[#newSeg + 1] = { beat = copyBeat(baseBeat), x = offsetX }
    end
  end
  commit(main, newSeg, targets)
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
  mergeJoin(targets)
  Editor:FinishBatch()
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
    ・「順番に選択」を使わず、LASSO などでスライドを2本以上選ぶ → 始点がいちばん早いスライドが幹
  境目の beat が重複しても、そのまま残す (バグスライドを許す)。
]]
PluginName='枝分かれ敷'
PluginMode=7
PluginType=0

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

local function capBeat(m, n, d)
  if d <= 0 then d = 1 end
  if d <= MAX_BEAT_DEN then
    if n == 0 then return { m, 0, 1 } end
    local g = gcd(n, d)
    return { m, n / g, d / g }
  end
  local newNum = math.floor(n / d * MAX_BEAT_DEN + 0.5)
  if newNum >= MAX_BEAT_DEN then
    m = m + 1
    newNum = 0
  end
  if newNum == 0 then return { m, 0, 1 } end
  local g = gcd(newNum, MAX_BEAT_DEN)
  return { m, newNum / g, MAX_BEAT_DEN / g }
end

local function copyBeat(b) return { b[1], b[2], b[3] } end

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

-- ---- エディタとのやりとり ----
local function readBeat(t)
  local d = t.denom
  if d == nil or d < 1 then d = 1 end
  return { t.beat or 0, t.numor or 0, d }
end

local function toBeatTable(b)
  return { beat = b[1], numor = b[2], denom = b[3] }
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

-- 「順番に選択」(Order ボタン) でタップした順のノーツ。この機能が無い環境では空
local function orderNotes()
  if Editor.GetOrderNotes == nil then return {} end
  return toList(Editor:GetOrderNotes())
end

local function clearOrder()
  if Editor.ClearOrderNotes ~= nil then Editor:ClearOrderNotes() end
end

-- ノーツの一覧から、スライドだけを読み出す。同じノーツは1回だけ。
-- 始点・x・seg の beat と x は、すべて数値にして持つ。order = 一覧の中での位置
local function readSlides(notes)
  local list = {}
  local seen = {}
  for i = 1, #notes do
    local note = notes[i]
    if not seen[note] then
      seen[note] = true
      if Editor:GetNoteType(note) == SLIDE then
        local segs = {}
        local segCount = Editor:GetNoteSlideBodyCount(note)
        for k = 0, segCount - 1 do
          segs[#segs + 1] = {
            beat = readBeat(Editor:GetNoteSlideBodyBeat(note, k)),
            x = Editor:GetNoteSlideBodyX(note, k)
          }
        end
        list[#list + 1] = {
          note = note,
          beat = readBeat(Editor:GetNoteBeat(note, true)),
          x = Editor:GetNoteX(note),
          segs = segs,
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
    local pa, pb = beatPoint(a.beat), beatPoint(b.beat)
    if pa ~= pb then return pa < pb end
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

-- 本体スライドの seg を newSeg に置き換えて、本体以外のスライドを消す。「順番に選択」はリセットする
local function commit(main, newSeg, slides)
  Editor:DeleteNoteSlideBody(main.note)
  -- 並べ替えずに、足した順のまま末尾に足す (beat が行ったり来たりする seg も、そのまま残る)
  local add = Editor.AppendNoteSlideBody ~= nil and Editor.AppendNoteSlideBody or Editor.AddNoteSlideBody
  for i = 1, #newSeg do
    local s = newSeg[i]
    add(Editor, main.note, toBeatTable(s.beat))
    Editor:SetNoteSlideBodyX(main.note, i - 1, s.x)
  end
  for i = 1, #slides do
    if slides[i] ~= main then
      Editor:DeleteNote(slides[i].note)
    end
  end
  clearOrder()
end

-- 幹の相対 x を、任意の point (相対 beat) で補間して求める
local function getRelXAt(mainPoints, target)
  local n = #mainPoints
  if n == 1 then return mainPoints[1].relX end
  if target <= mainPoints[1].point then return mainPoints[1].relX end
  if target >= mainPoints[n].point then return mainPoints[n].relX end
  for i = 1, n - 1 do
    local p1, p2 = mainPoints[i], mainPoints[i + 1]
    if p1.point <= target and target <= p2.point then
      if math.abs(p2.point - p1.point) < EPS then return p2.relX end
      local t = (target - p1.point) / (p2.point - p1.point)
      return p1.relX + (p2.relX - p1.relX) * t
    end
  end
  return mainPoints[n].relX
end

local function mergeBranches(main, branches)
  -- 幹 seg: 折り返し (point が逆行) より前の有効な部分だけを切り出す
  local original = main.segs
  local effective = {}
  local prev = 0
  for i = 1, #original do
    local p = beatPoint(original[i].beat)
    if p < prev - EPS then break end
    effective[#effective + 1] = original[i]
    prev = p
  end

  local mainPoints = { { point = 0, relX = 0 } }
  for i = 1, #effective do
    mainPoints[#mainPoints + 1] = { point = beatPoint(effective[i].beat), relX = effective[i].x }
  end

  local events = {}
  local seq = 0
  local mainLast = nil
  local mainLastPoint = 0
  if #effective > 0 then
    mainLast = effective[#effective]
    mainLastPoint = beatPoint(mainLast.beat)
    for i = 1, #effective - 1 do
      local s = effective[i]
      seq = seq + 1
      events[#events + 1] = { kind = 'main_seg', point = beatPoint(s.beat), beat = s.beat, x = s.x, seq = seq }
    end
  end

  for _, br in ipairs(branches) do
    local offsetX = br.x - main.x
    local offsetBeat = beatDiff(br.beat, main.beat)
    local lastSegBeat = { 0, 0, 1 }
    if #br.segs > 0 then lastSegBeat = br.segs[#br.segs].beat end
    local endRelBeat = beatAdd(offsetBeat, lastSegBeat)
    local endRelPoint = beatPoint(endRelBeat)
    local trunkRelX = math.floor(getRelXAt(mainPoints, endRelPoint))
    seq = seq + 1
    events[#events + 1] = {
      kind = 'branch_insert', point = endRelPoint, beat = endRelBeat, x = trunkRelX,
      segs = br.segs, offsetX = offsetX, offsetBeat = offsetBeat, seq = seq
    }
  end

  -- point の昇順。同じ point なら幹の seg を先に
  table.sort(events, function(a, b)
    local d = a.point - b.point
    if math.abs(d) > EPS then return d < 0 end
    if a.kind ~= b.kind then return a.kind == 'main_seg' end
    return a.seq < b.seq
  end)

  local newSeg = {}
  local currentPoint = 0
  for _, ev in ipairs(events) do
    if ev.kind == 'main_seg' then
      newSeg[#newSeg + 1] = { beat = copyBeat(ev.beat), x = ev.x }
      currentPoint = ev.point
    else
      -- 幹の上の枝の終点へ → 枝を逆走 → 枝の始点 → 枝を順行 → 幹へ戻る
      newSeg[#newSeg + 1] = { beat = copyBeat(ev.beat), x = ev.x }
      for j = #ev.segs, 1, -1 do
        local s = ev.segs[j]
        newSeg[#newSeg + 1] = { beat = beatAdd(ev.offsetBeat, s.beat), x = ev.offsetX + s.x }
      end
      newSeg[#newSeg + 1] = { beat = copyBeat(ev.offsetBeat), x = ev.offsetX }
      for j = 1, #ev.segs do
        local s = ev.segs[j]
        newSeg[#newSeg + 1] = { beat = beatAdd(ev.offsetBeat, s.beat), x = ev.offsetX + s.x }
      end
      newSeg[#newSeg + 1] = { beat = copyBeat(ev.beat), x = ev.x }
      currentPoint = ev.point
    end
  end

  -- 枝が幹の終点より未来にあるとき: 幹を逆走して戻す
  if mainLast ~= nil and currentPoint > mainLastPoint then
    for i = #events, 1, -1 do
      local ev = events[i]
      if ev.kind == 'main_seg' and ev.point <= currentPoint and ev.point > mainLastPoint then
        newSeg[#newSeg + 1] = { beat = copyBeat(ev.beat), x = ev.x }
      end
    end
  end
  -- 最後に幹の終点で蓋をする
  if mainLast ~= nil then
    newSeg[#newSeg + 1] = { beat = copyBeat(mainLast.beat), x = mainLast.x }
  end
  -- 元の折り返し部分 (有効範囲の外) は、そのまま末尾へ
  for i = #effective + 1, #original do
    newSeg[#newSeg + 1] = { beat = copyBeat(original[i].beat), x = original[i].x }
  end

  local all = { main }
  for _, br in ipairs(branches) do all[#all + 1] = br end
  commit(main, newSeg, all)
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
  mergeBranches(main, branches)
  Editor:FinishBatch()
  Editor:ShowTip('✅ 枝分かれ結合: ' .. (#branches + 1) .. '本を処理しました')
end
"""##)
    ]
}
