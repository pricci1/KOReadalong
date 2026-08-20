local MediaOverlays = {}

local XML_ENTITIES = {
    amp = "&",
    apos = "'",
    gt = ">",
    lt = "<",
    quot = '"',
}

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function utf8_character(codepoint)
    if codepoint < 0x80 then
        return string.char(codepoint)
    elseif codepoint < 0x800 then
        return string.char(
            0xc0 + math.floor(codepoint / 0x40),
            0x80 + codepoint % 0x40
        )
    elseif codepoint < 0x10000 then
        return string.char(
            0xe0 + math.floor(codepoint / 0x1000),
            0x80 + math.floor(codepoint / 0x40) % 0x40,
            0x80 + codepoint % 0x40
        )
    end
    return string.char(
        0xf0 + math.floor(codepoint / 0x40000),
        0x80 + math.floor(codepoint / 0x1000) % 0x40,
        0x80 + math.floor(codepoint / 0x40) % 0x40,
        0x80 + codepoint % 0x40
    )
end

local function decode_entities(value)
    local result, error_message
    result = value:gsub("&([^;]+);", function(entity)
        if XML_ENTITIES[entity] then
            return XML_ENTITIES[entity]
        end
        local codepoint = entity:match("^#([0-9]+)$")
        if not codepoint then
            codepoint = entity:match("^#[xX]([0-9a-fA-F]+)$")
            codepoint = codepoint and tonumber(codepoint, 16)
        else
            codepoint = tonumber(codepoint)
        end
        if codepoint and codepoint <= 0x10ffff then
            return utf8_character(codepoint)
        end
        error_message = "unknown or invalid XML entity &" .. entity .. ";"
        return ""
    end)
    if error_message then
        return nil, error_message
    end
    return result
end

local function local_name(name)
    return name:match("([^:]+)$")
end

local function find_tag_end(xml, start)
    local quote
    local position = start
    while position <= #xml do
        local character = xml:sub(position, position)
        if quote then
            if character == quote then
                quote = nil
            end
        elseif character == '"' or character == "'" then
            quote = character
        elseif character == ">" then
            return position
        end
        position = position + 1
    end
    return nil
end

local function parse_open_tag(contents)
    local name, name_end = contents:match("^%s*([%w_:%.%-]+)()")
    if not name then
        return nil, "missing element name"
    end

    local self_closing = contents:match("/%s*$") ~= nil
    local limit = #contents
    if self_closing then
        limit = contents:match("^(.*)/%s*$"):len()
    end
    local attributes = {}
    local position = name_end
    while position <= limit do
        local whitespace_end = contents:match("^%s*()", position)
        position = whitespace_end
        if position > limit then
            break
        end
        local attribute, attribute_end = contents:match(
            "^([%w_:%.%-]+)()", position
        )
        if not attribute then
            return nil, "malformed attribute near '" .. contents:sub(position) .. "'"
        end
        position = contents:match("^%s*()", attribute_end)
        if contents:sub(position, position) ~= "=" then
            return nil, "attribute '" .. attribute .. "' has no value"
        end
        position = contents:match("^%s*()", position + 1)
        local quote = contents:sub(position, position)
        if quote ~= '"' and quote ~= "'" then
            return nil, "attribute '" .. attribute .. "' is not quoted"
        end
        local value_end = contents:find(quote, position + 1, true)
        if not value_end or value_end > limit then
            return nil, "unterminated value for attribute '" .. attribute .. "'"
        end
        local value, entity_error = decode_entities(
            contents:sub(position + 1, value_end - 1)
        )
        if not value then
            return nil, entity_error
        end
        attributes[attribute] = value
        position = value_end + 1
    end
    return { name = local_name(name), attributes = attributes, children = {} }, self_closing
end

local function parse_xml(xml)
    if type(xml) ~= "string" then
        return nil, "XML document must be a string"
    end
    local root
    local stack = {}
    local position = 1
    while position <= #xml do
        local opening = xml:find("<", position, true)
        if not opening then
            if trim(xml:sub(position)) ~= "" then
                return nil, "text outside the document element"
            end
            break
        end
        if trim(xml:sub(position, opening - 1)) ~= "" and #stack == 0 then
            return nil, "text outside the document element"
        end
        if xml:sub(opening, opening + 3) == "<!--" then
            local comment_end = xml:find("-->", opening + 4, true)
            if not comment_end then
                return nil, "unterminated XML comment"
            end
            position = comment_end + 3
        elseif xml:sub(opening, opening + 8) == "<![CDATA[" then
            local cdata_end = xml:find("]]>", opening + 9, true)
            if not cdata_end then
                return nil, "unterminated CDATA section"
            end
            position = cdata_end + 3
        elseif xml:sub(opening, opening + 1) == "<?" then
            local instruction_end = xml:find("?>", opening + 2, true)
            if not instruction_end then
                return nil, "unterminated processing instruction"
            end
            position = instruction_end + 2
        elseif xml:sub(opening, opening + 1) == "<!" then
            local declaration_end = find_tag_end(xml, opening + 2)
            if not declaration_end then
                return nil, "unterminated XML declaration"
            end
            position = declaration_end + 1
        else
            local tag_end = find_tag_end(xml, opening + 1)
            if not tag_end then
                return nil, "unterminated XML tag"
            end
            local contents = xml:sub(opening + 1, tag_end - 1)
            if contents:match("^%s*/") then
                local closing_name = contents:match("^%s*/%s*([%w_:%.%-]+)%s*$")
                local parent = stack[#stack]
                if not closing_name then
                    return nil, "malformed closing tag"
                end
                if not parent or parent.name ~= local_name(closing_name) then
                    return nil, "closing tag does not match '" .. closing_name .. "'"
                end
                stack[#stack] = nil
            else
                local node, self_closing_or_error = parse_open_tag(contents)
                if not node then
                    return nil, "malformed XML tag: " .. self_closing_or_error
                end
                local parent = stack[#stack]
                if parent then
                    parent.children[#parent.children + 1] = node
                elseif root then
                    return nil, "multiple document elements"
                else
                    root = node
                end
                if not self_closing_or_error then
                    stack[#stack + 1] = node
                end
            end
            position = tag_end + 1
        end
    end
    if #stack > 0 then
        return nil, "unclosed XML element '" .. stack[#stack].name .. "'"
    end
    if not root then
        return nil, "document has no root element"
    end
    return root
end

local function find_child(node, wanted_name)
    for _, child in ipairs(node.children) do
        if child.name == wanted_name then
            return child
        end
    end
end

local function find_descendant(node, wanted_name)
    if node.name == wanted_name then
        return node
    end
    for _, child in ipairs(node.children) do
        local result = find_descendant(child, wanted_name)
        if result then
            return result
        end
    end
end

local function normalize_path(path)
    local absolute = path:sub(1, 1) == "/"
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                parts[#parts] = nil
            elseif not absolute then
                parts[#parts + 1] = part
            end
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    local result = table.concat(parts, "/")
    if absolute then
        result = "/" .. result
    end
    return result
end

local function split_reference(reference)
    local literal_fragment = reference:find("#", 1, true)
    local encoded_fragment = reference:lower():find("%23", 1, true)
    local separator = literal_fragment
    local separator_length = 1
    if encoded_fragment and (not separator or encoded_fragment < separator) then
        separator = encoded_fragment
        separator_length = 3
    end
    if separator then
        return reference:sub(1, separator - 1), reference:sub(separator + separator_length)
    end
    return reference, nil
end

local function resolve_reference(base_path, reference)
    local path, fragment = split_reference(reference)
    if path:sub(1, 1) ~= "/" then
        local directory = base_path:match("^(.*)/")
        path = (directory and directory .. "/" or "") .. path
    end
    return normalize_path(path), fragment
end

local function parse_clock(value)
    if type(value) ~= "string" then
        return nil, "clock value must be a string"
    end
    value = trim(value)
    local hours, minutes, seconds, fraction = value:match(
        "^([0-9]+):([0-9][0-9]):([0-9][0-9])([.][0-9]+)$"
    )
    if not hours then
        hours, minutes, seconds = value:match(
            "^([0-9]+):([0-9][0-9]):([0-9][0-9])$"
        )
    end
    if hours then
        minutes = tonumber(minutes)
        seconds = tonumber(seconds)
        if minutes >= 60 or seconds >= 60 then
            return nil, "clock value has minutes or seconds outside 0..59: " .. value
        end
        return tonumber(hours) * 3600 + minutes * 60 + seconds
            + (fraction and tonumber(fraction) or 0)
    end
    minutes, seconds, fraction = value:match(
        "^([0-9]+):([0-9][0-9])([.][0-9]+)$"
    )
    if not minutes then
        minutes, seconds = value:match("^([0-9]+):([0-9][0-9])$")
    end
    if minutes then
        seconds = tonumber(seconds)
        if seconds >= 60 then
            return nil, "clock value has seconds outside 0..59: " .. value
        end
        return tonumber(minutes) * 60 + seconds
            + (fraction and tonumber(fraction) or 0)
    end
    local number, unit
    for _, candidate in ipairs({ "ms", "min", "h", "s" }) do
        number = value:match("^([0-9]+[.][0-9]+)%s*" .. candidate .. "$")
        if not number then
            number = value:match("^([0-9]+)%s*" .. candidate .. "$")
        end
        if number then
            unit = candidate
            break
        end
    end
    if number then
        local multipliers = { h = 3600, min = 60, ms = 0.001, s = 1 }
        return tonumber(number) * multipliers[unit]
    end
    if value:match("^[0-9]+[.][0-9]+$")
        or value:match("^[0-9]+$") then
        return tonumber(value)
    end
    return nil, "invalid SMIL clock value '" .. value .. "'"
end

local function normalized_documents(documents, single_path)
    local result = {}
    if type(documents) == "string" and single_path then
        result[normalize_path(single_path)] = documents
    elseif type(documents) == "table" then
        if documents.path and documents.xml then
            result[normalize_path(documents.path)] = documents.xml
        elseif #documents > 0 then
            for _, document in ipairs(documents) do
                result[normalize_path(document.path)] = document.xml
            end
        else
            for path, document in pairs(documents) do
                if type(document) == "table" then
                    result[normalize_path(path)] = document.xml
                else
                    result[normalize_path(path)] = document
                end
            end
        end
    end
    return result
end

local function parse_smil(smil_xml, smil_path, content_path)
    local root, xml_error = parse_xml(smil_xml)
    if not root then
        return nil, xml_error
    end
    local body = find_descendant(root, "body")
    if not body then
        return nil, "SMIL document has no body"
    end
    local clips = {}
    local par_number = 0
    local function walk(node)
        if node.name == "par" then
            par_number = par_number + 1
            local text = find_child(node, "text")
            local audio = find_child(node, "audio")
            if not text or not text.attributes.src or text.attributes.src == "" then
                return nil, "SMIL par " .. par_number .. " is missing text src"
            end
            if not audio or not audio.attributes.src or audio.attributes.src == "" then
                return nil, "SMIL par " .. par_number .. " is missing audio src"
            end
            if not audio.attributes.clipBegin or audio.attributes.clipBegin == "" then
                return nil, "SMIL par " .. par_number .. " is missing clipBegin"
            end
            if not audio.attributes.clipEnd or audio.attributes.clipEnd == "" then
                return nil, "SMIL par " .. par_number .. " is missing clipEnd"
            end
            local text_reference_path, fragment = split_reference(text.attributes.src)
            if not fragment or fragment == "" then
                return nil, "SMIL par " .. par_number .. " text src has no fragment"
            end
            local text_path
            if text_reference_path == "" and content_path then
                text_path = content_path
            else
                text_path = resolve_reference(smil_path, text_reference_path)
            end
            local audio_path = resolve_reference(smil_path, audio.attributes.src)
            local clip_begin, begin_error = parse_clock(audio.attributes.clipBegin)
            if not clip_begin then
                return nil, "SMIL par " .. par_number .. " clipBegin: " .. begin_error
            end
            local clip_end, end_error = parse_clock(audio.attributes.clipEnd)
            if not clip_end then
                return nil, "SMIL par " .. par_number .. " clipEnd: " .. end_error
            end
            if clip_end <= clip_begin then
                return nil, "SMIL par " .. par_number .. " clipEnd must be after clipBegin"
            end
            clips[#clips + 1] = {
                text_path = text_path,
                text_fragment = fragment,
                audio_path = audio_path,
                clip_begin = clip_begin,
                clip_end = clip_end,
            }
            return true
        end
        for _, child in ipairs(node.children) do
            local ok, error_message = walk(child)
            if not ok then
                return nil, error_message
            end
        end
        return true
    end
    local ok, walk_error = walk(body)
    if not ok then
        return nil, walk_error
    end
    return clips
end

function MediaOverlays.parse_clock(value)
    return parse_clock(value)
end

function MediaOverlays.split_reference(reference)
    return split_reference(reference)
end

function MediaOverlays.resolve_path(base_path, reference)
    return resolve_reference(base_path, reference)
end

function MediaOverlays.parse(opf_xml, opf_path, smil_documents, single_smil_path)
    local package, xml_error = parse_xml(opf_xml)
    if not package then
        return nil, "invalid OPF XML: " .. xml_error
    end
    if type(opf_path) ~= "string" or opf_path == "" then
        return nil, "OPF containing path is required"
    end
    local manifest = find_descendant(package, "manifest")
    if not manifest then
        return nil, "OPF document has no manifest"
    end
    local items_by_id = {}
    local content_items = {}
    for _, item in ipairs(manifest.children) do
        if item.name == "item" then
            local attributes = item.attributes
            if attributes.id then
                items_by_id[attributes.id] = attributes
            end
            if attributes["media-type"] == "application/xhtml+xml" then
                content_items[#content_items + 1] = attributes
            end
        end
    end
    local documents = normalized_documents(smil_documents, single_smil_path)
    local clips = {}
    for _, content in ipairs(content_items) do
        if content["media-overlay"] then
            if not content.href then
                return nil, "XHTML item '" .. (content.id or "?") .. "' has no href"
            end
            local content_path = resolve_reference(opf_path, content.href)
            local smil_item = items_by_id[content["media-overlay"]]
            if not smil_item then
                return nil, "XHTML item '" .. (content.id or "?")
                    .. "' references missing media-overlay '"
                    .. content["media-overlay"] .. "'"
            end
            if not smil_item.href then
                return nil, "media-overlay item '" .. content["media-overlay"]
                    .. "' has no href"
            end
            local smil_path = resolve_reference(opf_path, smil_item.href)
            local smil_xml = documents[smil_path]
            if not smil_xml then
                return nil, "SMIL document not provided for '" .. smil_path .. "'"
            end
            local smil_clips, smil_error = parse_smil(
                smil_xml,
                smil_path,
                content_path
            )
            if not smil_clips then
                return nil, "invalid SMIL '" .. smil_path .. "': " .. smil_error
            end
            for _, clip in ipairs(smil_clips) do
                clips[#clips + 1] = clip
            end
        end
    end
    return clips
end

MediaOverlays.parse_media_overlays = MediaOverlays.parse

return MediaOverlays
