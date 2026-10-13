package.path = "./koreadalong.koplugin/?.lua;"
    .. ".cache/koreader/lib/koreader/?.lua;"
    .. ".cache/koreader/lib/koreader/common/?.lua;"
    .. package.path
package.cpath = ".cache/koreader/lib/koreader/common/?.so;" .. package.cpath

local ffi = require("ffi")
local MpvAudio = require("mpvaudio")
local MpvTransport = require("mpvtransport")
local posix = require("mpvposix")

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

local function sent_count(transport, command_name)
    local count = 0
    for _, message in ipairs(transport.sent) do
        if message.command[1] == command_name then
            count = count + 1
        end
    end
    return count
end

local function sent_index(transport, request_id)
    for index, message in ipairs(transport.sent) do
        if message.request_id == request_id then
            return index
        end
    end
end

local function reply(transport, request, error_message)
    transport:push{
        request_id = request.request_id,
        error = error_message or "success",
    }
end

local function push_property(adapter, transport, name, data)
    local observer_id = adapter.active_observer_ids[name]
    assert.is_not_nil(observer_id)
    transport:push{
        event = "property-change",
        id = observer_id,
        name = name,
        data = data,
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

describe("production transport nonblocking IO", function()
    local function fake_io(send_results, recv_results)
        local io = {
            send_results = send_results or {},
            recv_results = recv_results or {},
            sent = {},
            close_count = 0,
        }
        io.send = function(fd, data, length)
            io.sent[#io.sent + 1] = data:sub(1, length)
            local result = table.remove(io.send_results, 1)
            if type(result) == "table" then
                return result[1], result[2]
            end
            return result or length
        end
        io.recv = function(_, buffer)
            local result = table.remove(io.recv_results, 1)
            if type(result) == "string" then
                ffi.copy(buffer, result, #result)
                return #result
            end
            result = result or { -1, posix.C.EAGAIN }
            return result[1], result[2]
        end
        io.close = function()
            io.close_count = io.close_count + 1
        end
        return io
    end

    local function connected_transport(io)
        local transport = MpvTransport.new{ io = io }
        transport.fd = 7
        transport.connected = true
        return transport
    end

    it("retains partial send offsets across EINTR and EAGAIN", function()
        local io = fake_io{
            2,
            { -1, posix.C.EINTR },
            { -1, posix.C.EAGAIN },
            4096,
        }
        local transport = connected_transport(io)
        assert.is_true(transport:send{ command = { "stop" }, request_id = 1 })

        local events = {}
        transport:_flush(events)
        assert.are.equal(3, transport.tx_offset)
        assert.are.same({}, events)
        transport:_flush(events)
        assert.are.equal(3, transport.tx_offset)
        assert.are.same({}, events)
        transport:_flush(events)
        assert.is_nil(transport.tx_queue[1])
        assert.are.same({}, events)
        assert.are.equal(4, #io.sent)
    end)

    it("turns EPIPE into a transport error and HUP/EOF into close", function()
        local io = fake_io{
            { -1, posix.C.EPIPE },
        }
        local transport = connected_transport(io)
        assert.is_true(transport:send{ command = { "stop" }, request_id = 1 })
        local events = {}
        transport:_flush(events)
        assert.matches("write failed", events[1].error)
        assert.is_false(transport.connected)
        assert.are.equal(1, io.close_count)

        io = fake_io(nil, {
            { -1, posix.C.EINTR },
            { 0 },
        })
        transport = connected_transport(io)
        events = {}
        transport:_read(events)
        assert.are.same({}, events)
        assert.is_true(transport.connected)
        transport:_read(events)
        assert.are.equal("closed", events[1].kind)
        assert.is_false(transport.connected)
        assert.are.equal(1, io.close_count)
    end)
end)

describe("desktop mpv audio adapter", function()
    it("stages speed before loading and reports speed command failures", function()
        local adapter, timer, _, transport = make_adapter()
        for _, speed in ipairs{ 0.49, 3.01, math.huge, 0/0, false } do
            assert.is_nil(adapter:setSpeed(speed))
            assert.is_nil(adapter:open("/tmp/audio.wav", { speed = speed }))
        end
        assert.is_true(adapter:setSpeed(1.7))
        assert.are.equal("startup", adapter:getStatus().state)
        assert.is_true(adapter:open("/tmp/audio.wav", { paused = true }))
        assert.is_true(adapter:setSpeed(0.8))
        tick(timer)
        reply(transport, sent_request(transport, "loadfile"))
        transport:push{ event = "file-loaded" }
        tick(timer)
        push_property(adapter, transport, "speed", 0.8)
        tick(timer)
        assert.are.equal(0.8, adapter:getStatus().speed)
        assert.is_true(adapter:setSpeed(2.3))
        local request = sent_request(transport, "set_property")
        reply(transport, request, "property unavailable")
        tick(timer)
        assert.are.equal("error", adapter:getStatus().state)
        assert.matches("speed failed", adapter:getStatus().error)
    end)

    it("starts in startup, opens asynchronously, and reconciles observed playback", function()
        local adapter, timer, process, transport = make_adapter()
        assert.are.equal("startup", adapter:getStatus().state)
        assert.is_true(adapter:open("/tmp/book/audio.wav", {
            position = 0.25,
            paused = false,
        }))
        assert.is_true(process.started)
        assert.are.equal("loading", adapter:getStatus().state)
        assert.are.equal(0, sent_count(transport, "seek"))
        assert.are.equal(0, sent_count(transport, "set_property"))

        tick(timer)
        local load_request = sent_request(transport, "loadfile")
        assert.is_not_nil(load_request)
        assert.are.equal(1, sent_count(transport, "set_property"))
        assert.are.same({ "set_property", "pause", true },
            sent_request(transport, "set_property").command)
        reply(transport, load_request)
        transport:push{ event = "file-loaded" }
        tick(timer)
        assert.are.equal(1, sent_count(transport, "seek"))
        assert.are.equal(2, sent_count(transport, "set_property"))
        assert.are.same({ "seek", 0.25, "absolute+exact" },
            sent_request(transport, "seek").command)
        assert.are.same({ "set_property", "pause", false },
            sent_request(transport, "set_property").command)
        push_property(adapter, transport, "duration", 2)
        push_property(adapter, transport, "idle-active", false)
        push_property(adapter, transport, "pause", false)
        tick(timer)
        assert.are.equal("playing", adapter:getStatus().state)
        assert.are.equal(2, adapter:getStatus().duration)

        assert.is_true(adapter:setPaused(true))
        local pause_request = sent_request(transport, "set_property")
        assert.are.same({ "set_property", "pause", true }, pause_request.command)
        local pause_count = sent_count(transport, "set_property")
        assert.is_true(adapter:setPaused(true))
        assert.are.equal(pause_count, sent_count(transport, "set_property"))
        reply(transport, pause_request)
        tick(timer)
        assert.are.equal("paused", adapter:getStatus().state)

        assert.is_true(adapter:setPaused(false))
        local resume_request = sent_request(transport, "set_property")
        assert.are.same({ "set_property", "pause", false }, resume_request.command)
        push_property(adapter, transport, "pause", false)
        tick(timer)
        assert.are.equal("playing", adapter:getStatus().state)

        assert.is_true(adapter:seek(1.25))
        local seek_request = sent_request(transport, "seek")
        assert.are.same({ "seek", 1.25, "absolute+exact" }, seek_request.command)
        assert.is_nil(adapter:seek(-1))
        assert.is_nil(adapter:seek(math.huge))
    end)

    it("does not treat loadfile success as decode success and handles EOF and stop", function()
        local adapter, timer, _, transport = make_adapter()
        adapter:open("/tmp/book/audio.wav", { paused = false })
        tick(timer)
        local load_request = sent_request(transport, "loadfile")
        reply(transport, load_request)
        tick(timer)
        assert.are.equal("loading", adapter:getStatus().state)

        transport:push{ event = "file-loaded" }
        tick(timer)
        transport:push{ event = "playback-restart" }
        push_property(adapter, transport, "duration", 1)
        push_property(adapter, transport, "idle-active", false)
        push_property(adapter, transport, "pause", false)
        tick(timer)
        assert.are.equal("playing", adapter:getStatus().state)

        transport:push{ event = "end-file", reason = "eof" }
        tick(timer)
        assert.are.equal("ended", adapter:getStatus().state)

        assert.is_true(adapter:stop())
        local stop_request = sent_request(transport, "stop")
        reply(transport, stop_request)
        tick(timer)
        assert.are.equal("ended", adapter:getStatus().state)
        transport:push{ event = "end-file", reason = "stop" }
        tick(timer)
        assert.are.equal("idle", adapter:getStatus().state)
    end)

    it("stages open options before the connection and rejects active replacement", function()
        local adapter, timer, _, transport = make_adapter()
        assert.is_true(adapter:open("/tmp/first.wav", {
            position = 0.5,
            paused = false,
        }))
        -- Both controls update the staged open request before the connection
        -- and before mpv emits file-loaded.
        assert.is_true(adapter:setPaused(true))
        assert.is_true(adapter:seek(1.5))
        assert.are.equal(0, #transport.sent)

        tick(timer)
        local first_load = sent_request(transport, "loadfile")
        assert.is_not_nil(first_load)
        assert.is_true(adapter.awaiting_file_loaded)
        local generation = adapter.generation
        local commands_before_rejection = #transport.sent

        local stopped, stop_error = adapter:stop()
        assert.is_nil(stopped)
        assert.matches("file%-loaded", stop_error)
        local replaced, replace_error = adapter:open("/tmp/second.wav", {
            position = 0,
            paused = false,
        })
        assert.is_nil(replaced)
        assert.matches("active", replace_error)
        assert.are.equal(generation, adapter.generation)
        assert.are.equal(commands_before_rejection, #transport.sent)
        assert.are.equal(1, sent_count(transport, "loadfile"))
        assert.are.equal(0, sent_count(transport, "stop"))

        -- These are production-shaped, untagged mpv messages for the first
        -- load. With no replacement admitted, they can only complete that
        -- same generation.
        reply(transport, first_load)
        transport:push{ event = "file-loaded" }
        tick(timer)
        assert.is_false(adapter.awaiting_file_loaded)
        assert.are.same({ "seek", 1.5, "absolute+exact" },
            sent_request(transport, "seek").command)
        assert.are.same({ "set_property", "pause", true },
            sent_request(transport, "set_property").command)
        push_property(adapter, transport, "duration", 2)
        push_property(adapter, transport, "idle-active", false)
        push_property(adapter, transport, "pause", false)
        tick(timer)
        assert.are.equal("loading", adapter:getStatus().state)
        push_property(adapter, transport, "pause", true)
        tick(timer)
        assert.are.equal(generation, adapter.generation)
        assert.are.equal("paused", adapter:getStatus().state)
    end)

    it("keeps delayed lifecycle messages in a closed session away from a new session", function()
        local first, first_timer, first_process, first_transport = make_adapter()
        assert.is_true(first:open("/tmp/first.wav"))
        tick(first_timer)
        assert.is_true(first:setPaused(true))
        assert.is_true(first:close())

        -- A late event/property pair from the closed session has no request
        -- generation field, just like real mpv IPC messages.
        first_transport:push{ event = "file-loaded" }
        first_transport:push{
            event = "property-change",
            id = 1,
            name = "duration",
            data = 99,
        }
        first_timer:advance(0.05)
        assert.are.equal(1, first_process.cleanup_count)
        assert.are.equal(1, first_transport.close_count)

        local second, second_timer, _, second_transport = make_adapter()
        assert.is_true(second:open("/tmp/second.wav"))
        tick(second_timer)
        assert.are.equal("loading", second:getStatus().state)
        assert.is_nil(second:getStatus().duration)

        local second_load = sent_request(second_transport, "loadfile")
        reply(second_transport, second_load)
        second_transport:push{ event = "file-loaded" }
        tick(second_timer)
        push_property(second, second_transport, "duration", 3)
        push_property(second, second_transport, "idle-active", false)
        push_property(second, second_transport, "pause", false)
        tick(second_timer)
        assert.are.equal("playing", second:getStatus().state)
        assert.are.equal(3, second:getStatus().duration)
    end)

    it("allows stop acknowledgement and a new open after idle", function()
        local adapter, timer, _, transport = make_adapter()
        assert.is_true(adapter:open("/tmp/first.wav"))
        tick(timer)
        local first_load = sent_request(transport, "loadfile")
        reply(transport, first_load)
        transport:push{ event = "file-loaded" }
        tick(timer)
        assert.is_false(adapter.awaiting_file_loaded)

        assert.is_true(adapter:stop())
        local stop_request = sent_request(transport, "stop")
        reply(transport, stop_request)
        transport:push{ event = "end-file", reason = "stop" }
        tick(timer)
        assert.are.equal("idle", adapter:getStatus().state)
        transport:push{ event = "end-file", reason = "eof" }
        tick(timer)
        assert.are.equal("idle", adapter:getStatus().state)

        assert.is_true(adapter:open("/tmp/second.wav"))
        local second_load = sent_request(transport, "loadfile")
        assert.is_not_nil(second_load)
        assert.are_not.equal(first_load.request_id, second_load.request_id)
        assert.are.equal(2, adapter.generation)
    end)

    it("uses production observer ids and orders a new open around file-loaded", function()
        local adapter, timer, _, transport = make_adapter()
        adapter:open("/tmp/first.wav")
        tick(timer)
        local first_request = sent_request(transport, "loadfile")
        reply(transport, first_request)
        transport:push{ event = "file-loaded" }
        tick(timer)
        local old_duration_id = adapter.active_observer_ids.duration
        push_property(adapter, transport, "duration", 2)
        push_property(adapter, transport, "idle-active", false)
        push_property(adapter, transport, "pause", false)
        tick(timer)
        assert.are.equal("playing", adapter:getStatus().state)

        assert.is_true(adapter:stop())
        local stop_request = sent_request(transport, "stop")
        reply(transport, stop_request)
        transport:push{ event = "end-file", reason = "stop" }
        tick(timer)
        assert.are.equal("idle", adapter:getStatus().state)

        assert.is_true(adapter:open("/tmp/second.wav"))
        local second_request = sent_request(transport, "loadfile")
        assert.are_not.equal(first_request.request_id, second_request.request_id)
        local second_load_index = sent_index(transport, second_request.request_id)
        assert.are.equal("unobserve_property",
            transport.sent[second_load_index - 1].command[1])

        reply(transport, second_request)
        transport:push{ event = "end-file", reason = "stop" }
        transport:push{
            event = "property-change",
            id = old_duration_id,
            name = "duration",
            data = 99,
        }
        transport:push{ event = "file-loaded" }
        tick(timer)
        assert.are.equal("loading", adapter:getStatus().state)
        assert.is_nil(adapter:getStatus().duration)
        assert.are_not.equal(old_duration_id, adapter.active_observer_ids.duration)

        push_property(adapter, transport, "duration", 3)
        push_property(adapter, transport, "idle-active", false)
        push_property(adapter, transport, "pause", false)
        tick(timer)
        assert.are.equal("playing", adapter:getStatus().state)
        assert.are.equal(3, adapter:getStatus().duration)
    end)

    it("keeps the first terminal error across same-batch messages and timer orders", function()
        local function run_order(teardown_first)
            local adapter, timer, process, transport = make_adapter()
            adapter:open("/tmp/audio.wav")
            tick(timer)
            local load_request = sent_request(transport, "loadfile")
            reply(transport, load_request)
            transport:push{ event = "file-loaded" }
            tick(timer)
            push_property(adapter, transport, "duration", 2)
            push_property(adapter, transport, "idle-active", false)
            push_property(adapter, transport, "pause", false)
            tick(timer)

            transport:push_error("error", "malformed mpv IPC JSON: bad line")
            transport:push{ event = "end-file", reason = "eof" }
            push_property(adapter, transport, "duration", 99)
            tick(timer)
            assert.are.equal("error", adapter:getStatus().state)
            assert.matches("malformed mpv IPC JSON", adapter:getStatus().error)

            transport:push_error("closed", "HUP")
            process.poll_events[#process.poll_events + 1] = {
                kind = "exit",
                status = { exited = true, exit_code = 1 },
            }
            if teardown_first then
                adapter.teardown_action()
                adapter.poll_action()
            else
                adapter.poll_action()
                adapter.teardown_action()
            end
            assert.are.equal("error", adapter:getStatus().state)
            assert.matches("malformed mpv IPC JSON", adapter:getStatus().error)
        end

        run_order(true)
        run_order(false)
    end)

    it("makes close idempotent, unschedules polling, and rejects later commands", function()
        local adapter, timer, process, transport = make_adapter()
        adapter:open("/tmp/audio.wav")
        tick(timer)
        assert.is_true(adapter:close())
        assert.is_true(adapter:close())
        assert.are.equal("closed", adapter:getStatus().state)
        assert.are.equal(1, process.begin_close_count)
        assert.are.equal(1, timer.unschedule_count)
        assert.are.equal(0, transport.close_count)
        assert.is_nil(adapter:setPaused(true))
        assert.is_nil(adapter:seek(0))
        assert.is_nil(adapter:stop())
        assert.is_nil(adapter:open("/tmp/later.wav"))
        timer:advance(0.05)
        assert.are.equal(1, process.cleanup_count)
        assert.are.equal(1, transport.close_count)
    end)

    it("does not flush a queued load after closing before IPC connects", function()
        local adapter, timer, process, transport = make_adapter()
        assert.is_true(adapter:open("/tmp/audio.wav"))
        assert.is_true(adapter:close())
        timer:advance(0.05)
        assert.are.equal("closed", adapter:getStatus().state)
        assert.are.equal(0, #transport.sent)
        assert.are.equal(1, process.cleanup_count)
        assert.are.equal(1, transport.close_count)
        assert.is_nil(timer.tasks[adapter.teardown_action])
    end)
end)
