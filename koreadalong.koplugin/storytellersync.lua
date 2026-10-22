-- Read-only Storyteller v3 LAN receiver. Discovery is not authentication.
local Sync = {}
Sync.__index = Sync
local SERVICE = "_storyteller-lrs._udp.local"
local ENUM = "_services._dns-sd._udp.local"
local MAX_PACKET, MAX_WORK = 8192, 16

local function u16(n)
    return string.char(math.floor(n / 256) % 256, n % 256)
end

local function name(s)
    local parts = {}
    for label in s:gmatch("[^.]+") do
        parts[#parts + 1] = string.char(#label) .. label
    end
    return table.concat(parts) .. "\0"
end

local function ipv4(s)
    if type(s) ~= "string" then return end
    local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if a == 0 or a >= 224 or b > 255 or c > 255 or d > 255 then return end
    return string.char(a, b, c, d)
end

local function read16(s, p)
    local a, b = s:byte(p, p + 1)
    assert(b, "short DNS packet")
    return a * 256 + b
end

-- Both expanded length and pointer traversal are bounded, including cycles.
local function readname(s, p)
    local parts, finish, length = {}, nil, 0
    for _ = 1, 128 do
        local n = s:byte(p)
        assert(n, "short DNS name")
        if n == 0 then return table.concat(parts, "."):lower(), finish or p + 1 end
        if n >= 192 then
            local target = (n - 192) * 256 + assert(s:byte(p + 1)) + 1
            finish = finish or p + 2
            p = target
        else
            assert(n <= 63 and p + n <= #s, "bad DNS label")
            length = length + n + 1
            assert(length <= 255, "long DNS name")
            parts[#parts + 1] = s:sub(p + 1, p + n)
            p = p + n + 1
        end
    end
    error("DNS pointer loop")
end

local function questions(s)
    assert(#s >= 12 and read16(s, 3) < 32768, "not a query")
    local count, p, result = read16(s, 5), 13, {}
    assert(count <= 32, "too many questions")
    for _ = 1, count do
        local q
        q, p = readname(s, p)
        local kind, class = read16(s, p), read16(s, p + 2)
        p = p + 4
        result[#result + 1] = { name = q, kind = kind, class = class }
    end
    return result, s:sub(13, p - 1)
end

local function record(owner, kind, unique, ttl, data)
    return name(owner) .. u16(kind) .. u16(unique and 32769 or 1)
        .. u16(0) .. u16(ttl) .. u16(#data) .. data
end

function Sync.new(options)
    return setmetatable({ options = options or {} }, Sync)
end

function Sync:_response(ttl, id, query, count, legacy)
    local unique = not legacy
    local records = {
        record(SERVICE, 12, false, ttl, name(self.instance)),
        record(self.instance, 33, unique, ttl, u16(0) .. u16(0) .. u16(self.port) .. name(self.hostname)),
        record(self.instance, 16, unique, ttl, "\0"),
        record(self.hostname, 1, unique, ttl, self.ipbytes),
        record(ENUM, 12, false, ttl, name(SERVICE)),
    }
    return u16(id or 0) .. u16(33792) .. u16(count or 0) .. u16(#records)
        .. u16(0) .. u16(0) .. (query or "") .. table.concat(records)
end

function Sync:_send(ttl, host, port, id, query, count, legacy)
    local ok, err = self.mdns:sendto(self:_response(ttl, id, query, count, legacy),
        host or self.multicast, port or self.mdns_port)
    if not ok and err ~= "timeout" then return nil, err end
    return true
end

function Sync:start()
    if self.udp then return true end
    local options = self.options
    self.socket = options.socket or require("socket")
    self.clock = options.clock or self.socket.gettime
    self.multicast = options.multicast_address or "224.0.0.251"
    self.mdns_port = options.mdns_port or 5353
    local udp = self.socket.udp4 or self.socket.udp
    local function checked(value, err)
        assert(value, err or "socket operation failed")
        return value
    end
    local ok, err = pcall(function()
        local address = options.address
        if not address then
            self.route = checked(udp())
            checked(self.route:settimeout(0))
            checked(self.route:setpeername(self.multicast, self.mdns_port))
            address = self.route:getsockname()
            self.route:close()
            self.route = nil
        end
        self.ipbytes = checked(ipv4(address), "no usable local IPv4 address")
        self.address = address
        self.udp = checked(udp())
        checked(self.udp:settimeout(0))
        checked(self.udp:setsockname("0.0.0.0", 0))
        local _, port = self.udp:getsockname()
        self.port = checked(port)
        self.mdns = checked(udp())
        checked(self.mdns:settimeout(0))
        checked(self.mdns:setoption("reuseaddr", true))
        checked(self.mdns:setsockname("0.0.0.0", self.mdns_port))
        checked(self.mdns:setoption("ip-add-membership", {
            multiaddr = self.multicast, interface = address,
        }))
        checked(self.mdns:setoption("ip-multicast-if", address))
        checked(self.mdns:setoption("ip-multicast-ttl", 255))
        -- OS entropy, not a globally seeded PRNG shared with KOReader UI.
        local entropy = checked(io.open("/dev/urandom", "rb"))
        local bytes = entropy:read(12)
        entropy:close()
        checked(bytes and #bytes == 12, "no name entropy")
        local suffix = bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end)
        self.hostname = "koreadalong-" .. suffix .. ".local"
        self.instance = "KOReadalong-" .. suffix .. "." .. SERVICE
        checked(self:_send(120))
        self.next_announce = self.clock() + 1
    end)
    if not ok then self:close(); return nil, tostring(err) end
    return true
end

-- Reject excessively nested JSON before invoking a recursive decoder.
local function decode(json, s)
    local depth, quoted, escaped = 0, false, false
    for i = 1, #s do
        local c = s:sub(i, i)
        if quoted then
            if escaped then escaped = false
            elseif c == "\\" then escaped = true
            elseif c == '"' then quoted = false end
        elseif c == '"' then quoted = true
        elseif c == "{" or c == "[" then
            depth = depth + 1
            if depth > 16 then return end
        elseif c == "}" or c == "]" then depth = depth - 1 end
    end
    local ok, value, pos, err = pcall(json.decode, s)
    if ok and type(value) == "table" and s:match("^%s*{") and not err
        and (not pos or s:sub(pos):match("^%s*$")) then return value end
end

function Sync:poll()
    if not self.udp then return nil, "receiver not started" end
    local function failed(err)
        self:close()
        return nil, tostring(err)
    end
    if self.clock() >= self.next_announce then
        local ok, err = self:_send(120)
        if not ok then return failed(err) end
        self.next_announce = self.clock() + 60
    end
    for _ = 1, MAX_WORK do
        local s, host, port = self.mdns:receivefrom(MAX_PACKET + 1)
        if not s then
            if host ~= "timeout" then return failed(host) end
            break
        end
        if #s <= MAX_PACKET then
            local ok, qs, raw = pcall(questions, s)
            if ok then
                local matches, unicast = false, port ~= self.mdns_port
                for _, q in ipairs(qs) do
                    local class = q.class % 32768
                    if (class == 1 or class == 255) and (
                        (q.name == SERVICE and (q.kind == 12 or q.kind == 255))
                        or (q.name == ENUM and (q.kind == 12 or q.kind == 255))
                        or (q.name == self.instance:lower() and (q.kind == 33 or q.kind == 16 or q.kind == 255))
                        or (q.name == self.hostname and (q.kind == 1 or q.kind == 255))) then
                        matches = true
                        unicast = unicast or q.class >= 32768
                    end
                end
                if matches then
                    local legacy = port ~= self.mdns_port
                    local sent, err = self:_send(legacy and 10 or 120,
                        unicast and host or nil, unicast and port or nil,
                        legacy and read16(s, 1) or 0, legacy and raw or nil,
                        legacy and #qs or 0, legacy)
                    if not sent then return failed(err) end
                end
            end
        end
    end
    self.json = self.json or require("dkjson")
    local result = {}
    for _ = 1, MAX_WORK do
        local s, host, port = self.udp:receivefrom(MAX_PACKET + 1)
        if not s then
            if host ~= "timeout" then return failed(host) end
            break
        end
        if #s <= MAX_PACKET then
            local packet = decode(self.json, s)
            if packet then result[#result + 1] = { packet = packet, host = host, port = port } end
        end
    end
    return result
end

function Sync:getAddress()
    if self.udp then return self.address, self.port end
end

function Sync:close()
    if self.mdns and self.instance then pcall(self._send, self, 0) end
    for _, key in ipairs({ "route", "udp", "mdns" }) do
        if self[key] then pcall(self[key].close, self[key]); self[key] = nil end
    end
    self.address, self.port, self.instance = nil, nil, nil
end

return Sync
