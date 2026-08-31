local ffi = require("ffi")

require("ffi/posix_h")

local KinAMPPort = require("kinampport")
local C = ffi.C

local KindleAudio = {}
KindleAudio.__index = KindleAudio

local function load_logger()
    local ok, logger = pcall(require, "logger")
    return ok and logger or nil
end

local function redact_path(value)
    if type(value) ~= "string" then
        return tostring(value)
    end
    return (value:gsub("/[^%s,;:%)]*", "<path>"))
end

local function safe_command_argument(name, value)
    if name == "load" then
        return "<playlist>"
    end
    if type(value) == "number" then
        return value
    end
    return "<redacted>"
end

KindleAudio.STATES = {
    IDLE = "idle",
    LOADING = "loading",
    PLAYING = "playing",
    PAUSED = "paused",
    ENDED = "ended",
    ERROR = "error",
    CLOSED = "closed",
}

local POLL_INTERVAL = 0.18
local STARTUP_TIMEOUT = 3

local function finite_nonnegative(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
        and value >= 0
end

local function round_seconds(value)
    -- KinAMP accepts integer seconds.  Round the request once; report only
    -- whole seconds observed in a daemon publication.
    return math.floor(value + 0.5)
end

local function has_control_character(value)
    return type(value) == "string" and value:find("[%z\r\n]", 1) ~= nil
end

local function valid_path(path, name)
    if type(path) ~= "string" or path == "" then
        return nil, name .. " must be a non-empty local path"
    end
    if path:sub(1, 1) ~= "/" then
        return nil, name .. " must be an absolute local path"
    end
    if has_control_character(path) then
        return nil, name .. " contains a newline or control character"
    end
    return true
end

local function copy(source)
    local result = {}
    for key, value in pairs(source or {}) do
        result[key] = value
    end
    return result
end

local function invoke(object, method_name, ...)
    local method = object and object[method_name]
    if type(method) ~= "function" then
        return nil, "KinAMP dependency is missing " .. method_name
    end
    local ok, first, second, third = pcall(method, object, ...)
    if not ok then
        return nil, tostring(first)
    end
    return first, second, third
end

local function append_path(directory, basename)
    return directory:sub(-1) == "/"
        and directory .. basename
        or directory .. "/" .. basename
end

local function make_playlist_writer(root)
    local writer = {}

    function writer:create(content)
        if type(content) ~= "string" or content:sub(-1) ~= "\n" then
            return nil, "invalid KinAMP playlist content"
        end
        local entry = content:sub(1, -2)
        local valid, error_message = valid_path(entry, "KinAMP playlist entry")
        if not valid or root:sub(1, 1) ~= "/"
            or has_control_character(root) then
            return nil, error_message
                or "KinAMP playlist content or directory is invalid"
        end

        local template = append_path(root, "koreadalong-kinamp-XXXXXX.m3u")
        local buffer = ffi.new("char[?]", #template + 1, template)
        local fd = C.mkstemps(buffer, 4)
        if fd < 0 then
            return nil, "unable to create KinAMP playlist"
        end
        local path = ffi.string(buffer)
        local bytes = ffi.new("char[?]", #content, content)
        local offset = 0
        local write_error
        while offset < #content do
            local written = C.write(fd, bytes + offset, #content - offset)
            if written < 0 then
                if ffi.errno() ~= C.EINTR then
                    write_error = "unable to write KinAMP playlist"
                    break
                end
            elseif written == 0 then
                write_error = "unable to write KinAMP playlist: short write"
                break
            else
                offset = offset + tonumber(written)
            end
        end
        local closed = C.close(fd) == 0
        if write_error or not closed then
            os.remove(path)
            return nil, write_error or "unable to close KinAMP playlist"
        end
        return path
    end

    function writer:remove(path)
        local removed, remove_error = os.remove(path)
        if not removed then
            return nil, remove_error or "unable to remove KinAMP playlist"
        end
        return true
    end

    return writer
end

local function status_missing(error_message)
    if type(error_message) ~= "string" then
        return false
    end
    local lower = error_message:lower()
    return lower:find("no such file", 1, true) ~= nil
        or lower:find("not found", 1, true) ~= nil
        or lower:find("status file is not available", 1, true) ~= nil
        or lower:match("^enoent[%s:]?") ~= nil
end

local function same_token(left, right)
    return left ~= nil and right ~= nil and left == right
end

local function snapshot_token(result)
    local status = result.status
    local token = result.token or result.publication_token
    if not token and status then
        token = status.token or status.publication_token
    end
    if token == nil then
        return nil
    end
    return tostring(token)
end

local function normalize_status(status)
    if type(status) ~= "table" then
        return nil, "KinAMP status is not a table"
    end
    if status.state ~= "playing" and status.state ~= "paused"
        and status.state ~= "stopped" then
        return nil, "KinAMP status has an invalid state"
    end
    local position = status.position or status.pos
    local duration = status.duration or status.dur
    if position ~= nil and (not finite_nonnegative(position)
        or position ~= math.floor(position)) then
        return nil, "KinAMP status has an invalid position"
    end
    if duration ~= nil and (not finite_nonnegative(duration)
        or duration ~= math.floor(duration)) then
        return nil, "KinAMP status has an invalid duration"
    end
    if status.path ~= nil and type(status.path) ~= "string" then
        return nil, "KinAMP status has an invalid path"
    end
    return {
        state = status.state,
        position = position,
        duration = duration,
        path = status.path,
    }
end

local function normalize_result(result, error_message)
    if type(result) ~= "table" or result.live == nil then
        return nil, error_message or "invalid KinAMP liveness result"
    end
    result = copy(result)
    result.token = snapshot_token(result)
    if result.status then
        local status, status_error = normalize_status(result.status)
        if not status then
            return nil, status_error
        end
        result.status = status
        if not result.token then
            return nil, "KinAMP status publication token unavailable"
        end
    end
    return result
end

function KindleAudio.new(options)
    options = options or {}
    local port = options.port or KinAMPPort.new(options.port_options)
    local root = options.playlist_root
    if not root and type(port.getRuntimeDir) == "function" then
        root = select(1, invoke(port, "getRuntimeDir"))
    end
    root = root or "/tmp"

    local self = setmetatable({
        port = port,
        logger = options.logger or load_logger(),
        timer = options.timer or require("ui/uimanager"),
        clock = options.clock or function()
            local time = require("ui/time")
            return time.to_s(time.now())
        end,
        playlist_writer = options.playlist_writer
            or make_playlist_writer(root),
        poll_interval = options.poll_interval or POLL_INTERVAL,
        startup_timeout = options.startup_timeout or STARTUP_TIMEOUT,
        state = KindleAudio.STATES.IDLE,
        status = {
            state = KindleAudio.STATES.IDLE,
            position = 0,
            duration = nil,
            paused = nil,
            error = nil,
        },
        closed = false,
        close_requested = false,
        close_finished = false,
        poll_scheduled = false,
        deadline = nil,
        terminal_error = nil,
        audio_path = nil,
        playlist_path = nil,
        playlist_owned = false,
        command_attempted = false,
        open_sent = false,
        desired_paused = false,
        pause_pending = nil,
        seek_intent = nil,
        baseline_token = nil,
        last_token = nil,
        resource_seen = false,
        last_snapshot = nil,
        last_daemon_state = nil,
        last_logged_token = nil,
        last_logged_error = nil,
        last_logged_error_terminal = nil,
        last_logged_cleanup_error = nil,
        stop_requested = false,
        stop_sent = false,
        stop_baseline = nil,
        release_confirmed = false,
        close_release_confirmed = false,
    }, KindleAudio)

    self.poll_action = function()
        self.poll_scheduled = false
        if self.closed then
            self:_poll_close()
        else
            self:_poll()
        end
    end
    return self
end

function KindleAudio:_log(level, ...)
    local method = self.logger and self.logger[level]
    if type(method) == "function" then
        pcall(method, ...)
    end
end

function KindleAudio:_log_commands(commands)
    local list = type(commands[1]) == "table" and commands or { commands }
    for _, command in ipairs(list) do
        local name = command[1]
        local arguments = {}
        for index = 2, #command do
            arguments[#arguments + 1] = tostring(
                safe_command_argument(name, command[index])
            )
        end
        if #arguments == 0 then
            self:_log("info", "KoReadalong KindleAudio command", name)
        else
            self:_log(
                "info",
                "KoReadalong KindleAudio command",
                name,
                table.concat(arguments, " ")
            )
        end
    end
end

function KindleAudio:_log_publication(token)
    if token == nil or same_token(self.last_logged_token, token) then
        return
    end
    self:_log(
        "info",
        "KoReadalong KindleAudio publication",
        self.last_logged_token and "changed" or "initial",
        tostring(token)
    )
    self.last_logged_token = token
end

function KindleAudio:_log_failure(message, terminal)
    message = tostring(message or "unknown KinAMP error")
    terminal = terminal == true
    if self.last_logged_error == message
        and self.last_logged_error_terminal == terminal then
        return
    end
    self.last_logged_error = message
    self.last_logged_error_terminal = terminal
    self:_log(
        terminal and "err" or "warn",
        "KoReadalong KindleAudio failure",
        terminal and "terminal" or "recoverable",
        redact_path(message)
    )
end

function KindleAudio:_log_cleanup_failure(message)
    message = tostring(message or "unknown cleanup error")
    if self.last_logged_cleanup_error == message then
        return
    end
    self.last_logged_cleanup_error = message
    self:_log(
        "warn",
        "KoReadalong KindleAudio cleanup failure",
        redact_path(message)
    )
end

function KindleAudio:_set_state(state)
    local previous = self.state
    self.state = state
    self.status.state = state
    if state == KindleAudio.STATES.PLAYING then
        self.status.paused = false
    elseif state == KindleAudio.STATES.PAUSED then
        self.status.paused = true
    else
        self.status.paused = nil
    end
    if previous ~= state then
        self:_log(
            "info",
            "KoReadalong KindleAudio state",
            previous,
            "->",
            state
        )
    end
end

function KindleAudio:_schedule()
    if self.poll_scheduled or self.close_finished then
        return
    end
    self.poll_scheduled = true
    self.timer:scheduleIn(self.poll_interval, self.poll_action)
end

function KindleAudio:_unschedule()
    if self.poll_scheduled then
        self.timer:unschedule(self.poll_action)
    end
    self.poll_scheduled = false
end

function KindleAudio:_error(error_message)
    local message = tostring(error_message or "unknown KinAMP error")
    local resource_uncertain = self.playlist_owned or self.command_attempted
    local terminal = self.terminal_error ~= nil or resource_uncertain
    if resource_uncertain then
        if not self.terminal_error then
            self.terminal_error = message
            self.status.error = self.terminal_error
        end
    else
        self.status.error = message
    end
    self:_log_failure(message, terminal)
    if not self.closed then
        self:_set_state(KindleAudio.STATES.ERROR)
        if not self.stop_requested and not self.stop_sent
            and not self.close_requested then
            self:_unschedule()
        end
    end
    return nil, self.status.error
end

function KindleAudio:_probe()
    local result, error_message = invoke(self.port, "probe")
    result, error_message = normalize_result(result, error_message)
    if not result then
        return nil, error_message
    end
    if result.status_error_kind == "compatibility" then
        return nil, result.status_error
            or "KinAMP status publication metadata unavailable"
    end
    if result.status_error and not status_missing(result.status_error) then
        return nil, result.status_error
    end
    if result.status and not result.token then
        return nil, "KinAMP status publication token unavailable"
    end
    self:_log_publication(result.token)
    return result
end

function KindleAudio:_request_status()
    local result, error_message = invoke(self.port, "requestStatus")
    result, error_message = normalize_result(result, error_message)
    if not result then
        return nil, error_message
    end
    self:_log_publication(result.token)
    if not result.live then
        return result
    end
    if not result.status then
        if result.status_error_kind == "compatibility" then
            return nil, result.status_error
                or "KinAMP status publication metadata unavailable"
        end
        if result.status_error and not status_missing(result.status_error) then
            return nil, result.status_error
        end
        return result
    end
    if not result.token then
        return nil, "KinAMP status publication token unavailable"
    end
    return result
end

function KindleAudio:_send(commands)
    -- Once a playback command reaches the FIFO, a failed write cannot prove
    -- that the daemon consumed none of it.  Keep cleanup terminal from this
    -- point, even when the write reports an error.
    self.command_attempted = true
    self:_log_commands(commands)
    local sent, error_message = invoke(self.port, "send", commands)
    if not sent then
        return nil, error_message or "KinAMP command was not accepted"
    end
    return true
end

function KindleAudio:_create_playlist()
    local writer = self.playlist_writer
    if type(writer) ~= "table" or type(writer.create) ~= "function" then
        return nil, "KinAMP playlist writer is missing create"
    end
    local path, error_message = invoke(writer, "create", self.audio_path .. "\n")
    if not path then
        return nil, error_message or "unable to create KinAMP playlist"
    end
    local valid, path_error = valid_path(path, "KinAMP playlist path")
    if not valid then
        return nil, path_error
    end
    self.playlist_path = path
    self.playlist_owned = true
    self:_log("info", "KoReadalong KindleAudio playlist", "created")
    return true
end

function KindleAudio:_remove_playlist()
    if not self.playlist_owned then
        return true
    end
    local removed, error_message = invoke(
        self.playlist_writer,
        "remove",
        self.playlist_path
    )
    if not removed then
        self:_log_cleanup_failure(error_message)
        return nil, error_message or "unable to remove KinAMP playlist"
    end
    self.playlist_path = nil
    self.playlist_owned = false
    self:_log("info", "KoReadalong KindleAudio playlist", "removed")
    return true
end

function KindleAudio:_clear_resource()
    self.audio_path = nil
    self.playlist_path = nil
    self.playlist_owned = false
    self.command_attempted = false
    self.open_sent = false
    self.desired_paused = false
    self.pause_pending = nil
    self.seek_intent = nil
    self.baseline_token = nil
    self.last_token = nil
    self.resource_seen = false
    self.last_snapshot = nil
    self.last_daemon_state = nil
    self.last_logged_token = nil
    self.last_logged_error = nil
    self.last_logged_error_terminal = nil
    self.last_logged_cleanup_error = nil
    self.stop_requested = false
    self.stop_sent = false
    self.stop_baseline = nil
    self.release_confirmed = false
    self.close_release_confirmed = false
end

function KindleAudio:_finish_resource()
    self:_unschedule()
    local removed, error_message = self:_remove_playlist()
    if not removed then
        return self:_error(error_message)
    end
    self:_clear_resource()
    self.status.position = 0
    self.status.duration = nil
    if not self.closed then
        self:_set_state(KindleAudio.STATES.IDLE)
    end
    return true
end

function KindleAudio:_matches(status)
    return self.audio_path ~= nil and status.path == self.audio_path
end

function KindleAudio:_record(status)
    self.last_snapshot = copy(status)
    if status.duration ~= nil
        and (self.status.duration == nil or status.duration > 0) then
        self.status.duration = status.duration
    end
    if status.state == "playing" or status.state == "paused" then
        if status.position ~= nil then
            self.status.position = status.position
        end
        self.last_daemon_state = status.state
    end
end

function KindleAudio:_seek_reconcile(status, fresh)
    local intent = self.seek_intent
    if not intent then
        return true
    end
    if intent.sent then
        if fresh then
            self.seek_intent = nil
        end
        return true
    end
    if status.position == nil then
        return true
    end
    if status.position == intent.target then
        self.seek_intent = nil
    elseif not intent.sent then
        local sent, error_message = self:_send{{ "seek", intent.target }}
        if not sent then
            return self:_error(error_message)
        end
        intent.sent = true
    end
    return true
end

function KindleAudio:_pause_reconcile(status)
    local paused = status.state == "paused"
    if paused == self.desired_paused then
        self.pause_pending = nil
        return true
    end
    if self.pause_pending ~= nil then
        if paused == self.pause_pending then
            self.pause_pending = nil
        end
        return true
    end
    local command
    if self.desired_paused then
        command = { "pause" }
    elseif status.position ~= nil then
        -- KinAMP 3.0 can move its synthetic clock backwards when its `play`
        -- command resumes a paused pipeline. Seeking to the published paused
        -- second creates a playing pipeline without that clock adjustment.
        command = { "seek", status.position }
    else
        command = { "play" }
    end
    local sent, error_message = self:_send{ command }
    if not sent then
        return self:_error(error_message)
    end
    self.pause_pending = self.desired_paused
    return true
end

function KindleAudio:_reconcile_active(status, fresh)
    if not self:_seek_reconcile(status, fresh) then
        return nil
    end
    if not self:_pause_reconcile(status) then
        return nil
    end
    if self.pause_pending == nil then
        self:_set_state(
            status.state == "paused"
                and KindleAudio.STATES.PAUSED
                or KindleAudio.STATES.PLAYING
        )
    end
    return true
end

function KindleAudio:_handle_stopped(status)
    if self.last_daemon_state == "playing" then
        local duration = self.status.duration
        if status.duration and status.duration > 0 then
            duration = status.duration
        end
        if finite_nonnegative(duration) and duration > 0 then
            -- KinAMP can publish a stale final position (including zero).
            -- External stop and EOF are indistinguishable in this protocol.
            self:_set_state(KindleAudio.STATES.ENDED)
            self:_unschedule()
            return true
        end
        return self:_error("KinAMP stopped without a positive duration")
    end
    if self.last_daemon_state == "paused" then
        return self:_error("KinAMP stopped before the audio ended")
    end
    return true
end

function KindleAudio:_process_stop(status, token, fresh)
    if self.release_confirmed then
        return self:_finish_resource()
    end
    if not self:_matches(status) then
        if status.path and status.path ~= "" and fresh then
            self.release_confirmed = true
            return self:_finish_resource()
        end
        return true
    end
    if self.stop_sent then
        if fresh and token ~= self.stop_baseline and status.state == "stopped" then
            self.release_confirmed = true
            return self:_finish_resource()
        end
        return true
    end
    local sent, error_message = self:_send_stop()
    if not sent then
        return self:_error(error_message)
    end
    self.stop_requested = false
    self.stop_sent = true
    self.stop_baseline = token
    return true
end

function KindleAudio:_send_stop()
    return self:_send{
        { "stop" },
        { "status" },
    }
end

function KindleAudio:_process_preload(snapshot)
    if not snapshot.live then
        return self:_error("KinAMP daemon is not running; start KinAMP first")
    end
    if not snapshot.status then
        return true
    end
    local status = snapshot.status
    if status.state == "playing" or status.state == "paused" then
        return self:_error("KinAMP is busy")
    end
    if same_token(snapshot.token, self.baseline_token) then
        return true
    end
    if status.state ~= "stopped" then
        return self:_error("KinAMP status is not idle")
    end

    local created, error_message = self:_create_playlist()
    if not created then
        return self:_error(error_message)
    end
    local commands = {
        { "load", self.playlist_path },
        { "index", 0 },
    }
    if self.seek_intent and self.seek_intent.target > 0 then
        commands[#commands + 1] = { "seek", self.seek_intent.target }
    end
    if self.desired_paused then
        commands[#commands + 1] = { "pause" }
        self.pause_pending = true
    end
    -- A failed FIFO call does not prove that no part of the command was
    -- consumed; retain the playlist for the close/release handshake.
    self.command_attempted = true
    local sent, send_error = self:_send(commands)
    if not sent then
        return self:_error(send_error)
    end
    if self.seek_intent then
        if self.seek_intent.target > 0 then
            self.seek_intent.sent = true
        else
            self.seek_intent = nil
        end
    end
    self.open_sent = true
    self.baseline_token = snapshot.token
    self.last_token = snapshot.token
    self.resource_seen = false
    self.last_snapshot = nil
    self.last_daemon_state = nil
    self:_schedule()
    return true
end

function KindleAudio:_process_snapshot(snapshot)
    if not snapshot.status then
        return true
    end
    local status = snapshot.status
    local fresh = not same_token(self.last_token, snapshot.token)
    self.last_token = snapshot.token

    if self.stop_requested or self.stop_sent then
        return self:_process_stop(status, snapshot.token, fresh)
    end
    if not self.resource_seen then
        if same_token(snapshot.token, self.baseline_token) then
            return true
        end
        self.resource_seen = true
    end
    if self.terminal_error or self.state == KindleAudio.STATES.ENDED
        or not fresh or not self:_matches(status) then
        return true
    end
    self:_record(status)
    if status.state == "playing" or status.state == "paused" then
        return self:_reconcile_active(status, fresh)
    end
    return self:_handle_stopped(status)
end

function KindleAudio:_check_deadline(message)
    if self.deadline and self.clock() >= self.deadline then
        return self:_error(message)
    end
    return true
end

function KindleAudio:_poll()
    if (self.terminal_error or self.state == KindleAudio.STATES.ENDED)
        and not self.stop_requested and not self.stop_sent then
        return
    end
    local snapshot, error_message = self:_request_status()
    if not snapshot then
        self:_error(error_message)
        if self.stop_requested or self.stop_sent then
            self:_schedule()
        end
        return
    end
    if not snapshot.live then
        self:_error("KinAMP daemon disappeared")
        if self.stop_requested or self.stop_sent then
            self:_schedule()
        end
        return
    end
    if self.open_sent or self.command_attempted
        and (self.stop_requested or self.stop_sent) then
        self:_process_snapshot(snapshot)
    else
        self:_process_preload(snapshot)
    end
    if self.state == KindleAudio.STATES.LOADING then
        self:_check_deadline(
            self.open_sent
                and "timed out waiting for KinAMP audio"
                or "timed out waiting for fresh idle KinAMP status"
        )
    end
    if self.state == KindleAudio.STATES.LOADING
        or self.state == KindleAudio.STATES.PLAYING
        or self.state == KindleAudio.STATES.PAUSED
        or self.stop_requested or self.stop_sent then
        self:_schedule()
    end
end

function KindleAudio:open(path, options)
    if self.closed then
        return nil, "Kindle audio adapter is closed"
    end
    if self.terminal_error then
        return nil, "Kindle audio adapter is in a terminal error state"
    end
    if self.state ~= KindleAudio.STATES.IDLE then
        return nil, "audio resource is still active"
    end
    local valid, error_message = valid_path(path, "audio path")
    if not valid then
        return nil, error_message
    end
    if options ~= nil and type(options) ~= "table" then
        return nil, "audio open options must be a table"
    end
    options = options or {}
    local position = options.position
    if position == nil then
        position = 0
    end
    if not finite_nonnegative(position) then
        return nil, "open position must be a finite non-negative number"
    end
    local paused = options.paused
    if paused == nil then
        paused = false
    end
    if type(paused) ~= "boolean" then
        return nil, "open paused option must be boolean"
    end

    self.audio_path = path
    self.desired_paused = paused
    local rounded = round_seconds(position)
    self.seek_intent = rounded > 0 and { target = rounded } or nil
    self.status.position = 0
    self.status.duration = nil
    self.status.error = nil
    self.open_sent = false
    self.command_attempted = false
    self.pause_pending = nil
    self.baseline_token = nil
    self.last_token = nil
    self.resource_seen = false
    self.last_snapshot = nil
    self.last_daemon_state = nil
    self.stop_requested = false
    self.stop_sent = false
    self.stop_baseline = nil
    self.deadline = self.clock() + self.startup_timeout
    self:_set_state(KindleAudio.STATES.LOADING)

    local probe, probe_error = self:_probe()
    if not probe then
        return self:_error(probe_error)
    end
    if not probe.live then
        return self:_error(
            "KinAMP daemon is not running; start KinAMP first"
        )
    end
    if probe.status
        and (probe.status.state == "playing"
            or probe.status.state == "paused") then
        return self:_error("KinAMP is busy")
    end
    self.baseline_token = probe.token

    local snapshot, request_error = self:_request_status()
    if not snapshot then
        return self:_error(request_error)
    end
    if not snapshot.live then
        return self:_error(
            "KinAMP daemon is not running; start KinAMP first"
        )
    end
    self:_process_preload(snapshot)
    if self.state == KindleAudio.STATES.ERROR then
        return nil, self.status.error
    end
    self:_schedule()
    return true
end

function KindleAudio:setPaused(paused)
    if self.closed then
        return nil, "Kindle audio adapter is closed"
    end
    if self.terminal_error then
        return nil, "Kindle audio adapter is in a terminal error state"
    end
    if type(paused) ~= "boolean" then
        return nil, "paused state must be boolean"
    end
    if self.state == KindleAudio.STATES.IDLE
        or self.state == KindleAudio.STATES.ENDED then
        return nil, "audio resource is not open"
    end
    if self.stop_requested or self.stop_sent then
        return nil, "audio is stopping"
    end
    self.desired_paused = paused
    if self.open_sent and self.last_snapshot and self:_matches(self.last_snapshot)
        and (self.last_snapshot.state == "playing"
            or self.last_snapshot.state == "paused") then
        local reconciled, reconcile_error = self:_pause_reconcile(
            self.last_snapshot
        )
        if not reconciled then
            return nil, reconcile_error
        end
    end
    self:_schedule()
    return true
end

function KindleAudio:seek(position)
    if self.closed then
        return nil, "Kindle audio adapter is closed"
    end
    if self.terminal_error then
        return nil, "Kindle audio adapter is in a terminal error state"
    end
    if not finite_nonnegative(position) then
        return nil, "seek position must be a finite non-negative number"
    end
    if self.state == KindleAudio.STATES.IDLE
        or self.state == KindleAudio.STATES.ENDED then
        return nil, "audio resource is not open"
    end
    if self.stop_requested or self.stop_sent then
        return nil, "audio is stopping"
    end
    local rounded = round_seconds(position)
    if not self.seek_intent or self.seek_intent.target ~= rounded then
        self.seek_intent = { target = rounded }
    end
    if self.open_sent and self.last_snapshot and self:_matches(self.last_snapshot)
        and (self.last_snapshot.state == "playing"
            or self.last_snapshot.state == "paused") then
        local reconciled, reconcile_error = self:_seek_reconcile(
            self.last_snapshot
        )
        if not reconciled then
            return nil, reconcile_error
        end
    end
    self:_schedule()
    return true, rounded
end

function KindleAudio:stop()
    if self.closed then
        return nil, "Kindle audio adapter is closed"
    end
    if self.state == KindleAudio.STATES.IDLE then
        return true
    end
    if self.stop_requested or self.stop_sent then
        return true
    end
    if not self.command_attempted then
        self.stop_requested = true
        return self:_finish_resource()
    end
    self.stop_requested = true
    self:_schedule()
    return true
end

function KindleAudio:_close_port()
    if self.close_finished then
        return true
    end
    local closed, error_message = invoke(self.port, "close")
    if not closed then
        self:_log_cleanup_failure(error_message)
        self.status.cleanup_error = error_message
        return nil, error_message
    end
    self.close_finished = true
    self.poll_scheduled = false
    self:_log("info", "KoReadalong KindleAudio port", "closed")
    return true
end

function KindleAudio:_close_cleanup()
    local removed, error_message = self:_remove_playlist()
    if not removed then
        self.status.cleanup_error = error_message
        if not self.terminal_error then
            self:_error(error_message)
        end
        return nil
    end
    self.status.cleanup_error = nil
    return true
end

function KindleAudio:_keep_closing(message)
    self.status.cleanup_error = self.status.cleanup_error or message
    self:_schedule()
end

function KindleAudio:_complete_close()
    local cleaned, cleanup_error = self:_close_cleanup()
    if not cleaned then
        self:_keep_closing(cleanup_error)
        return nil
    end
    local closed, close_error = self:_close_port()
    if not closed then
        self:_keep_closing(close_error)
        return nil
    end
    return true
end

function KindleAudio:_poll_close()
    if self.close_finished then
        return
    end
    if self.close_release_confirmed then
        self:_complete_close()
        return
    end
    if not self.command_attempted then
        self:_complete_close()
        return
    end

    local snapshot, error_message = self:_request_status()
    if not snapshot then
        self:_error(error_message)
        self:_keep_closing(error_message)
        return
    end
    if not snapshot.live or not snapshot.status then
        if not snapshot.live then
            self.close_release_confirmed = true
            self:_complete_close()
            return
        end
        self:_keep_closing(
            "waiting for KinAMP status publication during close"
        )
        return
    end
    local status = snapshot.status
    local fresh = not same_token(self.last_token, snapshot.token)
    self.last_token = snapshot.token
    if not self:_matches(status) then
        if status.path and status.path ~= "" and fresh then
            self.close_release_confirmed = true
            self:_complete_close()
        else
            self:_keep_closing(
                "could not confirm owned KinAMP audio release"
            )
        end
        return
    end
    if self.stop_sent then
        if fresh and snapshot.token ~= self.stop_baseline
            and status.state == "stopped" then
            self.close_release_confirmed = true
            self:_complete_close()
        else
            self:_keep_closing(
                "waiting for fresh stopped KinAMP publication during close"
            )
        end
        return
    end

    local sent, send_error = self:_send_stop()
    if sent then
        self.stop_sent = true
        self.stop_baseline = snapshot.token
    else
        self:_error(send_error)
    end
    self:_schedule()
end

function KindleAudio:close()
    if self.close_requested then
        if not self.close_finished then
            self:_schedule()
        end
        return true
    end
    self.close_requested = true
    self.closed = true
    self.close_release_confirmed = self.release_confirmed
    self:_set_state(KindleAudio.STATES.CLOSED)
    self:_unschedule()
    self:_poll_close()
    return true
end

function KindleAudio:getStatus()
    local status = copy(self.status)
    status.recoverable = self.state == KindleAudio.STATES.ERROR
        and not self.terminal_error
    return status
end

return KindleAudio
