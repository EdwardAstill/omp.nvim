import { createConnection, type Socket } from "node:net";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

// Each Neovim-owned terminal gets a private local socket. Never inherit the
// connection in a task subagent, and never edit the interactive prompt draft.
export default function (pi: ExtensionAPI) {
  const path = process.env.OMP_NVIM_SOCKET;
  if (!path) return;
  let socket: Socket | undefined;
  let context: ExtensionContext;
  const emit = (message: object) => {
    if (socket && !socket.destroyed) socket.write(JSON.stringify(message) + "\n");
  };
  const state = () => emit({
    type: "state", name: pi.getSessionName(), cwd: context.cwd,
    sessionId: context.sessionManager.getSessionId(), file: context.sessionManager.getSessionFile(),
    status: context.isIdle() ? "idle" : "working",
  });

  pi.on("session_start", (_event, ctx) => {
    if (ctx.agent.kind !== "main" || ctx.mode !== "tui") return;
    context = ctx;
    socket = createConnection(path);
    socket.on("connect", state);
    socket.on("error", () => socket?.destroy());
    let pending = "";
    socket.setEncoding("utf8");
    socket.on("data", data => {
      pending += data;
      let newline: number;
      while ((newline = pending.indexOf("\n")) !== -1) {
        const line = pending.slice(0, newline);
        pending = pending.slice(newline + 1);
        void handle(line);
      }
    });
  });

  async function handle(line: string) {
    let request: { id: number; type: string; text?: string; name?: string } | undefined;
    try {
      request = JSON.parse(line);
      if (!request) throw new Error("Invalid request");
      if (request.type === "prompt") {
        if (typeof request.text !== "string" || !request.text.trim()) throw new Error("Empty prompt");
        const queued = !context.isIdle();
        pi.sendUserMessage(request.text, queued ? { deliverAs: "followUp" } : undefined);
        emit({ type: "response", id: request.id, queued });
      } else if (request.type === "abort") {
        context.abort();
        emit({ type: "response", id: request.id });
      } else if (request.type === "rename") {
        if (typeof request.name !== "string" || !request.name.trim()) throw new Error("Empty name");
        await pi.setSessionName(request.name.trim());
        emit({ type: "response", id: request.id });
      } else {
        throw new Error("Unknown request");
      }
      state();
    } catch (error) {
      emit({ type: "response", id: request?.id, error: String(error) });
    }
  }

  function update(_event: unknown, ctx: ExtensionContext) {
    if (!socket || ctx.agent.kind !== "main") return;
    context = ctx;
    state();
  }
  pi.on("session_switch", update);
  pi.on("agent_start", update);
  pi.on("agent_end", (event, ctx) => {
    update(event, ctx);
    if (socket && ctx.agent.kind === "main") emit({ type: "end" });
  });
  pi.on("session_shutdown", () => { socket?.destroy(); socket = undefined; });
}
