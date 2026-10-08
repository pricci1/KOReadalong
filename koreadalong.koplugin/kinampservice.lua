local loaded_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not loaded_lfs then
    lfs = require("lfs")
end
local ffi = require("ffi")
require("ffi/posix_h")

-- Startup interoperability with externally installed KinAMP, not a player or
-- lifecycle manager. The official launcher replaces existing processes and
-- its private Lua launch helper changes Bluetooth. Neither is safe here.
local KinAMPService = {}
KinAMPService.__index = KinAMPService

local function read_file(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read(4097)
    file:close()
    return content
end

local function process_identity(pid)
    local content = read_file("/proc/" .. pid .. "/stat")
    if not content then
        -- Unknown is not dead: fail closed if /proc cannot be inspected.
        local attributes, _, errno = lfs.attributes("/proc/" .. pid)
        if not attributes and errno == 2 then return false end
        return nil
    end
    local fields = content:match("^%d+ %(.+%) (.*)")
    local index = 0
    for value in (fields or ""):gmatch("%S+") do
        index = index + 1
        if index == 20 and value:match("^%d+$") then
            -- Linux field 22, the process start clock, excludes PID reuse.
            return pid .. ":" .. value
        end
    end
end

local function write_file(path, content)
    local file = io.open(path .. ".new", "w")
    if not file then return nil end
    local written = file:write(content)
    local closed = file:close()
    if written and closed and os.rename(path .. ".new", path) then return true end
    os.remove(path .. ".new")
end

local function receipt_path(runtime)
    return runtime:gsub("/+$", "") .. "/koreadalong-kinamp-owner"
end

local function exists(path)
    return lfs.attributes(path, "mode") == "file"
end

local function running(started_pid)
    -- FIFO absence is not proof of process absence (startup or broken IPC).
    -- Include the GUI and all minimal flavours, whose comm names truncate.
    if started_pid and lfs.attributes("/proc/" .. started_pid, "mode") == "directory" then
        return started_pid
    end
    for entry in lfs.dir("/proc") do
        if entry:match("^%d+$") then
            local file = io.open("/proc/" .. entry .. "/comm", "r")
            if file then
                local name = file:read("*l")
                file:close()
                if name and name:match("^KinAMP") then
                    return tonumber(entry)
                end
            end
        end
    end
    return false
end

local function quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function launch(directory, binary, libraries, runtime)
    -- Only the short-lived shell is waited on. KinAMP inherits no terminal or
    -- standard streams and stays idle even if its saved playlist is nonempty.
    local pipe = io.popen("(cd " .. quote(directory)
        .. " && LD_LIBRARY_PATH=" .. quote(libraries)
        .. " KINAMP_RUNTIME_DIR=" .. quote(runtime)
        .. " exec nohup " .. quote(binary) .. " --idle)"
        .. " </dev/null >/dev/null 2>&1 & echo $!", "r")
    if not pipe then
        return nil, "Unable to start KinAMP"
    end
    local pid = tonumber(pipe:read("*l"))
    pipe:close()
    if not pid then
        return nil, "Unable to start KinAMP"
    end
    return pid
end

function KinAMPService.new(options)
    options = options or {}
    return setmetatable({
        get_config = options.get_config or function()
            -- Reuse the enabled official plugin's installation discovery.
            local ok, config = pcall(require, "kinamp_config")
            return ok and config or nil
        end,
        get_bluetooth = options.get_bluetooth or function()
            local cached = package.loaded.kinamp_bt
            local ok, bluetooth = pcall(require, "kinamp_bt")
            if ok and cached and type(bluetooth.available) == "function" then
                local reported, available = pcall(bluetooth.available)
                if reported and available == false then
                    -- The official close() can leave handle_tried set, so its
                    -- cached module cannot reopen after reader transitions.
                    -- Refresh that reader API and the settings that capture it;
                    -- no daemon, radio or existing client is changed.
                    package.loaded.kinamp_bt = nil
                    package.loaded.kinamp_btdevices = nil
                    ok, bluetooth = pcall(require, "kinamp_bt")
                end
            end
            return ok and bluetooth or nil
        end,
        exists = options.exists or exists,
        running = options.running or running,
        launch = options.launch or launch,
        reader_pid = options.reader_pid or tonumber(ffi.C.getpid()),
        process_identity = options.process_identity or process_identity,
        read_file = options.read_file or read_file,
        write_file = options.write_file or write_file,
        remove_file = options.remove_file or os.remove,
    }, KinAMPService)
end

function KinAMPService:_receipt(runtime)
    local content = self.read_file(receipt_path(runtime))
    if not content or #content > 4096 then return nil end
    local reader, daemon, audio, playlist = content:match(
        "^(%d+:%d+)\n(%d+:%d+)\n([^\n]+)\n([^\n]+)\n$"
    )
    if reader then
        return { reader = reader, daemon = daemon, audio = audio, playlist = playlist }
    end
end

function KinAMPService:isOrphan(runtime, status)
    local receipt = self:_receipt(runtime)
    if not receipt or not status or not status.pid
        or status.path ~= receipt.audio or status.index ~= 0
        or status.count ~= 1 or status.mode ~= "music" then return false end
    local reader_pid = tonumber(receipt.reader:match("^%d+"))
    local reader = self.process_identity(reader_pid)
    return reader ~= nil and reader ~= receipt.reader
        and self.process_identity(status.pid) == receipt.daemon
end

function KinAMPService:releaseOrphan(runtime, status)
    if status.state ~= "stopped" or not self:isOrphan(runtime, status) then return true end
    local receipt = self:_receipt(runtime)
    local directory = receipt.audio:match("^(/tmp/koreadalong%-[%w]+)/audio%-[%w]+%.[%w]+$")
    local prefix = runtime:gsub("/+$", "") .. "/koreadalong-kinamp-"
    if not directory or receipt.playlist:sub(1, #prefix) ~= prefix
        or not receipt.playlist:sub(#prefix + 1):match("^[%w]+%.m3u$") then
        return nil, "Unable to verify orphaned read-along files"
    end
    for _, path in ipairs{ receipt.audio, receipt.playlist } do
        if self.exists(path) and not self.remove_file(path) then
            return nil, "Unable to remove orphaned read-along files"
        end
    end
    -- Never recurse: unrelated files, even inside this directory, stay intact.
    lfs.rmdir(directory)
    if not self.remove_file(receipt_path(runtime)) then
        return nil, "Unable to clear orphaned read-along ownership"
    end
    return true
end

function KinAMPService:remember(runtime, status, audio, playlist)
    local reader = self.process_identity(self.reader_pid)
    local daemon = status and status.pid and self.process_identity(status.pid)
    if not reader or not daemon or audio:find("[%z\r\n]")
        or playlist:find("[%z\r\n]") then
        return nil, "Unable to record read-along ownership"
    end
    if not self.write_file(receipt_path(runtime), table.concat({
        reader, daemon, audio, playlist, "",
    }, "\n")) then
        return nil, "Unable to record read-along ownership"
    end
    return true
end

function KinAMPService:forget(runtime, playlist)
    local receipt = self:_receipt(runtime)
    if receipt and receipt.playlist == playlist
        and receipt.reader == self.process_identity(self.reader_pid) then
        return self.remove_file(receipt_path(runtime))
    end
    return true
end

function KinAMPService:checkOutput()
    -- Read only the official Bluetooth API. Unknown/unsupported reporting is
    -- not proof of a missing connection; never change the radio or pair here.
    local ok, connected, name = pcall(function()
        local bluetooth = self.get_bluetooth()
        if bluetooth and type(bluetooth.available) == "function"
            and type(bluetooth.getConnected) == "function"
            and type(bluetooth.getConnectedName) == "function"
            and bluetooth.available() then
            return bluetooth.getConnected(), bluetooth.getConnectedName()
        end
    end)
    if ok and type(connected) == "table" and #connected == 0 and not name then
        return nil, "Bluetooth audio is not connected"
    end
    return true
end

function KinAMPService:start(runtime)
    local config = self.get_config()
    if not config or type(config.bin_folder) ~= "string" then
        return nil, "Install and enable the KinAMP plugin and player, then restart KOReader"
    end
    -- Leave an existing process alone even if it has not published IPC yet.
    local existing_pid = self.running(self.started_pid)
    if existing_pid then
        if existing_pid ~= self.started_pid then
            self.started_pid = nil
        end
        return true
    end
    local directory = config.bin_folder:gsub("/+$", "")
    local suffix, libraries = "", "libs_hf"
    if not self.exists("/lib/ld-linux-armhf.so.3") then
        suffix, libraries = "-pw2", "libs_pw2"
    else
        local gst010, gst100 = false, false
        for _, root in ipairs{
            "/lib", "/usr/lib", "/lib/arm-linux-gnueabihf",
            "/usr/lib/arm-linux-gnueabihf", "/usr/local/lib",
        } do
            gst010 = gst010 or self.exists(root .. "/libgstreamer-0.10.so.0")
            gst100 = gst100 or self.exists(root .. "/libgstreamer-1.0.so.0")
        end
        if not gst010 and gst100
            and self.exists(directory .. "/KinAMP-minimal-gst") then
            suffix = "-gst"
        end
    end
    local binary = directory .. "/KinAMP-minimal" .. suffix
    if not self.exists(binary) then
        return nil, "KinAMP player is missing; complete the separate KinAMP installation"
    end
    local pid, error_message = self.launch(
        directory, binary, directory .. "/" .. libraries, runtime
    )
    if not pid then
        return nil, error_message
    end
    self.started_pid = pid
    return true
end

-- Survives reader/file-manager transitions and prevents duplicate starts while
-- the child is still exec'ing, before it has created its command FIFO.
KinAMPService.shared = KinAMPService.new()

return KinAMPService
