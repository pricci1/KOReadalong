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

local function make_logger()
    local logger = {
        entries = {},
    }
    local function record(level, ...)
        logger.entries[#logger.entries + 1] = {
            level = level,
            arguments = { ... },
        }
    end
    function logger.info(...)
        record("info", ...)
    end
    function logger.warn(...)
        record("warn", ...)
    end
    function logger.err(...)
        record("err", ...)
    end
    return logger
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
    function port:getRuntimeDir()
        return "/tmp"
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
    local logger = options.logger or make_logger()
    local audio = KindleAudio.new{
        timer = timer,
        clock = function() return timer.now end,
        port = port,
        playlist_writer = writer,
        logger = logger,
        startup_timeout = options.startup_timeout or 2,
        starter = options.starter,
        service_start_timeout = options.service_start_timeout or 1,
        close_timeout = options.close_timeout or 2,
        poll_interval = options.poll_interval or 0.2,
    }
    return audio, timer, port, writer, logger
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

local function log_count(logger, marker)
    local count = 0
    for _, entry in ipairs(logger.entries) do
        if entry.arguments[1] == marker then
            count = count + 1
        end
    end
    return count
end

local function log_has_argument(logger, marker, value)
    for _, entry in ipairs(logger.entries) do
        if entry.arguments[1] == marker then
            for index = 2, #entry.arguments do
                if entry.arguments[index] == value then
                    return true
                end
            end
        end
    end
    return false
end

local function log_text(logger)
    local values = {}
    for _, entry in ipairs(logger.entries) do
        for _, argument in ipairs(entry.arguments) do
            values[#values + 1] = tostring(argument)
        end
    end
    return table.concat(values, " ")
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

    it("creates a KinAMP playlist with the default writer", function()
        local timer = make_timer()
        local port = make_port{
            probe_result = {
                live = true,
                status = daemon_status("stopped", 0, 0, ""),
                token = "p0",
            },
            refreshes = {
                {
                    live = true,
                    status = daemon_status("stopped", 0, 0, ""),
                    token = "p1",
                },
            },
        }
        local audio = KindleAudio.new{
            timer = timer,
            clock = function() return timer.now end,
            port = port,
            playlist_root = "/tmp",
            logger = make_logger(),
        }

        assert.is_true(audio:open(AUDIO_PATH))
        local batch = assert(batch_with(port, "load"))
        local playlist_path = batch[1][2]
        local playlist = assert(io.open(playlist_path, "rb"))
        assert.are.equal(AUDIO_PATH .. "\n", playlist:read("*a"))
        assert.is_true(playlist:close())
        assert.is_true(os.remove(playlist_path))
    end)

    it("reports missing playback when no startup service is supplied", function()
        local audio, _, port, writer = make_audio{
            port = make_port{ live = false },
        }
        local opened, error_message = audio:open(AUDIO_PATH)
        assert.is_nil(opened)
        assert.matches("daemon is not running; start KinAMP first", error_message)
        assert.is_true(audio:getStatus().recoverable)
        assert.is_nil(audio.timer.tasks[audio.poll_action])
        assert.are.equal(0, #writer.created)
        assert.is_nil(port.start)
    end)

    it("offers recoverable output setup before starting or acquiring idle playback", function()
        for _, live in ipairs{ false, true } do
            local connected, launches = false, 0
            local starter = {
                checkOutput = function()
                    if connected then return true end
                    return nil, "Bluetooth audio is not connected"
                end,
                start = function() launches = launches + 1; return true end,
            }
            local audio, _, port, writer = make_audio{ live = live, starter = starter }
            local opened, message = audio:open(AUDIO_PATH)
            assert.is_nil(opened)
            assert.are.equal("Bluetooth audio is not connected", message)
            assert.is_true(audio:getStatus().recoverable)
            assert.are.equal(0, launches)
            assert.are.equal(0, #writer.created)
            assert.are.equal(0, #port.commands)
            assert.is_true(audio:stop())
            connected = true
            assert.is_true(audio:open(AUDIO_PATH))
            assert.are.equal(live and 0 or 1, launches)
        end
    end)

    it("prioritizes preserving busy playback over Bluetooth setup", function()
        local checks = 0
        local audio, _, port, writer = make_audio{
            status = daemon_status("paused", 14, 90, "/other/client.mp3"),
            starter = { checkOutput = function()
                checks = checks + 1
                return nil, "Bluetooth audio is not connected"
            end },
        }
        local opened, message = audio:open(AUDIO_PATH)
        assert.is_nil(opened)
        assert.are.equal("KinAMP is busy", message)
        assert.are.equal(0, checks)
        assert.are.equal(0, #writer.created)
        assert.are.equal(0, #port.commands)
    end)

    it("starts asynchronously once and requires fresh idle readiness before playback", function()
        local launches = 0
        local starter = { start = function(_, runtime)
            assert.are.equal("/tmp", runtime)
            launches = launches + 1
            return true
        end }
        local audio, timer, port, writer = make_audio{
            live = false, starter = starter,
        }
        assert.is_true(audio:open(AUDIO_PATH, { position = 27.6 }))
        tick(timer, 2)
        assert.are.equal("loading", audio:getStatus().state)
        assert.are.equal(1, launches)
        assert.are.equal(0, #port.commands)
        assert.are.equal(0, #writer.created)
        assert.is_nil(audio:open(AUDIO_PATH))
        assert.are.equal(1, launches)

        port.live = true
        tick(timer)
        assert.are.equal(0, #writer.created)
        port:queue{ live = true, token = "ready", status = daemon_status("stopped", 0, 0, "") }
        tick(timer)
        assert.are.same({
            { "load", writer.created[1].path }, { "index", 0 }, { "seek", 28 },
        }, batch_with(port, "load"))
        port:queue{ live = true, token = "playing", status = daemon_status("playing", 28, 90, AUDIO_PATH) }
        tick(timer)
        assert.are.equal("playing", audio:getStatus().state)
    end)

    it("refuses a client that becomes busy during startup without loading or stopping it", function()
        for _, state in ipairs{ "playing", "paused" } do
            local audio, timer, port, writer = make_audio{
                live = false, starter = { start = function() return true end },
            }
            assert.is_true(audio:open(AUDIO_PATH))
            port.live = true
            port.status = daemon_status(state, 14, 90, "/other/client.mp3")
            tick(timer)
            assert.are.equal("KinAMP is busy", audio:getStatus().error)
            assert.is_true(audio:getStatus().recoverable)
            assert.are.equal(0, #writer.created)
            assert.is_true(audio:close())
            assert.are.equal(0, command_count(port, "stop"))
            assert.are.equal(0, command_count(port, "load"))
        end
    end)

    it("times out startup recoverably and cancels on close without commanding the daemon", function()
        local audio, timer, port, writer = make_audio{
            live = false, starter = { start = function() return true end },
        }
        assert.is_true(audio:open(AUDIO_PATH))
        tick(timer, 6)
        assert.matches("did not become ready", audio:getStatus().error)
        assert.is_true(audio:getStatus().recoverable)
        assert.is_nil(timer.tasks[audio.poll_action])
        assert.is_true(audio:stop())
        assert.is_true(audio:open(AUDIO_PATH))
        assert.is_true(audio:close())
        port.live = true
        tick(timer, 8)
        assert.are.equal(0, #writer.created)
        assert.are.equal(0, #port.commands)
        assert.are.equal(1, port.closes)
    end)

    it("reports installation or launch failure before acquiring playback resources", function()
        local audio, _, port, writer = make_audio{
            live = false, starter = { start = function() return nil, "KinAMP player is missing" end },
        }
        local opened, message = audio:open(AUDIO_PATH)
        assert.is_nil(opened)
        assert.are.equal("KinAMP player is missing", message)
        assert.is_true(audio:getStatus().recoverable)
        assert.are.equal(0, #writer.created)
        assert.are.equal(0, #port.commands)
    end)

    it("retries a missing-daemon preflight after resetting the adapter", function()
        local audio, timer, port, writer = make_audio{
            port = make_port{ live = false },
        }
        assert.is_nil(audio:open(AUDIO_PATH))
        assert.is_true(audio:getStatus().recoverable)

        port.live = true
        port.token = "p1"
        port.status = daemon_status("stopped", 0, 0, "")
        port:queue{
            live = true,
            status = daemon_status("stopped", 0, 0, ""),
            token = "p2",
        }
        assert.is_true(audio:stop())
        assert.are.equal("idle", audio:getStatus().state)
        assert.is_false(audio:getStatus().recoverable)

        assert.is_true(audio:open(AUDIO_PATH))
        assert.are.equal(1, #writer.created)
        assert.are.equal(1, command_count(port, "load"))
        assert.is_not_nil(timer.tasks[audio.poll_action])
        local schedules = 0
        for _ in pairs(timer.tasks) do
            schedules = schedules + 1
        end
        assert.are.equal(1, schedules)
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

    it("logs decisive transitions without fresh-token polling noise or paths", function()
        local audio, timer, port, writer, logger = start_ready{
            logger = make_logger(),
        }
        assert.is_true(audio:open(AUDIO_PATH, { position = 1.4 }))
        assert.are.equal(1, log_count(logger, "KoReadalong KindleAudio state"))
        assert.are.equal(2, log_count(logger, "KoReadalong KindleAudio publication"))
        assert.is_true(log_has_argument(
            logger,
            "KoReadalong KindleAudio command",
            "load"
        ))
        assert.is_true(log_has_argument(logger, "KoReadalong KindleAudio command", "<playlist>"))
        assert.is_true(log_has_argument(logger, "KoReadalong KindleAudio command", "1"))
        assert.is_false(log_text(logger):find(AUDIO_PATH, 1, true) ~= nil)
        assert.is_false(log_text(logger):find(writer.created[1].path, 1, true) ~= nil)

        port:queue{
            live = true,
            status = daemon_status("playing", 1, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(timer)
        assert.are.equal(3, log_count(logger, "KoReadalong KindleAudio publication"))
        assert.are.equal(2, log_count(logger, "KoReadalong KindleAudio state"))

        local before_routine_polls = #logger.entries
        for _, token in ipairs({ "poll-1", "poll-2", "poll-3" }) do
            port:queue{
                live = true,
                status = daemon_status("playing", 1, 10, AUDIO_PATH),
                token = token,
            }
            tick(timer)
        end
        assert.are.equal(before_routine_polls, #logger.entries)
        assert.are.equal(3, log_count(logger, "KoReadalong KindleAudio publication"))

        assert.is_true(audio:stop())
        port:queue{
            live = true,
            status = daemon_status("playing", 1, 10, AUDIO_PATH),
            token = "stop-command",
        }
        tick(timer)
        local before_release = #logger.entries
        port:queue{
            live = true,
            status = daemon_status("stopped", 1, 10, AUDIO_PATH),
            token = "release-1",
        }
        tick(timer)
        assert.is_true(#logger.entries > before_release)
        assert.are.equal(4, log_count(logger, "KoReadalong KindleAudio publication"))
        assert.is_true(log_has_argument(
            logger,
            "KoReadalong KindleAudio publication",
            "release-1"
        ))
    end)

    it("deduplicates repeated failure and unchanged-state logs", function()
        local logger = make_logger()
        local audio = make_audio{
            logger = logger,
            port = make_port{ live = false },
        }
        assert.is_nil(audio:open(AUDIO_PATH))
        local failure_count = log_count(
            logger,
            "KoReadalong KindleAudio failure"
        )
        local state_count = log_count(logger, "KoReadalong KindleAudio state")
        audio:_error("KinAMP daemon is not running; start KinAMP first")
        audio:_set_state(KindleAudio.STATES.ERROR)
        assert.are.equal(failure_count, log_count(
            logger,
            "KoReadalong KindleAudio failure"
        ))
        assert.are.equal(state_count, log_count(
            logger,
            "KoReadalong KindleAudio state"
        ))
    end)

    it("logs owned cleanup transitions without repeating them", function()
        local audio, timer, port, writer, logger = start_ready{
            logger = make_logger(),
        }
        assert.is_true(audio:open(AUDIO_PATH))
        port:queue{
            live = true,
            status = daemon_status("playing", 1, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(timer)
        assert.is_true(audio:close())
        port:queue{
            live = true,
            status = daemon_status("stopped", 1, 10, AUDIO_PATH),
            token = "a1",
        }
        tick(timer)
        port:queue{
            live = true,
            status = daemon_status("stopped", 0, 10, AUDIO_PATH),
            token = "a2",
        }
        tick(timer)
        assert.are.equal(2, log_count(logger, "KoReadalong KindleAudio playlist"))
        assert.is_true(log_has_argument(logger, "KoReadalong KindleAudio playlist", "removed"))
        assert.are.equal(1, log_count(logger, "KoReadalong KindleAudio port"))
        assert.is_true(log_has_argument(logger, "KoReadalong KindleAudio port", "closed"))
        assert.are.equal(1, #writer.removed)
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

    it("retries a busy preflight after the daemon becomes idle", function()
        local port = make_port{
            probe_result = {
                live = true,
                status = daemon_status("paused", 2, 10, "/mnt/us/other.mp3"),
                token = "busy",
            },
        }
        local audio, timer, _, writer = make_audio{ port = port }
        local opened, error_message = audio:open(AUDIO_PATH)
        assert.is_nil(opened)
        assert.matches("KinAMP is busy", error_message)
        assert.is_true(audio:getStatus().recoverable)
        assert.are.equal(0, #writer.created)

        port.status = daemon_status("stopped", 0, 0, "")
        port.token = "idle"
        port:queue{
            live = true,
            status = daemon_status("stopped", 0, 0, ""),
            token = "fresh-idle",
        }
        assert.is_true(audio:stop())
        assert.is_true(audio:open(AUDIO_PATH))
        assert.are.equal(1, #writer.created)
        assert.are.equal(1, command_count(port, "load"))
        assert.is_not_nil(timer.tasks[audio.poll_action])
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

    it("resumes by seeking to the paused second without duplicate commands", function()
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
            status = daemon_status("paused", 186, 482, AUDIO_PATH),
            token = "a2",
        }
        tick(timer)
        assert.are.equal("paused", audio:getStatus().state)

        local seeks_before = command_count(port, "seek")
        local plays_before = command_count(port, "play")
        assert.is_true(audio:setPaused(false))
        assert.is_true(audio:setPaused(false))
        assert.are.equal(seeks_before + 1, command_count(port, "seek"))
        assert.are.equal(plays_before, command_count(port, "play"))
        assert.are.same({ { "seek", 186 } }, port.commands[#port.commands])
        port:queue{
            live = true,
            status = daemon_status("playing", 186, 482, AUDIO_PATH),
            token = "a3",
        }
        tick(timer)
        assert.are.equal("playing", audio:getStatus().state)

        local pauses_before = command_count(port, "pause")
        assert.is_true(audio:setPaused(true))
        assert.is_true(audio:setPaused(true))
        assert.are.equal(pauses_before + 1, command_count(port, "pause"))
        port:queue{
            live = true,
            status = daemon_status("paused", 186, 482, AUDIO_PATH),
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
        local audio, timer, port, writer, logger = start_ready{
            logger = make_logger(),
        }
        port.send_error = "open write failed"
        local opened, error_message = audio:open(AUDIO_PATH)
        assert.is_nil(opened)
        assert.matches("open write failed", error_message)
        assert.is_false(audio:getStatus().recoverable)
        assert.are.equal(1, log_count(logger, "KoReadalong KindleAudio failure"))
        assert.is_true(log_has_argument(
            logger,
            "KoReadalong KindleAudio failure",
            "terminal"
        ))
        assert.are.equal(1, #writer.created)
        local retry, retry_error = audio:open(AUDIO_PATH)
        assert.is_nil(retry)
        assert.matches("terminal error state", retry_error)

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
