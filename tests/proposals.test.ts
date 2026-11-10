// bun test tests/proposals.test.ts (no installed pi-ai needed: inference stays behind held auth).
import { expect, test } from "bun:test";
import { once } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import extension, { proposalText } from "../extensions/neovim";

test("proposal decoding preserves whitespace and empty deletion", () => {
  for (const text of ["", "\n\t  replacement  \n", "```literal code fences```", "λ"]) {
    expect(proposalText({ stopReason: "stop", content: [
      { type: "thinking", thinking: "not part of the replacement" },
      { type: "text", text: JSON.stringify({ text }) },
    ] })).toBe(text);
  }
});

test("proposal decoding rejects malformed, truncated, failed and tool responses", () => {
  for (const text of ["", "plain code", '```json\n{"text":"x"}\n```', '{"text":', "null", "[]",
    '{"text":null}', '{"text":123}', '{"text":"ok","extra":true}']) {
    expect(() => proposalText({ stopReason: "stop", content: [{ type: "text", text }] })).toThrow();
  }
  for (const stopReason of ["length", "error", "aborted", "toolUse"] as const) {
    expect(() => proposalText({ stopReason, content: [{ type: "text", text: '{"text":"partial"}' }] })).toThrow();
  }
  expect(() => proposalText({ stopReason: "stop", errorMessage: "provider failure",
    content: [{ type: "text", text: '{"text":"partial"}' }] })).toThrow("provider failure");
  expect(() => proposalText({ stopReason: "stop", content: [
    { type: "text", text: '{"text":"partial"}' },
    { type: "toolCall", id: "call", name: "write", arguments: {} },
  ] })).toThrow("Unexpected suggestion content");
});

test("suggestions validate, serialize and cancel without touching chat", async () => {
  const root = mkdtempSync(join(tmpdir(), "omp-proposal-"));
  const oldSocket = process.env.OMP_NVIM_SOCKET;
  process.env.OMP_NVIM_SOCKET = join(root, "bridge.sock");
  const server = createServer();
  const handlers = new Map<string, Function>();
  const replies = new Map<number, (response: Record<string, unknown>) => void>();
  let peer: Socket | undefined;
  let authStarted = Promise.withResolvers<AbortSignal>();
  const auth = Promise.withResolvers<string>();
  const model = { provider: "fixture", id: "selected-model" };
  let draft = "unsent draft";
  let chatAborts = 0;
  const context = {
    mode: "tui", agent: { kind: "main" }, cwd: root, model,
    sessionManager: { getSessionId: () => "current-session", getSessionFile: () => "session.jsonl" },
    isIdle: () => false,
    abort: () => { chatAborts++; },
    ui: { getEditorText: () => draft, setEditorText: (text: string) => { draft = text; } },
    modelRegistry: {
      getApiKey: (selected: unknown, session: string, { signal }: { signal: AbortSignal }) => {
        expect(selected).toBe(model);
        expect(session).toBe("current-session");
        authStarted.resolve(signal);
        return auth.promise;
      },
    },
  };
  try {
    server.listen(process.env.OMP_NVIM_SOCKET);
    await once(server, "listening");
    const connected = once(server, "connection");
    extension({
      on: (event: string, handler: Function) => handlers.set(event, handler),
      getSessionName: () => "fixture",
    } as never);
    handlers.get("session_start")!({}, context);
    [peer] = await connected as [Socket];
    peer.setEncoding("utf8");
    let pending = "";
    let ended = 0;
    peer.on("data", data => {
      pending += data;
      let newline: number;
      while ((newline = pending.indexOf("\n")) !== -1) {
        const response = JSON.parse(pending.slice(0, newline));
        pending = pending.slice(newline + 1);
        if (response.type === "end") ended++;
        if (response.type === "response") replies.get(response.id)?.(response);
      }
    });
    const send = (request: Record<string, unknown> & { id: number }) => {
      const reply = Promise.withResolvers<Record<string, unknown>>();
      replies.set(request.id, reply.resolve);
      peer!.write(JSON.stringify(request) + "\n");
      return reply.promise;
    };
    const suggestion = { type: "suggest", action: "edit", before: "", selected: "remove me", after: "",
      file: "unsaved.lua", filetype: "lua", instruction: "delete selected text" };
    expect((await send({ ...suggestion, id: 1, action: "unknown" })).error).toContain("Invalid suggestion");
    expect((await send({ ...suggestion, id: 2, selected: null })).error).toContain("Invalid suggestion");
    expect((await send({ ...suggestion, id: 3, action: "complete" })).error).toContain("Invalid suggestion");
    const first = send({ ...suggestion, id: 4 });
    const signal = await authStarted.promise;
    expect((await send({ ...suggestion, id: 5 })).error).toContain("already running");
    expect(await send({ id: 6, type: "cancel_suggestion" })).toEqual({ type: "response", id: 6 });
    expect(signal.aborted).toBe(true);
    expect((await first).error).toContain("cancelled");
    expect(await send({ id: 7, type: "cancel_suggestion" })).toEqual({ type: "response", id: 7 });
    authStarted = Promise.withResolvers<AbortSignal>();
    const next = send({ ...suggestion, id: 8 });
    const nextSignal = await authStarted.promise;
    handlers.get("session_switch")!({}, context);
    expect((await next).error).toContain("Session switched");
    expect(nextSignal.aborted).toBe(true);
    authStarted = Promise.withResolvers<AbortSignal>();
    void send({ ...suggestion, id: 9 });
    const disconnected = await authStarted.promise;
    const didAbort = once(disconnected, "abort");
    peer.destroy();
    await didAbort;
    expect(disconnected.aborted).toBe(true);
    expect(draft).toBe("unsent draft");
    expect(chatAborts).toBe(0);
    expect(ended).toBe(0);
  } finally {
    handlers.get("session_shutdown")?.({}, context);
    peer?.destroy();
    server.close();
    if (oldSocket === undefined) delete process.env.OMP_NVIM_SOCKET;
    else process.env.OMP_NVIM_SOCKET = oldSocket;
    rmSync(root, { recursive: true, force: true });
  }
});
