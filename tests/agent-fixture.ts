import { appendFileSync, existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// A local fake agent exercises the real extension without contacting a model.
const extensionPath = process.argv[process.argv.indexOf("--extension") + 1];
const { default: extension } = await import(extensionPath);
const handlers = new Map<string, Function[]>();
const log = join(process.cwd(), `${process.pid}.jsonl`);
const resume = process.argv.indexOf("--resume");
const file = resume >= 0 ? process.argv[resume + 1] : join(process.cwd(), `${process.pid}.session`);
if (!existsSync(file)) writeFileSync(file, "saved conversation\n");
const record = (value: object) => appendFileSync(log, JSON.stringify(value) + "\n");
let busy = false;
let name = "Fixture " + process.pid;
let draft = "unsent draft";
const context = {
  mode: "tui", agent: { kind: "main" }, cwd: process.cwd(),
  sessionManager: { getSessionId: () => file, getSessionFile: () => file },
  isIdle: () => !busy,
  abort: () => { record({ type: "abort" }); busy = false; fire("agent_end"); },
  ui: {
    getEditorText: () => draft,
    setEditorText: (text: string) => { draft = text; record({ type: "draft", text, file, busy }); },
  },
};
function fire(event: string) {
  for (const handler of handlers.get(event) ?? []) handler({ type: event }, context);
}
extension({
  on: (event: string, callback: Function) => handlers.set(event, [...handlers.get(event) ?? [], callback]),
  getSessionName: () => name,
  setSessionName: async (value: string) => { name = value; record({ type: "rename", name }); },
  sendUserMessage: () => { throw new Error("Draft transport must not submit or queue messages"); },
});
record({ type: "start", argv: process.argv, file });
// Delay the handshake so immediate Neovim sends exercise the connecting state.
setTimeout(() => fire("session_start"), 100);
console.log("READY");
process.stdin.setRawMode(true);
process.stdin.setEncoding("utf8");
process.stdin.on("data", (data: string) => {
  for (const character of data) {
    if (character === "\r" || character === "\n") {
      if (busy || !draft.trim()) continue;
      const text = draft;
      draft = "";
      record({ type: "prompt", text, file, source: "enter" });
      busy = true;
      fire("agent_start");
      if (text.trim() !== "wait") setTimeout(() => { busy = false; fire("agent_end"); }, 30);
    } else if (character === "\x15") {
      context.ui.setEditorText("");
    } else {
      context.ui.setEditorText(draft + character);
    }
  }
});
process.on("SIGTERM", () => { fire("session_shutdown"); process.exit(0); });
