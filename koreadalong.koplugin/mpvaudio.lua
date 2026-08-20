local MpvProcess = require("mpvprocess")
local MpvTransport = require("mpvtransport")

local MpvAudio = {}
MpvAudio.__index = MpvAudio

MpvAudio.STATES = {
    STARTUP = "startup",
    IDLE = "idle",
    LOADING = "loading",
    PLAYING = "playing",
    PAUSED = "paused",
    ENDED = "ended",
    ERROR = "error",
    CLOSED = "closed",
}

local POLL_INTERVAL = 0.18
local STARTUP_TIMEOUT = 2

local OBSERVED_PROPERTIES = {
    "time-pos",
    "duration",
    "pause",
    "idle-active",
}

local function default_timer()
    return require("ui/uimanager")
end

local function default_clock()
    local time = require("ui/time")
    return time.to_s(time.now())
end

local function invoke(object, method_name, ...)
    local method = object and object[method_name]
    if type(method) ~= "function" then
        return nil, "mpv dependency is missing " .. method_name
    end
    return method(object, ...)
end

function MpvAudio.new(options)
    options = options or {}
    local self = setmetatable({
        timer = options.timer or default_timer(),
        clock = options.clock or default_clock,
        process = options.process,
        process_factory = options.process_factory,
        process_options = options.process_options,
        transport = options.transport,
        transport_factory = options.transport_factory,
        state = MpvAudio.STATES.STARTUP,
        generation = 0,
        next_request_id = 0,
        pending_requests = {},
        queued_commands = {},
        status = {
            state = MpvAudio.STATES.STARTUP,
            position = nil,
            duration = nil,
            paused = nil,
            error = nil,
        },
        poll_scheduled = false,
        teardown_scheduled = false,
        closed = false,
        connected = false,
        startup_deadline = nil,
        load_acknowledged = false,
    }, MpvAudio)

    self.poll_action = function()
        self.poll_scheduled = false
        if not self.closed then
            self:_poll()
            self:_schedule_poll()
        end
    end
    self.teardown_action = function()
        self.teardown_scheduled = false
        self:_poll_teardown()
    end
    return self
end

function MpvAudio:_set_state(state)
    self.state = state
    self.status.state = state
end

function MpvAudio:_schedule_poll()
    if self.closed or self.poll_scheduled then
        return
    end
    self.poll_scheduled = true
    self.timer:scheduleIn(POLL_INTERVAL, self.poll_action)
end

function MpvAudio:_schedule_teardown()
    if self.teardown_scheduled then
        return
    end
    self.teardown_scheduled = true
    self.timer:scheduleIn(0.05, self.teardown_action)
end

function MpvAudio:_fail(error_message)
    if self.closed then
        return
    end
    self.status.error = tostring(error_message)
    self:_set_state(MpvAudio.STATES.ERROR)
end

function MpvAudio:_abort_session()
    if self.abort_started then
        return
    end
    self.abort_started = true
    self.connected = false
    invoke(self.transport, "close")
    if self.process then
        self.process:begin_close(self.clock())
    end
    local process_done = not self.process
    if self.process then
        process_done = self.process:is_done()
    end
    if process_done then
        invoke(self.process, "cleanup")
    else
        self:_schedule_teardown()
    end
end

function MpvAudio:_new_process()
    if self.process and self.process_started then
        return true
    end
    if not self.process then
        if self.process_factory then
            self.process = self.process_factory(self.process_options)
        else
            self.process = MpvProcess.new(self.process_options)
        end
    end
    if not self.process then
        self:_fail("unable to create mpv process")
        return nil
    end
    local socket_path, start_error = invoke(self.process, "start")
    if not socket_path then
        self:_fail(start_error or "unable to start mpv")
        return nil
    end
    self.process_started = true
    self.socket_path = socket_path
    if not self.transport then
        self.transport = self.transport_factory
            and self.transport_factory()
            or MpvTransport.new()
    end
    local now = self.clock()
    local connected, connect_result = invoke(
        self.transport,
        "connect",
        socket_path,
        now,
        STARTUP_TIMEOUT
    )
    if connected == nil then
        self:_fail(connect_result or "unable to connect to mpv")
        self:_abort_session()
        return nil
    end
    self.startup_deadline = now + STARTUP_TIMEOUT
    if type(connect_result) == "table" then
        self:_on_transport_event(connect_result)
    end
    self:_schedule_poll()
    return true
end

function MpvAudio:_next_request(command, kind, generation, metadata)
    self.next_request_id = self.next_request_id + 1
    local request_id = self.next_request_id
    self.pending_requests[request_id] = {
        kind = kind,
        generation = generation or self.generation,
    }
    for key, value in pairs(metadata or {}) do
        self.pending_requests[request_id][key] = value
    end
    local sent, send_error = invoke(self.transport, "send", {
        command = command,
        request_id = request_id,
    })
    if sent == nil or sent == false then
        self.pending_requests[request_id] = nil
        return nil, send_error or "unable to send mpv command"
    end
    return request_id
end

function MpvAudio:_queue_or_send(command, kind)
    if not self.connected then
        self.queued_commands[#self.queued_commands + 1] = {
            command = command,
            kind = kind,
            generation = self.generation,
        }
        return true
    end
    local request_id, send_error = self:_next_request(
        command,
        kind,
        self.generation
    )
    if not request_id then
        self:_fail(send_error)
        return nil, send_error
    end
    return true
end

function MpvAudio:_send_observers()
    for _, property in ipairs(OBSERVED_PROPERTIES) do
        local request_id, send_error = self:_next_request(
            { "observe_property", self.next_request_id + 1, property },
            "observe",
            self.generation
        )
        if not request_id then
            self:_fail(send_error)
            return nil
        end
    end
    return true
end

function MpvAudio:_send_pending_commands()
    if self.pending_load then
        local pending_load = self.pending_load
        self.pending_load = nil
        local request_id, send_error = self:_next_request(
            { "loadfile", pending_load.path, "replace" },
            "load",
            pending_load.generation
        )
        if not request_id then
            self:_fail(send_error)
            return nil
        end
        self.load_request_id = request_id
    end

    local queued = self.queued_commands
    self.queued_commands = {}
    for _, queued_command in ipairs(queued) do
        if queued_command.generation == self.generation then
            local request_id, send_error = self:_next_request(
                queued_command.command,
                queued_command.kind,
                queued_command.generation,
                queued_command
            )
            if not request_id then
                self:_fail(send_error)
                return nil
            end
        end
    end
    return true
end

function MpvAudio:_on_connected(event)
    if event.generation and event.generation ~= self.generation then
        return
    end
    self.connected = true
    if not self:_send_observers() then
        return
    end
    self:_send_pending_commands()
end

function MpvAudio:_reconcile()
    if self.state == MpvAudio.STATES.ERROR
        or not self.load_acknowledged then
        return
    end
    if self.status.idle_active == false and self.status.duration then
        if self.status.paused then
            self:_set_state(MpvAudio.STATES.PAUSED)
        else
            self:_set_state(MpvAudio.STATES.PLAYING)
        end
    elseif self.status.idle_active == true
        and self.state ~= MpvAudio.STATES.ENDED
        and self.state ~= MpvAudio.STATES.ERROR then
        self:_set_state(MpvAudio.STATES.IDLE)
    end
end

function MpvAudio:_on_property_change(message)
    if message.generation and message.generation ~= self.generation then
        return
    end
    local property = message.name
    if property == "time-pos" and type(message.data) == "number" then
        self.status.position = message.data
    elseif property == "duration" and type(message.data) == "number" then
        self.status.duration = message.data
    elseif property == "pause" and type(message.data) == "boolean" then
        self.status.paused = message.data
    elseif property == "idle-active" and type(message.data) == "boolean" then
        self.status.idle_active = message.data
    end
    self:_reconcile()
end

function MpvAudio:_on_event(message)
    if message.generation and message.generation ~= self.generation then
        return
    end
    if message.event == "playback-restart" then
        self:_reconcile()
    elseif message.event == "end-file" then
        local reason = message.reason or (message.data and message.data.reason)
        if reason == "eof" then
            if self.status.duration then
                self.status.position = self.status.duration
            end
            self:_set_state(MpvAudio.STATES.ENDED)
        elseif reason == "stop" or reason == "quit" then
            self:_set_state(MpvAudio.STATES.IDLE)
        elseif reason == "error" then
            self:_fail("mpv media error")
        end
    end
end

function MpvAudio:_on_reply(message)
    local request = self.pending_requests[message.request_id]
    if not request then
        return
    end
    self.pending_requests[message.request_id] = nil
    if request.generation ~= self.generation then
        return
    end
    if message.error and message.error ~= "success" then
        self:_fail("mpv " .. request.kind .. " failed: " .. tostring(message.error))
        return
    end
    if request.kind == "load" then
        self.load_acknowledged = true
        self.status.error = nil
        self:_reconcile()
    elseif request.kind == "pause" then
        self.status.paused = request.paused
        self:_reconcile()
    elseif request.kind == "stop" then
        self.load_acknowledged = false
        self.status.position = 0
        self.status.duration = nil
        self.status.paused = nil
        self.status.idle_active = true
        self:_set_state(MpvAudio.STATES.IDLE)
    end
end

function MpvAudio:_on_message(message)
    if type(message) ~= "table" then
        return
    end
    if message.request_id ~= nil then
        self:_on_reply(message)
    elseif message.event == "property-change" then
        self:_on_property_change(message)
    elseif message.event then
        self:_on_event(message)
    end
end

function MpvAudio:_on_transport_event(event)
    if event.generation and event.generation ~= self.generation then
        return
    end
    if event.kind == "connected" then
        self:_on_connected(event)
    elseif event.kind == "message" then
        self:_on_message(event.message)
    elseif event.kind == "closed" then
        self.connected = false
        self:_fail(event.error or "mpv IPC socket closed")
        self:_abort_session()
    elseif event.kind == "error" then
        self.connected = false
        self:_fail(event.error)
        self:_abort_session()
    end
end

function MpvAudio:_poll()
    local now = self.clock()
    local process_events = invoke(self.process, "poll", now)
    if type(process_events) == "table" then
        for _, event in ipairs(process_events) do
            if event.kind == "exec_error" or event.kind == "wait_error" then
                self:_fail(event.error)
                self:_abort_session()
            elseif event.kind == "exit"
                and self.state ~= MpvAudio.STATES.ENDED then
                self:_fail("mpv exited before the session completed")
                self:_abort_session()
            end
        end
    end

    local transport_events = invoke(self.transport, "poll", now)
    if type(transport_events) == "table" then
        for _, event in ipairs(transport_events) do
            self:_on_transport_event(event)
        end
    end

    if self.startup_deadline and not self.connected and now >= self.startup_deadline
        and self.state ~= MpvAudio.STATES.ERROR then
        self:_fail("timed out starting mpv IPC")
        self:_abort_session()
    end
end

function MpvAudio:load(local_file_path)
    if self.closed then
        return nil, "mpv audio adapter is closed"
    end
    if type(local_file_path) ~= "string" or local_file_path == "" then
        return nil, "audio path must be a non-empty local path"
    end
    self.generation = self.generation + 1
    self.status.position = 0
    self.status.duration = nil
    self.status.paused = nil
    self.status.idle_active = nil
    self.status.error = nil
    self.load_acknowledged = false
    self.load_request_id = nil
    self:_set_state(MpvAudio.STATES.LOADING)

    local retained_commands = {}
    for _, queued_command in ipairs(self.queued_commands) do
        if queued_command.generation == self.generation then
            retained_commands[#retained_commands + 1] = queued_command
        end
    end
    self.queued_commands = retained_commands
    self.pending_load = {
        path = local_file_path,
        generation = self.generation,
    }
    if not self:_new_process() then
        return nil, self.status.error
    end
    self:_schedule_poll()
    if self.connected then
        self:_send_pending_commands()
    end
    return true
end

function MpvAudio:play()
    if self.closed then
        return nil, "mpv audio adapter is closed"
    end
    local ok, error_message = self:_queue_or_send(
        { "set_property", "pause", false },
        "play"
    )
    if not ok then
        return nil, error_message
    end
    return true
end

MpvAudio.resume = MpvAudio.play

function MpvAudio:pause()
    if self.closed then
        return nil, "mpv audio adapter is closed"
    end
    if not self.connected then
        self.queued_commands[#self.queued_commands + 1] = {
            command = { "set_property", "pause", true },
            kind = "pause",
            paused = true,
            generation = self.generation,
        }
        return true
    end
    local request_id, error_message
    request_id, error_message = self:_next_request(
        { "set_property", "pause", true },
        "pause",
        self.generation,
        { paused = true }
    )
    if not request_id then
        self:_fail(error_message)
        return nil, error_message
    end
    self.status.paused = true
    self:_set_state(MpvAudio.STATES.PAUSED)
    return true
end

function MpvAudio:seek(seconds)
    if self.closed then
        return nil, "mpv audio adapter is closed"
    end
    if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 then
        return nil, "seek position must be a non-negative number"
    end
    local ok, error_message = self:_queue_or_send(
        { "seek", seconds, "absolute+exact" },
        "seek"
    )
    if not ok then
        return nil, error_message
    end
    return true
end

function MpvAudio:stop()
    if self.closed then
        return nil, "mpv audio adapter is closed"
    end
    local ok, error_message = self:_queue_or_send({ "stop" }, "stop")
    if not ok then
        return nil, error_message
    end
    return true
end

function MpvAudio:getStatus()
    local status = {}
    for key, value in pairs(self.status) do
        status[key] = value
    end
    status.generation = self.generation
    status.connected = self.connected
    return status
end

function MpvAudio:_poll_teardown()
    local now = self.clock()
    invoke(self.transport, "poll", now)
    local process_events = invoke(self.process, "poll", now)
    local process_done = not self.process
    if self.process then
        local done = invoke(self.process, "is_done")
        process_done = done == true
        if type(process_events) == "table" then
            for _, event in ipairs(process_events) do
                if event.kind == "closed" then
                    process_done = true
                end
            end
        end
    end
    if process_done then
        invoke(self.transport, "close")
        invoke(self.process, "cleanup")
        return
    end
    self:_schedule_teardown()
end

function MpvAudio:close()
    if self.closed then
        return true
    end
    self.closed = true
    self:_set_state(MpvAudio.STATES.CLOSED)
    if self.poll_scheduled then
        self.timer:unschedule(self.poll_action)
        self.poll_scheduled = false
    end
    if self.connected and self.transport then
        self.transport:send({ command = { "quit" }, request_id = self.next_request_id + 1 })
    end
    self.connected = false
    if self.process then
        self.process:begin_close(self.clock())
    end
    if not self.process or self.process:is_done() then
        invoke(self.transport, "close")
        invoke(self.process, "cleanup")
    else
        self:_schedule_teardown()
    end
    return true
end

return MpvAudio
