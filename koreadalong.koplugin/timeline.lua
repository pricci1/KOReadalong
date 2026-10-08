local Timeline = {}
Timeline.__index = Timeline

function Timeline.new(clips)
    if type(clips) ~= "table" then
        return nil, "Timeline clips must be a table"
    end
    local clips_by_audio_path = {}
    local last_by_audio_path = {}
    for index, clip in ipairs(clips) do
        if type(clip.audio_path) ~= "string" or clip.audio_path == "" then
            return nil, "clip " .. index .. " is missing audio_path"
        end
        if type(clip.clip_begin) ~= "number" or type(clip.clip_end) ~= "number" then
            return nil, "clip " .. index .. " has invalid clip bounds"
        end
        if clip.clip_end <= clip.clip_begin then
            return nil, "clip " .. index .. " clipEnd must be after clipBegin"
        end
        local resource_clips = clips_by_audio_path[clip.audio_path]
        if not resource_clips then
            resource_clips = {}
            clips_by_audio_path[clip.audio_path] = resource_clips
        end
        local previous = last_by_audio_path[clip.audio_path]
        if previous and clip.clip_begin < previous.clip_begin then
            return nil, "clips for audio resource '" .. clip.audio_path
                .. "' are non-monotonic at clip " .. index
        end
        resource_clips[#resource_clips + 1] = clip
        last_by_audio_path[clip.audio_path] = clip
    end
    local extents, chapters, chapter_count, duration = {}, {}, 0, 0
    for _, clip in ipairs(clips) do
        local extent = extents[clip.audio_path]
        if not extent then
            extent = { begin = clip.clip_begin, finish = clip.clip_end }
            extents[clip.audio_path] = extent
        end
        extent.finish = math.max(extent.finish, clip.clip_end)
        if clip.spine_index and not chapters[clip.spine_index] then
            chapter_count = chapter_count + 1
            chapters[clip.spine_index] = chapter_count
        end
    end
    local seen = {}
    for _, clip in ipairs(clips) do
        if not seen[clip.audio_path] then
            local extent = extents[clip.audio_path]
            extent.offset = duration
            duration = duration + extent.finish - extent.begin
            seen[clip.audio_path] = true
        end
    end
    return setmetatable({ clips_by_audio_path = clips_by_audio_path,
        extents = extents, duration = duration, chapters = chapters,
        chapter_count = chapter_count }, Timeline)
end

-- Overlay span includes gaps, excludes unreferenced leading/trailing audio.
function Timeline:getBookProgress(audio_path, position)
    local extent = self.extents[audio_path]
    local elapsed
    if extent and type(position) == "number" and position == position
        and position > -math.huge and position < math.huge then
        elapsed = extent.offset + math.max(0,
            math.min(extent.finish - extent.begin, position - extent.begin))
    end
    local clip = self:lookup(audio_path, position)
    return elapsed, self.duration, clip and self.chapters[clip.spine_index], self.chapter_count
end

-- Clip intervals are half-open: [clip_begin, clip_end).
-- At an exact shared boundary, the following clip is selected; gaps return nil.
function Timeline:lookup(audio_path, playback_time)
    if type(audio_path) ~= "string" then
        return nil
    end
    local clips = self.clips_by_audio_path[audio_path]
    if not clips then
        return nil
    end
    if type(playback_time) ~= "number" or playback_time ~= playback_time then
        return nil
    end
    local low = 1
    local high = #clips
    local candidate
    while low <= high do
        local middle = math.floor((low + high) / 2)
        if clips[middle].clip_begin <= playback_time then
            candidate = middle
            low = middle + 1
        else
            high = middle - 1
        end
    end
    if candidate then
        local clip = clips[candidate]
        if playback_time < clip.clip_end then
            return clip
        end
    end
    return nil
end

return Timeline
