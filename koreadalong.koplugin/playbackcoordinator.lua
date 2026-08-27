local PlaybackCoordinator = {}
PlaybackCoordinator.__index = PlaybackCoordinator

PlaybackCoordinator.STATES = {
    IDLE = "idle",
    LOADING = "loading",
    STOPPING = "stopping",
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

local function valid_xpointer(pointer)
    return type(pointer) == "string" and pointer ~= ""
end

local function compare_xpointers(document, left, right)
    local compared, compare_error = invoke(
        document,
        "compareXPointers",
        left,
        right
    )
    if type(compared) ~= "number"
        or (compared ~= -1 and compared ~= 0 and compared ~= 1) then
        return nil, compare_error or "unable to compare XPointers"
    end
    return compared
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
        on_range = options.on_range,
        on_error = options.on_error,
        clips = clips,
        state = PlaybackCoordinator.STATES.IDLE,
        intent = nil,
        current_clip_index = nil,
        current_audio_path = nil,
        materialized_path = nil,
        playback_position = nil,
        playback_duration = nil,
        range_cache = {},
        poll_scheduled = false,
        scheduled_generation = nil,
        generation = 0,
        closed = false,
        error = nil,
        cleanup_error = nil,
        transition = nil,
        stop_issued = false,
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
                or self.state == PlaybackCoordinator.STATES.STOPPING
                or self.state == PlaybackCoordinator.STATES.PLAYING) then
            self:_schedule_poll()
        end
    end

    return self
end

function PlaybackCoordinator:getState()
    return self.state
end

function PlaybackCoordinator:getPlaybackStatus()
    return {
        state = self.state,
        position = self.playback_position,
        duration = self.playback_duration,
        can_seek = self:isSeekEnabled(),
    }
end

function PlaybackCoordinator:getActionLabel()
    if self.state == PlaybackCoordinator.STATES.PLAYING then
        return "Pause"
    elseif self.state == PlaybackCoordinator.STATES.PAUSED then
        return "Resume"
    elseif self.state == PlaybackCoordinator.STATES.LOADING then
        return "Loading…"
    elseif self.state == PlaybackCoordinator.STATES.STOPPING then
        return "Stopping…"
    elseif self.state == PlaybackCoordinator.STATES.ERROR then
        return "Unavailable"
    end
    return "Start"
end

function PlaybackCoordinator:isActionEnabled()
    -- MpvAudio's ERROR state is terminal for this document session. Reopening
    -- the document is the recovery path; do not expose a Start action that
    -- can only repeat the same failed adapter session.
    return not self.closed
        and self.state ~= PlaybackCoordinator.STATES.LOADING
        and self.state ~= PlaybackCoordinator.STATES.STOPPING
        and self.state ~= PlaybackCoordinator.STATES.ERROR
end

function PlaybackCoordinator:isStopEnabled()
    return not self.closed
        and self.state ~= PlaybackCoordinator.STATES.ERROR
        and self.state ~= PlaybackCoordinator.STATES.LOADING
        and self.state ~= PlaybackCoordinator.STATES.STOPPING
        and self.state ~= PlaybackCoordinator.STATES.IDLE
        and self.state ~= PlaybackCoordinator.STATES.ENDED
end

function PlaybackCoordinator:isSeekEnabled()
    return not self.closed
        and (self.state == PlaybackCoordinator.STATES.PLAYING
            or self.state == PlaybackCoordinator.STATES.PAUSED)
        and type(self.playback_position) == "number"
        and type(self.playback_duration) == "number"
        and self.playback_duration > 0
end

function PlaybackCoordinator:seekBy(seconds)
    if type(seconds) ~= "number" or seconds ~= seconds
        or seconds == math.huge or seconds == -math.huge then
        return nil, "seek offset must be a finite number"
    end
    if not self:isSeekEnabled() then
        return nil, "read-along is not ready to seek"
    end

    local position = math.max(0, math.min(
        self.playback_duration,
        self.playback_position + seconds
    ))
    local sought, seek_error = invoke(self.adapter, "seek", position)
    if not sought then
        return self:_fail(seek_error or "unable to seek audio")
    end
    self.playback_position = position
    self:_update_overlay(self.current_audio_path, position)
    return true, position
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

function PlaybackCoordinator:_show_range(range)
    invoke_optional(self.overlay, "setRange", range.pos0, range.pos1)
    if type(self.on_range) == "function" then
        pcall(self.on_range, range.pos0, range.pos1)
    end
end

function PlaybackCoordinator:_remove_materialized_audio()
    if self.materialized_path then
        local removed, remove_error = invoke(
            self.materializer,
            "remove",
            self.materialized_path
        )
        if not removed then
            return nil, remove_error or "unable to remove materialized audio"
        end
    end
    self.materialized_path = nil
    self.current_audio_path = nil
    self.playback_position = nil
    self.playback_duration = nil
    return true
end

function PlaybackCoordinator:_report_error(error_message)
    self.error = tostring(error_message or "unknown read-along error")
    if type(self.on_error) == "function" then
        pcall(self.on_error, self.error)
    end
end

function PlaybackCoordinator:_fail(error_message, skip_stop)
    if self.closed then
        return nil, error_message
    end
    self.generation = self.generation + 1
    self:_unschedule_poll()
    self.intent = nil
    self.transition = nil
    if self.materialized_path or self.current_audio_path then
        if not skip_stop and not self.stop_issued then
            self.stop_issued = true
            invoke_optional(self.adapter, "stop")
        end
        local removed, remove_error = self:_remove_materialized_audio()
        if not removed then
            error_message = tostring(error_message or "read-along error")
                .. "; cleanup failed: " .. tostring(remove_error)
            self.cleanup_error = remove_error
        end
    else
        self:_clear_overlay()
    end
    self.stop_issued = false
    self.state = PlaybackCoordinator.STATES.ERROR
    self:_report_error(error_message)
    return nil, self.error
end

function PlaybackCoordinator:_next_clip(index)
    local next_clip = self.clips[index + 1]
    if same_resolver_context(self.clips[index], next_clip) then
        return next_clip
    end
    return nil
end

function PlaybackCoordinator:_get_range(index)
    local cached = self.range_cache[index]
    if cached == false then
        return nil
    end
    if cached then
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
        return nil, resolve_error
    end
    self.range_cache[index] = {
        pos0 = range.pos0,
        pos1 = range.pos1,
    }
    return self.range_cache[index]
end

function PlaybackCoordinator:_resolve_range(index)
    local range = self:_get_range(index)
    if not range then
        self:_clear_overlay()
        return nil
    end
    self:_show_range(range)
    return range
end

function PlaybackCoordinator:_find_clip_for_selection(pos0, pos1)
    if not valid_xpointer(pos0) or not valid_xpointer(pos1) then
        return nil, nil, "selected text has no valid XPointer range"
    end

    local selection_order, selection_error = compare_xpointers(
        self.document,
        pos0,
        pos1
    )
    if not selection_order then
        return nil, nil, selection_error
    end
    if selection_order ~= 1 then
        return nil, nil, "selected text has an empty or reversed XPointer range"
    end

    for index = 1, #self.clips do
        local range = self:_get_range(index)
        if range then
            -- Ranges are half-open. Strict comparisons exclude a selection
            -- that only touches either boundary.
            local selection_starts_before_range_end, compare_error =
                compare_xpointers(self.document, pos0, range.pos1)
            if not selection_starts_before_range_end then
                return nil, nil, compare_error
            end
            local range_starts_before_selection_end
            range_starts_before_selection_end, compare_error = compare_xpointers(
                self.document,
                range.pos0,
                pos1
            )
            if not range_starts_before_selection_end then
                return nil, nil, compare_error
            end
            if selection_starts_before_range_end == 1
                and range_starts_before_selection_end == 1 then
                return index, range
            end
        end
    end
    return nil, nil, "no media overlay segment contains the selected word"
end

function PlaybackCoordinator:canPlayFromXPointer(pos0, pos1)
    if self.closed
        or (self.state ~= PlaybackCoordinator.STATES.IDLE
            and self.state ~= PlaybackCoordinator.STATES.ENDED
            and self.state ~= PlaybackCoordinator.STATES.PLAYING
            and self.state ~= PlaybackCoordinator.STATES.PAUSED) then
        return false
    end
    local index = self:_find_clip_for_selection(pos0, pos1)
    return index ~= nil
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
        return self:_fail("previous audio resource is still owned")
    else
        self:_clear_overlay()
    end
    self.current_clip_index = index
    self.current_audio_path = clip.audio_path
    self.playback_position = nil
    self.playback_duration = nil
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
    local paused, pause_error = invoke(self.adapter, "pause")
    if not paused then
        return self:_fail(pause_error or "unable to pause newly loaded audio")
    end
    self:_schedule_poll()
    return true
end

function PlaybackCoordinator:_prepare_same_resource(index, range)
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
    self.playback_position = clip.clip_begin
    local play_ok, play_error = invoke(self.adapter, "play")
    if not play_ok then
        return self:_fail(play_error or "unable to resume audio")
    end
    self.intent = PlaybackCoordinator.STATES.PLAYING
    self.state = PlaybackCoordinator.STATES.PLAYING
    self:_schedule_poll()
    if range then
        self:_show_range(range)
    end
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
        self:_clear_overlay()
        return self:_begin_stopping{
            kind = "ended",
        }
    end
    if self.current_audio_path == self.clips[next_index].audio_path
        and self.materialized_path then
        return self:_prepare_same_resource(next_index)
    end
    return self:_begin_stopping{
        kind = "resource",
        next_index = next_index,
    }
end

function PlaybackCoordinator:_begin_stopping(transition)
    if self.state == PlaybackCoordinator.STATES.STOPPING then
        return true
    end
    self.transition = transition
    self.state = PlaybackCoordinator.STATES.STOPPING
    self.stop_issued = true
    local stopped, stop_error = invoke(self.adapter, "stop")
    if not stopped then
        return self:_fail(stop_error or "unable to stop audio", true)
    end
    self:_schedule_poll()
    return true
end

function PlaybackCoordinator:_finish_stopping(status)
    if status.state == "error" or status.state == "closed" then
        return self:_fail(
            status.error or "audio failed while stopping",
            true
        )
    end
    if status.state ~= "idle" then
        return true
    end

    local transition = self.transition
    self.transition = nil
    local removed, remove_error = self:_remove_materialized_audio()
    if not removed then
        self.stop_issued = true
        return self:_fail(
            "unable to remove stopped audio: " .. tostring(remove_error),
            true
        )
    end
    self.stop_issued = false

    if transition.kind == "ended" then
        self.current_clip_index = nil
        self.intent = nil
        self.state = PlaybackCoordinator.STATES.ENDED
        self:_unschedule_poll()
        self:_clear_overlay()
        return true
    elseif transition.kind == "stop" then
        self.current_clip_index = nil
        self.intent = nil
        self.state = PlaybackCoordinator.STATES.IDLE
        self:_unschedule_poll()
        self:_clear_overlay()
        return true
    end

    return self:_prepare_resource(transition.next_index)
end

function PlaybackCoordinator:_finish_load(status)
    if status.state == "error" or status.state == "closed"
        or status.state == "ended" then
        return self:_fail(status.error or "audio ended before it became ready")
    end
    if status.state == "loading" or status.state == "startup" then
        return true
    end
    if type(status.duration) ~= "number"
        or status.duration ~= status.duration
        or status.duration == math.huge
        or status.duration <= 0
        or status.paused ~= true then
        return true
    end

    self.playback_position = type(status.position) == "number"
        and status.position or 0
    self.playback_duration = status.duration

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
        self.playback_position = clip.clip_begin
    end
    if self.intent == PlaybackCoordinator.STATES.PLAYING then
        local resumed, resume_error = invoke(self.adapter, "play")
        if not resumed then
            return self:_fail(resume_error or "unable to start audio")
        end
        self.state = PlaybackCoordinator.STATES.PLAYING
    else
        self.state = PlaybackCoordinator.STATES.PAUSED
    end
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
    if type(status.position) == "number" then
        self.playback_position = status.position
    end
    if type(status.duration) == "number" and status.duration > 0 then
        self.playback_duration = status.duration
    end
    if self.state == PlaybackCoordinator.STATES.STOPPING then
        self:_finish_stopping(status)
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
    if self.state == PlaybackCoordinator.STATES.ERROR then
        return nil, "read-along audio failed; reopen the document to retry"
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
    if self.state == PlaybackCoordinator.STATES.STOPPING then
        return nil, "audio is still stopping"
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

function PlaybackCoordinator:playFromXPointer(pos0, pos1)
    if self.closed then
        return nil, "read-along coordinator is closed"
    end
    if self.state == PlaybackCoordinator.STATES.LOADING then
        return nil, "audio is still loading; wait for it to finish"
    end
    if self.state == PlaybackCoordinator.STATES.STOPPING then
        return nil, "audio is still stopping; wait for it to finish"
    end
    if self.state == PlaybackCoordinator.STATES.ERROR then
        return nil, "read-along audio failed; reopen the document to retry"
    end
    if self.state ~= PlaybackCoordinator.STATES.IDLE
        and self.state ~= PlaybackCoordinator.STATES.ENDED
        and self.state ~= PlaybackCoordinator.STATES.PLAYING
        and self.state ~= PlaybackCoordinator.STATES.PAUSED then
        return nil, "read-along is not ready to jump"
    end

    local index, range, selection_error = self:_find_clip_for_selection(
        pos0,
        pos1
    )
    if not index then
        return nil, selection_error
    end

    local clip = self.clips[index]
    if self.state == PlaybackCoordinator.STATES.PLAYING
        or self.state == PlaybackCoordinator.STATES.PAUSED then
        if self.materialized_path
            and self.current_audio_path == clip.audio_path then
            return self:_prepare_same_resource(index, range)
        end
        if not self.materialized_path or not self.current_audio_path then
            return nil, "current audio resource is not ready"
        end
        self.generation = self.generation + 1
        self:_unschedule_poll()
        self.intent = PlaybackCoordinator.STATES.PLAYING
        self:_clear_overlay()
        return self:_begin_stopping{
            kind = "resource",
            next_index = index,
        }
    end

    if self.materialized_path or self.current_audio_path then
        return nil, "audio resource ownership is still active"
    end
    self.error = nil
    self.intent = PlaybackCoordinator.STATES.PLAYING
    self.generation = self.generation + 1
    self:_unschedule_poll()
    return self:_prepare_resource(index)
end

function PlaybackCoordinator:stop()
    if self.closed then
        return true
    end
    if self.state == PlaybackCoordinator.STATES.ERROR then
        return nil, "read-along audio failed; reopen the document to retry"
    end
    if self.state == PlaybackCoordinator.STATES.LOADING then
        return nil, "audio is still loading; close the document to cancel it"
    end
    if self.state == PlaybackCoordinator.STATES.STOPPING then
        return true
    end
    if self.state == PlaybackCoordinator.STATES.IDLE
        or self.state == PlaybackCoordinator.STATES.ENDED then
        return true
    end
    self.generation = self.generation + 1
    self:_unschedule_poll()
    self.intent = nil
    self.error = nil
    self:_clear_overlay()
    return self:_begin_stopping{
        kind = "stop",
    }
end

function PlaybackCoordinator:close()
    if self.closed then
        if self.cleanup_error then
            local cleaned, cleanup_error = invoke(self.materializer, "cleanup")
            if cleaned then
                self.materialized_path = nil
                self.current_audio_path = nil
                self.cleanup_error = nil
            else
                self.cleanup_error = cleanup_error
            end
        end
        return true
    end
    -- Invalidate first: callbacks already dequeued by UIManager must become
    -- no-ops and must never schedule themselves again.
    self.generation = self.generation + 1
    self.closed = true
    self:_unschedule_poll()
    if self.state ~= PlaybackCoordinator.STATES.STOPPING
        and self.state ~= PlaybackCoordinator.STATES.LOADING then
        invoke_optional(self.adapter, "stop")
    end
    invoke_optional(self.adapter, "close")
    self:_clear_overlay()
    invoke_optional(self.overlay, "deactivate")
    local cleaned, cleanup_error = invoke(self.materializer, "cleanup")
    if cleaned then
        self.materialized_path = nil
        self.current_audio_path = nil
        self.cleanup_error = nil
    else
        self.cleanup_error = cleanup_error
    end
    self.intent = nil
    self.transition = nil
    self.stop_issued = false
    self.state = PlaybackCoordinator.STATES.CLOSED
    return true
end

return PlaybackCoordinator
