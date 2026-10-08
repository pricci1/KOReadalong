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
