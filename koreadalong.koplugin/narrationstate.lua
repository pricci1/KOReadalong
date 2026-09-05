local NarrationState = {}
NarrationState.__index = NarrationState

NarrationState.KEY = "koreadalong_narration_location"
NarrationState.VERSION = 1

local IDENTITY_FIELDS = {
    "text_path",
    "text_fragment",
    "spine_index",
    "audio_path",
    "clip_begin",
    "clip_end",
}

local function valid_string(value)
    return type(value) == "string" and value ~= ""
end

local function finite_number(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function append_identity_field(parts, value)
    local encoded = tostring(value == nil and "" or value)
    parts[#parts + 1] = tostring(#encoded) .. ":" .. encoded
end

local function copy_clip(clip)
    local copy = {}
    for _, field in ipairs(IDENTITY_FIELDS) do
        copy[field] = clip[field]
    end
    return copy
end

local function copy_state(state)
    return {
        version = state.version,
        content_id = state.content_id,
        clip = copy_clip(state.clip),
        pos0 = state.pos0,
        pos1 = state.pos1,
        position = state.position,
    }
end

function NarrationState.contentIdentity(clips)
    if type(clips) ~= "table" then
        return nil
    end
    local parts = {}
    for index, clip in ipairs(clips) do
        if type(clip) ~= "table" then
            return nil
        end
        append_identity_field(parts, index)
        for _, field in ipairs(IDENTITY_FIELDS) do
            append_identity_field(parts, clip[field])
        end
    end
    return table.concat(parts, "|")
end

function NarrationState.new(options)
    options = options or {}
    return setmetatable({
        settings = options.settings,
        content_id = NarrationState.contentIdentity(options.clips or {}),
    }, NarrationState)
end

function NarrationState:load()
    if not self.settings
        or type(self.settings.readSetting) ~= "function" then
        return nil
    end
    local ok, state = pcall(
        self.settings.readSetting,
        self.settings,
        NarrationState.KEY
    )
    if not ok or type(state) ~= "table" then
        return nil, "saved narration state is unavailable"
    end
    if state.version ~= NarrationState.VERSION
        or state.content_id ~= self.content_id
        or type(state.clip) ~= "table"
        or not valid_string(state.pos0)
        or not valid_string(state.pos1)
        or not finite_number(state.position) then
        return nil, "saved narration state does not match this EPUB"
    end
    for _, field in ipairs(IDENTITY_FIELDS) do
        if state.clip[field] == nil then
            return nil, "saved narration state has no clip identity"
        end
    end
    return copy_state(state)
end

function NarrationState:save(location)
    if not self.settings
        or type(self.settings.saveSetting) ~= "function"
        or type(location) ~= "table"
        or type(location.clip) ~= "table"
        or not valid_string(location.pos0)
        or not valid_string(location.pos1)
        or not finite_number(location.position) then
        return nil, "unable to save narration state"
    end

    local state = {
        version = NarrationState.VERSION,
        content_id = self.content_id,
        clip = copy_clip(location.clip),
        pos0 = location.pos0,
        pos1 = location.pos1,
        position = location.position,
    }
    local ok, error_message = pcall(
        self.settings.saveSetting,
        self.settings,
        NarrationState.KEY,
        state
    )
    if not ok then
        return nil, tostring(error_message)
    end
    if type(self.settings.flush) == "function" then
        ok, error_message = pcall(self.settings.flush, self.settings)
        if not ok then
            return nil, tostring(error_message)
        end
    end
    return true
end

function NarrationState:clear()
    if not self.settings then
        return true
    end
    if type(self.settings.delSetting) == "function" then
        local ok, error_message = pcall(
            self.settings.delSetting,
            self.settings,
            NarrationState.KEY
        )
        if not ok then
            return nil, tostring(error_message)
        end
    end
    if type(self.settings.flush) == "function" then
        local ok, error_message = pcall(self.settings.flush, self.settings)
        if not ok then
            return nil, tostring(error_message)
        end
    end
    return true
end

return NarrationState
