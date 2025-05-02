-- @description IntelliChorus Recorder (Accessible & Modular Edition)
-- @version 1.0
-- @author Uniqueboy
-- @changelog
--   + Initial release: All-in-one prompt (9 inputs)
--   + Supports auto-punch, track grouping, muting, saving, delayed call, and screen reader feedback
-- @about
--   IntelliChorus Recorder automates the recording of chorus layers with punch-in logic,
--   automatic track creation, naming, panning, folder grouping, and spoken feedback.
--   Designed to be fully accessible for screen reader users like NVDA with OSARA.
--   Created by Uniqueboy from Unique Creators.
-- @provides
--   [main] IntelliChorus Recorder/IntelliChorus Recorder.lua
-- IntelliChorus Recorder/help.pdf
-- IntelliChorus Recorder/readme.md
-- @link https://github.com/UniqueCreators/scripts

if _G.__INTELLICHORUS_RUNNING__ then
  reaper.ShowMessageBox("IntelliChorus Recorder is already running!", "Notice", 0)
  return
end
_G.__INTELLICHORUS_RUNNING__ = true

local inform = true

local function speak(text)
  if not inform then return end
  if reaper.osara_outputMessage then
    reaper.osara_outputMessage(text)
  else
    reaper.ShowConsoleMsg(text .. "\n")
  end
end

local function delayCall(ms, callback)
  local targetTime = reaper.time_precise() + (ms / 1000)
  local function loop()
    if reaper.time_precise() >= targetTime then
      callback()
    else
      reaper.defer(loop)
    end
  end
  reaper.defer(loop)
end

local originalRepeat
reaper.atexit(function()
  _G.__INTELLICHORUS_RUNNING__ = nil
  if originalRepeat == 1 then reaper.GetSetRepeat(1) end
end)

reaper.Undo_BeginBlock()

-- Validate time selection
local timeSelStart, timeSelEnd = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
if timeSelStart == timeSelEnd then
  reaper.ShowMessageBox("Set a time selection before recording.", "Error", 0)
  return
end

-- Unified prompt
local prompt = "Number of Tracks (1–50),Max Pan (1–100),Input Channel,Wrap Folder (yes/no),Mute Tracks after recording (yes/no),Count-In Once (yes/no),Save Project (yes/no),Track Name,Inform Me About Each Record (yes/no)"
local defaults = "4,50,1,yes,no,yes,no,Chorus,yes"
local ok, result = reaper.GetUserInputs("IntelliChorus Setup", 9, prompt, defaults)
if not ok then return end

-- Parse
local nStr, panStr, inStr, wrapStr, muteStr, countStr, saveStr, nameTemplate, informStr =
  result:match("([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)")

local trackCount = tonumber(nStr)
local maxPan = tonumber(panStr)
local inputChannel = tonumber(inStr)

local function validateYesNo(val, label)
  val = val:lower()
  if val ~= "yes" and val ~= "no" then
    reaper.ShowMessageBox("Invalid '" .. label .. "' (must be yes/no)", "Error", 0)
    return nil
  end
  return val == "yes"
end

-- Validations
if not trackCount or trackCount < 1 or trackCount > 50 then
  reaper.ShowMessageBox("Track count must be 1–50.", "Error", 0) return end
if not maxPan or maxPan < 1 or maxPan > 100 then
  reaper.ShowMessageBox("Max pan must be 1–100.", "Error", 0) return end
if not inputChannel or inputChannel < 1 or inputChannel > reaper.GetNumAudioInputs() then
  reaper.ShowMessageBox("Invalid input channel.", "Error", 0) return end
if not nameTemplate or nameTemplate:match("^%s*$") then
  reaper.ShowMessageBox("Track name cannot be empty.", "Error", 0) return end

local wrapFolder = validateYesNo(wrapStr, "Wrap Folder")
local mutePrevious = validateYesNo(muteStr, "Mute Previous")
local countInOnlyOnce = validateYesNo(countStr, "Count-In Once")
local saveAfter = validateYesNo(saveStr, "Save Project")
inform = validateYesNo(informStr, "Inform Me")

if wrapFolder == nil or mutePrevious == nil or countInOnlyOnce == nil or saveAfter == nil or inform == nil then return end

-- Save and disable repeat
originalRepeat = reaper.GetToggleCommandState(1068)
if originalRepeat == 1 then
  reaper.GetSetRepeat(0)
  reaper.ShowConsoleMsg("Repeat mode disabled.\n")
end

-- Enable metronome if off
if reaper.GetToggleCommandState(40364) == 0 then
  local met = reaper.ShowMessageBox("Metronome is OFF. Enable it?", "Metronome", 4)
  if met == 6 then reaper.Main_OnCommand(40364, 0) end
end

reaper.Main_OnCommand(1016, 0)
reaper.ClearConsole()
speak("IntelliChorus started...")

-- Optional folder
local folder = nil
if wrapFolder then
  reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
  folder = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
  reaper.GetSetMediaTrackInfo_String(folder, "P_NAME", "Chorus Folder", true)
  reaper.SetMediaTrackInfo_Value(folder, "I_FOLDERDEPTH", 1)
end

-- Pan logic
local function calculatePan(i)
  local half = math.ceil(trackCount / 2)
  local offset = math.floor((i - 1) / 2)
  local step = (maxPan / (half - 1)) * offset
  return i % 2 == 0 and step / 100 or -step / 100
end

-- Create tracks
local tracks = {}
for i = 1, trackCount do
  reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
  local t = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
  local name = nameTemplate .. " " .. i
  reaper.GetSetMediaTrackInfo_String(t, "P_NAME", name, true)
  reaper.SetMediaTrackInfo_Value(t, "D_PAN", calculatePan(i))
  reaper.SetMediaTrackInfo_Value(t, "I_RECINPUT", inputChannel - 1)
  reaper.SetMediaTrackInfo_Value(t, "I_RECMODE", 0)
  if wrapFolder and i == trackCount then
    reaper.SetMediaTrackInfo_Value(t, "I_FOLDERDEPTH", -1)
  end
  table.insert(tracks, t)
end

reaper.GetSetProjectInfo(0, "RECORD_MODE", 5, true)

-- Recording phase
local current = 1
local totalTracks = #tracks
local countInPlayed = false

function recordNext()
  if current > totalTracks then
    reaper.Main_OnCommand(40290, 0)
    reaper.Main_OnCommand(40289, 0)
    reaper.SetEditCurPos(timeSelStart, true, false)
    if saveAfter then reaper.Main_OnCommand(40026, 0) end
    speak("All takes recorded.")
    reaper.Undo_EndBlock("IntelliChorus: Inform Toggle Edition", -1)
    return
  end

  local t = tracks[current]
  local useCountIn = (not countInPlayed) or (not countInOnlyOnce)

  if useCountIn then
    reaper.Main_OnCommand(1016, 0)
  end

  reaper.PreventUIRefresh(1)
  reaper.Main_OnCommand(40290, 0)
  reaper.Main_OnCommand(40297, 0)
  reaper.SetMediaTrackInfo_Value(t, "I_SELECTED", 1)
  reaper.SetMediaTrackInfo_Value(t, "I_RECARM", 1)
  reaper.Main_OnCommand(40914, 0)
  reaper.PreventUIRefresh(-1)

  if mutePrevious and current > 1 then
    local prev = tracks[current - 1]
    reaper.SetMediaTrackInfo_Value(prev, "B_MUTE", 1)
  end

  reaper.defer(function()
    local nameOut = nameTemplate .. " " .. current
    delayCall(50, function()
      speak("Recording " .. nameOut)
    end)

    reaper.SetEditCurPos(timeSelStart, false, false)
    reaper.Main_OnCommand(1013, 0)
    reaper.Main_OnCommand(1017, 0)

    local function waitPlayEnd()
      if reaper.GetPlayState() == 0 then
        speak("Recording cancelled.")
        return
      end
      if reaper.GetPlayPosition() >= timeSelEnd then
        reaper.Main_OnCommand(1016, 0)
        reaper.SetMediaTrackInfo_Value(t, "I_RECARM", 0)
        countInPlayed = true
        current = current + 1
        reaper.defer(recordNext)
      else
        reaper.defer(waitPlayEnd)
      end
    end

    waitPlayEnd()
  end)
end

recordNext()
