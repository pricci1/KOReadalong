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
            else
                return nil, "path escapes EPUB ZIP root: " .. path
            end
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    local result = table.concat(parts, "/")
    if absolute then
        result = "/" .. result
    end
    return result, nil
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
    local normalized, error_message = normalize_path(path)
    if not normalized then
        return nil, error_message
    end
    return normalized, fragment
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

local function normalized_documents(documents)
    local result = {}
    if type(documents) ~= "table" then
        return nil, "SMIL documents must be a map of ZIP-entry path to XML"
    end
    for path, document in pairs(documents) do
        if type(path) ~= "string" or type(document) ~= "string" then
            return nil, "SMIL documents must map string paths to XML strings"
        end
        local normalized, error_message = normalize_path(path)
        if not normalized then
            return nil, error_message
        end
        result[normalized] = document
    end
    return result, nil
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
    local skipped_clips = 0
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
            local text_path, text_path_error
            if text_reference_path == "" and content_path then
                text_path = content_path
            else
                text_path, text_path_error = resolve_reference(smil_path, text_reference_path)
            end
            if not text_path then
                return nil, "SMIL par " .. par_number .. " text src: " .. text_path_error
            end
            local audio_path, audio_path_error = resolve_reference(smil_path, audio.attributes.src)
            if not audio_path then
                return nil, "SMIL par " .. par_number .. " audio src: " .. audio_path_error
            end
            local clip_begin, begin_error = parse_clock(audio.attributes.clipBegin)
            if not clip_begin then
                return nil, "SMIL par " .. par_number .. " clipBegin: " .. begin_error
            end
            local clip_end, end_error = parse_clock(audio.attributes.clipEnd)
            if not clip_end then
                return nil, "SMIL par " .. par_number .. " clipEnd: " .. end_error
            end
            if clip_end <= clip_begin then
                skipped_clips = skipped_clips + 1
                return true
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
    return clips, nil, skipped_clips
end

function MediaOverlays.parse_clock(value)
    return parse_clock(value)
end

function MediaOverlays.resolve_path(base_path, reference)
    return resolve_reference(base_path, reference)
end

local function parse_package_metadata(opf_xml, opf_path)
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
    local overlay_items_by_id = {}
    local content_paths_by_href = {}
    for _, item in ipairs(manifest.children) do
        if item.name == "item" then
            local attributes = item.attributes
            if attributes.id then
                if items_by_id[attributes.id] then
                    return nil, "manifest has duplicate item id '" .. attributes.id
                        .. "'"
                end
                items_by_id[attributes.id] = attributes
            end
            if attributes["media-type"] == "application/xhtml+xml" then
                if attributes.href and attributes.href ~= "" then
                    local content_path, content_path_error = resolve_reference(
                        opf_path,
                        attributes.href
                    )
                    if not content_path then
                        return nil, content_path_error
                    end
                    if content_paths_by_href[content_path] then
                        return nil, "manifest has duplicate XHTML content href '"
                            .. content_path .. "'"
                    end
                    content_paths_by_href[content_path] = attributes.id or true
                end
                if attributes["media-overlay"] then
                    if not attributes.id then
                        return nil, "XHTML overlay item has no manifest id"
                    end
                    overlay_items_by_id[attributes.id] = attributes
                end
            end
        end
    end
    local spine = find_descendant(package, "spine")
    if not spine then
        return nil, "OPF document has no spine"
    end
    local overlay_documents = {}
    local spine_content_hrefs = {}
    -- CRe counts every preceding spine itemref whose manifest item has a
    -- non-empty id and href.  linear="no", non-overlay, unsupported, and
    -- repeated valid itemrefs still consume a slot. Repeated content hrefs
    -- are rejected below because CRe's path substitution is ambiguous.
    local spine_index = 0
    for _, itemref in ipairs(spine.children) do
        if itemref.name == "itemref" then
            local idref = itemref.attributes.idref
            if not idref or idref == "" then
                return nil, "spine itemref is missing idref"
            end
            local content = items_by_id[idref]
            if not content then
                return nil, "spine itemref references missing manifest item '" .. idref .. "'"
            end
            local document_spine_index = spine_index
            local content_path, content_path_error
            if content.id and content.id ~= "" and content.href and content.href ~= "" then
                content_path, content_path_error = resolve_reference(
                    opf_path,
                    content.href
                )
                if not content_path then
                    return nil, content_path_error
                end
                if spine_content_hrefs[content_path] then
                    return nil, "duplicate spine content href '" .. content_path
                        .. "' is unsupported"
                end
                spine_content_hrefs[content_path] = true
                spine_index = spine_index + 1
            end
            if overlay_items_by_id[idref] then
                if not content.href or content.href == "" then
                    return nil, "XHTML item '" .. (content.id or "?") .. "' has no href"
                end
                local smil_item = items_by_id[content["media-overlay"]]
                if not smil_item then
                    return nil, "XHTML item '" .. (content.id or "?")
                        .. "' references missing media-overlay '"
                        .. content["media-overlay"] .. "'"
                end
                if not smil_item.href or smil_item.href == "" then
                    return nil, "media-overlay item '" .. content["media-overlay"]
                        .. "' has no href"
                end
                local smil_path, smil_path_error = resolve_reference(
                    opf_path,
                    smil_item.href
                )
                if not smil_path then
                    return nil, smil_path_error
                end
                overlay_documents[#overlay_documents + 1] = {
                    path = smil_path,
                    content_path = content_path,
                    spine_index = document_spine_index,
                }
            end
        end
    end
    return overlay_documents
end

-- parse/load return clips, nil, skipped_clips on success (including zero
-- retained clips), or nil, error on failure. The count contains no book paths
-- or text; only parsed nonpositive intervals are recoverable.
function MediaOverlays.parse(opf_xml, opf_path, smil_documents)
    local overlay_documents, metadata_error = parse_package_metadata(
        opf_xml,
        opf_path
    )
    if not overlay_documents then
        return nil, metadata_error
    end
    local documents, documents_error = normalized_documents(smil_documents)
    if not documents then
        return nil, documents_error
    end
    local clips = {}
    local skipped_clips = 0
    for _, document in ipairs(overlay_documents) do
        local smil_xml = documents[document.path]
        if not smil_xml then
            return nil, "SMIL document not provided for '" .. document.path .. "'"
        end
        local smil_clips, smil_error, smil_skipped_clips = parse_smil(
            smil_xml,
            document.path,
            document.content_path
        )
        if not smil_clips then
            return nil, "invalid SMIL '" .. document.path .. "': " .. smil_error
        end
        skipped_clips = skipped_clips + smil_skipped_clips
        for _, clip in ipairs(smil_clips) do
            clip.spine_index = document.spine_index
            clips[#clips + 1] = clip
        end
    end
    return clips, nil, skipped_clips
end

local function read_archive_entry(read_file, path, description)
    local ok, content, callback_error = pcall(read_file, path)
    if not ok then
        callback_error = content
        content = nil
    end
    if type(content) == "string" then
        return content
    end
    local detail = callback_error and tostring(callback_error)
    if not detail or detail == "" then
        detail = "callback returned no content"
    end
    return nil, "unable to read " .. description .. " '" .. path .. "': " .. detail
end

local function rootfile_path(container_xml)
    local container, xml_error = parse_xml(container_xml)
    if not container then
        return nil, "invalid META-INF/container.xml: " .. xml_error
    end
    local rootfiles = find_descendant(container, "rootfiles")
    if not rootfiles then
        return nil, "META-INF/container.xml has no rootfile"
    end
    local first_rootfile
    local package_rootfile
    for _, child in ipairs(rootfiles.children) do
        if child.name == "rootfile" then
            first_rootfile = first_rootfile or child
            if child.attributes["media-type"] == "application/oebps-package+xml" then
                package_rootfile = package_rootfile or child
            end
        end
    end
    local selected = package_rootfile or first_rootfile
    if not selected then
        return nil, "META-INF/container.xml has no rootfile"
    end
    local full_path = selected.attributes["full-path"]
    if not full_path or full_path == "" then
        return nil, "EPUB rootfile is missing full-path"
    end
    local normalized, path_error = normalize_path(full_path)
    if not normalized then
        return nil, "invalid EPUB rootfile full-path: " .. path_error
    end
    return normalized
end

function MediaOverlays.load(read_file)
    if type(read_file) ~= "function" then
        return nil, "MediaOverlays.load requires a read_file callback"
    end
    local container_xml, container_error = read_archive_entry(
        read_file,
        "META-INF/container.xml",
        "container"
    )
    if not container_xml then
        return nil, container_error
    end
    local opf_path, rootfile_error = rootfile_path(container_xml)
    if not opf_path then
        return nil, rootfile_error
    end
    local opf_xml, opf_error = read_archive_entry(read_file, opf_path, "OPF")
    if not opf_xml then
        return nil, opf_error
    end
    local overlay_documents, metadata_error = parse_package_metadata(
        opf_xml,
        opf_path
    )
    if not overlay_documents then
        return nil, "invalid OPF '" .. opf_path .. "': " .. metadata_error
    end
    local smil_documents = {}
    local requested = {}
    for _, document in ipairs(overlay_documents) do
        if not requested[document.path] then
            local smil_xml, smil_error = read_archive_entry(
                read_file,
                document.path,
                "SMIL"
            )
            if not smil_xml then
                return nil, smil_error
            end
            smil_documents[document.path] = smil_xml
            requested[document.path] = true
        end
    end
    return MediaOverlays.parse(opf_xml, opf_path, smil_documents)
end

return MediaOverlays
