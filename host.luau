-- Only our explicit launcher marker changes the spawned program.
local MARKER = "__TERN_WSL_HELPER_NATIVE_POWERSHELL_02__"
tern.on("spawn", function(spec)
    local selected = spec.program == MARKER
    for _, arg in ipairs(spec.args) do
        if arg:find(MARKER, 1, true) then selected = true end
    end
    if not selected then return nil end
    local windows = tern.getenv("SystemRoot") or "C:\\Windows"
    spec.program = windows .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
    spec.args = {"-NoLogo"}
    spec.cwd = tern.getenv("USERPROFILE") or "C:\\Users\\nalon"
    return spec
end)
