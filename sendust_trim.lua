--  easy movie editor.. without AHK
-- 	Inspired from  https://github.com/aerobounce/trim.lua
--  
--  mpv script for fast movie editing.
--  Code managed by sendust. 2023/12/1
--  Require config file (config_trim.txt)
--  2024/1/23   Add number prefix for output     [1]_filename.mxf
--  2024/4/22   Add mp3 preset
--
--


-- #https://mpv.io/manual/master/#json-ipc
-- #commands: https://mpv.io/manual/master/#list-of-input-commands
-- #properties: https://mpv.io/manual/master/#properties
-- #events: https://mpv.io/manual/master/#list-of-events
-- https://github.com/mpv-player/mpv/wiki/User-Scripts
-- https://github.com/mpv-player/mpv/tree/master/TOOLS/lua
-- http://www.tcax.org/docs/ass-specs.htm
-- Lua String library       https://www.lua.org/pil/20.html


local io = require "io"
local utils = require "mp.utils"
local msg = require "mp.msg"
local assdraw = require "mp.assdraw"
local options = require "mp.options"
info = {tc="00:00:00.000", 
            smpte="00:00:00.00", 
            mark_in = 0,
            mark_out = 0,
			duration = 0,
            index = 1,
            last_job = "",
			path_target = "",
			name_target = "",
			last_msg = "",
            active_encoder={},
            active_encoder_str="",
            encoder_param = {copy = "-map 0:v -map 0:a -c:v copy -c:a copy -ignore_unknown -y",
                copy_A1 = "-map 0:v -map 0:a:0 -c:v copy -c:a copy -ignore_unknown -y", 
                h264 = "-map 0:v -map 0:a -ignore_unknown -pix_fmt yuv420p -c:v h264 -b:v 5500k -vf yadif=0:-1:0 -c:a aac -ac 2 -y -preset:v veryfast -movflags faststart",
                mp3 = "-vn -af loudnorm -ac 2 -c:a mp3 -b:a 256k -ignore_unknown -y"},
            encoder_key = "h264",
            encoder_extension = {copy = ".ts", copy_A1 = ".ts", h264 = ".mp4", mp3 = ".mp3"}}

local o = {
	default_enable = false}

    
    
options.read_options(o)

function remove_extension(filename)
	return filename:match("(.+)%..+$")
end

-- https://codereview.stackexchange.com/questions/90177/get-file-name-with-extension-and-get-only-extension
function GetFileName(url)
  return url:match("^.+/(.+)$")
end

function GetFileExtension(url)
  return url:match("^.+(%..+)$")
end


function join(sep, arr, count)
    local r = ""
    if count == nil then
        count = #arr
    end
    for i = 1, count do
        if i > 1 then
            r = r .. sep
        end
        r = r .. utils.to_string(arr[i])
    end
    return r
end

function all_trim(s)		-- trim non character from string left, right
	-- https://stackoverflow.com/questions/10460126/how-to-remove-spaces-from-a-string-in-lua
   return s:match( "^%s*(.-)%s*$" )
end


function showOsdAss(message)
    -- msg.log("info", message)
    ass = assdraw.ass_new()

    --ass:append(message)
    ass.text = message
	-- ass:pos(20, 50)
    -- mp.set_osd_ass(1, 1, "{\\c&H0000FF}" .. ass.text .. "{\\pos(100,80,1300,1300)}")
	mp.set_osd_ass(60, 40, message)

end


function split(str, sep)
   local result = {}
   local regex = ("([^%s]+)"):format(sep)
   for each in str:gmatch(regex) do
      table.insert(result, each)
   end
   return result
end


function sectotc(time_pos)
    local sign = ""
    if (time_pos < 0) then 
        sign = "-"
        time_pos = -1 * time_pos
    end
    local time_int = math.floor(time_pos)
    local frame_out = time_pos - time_int
    local hour_out = math.floor(time_int / 3600)
    local minute_out = math.floor((time_int - hour_out * 3600) / 60)
    local second_out = time_int - hour_out * 3600 - minute_out * 60
    local frame_string = string.sub(string.format("%.3f", frame_out), -3)
    return string.format("%s%02d:%02d:%02d.%s", sign, hour_out, minute_out, second_out, frame_string)
end


function sectosmpte(time_pos)
    local framerate = 29.97
    local frames = time_pos * framerate
    local sign = ""
	if (frames < 0) then
        frames = math.floor(frames - 0.5)
		sign = "-"
    else
        frames = math.floor(frames + 0.5)
        
    end
    
	local fps_int = math.floor(framerate + 0.5)
	local sizeBigCycle = 17982			-- every 10 minute, there is no tc drop
	local sizeWeeCycle = 1798			-- every  1 minute, there is tc drop
	local numBigCycles = math.floor(frames / sizeBigCycle)
	local tailFrames = frames - (numBigCycles * sizeBigCycle)

	if (tailFrames < (sizeWeeCycle + 2)) then
		numWeeCycles = 1
	else
		numWeeCycles = math.floor((tailFrames - 2) / sizeWeeCycle + 1)
    end

	local numSkips1 = numWeeCycles - 1
	local numSkips2 = numBigCycles * 9
	local numSkips3 = numSkips1 + numSkips2
	local framesSkipped = numSkips3 * 2
	local adjustedFrames = frames + framesSkipped

	local frame = adjustedFrames % fps_int
	local seconds = math.floor(adjustedFrames / fps_int) % 60
	local minutes = math.floor(adjustedFrames / (fps_int * 60)) % 60
	local hours = math.floor(adjustedFrames / (fps_int * 3600))

	return string.format("%02d:%02d:%02d.%02d", hours, minutes, seconds, frame)

end  
    
function update_osd()
    info.active_encoder_str = ""
    for key, value in pairs(info.active_encoder) do
        if value then
            info.active_encoder_str = info.active_encoder_str .. "/" .. tostring(key)
        end
    end
    if mp.get_property_number("time-pos") then
        info.tc = sectotc(mp.get_property_number("time-pos"))
        info.smpte = sectosmpte(mp.get_property_number("time-pos"))
        showOsdAss("{\\fs2\\pos(1,4)\\an7}T {\\c&H0000FF}" .. info.tc .. "\n{\\fs2\\pos(1,5)\\an7}" .. "\n{\\fs2\\pos(1,7)\\an7}|< " .. sectotc(info.mark_in) .. "\n{\\fs2\\pos(1,9)\\an7}>| " .. sectotc(info.mark_out) .. "\n{\\fs2\\pos(1,11)\\an7}D " .. sectotc(info.duration) .. "\n{\\fs2\\pos(1,13)\\an7}E " .. info.active_encoder_str .. "\n{\\fs2\\pos(1,15)\\an7}M " .. info.last_msg)
    end

end

function setStartPosition()
    print("set mark in")
	info.mark_in = mp.get_property_number("time-pos")
    info.duration = info.mark_out - info.mark_in
    info.last_msg = "set mark in"
	update_osd()
end

function setEndPosition()
    print("set mark out")
	info.mark_out = mp.get_property_number("time-pos")
    info.duration = info.mark_out - info.mark_in
    info.last_msg = "set mark out"
	update_osd()
end

function do_finish()
    print("Finish encoding...")
end

function start_encoder(arg)
	local encoder = {}
	encoder.index = info.index
    table.insert(info.active_encoder, true)     -- append 'true' encoder flags.
    update_osd()
	info.index = info.index + 1
    print("start editing.. #" .. tostring(encoder.index))
    -- str_run = "ffmpeg.exe -hide_banner -f lavfi -re -i testsrc  -t 1 -f null -"
    -- args = split(str_run, " ")
	encoder.thread = mp.command_native_async({
    name = "subprocess",
    args = arg,
	playback_only =false,
    capture_stdout = true},
        function(res, stdout, val, err)
            print("Finish subprocess: " .. join(" ", {res, stdout, val, err}))
			print(encoder.index)
            info.active_encoder[encoder.index] = false  -- indicate finished encoder as false

            info.last_msg = "Finished.. " .. tostring(encoder.index)
            update_osd()
        end)
end


function get_path_files(path)
    local l_file = {}
    l_file = utils.readdir(path, "files")
    return l_file
end


function get_no_list(list)
    if not (list == nil) then
        return #list
    else
        return 0
    end
end


function do_edit()
    if info.duration <= 0 then 
        info.last_msg = "Check duration."
        update_osd()
        return
    end
    print("start editing..")
	local file_input = mp.get_property("path")
	local arg_table = {}
	table.insert(arg_table, "ffmpeg")
	table.insert(arg_table, "-hide_banner")
	table.insert(arg_table, "-ss")
	table.insert(arg_table, tostring(info.mark_in))
	table.insert(arg_table, "-i")
	table.insert(arg_table, file_input)
	local param_codec = info.encoder_param[info.encoder_key]
	
	for key, value in pairs(split(param_codec, " ")) do
		table.insert(arg_table, value)
	end
	table.insert(arg_table, "-t")
	table.insert(arg_table, tostring(info.duration))
	valid_output = string.gsub(get_name_target(), ":", "_")
    str_prefix = "00000" .. tostring(get_no_list(get_path_files(info.path_target)))
    str_prefix = string.sub(str_prefix, -3)
	--target_fullpath = utils.join_path(info.path_target, valid_output)
    target_fullpath = utils.join_path(info.path_target, "[" .. str_prefix .. "]_" .. valid_output)
    print(target_fullpath)
	table.insert(arg_table, target_fullpath)
	for key, value in pairs(arg_table) do
		print(value)
	end
    info.last_msg = valid_output
    update_osd()
	start_encoder(arg_table)
end

function printinfo()
	for key, val in pairs(info) do
		print(key , " --> " , val)
	end
end

function file_exists(filename)
    local f = io.open(filename,"r")
    if not f then 
        return false 
    else
        io.close(f) 
        return  true
    end
end





function get_path_target()
    if file_exists("config_trim.txt") then
        for line in io.lines("config_trim.txt") do
            local n = string.find(line, "=")
            if string.sub(line, 1, n-1) == "target" then	-- delimiter left side is "target"
                info.path_target = all_trim(string.sub(line, n+1))
                print("target path = " .. info.path_target)
            end
        end
    else
        info.path_target = "c:/temp"
        print("target config file not exist.. use default.... " .. info.path_target)
    end
	return info.path_target
end


function get_name_target()
	local name_input = mp.get_property("path")
	local folder, name = utils.split_path(name_input)
	-- local extension = GetFileExtension(name_input)
    local extension = info.encoder_extension[info.encoder_key]
	info.name_target = remove_extension(name) .. "_" .. sectotc(info.mark_in) .. extension
	return info.name_target
end

function get_binary()
	local result = mp.command_native({
	name = "subprocess",
	args = {"where", "ffmpeg"},
	playback_only =false,
	capture_stdout = true})
	print("## ffmpeg binary found at .. " .. result.stdout)
end


function goto_in()
	mp.set_property_bool("pause", true)
	mp.command("seek " .. info.mark_in .. " absolute+exact")
	info.last_msg = "Goto IN"
    update_osd()
end

function goto_out()
	mp.set_property_bool("pause", true)
	mp.command("seek " .. info.mark_out  .. " absolute+exact")
	info.last_msg = "Goto OUT"
    update_osd()

end

function encoder_mode()     -- cycle through encoder parameter
    info.encoder_key, value = next(info.encoder_param, info.encoder_key)
    if not info.encoder_key then
        info.encoder_key, value = next(info.encoder_param, info.encoder_key)
    end
    print(info.encoder_key)
    print(info.encoder_param[info.encoder_key])
    print(info.encoder_extension[info.encoder_key])
    info.last_msg = info.encoder_key
    update_osd()
    
end


function fileLoaded()
    mp.set_property_bool("pause", true)
    
    info.encoder_extension.copy = GetFileExtension(mp.get_property("filename"))
    info.encoder_extension.copy_A1 = GetFileExtension(mp.get_property("filename"))
    print("Stream copy mode extension is " .. info.encoder_extension.copy)
    info.last_msg = info.encoder_key
	info.mark_in = 0
	info.mark_out = 0
	info.duration = 0
    update_osd()
	mp.osd_message("target path = " .. info.path_target, 3)
end

function goto_end()
    mp.command("seek 100 absolute-percent")
    mp.set_property_bool("pause",false)
end

print("start sendust trim ++++++++++++++")
printinfo()

get_path_target()
get_binary()


mp.observe_property("time-pos", "native", update_osd)
mp.register_event("file-loaded", fileLoaded)
mp.set_property("osd-scale", 0.7)
mp.set_property_bool("keep-open", true)

mp.add_forced_key_binding("i", "trim-set-start-position", setStartPosition)
mp.add_forced_key_binding("o", "trim-set-end-position", setEndPosition)
mp.add_forced_key_binding("enter", "start-edit", do_edit)
mp.add_forced_key_binding("ctrl+i", "goto_in", goto_in)
mp.add_forced_key_binding("ctrl+o", "goto_out", goto_out)
mp.add_forced_key_binding("f2", "select_mode", encoder_mode)
mp.add_forced_key_binding("End","goto_end",goto_end)


mp.osd_message("target path = " .. info.path_target, 3)


