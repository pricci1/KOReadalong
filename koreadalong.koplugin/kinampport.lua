local bit = require("bit")
local ffi = require("ffi")

require("ffi/posix_h")

local C = ffi.C

-- Clean-room interoperability with the text protocol of the separately
-- installed GPLv3+ KinAMP daemon: https://github.com/kbarni/KinAMP.
-- KOReadalong does not bundle or derive code from KinAMP.  Kindle/Linux is
-- assumed here so one <= PIPE_BUF (4096-byte) FIFO write is atomic.
pcall(ffi.cdef, [[
typedef void (*koreadalong_sighandler_t)(int);
koreadalong_sighandler_t signal(int, koreadalong_sighandler_t);
]])

local KinAMPPort = {}
KinAMPPort.__index = KinAMPPort

KinAMPPort.MAX_FIFO_PAYLOAD = 4096
KinAMPPort.MAX_STATUS_BYTES = 16 * 1024
KinAMPPort.MAX_WRITE_RETRIES = 3
KinAMPPort.MAX_STATUS_READ_RETRIES = 3

local DEFAULT_RUNTIME_DIR = "/tmp"
local SIGPIPE = 13
local SIGPIPE_IGNORED = false

local ERRNO = {
    EAGAIN = 11,
    EINTR = 4,
    ENOENT = 2,
    ENXIO = 6,
    EPIPE = 32,
}

local COMMAND_ARITY = {
    load = 1,
    index = 1,
    play = 0,
    pause = 0,
    stop = 0,
    seek = 1,
    status = 0,
    speed = 1,
}

local function has_control_character(value)
    return type(value) == "string" and value:find("[%z\r\n]", 1) ~= nil
end

local function errno_is(value, name)
    if type(value) == "string" then
        local lower = value:lower()
        return lower == name:lower()
            or lower:find(name:lower(), 1, true) ~= nil
            or (name == "ENXIO" and lower:find("no listener", 1, true) ~= nil)
            or (name == "EPIPE" and lower:find("broken pipe", 1, true) ~= nil)
    end
    return tonumber(value) == ERRNO[name]
end

local function error_text(value)
    if type(value) == "string" then
        return value
    end
    if value == nil then
        return "unknown error"
    end
    local ok, text = pcall(function()
        return ffi.string(C.strerror(value))
    end)
    return ok and text or tostring(value)
end

local function missing_file(error_message)
    if tonumber(error_message) == ERRNO.ENOENT then
        return true
    end
    if type(error_message) ~= "string" then
        return false
    end
    local lower = error_message:lower()
    return lower:find("no such file", 1, true) ~= nil
        or lower:find("not found", 1, true) ~= nil
        or lower:match("^enoent[%s:]?") ~= nil
end

local function load_lfs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok then
        return lfs
    end
    ok, lfs = pcall(require, "lfs")
    return ok and lfs or nil
end

local function stat_file(path)
    local lfs = load_lfs()
    if not lfs then
        return nil, "KinAMP status publication metadata unavailable"
    end
    local ok, attributes, error_message = pcall(lfs.attributes, path)
    if not ok then
        return nil, tostring(attributes)
    end
    if not attributes then
        return nil, error_message or "No such file or directory"
    end
    return attributes
end

local function is_fifo(path)
    local attributes, error_message = stat_file(path)
    if not attributes then
        if error_message == "KinAMP status publication metadata unavailable" then
            return nil, "KinAMP FIFO type metadata unavailable"
        end
        return nil, error_message
    end
    return attributes.mode == "fifo" or attributes.mode == "named pipe"
end

local function verify_open_fifo(fd)
    -- Checking /proc/self/fd keeps the check tied to the opened descriptor,
    -- rather than trusting a path that may have been replaced after open().
    local attributes, error_message = stat_file("/proc/self/fd/" .. tostring(fd))
    if not attributes then
        return nil, "KinAMP opened-target FIFO metadata unavailable: "
            .. tostring(error_message)
    end
    if attributes.mode ~= "fifo" and attributes.mode ~= "named pipe" then
        return nil, "KinAMP opened target is not a FIFO"
    end
    return true
end

local function verify_status_file(attributes)
    if type(attributes) ~= "table" or attributes.mode == nil then
        return nil, "KinAMP status file type metadata unavailable"
    end
    if attributes.mode ~= "file" then
        return nil, "KinAMP status path is not a regular file"
    end
    return true
end

local function open_fifo(path, flags)
    local fd = C.open(path, flags)
    if fd < 0 then
        return nil, ffi.errno()
    end
    return tonumber(fd)
end

local function write_fd(fd, payload)
    -- A string initializer also copies its NUL, even for a variable-size array.
    local buffer = ffi.new("char[?]", #payload + 1, payload)
    local written = C.write(fd, buffer, #payload)
    if written < 0 then
        return nil, ffi.errno()
    end
    return tonumber(written)
end

local function close_fd(fd)
    if C.close(fd) == 0 then
        return true
    end
    return nil, ffi.errno()
end

local function read_file(path, maximum)
    local flags = bit.bor(C.O_RDONLY, C.O_NONBLOCK, C.O_CLOEXEC)
    local fd = C.open(path, flags)
    if fd < 0 then
        return nil, ffi.errno()
    end

    local buffer = ffi.new("char[?]", maximum + 1)
    local offset = 0
    local interrupted = 0
    local read_error
    while offset <= maximum do
        local count = C.read(fd, buffer + offset, maximum + 1 - offset)
        if count < 0 then
            local errno = ffi.errno()
            if errno == C.EINTR and interrupted < KinAMPPort.MAX_STATUS_READ_RETRIES then
                interrupted = interrupted + 1
            else
                read_error = errno
                break
            end
        elseif count == 0 then
            break
        else
            offset = offset + tonumber(count)
        end
    end

    local closed = C.close(fd) == 0
    if read_error then
        return nil, read_error
    end
    if not closed then
        return nil, ffi.errno()
    end
    if offset > maximum then
        return nil, "KinAMP status file exceeds the size limit"
    end
    return ffi.string(buffer, offset)
end

local function ignore_sigpipe(signal_function)
    local ignored = ffi.cast("koreadalong_sighandler_t", 1)
    local sigerr = ffi.cast("koreadalong_sighandler_t", -1)
    local ok, previous = pcall(signal_function, SIGPIPE, ignored)
    if not ok then
        return nil, "unable to ignore SIGPIPE: " .. tostring(previous)
    end
    if previous == sigerr then
        return nil, "unable to ignore SIGPIPE: signal() returned SIG_ERR"
    end
    return true
end

local function default_fs(options)
    options = options or {}
    local flags = bit.bor(C.O_WRONLY, C.O_NONBLOCK, C.O_CLOEXEC)
    local signal_function = options.signal or C.signal
    return {
        open_fifo = function(path)
            return open_fifo(path, flags)
        end,
        write_fd = write_fd,
        close_fd = close_fd,
        read_file = read_file,
        stat_file = stat_file,
        is_fifo = is_fifo,
        verify_open_fifo = verify_open_fifo,
        ignore_sigpipe = function()
            return ignore_sigpipe(signal_function)
        end,
    }
end

local function make_fs(options)
    local fs = default_fs(options)
    local supplied = options.fs or options.syscalls or {}
    local names = {
        "open_fifo",
        "write_fd",
        "close_fd",
        "read_file",
        "stat_file",
        "is_fifo",
        "verify_open_fifo",
        "ignore_sigpipe",
    }
    for _, name in ipairs(names) do
        if supplied[name] ~= nil then
            fs[name] = supplied[name]
        elseif options[name] ~= nil then
            fs[name] = options[name]
        end
    end
    return fs
end

local function join_path(directory, basename)
    if directory:sub(-1) == "/" then
        return directory .. basename
    end
    return directory .. "/" .. basename
end

local function parse_integer(value, name)
    if name == "index" and value == "-1" then
        return -1
    end
    if not value:match("^%d+$") then
        return nil, "KinAMP status field " .. name
            .. " is not a non-negative integer"
    end
    local number = tonumber(value)
    if not number or number ~= math.floor(number)
        or number > 9007199254740991 then
        return nil, "KinAMP status field " .. name .. " is out of range"
    end
    return number
end

local function parse_status(content, maximum)
    if type(content) ~= "string" then
        return nil, "KinAMP status is not text"
    end
    if #content > (maximum or KinAMPPort.MAX_STATUS_BYTES) then
        return nil, "KinAMP status file exceeds the size limit"
    end

    local status = {}
    local seen = {}
    local start = 1
    while start <= #content do
        local newline = content:find("\n", start, true)
        local line
        if newline then
            line = content:sub(start, newline - 1)
            start = newline + 1
        else
            line = content:sub(start)
            start = #content + 1
        end
        line = line:gsub("\r$", "")
        if line ~= "" then
            local key, value = line:match("^([A-Za-z_][A-Za-z0-9_-]*)=(.*)$")
            if not key then
                return nil, "malformed KinAMP status line"
            end
            if seen[key] then
                return nil, "duplicate KinAMP status field: " .. key
            end
            if has_control_character(value) then
                return nil, "KinAMP status field contains a control character: "
                    .. key
            end
            seen[key] = true
            if key == "state" then
                if value ~= "playing" and value ~= "paused"
                    and value ~= "stopped" then
                    return nil, "invalid KinAMP state: " .. value
                end
                status.state = value
            elseif key == "pid" or key == "index" or key == "count"
                or key == "pos" or key == "dur" or key == "pos_ms" then
                local number, integer_error = parse_integer(value, key)
                if not number and integer_error then
                    return nil, integer_error
                end
                status[key] = number
                if key == "pos" then
                    status.position = number
                elseif key == "dur" then
                    status.duration = number
                end
            elseif key == "speed" or key == "speed_min" or key == "speed_max" then
                local number = tonumber(value)
                if not number or number ~= number or number == math.huge
                    or number == -math.huge or number <= 0 then
                    return nil, "invalid KinAMP speed field: " .. key
                end
                status[key] = number
            elseif key == "speed_supported" then
                if value ~= "0" and value ~= "1" then
                    return nil, "invalid KinAMP speed support flag"
                end
                status.speed_supported = value == "1"
            else
                status[key] = value
            end
        end
    end
    if not status.state then
        return nil, "KinAMP status is missing state"
    end
    return status
end

local function encode_command(command)
    if type(command) ~= "table" or #command == 0 then
        return nil, "KinAMP command must be a non-empty array"
    end
    local name = command[1]
    if type(name) ~= "string" or name == ""
        or has_control_character(name) then
        return nil, "KinAMP command name is invalid"
    end
    local arity = COMMAND_ARITY[name]
    if arity == nil then
        return nil, name == "quit"
            and "KinAMP quit is not supported by this adapter"
            or "unknown KinAMP command: " .. name
    end
    if #command - 1 ~= arity then
        return nil, "invalid argument count for KinAMP command: " .. name
    end
    local parts = { name }
    for index = 2, #command do
        local part = command[index]
        if type(part) ~= "string" and type(part) ~= "number" then
            return nil, "KinAMP command arguments must be strings or numbers"
        end
        part = tostring(part)
        if part == "" or has_control_character(part) then
            return nil, "KinAMP command contains an invalid argument"
        end
        parts[#parts + 1] = part
    end
    return table.concat(parts, " ")
end

local function encode_commands(commands, maximum)
    if type(commands) ~= "table" or #commands == 0 then
        return nil, "KinAMP commands must be an array; raw strings are rejected"
    end
    local list = type(commands[1]) == "table" and commands or { commands }
    local lines = {}
    for index, command in ipairs(list) do
        local line, error_message = encode_command(command)
        if not line then
            return nil, error_message
        end
        lines[index] = line
    end
    local payload = table.concat(lines, "\n") .. "\n"
    local limit = tonumber(maximum) or KinAMPPort.MAX_FIFO_PAYLOAD
    limit = math.min(limit, KinAMPPort.MAX_FIFO_PAYLOAD)
    if #payload > limit then
        return nil, "KinAMP command payload exceeds the atomic FIFO limit"
    end
    return payload
end

local function publication_token(attributes)
    if type(attributes) ~= "table" then
        return nil
    end
    -- Explicit tokens are only a deterministic-test seam; production lfs
    -- attributes must identify the atomically replaced publication.
    if attributes.token ~= nil then
        return tostring(attributes.token)
    end
    if attributes.ino == nil or attributes.modification == nil then
        return nil
    end
    return table.concat({
        tostring(attributes.dev or "?"),
        tostring(attributes.ino),
        tostring(attributes.modification),
        tostring(attributes.change or "?"),
        tostring(attributes.size or "?"),
    }, ":")
end

local function same_token(left, right)
    return left ~= nil and right ~= nil and left == right
end

local function safe_call(function_value, ...)
    local ok, first, second = pcall(function_value, ...)
    if not ok then
        return nil, tostring(first)
    end
    return first, second
end

function KinAMPPort.new(options)
    options = options or {}
    local getenv = options.getenv or os.getenv
    local runtime_dir = options.runtime_dir
    if runtime_dir == nil then
        runtime_dir = getenv("KINAMP_RUNTIME_DIR")
    end
    if runtime_dir == nil or runtime_dir == "" then
        runtime_dir = DEFAULT_RUNTIME_DIR
    end
    local max_payload = tonumber(options.max_payload)
        or KinAMPPort.MAX_FIFO_PAYLOAD
    local max_status_bytes = tonumber(options.max_status_bytes)
        or KinAMPPort.MAX_STATUS_BYTES
    max_payload = math.max(1, math.min(
        max_payload,
        KinAMPPort.MAX_FIFO_PAYLOAD
    ))
    max_status_bytes = math.max(1, math.min(
        max_status_bytes,
        KinAMPPort.MAX_STATUS_BYTES
    ))
    return setmetatable({
        fs = make_fs(options),
        runtime_dir = runtime_dir,
        command_fifo = join_path(runtime_dir, "kinamp_cmd"),
        status_file = join_path(runtime_dir, "kinamp_status"),
        max_payload = max_payload,
        max_status_bytes = max_status_bytes,
        closed = false,
    }, KinAMPPort)
end

function KinAMPPort:getRuntimeDir()
    return self.runtime_dir
end

function KinAMPPort:_check_fifo()
    if type(self.fs.is_fifo) ~= "function" then
        return nil, "KinAMP FIFO type metadata unavailable"
    end
    local ok, fifo, error_message = pcall(self.fs.is_fifo, self.command_fifo)
    if not ok then
        return nil, "KinAMP FIFO type check failed: " .. tostring(fifo)
    end
    if fifo == nil then
        if missing_file(error_message) then
            return false, "KinAMP FIFO is missing", "missing"
        end
        return nil, error_message or "KinAMP FIFO type metadata unavailable"
    end
    if not fifo then
        return nil, "KinAMP command path is not a FIFO"
    end
    return true
end

function KinAMPPort:_open_fifo()
    local valid, error_message, kind = self:_check_fifo()
    if valid == false then
        return nil, "ENOENT", kind
    end
    if not valid then
        return nil, error_message
    end
    local ok, fd, open_error = pcall(self.fs.open_fifo, self.command_fifo)
    if not ok then
        return nil, "KinAMP FIFO open failed: " .. tostring(fd)
    end
    if not fd then
        return nil, open_error
    end
    if type(self.fs.verify_open_fifo) ~= "function" then
        pcall(self.fs.close_fd, fd)
        return nil, "KinAMP opened-target FIFO metadata unavailable"
    end
    local verified, verify_error = safe_call(self.fs.verify_open_fifo, fd)
    if not verified then
        pcall(self.fs.close_fd, fd)
        return nil, verify_error or "KinAMP opened target is not a FIFO"
    end
    return fd
end

function KinAMPPort:_read_snapshot()
    if type(self.fs.stat_file) ~= "function"
        or type(self.fs.read_file) ~= "function" then
        return nil, "KinAMP status publication metadata unavailable", "compatibility"
    end
    for _ = 1, KinAMPPort.MAX_STATUS_READ_RETRIES do
        local ok_before, before, before_error = pcall(
            self.fs.stat_file,
            self.status_file
        )
        if not ok_before then
            return nil, "KinAMP status publication metadata unavailable: "
                .. tostring(before), "compatibility"
        end
        if not before then
            if missing_file(before_error) then
                return nil, "KinAMP status file is not available", "missing"
            end
            return nil, "KinAMP status publication metadata unavailable: "
                .. tostring(before_error),
                "compatibility"
        end
        local regular, type_error = verify_status_file(before)
        if not regular then
            return nil, type_error, "compatibility"
        end
        local before_token = publication_token(before)
        if not before_token then
            return nil, "KinAMP status publication metadata unavailable",
                "compatibility"
        end

        local ok_read, content, read_error = pcall(
            self.fs.read_file,
            self.status_file,
            self.max_status_bytes
        )
        if not ok_read then
            return nil, "KinAMP status read failed: " .. tostring(content), "read"
        end
        if type(content) ~= "string" then
            if missing_file(read_error) then
                return nil, "KinAMP status file is not available", "missing"
            end
            return nil, "KinAMP status read failed: "
                .. tostring(read_error or "unable to read status file"), "read"
        end

        local ok_after, after, after_error = pcall(
            self.fs.stat_file,
            self.status_file
        )
        if not ok_after then
            return nil, "KinAMP status publication metadata unavailable: "
                .. tostring(after), "compatibility"
        end
        if not after then
            if not missing_file(after_error) then
                return nil, "KinAMP status publication metadata unavailable: "
                    .. tostring(after_error),
                    "compatibility"
            end
        else
            local after_regular, after_type_error = verify_status_file(after)
            if not after_regular then
                return nil, after_type_error, "compatibility"
            end
            local after_token = publication_token(after)
            if not after_token then
                return nil, "KinAMP status publication metadata unavailable",
                    "compatibility"
            end
            if same_token(before_token, after_token) then
                local status, parse_error = parse_status(
                    content,
                    self.max_status_bytes
                )
                if not status then
                    return nil, parse_error, "malformed"
                end
                status.publication_token = after_token
                return status, nil, after_token
            end
        end
    end
    return nil, "KinAMP status changed while it was being read", "unstable"
end

function KinAMPPort:readStatus()
    if self.closed then
        return nil, "KinAMP port is closed"
    end
    return self:_read_snapshot()
end

function KinAMPPort:probe()
    if self.closed then
        return nil, "KinAMP port is closed"
    end
    local valid, error_message, kind = self:_check_fifo()
    if valid == false then
        return { live = false, reason = "missing-fifo", errno = "ENOENT" }
    end
    if not valid then
        return nil, error_message
    end
    local fd, open_error = self:_open_fifo()
    if not fd then
        if errno_is(open_error, "ENOENT") or errno_is(open_error, "ENXIO") then
            return {
                live = false,
                reason = kind == "missing" and "missing-fifo" or "no-listener",
                errno = open_error,
            }
        end
        return nil, "KinAMP FIFO probe failed: " .. error_text(open_error)
    end
    local closed, close_error = safe_call(self.fs.close_fd, fd)
    if not closed then
        return nil, "KinAMP FIFO probe close failed: " .. error_text(close_error)
    end

    local status, status_error, token = self:readStatus()
    if status then
        return {
            live = true,
            status = status,
            token = token,
            publication_token = token,
        }
    end
    if token == "compatibility" then
        return nil, status_error
    end
    return {
        live = true,
        status_error = status_error,
        status_error_kind = token,
    }
end

function KinAMPPort:send(commands)
    if self.closed then
        return nil, "KinAMP port is closed"
    end
    local payload, encode_error = encode_commands(commands, self.max_payload)
    if not payload then
        return nil, encode_error
    end
    if not SIGPIPE_IGNORED then
        local ok, ignored, ignore_error = pcall(self.fs.ignore_sigpipe)
        if not ok then
            return nil, "unable to ignore SIGPIPE: " .. tostring(ignored)
        end
        if not ignored then
            return nil, ignore_error or "unable to ignore SIGPIPE"
        end
        SIGPIPE_IGNORED = true
    end

    local fd, open_error, kind = self:_open_fifo()
    if not fd then
        if kind == "missing" or errno_is(open_error, "ENOENT")
            or errno_is(open_error, "ENXIO") then
            return nil, "KinAMP daemon is not running; start KinAMP first"
        end
        return nil, "KinAMP FIFO open failed: " .. error_text(open_error)
    end

    local eagain = 0
    local eintr = 0
    local wrote
    local write_error
    while true do
        local ok, count, error_value = pcall(self.fs.write_fd, fd, payload)
        if not ok then
            write_error = "KinAMP FIFO write failed: " .. tostring(count)
            break
        end
        if count == true or tonumber(count) == #payload then
            wrote = true
            break
        end
        local errno = error_value or count
        if errno_is(errno, "EINTR") then
            if eintr >= KinAMPPort.MAX_WRITE_RETRIES then
                write_error = "KinAMP FIFO write interrupted too many times"
                break
            end
            eintr = eintr + 1
        elseif errno_is(errno, "EAGAIN") then
            if eagain >= KinAMPPort.MAX_WRITE_RETRIES then
                write_error = "KinAMP FIFO write would block"
                break
            end
            eagain = eagain + 1
        elseif errno_is(errno, "EPIPE") then
            write_error = "KinAMP daemon is not running; start KinAMP first"
            break
        elseif tonumber(count) and tonumber(count) >= 0 then
            write_error = "KinAMP FIFO short write would corrupt an atomic command"
            break
        else
            write_error = "KinAMP FIFO write failed: " .. error_text(errno)
            break
        end
    end
    local closed, close_error = safe_call(self.fs.close_fd, fd)
    if not wrote then
        return nil, write_error
    end
    if not closed then
        return nil, "KinAMP FIFO close failed: " .. error_text(close_error)
    end
    return true
end

function KinAMPPort:requestStatus()
    if self.closed then
        return nil, "KinAMP port is closed"
    end
    local sent, send_error = self:send{{ "status" }}
    if not sent then
        if send_error == "KinAMP daemon is not running; start KinAMP first" then
            return { live = false, reason = "no-listener" }
        end
        return nil, send_error
    end
    local status, status_error, token = self:readStatus()
    if status then
        return {
            live = true,
            status = status,
            token = token,
            publication_token = token,
        }
    end
    if token == "compatibility" then
        return nil, status_error
    end
    return {
        live = true,
        status_error = status_error,
        status_error_kind = token,
    }
end

function KinAMPPort:close()
    -- The daemon is global and this port never established ownership of it.
    -- In particular, never send quit and never kill a process.
    self.closed = true
    return true
end

KinAMPPort.encode = encode_commands
KinAMPPort.parseStatus = parse_status

return KinAMPPort
