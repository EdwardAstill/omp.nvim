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
const context = {
  mode: "tui", agent: { kind: "main" }, cwd: process.cwd(),
  sessionManager: { getSessionId: () => file, getSessionFile: () => file },
  isIdle: () => !busy,
  abort: () => { record({ type: "abort" }); busy = false; fire("agent_end"); },
  ui: { getEditorText: () => "unsent draft", setEditorText: () => { throw new Error("Draft was changed"); } },
};
function fire(event: string) {
  for (const handler of handlers.get(event) ?? []) handler({ type: event }, context);
}
extension({
  on: (event: string, callback: Function) => handlers.set(event, [...handlers.get(event) ?? [], callback]),
  getSessionName: () => name,
  setSessionName: async (value: string) => { name = value; record({ type: "rename", name }); },
  sendUserMessage: (text: string, options: object) => {
    record({ type: "prompt", text, options, file, draft: context.ui.getEditorText() });
    if (busy) return;
    busy = true;
    fire("agent_start");
    if (text !== "wait") setTimeout(() => { busy = false; fire("agent_end"); }, 30);
  },
});
record({ type: "start", argv: process.argv, file });
fire("session_start");
console.log("READY");
process.on("SIGTERM", () => { fire("session_shutdown"); process.exit(0); });
