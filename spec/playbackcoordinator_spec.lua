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
        duration = nil,
        paused = false,
        loads = {},
        commands = {},
        seeks = {},
        plays = 0,
        pauses = 0,
        resumes = 0,
        stops = 0,
        closes = 0,
        fail_load = nil,
        fail_resume = nil,
        fail_stop = nil,
        stop_waits = false,
    }
    function adapter:load(path)
        self.loads[#self.loads + 1] = path
        self.commands[#self.commands + 1] = "load"
        if self.fail_load then
            return nil, self.fail_load
        end
        self.state = "loading"
        self.duration = nil
        self.paused = false
        return true
    end
    function adapter:seek(position)
        self.commands[#self.commands + 1] = "seek"
        self.seeks[#self.seeks + 1] = position
        self.position = position
        return true
    end
    function adapter:play()
        self.commands[#self.commands + 1] = "play"
        self.plays = self.plays + 1
        self.state = "playing"
        self.paused = false
        return true
    end
    function adapter:pause()
        self.commands[#self.commands + 1] = "pause"
        self.pauses = self.pauses + 1
        self.paused = true
        if not self.stop_waits then
            self.state = "paused"
        end
        return true
    end
    function adapter:resume()
        self.commands[#self.commands + 1] = "resume"
        self.resumes = self.resumes + 1
        if self.fail_resume then
            return nil, self.fail_resume
        end
        self.state = "playing"
        self.paused = false
        return true
    end
    function adapter:stop()
        self.commands[#self.commands + 1] = "stop"
        self.stops = self.stops + 1
        if self.fail_stop then
            return nil, self.fail_stop
        end
        if not self.stop_waits then
            self.state = "idle"
        end
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
            duration = self.duration,
            paused = self.paused,
            error = self.error,
        }
    end
    return adapter
end

local function make_materializer()
    local materializer = {
        paths = {},
        owned = {},
        removed = {},
        cleaned = 0,
        fail_remove = false,
        fail_cleanup = false,
    }
    function materializer:materialize(audio_path, reader)
        local bytes = reader(audio_path)
        if not bytes then
            return nil, "archive read failed"
        end
        local path = "/private/" .. audio_path
        self.paths[#self.paths + 1] = path
        self.owned[path] = true
        return path
    end
    function materializer:remove(path)
        self.removed[#self.removed + 1] = path
        if self.fail_remove then
            return nil, "remove failed"
        end
        self.owned[path] = nil
        return true
    end
    function materializer:cleanup()
        self.cleaned = self.cleaned + 1
        if self.fail_cleanup then
            return nil, "cleanup failed"
        end
        return true
    end
    return materializer
end

local function mark_ready(adapter)
    adapter.duration = 2
    adapter.paused = true
    adapter.state = "paused"
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
    local ranges_shown = {}
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
        on_range = function(pos0, pos1)
            ranges_shown[#ranges_shown + 1] = { pos0, pos1 }
        end,
        on_error = function(error_message)
            errors[#errors + 1] = error_message
        end,
    }
    return coordinator, scheduler, adapter, materializer, resolver, overlay, errors,
        ranges_shown
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
            text_path = "book/next-chapter.xhtml",
            text_fragment = "three",
            spine_index = 1,
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
        mark_ready(adapter)
        scheduler:fire_any()
        assert.are.equal("playing", coordinator:getState())
        assert.are.equal(1, adapter.plays)
        assert.are.same({}, adapter.seeks)
        assert.are.equal(1, #resolver.calls)
        assert.are.equal("two", resolver.calls[1].next_clip.text_fragment)
    end)

    it("rejects stop during loading and closes the unresolved session safely", function()
        local coordinator, scheduler, adapter, materializer =
            make_fixture(clips_fixture())
        assert.is_true(coordinator:start())
        assert.are.equal("loading", coordinator:getState())
        assert.is_false(coordinator:isStopEnabled())

        local stopped, stop_error = coordinator:stop()
        assert.is_nil(stopped)
        assert.matches("still loading", stop_error)
        assert.are.equal("loading", coordinator:getState())
        assert.are.equal(0, adapter.stops)
        assert.is_not_nil(scheduler.tasks[coordinator.poll_action])

        assert.is_true(coordinator:close())
        assert.are.equal("closed", coordinator:getState())
        assert.are.equal(0, adapter.stops)
        assert.are.equal(1, adapter.closes)
        assert.are.equal(1, materializer.cleaned)
        assert.is_nil(scheduler.tasks[coordinator.poll_action])

        assert.is_true(coordinator:close())
        assert.are.equal(1, adapter.closes)
        assert.are.equal(1, materializer.cleaned)
        assert.is_nil(scheduler.tasks[coordinator.poll_action])
    end)

    it("moves through same-resource clips, clears gaps, and caches ranges", function()
        local coordinator, scheduler, adapter, _, resolver, overlay, _, ranges_shown =
            make_fixture(clips_fixture())
        coordinator:start()
        mark_ready(adapter)
        scheduler:fire_any()

        adapter.position = 0.4
        scheduler:fire_any()
        assert.are.equal("pos0-one", overlay.ranges[#overlay.ranges][1])
        local calls_after_one = #resolver.calls

        adapter.position = 1.4
        scheduler:fire_any()
        assert.are.equal("pos0-two", overlay.ranges[#overlay.ranges][1])
        assert.are.same({ "pos0-two", "pos1-two" }, ranges_shown[#ranges_shown])
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
        mark_ready(adapter)
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

    it("hands off to the next chapter only after asynchronous stop acknowledgement", function()
        local coordinator, scheduler, adapter, materializer, _, _, _, ranges_shown =
            make_fixture(clips_fixture())
        coordinator:start()
        mark_ready(adapter)
        scheduler:fire_any()
        adapter.stop_waits = true
        adapter.state = "ended"
        adapter.position = 2
        scheduler:fire_any()
        assert.are.equal("stopping", coordinator:getState())
        assert.are.equal(1, #adapter.loads)
        assert.are.equal(0, #materializer.removed)
        scheduler:fire_any()
        assert.are.equal(1, #adapter.loads)
        assert.are.equal(0, #materializer.removed)

        adapter.stop_waits = false
        adapter.state = "idle"
        scheduler:fire_any()
        assert.are.equal(2, #adapter.loads)
        assert.are.equal("book/second.wav", materializer.paths[2]:match("book/second%.wav$"))
        assert.are.equal(1, #materializer.removed)
        assert.are.equal("loading", coordinator:getState())
        mark_ready(adapter)
        scheduler:fire_any()
        assert.are.equal(2, #adapter.loads)
        assert.are.equal(2, adapter.plays)
        assert.are.same({ "pos0-three", "pos1-three" }, ranges_shown[#ranges_shown])
    end)

    it("ends cleanly after the final ordered clip", function()
        local clips = clips_fixture()
        clips[2] = nil
        clips[3] = nil
        local coordinator, scheduler, adapter, materializer, _, overlay = make_fixture(clips)
        coordinator:start()
        mark_ready(adapter)
        scheduler:fire_any()
        adapter.state = "ended"
        scheduler:fire_any()
        assert.are.equal("stopping", coordinator:getState())
        assert.are.equal(1, adapter.stops)
        assert.are.equal(0, #materializer.removed)
        adapter.state = "idle"
        scheduler:fire_any()
        assert.are.equal("ended", coordinator:getState())
        assert.are.equal(0, scheduler.tasks[coordinator.poll_action] or 0)
        assert.are.equal(1, #materializer.removed)
        assert.is_nil(coordinator.materialized_path)
        assert.is_nil(next(materializer.owned))
        assert.is_true(overlay.clears > 0)
    end)

    it("pauses immediately after load and waits for duration before seeking or playing", function()
        local clips = clips_fixture()
        clips[2] = nil
        clips[3] = nil
        clips[1].clip_begin = 0.25
        local coordinator, scheduler, adapter = make_fixture(clips)
        assert.is_true(coordinator:start())
        assert.are.same({ "load", "pause" }, adapter.commands)

        scheduler:fire_any()
        assert.are.equal(0, #adapter.seeks)
        assert.are.equal(0, adapter.plays)
        assert.are.equal("loading", coordinator:getState())

        mark_ready(adapter)
        scheduler:fire_any()
        assert.are.same({ "load", "pause", "seek", "play" }, adapter.commands)
        assert.are.equal(0.25, adapter.seeks[1])
        assert.are.equal(1, adapter.plays)
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
        mark_ready(adapter)
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
        mark_ready(adapter)
        scheduler:fire_any()
        assert.is_true(coordinator:stop())
        assert.are.equal("stopping", coordinator:getState())
        assert.are.equal(0, #materializer.removed)
        scheduler:fire_any()
        assert.are.equal("idle", coordinator:getState())
        assert.are.equal(1, #materializer.removed)
        assert.is_true(overlay.clears > 0)
        assert.are.equal(0, scheduler.tasks[coordinator.poll_action] or 0)
    end)

    it("surfaces adapter status errors and disables terminal error controls", function()
        local coordinator, scheduler, adapter, _, _, _, errors =
            make_fixture(clips_fixture())
        assert.is_true(coordinator:start())
        adapter.error = "decoder disconnected"
        adapter.state = "error"
        scheduler:fire_any()
        assert.are.equal("error", coordinator:getState())
        assert.matches("decoder disconnected", errors[1])
        assert.is_false(coordinator:isActionEnabled())
        assert.is_false(coordinator:isStopEnabled())
        local retry_ok, retry_error = coordinator:start()
        assert.is_nil(retry_ok)
        assert.matches("reopen the document", retry_error)
    end)

    it("surfaces transition cleanup errors without claiming the resource is gone", function()
        local clips = clips_fixture()
        clips[2] = nil
        clips[3] = nil
        local coordinator, scheduler, adapter, materializer, _, _, errors =
            make_fixture(clips)
        assert.is_true(coordinator:start())
        mark_ready(adapter)
        scheduler:fire_any()
        materializer.fail_remove = true
        adapter.state = "ended"
        scheduler:fire_any()
        adapter.state = "idle"
        scheduler:fire_any()
        assert.are.equal("error", coordinator:getState())
        assert.matches("remove failed", errors[1])
        assert.is_not_nil(coordinator.materialized_path)
        assert.is_true(next(materializer.owned) ~= nil)
    end)

    it("keeps coordinator ownership visible when close cleanup fails", function()
        local coordinator, scheduler, adapter, materializer =
            make_fixture(clips_fixture())
        assert.is_true(coordinator:start())
        mark_ready(adapter)
        scheduler:fire_any()
        materializer.fail_cleanup = true
        assert.is_true(coordinator:close())
        assert.are.equal("closed", coordinator:getState())
        assert.is_not_nil(coordinator.materialized_path)
        assert.matches("cleanup failed", coordinator.cleanup_error)

        materializer.fail_cleanup = false
        assert.is_true(coordinator:close())
        assert.are.equal(2, materializer.cleaned)
        assert.is_nil(coordinator.materialized_path)
        assert.is_nil(coordinator.cleanup_error)
    end)
end)
