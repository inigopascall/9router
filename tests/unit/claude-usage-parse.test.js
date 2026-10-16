// Pins what getClaudeUsage returns for an OAuth usage body, so the body parser can be
// shared (Otterly serves the same body) without changing what the Claude card receives.
import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("../../open-sse/utils/proxyFetch.js", () => ({
  proxyAwareFetch: vi.fn(),
}));

import { proxyAwareFetch } from "../../open-sse/utils/proxyFetch.js";
import { getUsageForProvider } from "../../open-sse/services/usage.js";
import { parseClaudeResetGrants } from "../../open-sse/services/usage/claude.js";

const BODY = {
  five_hour: { utilization: 87, resets_at: "2026-10-17T03:10:00.000Z" },
  seven_day: { utilization: 43, resets_at: "2026-10-22T09:00:00.000Z" },
  seven_day_opus: { utilization: 12, resets_at: "2026-10-22T09:00:00.000Z" },
  seven_day_sonnet: null,
  seven_day_oauth_apps: { utilization: null, resets_at: null },
  limits: [
    { kind: "weekly_scoped", percent: 130, resets_at: "2026-10-23T00:00:00.000Z", scope: { model: { display_name: " Fable " } } },
    { kind: "weekly_scoped", percent: 7, scope: { model: {} } },
    { kind: "monthly", percent: 5 },
  ],
  extra_usage: { is_enabled: true, monthly_limit: 5000, used_credits: 120 },
  cedar_ember: {
    eligible: true,
    next_grant_id: "g1",
    grants: [{ id: "g1", resets_left: 2, resets_total: 3, ends_at: "2026-10-30T00:00:00Z", clears: ["five_hour"] }],
  },
};

function response(body) {
  return new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
}

describe("getUsageForProvider(claude) OAuth usage body", () => {
  beforeEach(() => vi.clearAllMocks());

  it("maps 5h/7d windows, model weeklies, scoped limits, extra usage and reset grants", async () => {
    proxyAwareFetch.mockResolvedValueOnce(response(BODY));

    const usage = await getUsageForProvider({ provider: "claude", accessToken: "tok-parse-1" }, null, { force: true });

    expect(proxyAwareFetch).toHaveBeenCalledTimes(1);
    const [url, opts] = proxyAwareFetch.mock.calls[0];
    expect(url).toMatch(/\?cedar_ember=1$/);
    expect(opts.headers.Authorization).toBe("Bearer tok-parse-1");
    expect(usage).toEqual({
      plan: "Claude Code",
      extraUsage: { is_enabled: true, monthly_limit: 5000, used_credits: 120 },
      resetCredits: parseClaudeResetGrants(BODY.cedar_ember),
      quotas: {
        "session (5h)": { used: 87, total: 100, remaining: 13, remainingPercentage: 13, resetAt: "2026-10-17T03:10:00.000Z", unlimited: false },
        "weekly (7d)": { used: 43, total: 100, remaining: 57, remainingPercentage: 57, resetAt: "2026-10-22T09:00:00.000Z", unlimited: false },
        "weekly opus (7d)": { used: 12, total: 100, remaining: 88, remainingPercentage: 88, resetAt: "2026-10-22T09:00:00.000Z", unlimited: false },
        "weekly fable (7d)": { used: 100, total: 100, remaining: 0, remainingPercentage: 0, resetAt: "2026-10-23T00:00:00.000Z", unlimited: false },
      },
    });
    expect(Object.keys(usage.quotas)).toEqual(["session (5h)", "weekly (7d)", "weekly opus (7d)", "weekly fable (7d)"]);
    expect(usage.resetCredits).toMatchObject({ availableCount: 2, nextGrantId: "g1", expiresAt: "2026-10-30T00:00:00Z" });
  });

  it("returns empty quotas and null extras for an empty body", async () => {
    proxyAwareFetch.mockResolvedValueOnce(response({}));

    const usage = await getUsageForProvider({ provider: "claude", accessToken: "tok-parse-2" }, null, { force: true });

    expect(usage).toEqual({ plan: "Claude Code", extraUsage: null, resetCredits: null, quotas: {} });
  });
});
