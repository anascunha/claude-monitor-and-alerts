"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
/**
 * Hook do Claude Code (UserPromptSubmit, Stop, Notification, SessionEnd).
 * Script Node standalone — não importa nada do VSCode. A extensão copia ele
 * pra ~/.claude-monitor/hook.js e registra no ~/.claude/settings.json.
 *
 * Lê o JSON do stdin e grava ~/.claude-monitor/sessions/<session_id>.json
 *
 * Uso: node hook.js <working|waiting|notification|end>
 *   notification -> vira "permission" se for pedido de permissão, senão "waiting"
 *   end          -> apaga o arquivo da sessão
 */
const fs = __importStar(require("fs"));
const os = __importStar(require("os"));
const path = __importStar(require("path"));
const processes_1 = require("./processes");
const { execFileSync } = require("child_process");
const SESS_DIR = path.join(os.homedir(), ".claude-monitor", "sessions");
/**
 * WSL: the floating window runs on Windows and reads the Windows profile's
 * .claude-monitor, so sessions started inside WSL must be written there. Only used when that
 * folder already exists (the window was opened at least once); otherwise the Linux folder.
 * The Windows path is resolved once (cmd.exe is slow) and cached in ~/.claude-monitor/winpath.
 */
function windowsSessionsDir() {
    if (!process.env.WSL_DISTRO_NAME && !/microsoft/i.test(os.release()))
        return null;
    const cache = path.join(os.homedir(), ".claude-monitor", "winpath");
    const failMarker = `${cache}.fail`;
    // only ever accept <drive-mount>/.../.claude-monitor, already normalized, no control chars
    const valid = (d) => /^\/mnt\/[a-z]\/[^\0\r\n]+\/\.claude-monitor$/.test(d) && path.posix.normalize(d) === d && !d.split("/").includes("..");
    const usable = (d) => {
        try {
            const st = fs.lstatSync(d);
            return st.isDirectory() && !st.isSymbolicLink();
        }
        catch {
            return false;
        }
    };
    let dir = "";
    try {
        dir = fs.readFileSync(cache, "utf8").trim();
    }
    catch {
        // not resolved yet
    }
    if (!valid(dir)) {
        dir = "";
        // negative cache: after a failed resolution do not retry (cmd.exe is slow) for 10 min
        try {
            if (Date.now() - fs.statSync(failMarker).mtimeMs < 600000)
                return null;
        }
        catch {
            // no marker
        }
        try {
            const opts = { cwd: "/mnt/c", encoding: "utf8", timeout: 3000, stdio: ["ignore", "pipe", "ignore"] };
            const profile = execFileSync("cmd.exe", ["/c", "echo %USERPROFILE%"], opts).trim();
            if (/^[A-Za-z]:\\[^\0\r\n]*$/.test(profile)) {
                const resolved = execFileSync("wslpath", ["-u", `${profile}\\.claude-monitor`], opts).trim();
                if (valid(resolved))
                    dir = resolved;
            }
            fs.mkdirSync(path.dirname(cache), { recursive: true, mode: 0o700 });
            if (dir)
                fs.writeFileSync(cache, dir, { mode: 0o600 });
            else
                fs.writeFileSync(failMarker, "", { mode: 0o600 });
        }
        catch {
            try {
                fs.mkdirSync(path.dirname(cache), { recursive: true, mode: 0o700 });
                fs.writeFileSync(failMarker, "", { mode: 0o600 });
            }
            catch {
                // ignore
            }
            return null;
        }
    }
    if (!dir || !usable(dir))
        return null;
    return path.join(dir, "sessions");
}
const SHELLS = new Set(["sh", "bash", "zsh", "dash", "fish", "cmd", "powershell", "pwsh", "conhost"]);
function readStdin() {
    try {
        return JSON.parse(fs.readFileSync(0, "utf8"));
    }
    catch {
        return {};
    }
}
/**
 * PID do processo do Claude. O Claude exporta CLAUDE_PID; se não vier, sobe
 * a árvore: o primeiro ancestral chamado "claude" ou, na falta dele (instalação
 * via npm roda como node), o primeiro que não é shell.
 */
function findClaudePid() {
    const fromEnv = Number(process.env.CLAUDE_PID);
    if (fromEnv)
        return fromEnv;
    const table = (0, processes_1.processTable)();
    if (!table)
        return null;
    let firstNonShell = null;
    let pid = table.get(process.pid)?.ppid;
    for (let i = 0; pid && i < 15; i++) {
        const proc = table.get(pid);
        if (!proc)
            break;
        if (proc.name === "claude")
            return pid;
        if (firstNonShell === null && !SHELLS.has(proc.name))
            firstNonShell = pid;
        pid = proc.ppid;
    }
    return firstNonShell;
}
/**
 * O /rename grava "custom-title" no transcript; o título automático é o
 * "ai-title". O do /rename ganha. Pega sempre o mais recente.
 */
function getTitle(transcript, sessionId) {
    let custom;
    let ai;
    try {
        for (const line of fs.readFileSync(transcript, "utf8").split("\n")) {
            if (!line.includes('"custom-title"') && !line.includes('"ai-title"'))
                continue;
            try {
                const obj = JSON.parse(line);
                if ((obj.sessionId ?? sessionId) !== sessionId)
                    continue;
                if (obj.type === "custom-title")
                    custom = obj.customTitle || custom;
                else if (obj.type === "ai-title")
                    ai = obj.aiTitle || ai;
            }
            catch {
                // linha quebrada
            }
        }
    }
    catch {
        // sem transcript
    }
    return custom || ai;
}
/**
 * Notification dispara tanto pra pedido de permissão quanto pro aviso de
 * "tá ocioso há 60s". Só o primeiro é urgente.
 */
function notificationState(data) {
    const kind = String(data.notification_type || "").toLowerCase();
    const message = String(data.message || "").toLowerCase();
    if (kind.includes("permission") || message.includes("permission") || kind.includes("elicitation")) {
        return "permission";
    }
    return "waiting";
}
/**
 * Subagents of a session, kept in the session file as a list of { id, type, since, updated }.
 * Entries older than 2 h are dropped (a missed SubagentStop must not leave a ghost row) and the
 * list is capped, so a runaway session cannot grow the file.
 */
/**
 * What a subagent is doing: the `description` Claude Code stores in the agent's meta file. Only
 * regular files under ~/.claude/projects are read, and only their head.
 */
function insideProjects(file) {
    try {
        const root = fs.realpathSync(path.join(os.homedir(), ".claude", "projects"));
        const real = fs.realpathSync(file);
        return real.startsWith(root + path.sep) && fs.statSync(real).isFile();
    }
    catch {
        return false;
    }
}
function readSlice(file, fromEnd, bytes) {
    const fd = fs.openSync(file, "r");
    try {
        const size = fs.fstatSync(fd).size;
        const len = Math.min(size, bytes);
        const buf = Buffer.alloc(len);
        fs.readSync(fd, buf, 0, len, fromEnd ? size - len : 0);
        return buf.toString("utf8");
    }
    finally {
        fs.closeSync(fd);
    }
}
function textOf(content) {
    if (typeof content === "string")
        return content;
    if (Array.isArray(content))
        return content.map((c) => (c && typeof c.text === "string" ? c.text : "")).join("");
    return "";
}
function cleanText(text, max) {
    return String(text || "").replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim().slice(0, max);
}
function sleepMs(ms) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}
function describeSubagent(data, sessionId, agentId, lastResort) {
    try {
        const parent = data.transcript_path;
        if (typeof parent !== "string" || !insideProjects(parent))
            return "";
        // Claude Code writes agent-<id>.meta.json ({ agentType, description, ... }) next to the
        // subagent transcript, but only after SubagentStart returns: callers retry (see describeLater).
        // It is keyed by the agent id, so it stays exact even when two subagents share a prompt.
        const folder = path.join(path.dirname(parent), sessionId, "subagents");
        const meta = path.join(folder, `agent-${agentId}.meta.json`);
        if (insideProjects(meta)) {
            const text = cleanText(JSON.parse(readSlice(meta, false, 64 * 1024)).description, 160);
            if (text)
                return text;
        }
        // last resort, only after waiting for the meta file: the first line of the agent's own prompt
        const own = path.join(folder, `agent-${agentId}.jsonl`);
        if (lastResort && insideProjects(own)) {
            const first = readSlice(own, false, 256 * 1024).split("\n")[0];
            return cleanText(textOf(JSON.parse(first).message?.content).split("\n")[0], 120);
        }
    }
    catch {
        // description is optional
    }
    return "";
}
/**
 * SubagentStart fires before the subagent's files exist, so the description is filled in afterwards
 * by a short detached process (this same script, event "subagent-describe") that waits up to 15 s
 * for it and then patches the session file. The hook itself returns immediately.
 */
function spawnDescriber(sessionId, agentId, transcript) {
    try {
        require("child_process")
            .spawn(process.execPath, [__filename, "subagent-describe", sessionId, agentId, String(transcript || "")], { detached: true, stdio: "ignore", windowsHide: true })
            .unref();
    }
    catch {
        // the row just keeps showing the agent type
    }
}
function describeLater(sessionId, agentId, transcript) {
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(sessionId || "") || !/^[A-Za-z0-9_.:-]{1,128}$/.test(agentId || ""))
        return;
    const sessDir = windowsSessionsDir() || SESS_DIR;
    const file = path.join(sessDir, `${sessionId}.json`);
    for (let waited = 0; waited <= 15000; waited += 100) {
        const desc = describeSubagent({ transcript_path: transcript }, sessionId, agentId, waited >= 15000);
        if (desc) {
            withLock(file, () => {
                let session;
                try {
                    session = JSON.parse(fs.readFileSync(file, "utf8"));
                }
                catch {
                    return;
                }
                const entry = (session.subagents || []).find((a) => a && a.id === agentId);
                if (entry && !entry.desc) {
                    entry.desc = desc;
                    writeSession(file, session);
                }
            });
            return;
        }
        sleepMs(100);
    }
}
const SUBAGENT_TTL_SEC = 2 * 3600;
const SUBAGENT_MAX = 12;
function pruneSubagents(list, now) {
    if (!Array.isArray(list))
        return [];
    return list
        .filter((a) => a && typeof a.id === "string" && now - Number(a.updated || 0) < SUBAGENT_TTL_SEC)
        .slice(0, SUBAGENT_MAX);
}
function cleanAgentType(type) {
    return String(type || "agent").replace(/[^A-Za-z0-9 ._:-]/g, "").slice(0, 40) || "agent";
}
/**
 * Serializes the read-modify-write of a session file between hook processes (two subagents ending
 * together used to overwrite each other's update). A lock file created with O_EXCL; a lock older than
 * 5 s is considered stale. If locking is impossible the update goes ahead unlocked.
 */
function withLock(file, fn) {
    const lock = `${file}.lock`;
    let held = false;
    for (let attempt = 0; attempt < 250 && !held; attempt++) {
        try {
            fs.closeSync(fs.openSync(lock, "wx", 0o600));
            held = true;
        }
        catch (err) {
            if (err.code !== "EEXIST")
                break;
            try {
                if (Date.now() - fs.statSync(lock).mtimeMs > 5000)
                    fs.rmSync(lock, { force: true });
            }
            catch {
                // somebody else released it
            }
            sleepMs(20);
        }
    }
    try {
        return fn();
    }
    finally {
        if (held) {
            try {
                fs.rmSync(lock, { force: true });
            }
            catch {
                // already gone
            }
        }
    }
}
function writeSession(file, session) {
    // write next to the target and rename: the overlay never reads a half-written file
    const temp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(temp, JSON.stringify(session), { mode: 0o600 });
    fs.renameSync(temp, file);
}
function main() {
    const event = process.argv[2] || "waiting";
    if (event === "subagent-describe") {
        describeLater(process.argv[3], process.argv[4], process.argv[5]);
        return;
    }
    const data = readStdin();
    // A subagent finishing its turn must not mark the whole session as finished: its hook input
    // carries "agent_id" (same rule as play_beep.sh). Permission/question notifications still count.
    if ((event === "waiting" || event === "question") && data.agent_id)
        return;
    // PostToolUse: a tool ran, so an approved permission or an answered question is over. No hook
    // fires on the approval itself, and the window cannot read WSL transcripts to notice it.
    if (event === "resume" && data.agent_id)
        return;
    const sessionId = data.session_id;  // no id, no session: nothing is written
    // the id becomes a file name: reject anything that could leave SESS_DIR
    if (typeof sessionId !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(sessionId))
        return;
    const winDir = windowsSessionsDir();
    const sessDir = winDir || SESS_DIR;
    fs.mkdirSync(sessDir, { recursive: true, mode: 0o700 });
    const file = path.join(sessDir, `${sessionId}.json`);
    if (event === "end") {
        fs.rmSync(file, { force: true });
        return;
    }
    // one hook process at a time per session file: read, change and write happen under the lock
    withLock(file, () => {
        let previous = {};
        try {
            previous = JSON.parse(fs.readFileSync(file, "utf8"));
        }
        catch {
            // primeira vez dessa sessão
        }
        const now = Date.now() / 1000;
        if (event === "subagent-start" || event === "subagent-stop") {
            // The hook input of these events describes the subagent (its transcript, its cwd): only the
            // list changes, never the name/state of the session. Unknown session (no file yet): ignore.
            if (!previous.state)
                return;
            const agentId = data.agent_id;
            if (typeof agentId !== "string" || !/^[A-Za-z0-9_.:-]{1,128}$/.test(agentId))
                return;
            const others = pruneSubagents(previous.subagents, now).filter((a) => a.id !== agentId);
            if (event === "subagent-start") {
                const before = (previous.subagents || []).find((a) => a && a.id === agentId);
                if (others.length < SUBAGENT_MAX) {
                    const desc = (before && before.desc) || describeSubagent(data, sessionId, agentId);
                    others.push({
                        id: agentId,
                        type: cleanAgentType(data.agent_type),
                        desc,
                        since: before ? before.since : now,
                        updated: now,
                    });
                    if (!desc && !before)
                        spawnDescriber(sessionId, agentId, data.transcript_path);
                }
            }
            const session = { ...previous, subagents: others };
            // The main agent already finished its turn (Stop) while subagents were still running: the
            // session only counts as finished once the last one ends.
            if (event === "subagent-stop" && !others.length && previous.deferredStop && previous.state === "working") {
                session.state = "waiting";
                session.since = now;
                session.deferredStop = false;
            }
            writeSession(file, session);
            return;
        }
        if (event === "resume" && previous.state !== "permission" && previous.state !== "question")
            return;  // already working: runs after every tool, so leave the file alone
        let state = event === "notification" ? notificationState(data) : event === "resume" ? "working" : event;
        // AskUserQuestion box open (PreToolUse): the late idle/elicitation notice keeps it a question.
        // Set by the hook because the window cannot read WSL transcripts to find the box itself.
        if (event === "notification" && previous.state === "question")
            state = "question";
        const activeSubagents = pruneSubagents(previous.subagents, now);
        // Stop (or the idle notice) while subagents are still running, e.g. in the background: the
        // session keeps showing as working until the last subagent stops (see subagent-stop above).
        const deferStop = state === "waiting" && activeSubagents.length > 0;
        if (deferStop)
            state = "working";
        // mesmo estado de antes (ex.: aviso de ociosidade depois do Stop) não
        // reinicia o relógio do "esperando há X". Permissão sempre reinicia: aprovar
        // não dispara hook, então 2 pedidos seguidos chegam como permission ->
        // permission, e o since velho fazia o transcript do trabalho entre os dois
        // contar como "voltou a trabalhar" (verde no lugar do amarelo).
        const since = previous.state === state && previous.since && state !== "permission" ? previous.since : now;
        const cwd = data.cwd || "";
        const transcript = data.transcript_path || "";
        const name = getTitle(transcript, sessionId) || path.basename(cwd.replace(/[\\/]+$/, "")) || sessionId.slice(0, 8);
        // o pid não muda durante a sessão — no Windows achar ele custa ~1s de PowerShell
        // WSL: a Linux pid means nothing to the Windows window; without pid it uses the 6h rule
        const pid = winDir ? null : previous.pid || findClaudePid();
        writeSession(file, {
            name,
            cwd,
            state,
            since,
            updated: now,
            pid,
            entrypoint: process.env.CLAUDE_CODE_ENTRYPOINT || previous.entrypoint || null,
            transcript,
            subagents: activeSubagents,
            // set while a Stop is held back; a notification keeps it, anything else (a new prompt, a real Stop) clears it
            deferredStop: deferStop || (event === "notification" && !!previous.deferredStop),
        });
    });
}
try {
    main();
}
catch {
    // hook nunca pode travar o Claude
}
//# sourceMappingURL=hook.js.map
