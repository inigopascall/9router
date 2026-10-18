// Otterly: a self-hosted, OpenAI-compatible server fronting one Claude subscription.
// Each connection points at one Otterly server through providerSpecificData.baseUrl (.../v1);
// its quota comes from that server's /api/quota (open-sse/services/usage/otterly.js).
export default {
  id: "otterly",
  priority: 12,
  alias: "otterly",
  display: {
    name: "Otterly (Claude)",
    icon: "smart_toy",
    color: "#D97757",
    textIcon: "OT",
  },
  category: "apikey",
  transport: {
    // Default server. connectionBaseUrl: a connection's providerSpecificData.baseUrl replaces it.
    baseUrl: "http://127.0.0.1:11445/v1/chat/completions",
    connectionBaseUrl: true,
    // Otterly drops a streamed reply on purpose when the client should retry it, so the drop is
    // passed on to the client rather than turned into an end of stream.
    passUpstreamDrop: true,
    // A non-streamed reply arrives only when the run ends: wait for headers as long as Node's
    // fetch does (undici headersTimeout, 300 s) instead of the 60 s default.
    timeoutMs: 300000,
    // Each re-send starts another Claude run: no re-send on a network error, timeout, 502, 503 or 504.
    retry: { 502: 0, 503: 0, 504: 0 },
  },
  // Mirrors Otterly's catalog (otterly/src/server/models.ts)
  models: [
    { id: "claude-opus-5-5", name: "Claude Opus 5.5", contextLength: 1000000 },
    { id: "claude-opus-5", name: "Claude Opus 5", contextLength: 1000000 },
    { id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", contextLength: 1000000 },
    { id: "claude-sonnet-5", name: "Claude Sonnet 5", contextLength: 1000000 },
    { id: "claude-haiku-5-5", name: "Claude Haiku 5.5", contextLength: 1000000 },
    { id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5", contextLength: 200000 },
  ],
  features: {
    usage: true,
    usageApikey: true,
  },
};
