/**
 * Otterly usage handler
 *
 * Otterly is a self-hosted, OpenAI-compatible server fronting a Claude subscription.
 * It serves Anthropic's /api/oauth/usage body, plus an `otterly` metadata key, at
 * <root>/api/quota (always HTTP 200), so the body is parsed exactly like Claude's.
 */

import { fetchWithTimeout } from "./shared.js";
import { parseClaudeOAuthUsage } from "./claude.js";

export const OTTERLY_DEFAULT_BASE_URL = "http://127.0.0.1:11445/v1";
const OTTERLY_QUOTA_TIMEOUT_MS = 10000;

// The connection's own base URL (.../v1) from providerSpecificData.baseUrl; default server when unset.
export function resolveOtterlyBaseUrl(credentials) {
  const raw = credentials?.providerSpecificData?.baseUrl;
  const baseUrl = typeof raw === "string" && raw.trim() ? raw.trim() : OTTERLY_DEFAULT_BASE_URL;
  return baseUrl.replace(/\/$/, "");
}

// Server root: the base URL with a trailing "/" removed, then a trailing "/v1" removed.
export function otterlyRootUrl(baseUrl) {
  return String(baseUrl).replace(/\/$/, "").replace(/\/v1$/, "");
}

// "max" -> "Claude Max (Otterly)"; no subscription type -> "Claude (Otterly)"
function otterlyPlan(subscriptionType) {
  const type = typeof subscriptionType === "string" ? subscriptionType.trim() : "";
  return type ? `Claude ${type[0].toUpperCase()}${type.slice(1)} (Otterly)` : "Claude (Otterly)";
}

export async function getOtterlyUsage(apiKey, providerSpecificData, proxyOptions = null, options = {}) {
  const root = otterlyRootUrl(resolveOtterlyBaseUrl({ providerSpecificData }));
  // refresh=1 asks Otterly to bypass its own 5-minute cache (manual refresh)
  const url = `${root}/api/quota${options?.force === true ? "?refresh=1" : ""}`;
  const headers = { Accept: "application/json" };
  if (apiKey) headers.Authorization = `Bearer ${apiKey}`;

  let response;
  try {
    response = await fetchWithTimeout(url, { method: "GET", headers }, OTTERLY_QUOTA_TIMEOUT_MS, proxyOptions);
  } catch (error) {
    return { message: `Otterly not reachable at ${root}: ${error?.message || error}` };
  }
  if (!response.ok) {
    return { message: `Otterly at ${root} returned HTTP ${response.status}` };
  }

  const data = await response.json().catch(() => null);
  if (!data || typeof data !== "object") {
    return { message: `Otterly at ${root} returned an unreadable quota body` };
  }

  const usage = parseClaudeOAuthUsage(data);
  if (!usage.quotas["session (5h)"] && !usage.quotas["weekly (7d)"]) {
    return { message: data.otterly?.live_error || "No usage reported yet" };
  }
  return { plan: otterlyPlan(data.otterly?.account?.subscription_type), ...usage };
}
