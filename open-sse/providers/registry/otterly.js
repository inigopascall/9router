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
  },
  // Mirrors Otterly's catalog (otterly/src/server/models.ts)
  models: [
    { id: "claude-opus-4-8", name: "Claude Opus 4", contextLength: 200000 },
    { id: "claude-sonnet-4-6", name: "Claude Sonnet 4", contextLength: 200000 },
    { id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5", contextLength: 200000 },
  ],
  features: {
    usage: true,
    usageApikey: true,
  },
};
