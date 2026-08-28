package.path = "./koreadalong.koplugin/?.lua;"
    .. ".cache/koreader/lib/koreader/?.lua;"
    .. ".cache/koreader/lib/koreader/common/?.lua;"
    .. package.path

local KindleAudio = require("kindleaudio")

local AUDIO_PATH = "/mnt/us/book/audio.mp3"

local function make_timer()
    local timer = {
        now = 0,
        tasks = {},
    }
    function timer:scheduleIn(delay, action)
        self.tasks[action] = self.now + delay
    end
    function timer:unschedule(action)
        self.tasks[action] = nil
    end
    function timer:advance(seconds)
        self.now = self.now + seconds
        local due = {}
        for action, deadline in pairs(self.tasks) do
            if deadline <= self.now then
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

local function daemon_status(state, position, duration, path)
    return {
        state = state,
        pos = position,
        dur = duration,
        path = path,
    }
end

local function make_port(options)
    options = options or {}
    local port = {
        live = options.live ~= false,
        status = options.status or daemon_status("stopped", 0, 0, ""),
        token = options.token or "p0",
        probe_result = options.probe_result,
        refreshes = options.refreshes or {},
        commands = {},
        closes = 0,
        request_count = 0,
        send_error = nil,
    }
    function port:probe()
        if self.probe_result then
            local result = self.probe_result
            self.probe_result = nil
            return result
        end
        return {
            live = self.live,
            status = self.live and self.status or nil,
            token = self.token,
        }
    end
    function port:requestStatus()
        self.request_count = self.request_count + 1
        self.commands[#self.commands + 1] = { { "status" } }
        local result = table.remove(self.refreshes, 1)
        if result and result.error then
            return nil, result.error
        end
        if result then
            if result.live ~= nil then
                self.live = result.live
            end
            if result.status then
                self.status = result.status
            end
            if result.token ~= nil then
                self.token = result.token
            end
            return result
        end
        return {
            live = self.live,
            status = self.live and self.status or nil,
            token = self.token,
        }
    end
    function port:send(commands)
        if self.send_error then
            return nil, self.send_error
        end
        self.commands[#self.commands + 1] = commands
        return true
    end
    function port:queue(result)
        self.refreshes[#self.refreshes + 1] = result
    end
    function port:close()
        self.closes = self.closes + 1
        return true
    end
    return port
end

local function make_writer()
    local writer = {
        created = {},
        removed = {},
    }
    function writer:create(content)
        local path = "/tmp/koreadalong-test-playlist-"
            .. (#self.created + 1) .. ".m3u"
        self.created[#self.created + 1] = {
            path = path,
            content = content,
        }
        return path
    end
    function writer:remove(path)
        self.removed[#self.removed + 1] = path
        return true
    end
    return writer
end

local function make_audio(options)
    options = options or {}
    local timer = options.timer or make_timer()
    local port = options.port or make_port(options)
    local writer = options.writer or make_writer()
    local audio = KindleAudio.new{
        timer = timer,
        clock = function() return timer.now end,
        port = port,
        playlist_writer = writer,
        startup_timeout = options.startup_timeout or 2,
        close_timeout = options.close_timeout or 2,
        poll_interval = options.poll_interval or 0.2,
    }
    return audio, timer, port, writer
end

local function tick(timer, count)
    for _ = 1, count or 1 do
        timer:advance(0.2)
    end
end

local function command_count(port, name)
    local count = 0
    for _, batch in ipairs(port.commands) do
        for _, command in ipairs(batch) do
            if command[1] == name then
                count = count + 1
            end
        end
    end
    return count
end

local function batch_with(port, name)
    for _, batch in ipairs(port.commands) do
        for _, command in ipairs(batch) do
            if command[1] == name then
                return batch
            end
        end
    end
    return nil
end

local function start_ready(options)
    options = options or {}
    options.probe_result = options.probe_result or {
        live = true,
        status = daemon_status("stopped", 0, 0, ""),
        token = "p0",
    }
    options.refreshes = options.refreshes or {
        {
            live = true,
            status = daemon_status("stopped", 0, 10, ""),
            token = "p1",
        },
    }
    return make_audio(options)
end

describe("KinAMP Kindle audio adapter", function()
    it("starts idle and returns copied status snapshots", function()
        local audio = make_audio()
        local status = audio:getStatus()
        assert.are.equal("idle", status.state)
        assert.are.equal(0, status.position)
        status.state = "playing"
        status.position = 99
        local unchanged = audio:getStatus()
        assert.are.equal("idle", unchanged.state)
        assert.are.equal(0, unchanged.position)
    end)

    it("requires an already-running daemon and does not launch one", function()
        local audio, _, port, writer = make_audio{
            port = make_port{ live = false },
        }
        local opened, error_message = audio:open(AUDIO_PATH)
        assert.is_nil(opened)
        assert.matches("daemon is not running; start KinAMP first", error_message)
        assert.are.equal(0, #writer.created)
        assert.is_nil(port.start)
    end)

    it("waits for a newly published idle token before opening", function()
        local audio, timer, port, writer = start_ready()
        assert.is_true(audio:open(AUDIO_PATH, {
            position = 1.4,
            paused = false,
        }))
        assert.are.equal("loading", audio:getStatus().state)
        assert.are.equal(1, port.request_count)
        assert.are.equal(1, #writer.created)
        local batch = batch_with(port, "load")
        assert.are.same({
            { "load", writer.created[1].path },
            { "index", 0 },
            { "seek", 1 },
        }, batch)
        port:queue{
            live = true,
            status = daemon_status("playing", 1, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(timer)
        assert.are.equal("playing", audio:getStatus().state)
    end)

    it("forces the first status publication when no status file exists yet", function()
        local audio, _, port, writer = make_audio{
            port = make_port{
                probe_result = {
                    live = true,
                    status_error = "KinAMP status file is not available",
                    status_error_kind = "missing",
                },
                refreshes = {
                    {
                        live = true,
                        status = daemon_status("stopped", 0, 0, ""),
                        token = "p1",
                    },
                },
            },
        }
        assert.is_true(audio:open(AUDIO_PATH))
        assert.are.equal(1, port.request_count)
        assert.are.equal(1, #writer.created)
        assert.is_not_nil(batch_with(port, "load"))
    end)

    it("cancels a pre-load wait without leaving a scheduled nil resource poll", function()
        local audio, timer, port, writer = make_audio{
            port = make_port{
                probe_result = {
                    live = true,
                    status = daemon_status("stopped", 0, 0, ""),
                    token = "same",
                },
                token = "same",
            },
        }
        assert.is_true(audio:open(AUDIO_PATH))
        assert.are.equal("loading", audio:getStatus().state)
        assert.is_true(audio:stop())
        assert.are.equal("idle", audio:getStatus().state)
        tick(timer, 3)
        assert.are.equal(1, port.request_count)
        assert.are.equal(0, #writer.created)
    end)

    it("times out when the idle publication never changes", function()
        local audio, timer = make_audio{
            startup_timeout = 0.5,
            port = make_port{
                probe_result = {
                    live = true,
                    status = daemon_status("stopped", 0, 10, ""),
                    token = "same",
                },
                token = "same",
            },
        }
        assert.is_true(audio:open(AUDIO_PATH))
        tick(timer, 4)
        assert.are.equal("error", audio:getStatus().state)
        assert.matches("fresh idle", audio:getStatus().error)
    end)

    it("rejects a busy pre-existing daemon without sending load", function()
        local port = make_port{
            probe_result = {
                live = true,
                status = daemon_status("stopped", 0, 10, ""),
                token = "p0",
            },
            refreshes = {
                {
                    live = true,
                    status = daemon_status("playing", 2, 10, "/mnt/us/other.mp3"),
                    token = "p1",
                },
            },
        }
        local audio, _, _, writer = make_audio{ port = port }
        local opened, error_message = audio:open(AUDIO_PATH)
        assert.is_nil(opened)
        assert.matches("KinAMP is busy", error_message)
        assert.is_nil(batch_with(port, "load"))
        assert.are.equal(0, #writer.created)
    end)

    it("rejects a busy daemon reported by the initial live probe", function()
        local port = make_port{
            probe_result = {
                live = true,
                status = daemon_status("paused", 2, 10, "/mnt/us/other.mp3"),
                token = "busy",
            },
        }
        local audio, _, _, writer = make_audio{ port = port }
        local opened, error_message = audio:open(AUDIO_PATH)
        assert.is_nil(opened)
        assert.matches("KinAMP is busy", error_message)
        assert.is_nil(batch_with(port, "load"))
        assert.are.equal(0, #writer.created)
    end)

    it("uses nearest whole-second initial seek and exact command ordering", function()
        local audio, _, port, writer = start_ready()
        assert.is_true(audio:open(AUDIO_PATH, {
            position = 2.6,
            paused = true,
        }))
        local batch = batch_with(port, "load")
        assert.are.same({
            { "load", writer.created[1].path },
            { "index", 0 },
            { "seek", 3 },
            { "pause" },
        }, batch)
        assert.are.same({ { "status" } }, port.commands[1])
    end)

    it("never repeats an open seek as positions advance", function()
        local audio, timer, port = start_ready{
            refreshes = {
                {
                    live = true,
                    status = daemon_status("stopped", 0, 10, ""),
                    token = "p1",
                },
            },
        }
        assert.is_true(audio:open(AUDIO_PATH, { position = 1.6 }))
        local before = command_count(port, "seek")
        port:queue{
            live = true,
            status = daemon_status("playing", 2, 10, AUDIO_PATH),
            token = "a1",
        }
        port:queue{
            live = true,
            status = daemon_status("playing", 3, 10, AUDIO_PATH),
            token = "a2",
        }
        port:queue{
            live = true,
            status = daemon_status("playing", 4, 10, AUDIO_PATH),
            token = "a3",
        }
        tick(timer, 3)
        assert.are.equal("playing", audio:getStatus().state)
        assert.are.equal(4, audio:getStatus().position)
        assert.are.equal(before, command_count(port, "seek"))
    end)

    it("opens at zero without a seek and applies an explicit seek once", function()
        local audio, timer, port = start_ready()
        assert.is_true(audio:open(AUDIO_PATH, { position = 0 }))
        local before = command_count(port, "seek")
        port:queue{
            live = true,
            status = daemon_status("playing", 1, 10, AUDIO_PATH),
            token = "a1",
        }
        port:queue{
            live = true,
            status = daemon_status("playing", 2, 10, AUDIO_PATH),
            token = "a2",
        }
        tick(timer, 2)
        assert.are.equal(before, command_count(port, "seek"))
        assert.are.equal(2, audio:getStatus().position)
        assert.is_true(audio:seek(4.4))
        assert.are.equal(before + 1, command_count(port, "seek"))
        assert.is_true(audio:seek(4.4))
        assert.are.equal(before + 1, command_count(port, "seek"))
        port:queue{
            live = true,
            status = daemon_status("playing", 4, 10, AUDIO_PATH),
            token = "a3",
        }
        port:queue{
            live = true,
            status = daemon_status("playing", 5, 10, AUDIO_PATH),
            token = "a4",
        }
        tick(timer, 2)
        assert.are.equal(5, audio:getStatus().position)
        assert.are.equal(before + 1, command_count(port, "seek"))
    end)

    it("consumes a sent initial seek on the first fresh active snapshot", function()
        local audio, timer, port = start_ready{
            refreshes = {
                {
                    live = true,
                    status = daemon_status("stopped", 0, 10, ""),
                    token = "p1",
                },
            },
        }
        assert.is_true(audio:open(AUDIO_PATH, { position = 2 }))
        local initial_seeks = command_count(port, "seek")
        assert.are.equal(1, initial_seeks)

        port:queue{
            live = true,
            status = daemon_status("playing", 3, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(timer)
        port:queue{
            live = true,
            status = daemon_status("playing", 4, 10, AUDIO_PATH),
            token = "a2",
        }
        tick(timer)
        assert.are.equal(initial_seeks, command_count(port, "seek"))

        assert.is_true(audio:seek(2))
        assert.are.equal(initial_seeks + 1, command_count(port, "seek"))
        port:queue{
            live = true,
            status = daemon_status("playing", 2, 10, AUDIO_PATH),
            token = "a3",
        }
        tick(timer)
        port:queue{
            live = true,
            status = daemon_status("playing", 5, 10, AUDIO_PATH),
            token = "a4",
        }
        tick(timer)
        assert.are.equal(initial_seeks + 1, command_count(port, "seek"))
    end)

    it("converges pause in both directions without duplicate toggle commands", function()
        local audio, timer, port = start_ready{
            refreshes = {
                {
                    live = true,
                    status = daemon_status("stopped", 0, 10, ""),
                    token = "p1",
                },
            },
        }
        assert.is_true(audio:open(AUDIO_PATH, { paused = true }))
        port:queue{
            live = true,
            status = daemon_status("playing", 0, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(timer)
        assert.are.equal("loading", audio:getStatus().state)
        port:queue{
            live = true,
            status = daemon_status("paused", 0, 10, AUDIO_PATH),
            token = "a2",
        }
        tick(timer)
        assert.are.equal("paused", audio:getStatus().state)

        local before = command_count(port, "play")
        assert.is_true(audio:setPaused(false))
        assert.is_true(audio:setPaused(false))
        assert.are.equal(before + 1, command_count(port, "play"))
        port:queue{
            live = true,
            status = daemon_status("playing", 0, 10, AUDIO_PATH),
            token = "a3",
        }
        tick(timer)
        assert.are.equal("playing", audio:getStatus().state)

        before = command_count(port, "pause")
        assert.is_true(audio:setPaused(true))
        assert.is_true(audio:setPaused(true))
        assert.are.equal(before + 1, command_count(port, "pause"))
        port:queue{
            live = true,
            status = daemon_status("paused", 0, 10, AUDIO_PATH),
            token = "a4",
        }
        tick(timer)
        assert.are.equal("paused", audio:getStatus().state)
    end)

    it("requires a fresh exact stopped publication after atomic stop plus status", function()
        local audio, timer, port, writer = start_ready()
        assert.is_true(audio:open(AUDIO_PATH))
        port:queue{
            live = true,
            status = daemon_status("playing", 3, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(timer)
        assert.is_true(audio:stop())
        port:queue{
            live = true,
            status = daemon_status("playing", 4, 10, AUDIO_PATH),
            token = "a2",
        }
        tick(timer)
        assert.are.equal(1, command_count(port, "stop"))
        assert.are.same({ { "stop" }, { "status" } }, port.commands[#port.commands])
        assert.are.equal("playing", audio:getStatus().state)

        port:queue{
            live = true,
            status = daemon_status("stopped", 4, 10, AUDIO_PATH),
            token = "a2",
        }
        tick(timer)
        assert.are.equal("playing", audio:getStatus().state)
        assert.are.equal(0, #writer.removed)
        port:queue{
            live = true,
            status = daemon_status("stopped", 4, 10, AUDIO_PATH),
            token = "a3",
        }
        tick(timer)
        assert.are.equal("idle", audio:getStatus().state)
        assert.are.equal(1, #writer.removed)
    end)

    it("infers EOF from an owned fresh playing-to-stopped transition with stale pos", function()
        local audio, timer, port, writer = start_ready()
        assert.is_true(audio:open(AUDIO_PATH))
        port:queue{
            live = true,
            status = daemon_status("playing", 7, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(timer)
        port:queue{
            live = true,
            status = daemon_status("stopped", 0, 0, AUDIO_PATH),
            token = "e1",
        }
        tick(timer)
        local status = audio:getStatus()
        assert.are.equal("ended", status.state)
        assert.are.equal(7, status.position)
        assert.are.equal(10, status.duration)
        assert.are.equal(0, #writer.removed)
        tick(timer)
        assert.are.equal("ended", audio:getStatus().state)
        assert.is_true(audio:stop())
        port:queue{
            live = true,
            status = daemon_status("stopped", 0, 10, AUDIO_PATH),
            token = "e2",
        }
        tick(timer)
        port:queue{
            live = true,
            status = daemon_status("stopped", 0, 10, AUDIO_PATH),
            token = "e3",
        }
        tick(timer)
        assert.are.equal("idle", audio:getStatus().state)
    end)

    it("ignores stale tokens, other paths, and empty paths", function()
        local audio, timer, port = start_ready()
        assert.is_true(audio:open(AUDIO_PATH))
        port:queue{
            live = true,
            status = daemon_status("playing", 99, 99, AUDIO_PATH),
            token = "p1",
        }
        tick(timer)
        assert.are.equal("loading", audio:getStatus().state)
        port:queue{
            live = true,
            status = daemon_status("playing", 1, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(timer)
        port:queue{
            live = true,
            status = daemon_status("playing", 99, 99, "/mnt/us/other.mp3"),
            token = "a2",
        }
        tick(timer)
        assert.are.equal("playing", audio:getStatus().state)
        assert.are.equal(1, audio:getStatus().position)

        assert.is_true(audio:stop())
        port:queue{
            live = true,
            status = daemon_status("stopped", 0, 10, nil),
            token = "a3",
        }
        tick(timer)
        assert.are.equal(0, command_count(port, "stop"))
        assert.are.equal(0, command_count(port, "quit"))
    end)

    it("allows cleanup convergence after a terminal command error", function()
        local audio, timer, port, writer = start_ready()
        assert.is_true(audio:open(AUDIO_PATH))
        port:queue{
            live = true,
            status = daemon_status("playing", 1, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(timer)
        port.send_error = "FIFO write failed"
        local sought, error_message = audio:seek(4)
        assert.is_nil(sought)
        assert.matches("FIFO write failed", error_message)
        port.send_error = nil
        assert.is_true(audio:stop())
        port:queue{
            live = true,
            status = daemon_status("stopped", 0, 10, AUDIO_PATH),
            token = "e1",
        }
        tick(timer)
        port:queue{
            live = true,
            status = daemon_status("stopped", 0, 10, AUDIO_PATH),
            token = "e2",
        }
        tick(timer)
        assert.are.equal("idle", audio:getStatus().state)
        assert.matches("FIFO write failed", audio:getStatus().error)
        assert.are.equal(1, #writer.removed)
    end)

    it("closes playing resources only after fresh stopped confirmation", function()
        local audio, timer, port, writer = start_ready()
        assert.is_true(audio:open(AUDIO_PATH))
        port:queue{
            live = true,
            status = daemon_status("playing", 2, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(timer)
        assert.is_true(audio:close())
        assert.are.equal("closed", audio:getStatus().state)
        assert.are.equal(0, #writer.removed)
        assert.are.equal(1, command_count(port, "stop"))
        port:queue{
            live = true,
            status = daemon_status("stopped", 2, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(timer)
        assert.are.equal(0, #writer.removed)
        port:queue{
            live = true,
            status = daemon_status("stopped", 0, 10, AUDIO_PATH),
            token = "a2",
        }
        tick(timer)
        assert.are.equal(1, #writer.removed)
        assert.are.equal(1, port.closes)
        assert.are.equal(0, command_count(port, "quit"))
        assert.is_true(audio:close())
        assert.are.equal(1, port.closes)
    end)

    it("completes controlled close when the daemon disappears", function()
        local audio, timer, port, writer = start_ready()
        assert.is_true(audio:open(AUDIO_PATH))
        port:queue{
            live = true,
            status = daemon_status("playing", 2, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(timer)

        assert.is_true(audio:close())
        assert.are.equal(0, #writer.removed)
        port:queue{ live = false }
        tick(timer)
        assert.are.equal(1, #writer.removed)
        assert.are.equal(1, port.closes)

        tick(timer, 2)
        assert.are.equal(1, #writer.removed)
        assert.are.equal(1, port.closes)
        assert.is_true(audio:close())
        assert.are.equal(1, #writer.removed)
        assert.are.equal(1, port.closes)
    end)

    it("does not stop another exact path and never releases on an empty path", function()
        local other_audio, other_timer, other_port, other_writer = start_ready()
        assert.is_true(other_audio:open(AUDIO_PATH))
        other_port:queue{
            live = true,
            status = daemon_status("playing", 1, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(other_timer)
        other_port:queue{
            live = true,
            status = daemon_status("playing", 4, 10, "/mnt/us/other.mp3"),
            token = "a2",
        }
        assert.is_true(other_audio:close())
        assert.are.equal(0, command_count(other_port, "stop"))
        assert.are.equal(1, #other_writer.removed)
        assert.are.equal(1, other_port.closes)

        local empty_audio, empty_timer, empty_port, empty_writer = start_ready()
        assert.is_true(empty_audio:open(AUDIO_PATH))
        empty_port:queue{
            live = true,
            status = daemon_status("playing", 1, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(empty_timer)
        empty_port:queue{
            live = true,
            status = daemon_status("stopped", 0, 10, nil),
            token = "a2",
        }
        assert.is_true(empty_audio:close())
        assert.are.equal(0, #empty_writer.removed)
        tick(empty_timer, 12)
        assert.are.equal(0, #empty_writer.removed)
        assert.are.equal(0, empty_port.closes)
        assert.is_truthy(empty_audio:getStatus().cleanup_error)
    end)

    it("surfaces status/read failures and daemon disappearance", function()
        local bad_audio = make_audio{
            port = make_port{
                probe_result = {
                    live = true,
                    status = daemon_status("stopped", 0, 10, ""),
                    token = "p0",
                },
                refreshes = { { error = "status read failed" } },
            },
        }
        local opened, error_message = bad_audio:open(AUDIO_PATH)
        assert.is_nil(opened)
        assert.matches("status read failed", error_message)

        local audio, timer, port = start_ready()
        assert.is_true(audio:open(AUDIO_PATH))
        port:queue{ live = false }
        tick(timer)
        assert.are.equal("error", audio:getStatus().state)
        assert.matches("disappeared", audio:getStatus().error)
    end)

    it("does not retry a failed open while doing terminal cleanup", function()
        local audio, timer, port, writer = start_ready()
        port.send_error = "open write failed"
        local opened, error_message = audio:open(AUDIO_PATH)
        assert.is_nil(opened)
        assert.matches("open write failed", error_message)
        assert.are.equal(1, #writer.created)

        port.send_error = nil
        assert.is_true(audio:stop())
        port:queue{
            live = true,
            status = daemon_status("playing", 1, 10, "/mnt/us/other.mp3"),
            token = "other",
        }
        tick(timer)
        assert.are.equal("idle", audio:getStatus().state)
        assert.are.equal(1, #writer.removed)
    end)

    it("keeps a terminal-error resource until close observes fresh stopped status", function()
        local audio, timer, port, writer = start_ready()
        assert.is_true(audio:open(AUDIO_PATH))
        port:queue{
            live = true,
            status = daemon_status("playing", 1, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(timer)
        port.send_error = "seek failed"
        local sought, error_message = audio:seek(4)
        assert.is_nil(sought)
        assert.matches("seek failed", error_message)
        port.send_error = nil

        assert.is_true(audio:close())
        assert.are.equal(0, #writer.removed)
        port:queue{
            live = true,
            status = daemon_status("stopped", 1, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(timer)
        assert.are.equal(0, #writer.removed)
        port:queue{
            live = true,
            status = daemon_status("stopped", 0, 10, AUDIO_PATH),
            token = "a2",
        }
        tick(timer)
        assert.are.equal(1, #writer.removed)
        assert.matches("seek failed", audio:getStatus().error)
        assert.are.equal(1, port.closes)
    end)

    it("retries local cleanup after release has already been confirmed", function()
        local audio, timer, port, writer = start_ready()
        assert.is_true(audio:open(AUDIO_PATH))
        port:queue{
            live = true,
            status = daemon_status("playing", 1, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(timer)
        local remove = writer.remove
        writer.remove = function(self, path)
            self.removed[#self.removed + 1] = path
            return nil, "temporary cleanup failure"
        end
        assert.is_true(audio:stop())
        port:queue{
            live = true,
            status = daemon_status("stopped", 1, 10, AUDIO_PATH),
            token = "a2",
        }
        tick(timer)
        port:queue{
            live = true,
            status = daemon_status("stopped", 1, 10, AUDIO_PATH),
            token = "a3",
        }
        tick(timer)
        assert.are.equal("error", audio:getStatus().state)
        writer.remove = remove
        tick(timer)
        assert.are.equal(2, #writer.removed)
        assert.are.equal("idle", audio:getStatus().state)
    end)

    it("does not close the port until close cleanup succeeds", function()
        local audio, timer, port, writer = start_ready()
        assert.is_true(audio:open(AUDIO_PATH))
        port:queue{
            live = true,
            status = daemon_status("playing", 1, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(timer)
        local remove = writer.remove
        writer.remove = function(self, path)
            self.removed[#self.removed + 1] = path
            return nil, "temporary cleanup failure"
        end
        assert.is_true(audio:close())
        port:queue{
            live = true,
            status = daemon_status("stopped", 1, 10, AUDIO_PATH),
            token = "a2",
        }
        tick(timer)
        port:queue{
            live = true,
            status = daemon_status("stopped", 1, 10, AUDIO_PATH),
            token = "a3",
        }
        tick(timer)
        assert.are.equal(0, port.closes)
        writer.remove = remove
        tick(timer)
        assert.are.equal(1, port.closes)
        assert.are.equal(3, #writer.removed)
    end)

    it("closes safely from idle, loading, and error without quitting", function()
        local idle, _, idle_port = make_audio()
        assert.is_true(idle:close())
        assert.is_true(idle:close())
        assert.are.equal(1, idle_port.closes)

        local loading, loading_timer, loading_port = make_audio{
            port = make_port{
                probe_result = {
                    live = true,
                    status = daemon_status("stopped", 0, 10, ""),
                    token = "same",
                },
                token = "same",
            },
            startup_timeout = 10,
        }
        assert.is_true(loading:open(AUDIO_PATH))
        assert.is_true(loading:close())
        assert.are.equal(1, loading_port.closes)
        tick(loading_timer)
        assert.are.equal(1, loading_port.closes)

        local errored, _, errored_port = make_audio{
            port = make_port{ live = false },
        }
        assert.is_nil(errored:open(AUDIO_PATH))
        assert.is_true(errored:close())
        assert.are.equal(1, errored_port.closes)
        assert.are.equal(0, command_count(errored_port, "quit"))
    end)

    it("rejects unsafe audio paths", function()
        local audio = make_audio()
        local opened, error_message = audio:open("/tmp/bad\npath")
        assert.is_nil(opened)
        assert.matches("newline", error_message)
    end)
end)
