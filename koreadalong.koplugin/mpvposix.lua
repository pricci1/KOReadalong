local ffi = require("ffi")

require("ffi/posix_h")

-- posix_h.lua deliberately does not expose the stream-socket constants and
-- socket error query used by this small private IPC client.
ffi.cdef[[
static const unsigned SOCK_STREAM = 1;
static const unsigned SOL_SOCKET = 1;
static const unsigned SO_ERROR = 4;
static const unsigned ENOENT = 2;
static const unsigned SIGKILL = 9;
static const unsigned POLLNVAL = 32;
int getsockopt(int, int, int, void *, socklen_t *);
]]

if ffi.os == "Linux" then
    ffi.cdef[[
static const unsigned EINPROGRESS = 115;
static const unsigned EALREADY = 114;
static const unsigned ECONNREFUSED = 111;
]]
elseif ffi.os == "OSX" then
    ffi.cdef[[
static const unsigned EINPROGRESS = 36;
static const unsigned EALREADY = 37;
static const unsigned ECONNREFUSED = 61;
]]
end

if ffi.os == "Linux" then
    ffi.cdef[[
static const unsigned FIONBIO = 21537;
static const unsigned FIOCLEX = 21585;
]]
elseif ffi.os == "OSX" then
    ffi.cdef[[
static const unsigned FIONBIO = 2147773566;
static const unsigned FIOCLEX = 536897025;
]]
end

local C = ffi.C
local posix = {
    C = C,
    ffi = ffi,
    -- MSG_NOSIGNAL differs on macOS. It prevents a closed mpv socket from
    -- delivering SIGPIPE to KOReader while a nonblocking write is attempted.
    MSG_NOSIGNAL = ffi.os == "OSX" and 0x20000 or 0x4000,
}

function posix.strerror(error_number)
    return ffi.string(C.strerror(error_number or ffi.errno()))
end

function posix.is_errno(error_number, name)
    return error_number == C[name]
end

function posix.set_nonblocking(fd)
    local enabled = ffi.new("int[1]", 1)
    if C.ioctl(fd, C.FIONBIO, enabled) < 0 then
        return nil, posix.strerror()
    end
    return true
end

function posix.set_cloexec(fd)
    if C.ioctl(fd, C.FIOCLEX, 0) < 0 then
        return nil, posix.strerror()
    end
    return true
end

function posix.unix_address(path)
    local address = ffi.new("struct sockaddr_un")
    local path_offset = ffi.offsetof("struct sockaddr_un", "sun_path")
    local path_capacity = ffi.sizeof(address) - path_offset
    if #path >= path_capacity then
        return nil, "Unix socket path is too long"
    end
    address.sun_family = C.AF_UNIX
    ffi.copy(address.sun_path, path, #path)
    address.sun_path[#path] = 0
    return address, ffi.sizeof(address)
end

return posix
