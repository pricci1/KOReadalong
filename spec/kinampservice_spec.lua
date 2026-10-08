package.path = "./koreadalong.koplugin/?.lua;"
    .. ".cache/koreader/lib/koreader/?.lua;"
    .. ".cache/koreader/lib/koreader/common/?.lua;" .. package.path

local KinAMPService = require("kinampservice")
local ffi = require("ffi")
require("ffi/posix_h")
local lfs = require("lfs")
pcall(ffi.cdef, [[int chmod(const char *, unsigned int);]])

local function service(files)
    local calls = {}
    local pid
    local instance = KinAMPService.new{
        get_config = function() return { bin_folder = "/installed/KinAMP/" } end,
        exists = function(path) return files[path] == true end,
        running = function() return pid end,
        launch = function(...)
            calls[#calls + 1] = { ... }
            pid = 123
            return pid
        end,
    }
    return instance, calls, function(value) pid = value end
end

describe("KinAMP idle startup service", function()
    local saved_bluetooth, saved_devices, saved_loader
    before_each(function()
        saved_bluetooth = package.loaded.kinamp_bt
        saved_devices = package.loaded.kinamp_btdevices
        saved_loader = package.preload.kinamp_bt
    end)
    after_each(function()
        package.loaded.kinamp_bt = saved_bluetooth
        package.loaded.kinamp_btdevices = saved_devices
        package.preload.kinamp_bt = saved_loader
    end)

    it("recovers the official cached closed handle before checking output or opening settings", function()
        local devices, reloads = {}, 0
        package.loaded.kinamp_btdevices = devices
        package.loaded.kinamp_bt = { available = function() return false end }
        package.preload.kinamp_bt = function()
            reloads = reloads + 1
            return {
                available = function() return true end,
                getConnected = function() return {} end,
                getConnectedName = function() return nil end,
            }
        end
        local instance = KinAMPService.new()
        local ready, message = instance:checkOutput()
        assert.is_nil(ready)
        assert.are.equal("Bluetooth audio is not connected", message)
        assert.are.equal(1, reloads)
        assert.is_nil(package.loaded.kinamp_btdevices)
        package.loaded.kinamp_btdevices = devices
        assert.is_not_nil(instance.get_bluetooth())
        assert.are.equal(devices, package.loaded.kinamp_btdevices)
        assert.are.equal(1, reloads)
    end)

    it("attempts at most one refresh when the official API stays unavailable", function()
        local reloads = 0
        package.loaded.kinamp_bt = { available = function() return false end }
        package.preload.kinamp_bt = function()
            reloads = reloads + 1
            return { available = function() return false end }
        end
        assert.is_true(KinAMPService.new():checkOutput())
        assert.are.equal(1, reloads)
    end)

    it("requires Bluetooth only when the official API confirms no connected device", function()
        local connected, name = {}, nil
        local instance = KinAMPService.new{
            get_bluetooth = function()
                return {
                    available = function() return true end,
                    getConnected = function() return connected end,
                    getConnectedName = function() return name end,
                }
            end,
        }
        local ready, message = instance:checkOutput()
        assert.is_nil(ready)
        assert.are.equal("Bluetooth audio is not connected", message)
        connected = { { name = "Headphones" } }
        assert.is_true(instance:checkOutput())
        connected, name = {}, "Headphones"
        assert.is_true(instance:checkOutput())
        connected, name = nil, nil
        assert.is_true(instance:checkOutput())
    end)

    it("does not mistake unavailable Bluetooth reporting for a confirmed disconnection", function()
        for _, bluetooth in ipairs{
            false,
            {},
            { available = function() return false end },
            { available = function() error("unsupported firmware") end,
                getConnected = function() return {} end,
                getConnectedName = function() return nil end },
        } do
            local instance = KinAMPService.new{ get_bluetooth = function() return bluetooth end }
            assert.is_true(instance:checkOutput())
        end
    end)

    it("executes only idle startup with the installation working directory and quoted paths", function()
        local root = os.tmpname()
        os.remove(root)
        root = root .. " with 'quotes"
        assert(lfs.mkdir(root))
        local binary = root .. "/KinAMP-minimal-pw2"
        local file = assert(io.open(binary, "w"))
        file:write([[#!/bin/sh
printf '%s\n' "$PWD" "$LD_LIBRARY_PATH" "$KINAMP_RUNTIME_DIR" "$1" > "$KINAMP_RUNTIME_DIR/result.tmp"
mv "$KINAMP_RUNTIME_DIR/result.tmp" "$KINAMP_RUNTIME_DIR/result"
]])
        file:close()
        assert(ffi.C.chmod(binary, 448) == 0)
        local instance = KinAMPService.new{
            get_config = function() return { bin_folder = root } end,
            exists = function(path) return path == binary end,
            running = function() return false end,
        }
        local success, error_message = pcall(function()
            assert.is_true(instance:start(root))
            local output
            for _ = 1, 1000 do
                output = io.open(root .. "/result", "r")
                if output then break end
                ffi.C.usleep(1000)
            end
            assert(output, "idle process did not publish test result")
            local actual = output:read("*a")
            output:close()
            assert.are.equal(root .. "\n" .. root .. "/libs_pw2\n" .. root .. "\n--idle\n", actual)
        end)
        os.remove(root .. "/result.tmp")
        os.remove(root .. "/result")
        os.remove(binary)
        lfs.rmdir(root)
        assert(success, error_message)
    end)

    it("uses the installed armhf 0.10 binary without invoking a destructive launcher", function()
        local instance, calls = service{
            ["/lib/ld-linux-armhf.so.3"] = true,
            ["/usr/lib/libgstreamer-0.10.so.0"] = true,
            ["/lib/libgstreamer-1.0.so.0"] = true,
            ["/installed/KinAMP/KinAMP-minimal"] = true,
            ["/installed/KinAMP/KinAMP-minimal-gst"] = true,
        }
        assert.is_true(instance:start("/tmp/test-runtime"))
        assert.are.same({{
            "/installed/KinAMP", "/installed/KinAMP/KinAMP-minimal",
            "/installed/KinAMP/libs_hf", "/tmp/test-runtime",
        }}, calls)
        assert.are.equal(123, instance.started_pid)
        assert.is_true(instance:start("/tmp/test-runtime"))
        assert.are.equal(1, #calls)
        assert.are.equal(123, instance.started_pid)
    end)

    it("selects installed armhf 1.0 or armel flavours", function()
        local gst, gst_calls = service{
            ["/lib/ld-linux-armhf.so.3"] = true,
            ["/lib/libgstreamer-1.0.so.0"] = true,
            ["/installed/KinAMP/KinAMP-minimal-gst"] = true,
        }
        assert.is_true(gst:start("/tmp"))
        assert.are.equal("/installed/KinAMP/KinAMP-minimal-gst", gst_calls[1][2])
        assert.are.equal("/installed/KinAMP/libs_hf", gst_calls[1][3])
        local armel, armel_calls = service{ ["/installed/KinAMP/KinAMP-minimal-pw2"] = true }
        assert.is_true(armel:start("/tmp"))
        assert.are.equal("/installed/KinAMP/KinAMP-minimal-pw2", armel_calls[1][2])
        assert.are.equal("/installed/KinAMP/libs_pw2", armel_calls[1][3])
    end)

    it("waits for an existing process with broken or not-yet-ready IPC instead of replacing it", function()
        local instance, calls, set_pid = service{}
        set_pid(456)
        assert.is_true(instance:start("/tmp"))
        assert.is_nil(instance.started_pid)
        assert.are.equal(0, #calls)
    end)

    it("reports missing installation and launch failures without touching another process", function()
        local instance, calls = service{}
        local started, message = instance:start("/tmp")
        assert.is_nil(started)
        assert.matches("player is missing", message)
        instance.get_config = function() return nil end
        started, message = instance:start("/tmp")
        assert.is_nil(started)
        assert.matches("Install and enable", message)
        assert.are.equal(0, #calls)
        instance.get_config = function() return { bin_folder = "/installed/KinAMP" } end
        instance.exists = function() return true end
        instance.launch = function() return nil, "fork failed" end
        started, message = instance:start("/tmp")
        assert.is_nil(started)
        assert.are.equal("fork failed", message)
        assert.is_nil(instance.started_pid)
    end)
end)

describe("KinAMP read-along ownership receipts", function()
    it("recovers only a dead reader's exact resource in the same daemon generation", function()
        local identities = { [11] = "11:101", [22] = "22:202" }
        local files = {}
        local instance = KinAMPService.new{
            reader_pid = 11,
            process_identity = function(pid) return identities[pid] end,
            read_file = function(path) return files[path] end,
            write_file = function(path, bytes) files[path] = bytes; return true end,
        }
        local status = { pid = 22, path = "/private/audio.m4a", index = 0, count = 1, mode = "music" }
        assert.is_true(instance:remember("/tmp", status, status.path, "/tmp/private.m3u"))
        assert.is_false(instance:isOrphan("/tmp", status))
        identities[11] = false
        assert.is_true(instance:isOrphan("/tmp", status))
        identities[11] = "11:303" -- Reader PID reused: the recorded reader is dead.
        assert.is_true(instance:isOrphan("/tmp", status))
        identities[11] = nil -- Inaccessible metadata is not evidence of death.
        assert.is_false(instance:isOrphan("/tmp", status))
        identities[11] = false
        for key, value in pairs{ pid = 23, path = "/another/audio.m4a", index = 1,
            count = 2, mode = "radio" } do
            local previous = status[key]
            status[key] = value
            assert.is_false(instance:isOrphan("/tmp", status))
            status[key] = previous
        end
        identities[22] = "22:404" -- Daemon PID reused: never stop the replacement.
        assert.is_false(instance:isOrphan("/tmp", status))
        files["/tmp/koreadalong-kinamp-owner"] = "corrupt\n"
        assert.is_false(instance:isOrphan("/tmp", status))
    end)

    it("forgets only this live reader's exact playlist receipt", function()
        local bytes, removed
        local identity = "11:101"
        local instance = KinAMPService.new{
            reader_pid = 11,
            process_identity = function(pid) return pid == 11 and identity or "22:202" end,
            read_file = function() return bytes end,
            write_file = function(_, value) bytes = value; return true end,
            remove_file = function(path) removed = path; bytes = nil; return true end,
        }
        assert.is_true(instance:remember("/runtime", { pid = 22 }, "/audio", "/playlist"))
        assert.is_true(instance:forget("/runtime", "/another"))
        assert.is_nil(removed)
        identity = "11:303"
        assert.is_true(instance:forget("/runtime", "/playlist"))
        assert.is_nil(removed)
        identity = "11:101"
        assert.is_true(instance:forget("/runtime", "/playlist"))
        assert.are.equal("/runtime/koreadalong-kinamp-owner", removed)
    end)

    it("removes only confirmed stopped orphan files, without recursive directory cleanup", function()
        local root = os.tmpname()
        os.remove(root)
        root = "/tmp/koreadalong-" .. root:match("([^/]+)$"):gsub("%W", "")
        assert(lfs.mkdir(root))
        local audio = root .. "/audio-old.wav"
        local playlist = root .. "/koreadalong-kinamp-old.m3u"
        for _, path in ipairs{ audio, playlist, root .. "/unrelated" } do
            assert(io.open(path, "w")):close()
        end
        local identities = { [11] = "11:101", [22] = "22:202" }
        local instance = KinAMPService.new{
            reader_pid = 11,
            process_identity = function(pid) return identities[pid] end,
        }
        local success, message = pcall(function()
            local status = { pid = 22, path = audio, index = 0, count = 1,
                mode = "music", state = "playing" }
            assert.is_true(instance:remember(root, status, audio, playlist))
            identities[11] = false
            assert.is_true(instance:releaseOrphan(root, status))
            assert.is_not_nil(lfs.attributes(audio))
            status.state = "stopped"
            assert.is_true(instance:releaseOrphan(root, status))
            assert.is_nil(lfs.attributes(audio))
            assert.is_nil(lfs.attributes(playlist))
            assert.is_nil(lfs.attributes(root .. "/koreadalong-kinamp-owner"))
            assert.is_not_nil(lfs.attributes(root .. "/unrelated"))
        end)
        for _, path in ipairs{ audio, playlist, root .. "/unrelated",
            root .. "/koreadalong-kinamp-owner", root .. "/koreadalong-kinamp-owner.new" } do
            os.remove(path)
        end
        lfs.rmdir(root)
        assert(success, message)
    end)

    it("atomically persists real Linux process start identities and removes the receipt", function()
        local root = os.tmpname()
        os.remove(root)
        assert(lfs.mkdir(root))
        local instance = KinAMPService.new()
        local pid = tonumber(ffi.C.getpid())
        local pipe = assert(io.popen("awk '{print $22}' /proc/" .. pid .. "/stat"))
        local start = pipe:read("*l")
        pipe:close()
        local success, message = pcall(function()
            assert.are.equal(pid .. ":" .. start, instance.process_identity(pid))
            assert.is_false(instance.process_identity(2147483647))
            assert.is_true(instance:remember(root, { pid = pid }, "/audio", "/playlist"))
            local file = assert(io.open(root .. "/koreadalong-kinamp-owner"))
            assert.are.equal(pid .. ":" .. start .. "\n" .. pid .. ":" .. start
                .. "\n/audio\n/playlist\n", file:read("*a"))
            file:close()
            assert.is_true(instance:forget(root, "/playlist"))
        end)
        os.remove(root .. "/koreadalong-kinamp-owner")
        os.remove(root .. "/koreadalong-kinamp-owner.new")
        lfs.rmdir(root)
        assert(success, message)
    end)
end)
