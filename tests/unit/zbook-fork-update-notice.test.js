// zbook fork: the dashboard's update notice names zbook/update.sh instead of the npm command,
// and the update action (POST /api/version/update) installs nothing.
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

vi.mock("@/lib/appUpdater", () => ({ killAppProcesses: vi.fn(), spawnUpdaterAndExit: vi.fn() }));

const UPDATE_CMD = "~/code/iwd/9router/zbook/update.sh";

describe("zbook fork: dashboard update notice", () => {
  const savedEnv = process.env.NODE_ENV;
  beforeEach(() => {
    vi.resetModules();
  });
  afterEach(() => {
    process.env.NODE_ENV = savedEnv;
    delete global.__npmVersionCache;
  });

  it("GET /api/version reports a newer npm release and carries the update.sh command", async () => {
    global.__npmVersionCache = { value: "999.0.0", fetchedAt: Date.now() };
    const { GET } = await import("@/app/api/version/route.js");
    const body = await (await GET()).json();
    expect(body.latestVersion).toBe("999.0.0");
    expect(body.hasUpdate).toBe(true);
    expect(body.updateCommand).toBe(UPDATE_CMD);
  });

  it("GET /api/version reports no update when npm's latest is older", async () => {
    global.__npmVersionCache = { value: "0.0.1", fetchedAt: Date.now() };
    const { GET } = await import("@/app/api/version/route.js");
    const body = await (await GET()).json();
    expect(body.hasUpdate).toBe(false);
  });

  it("the command the dashboard shows is update.sh, not npm", async () => {
    const { UPDATER_CONFIG } = await import("@/shared/constants/config");
    expect(UPDATER_CONFIG.installCmdLatest).toBe(UPDATE_CMD);
    expect(UPDATER_CONFIG.installCmdLatest).not.toContain("npm");
  });

  it("POST /api/version/update installs nothing and returns an error naming update.sh", async () => {
    process.env.NODE_ENV = "production";
    const appUpdater = await import("@/lib/appUpdater");
    const { POST } = await import("@/app/api/version/update/route.js");
    const res = await POST();
    expect(res.status).toBe(409);
    const body = await res.json();
    expect(body.success).toBe(false);
    expect(body.message).toContain(UPDATE_CMD);
    expect(appUpdater.spawnUpdaterAndExit).not.toHaveBeenCalled();
    expect(appUpdater.killAppProcesses).not.toHaveBeenCalled();
  });
});
