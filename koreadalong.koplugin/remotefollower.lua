local MediaOverlays = require("mediaoverlays")

local RemoteFollower = {}
RemoteFollower.__index = RemoteFollower

local MAX_PEERS = 16
local MAX_PENDING = 64
local POLL_INTERVAL = 0.1

local function finite(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function text(value, limit)
    return type(value) == "string" and #value > 0 and #value <= limit
        and not value:find("[%z\1-\31\127]")
end

local function integer(value)
    return finite(value) and value >= 0 and value <= 10000000 and value == math.floor(value)
end

local function packet_key(packet, host)
    return host .. "\0" .. packet.senderID .. "\0" .. packet.bookID.sourceID .. "\0" .. packet.bookID.uuid
end

local function anchor_key(path, fragment)
    return path .. "\0" .. fragment
end

local function validate(packet)
    if type(packet) ~= "table" or packet.version ~= 1
        or not text(packet.senderID, 128) or type(packet.bookID) ~= "table"
        or not text(packet.bookID.uuid, 256) or not text(packet.bookID.sourceID, 256)
        or not text(packet.textHref, 2048) or not text(packet.textId, 1024)
        or not integer(packet.sectionIndex) or not integer(packet.entryIndex)
        or not finite(packet.playbackRate) or packet.playbackRate < 0.1 or packet.playbackRate > 10
        or not finite(packet.sentAt) or packet.sentAt < 0
        or packet.textHref:find("[:\\]") or packet.textHref:sub(1, 1) == "/" then
        return nil
    end
    local path, fragment = MediaOverlays.resolve_path("", packet.textHref)
    if not path or fragment then
        return nil
    end
    return path
end

function RemoteFollower.new(options)
    local correction = options.correction
    if not finite(correction) or correction < -5 or correction > 2 then
        correction = 0
    end
    local self = setmetatable({
        port = options.port, scheduler = options.scheduler, clock = options.clock,
        clips = options.clips, ranges = options.ranges, overlay = options.overlay,
        on_range = options.on_range, on_range_cleared = options.on_range_cleared,
        on_error = options.on_error, on_correction = options.on_correction,
        correction = correction, peers = {}, anchors = {}, pending = {}, generation = 0,
    }, RemoteFollower)
    for index, clip in ipairs(self.clips) do
        local key = anchor_key(clip.text_path, clip.text_fragment)
        self.anchors[key] = self.anchors[key] or {}
        table.insert(self.anchors[key], index)
    end
    return self
end

function RemoteFollower:isActive()
    return self.running == true and self.selected ~= nil
end

function RemoteFollower:getCurrentRange()
    if self.current_range then
        return { pos0 = self.current_range.pos0, pos1 = self.current_range.pos1 }
    end
end

function RemoteFollower:_clear(reason)
    self.current_range, self.shown_index, self.estimated = nil, nil, false
    self.overlay:clear()
    if self.on_range_cleared then
        self.on_range_cleared(reason)
    end
end

function RemoteFollower:_show(index, estimated)
    self.estimated = estimated == true
    if self.shown_index == index then
        return
    end
    local range = self.ranges:get(index)
    if not range then
        self:_clear("unresolved")
        return
    end
    self.shown_index, self.current_range = index, range
    self.overlay:setRange(range.pos0, range.pos1)
    if self.on_range then
        self.on_range(range.pos0, range.pos1)
    end
end

function RemoteFollower:start()
    if self.closed then
        return nil, "Remote follower is closed"
    elseif self.running then
        return true
    end
    local called, ok, err = pcall(self.port.start, self.port)
    if not called or not ok then
        self.error = tostring(called and err or ok)
        self.port:close()
        return nil, self.error
    end
    self.error, self.running = nil, true
    self.generation = self.generation + 1
    local generation = self.generation
    self.poll_action = function()
        if not self.running or self.generation ~= generation then
            return
        end
        self:poll()
        if self.running and self.generation == generation then
            self.scheduler:scheduleIn(POLL_INTERVAL, self.poll_action)
        end
    end
    self.scheduler:scheduleIn(POLL_INTERVAL, self.poll_action)
    return true
end

function RemoteFollower:stop()
    self.running = false
    self.generation = self.generation + 1
    if self.poll_action then
        self.scheduler:unschedule(self.poll_action)
        self.poll_action = nil
    end
    self.port:close()
    self.peers, self.pending = {}, {}
    self.selected, self.latest, self.mismatch = nil, nil, nil
    self:_clear("stop")
    return true
end

function RemoteFollower:close()
    if not self.closed then
        self:stop()
        self.closed = true
    end
end

function RemoteFollower:getPeers()
    local result = {}
    local now = self.clock()
    for key, peer in pairs(self.peers) do
        result[#result + 1] = {
            key = key, host = peer.host, sender = peer.packet.senderID,
            book = peer.packet.bookID.uuid, matches = peer.index ~= nil,
            age = math.max(0, now - peer.received),
            text_path = peer.packet.textHref, text_fragment = peer.packet.textId,
        }
    end
    table.sort(result, function(left, right)
        if left.age == right.age then return left.key < right.key end
        return left.age < right.age
    end)
    return result
end

function RemoteFollower:selectPeer(key)
    local peer = self.peers[key]
    if not self.running or not peer or not peer.index then
        return nil, "No matching text from this phone/book. Open the same aligned EPUB on both devices."
    end
    self.selected, self.latest, self.pending = key, nil, {}
    self:_clear("source")
    self:_accept(peer)
    self:_update()
    return true
end

function RemoteFollower:_accept(peer)
    if not peer.index then
        self.latest, self.pending, self.mismatch = nil, {}, true
        self:_clear("mismatch")
        return
    end
    local previous = self.latest
    self.mismatch = false
    local clip = self.clips[peer.index]
    local prior = previous and self.clips[previous.index]
    -- Never use a seek, skipped/repeated target, chapter change, or changed rate
    -- as a reliable clock anchor. Two naturally spaced observations are needed.
    local adjacent = prior and peer.index == previous.index + 1
        and clip.audio_path == prior.audio_path and clip.spine_index == prior.spine_index
        and clip.clip_begin == prior.clip_end
    local prediction = false
    if adjacent and previous.unique and peer.unique
        and previous.packet.playbackRate == peer.packet.playbackRate then
        local expected = (prior.clip_end - prior.clip_begin) / previous.packet.playbackRate
        local elapsed = peer.received - previous.received
        prediction = math.abs(elapsed - expected) <= math.min(1, math.max(0.3, expected * 0.2))
    end
    if previous and not adjacent then
        self.pending = {}
        self:_clear("jump")
    end
    self.latest = peer
    self.predictable = prediction
    if #self.pending >= MAX_PENDING then self.pending = {} end
    self.pending[#self.pending + 1] = peer
end

function RemoteFollower:_receive(envelope)
    if type(envelope) ~= "table" or not text(envelope.host, 64) then return end
    local packet = envelope.packet
    local path = validate(packet)
    if not path then return end
    local key = packet_key(packet, envelope.host)
    local old = self.peers[key]
    -- Sender timestamps are used only for ordering within a session, never to
    -- subtract clocks on different devices. Restart after a sender clock reset.
    -- Order across books too: a delayed old-book packet must not undo a switch.
    for _, peer in pairs(self.peers) do
        if peer.host == envelope.host and peer.packet.senderID == packet.senderID
            and packet.sentAt <= peer.packet.sentAt then return end
    end
    if not old then
        local count, oldest_key, oldest_time = 0, nil, math.huge
        for candidate, peer in pairs(self.peers) do
            count = count + 1
            if candidate ~= self.selected and peer.received < oldest_time then
                oldest_key, oldest_time = candidate, peer.received
            end
        end
        if count >= MAX_PEERS then self.peers[oldest_key] = nil end
    end
    local matches = self.anchors[anchor_key(path, packet.textId)]
    local peer = { packet = packet, host = envelope.host, received = self.clock(),
        index = matches and matches[1], unique = matches and #matches == 1 }
    self.peers[key] = peer
    local selected = self.selected and self.peers[self.selected]
    if key == self.selected then
        self:_accept(peer)
    elseif selected and selected.host == peer.host
        and selected.packet.senderID == packet.senderID then
        -- The selected phone switched books; never follow another book merely
        -- because its publisher reused chapter names or fragment IDs.
        self.latest, self.pending, self.mismatch = nil, {}, true
        self:_clear("mismatch")
    end
end

function RemoteFollower:_update()
    local now = self.clock()
    local due
    while self.pending[1]
        and now >= self.pending[1].received + math.max(0, -self.correction) do
        due = table.remove(self.pending, 1)
    end
    if due then self:_show(due.index, false) end
    local latest = self.latest
    if not latest or self.correction <= 0 then return end
    local clip = self.clips[latest.index]
    local duration = (clip.clip_end - clip.clip_begin) / latest.packet.playbackRate
    local age = now - latest.received
    local next_clip = self.clips[latest.index + 1]
    -- At most ONE future target, in the same resource/chapter, for 750 ms past
    -- its expected boundary. Silence may be a pause: never free-run a book.
    if self.predictable and next_clip and age >= math.max(0, duration - self.correction)
        and age <= duration + 0.75 and next_clip.audio_path == clip.audio_path
        and next_clip.spine_index == clip.spine_index and next_clip.clip_begin == clip.clip_end
        and next_clip.text_fragment ~= clip.text_fragment
        and #self.anchors[anchor_key(next_clip.text_path, next_clip.text_fragment)] == 1 then
        self:_show(latest.index + 1, true)
    elseif self.estimated then
        self:_show(latest.index, false)
    end
end

function RemoteFollower:poll()
    if not self.running then return end
    local called, packets, err = pcall(self.port.poll, self.port)
    if not called or not packets then
        self:stop()
        self.error = tostring(called and err or packets)
        if self.on_error then self.on_error(self.error) end
        return
    end
    for index = 1, math.min(#packets, MAX_PENDING) do self:_receive(packets[index]) end
    self:_update()
end

function RemoteFollower:setCorrection(value)
    if not finite(value) or value < -5 or value > 2 then
        return nil, "Correction must be between 5 seconds later and 2 seconds earlier"
    end
    self.correction = value
    self.pending = self.latest and { self.latest } or {}
    if self.latest and self.estimated then self:_show(self.latest.index, false) end
    self:_update()
    if self.on_correction then self.on_correction(value) end
    return true
end

function RemoteFollower:getStatus()
    local latest = self.latest
    local age = latest and math.max(0, self.clock() - latest.received)
    local state = self.closed and "closed" or self.error and "error"
        or not self.running and "idle" or not self.selected and "listening"
        or self.mismatch and "mismatch" or "following"
    if latest then
        local clip = self.clips[latest.index]
        local duration = (clip.clip_end - clip.clip_begin) / latest.packet.playbackRate
        if age > math.max(5, duration + 2) then state = "waiting" end
    end
    local host, port = self.port:getAddress()
    local peer = self.selected and self.peers[self.selected]
    return { state = state, correction = self.correction, estimated = self.estimated == true,
        has_text_range = self.current_range ~= nil, age = age, error = self.error,
        host = host, port = port, peer_host = peer and peer.host,
        book = peer and peer.packet.bookID.uuid,
        rate = latest and latest.packet.playbackRate }
end

return RemoteFollower
