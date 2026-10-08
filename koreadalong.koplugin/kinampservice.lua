local loaded_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not loaded_lfs then
    lfs = require("lfs")
end

-- Startup interoperability with externally installed KinAMP, not a player or
-- lifecycle manager. The official launcher replaces existing processes and
-- its private Lua launch helper changes Bluetooth. Neither is safe here.
local KinAMPService = {}
KinAMPService.__index = KinAMPService

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
    }, KinAMPService)
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
