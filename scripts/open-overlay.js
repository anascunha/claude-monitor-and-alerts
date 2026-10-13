// Copies the overlay files to ~/.claude-monitor and starts the floating window.
// Windows: overlay.ps1 (PowerShell/WPF). macOS: overlay.swift, compiled on first run.
// The overlay itself keeps a single instance (lock in ~/.claude-monitor).
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync, spawn } = require("child_process");

let MONITOR_DIR = path.join(os.homedir(), ".claude-monitor");
const IS_WSL = process.platform === "linux" && (!!process.env.WSL_DISTRO_NAME || /microsoft/i.test(os.release()));
const SOURCE_DIR = path.join(__dirname, "overlay");
const MAC_BINARY = path.join(MONITOR_DIR, "ClaudeMonitor");
const FILES = {
    win32: ["overlay.ps1"],
    darwin: ["overlay.swift"],
};

function fail(message) {
    console.error(`claude-monitor: ${message}`);
    process.exit(1);
}

function copyOverlayFiles(files) {
    fs.mkdirSync(path.join(MONITOR_DIR, "sessions"), { recursive: true, mode: 0o700 });
    let changed = false;
    for (const file of files) {
        const source = path.join(SOURCE_DIR, file);
        const target = path.join(MONITOR_DIR, file);
        // untouched files keep their mtime: a running window closes itself when its file changes
        try {
            if (fs.readFileSync(source).equals(fs.readFileSync(target))) continue;
        } catch {
            // target missing
        }
        fs.copyFileSync(source, target);
        const now = new Date();
        fs.utimesSync(target, now, now);
        changed = true;
    }
    return changed;
}

function compileMac() {
    const source = path.join(MONITOR_DIR, "overlay.swift");
    try {
        if (fs.statSync(MAC_BINARY).mtimeMs >= fs.statSync(source).mtimeMs) return;
    } catch {
        // not compiled yet
    }
    try {
        execFileSync("xcode-select", ["-p"], { stdio: "ignore" });
    } catch {
        fail("macOS command line tools are missing. Run `xcode-select --install`, then try again.");
    }
    const temp = `${MAC_BINARY}.${process.pid}.new`;
    console.log("claude-monitor: compiling the window (first run only)...");
    try {
        execFileSync("xcrun", ["swiftc", "-swift-version", "5", "-O", "-o", temp, source], {
            stdio: "inherit",
            timeout: 300000,
        });
    } catch (err) {
        fail(`could not compile the window: ${err.message}`);
    }
    fs.renameSync(temp, MAC_BINARY);
}

/**
 * WSL: the window runs on Windows, so the files go to the Windows profile's .claude-monitor
 * (the folder the window and the hooks use) and are started through cmd.exe.
 * Returns the Windows form of that folder; MONITOR_DIR becomes its /mnt/... form.
 */
function useWindowsProfile() {
    let winDir;
    try {
        const profile = execFileSync("cmd.exe", ["/c", "echo %USERPROFILE%"], { cwd: "/mnt/c", encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"] }).trim();
        // strict whitelist: this string ends up on the cmd.exe command line, so no cmd metacharacters (& | ^ < > ( ) ! % quotes)
        if (!/^[A-Za-z]:(\\[A-Za-z0-9_.-]+)+$/.test(profile) || profile.split("\\").includes("..")) fail("unexpected Windows profile path (only letters, digits, '_', '.', '-' are supported).");
        winDir = `${profile}\\.claude-monitor`;
        const linuxDir = execFileSync("wslpath", ["-u", winDir], { encoding: "utf8", timeout: 5000 }).trim();
        if (!/^\/mnt\/[a-z]\/[^\0]+$/.test(linuxDir) || linuxDir.split("/").includes("..")) fail("unexpected Windows profile path.");
        MONITOR_DIR = linuxDir;
    } catch (err) {
        fail(`could not find the Windows profile (${err.message.split("\n")[0]})`);
    }
    return winDir;
}

const files = FILES[IS_WSL ? "win32" : process.platform];
if (!files) fail(`${process.platform} is not supported (Windows, WSL and macOS only).`);
const windowsDir = IS_WSL ? useWindowsProfile() : null;

let changed = false;
try {
    changed = copyOverlayFiles(files);
} catch (err) {
    fail(`could not copy the overlay files: ${err.message}`);
}

function launch() {
    if (IS_WSL) {
        spawn(
            "cmd.exe",
            ["/c", "start", '""', "/min", "powershell.exe", "-WindowStyle", "Hidden", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", `${windowsDir}\\overlay.ps1`],
            { cwd: "/mnt/c", detached: true, stdio: "ignore" },
        )
            .on("error", (err) => fail(`could not start the window: ${err.message}`))
            .unref();
    } else if (process.platform === "win32") {
        // via "cmd start": a PowerShell started directly with detached dies immediately
        const ps1 = path.join(MONITOR_DIR, "overlay.ps1");
        spawn(
            "cmd.exe",
            ["/c", "start", '""', "/min", "powershell.exe", "-WindowStyle", "Hidden", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1],
            { detached: true, stdio: "ignore", windowsHide: true },
        ).unref();
    } else {
        compileMac();
        spawn(MAC_BINARY, [], { detached: true, stdio: "ignore" }).unref();
    }
    console.log("claude-monitor: window opened (bottom-right corner of the screen).");
}

// A window that is already open closes itself within ~2 s when its files change; wait for it,
// otherwise the new one finds the old one still running and exits.
if (changed) {
    console.log("claude-monitor: updating the window...");
    setTimeout(launch, 4000);
} else {
    launch();
}
