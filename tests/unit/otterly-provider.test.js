// Otterly provider: registry entry, per-connection chat URL, and the quota handler that
// reads <root>/api/quota from the connection's own Otterly server.
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

vi.mock("../../open-sse/utils/proxyFetch.js", () => ({
  proxyAwareFetch: vi.fn(),
}));

import { proxyAwareFetch } from "../../open-sse/utils/proxyFetch.js";
import { getUsageForProvider } from "../../open-sse/services/usage.js";
import { parseClaudeOAuthUsage } from "../../open-sse/services/usage/claude.js";
import {
  OTTERLY_DEFAULT_BASE_URL,
  otterlyRootUrl,
  resolveOtterlyBaseUrl,
} from "../../open-sse/services/usage/otterly.js";
import { getExecutor } from "../../open-sse/executors/index.js";
import { parseModel } from "../../open-sse/services/model.js";
import { PROVIDER_MODELS } from "../../open-sse/providers/index.js";
import {
  APIKEY_PROVIDERS,
  USAGE_SUPPORTED_PROVIDERS,
  USAGE_APIKEY_PROVIDERS,
} from "../../src/shared/constants/providers.js";
import { parseQuotaData } from "../../src/app/(dashboard)/dashboard/usage/components/ProviderLimits/utils.js";

const SERVER = "http://127.0.0.1:11447";

// The contract example: Anthropic's /api/oauth/usage shape plus Otterly's metadata key.
const QUOTA_BODY = {
  five_hour: { utilization: 4, resets_at: "2026-10-17T03:10:00.000Z" },
  seven_day: { utilization: 43, resets_at: "2026-10-22T09:00:00.000Z" },
  seven_day_opus: { utilization: 12, resets_at: "2026-10-22T09:00:00.000Z" },
  otterly: {
    source: "oauth_usage",
    observed_at: "2026-10-16T15:00:00.000Z",
    status: "allowed",
    live_error: null,
    config_dir: "/home/inigo/.claude-acct1",
    account: { email: "a@example.com", organization: "Example", subscription_type: "max", rate_limit_tier: "default_claude_max_5x" },
  },
};

const NO_DATA_BODY = {
  otterly: {
    source: "none",
    observed_at: "2026-10-16T15:00:00.000Z",
    status: null,
    live_error: "No Claude credentials in /home/inigo/.claude-acct1",
    config_dir: "/home/inigo/.claude-acct1",
    account: null,
  },
};

function response(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function connection(extra = {}) {
  return { provider: "otterly", providerSpecificData: { baseUrl: `${SERVER}/v1` }, ...extra };
}

describe("otterly registry entry", () => {
  it("is an apikey provider listed for the quota dashboard", () => {
    expect(APIKEY_PROVIDERS.otterly).toMatchObject({ id: "otterly", alias: "otterly", name: "Otterly (Claude)" });
    expect(USAGE_SUPPORTED_PROVIDERS).toContain("otterly");
    expect(USAGE_APIKEY_PROVIDERS).toContain("otterly");
  });

  it("mirrors Otterly's model catalog", () => {
    expect(PROVIDER_MODELS.otterly.map((m) => m.id)).toEqual([
      "claude-opus-4-8",
      "claude-sonnet-4-6",
      "claude-haiku-4-5-20251001",
    ]);
  });

  it("resolves otterly/<model> to the otterly provider", () => {
    expect(parseModel("otterly/claude-sonnet-4-6")).toMatchObject({ provider: "otterly", model: "claude-sonnet-4-6" });
  });
});

describe("otterly chat URL", () => {
  it("goes to the connection's own base URL", () => {
    const url = getExecutor("otterly").buildUrl("claude-sonnet-4-6", true, 0, {
      providerSpecificData: { baseUrl: `${SERVER}/v1/` },
    });
    expect(url).toBe(`${SERVER}/v1/chat/completions`);
  });

  it("falls back to the default server without a base URL", () => {
    const url = getExecutor("otterly").buildUrl("claude-sonnet-4-6", false, 0, { providerSpecificData: {} });
    expect(url).toBe("http://127.0.0.1:11445/v1/chat/completions");
  });

  it("leaves other registry providers on their registry URL", () => {
    const url = getExecutor("groq").buildUrl("llama-3.3-70b-versatile", false, 0, {
      providerSpecificData: { baseUrl: `${SERVER}/v1` },
    });
    expect(url).toBe("https://api.groq.com/openai/v1/chat/completions");
  });
});

describe("otterly base URL and quota root", () => {
  it.each([
    ["http://127.0.0.1:11445/v1", "http://127.0.0.1:11445"],
    ["http://127.0.0.1:11445/v1/", "http://127.0.0.1:11445"],
    ["http://otterly.lan:8080", "http://otterly.lan:8080"],
    ["http://otterly.lan:8080/claude/v1", "http://otterly.lan:8080/claude"],
  ])("root of %s is %s", (baseUrl, root) => {
    expect(otterlyRootUrl(baseUrl)).toBe(root);
  });

  it("uses the connection's base URL, or the default when it has none", () => {
    expect(OTTERLY_DEFAULT_BASE_URL).toBe("http://127.0.0.1:11445/v1");
    expect(resolveOtterlyBaseUrl({})).toBe(OTTERLY_DEFAULT_BASE_URL);
    expect(resolveOtterlyBaseUrl({ providerSpecificData: { baseUrl: "  " } })).toBe(OTTERLY_DEFAULT_BASE_URL);
    expect(resolveOtterlyBaseUrl({ providerSpecificData: { baseUrl: " http://127.0.0.1:11446/v1/ " } }))
      .toBe("http://127.0.0.1:11446/v1");
  });
});

describe("getUsageForProvider(otterly)", () => {
  beforeEach(() => vi.clearAllMocks());
  afterEach(() => vi.useRealTimers());

  it("GETs <root>/api/quota with the API key as Bearer and a timeout signal", async () => {
    proxyAwareFetch.mockResolvedValueOnce(response(QUOTA_BODY));
    await getUsageForProvider(connection({ apiKey: "otterly-key" }));

    expect(proxyAwareFetch).toHaveBeenCalledTimes(1);
    const [url, opts] = proxyAwareFetch.mock.calls[0];
    expect(url).toBe(`${SERVER}/api/quota`);
    expect(opts.method).toBe("GET");
    expect(opts.headers.Authorization).toBe("Bearer otterly-key");
    expect(opts.signal).toBeInstanceOf(AbortSignal);
  });

  it("sends no Authorization header without an API key", async () => {
    proxyAwareFetch.mockResolvedValueOnce(response(QUOTA_BODY));
    await getUsageForProvider(connection());
    expect(proxyAwareFetch.mock.calls[0][1].headers).not.toHaveProperty("Authorization");
  });

  it("asks Otterly to bypass its cache when forced", async () => {
    proxyAwareFetch.mockResolvedValueOnce(response(QUOTA_BODY));
    await getUsageForProvider(connection({ apiKey: "k" }), null, { force: true });
    expect(proxyAwareFetch.mock.calls[0][0]).toBe(`${SERVER}/api/quota?refresh=1`);
  });

  it("uses the default server when the connection has no base URL", async () => {
    proxyAwareFetch.mockResolvedValueOnce(response(QUOTA_BODY));
    await getUsageForProvider({ provider: "otterly", apiKey: "k" });
    expect(proxyAwareFetch.mock.calls[0][0]).toBe("http://127.0.0.1:11445/api/quota");
  });

  it("parses the body like Claude's and names the plan", async () => {
    proxyAwareFetch.mockResolvedValueOnce(response(QUOTA_BODY));
    const usage = await getUsageForProvider(connection({ apiKey: "k" }));

    expect(usage.message).toBeUndefined();
    expect(usage.plan).toBe("Claude Max (Otterly)");
    expect(usage.quotas).toEqual(parseClaudeOAuthUsage(QUOTA_BODY).quotas);
    expect(Object.keys(usage.quotas)).toEqual(["session (5h)", "weekly (7d)", "weekly opus (7d)"]);
    expect(usage.quotas["session (5h)"]).toMatchObject({
      used: 4, total: 100, remaining: 96, resetAt: "2026-10-17T03:10:00.000Z",
    });
    expect(usage.quotas["weekly (7d)"]).toMatchObject({ used: 43, total: 100, remaining: 57 });
    expect(usage.quotas["weekly opus (7d)"]).toMatchObject({ used: 12, total: 100, remaining: 88 });
  });

  it.each([
    ["pro", "Claude Pro (Otterly)"],
    [null, "Claude (Otterly)"],
    [undefined, "Claude (Otterly)"],
  ])("plan for subscription type %s is %s", async (type, plan) => {
    const body = { ...QUOTA_BODY, otterly: { ...QUOTA_BODY.otterly, account: { subscription_type: type } } };
    proxyAwareFetch.mockResolvedValueOnce(response(body));
    expect((await getUsageForProvider(connection())).plan).toBe(plan);
  });

  it("reports Otterly's live_error when neither window is present", async () => {
    proxyAwareFetch.mockResolvedValueOnce(response(NO_DATA_BODY));
    expect(await getUsageForProvider(connection())).toEqual({
      message: "No Claude credentials in /home/inigo/.claude-acct1",
    });
  });

  it("reports a default message when there is no data and no live_error", async () => {
    proxyAwareFetch.mockResolvedValueOnce(response({
      seven_day_opus: QUOTA_BODY.seven_day_opus,
      otterly: { source: "none", live_error: null },
    }));
    expect(await getUsageForProvider(connection())).toEqual({ message: "No usage reported yet" });
  });

  it("reports an unreachable server", async () => {
    proxyAwareFetch.mockRejectedValueOnce(new Error("connect ECONNREFUSED 127.0.0.1:11447"));
    expect(await getUsageForProvider(connection())).toEqual({
      message: "Otterly not reachable at http://127.0.0.1:11447: connect ECONNREFUSED 127.0.0.1:11447",
    });
  });

  it("gives up on a server that does not answer within 10 s", async () => {
    vi.useFakeTimers();
    proxyAwareFetch.mockImplementationOnce((url, opts) => new Promise((resolve, reject) => {
      opts.signal.addEventListener("abort", () => reject(new Error("This operation was aborted")));
    }));

    const pending = getUsageForProvider(connection());
    await vi.advanceTimersByTimeAsync(9999);
    expect(proxyAwareFetch.mock.calls[0][1].signal.aborted).toBe(false);
    await vi.advanceTimersByTimeAsync(1);

    expect(await pending).toEqual({
      message: "Otterly not reachable at http://127.0.0.1:11447: This operation was aborted",
    });
  });

  it("reports a non-200 answer", async () => {
    proxyAwareFetch.mockResolvedValueOnce(response({ error: "unauthorized" }, 401));
    expect(await getUsageForProvider(connection({ apiKey: "wrong" }))).toEqual({
      message: "Otterly at http://127.0.0.1:11447 returned HTTP 401",
    });
  });
});

describe("parseClaudeOAuthUsage", () => {
  it("is a pure function of the body", () => {
    vi.clearAllMocks();
    expect(parseClaudeOAuthUsage({})).toEqual({ extraUsage: null, resetCredits: null, quotas: {} });
    expect(parseClaudeOAuthUsage(QUOTA_BODY)).toEqual(parseClaudeOAuthUsage(structuredClone(QUOTA_BODY)));
    expect(proxyAwareFetch).not.toHaveBeenCalled();
  });
});

describe("parseQuotaData(otterly)", () => {
  it("renders the rows exactly like Claude's card", () => {
    const usage = { plan: "Claude Max (Otterly)", ...parseClaudeOAuthUsage(QUOTA_BODY) };
    const rows = parseQuotaData("otterly", usage);

    expect(rows).toEqual(parseQuotaData("claude", usage));
    expect(rows.map((r) => r.name)).toEqual(["session (5h)", "weekly (7d)", "weekly opus (7d)"]);
    expect(rows[0]).toMatchObject({ used: 4, total: 100, remaining: 96, remainingPercentage: 96 });
  });

  it("shows a message row when there is no usage", () => {
    expect(parseQuotaData("otterly", { message: "No usage reported yet" })).toEqual([
      { name: "error", used: 0, total: 0, resetAt: null, message: "No usage reported yet" },
    ]);
  });
});
