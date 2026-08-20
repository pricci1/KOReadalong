package.path = "./koreadalong.koplugin/?.lua;"
    .. ".cache/koreader/lib/koreader/?.lua;"
    .. ".cache/koreader/lib/koreader/common/?.lua;"
    .. package.path
package.cpath = ".cache/koreader/lib/koreader/common/?.so;" .. package.cpath

local MpvAudio = require("mpvaudio")
local MpvTransport = require("mpvtransport")

local function fake_timer()
    local timer = {
        now = 0,
        tasks = {},
        schedule_count = 0,
        unschedule_count = 0,
    }
    function timer:scheduleIn(delay, action)
        self.schedule_count = self.schedule_count + 1
        self.tasks[action] = self.now + delay
    end
    function timer:unschedule(action)
        if self.tasks[action] then
            self.tasks[action] = nil
            self.unschedule_count = self.unschedule_count + 1
        end
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

local function fake_process()
    local process = {
        started = false,
        closing = false,
        done = false,
        poll_events = {},
        begin_close_count = 0,
        cleanup_count = 0,
    }
    function process:start()
        self.started = true
        return "/tmp/koreadalong-test.sock"
    end
    function process:poll()
        local events = self.poll_events
        self.poll_events = {}
        if self.closing and not self.done then
            self.done = true
            events[#events + 1] = { kind = "closed" }
        end
        return events
    end
    function process:begin_close()
        self.closing = true
        self.begin_close_count = self.begin_close_count + 1
    end
    function process:is_done()
        return self.done
    end
    function process:cleanup()
        self.cleanup_count = self.cleanup_count + 1
    end
    return process
end

local function fake_transport()
    local transport = {
        connected = false,
        closed = false,
        events = {},
        sent = {},
        close_count = 0,
    }
    function transport:connect()
        return true
    end
    function transport:poll()
        local events = self.events
        self.events = {}
        if not self.connected then
            self.connected = true
            table.insert(events, 1, { kind = "connected" })
        end
        return events
    end
    function transport:send(message)
        if self.closed then
            return nil, "EPIPE"
        end
        self.sent[#self.sent + 1] = message
        return true
    end
    function transport:close()
        if not self.closed then
            self.closed = true
            self.close_count = self.close_count + 1
        end
    end
    function transport:push(message)
        self.events[#self.events + 1] = { kind = "message", message = message }
    end
    function transport:push_error(kind, error_message)
        self.events[#self.events + 1] = { kind = kind, error = error_message }
    end
    return transport
end

local function make_adapter()
    local timer = fake_timer()
    local process = fake_process()
    local transport = fake_transport()
    local adapter = MpvAudio.new{
        timer = timer,
        clock = function() return timer.now end,
        process = process,
        transport = transport,
    }
    return adapter, timer, process, transport
end

local function tick(timer)
    timer:advance(0.18)
end

local function sent_request(transport, command_name)
    for index = #transport.sent, 1, -1 do
        local message = transport.sent[index]
        if message.command[1] == command_name then
            return message
        end
    end
end

local function reply(transport, request, error_message)
    transport:push{
        request_id = request.request_id,
        error = error_message or "success",
    }
end

describe("mpv JSON line framing", function()
    it("reassembles fragmented lines and preserves coalesced order", function()
        local codec = MpvTransport.LineCodec.new()
        local messages = codec:feed('{"event":"first"')
        assert.are.same({}, messages)
        messages = codec:feed('}\n{"event":"second"}\n')
        assert.are.equal(2, #messages)
        assert.are.equal("first", messages[1].message.event)
        assert.are.equal("second", messages[2].message.event)
    end)

    it("reports malformed JSON without losing the following message", function()
        local codec = MpvTransport.LineCodec.new()
        local messages = codec:feed("not json\n{\"event\":\"ok\"}\n")
        assert.are.equal(2, #messages)
        assert.are.equal("error", messages[1].kind)
        assert.matches("malformed mpv IPC JSON", messages[1].error)
        assert.are.equal("ok", messages[2].message.event)
    end)
end)

describe("desktop mpv audio adapter", function()
    it("starts in startup, loads asynchronously, and reconciles observed playback", function()
        local adapter, timer, process, transport = make_adapter()
        assert.are.equal("startup", adapter:getStatus().state)
        assert.is_true(adapter:load("/tmp/book/audio.wav"))
        assert.is_true(process.started)
        assert.are.equal("loading", adapter:getStatus().state)

        tick(timer)
        local load_request = sent_request(transport, "loadfile")
        assert.is_not_nil(load_request)
        reply(transport, load_request)
        transport:push{ event = "property-change", name = "duration", data = 2 }
        transport:push{ event = "property-change", name = "idle-active", data = false }
        transport:push{ event = "property-change", name = "pause", data = false }
        tick(timer)
        assert.are.equal("playing", adapter:getStatus().state)
        assert.are.equal(2, adapter:getStatus().duration)

        assert.is_true(adapter:pause())
        local pause_request = sent_request(transport, "set_property")
        assert.are.same({ "set_property", "pause", true }, pause_request.command)
        reply(transport, pause_request)
        tick(timer)
        assert.are.equal("paused", adapter:getStatus().state)

        assert.is_true(adapter:resume())
        local resume_request = sent_request(transport, "set_property")
        assert.are.same({ "set_property", "pause", false }, resume_request.command)
        transport:push{ event = "property-change", name = "pause", data = false }
        tick(timer)
        assert.are.equal("playing", adapter:getStatus().state)

        assert.is_true(adapter:seek(1.25))
        local seek_request = sent_request(transport, "seek")
        assert.are.same({ "seek", 1.25, "absolute+exact" }, seek_request.command)
        assert.is_nil(adapter:seek(-1))
    end)

    it("does not treat loadfile success as decode success and handles EOF and stop", function()
        local adapter, timer, _, transport = make_adapter()
        adapter:load("/tmp/book/audio.wav")
        tick(timer)
        local load_request = sent_request(transport, "loadfile")
        reply(transport, load_request)
        tick(timer)
        assert.are.equal("loading", adapter:getStatus().state)

        transport:push{ event = "playback-restart" }
        transport:push{ event = "property-change", name = "duration", data = 1 }
        transport:push{ event = "property-change", name = "idle-active", data = false }
        transport:push{ event = "property-change", name = "pause", data = false }
        tick(timer)
        assert.are.equal("playing", adapter:getStatus().state)

        transport:push{ event = "end-file", reason = "eof" }
        tick(timer)
        assert.are.equal("ended", adapter:getStatus().state)

        assert.is_true(adapter:stop())
        local stop_request = sent_request(transport, "stop")
        reply(transport, stop_request)
        tick(timer)
        assert.are.equal("idle", adapter:getStatus().state)
    end)

    it("discards stale replies/events by generation", function()
        local adapter, timer, _, transport = make_adapter()
        adapter:load("/tmp/first.wav")
        tick(timer)
        local first_request = sent_request(transport, "loadfile")
        adapter:load("/tmp/second.wav")
        transport:push{
            request_id = first_request.request_id,
            error = "success",
            generation = 1,
        }
        transport:push{
            event = "property-change",
            name = "duration",
            data = 99,
            generation = 1,
        }
        tick(timer)
        assert.are.equal("loading", adapter:getStatus().state)
        assert.is_nil(adapter:getStatus().duration)
        local second_request = sent_request(transport, "loadfile")
        assert.are_not.equal(first_request.request_id, second_request.request_id)
        reply(transport, second_request)
        transport:push{ event = "property-change", name = "duration", data = 3 }
        transport:push{ event = "property-change", name = "idle-active", data = false }
        transport:push{ event = "property-change", name = "pause", data = false }
        tick(timer)
        assert.are.equal("playing", adapter:getStatus().state)
        assert.are.equal(3, adapter:getStatus().duration)
    end)

    it("surfaces malformed/HUP/EPIPE-style transport failures and child exit", function()
        local adapter, timer, process, transport = make_adapter()
        adapter:load("/tmp/audio.wav")
        tick(timer)
        transport:push_error("error", "EAGAIN while writing")
        tick(timer)
        assert.are.equal("error", adapter:getStatus().state)
        assert.matches("EAGAIN", adapter:getStatus().error)

        transport:push_error("closed", "HUP")
        tick(timer)
        assert.matches("HUP", adapter:getStatus().error)

        process.poll_events[#process.poll_events + 1] = {
            kind = "exit",
            status = { exited = true, exit_code = 1 },
        }
        tick(timer)
        assert.matches("mpv exited", adapter:getStatus().error)
    end)

    it("makes close idempotent, unschedules polling, and rejects later commands", function()
        local adapter, timer, process, transport = make_adapter()
        adapter:load("/tmp/audio.wav")
        tick(timer)
        assert.is_true(adapter:close())
        assert.is_true(adapter:close())
        assert.are.equal("closed", adapter:getStatus().state)
        assert.are.equal(1, process.begin_close_count)
        assert.are.equal(1, timer.unschedule_count)
        assert.are.equal(0, transport.close_count)
        assert.is_nil(adapter:play())
        assert.is_nil(adapter:pause())
        assert.is_nil(adapter:seek(0))
        assert.is_nil(adapter:stop())
        assert.is_nil(adapter:load("/tmp/later.wav"))
        timer:advance(0.05)
        assert.are.equal(1, process.cleanup_count)
        assert.are.equal(1, transport.close_count)
    end)
end)
