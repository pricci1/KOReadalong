package.path = "./koreadalong.koplugin/?.lua;"
    .. ".cache/koreader/lib/koreader/?.lua;"
    .. ".cache/koreader/lib/koreader/common/?.lua;"
    .. package.path
package.cpath = ".cache/koreader/lib/koreader/common/?.so;" .. package.cpath

local ffi = require("ffi")
require("ffi/posix_h")

local MpvAudio = require("mpvaudio")
local MpvProcess = require("mpvprocess")
local MpvTransport = require("mpvtransport")

local C = ffi.C

local function monotonic()
    local timespec = ffi.new("struct timespec")
    C.clock_gettime(C.CLOCK_MONOTONIC, timespec)
    return tonumber(timespec.tv_sec) + tonumber(timespec.tv_nsec) / 1000000000
end

local function fake_timer(clock)
    local timer = { tasks = {}, clock = clock }
    function timer:scheduleIn(delay, action)
        self.tasks[action] = self.clock() + delay
    end
    function timer:unschedule(action)
        self.tasks[action] = nil
    end
    function timer:run_due()
        local due = {}
        local now = self.clock()
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

local function wait_for(timer, predicate, timeout)
    local deadline = monotonic() + timeout
    while monotonic() < deadline do
        timer:run_due()
        if predicate() then
            return true
        end
        C.usleep(10000)
    end
    timer:run_due()
    return predicate()
end

local function little_endian(value, bytes)
    local result = {}
    for _ = 1, bytes do
        result[#result + 1] = string.char(value % 256)
        value = math.floor(value / 256)
    end
    return table.concat(result)
end

local function write_wav(path, duration)
    local sample_rate = 8000
    local sample_count = math.floor(sample_rate * duration)
    local data_size = sample_count * 2
    local data = string.rep("\0\0", sample_count)
    local wav = "RIFF"
        .. little_endian(36 + data_size, 4)
        .. "WAVEfmt "
        .. little_endian(16, 4)
        .. little_endian(1, 2)
        .. little_endian(1, 2)
        .. little_endian(sample_rate, 4)
        .. little_endian(sample_rate * 2, 4)
        .. little_endian(2, 2)
        .. little_endian(16, 2)
        .. "data"
        .. little_endian(data_size, 4)
        .. data
    local file = assert(io.open(path, "wb"))
    file:write(wav)
    file:close()
end

local function path_exists(path)
    local ok = os.rename(path, path)
    return ok == true
end

describe("production mpv desktop audio integration", function()
    local audio
    local timer
    local process
    local wav_path
    local invalid_path

    after_each(function()
        if audio then
            audio:close()
        end
        if timer then
            wait_for(timer, function()
                return not process or process:is_done()
            end, 2)
        end
        if wav_path then
            os.remove(wav_path)
        end
        if invalid_path then
            os.remove(invalid_path)
        end
        audio = nil
        timer = nil
        process = nil
        wav_path = nil
        invalid_path = nil
    end)

    it("loads, clocks, pauses, seeks, stops, reaches EOF, rejects bad media, and cleans up", function()
        if not os.getenv("KOREADER_MPV_INTEGRATION") then
            pending("set KOREADER_MPV_INTEGRATION=1 for the real mpv check")
            return
        end

        wav_path = os.tmpname() .. ".wav"
        invalid_path = os.tmpname() .. ".media"
        write_wav(wav_path, 6)
        local invalid_file = assert(io.open(invalid_path, "wb"))
        invalid_file:write("not an audio file")
        invalid_file:close()

        local clock = monotonic
        timer = fake_timer(clock)
        process = MpvProcess.new{
            -- Null is a test-only sink. Production arguments retain the
            -- no-fallback policy and never add this option.
            test_only = true,
            extra_args = { "--ao=null" },
        }
        local production_transport = MpvTransport.new()
        local seek_target
        local seek_observed = false
        local pause_observed
        local paused_position_observed
        local pause_true_commands = 0
        local transport_send = production_transport.send
        function production_transport:send(message)
            if message.command[1] == "seek" then
                seek_target = message.command[2]
            end
            if message.command[1] == "set_property"
                and message.command[2] == "pause"
                and message.command[3] == true then
                pause_true_commands = pause_true_commands + 1
            end
            return transport_send(self, message)
        end
        local transport_poll = production_transport.poll
        function production_transport:poll(now)
            local events = transport_poll(self, now)
            for _, event in ipairs(events) do
                if event.kind == "message" and event.message.event == "property-change"
                    and event.message.name == "pause" and event.message.data == true then
                    pause_observed = true
                end
                if pause_observed and event.kind == "message"
                    and event.message.event == "property-change"
                    and event.message.name == "time-pos"
                    and type(event.message.data) == "number" then
                    paused_position_observed = event.message.data
                end
                if seek_target == 0.2 and event.kind == "message"
                    and event.message.event == "property-change"
                    and event.message.name == "time-pos"
                    and type(event.message.data) == "number"
                    and math.abs(event.message.data - 0.2) < 0.12 then
                    seek_observed = true
                end
            end
            return events
        end
        audio = MpvAudio.new{
            clock = clock,
            timer = timer,
            process = process,
            transport = production_transport,
        }

        assert.is_true(audio:open(wav_path, {
            position = 0.35,
            paused = false,
            speed = 2,
        }))
        assert.is_true(wait_for(timer, function()
            return audio:getStatus().state == "playing"
                or audio:getStatus().state == "error"
        end, 3))
        assert.are_not.equal("error", audio:getStatus().state, audio:getStatus().error)
        assert.is_true(audio:getStatus().duration > 0.7)
        assert.are.equal(0.35, seek_target)
        assert.is_true(wait_for(timer, function()
            return audio:getStatus().speed == 2
        end, 0.8))

        local first_position = audio:getStatus().position or 0
        assert.is_true(wait_for(timer, function()
            return (audio:getStatus().position or 0) > first_position + 0.08
        end, 0.8))

        local pause_true_before = pause_true_commands
        pause_observed = false
        paused_position_observed = nil
        assert.is_true(audio:setPaused(true))
        assert.is_true(audio:setPaused(true))
        assert.are.equal(pause_true_before + 1, pause_true_commands)
        assert.is_true(wait_for(timer, function()
            return pause_observed and audio:getStatus().state == "paused"
        end, 0.8), audio:getStatus().state)
        -- mpv can delay the final time-pos notification beyond the pause ack.
        -- Measure from that observed position, not a stale pre-pause sample.
        assert.is_true(wait_for(timer, function()
            return paused_position_observed ~= nil
        end, 1.5))
        local paused_position = paused_position_observed
        C.usleep(250000)
        timer:run_due()
        assert.is_true(math.abs((audio:getStatus().position or 0) - paused_position) < 0.06)

        assert.is_true(audio:setSpeed(0.5))
        assert.is_true(wait_for(timer, function()
            return audio:getStatus().speed == 0.5
        end, 0.8))
        assert.are.equal("paused", audio:getStatus().state)
        assert.is_true(audio:seek(0.2))
        assert.is_true(wait_for(timer, function()
            return seek_observed
        end, 0.8))

        assert.is_true(audio:setPaused(false))
        assert.is_true(wait_for(timer, function()
            return audio:getStatus().state == "playing"
        end, 0.8))
        -- Compare the real media clock to wall time, not merely an IPC ack.
        local slow_position = audio:getStatus().position
        local slow_start = monotonic()
        while monotonic() - slow_start < 0.65 do
            timer:run_due()
            C.usleep(10000)
        end
        local advanced = audio:getStatus().position - slow_position
        assert.is_true(advanced > 0.15 and advanced < 0.48, tostring(advanced))

        assert.is_true(audio:stop())
        assert.is_true(wait_for(timer, function()
            return audio:getStatus().state == "idle"
        end, 0.8))

        assert.is_true(audio:open(wav_path, {
            position = 0,
            paused = false,
            speed = 2,
        }))
        assert.is_true(wait_for(timer, function()
            return audio:getStatus().speed == 2
        end, 0.8))
        assert.is_true(wait_for(timer, function()
            return audio:getStatus().state == "ended"
                or audio:getStatus().state == "error"
        end, 5))
        assert.are.equal("ended", audio:getStatus().state, audio:getStatus().error)

        assert.is_true(audio:stop())
        assert.is_true(wait_for(timer, function()
            return audio:getStatus().state == "idle"
        end, 0.8))

        assert.is_true(audio:open(invalid_path, {
            position = 0,
            paused = false,
        }))
        assert.is_true(wait_for(timer, function()
            return audio:getStatus().state == "error"
        end, 1.5))
        assert.matches("mpv", audio:getStatus().error)

        local session_dir = process.session_dir
        assert.is_true(audio:close())
        assert.is_true(audio:close())
        assert.is_true(wait_for(timer, function()
            return process:is_done()
        end, 2))
        assert.is_true(process.reaped)
        assert.is_false(path_exists(process.socket_path))
        assert.is_false(path_exists(session_dir))
        assert.are.equal("closed", audio:getStatus().state)
    end)
end)
