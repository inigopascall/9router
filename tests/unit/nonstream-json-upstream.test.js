import { describe, expect, it, vi } from "vitest";

vi.mock("@/lib/usageDb.js", () => ({
  appendRequestLog: vi.fn(async () => {}),
  saveRequestDetail: vi.fn(async () => {}),
  saveRequestUsage: vi.fn(async () => {}),
  trackPendingRequest: vi.fn()
}));

const { FORMATS } = await import("../../open-sse/translator/formats.js");
const { handleNonStreamingResponse, isJsonReplyToUnrequestedStream } = await import("../../open-sse/handlers/chatCore/nonStreamingHandler.js");
const { createPassthroughStreamWithLogger } = await import("../../open-sse/utils/stream.js");

const completion = {
  id: "chatcmpl-test",
  object: "chat.completion",
  created: 1,
  model: "test-model",
  choices: [{ index: 0, message: { role: "assistant", content: "hello" }, finish_reason: "stop" }],
  usage: { prompt_tokens: 2, completion_tokens: 1, total_tokens: 3 }
};
const jsonResponse = () => new Response(JSON.stringify(completion), { headers: { "content-type": "application/json" } });
const sseResponse = () => new Response("data: {}\n\n", { headers: { "content-type": "text/event-stream" } });
const chunk = { id: "c1", object: "chat.completion.chunk", created: 1, model: "test-model", choices: [{ index: 0, delta: { content: "hi" }, finish_reason: null }] };
const countDone = (text) => text.split("[DONE]").length - 1;

async function runPassthrough(raw) {
  const out = new Response(raw).body.pipeThrough(createPassthroughStreamWithLogger("op-test"));
  return new Response(out).text();
}

describe("a JSON upstream reply to a request without stream", () => {
  it("takes the JSON path only when the client did not ask for a stream and the upstream answered JSON", () => {
    expect(isJsonReplyToUnrequestedStream({ stream: true, clientRequestedStreaming: false, providerResponse: jsonResponse() })).toBe(true);
    expect(isJsonReplyToUnrequestedStream({ stream: true, clientRequestedStreaming: true, providerResponse: jsonResponse() })).toBe(false);
    expect(isJsonReplyToUnrequestedStream({ stream: true, clientRequestedStreaming: false, providerResponse: sseResponse() })).toBe(false);
    expect(isJsonReplyToUnrequestedStream({ stream: false, clientRequestedStreaming: false, providerResponse: jsonResponse() })).toBe(false);
  });

  it("returns the upstream completion as clean JSON with no [DONE]", async () => {
    const result = await handleNonStreamingResponse({
      providerResponse: jsonResponse(),
      provider: "op-test",
      model: "test-model",
      sourceFormat: FORMATS.OPENAI,
      targetFormat: FORMATS.OPENAI,
      body: { model: "test-model", messages: [] },
      stream: true,
      requestStartTime: Date.now(),
      connectionId: "test-connection",
      clientRawRequest: { endpoint: "/v1/chat/completions" },
      reqLogger: { logProviderResponse: vi.fn(), logConvertedResponse: vi.fn() },
      trackDone: vi.fn(),
      appendLog: vi.fn()
    });
    expect(result.success).toBe(true);
    expect(result.response.headers.get("content-type")).toBe("application/json");
    const text = await result.response.text();
    expect(text).not.toContain("[DONE]");
    expect(JSON.parse(text).choices[0].message.content).toBe("hello");
  });
});

describe("passthrough stream terminator", () => {
  it("ends with exactly one [DONE] when the upstream sends its own", async () => {
    const text = await runPassthrough(`data: ${JSON.stringify(chunk)}\n\ndata: [DONE]\n\n`);
    expect(countDone(text)).toBe(1);
  });

  it("adds one [DONE] when the upstream sends none", async () => {
    const text = await runPassthrough(`data: ${JSON.stringify(chunk)}\n\n`);
    expect(countDone(text)).toBe(1);
  });
});
