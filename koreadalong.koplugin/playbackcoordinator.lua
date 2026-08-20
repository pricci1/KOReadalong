local PlaybackCoordinator = {}
PlaybackCoordinator.__index = PlaybackCoordinator

PlaybackCoordinator.STATES = {
    IDLE = "idle",
    LOADING = "loading",
    PLAYING = "playing",
    PAUSED = "paused",
    ENDED = "ended",
    ERROR = "error",
    CLOSED = "closed",
}

local POLL_INTERVAL = 0.18

local function invoke(object, method_name, ...)
    local method = object and object[method_name]
    if type(method) ~= "function" then
        return nil, "dependency is missing " .. method_name
    end
    local ok, first, second = pcall(method, object, ...)
    if not ok then
        return nil, tostring(first)
    end
    return first, second
end

local function invoke_optional(object, method_name, ...)
    local method = object and object[method_name]
    if type(method) ~= "function" then
        return nil
    end
    pcall(method, object, ...)
end

local function resolve_fragment(resolver, document, clip, next_clip)
    local method = resolver and resolver.resolve
    if type(method) ~= "function" then
        return nil, "fragment resolver is missing resolve"
    end
    local ok, range, error_message = pcall(
        method,
        document,
        clip,
        next_clip
    )
    if not ok then
        return nil, tostring(range)
    end
    return range, error_message
end

local function same_resolver_context(left, right)
    return left and right
        and left.spine_index == right.spine_index
        and left.text_path == right.text_path
end

function PlaybackCoordinator.new(options)
    options = options or {}
    local clips = options.clips or {}
    local self = setmetatable({
        adapter = options.adapter,
        scheduler = options.scheduler,
        archive_reader = options.archive_reader,
        materializer = options.materializer,
        timeline = options.timeline,
        resolver = options.resolver,
        document = options.document,
        overlay = options.overlay,
        on_error = options.on_error,
        clips = clips,
        state = PlaybackCoordinator.STATES.IDLE,
        intent = nil,
        current_clip_index = nil,
        current_audio_path = nil,
        materialized_path = nil,
        range_cache = {},
        poll_scheduled = false,
        scheduled_generation = nil,
        generation = 0,
        closed = false,
        error = nil,
        poll_interval = options.poll_interval or POLL_INTERVAL,
    }, PlaybackCoordinator)

    self.clip_indexes = {}
    for index, clip in ipairs(clips) do
        self.clip_indexes[clip] = index
    end

    self.poll_action = function()
        local callback_generation = self.scheduled_generation
        self.poll_scheduled = false
        self.scheduled_generation = nil
        if self.closed or callback_generation ~= self.generation then
            return
        end
        self:_poll()
        if not self.closed and callback_generation == self.generation
            and (self.state == PlaybackCoordinator.STATES.LOADING
                or self.state == PlaybackCoordinator.STATES.PLAYING) then
            self:_schedule_poll()
        end
    end

    return self
end

function PlaybackCoordinator:getState()
    return self.state
end

function PlaybackCoordinator:getActionLabel()
    if self.state == PlaybackCoordinator.STATES.PLAYING then
        return "Pause"
    elseif self.state == PlaybackCoordinator.STATES.PAUSED then
        return "Resume"
    elseif self.state == PlaybackCoordinator.STATES.LOADING then
        return "Loading…"
    end
    return "Start"
end

function PlaybackCoordinator:isActionEnabled()
    return not self.closed and self.state ~= PlaybackCoordinator.STATES.LOADING
end

function PlaybackCoordinator:isStopEnabled()
    return not self.closed
        and self.state ~= PlaybackCoordinator.STATES.IDLE
        and self.state ~= PlaybackCoordinator.STATES.ENDED
end

function PlaybackCoordinator:_schedule_poll()
    if self.closed or self.poll_scheduled or not self.scheduler then
        return
    end
    self.poll_scheduled = true
    self.scheduled_generation = self.generation
    self.scheduler:scheduleIn(self.poll_interval, self.poll_action)
end

function PlaybackCoordinator:_unschedule_poll()
    if self.poll_scheduled and self.scheduler then
        self.scheduler:unschedule(self.poll_action)
    end
    self.poll_scheduled = false
    self.scheduled_generation = nil
end

function PlaybackCoordinator:_clear_overlay()
    invoke_optional(self.overlay, "clear")
end

function PlaybackCoordinator:_release_audio()
    -- MpvAudio stop/unload is deliberately issued before removing the owned
    -- file. The materializer refuses to remove paths it did not create.
    invoke_optional(self.adapter, "stop")
    self:_clear_overlay()
    if self.materialized_path then
        invoke_optional(self.materializer, "remove", self.materialized_path)
    end
    self.materialized_path = nil
    self.current_audio_path = nil
end

function PlaybackCoordinator:_report_error(error_message)
    self.error = tostring(error_message or "unknown read-along error")
    if type(self.on_error) == "function" then
        pcall(self.on_error, self.error)
    end
end

function PlaybackCoordinator:_fail(error_message)
    if self.closed then
        return nil, error_message
    end
    self.generation = self.generation + 1
    self:_unschedule_poll()
    self.intent = nil
    self.state = PlaybackCoordinator.STATES.ERROR
    self:_report_error(error_message)
    if self.materialized_path or self.current_audio_path then
        self:_release_audio()
    else
        self:_clear_overlay()
    end
    return nil, self.error
end

function PlaybackCoordinator:_next_clip(index)
    local next_clip = self.clips[index + 1]
    if same_resolver_context(self.clips[index], next_clip) then
        return next_clip
    end
    return nil
end

function PlaybackCoordinator:_resolve_range(index)
    local cached = self.range_cache[index]
    if cached == false then
        self:_clear_overlay()
        return nil
    end
    if cached then
        invoke_optional(self.overlay, "setRange", cached.pos0, cached.pos1)
        return cached
    end

    local clip = self.clips[index]
    local next_clip = self:_next_clip(index)
    local range, resolve_error = resolve_fragment(
        self.resolver,
        self.document,
        clip,
        next_clip
    )
    if type(range) ~= "table"
        or type(range.pos0) ~= "string"
        or type(range.pos1) ~= "string" then
        -- Fragment failures are expected for unsupported Storyteller targets
        -- and must not interrupt audio or produce repeated dialogs.
        self.range_cache[index] = false
        self:_clear_overlay()
        return nil, resolve_error
    end
    self.range_cache[index] = {
        pos0 = range.pos0,
        pos1 = range.pos1,
    }
    invoke_optional(self.overlay, "setRange", range.pos0, range.pos1)
    return self.range_cache[index]
end

function PlaybackCoordinator:_update_overlay(audio_path, position)
    if type(position) ~= "number" then
        return
    end
    local clip = self.timeline:lookup(audio_path, position)
    local index = clip and self.clip_indexes[clip]
    if not index then
        self:_clear_overlay()
        return
    end
    self.current_clip_index = index
    self:_resolve_range(index)
end

function PlaybackCoordinator:_prepare_resource(index)
    local clip = self.clips[index]
    if not clip then
        self.state = PlaybackCoordinator.STATES.ENDED
        self.intent = nil
        self:_unschedule_poll()
        self:_clear_overlay()
        return true
    end

    if self.materialized_path or self.current_audio_path then
        self:_release_audio()
    else
        self:_clear_overlay()
    end
    self.current_clip_index = index
    self.current_audio_path = clip.audio_path
    self.state = PlaybackCoordinator.STATES.LOADING

    local local_path, materialize_error = invoke(
        self.materializer,
        "materialize",
        clip.audio_path,
        self.archive_reader
    )
    if not local_path then
        return self:_fail(materialize_error or "unable to materialize audio")
    end
    self.materialized_path = local_path

    local loaded, load_error = invoke(self.adapter, "load", local_path)
    if not loaded then
        return self:_fail(load_error or "unable to load audio")
    end
    self:_schedule_poll()
    return true
end

function PlaybackCoordinator:_prepare_same_resource(index)
    local clip = self.clips[index]
    self.current_clip_index = index
    local seek_ok, seek_error = invoke(
        self.adapter,
        "seek",
        clip.clip_begin
    )
    if not seek_ok then
        return self:_fail(seek_error or "unable to seek audio")
    end
    local play_ok, play_error = invoke(self.adapter, "play")
    if not play_ok then
        return self:_fail(play_error or "unable to resume audio")
    end
    self.intent = PlaybackCoordinator.STATES.PLAYING
    self.state = PlaybackCoordinator.STATES.PLAYING
    self:_schedule_poll()
    return true
end

function PlaybackCoordinator:_advance()
    local current_index = self.current_clip_index or 0
    while self.clips[current_index + 1]
        and self.clips[current_index + 1].audio_path == self.current_audio_path do
        current_index = current_index + 1
    end
    self.current_clip_index = current_index
    local next_index = current_index + 1
    if not self.clips[next_index] then
        self.intent = nil
        self.state = PlaybackCoordinator.STATES.ENDED
        self:_unschedule_poll()
        self:_clear_overlay()
        return true
    end
    if self.current_audio_path == self.clips[next_index].audio_path
        and self.materialized_path then
        return self:_prepare_same_resource(next_index)
    end
    return self:_prepare_resource(next_index)
end

function PlaybackCoordinator:_finish_load(status)
    if status.state == "error" or status.state == "closed"
        or status.state == "ended" then
        return self:_fail(status.error or "audio ended before it became ready")
    end
    if status.state == "loading" or status.state == "startup" then
        return true
    end

    local clip = self.clips[self.current_clip_index]
    if clip.clip_begin > 0 then
        local seek_ok, seek_error = invoke(
            self.adapter,
            "seek",
            clip.clip_begin
        )
        if not seek_ok then
            return self:_fail(seek_error or "unable to seek audio")
        end
    end
    local command
    if self.intent == PlaybackCoordinator.STATES.PAUSED then
        command = "pause"
    else
        command = "play"
    end
    local resumed, resume_error = invoke(self.adapter, command)
    if not resumed then
        return self:_fail(resume_error or "unable to start audio")
    end
    self.state = self.intent == PlaybackCoordinator.STATES.PAUSED
        and PlaybackCoordinator.STATES.PAUSED
        or PlaybackCoordinator.STATES.PLAYING
    self:_update_overlay(self.current_audio_path, clip.clip_begin)
    return true
end

function PlaybackCoordinator:_poll()
    local status, status_error = invoke(self.adapter, "getStatus")
    if type(status) ~= "table" then
        self:_fail(status_error or "unable to read audio status")
        return
    end
    if status.state == "error" then
        self:_fail(status.error or "audio playback failed")
        return
    end
    if self.state == PlaybackCoordinator.STATES.LOADING then
        if not self:_finish_load(status) then
            return
        end
        if self.state == PlaybackCoordinator.STATES.PAUSED then
            return
        end
    end
    if status.state == "ended" then
        self:_advance()
        return
    end
    if self.state == PlaybackCoordinator.STATES.PLAYING then
        self:_update_overlay(self.current_audio_path, status.position)
    end
end

function PlaybackCoordinator:start()
    if self.closed then
        return nil, "read-along coordinator is closed"
    end
    if #self.clips == 0 then
        return nil, "this document has no media overlays"
    end
    if self.state == PlaybackCoordinator.STATES.PLAYING then
        return true
    end
    if self.state == PlaybackCoordinator.STATES.PAUSED then
        return self:resume()
    end
    if self.state == PlaybackCoordinator.STATES.LOADING then
        return nil, "audio is still loading"
    end
    self.error = nil
    self.intent = PlaybackCoordinator.STATES.PLAYING
    self.generation = self.generation + 1
    return self:_prepare_resource(1)
end

function PlaybackCoordinator:pause()
    if self.closed or self.state ~= PlaybackCoordinator.STATES.PLAYING then
        return nil, "read-along is not playing"
    end
    local paused, pause_error = invoke(self.adapter, "pause")
    if not paused then
        return self:_fail(pause_error or "unable to pause audio")
    end
    self.state = PlaybackCoordinator.STATES.PAUSED
    self.intent = PlaybackCoordinator.STATES.PAUSED
    self:_unschedule_poll()
    return true
end

function PlaybackCoordinator:resume()
    if self.closed or self.state ~= PlaybackCoordinator.STATES.PAUSED then
        return nil, "read-along is not paused"
    end
    local resumed, resume_error = invoke(self.adapter, "resume")
    if not resumed then
        return self:_fail(resume_error or "unable to resume audio")
    end
    self.state = PlaybackCoordinator.STATES.PLAYING
    self.intent = PlaybackCoordinator.STATES.PLAYING
    self:_schedule_poll()
    return true
end

function PlaybackCoordinator:toggle()
    if self.state == PlaybackCoordinator.STATES.PLAYING then
        return self:pause()
    elseif self.state == PlaybackCoordinator.STATES.PAUSED then
        return self:resume()
    end
    return self:start()
end

function PlaybackCoordinator:stop()
    if self.closed then
        return true
    end
    self.generation = self.generation + 1
    self:_unschedule_poll()
    self.intent = nil
    self.state = PlaybackCoordinator.STATES.IDLE
    self:_release_audio()
    self.current_clip_index = nil
    self.error = nil
    return true
end

function PlaybackCoordinator:close()
    if self.closed then
        return true
    end
    -- Invalidate first: callbacks already dequeued by UIManager must become
    -- no-ops and must never schedule themselves again.
    self.generation = self.generation + 1
    self.closed = true
    self:_unschedule_poll()
    invoke_optional(self.adapter, "stop")
    invoke_optional(self.adapter, "close")
    self:_clear_overlay()
    invoke_optional(self.overlay, "deactivate")
    invoke_optional(self.materializer, "cleanup")
    self.materialized_path = nil
    self.current_audio_path = nil
    self.intent = nil
    self.state = PlaybackCoordinator.STATES.CLOSED
    return true
end

return PlaybackCoordinator
