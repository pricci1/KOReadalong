package.path = "./koreadalong.koplugin/?.lua;"
    .. ".cache/koreader/lib/koreader/?.lua;"
    .. ".cache/koreader/lib/koreader/common/?.lua;"
    .. package.path
package.cpath = ".cache/koreader/lib/koreader/common/?.so;"
    .. ".cache/koreader/lib/koreader/?.so;"
    .. package.cpath

local bit = require("bit")
local ffi = require("ffi")

require("ffi/posix_h")

local KinAMPPort = require("kinampport")
local KindleAudio = require("kindleaudio")
local C = ffi.C

pcall(ffi.cdef, [[
int mkfifo(const char *, unsigned int);
]])

local function load_lfs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok then
        return lfs
    end
    return assert(require("lfs"))
end

local lfs = load_lfs()

local function monotonic()
    local timespec = ffi.new("struct timespec")
    assert(C.clock_gettime(C.CLOCK_MONOTONIC, timespec) == 0)
    return tonumber(timespec.tv_sec) + tonumber(timespec.tv_nsec) / 1000000000
end

local function wait_until(predicate, timeout)
    local deadline = monotonic() + timeout
    while monotonic() < deadline do
        if predicate() then
            return true
        end
        C.usleep(1000)
    end
    return predicate()
end

local function pump(timer, predicate, timeout)
    local deadline = monotonic() + timeout
    while monotonic() < deadline do
        timer:run_due()
        if predicate() then
            return true
        end
        C.usleep(1000)
    end
    timer:run_due()
    return predicate()
end

local function read_file(path)
    local file, error_message = io.open(path, "rb")
    assert(file, error_message)
    local content = file:read("*a")
    assert(file:close())
    return content
end

local function write_file(path, content)
    local file, error_message = io.open(path, "wb")
    assert(file, error_message)
    assert(file:write(content))
    assert(file:close())
end

local function path_mode(path)
    return lfs.attributes(path, "mode")
end

local function make_runtime_dir()
    for _ = 1, 20 do
        local temporary = os.tmpname()
        os.remove(temporary)
        local suffix = temporary:gsub("^.*/", "")
        local path = "/tmp/koreadalong-kinamp-integration-" .. suffix
        if lfs.mkdir(path) then
            return path
        end
    end
    error("unable to create an isolated KinAMP integration directory")
end

local function command_lines(content)
    local lines = {}
    for line in content:gmatch("([^\n]+)") do
        lines[#lines + 1] = line:gsub("\r$", "")
    end
    return lines
end

local function without_status(lines)
    local result = {}
    for _, line in ipairs(lines) do
        if line ~= "status" then
            result[#result + 1] = line
        end
    end
    return result
end

local FakeKinAMP = {}
FakeKinAMP.__index = FakeKinAMP

function FakeKinAMP.new(runtime_dir, audio_path)
    local self = setmetatable({
        runtime_dir = runtime_dir,
        audio_path = audio_path,
        command_fifo = runtime_dir .. "/kinamp_cmd",
        status_file = runtime_dir .. "/kinamp_status",
        command_log = runtime_dir .. "/commands.log",
        child_error = runtime_dir .. "/child-error.log",
        pid = nil,
        reaped = false,
    }, FakeKinAMP)

    assert(C.mkfifo(self.command_fifo, 384) == 0,
        ffi.string(C.strerror(ffi.errno())))
    local pid = C.fork()
    assert(pid >= 0, ffi.string(C.strerror(ffi.errno())))
    if pid == 0 then
        self:_run_child()
    end
    self.pid = tonumber(pid)
    if not wait_until(function()
        return path_mode(self.status_file) == "file"
    end, 1) then
        self:stop()
        error("fake KinAMP daemon did not publish its initial status")
    end
    return self
end

function FakeKinAMP:_publish(state, position, duration, path)
    self.generation = (self.generation or 0) + 1
    local content = table.concat({
        "pid=" .. tostring(tonumber(C.getpid())),
        "state=" .. state,
        "mode=audio",
        "index=" .. (path ~= "" and "0" or "-1"),
        "count=1",
        "path=" .. path,
        "pos=" .. tostring(position),
        "dur=" .. tostring(duration),
        "generation=" .. tostring(self.generation),
        "padding=" .. string.rep("x", self.generation),
        "",
    }, "\n")
    if #content > KinAMPPort.MAX_STATUS_BYTES then
        error("fake KinAMP status publication exceeded its size bound")
    end

    local temporary = self.status_file .. ".tmp-" .. tostring(self.generation)
    write_file(temporary, content)
    assert(os.rename(temporary, self.status_file))
end

function FakeKinAMP:_record_command(line)
    local file, error_message = io.open(self.command_log, "ab")
    assert(file, error_message)
    assert(file:write(line, "\n"))
    assert(file:close())
end

function FakeKinAMP:_apply_command(line, state)
    self:_record_command(line)
    if line == "status" then
        self:_publish(state.state, state.position, state.duration, state.path)
        return
    end

    if line:match("^load ") then
        local playlist_path = line:sub(6)
        local playlist = read_file(playlist_path)
        assert(playlist == self.audio_path .. "\n",
            "fake KinAMP received unexpected M3U bytes")
        -- KinAMP reports the selected M3U entry, not the playlist path, in
        -- its status publication.
        state.path = self.audio_path
        state.position = 0
        state.duration = 12
        state.state = "stopped"
    elseif line == "index 0" then
        assert(state.path ~= "", "fake KinAMP indexed before load")
        -- A deterministic stand-in for the real daemon's advancing clock.
        state.position = 2
        state.state = "playing"
    elseif line == "play" then
        assert(state.path ~= "", "fake KinAMP played before load")
        state.state = "playing"
    elseif line == "pause" then
        assert(state.path ~= "", "fake KinAMP paused before load")
        state.state = "paused"
    elseif line == "stop" then
        assert(state.path ~= "", "fake KinAMP stopped before load")
        state.state = "stopped"
    else
        local position = line:match("^seek ([0-9]+)$")
        assert(position, "fake KinAMP received unsupported command: " .. line)
        assert(state.path ~= "", "fake KinAMP sought before load")
        state.position = assert(tonumber(position))
        state.state = "playing"
    end
    self:_publish(state.state, state.position, state.duration, state.path)
end

function FakeKinAMP:_serve()
    local flags = bit.bor(C.O_RDONLY, C.O_NONBLOCK)
    local fd = C.open(self.command_fifo, flags)
    assert(fd >= 0, ffi.string(C.strerror(ffi.errno())))

    local state = {
        state = "stopped",
        position = 0,
        duration = 0,
        path = "",
    }
    self:_publish(state.state, state.position, state.duration, state.path)

    local buffer = ffi.new("char[4096]")
    local pending = ""
    while true do
        local count = tonumber(C.read(fd, buffer, 4096))
        if count > 0 then
            pending = pending .. ffi.string(buffer, count)
            assert(#pending <= 4096, "fake KinAMP command exceeded FIFO bound")
            while true do
                local newline = pending:find("\n", 1, true)
                if not newline then
                    break
                end
                local line = pending:sub(1, newline - 1)
                pending = pending:sub(newline + 1)
                line = line:gsub("\r$", "")
                if line ~= "" then
                    self:_apply_command(line, state)
                end
            end
        elseif count < 0 then
            local errno = ffi.errno()
            assert(errno == C.EAGAIN or errno == C.EINTR,
                ffi.string(C.strerror(errno)))
        end
        C.usleep(1000)
    end
end

function FakeKinAMP:_run_child()
    local ok, error_message = pcall(function()
        self:_serve()
    end)
    if not ok then
        local file = io.open(self.child_error, "wb")
        if file then
            file:write(tostring(error_message))
            file:close()
        end
    end
    C._exit(ok and 0 or 1)
end

function FakeKinAMP:_wait_for_exit(timeout)
    if self.reaped then
        return true
    end
    local deadline = monotonic() + timeout
    local status = ffi.new("int[1]")
    while monotonic() < deadline do
        local result = tonumber(C.waitpid(self.pid, status, C.WNOHANG))
        if result == self.pid then
            self.reaped = true
            return true
        end
        if result < 0 and ffi.errno() ~= C.EINTR then
            return false
        end
        C.usleep(10000)
    end
    return self.reaped
end

function FakeKinAMP:kill()
    if self.reaped then
        return
    end
    C.kill(self.pid, 9)
    if not self:_wait_for_exit(1) then
        error("fake KinAMP daemon did not exit after SIGKILL")
    end
end

function FakeKinAMP:stop()
    if self.reaped then
        return
    end
    C.kill(self.pid, C.SIGTERM)
    if self:_wait_for_exit(1) then
        return
    end
    C.kill(self.pid, 9)
    if not self:_wait_for_exit(1) then
        local status = ffi.new("int[1]")
        C.waitpid(self.pid, status, 0)
        self.reaped = true
    end
end

function FakeKinAMP:cleanup()
    self:stop()
    if path_mode(self.runtime_dir) ~= "directory" then
        return
    end
    for entry in lfs.dir(self.runtime_dir) do
        if entry ~= "." and entry ~= ".." then
            os.remove(self.runtime_dir .. "/" .. entry)
        end
    end
    lfs.rmdir(self.runtime_dir)
end

local function make_timer()
    local timer = { tasks = {} }
    function timer:scheduleIn(delay, action)
        self.tasks[action] = monotonic() + delay
    end
    function timer:unschedule(action)
        self.tasks[action] = nil
    end
    function timer:run_due()
        local now = monotonic()
        local due = {}
        for action, deadline in pairs(self.tasks) do
            if deadline <= now then
                self.tasks[action] = nil
                due[#due + 1] = action
            end
        end
        for _, action in ipairs(due) do
            action()
        end
    end
    return timer
end

local function has_command(lines, expected)
    for _, line in ipairs(lines) do
        if line == expected then
            return true
        end
    end
    return false
end

describe("KinAMP filesystem integration", function()
    local runtime_dir
    local audio_path
    local daemon
    local timer
    local port
    local audio

    before_each(function()
        runtime_dir = make_runtime_dir()
        audio_path = runtime_dir .. "/narration.mp3"
        write_file(audio_path, "fake audio bytes\n")
        daemon = FakeKinAMP.new(runtime_dir, audio_path)
        timer = make_timer()
        port = KinAMPPort.new{ runtime_dir = runtime_dir }
        audio = KindleAudio.new{
            port = port,
            timer = timer,
            clock = monotonic,
            playlist_root = runtime_dir,
            poll_interval = 0.01,
            startup_timeout = 1,
        }
    end)

    after_each(function()
        if audio then
            pcall(function()
                audio:close()
            end)
            if timer then
                pump(timer, function()
                    return audio.close_finished
                end, 1)
            end
        end
        if daemon then
            pcall(function()
                daemon:cleanup()
            end)
        end
        if runtime_dir and path_mode(runtime_dir) == "directory" then
            for entry in lfs.dir(runtime_dir) do
                if entry ~= "." and entry ~= ".." then
                    os.remove(runtime_dir .. "/" .. entry)
                end
            end
            lfs.rmdir(runtime_dir)
        end
        runtime_dir = nil
        audio_path = nil
        daemon = nil
        timer = nil
        port = nil
        audio = nil
    end)

    it("runs load, pause, seek-resume, and stop over real KinAMP files", function()
        assert.is_true(audio:open(audio_path))
        local ready = pump(timer, function()
            return audio:getStatus().state == "playing"
        end, 2)
        assert.is_true(ready, audio:getStatus().state .. " / "
            .. tostring(audio:getStatus().error))

        local playlist_path = assert(audio.playlist_path)
        assert.are.equal("file", path_mode(playlist_path))
        assert.are.equal(audio_path .. "\n", read_file(playlist_path))
        local start_token = assert(audio.last_token)

        assert.is_true(audio:setPaused(true))
        assert.is_true(pump(timer, function()
            return audio:getStatus().state == "paused"
        end, 2))
        assert.are.equal(2, audio:getStatus().position)
        local paused_token = assert(audio.last_token)

        assert.is_true(audio:setPaused(false))
        assert.is_true(audio:setPaused(false))
        assert.is_true(pump(timer, function()
            return audio:getStatus().state == "playing"
        end, 2))
        local resumed_token = assert(audio.last_token)

        assert.is_true(audio:stop())
        assert.is_true(pump(timer, function()
            return audio:getStatus().state == "idle"
        end, 2))
        assert.is_false(path_mode(playlist_path) == "file")

        local final_status, final_error, final_token = port:readStatus()
        assert.is_nil(final_error)
        assert.are.equal("stopped", final_status.state)
        assert.are.equal(audio_path, final_status.path)
        assert.is_truthy(final_token)
        assert.are_not.equal(start_token, paused_token)
        assert.are_not.equal(paused_token, resumed_token)
        assert.are_not.equal(resumed_token, final_token)
        assert.is_true(#read_file(port.status_file)
            <= KinAMPPort.MAX_STATUS_BYTES)
        assert.is_truthy(final_status.padding)

        local lines = command_lines(read_file(daemon.command_log))
        assert.are.same({
            "load " .. playlist_path,
            "index 0",
            "pause",
            "seek 2",
            "stop",
        }, without_status(lines))
        assert.is_false(has_command(lines, "play"))
    end)

    it("starts an absent service and reopens with either a shared idle or shut-down daemon", function()
        daemon:stop()
        os.remove(daemon.command_fifo)
        os.remove(daemon.status_file)
        local starts = 0
        local starter = { start = function(_, runtime)
            assert.are.equal(runtime_dir, runtime)
            starts = starts + 1
            daemon = FakeKinAMP.new(runtime_dir, audio_path)
            return true
        end }
        local function reopen()
            port = KinAMPPort.new{ runtime_dir = runtime_dir }
            audio = KindleAudio.new{
                port = port, starter = starter, timer = timer, clock = monotonic,
                playlist_root = runtime_dir, poll_interval = 0.01,
                startup_timeout = 1, service_start_timeout = 1,
            }
            assert.are.equal("idle", audio:getStatus().state)
            assert.is_true(audio:open(audio_path))
            assert.is_true(pump(timer, function()
                return audio:getStatus().state == "playing"
            end, 2), tostring(audio:getStatus().error))
        end
        local function close()
            local playlist = audio.playlist_path
            assert.is_true(audio:close())
            assert.is_true(pump(timer, function() return audio.close_finished end, 2))
            assert.is_nil(path_mode(playlist))
            assert.is_true(port.closed)
            local status = KinAMPPort.new{ runtime_dir = runtime_dir }:probe()
            assert.is_true(status.live)
            assert.are.equal("stopped", status.status.state)
        end
        reopen()
        assert.are.equal(1, starts)
        close()
        reopen()
        assert.are.equal(1, starts, "must reuse the shared idle daemon")
        close()
        -- Model the official plugin quitting an idle daemon on reader teardown.
        daemon:stop()
        os.remove(daemon.command_fifo)
        os.remove(daemon.status_file)
        reopen()
        assert.are.equal(2, starts)
        assert.is_false(has_command(command_lines(read_file(daemon.command_log)), "quit"))
    end)

    it("detects daemon disappearance instead of trusting its stale status file", function()
        assert.is_true(audio:open(audio_path))
        local ready = pump(timer, function()
            return audio:getStatus().state == "playing"
        end, 2)
        assert.is_true(ready, audio:getStatus().state .. " / "
            .. tostring(audio:getStatus().error))
        local stale = assert(port:readStatus())
        assert.are.equal("playing", stale.state)
        assert.are.equal(audio_path, stale.path)

        daemon:kill()
        assert.is_true(pump(timer, function()
            return audio:getStatus().state == "error"
        end, 2))
        assert.matches("disappeared", audio:getStatus().error)
        assert.are.equal("file", path_mode(port.status_file))
    end)
end)
