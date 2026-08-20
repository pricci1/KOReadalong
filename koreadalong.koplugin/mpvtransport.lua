local ffi = require("ffi")

local json = require("json")
local posix = require("mpvposix")
local C = posix.C

local LineCodec = {}
LineCodec.__index = LineCodec

function LineCodec.new(options)
    options = options or {}
    return setmetatable({
        buffer = "",
        max_buffer = options.max_buffer or 1024 * 1024,
    }, LineCodec)
end

function LineCodec:feed(data)
    self.buffer = self.buffer .. data
    if #self.buffer > self.max_buffer then
        self.buffer = ""
        return nil, "mpv IPC input exceeded the line buffer limit"
    end

    local messages = {}
    while true do
        local newline = self.buffer:find("\n", 1, true)
        if not newline then
            break
        end
        local line = self.buffer:sub(1, newline - 1)
        self.buffer = self.buffer:sub(newline + 1)
        line = line:gsub("\r$", "")
        if line ~= "" then
            local ok, message = pcall(json.decode, line)
            if not ok or type(message) ~= "table" then
                messages[#messages + 1] = {
                    kind = "error",
                    error = "malformed mpv IPC JSON: " .. tostring(message),
                }
            else
                messages[#messages + 1] = {
                    kind = "message",
                    message = message,
                }
            end
        end
    end
    return messages
end

local MpvTransport = {}
MpvTransport.__index = MpvTransport

local DEFAULT_IO = {
    close = function(fd)
        return C.close(fd)
    end,
    recv = function(fd, buffer, length, flags)
        return C.recv(fd, buffer, length, flags)
    end,
    send = function(fd, data, length, flags)
        return C.send(fd, data, length, flags)
    end,
}

local RETRYABLE_CONNECT_ERRORS = {
    EAGAIN = true,
    EALREADY = true,
    ECONNREFUSED = true,
    ENOENT = true,
}

local posix_name

local function append_events(destination, source)
    for _, event in ipairs(source or {}) do
        destination[#destination + 1] = event
    end
end

local function close_fd(self)
    if self.fd then
        self.io.close(self.fd)
        self.fd = nil
    end
    self.connecting = false
    self.connected = false
end

function MpvTransport.new(options)
    options = options or {}
    return setmetatable({
        codec = options.codec or LineCodec.new(),
        read_buffer = ffi.new("char[8192]"),
        tx_queue = {},
        tx_offset = 1,
        closed = false,
        retry_interval = options.retry_interval or 0.02,
        io = options.io or DEFAULT_IO,
    }, MpvTransport)
end

function MpvTransport:_open_socket(now)
    local fd = C.socket(C.AF_UNIX, C.SOCK_STREAM, 0)
    if fd < 0 then
        return nil, "unable to create mpv IPC socket: " .. posix.strerror()
    end
    local nonblocking, nonblocking_error = posix.set_nonblocking(fd)
    if not nonblocking then
        C.close(fd)
        return nil, "unable to configure mpv IPC socket: " .. nonblocking_error
    end
    local address, address_length = posix.unix_address(self.path)
    if not address then
        C.close(fd)
        return nil, address_length
    end
    local result = C.connect(
        fd,
        ffi.cast("const struct sockaddr *", address),
        address_length
    )
    if result == 0 then
        self.fd = fd
        self.connected = true
        self.connecting = false
        return { kind = "connected" }
    end

    local error_number = ffi.errno()
    if posix.is_errno(error_number, "EINPROGRESS")
        or posix.is_errno(error_number, "EALREADY") then
        self.fd = fd
        self.connecting = true
        self.connected = false
        return nil
    end
    C.close(fd)
    if RETRYABLE_CONNECT_ERRORS[posix_name(error_number)] then
        self.next_attempt = now + self.retry_interval
        return nil
    end
    return nil, "mpv IPC connect failed: " .. posix.strerror(error_number)
end

-- Convert the small set of retryable errno values without depending on the
-- platform's numeric errno assignments.
posix_name = function(error_number)
    for name in pairs(RETRYABLE_CONNECT_ERRORS) do
        if posix.is_errno(error_number, name) then
            return name
        end
    end
    return ""
end

function MpvTransport:connect(path, now, timeout)
    if self.closed then
        return nil, "mpv IPC transport is closed"
    end
    if self.fd or self.path then
        return nil, "mpv IPC transport is already connected or connecting"
    end
    local address, path_error = posix.unix_address(path)
    if not address then
        return nil, path_error
    end
    now = now or 0
    self.path = path
    self.connect_deadline = now + (timeout or 2)
    self.next_attempt = now
    local event, connect_error = self:_open_socket(now)
    if connect_error then
        self.path = nil
        return nil, connect_error
    end
    return true, event
end

function MpvTransport:_poll_connect(now, events)
    if not self.fd then
        if now < self.next_attempt then
            return
        end
        if now >= self.connect_deadline then
            events[#events + 1] = {
                kind = "error",
                error = "timed out connecting to mpv IPC socket",
            }
            self.closed = true
            return
        end
        local event, connect_error = self:_open_socket(now)
        if connect_error then
            events[#events + 1] = { kind = "error", error = connect_error }
            self.closed = true
            return
        end
        if event then
            events[#events + 1] = event
        end
        return
    end

    if not self.connecting then
        return
    end
    local descriptor = ffi.new("struct pollfd[1]")
    descriptor[0].fd = self.fd
    descriptor[0].events = C.POLLOUT + C.POLLERR + C.POLLHUP + C.POLLNVAL
    local result = C.poll(descriptor, 1, 0)
    if result < 0 then
        if not posix.is_errno(ffi.errno(), "EINTR") then
            events[#events + 1] = {
                kind = "error",
                error = "mpv IPC connect poll failed: " .. posix.strerror(),
            }
            close_fd(self)
        end
        return
    end
    if result == 0 then
        return
    end

    local socket_error = ffi.new("int[1]")
    local socket_error_length = ffi.new("socklen_t[1]", ffi.sizeof(socket_error))
    if C.getsockopt(
        self.fd,
        C.SOL_SOCKET,
        C.SO_ERROR,
        socket_error,
        socket_error_length
    ) ~= 0 then
        events[#events + 1] = {
            kind = "error",
            error = "mpv IPC connect status failed: " .. posix.strerror(),
        }
        close_fd(self)
        return
    end
    if socket_error[0] ~= 0 then
        local error_number = socket_error[0]
        close_fd(self)
        if RETRYABLE_CONNECT_ERRORS[posix_name(error_number)] then
            self.next_attempt = now + self.retry_interval
        else
            events[#events + 1] = {
                kind = "error",
                error = "mpv IPC connect failed: " .. posix.strerror(error_number),
            }
            self.closed = true
        end
        return
    end
    self.connecting = false
    self.connected = true
    events[#events + 1] = { kind = "connected" }
end

function MpvTransport:_flush(events)
    if not self.connected then
        return
    end
    while self.tx_queue[1] do
        local data = self.tx_queue[1]
        local remaining = #data - self.tx_offset + 1
        local written, send_error = self.io.send(
            self.fd,
            data:sub(self.tx_offset),
            remaining,
            posix.MSG_NOSIGNAL
        )
        if written > 0 then
            self.tx_offset = self.tx_offset + written
            if self.tx_offset > #data then
                table.remove(self.tx_queue, 1)
                self.tx_offset = 1
            end
        elseif written < 0 then
            local error_number = send_error or ffi.errno()
            if posix.is_errno(error_number, "EINTR") then
                break
            elseif posix.is_errno(error_number, "EAGAIN") then
                return
            else
                events[#events + 1] = {
                    kind = "error",
                    error = "mpv IPC write failed: " .. posix.strerror(error_number),
                }
                close_fd(self)
                return
            end
        else
            return
        end
    end
end

function MpvTransport:_read(events)
    if not self.connected then
        return
    end
    for _ = 1, 32 do
        local bytes, recv_error = self.io.recv(
            self.fd,
            self.read_buffer,
            8192,
            0
        )
        if bytes > 0 then
            local decoded, decode_error = self.codec:feed(
                ffi.string(self.read_buffer, bytes)
            )
            if not decoded then
                events[#events + 1] = { kind = "error", error = decode_error }
            else
                append_events(events, decoded)
            end
        elseif bytes == 0 then
            events[#events + 1] = {
                kind = "closed",
                error = "mpv IPC socket reached EOF",
            }
            close_fd(self)
            return
        else
            local error_number = recv_error or ffi.errno()
            if posix.is_errno(error_number, "EINTR") then
                break
            elseif posix.is_errno(error_number, "EAGAIN") then
                return
            else
                events[#events + 1] = {
                    kind = "error",
                    error = "mpv IPC read failed: " .. posix.strerror(error_number),
                }
                close_fd(self)
                return
            end
        end
    end
end

function MpvTransport:poll(now)
    if self.closed then
        return {}
    end
    now = now or 0
    local events = {}
    self:_poll_connect(now, events)
    if self.connected then
        self:_flush(events)
        self:_read(events)
    end
    return events
end

function MpvTransport:send(message)
    if self.closed then
        return nil, "mpv IPC transport is closed"
    end
    local ok, encoded = pcall(json.encode, message)
    if not ok then
        return nil, "unable to encode mpv IPC command: " .. tostring(encoded)
    end
    self.tx_queue[#self.tx_queue + 1] = encoded .. "\n"
    return true
end

function MpvTransport:is_connected()
    return self.connected == true
end

function MpvTransport:close()
    if self.closed then
        return false
    end
    close_fd(self)
    self.closed = true
    self.path = nil
    self.tx_queue = {}
    self.tx_offset = 1
    return true
end

return {
    new = MpvTransport.new,
    LineCodec = LineCodec,
}
