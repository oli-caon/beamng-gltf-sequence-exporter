local M = {}

local frameTime = 1 / 30
local startFrame = 1
local endFrame = 100

local playbackSpeedMultiplier = 2

local totalReplaySeconds = 1

local animationLength = 0

local i = nil
local filenamePrefix = ""
local filenameTemplate = "%05d.glb"

local enabled = false
local isExporting = false

local _log = log
local function log(level, msg)
	_log(level, 'gltfSequenceExporterApp', msg)
end

local function setStartFrame(val)
	startFrame = val
	i = startFrame
end

local function setEndFrame(val)
	endFrame = val
end

local function setTotalReplaySeconds(val)
	totalReplaySeconds = val
end

local function startExport()
	animationLength = endFrame - startFrame + 1
	if animationLength <= 0 then
		-- Fix for single frame animations
		animationLength = 1
	end

	Engine.Platform.taskbarSetProgressState(1)
	
	local fileExt = (gltfSequenceExporter_export.gltfBinaryFormat) and '.glb' or '.gltf'
	filenamePrefix = filenamePrefix:gsub("%%", "")	-- clean before string formatting
	filenameTemplate = filenamePrefix .. "%05d" .. fileExt

	-- seek() only changes position by 1 second intervals, rounding up.
	-- Work around by seeking to the nearest second before the start frame.
	local desiredFrame = startFrame - 1
	local startTime = desiredFrame * frameTime
	core_replay.seek(math.floor(startTime) / totalReplaySeconds) -- position scaled from 0 to 1

	log('D', string.format("Export enabled, startFrame = %d, endFrame = %d", startFrame, endFrame))
	guihooks.message("glTF sequence export started.", 5, "gltfSequenceExporterApp", "movie_filter")
	enabled = true
	core_replay.pause(false)

	-- slow down playback to improve frame pacing accuracy of exported frames
	core_replay.setSpeed(frameTime * playbackSpeedMultiplier)
end

local function onFinished()
	Engine.Platform.taskbarSetProgress(1.0)
	enabled = false
	log('I', "Export disabled")
	core_replay.setSpeed(1)
	core_replay.pause(true)
	guihooks.trigger("AnimationExportEnd")
	Engine.Platform.taskbarSetProgressState(0)
end

local function cancelExport()
	onFinished()
	guihooks.message("glTF sequence export cancelled.", 5, "gltfSequenceExporterApp", "movie")
end

local function setFrameRate(frameRate)
	frameTime = 1 / frameRate
end

-- Pauses the replay at each frame, exports it, resumes and waits for next frame
local function onUpdate(dtReal, dtSim, dtRaw)
	if not enabled then return end

	if (i >= startFrame) and (i <= endFrame) then
		local positionSeconds = core_replay.getPositionSeconds()
		if positionSeconds >= (frameTime * i) and (positionSeconds <= (frameTime * (i + 1))) then
			core_replay.pause(true)

			-- Ensure we only export each frame once
			if not isExporting then
				isExporting = true

				Engine.Platform.taskbarSetProgressState(2)
				Engine.Platform.taskbarSetProgress((i - startFrame + 1) / animationLength)

				local filename = string.format(filenameTemplate, i)

				-- Use this to avoid creating any files while testing
				if M.DEBUG_DRY_RUN_EXPORT then
					log('D', string.format("Dry run: exported '%s' at %.3f ", filename, positionSeconds))
				else
					gltfSequenceExporter_export.exportFile(filename)
					log('I', string.format("exported '%s' at %.3f", filename, positionSeconds))
					guihooks.message("Exported frame " .. dumps(filename), 5, "gltfSequenceExporterApp", "bug_report")
				end

				if M.DEBUG_FRAME_PACING then
					log('D', string.format("frametime error %.5f", positionSeconds / frameTime - i))
				end

				i = i + 1
				isExporting = false
			end
			core_replay.pause(false)
		end
	else
		onFinished()
		guihooks.message(
			string.format("glTF sequence export completed (%d frames).", animationLength),
			5,
			"gltfSequenceExporterApp",
			"movie"
		)
	end
end

local function openDirectory(filenamePrefix)
	filenamePrefix = filenamePrefix:gsub("%%", "")

	local function getParentPath(str)
		return str:match("(.*)/") or "/"
	end

	local path = getParentPath(filenamePrefix)

	-- Go up a directory until we get a path that will open in the user folder.
	-- Need to do this to prevent exploreFolder from opening the game install
	--  folder if the suggested path doesn't exist yet.
	while isOfficialContent(FS:getFileRealPath(path)) do
		path = getParentPath(path)
	end

	log('D', string.format("Opening folder '%s' (supplied filename '%s').", dumps(path), dumps(filenamePrefix)))

	-- Trailing slash opens the folder instead of just focusing it.
	Engine.Platform.exploreFolder(path.."/")
end

local function setFilenamePrefix(filename)
	filenamePrefix = filename
end

local function suggestFilenamePrefix()
	local playerVehicle = getPlayerVehicle(0)
	if not playerVehicle then
		return ''
	end

	return playerVehicle:getPath() .. 'export_frame_'
end

M.onUpdate = onUpdate

M.startExport = startExport
M.cancelExport = cancelExport

M.setStartFrame = setStartFrame
M.setEndFrame = setEndFrame
M.setFilenamePrefix = setFilenamePrefix
M.suggestFilenamePrefix = suggestFilenamePrefix

M.setTotalReplaySeconds = setTotalReplaySeconds

M.setFrameRate = setFrameRate

M.openDirectory = openDirectory

M.DEBUG_DRY_RUN_EXPORT = false
M.DEBUG_FRAME_PACING = false

return M
