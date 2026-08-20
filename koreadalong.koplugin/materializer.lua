local ffi = require("ffi")

require("ffi/posix_h")

local C = ffi.C

local Materializer = {}
Materializer.__index = Materializer

local function strerror(error_number)
    return ffi.string(C.strerror(error_number or ffi.errno()))
end

local function default_syscalls()
    return {
        make_directory = function(template)
            local buffer = ffi.new("char[?]", #template + 1, template)
            if C.mkdtemp(buffer) == nil then
                return nil, strerror()
            end
            return ffi.string(buffer)
        end,
        make_file = function(template, suffix_length)
            local buffer = ffi.new("char[?]", #template + 1, template)
            local fd = C.mkstemps(buffer, suffix_length)
            if fd < 0 then
                return nil, strerror()
            end
            return fd, ffi.string(buffer)
        end,
        write = function(fd, buffer, length)
            local written = C.write(fd, buffer, length)
            if written < 0 then
                return nil, ffi.errno()
            end
            return tonumber(written)
        end,
        close = function(fd)
            return C.close(fd) == 0
        end,
        remove = function(path)
            return os.remove(path)
        end,
        error_string = strerror,
        eintr = C.EINTR,
    }
end

local function audio_suffix(audio_path)
    local suffix = audio_path:match("(%.[^/%.]+)$")
    if not suffix or #suffix > 16 or not suffix:match("^%.[A-Za-z0-9]+$") then
        return ""
    end
    return suffix
end

local function invoke_reader(read_file, path)
    local ok, bytes, error_message = pcall(read_file, path)
    if not ok then
        return nil, "archive read failed: " .. tostring(bytes)
    end
    if type(bytes) ~= "string" then
        return nil, error_message and tostring(error_message)
            or "archive reader returned non-binary content"
    end
    return bytes
end

function Materializer.new(options)
    options = options or {}
    return setmetatable({
        root = options.root or "/tmp",
        prefix = options.prefix or "koreadalong-",
        file_prefix = options.file_prefix or "audio-",
        syscalls = options.syscalls or default_syscalls(),
        session_dir = nil,
        owned_files = {},
        closed = false,
    }, Materializer)
end

function Materializer:_ensure_session()
    if self.closed then
        return nil, "materializer is closed"
    end
    if self.session_dir then
        return self.session_dir
    end
    local template = self.root .. "/" .. self.prefix .. "XXXXXX"
    local directory, error_message = self.syscalls.make_directory(template)
    if not directory then
        return nil, "unable to create private audio directory: "
            .. tostring(error_message or "unknown error")
    end
    self.session_dir = directory
    return directory
end

local function close_file(syscalls, fd)
    local closed = syscalls.close(fd)
    if closed == false then
        return nil, "unable to close materialized audio file"
    end
    return true
end

local function remove_path(self, path)
    local ok, removed, error_message = pcall(
        self.syscalls.remove,
        path
    )
    if not ok then
        return nil, "remove failed: " .. tostring(removed)
    end
    if not removed then
        return nil, "remove failed: " .. tostring(error_message or "unknown error")
    end
    return true
end

function Materializer:_remove_owned(path)
    if not path or not self.owned_files[path] then
        return false, "audio path is not owned"
    end
    local removed, error_message = remove_path(self, path)
    if not removed then
        return nil, "unable to remove private audio '" .. path
            .. "': " .. tostring(error_message)
    end
    self.owned_files[path] = nil
    return true
end

function Materializer:materialize(audio_path, read_file)
    if type(audio_path) ~= "string" or audio_path == "" then
        return nil, "audio archive path must be a non-empty string"
    end
    if type(read_file) ~= "function" then
        return nil, "audio archive reader is missing"
    end

    local bytes, read_error = invoke_reader(read_file, audio_path)
    if not bytes then
        return nil, read_error
    end

    local directory, directory_error = self:_ensure_session()
    if not directory then
        return nil, directory_error
    end

    local suffix = audio_suffix(audio_path)
    local template = directory .. "/" .. self.file_prefix .. "XXXXXX" .. suffix
    local fd, path_or_error = self.syscalls.make_file(template, #suffix)
    if not fd then
        return nil, "unable to create private audio file: "
            .. tostring(path_or_error or "unknown error")
    end
    local path = path_or_error
    self.owned_files[path] = true

    local buffer = ffi.new("uint8_t[?]", math.max(#bytes, 1))
    if #bytes > 0 then
        ffi.copy(buffer, bytes, #bytes)
    end

    local offset = 0
    local write_error
    while offset < #bytes do
        local written, error_number = self.syscalls.write(
            fd,
            buffer + offset,
            #bytes - offset
        )
        if not written then
            if error_number ~= self.syscalls.eintr then
                write_error = "unable to write private audio file: "
                    .. tostring(self.syscalls.error_string(error_number))
                break
            end
        elseif written <= 0 then
            write_error = "unable to write private audio file: short write"
            break
        else
            offset = offset + written
        end
    end

    local close_ok, close_error = close_file(self.syscalls, fd)
    if write_error or not close_ok then
        local removed, remove_error = self:_remove_owned(path)
        local failure = write_error or close_error
        if not removed then
            failure = failure .. "; " .. tostring(remove_error)
        end
        return nil, failure
    end
    return path
end

function Materializer:remove(path)
    return self:_remove_owned(path)
end

function Materializer:cleanup()
    local first_error
    for path in pairs(self.owned_files) do
        local removed, error_message = self:_remove_owned(path)
        if not removed and not first_error then
            first_error = error_message
        end
    end
    if self.session_dir and not next(self.owned_files) then
        local removed, error_message = remove_path(self, self.session_dir)
        if removed then
            self.session_dir = nil
        elseif not first_error then
            first_error = "unable to remove private audio directory '"
                .. self.session_dir .. "': " .. tostring(error_message)
        end
    end
    self.closed = true
    if first_error then
        return nil, first_error
    end
    return true
end

return Materializer
