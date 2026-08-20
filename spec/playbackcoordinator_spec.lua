package.path = "./koreadalong.koplugin/?.lua;" .. package.path

local PlaybackCoordinator = require("playbackcoordinator")
local Timeline = require("timeline")

local function make_scheduler()
    local scheduler = {
        tasks = {},
        schedules = 0,
        unschedules = 0,
    }
    function scheduler:scheduleIn(delay, action)
        self.tasks[action] = delay
        self.schedules = self.schedules + 1
    end
    function scheduler:unschedule(action)
        if self.tasks[action] then
            self.tasks[action] = nil
            self.unschedules = self.unschedules + 1
        end
    end
    function scheduler:fire(action)
        if self.tasks[action] then
            self.tasks[action] = nil
            action()
        end
    end
    function scheduler:fire_any()
        local action = next(self.tasks)
        if action then
            self:fire(action)
        end
    end
    return scheduler
end

local function make_adapter()
    local adapter = {
        state = "idle",
        position = 0,
        loads = {},
        seeks = {},
        plays = 0,
        pauses = 0,
        resumes = 0,
        stops = 0,
        closes = 0,
        fail_load = nil,
        fail_resume = nil,
    }
    function adapter:load(path)
        self.loads[#self.loads + 1] = path
        if self.fail_load then
            return nil, self.fail_load
        end
        self.state = "loading"
        return true
    end
    function adapter:seek(position)
        self.seeks[#self.seeks + 1] = position
        self.position = position
        return true
    end
    function adapter:play()
        self.plays = self.plays + 1
        self.state = "playing"
        return true
    end
    function adapter:pause()
        self.pauses = self.pauses + 1
        self.state = "paused"
        return true
    end
    function adapter:resume()
        self.resumes = self.resumes + 1
        if self.fail_resume then
            return nil, self.fail_resume
        end
        self.state = "playing"
        return true
    end
    function adapter:stop()
        self.stops = self.stops + 1
        self.state = "idle"
        return true
    end
    function adapter:close()
        self.closes = self.closes + 1
        self.state = "closed"
        return true
    end
    function adapter:getStatus()
        return {
            state = self.state,
            position = self.position,
            error = self.error,
        }
    end
    return adapter
end

local function make_materializer()
    local materializer = {
        paths = {},
        removed = {},
        cleaned = 0,
    }
    function materializer:materialize(audio_path, reader)
        local bytes = reader(audio_path)
        if not bytes then
            return nil, "archive read failed"
        end
        local path = "/private/" .. audio_path
        self.paths[#self.paths + 1] = path
        return path
    end
    function materializer:remove(path)
        self.removed[#self.removed + 1] = path
        return true
    end
    function materializer:cleanup()
        self.cleaned = self.cleaned + 1
        return true
    end
    return materializer
end

local function make_overlay()
    local overlay = {
        ranges = {},
        clears = 0,
        deactivates = 0,
    }
    function overlay:setRange(pos0, pos1)
        self.ranges[#self.ranges + 1] = { pos0, pos1 }
    end
    function overlay:clear()
        self.clears = self.clears + 1
    end
    function overlay:deactivate()
        self.deactivates = self.deactivates + 1
    end
    return overlay
end

local function make_fixture(clips)
    local scheduler = make_scheduler()
    local adapter = make_adapter()
    local materializer = make_materializer()
    local overlay = make_overlay()
    local resolver = {
        calls = {},
        fail = {},
    }
    function resolver.resolve(_, clip, next_clip)
        resolver.calls[#resolver.calls + 1] = {
            clip = clip,
            next_clip = next_clip,
        }
        if resolver.fail[clip.text_fragment] then
            return nil, "unsupported fragment"
        end
        return {
            pos0 = "pos0-" .. clip.text_fragment,
            pos1 = "pos1-" .. clip.text_fragment,
        }
    end
    local timeline = assert(Timeline.new(clips))
    local errors = {}
    local coordinator = PlaybackCoordinator.new{
        adapter = adapter,
        scheduler = scheduler,
        archive_reader = function()
            return "\0binary\255"
        end,
        materializer = materializer,
        timeline = timeline,
        resolver = resolver,
        document = {},
        overlay = overlay,
        clips = clips,
        on_error = function(error_message)
            errors[#errors + 1] = error_message
        end,
    }
    return coordinator, scheduler, adapter, materializer, resolver, overlay, errors
end

local function clips_fixture()
    return {
        {
            text_path = "book/chapter.xhtml",
            text_fragment = "one",
            spine_index = 0,
            audio_path = "book/first.wav",
            clip_begin = 0,
            clip_end = 1,
        },
        {
            text_path = "book/chapter.xhtml",
            text_fragment = "two",
            spine_index = 0,
            audio_path = "book/first.wav",
            clip_begin = 1,
            clip_end = 2,
        },
        {
            text_path = "book/chapter.xhtml",
            text_fragment = "three",
            spine_index = 0,
            audio_path = "book/second.wav",
            clip_begin = 0.25,
            clip_end = 1,
        },
    }
end

describe("playback coordinator", function()
    it("does not touch dependencies for a document without overlays", function()
        local scheduler = make_scheduler()
        local adapter = make_adapter()
        local coordinator = PlaybackCoordinator.new{
            clips = {},
            scheduler = scheduler,
            adapter = adapter,
        }
        local ok, error_message = coordinator:start()
        assert.is_nil(ok)
        assert.matches("no media overlays", error_message)
        assert.are.equal(0, #adapter.loads)
        assert.are.equal(0, scheduler.schedules)
    end)

    it("loads only after start, waits for readiness, seeks, and plays", function()
        local coordinator, scheduler, adapter, materializer, resolver =
            make_fixture(clips_fixture())
        assert.is_true(coordinator:start())
        assert.are.equal("loading", coordinator:getState())
        assert.are.equal(1, #materializer.paths)
        assert.are.equal(1, #adapter.loads)
        assert.are.equal(0, adapter.plays)

        scheduler:fire_any()
        assert.are.equal(0, adapter.plays)
        adapter.state = "idle"
        scheduler:fire_any()
        assert.are.equal("playing", coordinator:getState())
        assert.are.equal(1, adapter.plays)
        assert.are.same({}, adapter.seeks)
        assert.are.equal(1, #resolver.calls)
        assert.are.equal("two", resolver.calls[1].next_clip.text_fragment)
    end)

    it("moves through same-resource clips, clears gaps, and caches ranges", function()
        local coordinator, scheduler, adapter, _, resolver, overlay =
            make_fixture(clips_fixture())
        coordinator:start()
        adapter.state = "idle"
        scheduler:fire_any()

        adapter.position = 0.4
        scheduler:fire_any()
        assert.are.equal("pos0-one", overlay.ranges[#overlay.ranges][1])
        local calls_after_one = #resolver.calls

        adapter.position = 1.4
        scheduler:fire_any()
        assert.are.equal("pos0-two", overlay.ranges[#overlay.ranges][1])
        assert.are.equal(calls_after_one + 1, #resolver.calls)

        adapter.position = 2.1
        scheduler:fire_any()
        assert.is_true(overlay.clears > 0)
        adapter.position = 1.4
        scheduler:fire_any()
        assert.are.equal(calls_after_one + 1, #resolver.calls)
    end)

    it("preserves the range across pause and resumes polling only after success", function()
        local coordinator, scheduler, adapter, _, _, overlay =
            make_fixture(clips_fixture())
        coordinator:start()
        adapter.state = "idle"
        scheduler:fire_any()
        adapter.position = 0.4
        scheduler:fire_any()
        local ranges = #overlay.ranges
        assert.is_true(coordinator:pause())
        assert.are.equal("paused", coordinator:getState())
        assert.are.equal(ranges, #overlay.ranges)
        assert.are.equal(0, scheduler.tasks[coordinator.poll_action] or 0)

        adapter.fail_resume = "resume failed"
        local ok = coordinator:resume()
        assert.is_nil(ok)
        assert.are.equal("error", coordinator:getState())
        assert.are.equal(0, scheduler.tasks[coordinator.poll_action] or 0)
    end)

    it("hands off resources at EOF without overlapping loads", function()
        local coordinator, scheduler, adapter, materializer =
            make_fixture(clips_fixture())
        coordinator:start()
        adapter.state = "idle"
        scheduler:fire_any()
        adapter.state = "ended"
        adapter.position = 2
        scheduler:fire_any()
        assert.are.equal(2, #adapter.loads)
        assert.are.equal("book/second.wav", materializer.paths[2]:match("book/second%.wav$"))
        assert.are.equal(1, #materializer.removed)
        assert.are.equal("loading", coordinator:getState())
        adapter.state = "idle"
        scheduler:fire_any()
        assert.are.equal(2, #adapter.loads)
        assert.are.equal(2, adapter.plays)
    end)

    it("ends cleanly after the final ordered clip", function()
        local clips = clips_fixture()
        clips[2] = nil
        clips[3] = nil
        local coordinator, scheduler, adapter, _, _, overlay = make_fixture(clips)
        coordinator:start()
        adapter.state = "idle"
        scheduler:fire_any()
        adapter.state = "ended"
        scheduler:fire_any()
        assert.are.equal("ended", coordinator:getState())
        assert.are.equal(0, scheduler.tasks[coordinator.poll_action] or 0)
        assert.is_true(overlay.clears > 0)
    end)

    it("fails explicit extraction and adapter load errors", function()
        local coordinator, _, _, materializer, _, _, errors =
            make_fixture(clips_fixture())
        function materializer:materialize()
            return nil, "read failed"
        end
        assert.is_nil(coordinator:start())
        assert.are.equal("error", coordinator:getState())
        assert.matches("read failed", errors[1])

        local second_coordinator, _, second_adapter, second_materializer, _, _, second_errors =
            make_fixture(clips_fixture())
        second_adapter.fail_load = "decoder failed"
        assert.is_nil(second_coordinator:start())
        assert.are.equal("error", second_coordinator:getState())
        assert.matches("decoder failed", second_errors[1])
        assert.are.equal(1, second_adapter.stops)
        assert.are.equal(1, #second_materializer.removed)
    end)

    it("silently caches unsupported fragment failures and closes stale callbacks", function()
        local coordinator, scheduler, adapter, materializer, resolver, overlay =
            make_fixture(clips_fixture())
        resolver.fail.one = true
        coordinator:start()
        adapter.state = "idle"
        scheduler:fire_any()
        adapter.position = 0.5
        scheduler:fire_any()
        adapter.position = 0.6
        scheduler:fire_any()
        assert.are.equal(1, #resolver.calls)
        assert.are.equal(0, #overlay.ranges)

        local stale_callback = coordinator.poll_action
        assert.is_true(coordinator:close())
        assert.is_true(coordinator:close())
        stale_callback()
        assert.are.equal("closed", coordinator:getState())
        assert.are.equal(1, materializer.cleaned)
        assert.are.equal(1, adapter.closes)
        assert.are.equal(0, scheduler.tasks[coordinator.poll_action] or 0)
    end)

    it("stop removes the current materialized resource and clears the range", function()
        local coordinator, scheduler, adapter, materializer, _, overlay =
            make_fixture(clips_fixture())
        coordinator:start()
        adapter.state = "idle"
        scheduler:fire_any()
        assert.is_true(coordinator:stop())
        assert.are.equal("idle", coordinator:getState())
        assert.are.equal(1, #materializer.removed)
        assert.is_true(overlay.clears > 0)
        assert.are.equal(0, scheduler.tasks[coordinator.poll_action] or 0)
    end)
end)
