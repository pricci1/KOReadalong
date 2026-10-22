package.path = "./koreadalong.koplugin/?.lua;"
    .. ".cache/koreader/lib/koreader/?.lua;"
    .. ".cache/koreader/lib/koreader/common/?.lua;"
    .. package.path
package.cpath = ".cache/koreader/lib/koreader/common/?.so;" .. package.cpath

local Sync = require("storytellersync")
local socket = require("socket")
local json = require("dkjson")
local SERVICE = "_storyteller-lrs._udp.local"

-- Independent wire encoder/parser: never inspect implementation fields.
local function word(n) return string.char(math.floor(n / 256), n % 256) end
local function number(s, p) return s:byte(p) * 256 + s:byte(p + 1) end
local function dnsname(s)
    return (s:gsub("([^.]+)%.?", function(label) return string.char(#label) .. label end)) .. "\0"
end
local function readname(s, p)
    local labels = {}
    while s:byte(p) ~= 0 do
        local n = s:byte(p)
        assert.is_true(n < 64)
        labels[#labels + 1] = s:sub(p + 1, p + n)
        p = p + n + 1
    end
    return table.concat(labels, "."), p + 1
end
local function records(s)
    local p, out = 13, {}
    for _ = 1, number(s, 5) do
        local _, nextp = readname(s, p)
        p = nextp + 4
    end
    for _ = 1, number(s, 7) do
        local owner
        owner, p = readname(s, p)
        local kind, class, ttl, size = number(s, p), number(s, p + 2),
            number(s, p + 4) * 65536 + number(s, p + 6), number(s, p + 8)
        p = p + 10
        out[kind] = { owner = owner, class = class, ttl = ttl, data = s:sub(p, p + size - 1) }
        p = p + size
    end
    assert.are.equal(#s + 1, p)
    return out
end
local function query(owner, kind, class)
    return word(42) .. word(0) .. word(1) .. string.rep("\0", 6)
        .. dnsname(owner) .. word(kind) .. word(class or 1)
end
local function freeport()
    local s = assert(socket.udp())
    assert(s:setsockname("127.0.0.1", 0))
    local _, port = s:getsockname()
    s:close()
    return port
end

describe("Storyteller read-only UDP boundary", function()
    local receiver, phone, mdns_port, sent, now, wrappers
    before_each(function()
        sent, wrappers, now = {}, {}, 100
        mdns_port = freeport()
        -- All datagrams use real LuaSocket; observe outgoing DNS for refresh/goodbye.
        local adapter = { gettime = socket.gettime }
        function adapter.udp()
            local raw = assert(socket.udp4())
            local proxy = {}
            setmetatable(proxy, { __index = function(_, key)
                return function(_, ...) return raw[key](raw, ...) end
            end })
            function proxy:sendto(data, host, port)
                sent[#sent + 1] = { data = data, host = host, port = port }
                return raw:sendto(data, host, port)
            end
            wrappers[#wrappers + 1] = proxy
            return proxy
        end
        receiver = Sync.new{ socket = adapter, address = "127.0.0.1", mdns_port = mdns_port,
            clock = function() return now end }
        phone = assert(socket.udp())
        assert(phone:setsockname("127.0.0.1", 0))
        phone:settimeout(0.2)
    end)
    after_each(function() receiver:close(); phone:close() end)

    it("is IO-free until start and receives actual phone JSON with source metadata", function()
        assert.is_nil(receiver:getAddress())
        assert.are.equal(0, #wrappers)
        assert(receiver:start())
        assert(receiver:start())
        assert.are.equal(2, #wrappers)
        local host, port = receiver:getAddress()
        local packet = { version = 1, senderID = "phone", bookID = { sourceID = "local", uuid = "book" },
            sectionIndex = 3, entryIndex = 4, textId = "p1", textHref = "chapter.xhtml",
            playbackRate = 1.2, sentAt = 1700000000 }
        assert(phone:sendto(json.encode(packet), host, port))
        local result = assert(receiver:poll())
        local _, source_port = phone:getsockname()
        assert.same({ { packet = packet, host = "127.0.0.1", port = source_port } }, result)
        assert.same({}, receiver:poll())
        receiver:close(); receiver:close()
        assert.is_nil(receiver:getAddress())
        assert.is_nil(receiver:poll())
    end)

    it("advertises DNS-SD and resolves legacy PTR, SRV, TXT and A queries on the wire", function()
        assert(receiver:start())
        assert.are.equal("224.0.0.251", sent[1].host)
        local advertised = records(sent[1].data)
        assert.are.equal(SERVICE, advertised[33].owner:match("%.(.+)$"))
        assert.are.equal(120, advertised[1].ttl)
        assert.are.equal(32769, advertised[1].class)
        assert.are.equal("\127\0\0\1", advertised[1].data)
        assert.are.equal("\0", advertised[16].data)
        local _, port = receiver:getAddress()
        assert.are.equal(port, number(advertised[33].data, 5))
        local target = readname(advertised[33].data, 7)
        assert.are.equal(advertised[1].owner, target)
        for _, q in ipairs({ { SERVICE, 12 }, { advertised[33].owner, 33 },
            { advertised[16].owner, 16 }, { target, 1 } }) do
            assert(phone:sendto(query(q[1], q[2]), "127.0.0.1", mdns_port))
            assert(receiver:poll())
            local response = assert(phone:receive())
            assert.are.equal(42, number(response, 1))
            assert.are.equal(1, number(response, 5))
            local rr = records(response)
            assert.are.equal(10, rr[1].ttl)
            assert.are.equal(1, rr[1].class)
            assert.are.equal(advertised[33].data, rr[33].data)
        end
    end)

    it("answers QU and compressed questions, refreshes TTL and withdraws on close", function()
        assert(receiver:start())
        -- Bind a separate loopback address at the mDNS source port for a genuine QU query.
        local client = assert(socket.udp4())
        assert(client:setoption("reuseaddr", true))
        assert(client:setsockname("127.0.0.2", mdns_port))
        client:settimeout(0.2)
        local q = query(SERVICE, 12, 32769)
        -- Two questions, second name compressed to first.
        q = q:sub(1, 4) .. word(2) .. q:sub(7) .. "\192\12" .. word(12) .. word(32769)
        assert(client:sendto(q, "127.0.0.1", mdns_port))
        assert(receiver:poll())
        local response = assert(client:receive())
        client:close()
        assert.are.equal(0, number(response, 1))
        assert.are.equal(0, number(response, 5))
        assert.are.equal(120, records(response)[1].ttl)
        now = 101
        assert(receiver:poll())
        assert.are.equal(120, records(sent[#sent].data)[1].ttl)
        now = 161
        assert(receiver:poll())
        assert.are.equal(120, records(sent[#sent].data)[1].ttl)
        receiver:close()
        assert.are.equal(0, records(sent[#sent].data)[1].ttl)
    end)

    it("ignores malformed, oversized and deeply nested input and bounds each poll", function()
        assert(receiver:start())
        local host, port = receiver:getAddress()
        for _, s in ipairs({ "{", "[]", "{}trailing", string.rep(" ", 9000),
            string.rep('[', 30) .. string.rep(']', 30) }) do
            assert(phone:sendto(s, host, port))
        end
        assert(phone:sendto(query(SERVICE, 12):sub(1, 12) .. "\192\12\0\12\0\1",
            "127.0.0.1", mdns_port))
        assert.same({}, receiver:poll())
        for _ = 1, 20 do assert(phone:sendto('{"version":1}', host, port)) end
        assert.are.equal(16, #assert(receiver:poll()))
        assert.are.equal(4, #assert(receiver:poll()))
    end)

    it("fails closed on partial startup and terminal receive failures", function()
        local blocker = assert(socket.udp())
        assert(blocker:setsockname("0.0.0.0", mdns_port))
        local ok, err = receiver:start()
        blocker:close()
        assert.is_nil(ok)
        assert.is_string(err)
        assert.is_nil(receiver:getAddress())
        assert(receiver:start())
        -- LuaSocket reports timeout even for some closed UDP handles; inject
        -- the explicit terminal error that the boundary must propagate.
        wrappers[#wrappers - 1].receivefrom = function() return nil, "closed" end
        ok, err = receiver:poll()
        assert.is_nil(ok)
        assert.is_string(err)
        assert.is_nil(receiver:getAddress())
    end)

    it("answers multicast browse queries over real multicast UDP", function()
        local browser = assert(socket.udp4())
        assert(browser:setoption("reuseaddr", true))
        assert(browser:setsockname("0.0.0.0", mdns_port))
        assert(browser:setoption("ip-add-membership", {
            multiaddr = "224.0.0.251", interface = "127.0.0.1",
        }))
        assert(browser:setoption("ip-multicast-if", "127.0.0.1"))
        browser:settimeout(0.2)
        assert(receiver:start())
        local initial = assert(browser:receive())
        assert.are.equal(120, records(initial)[1].ttl)
        assert(browser:sendto(query(SERVICE, 12), "224.0.0.251", mdns_port))
        assert(browser:receive()) -- looped-back query
        assert(receiver:poll())
        local response = assert(browser:receive())
        assert.are.equal(0, number(response, 5))
        assert.are.equal(120, records(response)[1].ttl)
        receiver:close()
        local goodbye = assert(browser:receive())
        browser:close()
        assert.are.equal(0, records(goodbye)[1].ttl)
    end)

    it("selects a local IPv4 using only the multicast route", function()
        receiver = Sync.new{ mdns_port = mdns_port }
        assert(receiver:start())
        local host, port = receiver:getAddress()
        assert.matches("^%d+%.%d+%.%d+%.%d+$", host)
        assert.is_true(port > 0)
        assert(phone:sendto('{"version":1}', host, port))
        assert.are.equal(1, #assert(receiver:poll()))
    end)

    it("rejects unusable explicit addresses without opening sockets", function()
        receiver = Sync.new{ address = "0.0.0.0" }
        local ok, err = receiver:start()
        assert.is_nil(ok)
        assert.matches("no usable local IPv4", err)
        assert.is_nil(receiver:getAddress())
    end)
end)
