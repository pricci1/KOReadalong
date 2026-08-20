local ffi = require("ffi")

local posix = require("mpvposix")
local C = posix.C

local MpvProcess = {}
MpvProcess.__index = MpvProcess

local DEFAULT_EXECUTABLE = "mpv"
local DEFAULT_TERM_TIMEOUT = 0.4
local DEFAULT_KILL_TIMEOUT = 0.4

local function append(destination, values)
    for _, value in ipairs(values) do
        destination[#destination + 1] = value
    end
end

local function create_session_directory()
    local template = "/tmp/koreadalong-mpv-XXXXXX"
    local buffer = ffi.new("char[?]", #template + 1, template)
    if C.mkdtemp(buffer) == nil then
        return nil, "unable to create private mpv directory: " .. posix.strerror()
    end
    return ffi.string(buffer)
end

local function remove_owned_files(self)
    if self.cleaned then
        return
    end
    if self.socket_path then
        os.remove(self.socket_path)
    end
    if self.session_dir then
        os.remove(self.session_dir)
    end
    self.cleaned = true
end

local function make_argv(self)
    local argv = {
        self.executable,
        "--no-config",
        "--idle=yes",
        "--no-video",
        "--no-terminal",
        "--input-default-bindings=no",
        "--input-vo-keyboard=no",
        "--audio-fallback-to-null=no",
        "--input-ipc-server=" .. self.socket_path,
    }
    if self.test_only then
        append(argv, self.extra_args)
    end
    return argv
end

local function spawn(self, argv)
    local pipe = ffi.new("int[2]", { -1, -1 })
    if C.pipe(pipe) ~= 0 then
        return nil, "unable to create mpv exec-status pipe: " .. posix.strerror()
    end
    local cloexec, cloexec_error = posix.set_cloexec(pipe[1])
    if not cloexec then
        C.close(pipe[0])
        C.close(pipe[1])
        return nil, "unable to configure mpv exec-status pipe: " .. cloexec_error
    end
    local nonblocking, nonblocking_error = posix.set_nonblocking(pipe[0])
    if not nonblocking then
        C.close(pipe[0])
        C.close(pipe[1])
        return nil, "unable to configure mpv exec-status pipe: " .. nonblocking_error
    end

    local pid = C.fork()
    if pid < 0 then
        local error_message = posix.strerror()
        C.close(pipe[0])
        C.close(pipe[1])
        return nil, "unable to fork mpv: " .. error_message
    end
    if pid == 0 then
        C.close(pipe[0])
        C.setpgid(0, 0)

        local c_args = ffi.new("char *[?]", #argv + 1)
        local c_strings = {}
        for index, argument in ipairs(argv) do
            c_strings[index] = ffi.new("char[?]", #argument + 1, argument)
            c_args[index - 1] = c_strings[index]
        end
        c_args[#argv] = nil
        C.execvp(c_args[0], c_args)

        -- This pipe has CLOEXEC on the parent-visible write end, so EOF means
        -- exec succeeded and a four-byte errno means it failed. The write is
        -- a single small, atomic pipe write and cannot block in this path.
        local error_number = ffi.new("int[1]", ffi.errno())
        C.write(pipe[1], error_number, ffi.sizeof(error_number))
        C._exit(127)
    end

    C.close(pipe[1])
    self.pid = tonumber(pid)
    self.exec_status_fd = pipe[0]
    self.exec_status_buffer = ffi.new("char[?]", ffi.sizeof("int"))
    self.exec_status_bytes = 0
    self.argv = argv
    self.started = true
    self.exec_confirmed = false
    return true
end

local function process_status(status)
    status = tonumber(status)
    local signal = status % 128
    if signal == 0 then
        return {
            exited = true,
            exit_code = math.floor(status / 256),
        }
    end
    return {
        signaled = true,
        signal = signal,
    }
end

function MpvProcess.new(options)
    options = options or {}
    return setmetatable({
        executable = options.executable or DEFAULT_EXECUTABLE,
        extra_args = options.extra_args or {},
        test_only = options.test_only == true,
        term_timeout = options.term_timeout or DEFAULT_TERM_TIMEOUT,
        kill_timeout = options.kill_timeout or DEFAULT_KILL_TIMEOUT,
        cleaned = false,
    }, MpvProcess)
end

function MpvProcess:start()
    if self.started then
        return nil, "mpv process has already been started"
    end
    self.session_dir, self.start_error = create_session_directory()
    if not self.session_dir then
        return nil, self.start_error
    end
    self.socket_path = self.session_dir .. "/mpv.sock"
    local started, start_error = spawn(self, make_argv(self))
    if not started then
        remove_owned_files(self)
        return nil, start_error
    end
    return self.socket_path
end

function MpvProcess:poll(now)
    local events = {}
    if not self.started or self.reaped then
        return events
    end

    if self.exec_status_fd then
        local status_size = ffi.sizeof("int")
        local bytes = C.read(
            self.exec_status_fd,
            self.exec_status_buffer + self.exec_status_bytes,
            status_size - self.exec_status_bytes
        )
        if bytes > 0 then
            self.exec_status_bytes = self.exec_status_bytes + bytes
        end
        if self.exec_status_bytes == status_size then
            local error_number = ffi.new("int[1]")
            ffi.copy(error_number, self.exec_status_buffer, status_size)
            C.close(self.exec_status_fd)
            self.exec_status_fd = nil
            events[#events + 1] = {
                kind = "exec_error",
                error = "mpv exec failed: " .. posix.strerror(error_number[0]),
            }
        elseif bytes == 0 then
            C.close(self.exec_status_fd)
            self.exec_status_fd = nil
            if self.exec_status_bytes == 0 then
                self.exec_confirmed = true
                events[#events + 1] = { kind = "exec_ready" }
            else
                events[#events + 1] = {
                    kind = "exec_error",
                    error = "mpv exec-status pipe closed mid-error",
                }
            end
        elseif bytes < 0
            and not posix.is_errno(ffi.errno(), "EAGAIN")
            and not posix.is_errno(ffi.errno(), "EINTR") then
            C.close(self.exec_status_fd)
            self.exec_status_fd = nil
            events[#events + 1] = {
                kind = "exec_error",
                error = "mpv exec-status read failed: " .. posix.strerror(),
            }
        end
    end

    local status = ffi.new("int[1]")
    local result = C.waitpid(self.pid, status, C.WNOHANG)
    if result == self.pid then
        self.reaped = true
        self.status = process_status(status[0])
        if self.exec_status_fd then
            C.close(self.exec_status_fd)
            self.exec_status_fd = nil
        end
        events[#events + 1] = {
            kind = "exit",
            status = self.status,
        }
        remove_owned_files(self)
        events[#events + 1] = { kind = "closed" }
    elseif result < 0
        and not posix.is_errno(ffi.errno(), "EINTR") then
        events[#events + 1] = {
            kind = "wait_error",
            error = "waitpid failed: " .. posix.strerror(),
        }
    end

    if self.closing and not self.reaped then
        now = now or 0
        if not self.term_sent and now >= self.close_deadline then
            C.kill(-self.pid, C.SIGTERM)
            self.term_sent = true
            self.kill_deadline = now + self.kill_timeout
            events[#events + 1] = { kind = "term_sent" }
        elseif self.term_sent and not self.kill_sent and now >= self.kill_deadline then
            C.kill(-self.pid, C.SIGKILL)
            self.kill_sent = true
            self.kill_deadline = now + self.kill_timeout
            events[#events + 1] = { kind = "kill_sent" }
        end
    end

    return events
end

function MpvProcess:begin_close(now)
    if self.reaped or self.closing then
        return
    end
    self.closing = true
    self.close_deadline = (now or 0) + self.term_timeout
end

function MpvProcess:is_done()
    return not self.started or self.reaped
end

function MpvProcess:cleanup()
    if self.exec_status_fd then
        C.close(self.exec_status_fd)
        self.exec_status_fd = nil
    end
    if self.reaped or not self.started then
        remove_owned_files(self)
    end
end

return MpvProcess
