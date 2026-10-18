import { NextResponse } from "next/server";
import { UPDATER_CONFIG } from "@/shared/constants/config";

// zbook fork: the dashboard installs nothing. The fork is updated with zbook/update.sh.
export async function POST() {
  return NextResponse.json(
    {
      success: false,
      message: `This 9router is the zbook fork and is not updated from npm. Run ${UPDATER_CONFIG.installCmdLatest} instead. Nothing was installed.`,
    },
    { status: 409 }
  );
}
