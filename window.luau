-- Explicit local-host launches; PowerShell's marker is handled by host.luau.
local HOME = "\\\\wsl.localhost\\Ubuntu\\home\\jtar-wsl"
local GROUP = "WSL Helper"
local cachedHost = nil
local diagnosing = false
local MARKER = "__TERN_WSL_HELPER_NATIVE_POWERSHELL_02__"

local function openPowerShell(cx)
    cx.hosts:terminal("local", {cwd = tern.getenv("USERPROFILE") or "C:\\Users\\nalon", command = MARKER})
end

local function chooseShell(cx)
    cx:pick({placeholder = "New local tab — choose a shell", action = "open", items = {
        {label = "Ubuntu WSL", detail = "Ubuntu / jtar-wsl", shell = "wsl"},
        {label = "Windows PowerShell", detail = "Native Windows shell", shell = "powershell"},
    }}):next(function(item, err, fresh)
        if not fresh then return end
        if err then fresh:toast("error", "Could not open shell chooser", err) return end
        if not item then return end
        if item.shell == "powershell" then openPowerShell(fresh)
        else fresh.hosts:terminal("local", {cwd = HOME}) end
    end)
end

tern.command({id = "choose", title = "New tab: Choose WSL or Windows PowerShell", group = GROUP,
    run = chooseShell})
tern.command({id = "powershell", title = "Windows: Open PowerShell tab", group = GROUP,
    run = openPowerShell})

-- The ordinary local new-tab action (+ and Ctrl+Shift+T) now asks which shell.
tern.override("new_tab", function(cx)
    if cx.hosts:current().kind ~= "local" then return false end
    chooseShell(cx)
    return true
end)

tern.chrome.tab_title(function(tab)
    if tab.name == MARKER or tab.title:find(MARKER, 1, true) then return "Windows PowerShell" end
    return nil
end)

local function present(cx, title, lines)
    local report = title .. "\n" .. table.concat(lines, "\n")
    local items = {{label = "Copy full report", detail = title, copy = report}}
    for _, line in ipairs(lines) do
        if line ~= "" then
            table.insert(items, {label = line, copy = line})
        end
    end
    cx:pick({placeholder = title, action = "copy", items = items}):next(function(item, err, fresh)
        if fresh and item then
            fresh:copy(item.copy)
            fresh:toast("info", "Copied to clipboard")
        elseif fresh and err then
            fresh:toast("error", "Could not show report", err)
        end
    end)
end

local function refresh(cx)
    local host = cx.hosts:current()
    local signature = table.concat({tostring(host.id), host.name, host.kind, host.state,
        host.rtt_ms and tostring(math.floor(host.rtt_ms + 0.5)) or ""}, "|")
    if not cachedHost or cachedHost.signature ~= signature then
        cachedHost = {signature = signature, value = host}
        tern.chrome.refresh()
    end
end

tern.chrome.status(function(pane)
    if not cachedHost then return nil end
    local host = cachedHost.value
    if host.kind == "remote" then
        local label = host.name .. " / " .. host.state
        if host.rtt_ms then label ..= string.format(" / %.0f ms", host.rtt_ms) end
        return {{text = label, command = "plugin.wsl-helper.hosts",
            tone = host.state == "connected" and "muted" or "error"}}
    end
    local program = (pane.program or ""):lower()
    if program:find("powershell", 1, true) or program:find("pwsh", 1, true) then
        return {{text = "Windows / PowerShell", tone = "muted", command = "plugin.wsl-helper.choose"}}
    end
    local cwd = (pane.cwd or ""):lower()
    if (pane.kind == "terminal" or pane.kind == "agent") and
        (cwd:sub(1, 6) == "/home/" or cwd:find("wsl.localhost\\ubuntu\\", 1, true)) then
        return {{text = "WSL / Ubuntu", tone = "muted", command = "plugin.wsl-helper.diagnose"}}
    end
    return nil
end)

tern.command({id = "home", title = "WSL: Open Ubuntu home", group = GROUP,
    run = function(cx)
        cx.hosts:terminal("local", {cwd = HOME})
    end})

tern.command({id = "omarchy", title = "WSL: SSH to Omarchy over LAN", group = GROUP,
    run = function(cx)
        -- The local host's configured shell is WSL. SSH keeps interactive passphrase entry.
        cx.hosts:terminal("local", {cwd = HOME, command = "ssh omarchy"})
    end})

tern.command({id = "hosts", title = "WSL: Show Tern connection health", group = GROUP,
    run = function(cx)
        local lines = {"Tern native connections; separate from an ssh command inside WSL."}
        for _, host in ipairs(cx.hosts:list()) do
            local rtt = host.rtt_ms and string.format("%.1f ms", host.rtt_ms) or "not reported"
            table.insert(lines, string.format("%s: %s / %s / RTT %s", host.name, host.kind, host.state, rtt))
            if host.address then table.insert(lines, "Address: " .. host.address) end
            if host.detail and host.detail.error then table.insert(lines, "Error: " .. host.detail.error) end
        end
        present(cx, "Tern connection health", lines)
    end})

local DIAGNOSTIC = [[
printf 'Distribution: %s\n' "$WSL_DISTRO_NAME"
printf 'User: %s\n' "$(id -un)"
printf 'Home: %s\n' "$HOME"
printf 'Shell: %s\n' "$(getent passwd "$(id -un)" | cut -d: -f7)"
printf 'Kernel: %s\n' "$(uname -r)"
for tool in ssh git node npm python3 cargo; do
  path=$(command -v "$tool" 2>/dev/null)
  printf '%s: %s\n' "$tool" "${path:-not installed}"
done
printf '\nOmarchy SSH configuration (not an authentication test):\n'
ssh -G omarchy 2>/dev/null | sed -n '/^hostname /p; /^user /p; /^controlmaster /p; /^controlpersist /p'
printf '\nLAN probe to Omarchy:\n'
ping -n -c 3 -W 1 192.168.2.20
]]

tern.command({id = "diagnose", title = "WSL: Diagnose Ubuntu and Omarchy", group = GROUP,
    run = function(cx)
        if diagnosing then
            cx:toast("info", "WSL diagnostics are already running")
            return
        end
        diagnosing = true
        cx:toast("info", "Checking Ubuntu and LAN connectivity…")
        local ok, err = pcall(function()
            tern.process.run({"wsl.exe", "--distribution", "Ubuntu", "--user", "jtar-wsl",
                "--exec", "/bin/bash", "-lc", DIAGNOSTIC}, {timeout_ms = 12000}, function(result, fresh)
                diagnosing = false
                if not fresh then return end
                local lines = {}
                for line in result.stdout:gmatch("[^\r\n]+") do table.insert(lines, line) end
                if result.status ~= 0 then
                    table.insert(lines, result.timed_out and "Diagnostic timed out" or "One or more checks failed")
                    for line in result.stderr:gmatch("[^\r\n]+") do table.insert(lines, line) end
                end
                present(fresh, "Ubuntu WSL diagnostics", lines)
            end)
        end)
        if not ok then
            diagnosing = false
            cx:toast("error", "Could not start WSL diagnostics", tostring(err))
        end
    end})

-- Reads Tern's cached connection metadata; no network probing or subprocess polling.
local function tick(cx)
    if cx then refresh(cx) end
    tern.timer(5000, tick)
end
tern.on("window_start", function(cx) refresh(cx) end)
tern.on("focus", function(_, cx) refresh(cx) end)
tern.timer(0, tick)
