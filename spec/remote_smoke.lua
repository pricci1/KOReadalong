-- Loaded as an extra plugin only by scripts/run-remote-smoke. Uses the actual
-- production plugin, CRe, native widgets, X11 pointer events, mDNS and UDP.
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local socket = require("socket")
local json = require("dkjson")
local ffi = require("ffi")

local Smoke = WidgetContainer:extend{ is_doc_only = true }

function Smoke:onDocSettingsLoad(settings)
    settings:saveSetting("koreadalong_source", "remote")
end

function Smoke:onReaderReady()
    if self.started then return end
    self.started = true
    local phone = assert(socket.udp())
    assert(phone:setsockname("127.0.0.1", 0))
    phone:settimeout(0)
    ffi.cdef[[
        void *XOpenDisplay(const char *name);
        int XCloseDisplay(void *display);
        int XFlush(void *display);
        int XTestFakeMotionEvent(void *display, int screen, int x, int y, unsigned long delay);
        int XTestFakeButtonEvent(void *display, unsigned int button, int pressed, unsigned long delay);
    ]]
    local x11, xtst = ffi.load("X11"), ffi.load("libXtst.so.6")
    local display = assert(x11.XOpenDisplay(nil))
    local function wait(delay) coroutine.yield(delay) end
    local function check(value, message) assert(value, message) end
    local function log(message) print("REMOTE_SMOKE " .. message) end
    local artifacts = os.getenv("KOREADALONG_REMOTE_ARTIFACTS")
    local function shot(name)
        if artifacts then Device.screen:shot(artifacts .. "/" .. name .. ".png") end
    end
    local function find_button(widget, text)
        if widget.text == text and widget.callback and widget.dimen then return widget end
        for _, child in ipairs(widget) do
            local found = find_button(child, text)
            if found then return found end
        end
    end
    local pointer_x, pointer_y = 5, 5
    local function click(widget)
        local r = assert(widget and widget.dimen, "missing painted control")
        local x, y = math.floor(r.x + r.w / 2), math.floor(r.y + r.h / 2)
        for i = 1, 12 do
            xtst.XTestFakeMotionEvent(display, -1,
                math.floor(pointer_x + (x - pointer_x) * i / 12),
                math.floor(pointer_y + (y - pointer_y) * i / 12), 0)
            x11.XFlush(display)
            wait(0.02)
        end
        pointer_x, pointer_y = x, y
        xtst.XTestFakeButtonEvent(display, 1, 1, 0)
        -- Queue release in X11, not UIManager: touch handling may wait for the
        -- release before running another UI timer (otherwise this is a hold).
        xtst.XTestFakeButtonEvent(display, 1, 0, 80)
        x11.XFlush(display)
        wait(0.5)
    end

    local scenario = coroutine.create(function()
        wait(0.5)
        for i = #UIManager._window_stack, 1, -1 do
            local widget = UIManager._window_stack[i].widget
            if getmetatable(widget) == InfoMessage then UIManager:close(widget) end
        end
        local plugin = assert(self.ui.koreadalong, "production plugin not loaded")
        check(plugin.remote and not plugin.coordinator, "remote source not restored")
        check(not package.loaded.mpvaudio and not package.loaded.kindleaudio, "local player was loaded")
        check(plugin.remote:getStatus().state == "idle", "book opening listened automatically")
        plugin.remote.port.options.address = "127.0.0.1"
        plugin.remote.port.options.mdns_port = tonumber(os.getenv("KOREADALONG_REMOTE_MDNS_PORT"))
        plugin:onShowReadAlongControls()
        wait(0.3)
        local panel = plugin.playback_dialog
        shot("remote-stopped")
        click(panel:getButtonById("listen"))
        check(panel.child, "Listen did not ask for trust")
        shot("remote-trust")
        click(find_button(panel.child, "Listen"))
        check(plugin.remote:getStatus().state == "listening", "Listen failed")
        log("listening=true no_local_player=true")

        -- Discover over a real legacy mDNS query; independently parse SRV/A.
        local name = string.char(#"_storyteller-lrs") .. "_storyteller-lrs\4_udp\5local\0"
        phone:sendto("\0\42\0\0\0\1" .. string.rep("\0", 6) .. name .. "\0\12\0\1",
            "127.0.0.1", plugin.remote.port.options.mdns_port)
        wait(0.3)
        local dns = assert(phone:receive(), "no discovery response")
        local function word(p) return dns:byte(p) * 256 + dns:byte(p + 1) end
        local function skip_name(p)
            while dns:byte(p) ~= 0 do p = p + 1 + dns:byte(p) end
            return p + 1
        end
        local p, port, host = skip_name(13) + 4
        for _ = 1, word(7) do
            p = skip_name(p)
            local kind, size = word(p), word(p + 8)
            p = p + 10
            if kind == 33 then port = word(p + 4) end
            if kind == 1 then host = table.concat({ dns:byte(p, p + 3) }, ".") end
            p = p + size
        end
        check(host == "127.0.0.1" and port, "invalid discovery address")
        log("discovery=PTR/SRV/A wire=true")
        local stamp = 1700000000
        local function send(path, fragment, options)
            options = options or {}
            stamp = stamp + 1
            local packet = {
                version = 1, senderID = options.sender or "simulated-phone",
                bookID = { sourceID = "smoke", uuid = options.book or "Chapter transition" },
                sectionIndex = 999, entryIndex = 999, -- deliberately foreign indexes
                textHref = path, textId = fragment, playbackRate = options.rate or 1, sentAt = stamp,
            }
            assert(phone:sendto(json.encode(packet), host, port))
        end
        local first, second = "OEBPS/text/frontmatter.xhtml", "OEBPS/text/chapter-one.xhtml"
        local function expect_text(text)
            local range = assert(plugin.remote:getCurrentRange(), "no narrated range")
            check(self.document:getTextFromXPointers(range.pos0, range.pos1) == text, "wrong CRe text")
            check(#plugin.overlay.boxes > 0, "no rendered mark boxes")
        end
        send(first, "front-one")
        wait(0.3)
        check(not plugin.remote:getCurrentRange(), "followed without explicit selection")
        panel:_refresh()
        wait(0.2)
        click(panel:getButtonById("choose"))
        check(panel.child.item_group[1], "empty phone chooser")
        shot("remote-chooser")
        click(panel.child.item_group[1])
        shot("remote-pairing")
        click(find_button(panel.child, "Follow"))
        expect_text("First narrated section")
        shot("remote-following")
        log("pairing=explicit anchor_mapping=true exact_text=true")

        click(panel:getButtonById("later"))
        check(plugin.remote:getStatus().correction == -0.25, "Later failed")
        send(first, "front-two")
        wait(0.12)
        expect_text("First narrated section")
        wait(0.4)
        expect_text("The fixture begins narration at spine index three.")
        shot("remote-later")
        log("delay=0.25 held_then_advanced=true")
        click(panel:getButtonById("reset"))
        click(panel:getButtonById("earlier"))
        check(panel.child and plugin.remote:getStatus().correction == 0, "Earlier skipped warning")
        shot("remote-estimate-warning")
        click(find_button(panel.child, "Use estimates"))
        check(plugin.remote:getStatus().correction == 0.25, "Earlier failed")
        shot("remote-earlier")
        click(panel:getButtonById("reset"))

        click(panel:getButtonById("follow"))
        check(plugin.follow_state == "browsing", "Follow off failed")
        local before = self.document:getXPointer()
        send(second, "chapter-one", { rate = 1.5 })
        wait(0.3)
        check(self.document:getXPointer() == before, "snapped back while browsing")
        shot("remote-browsing")
        click(panel:getButtonById("return_to_narration"))
        check(plugin.follow_state == "following", "return did not resume following")
        expect_text("Next narrated chapter")
        log("chapter_handoff=3_to_5 browse_no_snapback=true return=true rate=1.5")
        shot("remote-chapter")
        send(first, "front-one", { sender = "other-phone" })
        wait(0.2)
        expect_text("Next narrated chapter")
        send(second, "chapter-two", { book = "Different book" })
        wait(0.3)
        check(plugin.remote:getStatus().state == "mismatch", "book switch not detected")
        check(not plugin.remote:getCurrentRange() and #plugin.overlay.boxes == 0, "stale mismatch mark")
        panel:_refresh(); wait(0.2); shot("remote-mismatch")
        send(second, "chapter-two")
        wait(0.3)
        expect_text("Playback crossed a non-overlay spine item and continued here.")
        wait(5.1)
        check(plugin.remote:getStatus().state == "waiting", "silence not reported")
        expect_text("Playback crossed a non-overlay spine item and continued here.")
        panel:_refresh(); wait(0.2); shot("remote-waiting")
        log("wrong_phone=ignored wrong_book=cleared silence=no_free_run")

        click(panel:getButtonById("hide"))
        check(not plugin.playback_dialog and plugin.remote:isActive(), "Hide stopped follower")
        shot("remote-reading")
        plugin:onShowReadAlongControls()
        wait(0.3)
        panel = plugin.playback_dialog
        click(panel:getButtonById("stop"))
        check(plugin.remote:getStatus().state == "idle", "Stop failed")
        check(not plugin.remote:getStatus().host and #plugin.overlay.boxes == 0, "Stop leaked receiver/marks")
        shot("remote-stopped-final")
        -- A real exclusive bind simulates another mDNS service owning the port.
        local blocker = assert(socket.udp())
        assert(blocker:setsockname("0.0.0.0", plugin.remote.port.options.mdns_port))
        click(panel:getButtonById("listen"))
        click(find_button(panel.child, "Listen"))
        check(plugin.remote:getStatus().state == "error", "bind failure not reported")
        check(not plugin.remote:getStatus().host, "failed start leaked receiver")
        shot("remote-error")
        local error_dialog = UIManager._window_stack[#UIManager._window_stack].widget
        check(getmetatable(error_dialog) == InfoMessage, "missing network error message")
        click(error_dialog)
        blocker:close()
        click(panel:getButtonById("listen"))
        click(find_button(panel.child, "Listen"))
        check(plugin.remote:getStatus().state == "listening", "restart failed")
        log("startup_error=closed retry=true")
        self.ui:handleEvent(Event:new("Suspend"))
        check(plugin.remote:getStatus().state == "idle", "Suspend did not stop receiver")
        check(plugin.remote:setCorrection(-0.75), "correction not saved")
        check(plugin:setAudioSource("local"), "could not return to local audio")
        check(plugin.coordinator:getState() == "idle", "source switch started audio")
        check(plugin:setAudioSource("remote"), "could not return to phone audio")
        check(plugin.remote:getStatus().state == "idle", "source switch opened sockets")
        check(plugin.remote:getStatus().correction == -0.75, "source switch lost correction")
        plugin:onCloseDocument()
        check(plugin.remote:getStatus().state == "closed", "Close did not close source")
        log("hide_keeps_following=true stop_cleans=true restart=true suspend_cleans=true close=true")
        log("source_switch_no_autoplay=true correction_persisted=true")
        log("PASS")
    end)
    local function advance()
        local ok, delay = coroutine.resume(scenario)
        if not ok then
            print("REMOTE_SMOKE FAIL " .. tostring(delay) .. "\n" .. debug.traceback(scenario))
        end
        if not ok or coroutine.status(scenario) == "dead" then
            phone:close()
            x11.XCloseDisplay(display)
            UIManager:quit(ok and 0 or 1)
        else
            UIManager:scheduleIn(delay, advance)
        end
    end
    UIManager:scheduleIn(0.1, advance)
end

return Smoke
