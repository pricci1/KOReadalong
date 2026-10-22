package.path = "./koreadalong.koplugin/?.lua;" .. package.path

local RemoteFollower = require("remotefollower")
local NarrationRanges = require("narrationranges")

describe("read-only remote narration", function()
    local follower, port, now, scheduler, painted, clips, saved

    local function packet(id, timestamp, options)
        options = options or {}
        return { host = options.host or "192.0.2.10", port = 12345, packet = {
            version = 1, senderID = options.sender or "phone",
            bookID = { sourceID = "phone-library", uuid = options.book or "chosen-book" },
            sectionIndex = options.section or 99, entryIndex = 999,
            textHref = options.path or "book/chapter.xhtml", textId = id,
            playbackRate = options.rate or 1.5, sentAt = timestamp,
        } }
    end

    local function receive(envelope, at)
        now = at or now
        port.queue[#port.queue + 1] = envelope
        follower:poll()
    end

    local function choose()
        assert(follower:selectPeer(follower:getPeers()[1].key))
    end

    local function at(time)
        now = time
        follower:poll()
    end

    before_each(function()
        now, painted, saved = 100, nil, nil
        clips = {
            { text_path = "book/chapter.xhtml", text_fragment = "a", spine_index = 3,
                audio_path = "audio/one", clip_begin = 0, clip_end = 3 },
            { text_path = "book/chapter.xhtml", text_fragment = "b", spine_index = 3,
                audio_path = "audio/one", clip_begin = 3, clip_end = 7.5 },
            { text_path = "book/chapter.xhtml", text_fragment = "c", spine_index = 3,
                audio_path = "audio/one", clip_begin = 7.5, clip_end = 9 },
            { text_path = "book/next.xhtml", text_fragment = "d", spine_index = 5,
                audio_path = "audio/two", clip_begin = 0, clip_end = 2 },
        }
        port = { queue = {}, opened = false }
        function port:start() self.opened = true; return true end
        function port:poll()
            if self.failure then return nil, self.failure end
            local batch = self.queue
            self.queue = {}
            return batch
        end
        function port:getAddress() if self.opened then return "192.0.2.20", 4321 end end
        function port:close() self.opened = false end
        scheduler = { tasks = {} }
        function scheduler:scheduleIn(delay, action) self.tasks[action] = delay end
        function scheduler:unschedule(action) self.tasks[action] = nil end
        follower = RemoteFollower.new{
            port = port, scheduler = scheduler, clock = function() return now end,
            clips = clips, ranges = NarrationRanges.new{
                clips = clips, document = {}, resolver = { resolve = function(_, clip)
                    return { pos0 = clip.text_fragment, pos1 = clip.text_fragment .. "-end" }
                end },
            },
            overlay = {
                setRange = function(_, pos0) painted = pos0 end,
                clear = function() painted = nil end,
            },
            on_correction = function(value) saved = value end,
        }
        assert(follower:start())
    end)

    after_each(function() follower:close() end)

    it("requires explicit book selection and uses text anchors, not foreign entry indexes", function()
        receive(packet("a", 9000))
        assert.is_nil(painted)
        assert.are.equal("listening", follower:getStatus().state)
        choose()
        assert.are.equal("a", painted)
        assert.are.same({ pos0 = "a", pos1 = "a-end" }, follower:getCurrentRange())
        receive(packet("b", 9001, { sender = "other-phone" }))
        assert.are.equal("a", painted)
        receive(packet("d", 9002, { path = "book/next.xhtml" }))
        assert.are.equal("d", painted)
        receive(packet("a", 9003, { book = "different-book" }))
        assert.is_nil(painted)
        assert.are.equal("mismatch", follower:getStatus().state)
        receive(packet("c", 9002.5)) -- delayed packet from the old book
        assert.is_nil(painted)
        receive(packet("b", 9004))
        assert.are.equal("b", painted)
        receive(packet("unknown-anchor", 9005))
        assert.is_nil(painted)
        assert.are.equal("mismatch", follower:getStatus().state)
        receive(packet("c", 9006))
        assert.are.equal("c", painted)
    end)

    it("rejects malformed, duplicate and out-of-order packets without trusting wall-clock offsets", function()
        receive(packet("a", 9000)); choose()
        for _, change in ipairs{
            { "version", 2 }, { "sentAt", 0/0 }, { "playbackRate", math.huge },
            { "textHref", "../../book/chapter.xhtml" }, { "textId", "a\0evil" },
            { "entryIndex", -1 }, { "bookID", "wrong type" },
        } do
            local invalid = packet("b", 9001)
            invalid.packet[change[1]] = change[2]
            receive(invalid)
            assert.are.equal("a", painted)
        end
        receive(packet("b", 8999)); receive(packet("b", 9000))
        assert.are.equal("a", painted)
        receive(packet("b", 9001), 101)
        assert.are.equal("b", painted)
        assert.are.equal(0, follower:getStatus().age)
        assert.is_false(follower:getStatus().estimated)
    end)

    it("delays by local receipt time, cancels old seeks, and resets correction without changing phone speed", function()
        assert(follower:setCorrection(-0.75))
        receive(packet("a", 8000000)); choose()
        assert.is_nil(painted)
        at(100.74); assert.is_nil(painted)
        at(100.75); assert.are.equal("a", painted)
        receive(packet("b", 8000001), 102)
        assert(follower:setCorrection(-1))
        assert.are.equal("a", painted)
        receive(packet("d", 8000002, { path = "book/next.xhtml" }), 102.25)
        assert.is_nil(painted)
        at(103.1); assert.is_nil(painted)
        at(103.25); assert.are.equal("d", painted)
        receive(packet("c", 8000003), 104)
        assert(follower:setCorrection(0))
        assert.are.equal("c", painted)
        assert.are.equal(0, saved)
        assert.are.equal(1.5, follower:getStatus().rate)
        assert.is_nil(follower:setCorrection(2.25))
        assert.is_nil(follower:setCorrection(-5.25))
    end)

    it("predicts only one adjacent target after steady observations and retracts on silence", function()
        assert(follower:setCorrection(0.5))
        receive(packet("a", 10000)); choose()
        at(101.75); assert.are.equal("a", painted) -- first observation might be a seek
        receive(packet("b", 10002), 102) -- 3 media seconds at 1.5x = 2 real seconds
        at(104.49); assert.are.equal("b", painted)
        at(104.5); assert.are.equal("c", painted)
        assert.is_true(follower:getStatus().estimated)
        at(105.76); assert.are.equal("b", painted)
        assert.is_false(follower:getStatus().estimated)
        at(110); assert.are.equal("waiting", follower:getStatus().state)
        assert.are.equal("b", painted) -- no invented pause/EOF and no free-running clock
        receive(packet("c", 10011), 111)
        at(111.9); assert.are.equal("c", painted) -- never predict into the next chapter
    end)

    it("does not predict after a rate change or a repeated report of the same target", function()
        assert(follower:setCorrection(1))
        receive(packet("a", 2000)); choose()
        receive(packet("b", 2002, { rate = 2 }), 102)
        at(104); assert.are.equal("b", painted)
        assert.is_false(follower:getStatus().estimated)
        -- Repeating the last reported target must reset rather than assume a new clock epoch.
        receive(packet("b", 2003), 104.1)
        at(106.5); assert.are.equal("b", painted)
    end)

    it("follows repeated SMIL targets but never infers their audio interval", function()
        follower:close()
        clips[3].text_fragment = "b"
        follower = RemoteFollower.new{
            port = port, scheduler = scheduler, clock = function() return now end,
            clips = clips, ranges = follower.ranges, overlay = follower.overlay,
            correction = 1,
        }
        assert(follower:start())
        receive(packet("a", 2000)); choose()
        receive(packet("b", 2002), 102)
        at(104); assert.are.equal("b", painted)
        assert.is_false(follower:getStatus().estimated)
        receive(packet("b", 2005), 105)
        at(105.9); assert.are.equal("b", painted)
        assert.is_false(follower:getStatus().estimated)
    end)

    it("bounds candidate memory, keeps the selected source, and closes/restarts without stale callbacks", function()
        receive(packet("a", 3000)); choose()
        for i = 1, 40 do receive(packet("b", 3000 + i, { sender = "other-" .. i }), 100 + i) end
        assert.are.equal(16, #follower:getPeers())
        receive(packet("c", 4000)); assert.are.equal("c", painted)
        local stale = next(scheduler.tasks)
        follower:stop()
        assert.is_nil(painted)
        assert.is_nil(next(scheduler.tasks))
        assert.is_nil(follower:getStatus().host)
        assert(follower:start())
        stale()
        assert.are.equal("listening", follower:getStatus().state)
        port.failure = "network lost"
        follower:poll()
        assert.are.equal("error", follower:getStatus().state)
        assert.are.equal("network lost", follower:getStatus().error)
        port.failure = nil
        assert(follower:start())
        receive(packet("a", 1)); choose() -- new sender clock accepted after restart
        assert.are.equal("a", painted)
        follower:close()
        assert.is_nil(follower:start())
        assert.are.equal("closed", follower:getStatus().state)
    end)
end)
