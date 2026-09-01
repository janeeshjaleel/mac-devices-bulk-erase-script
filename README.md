# Jamf Pro - Bulk Wipe Computer Group Script

A Bash script that authenticates with Jamf Pro via OAuth 2.0, retrieves all computers in a specified Smart or Static Group, and sends the **Wipe Computer** (Erase All Content and Settings) command to each one.

> ⚠️ **This script performs an irreversible destructive action.** Read this entire README, especially the [Safety Model](#safety-model) and [Security](#security) sections, before running it.

## What it does

1. Authenticates to Jamf Pro using OAuth 2.0 client credentials.
2. Fetches the membership of a Jamf Pro computer group (Smart or Static).
3. Lists every computer in that group (ID, name, serial number).
4. If configured for a live run, sends an `EraseDevice` command to each computer via the Jamf Pro API.
5. Invalidates the bearer token when finished.

## Prerequisites

- **curl** and **jq** installed on the machine running the script.
  ```bash
  brew install jq
  ```
- A Jamf Pro **API Client (OAuth 2.0)** with at least these privileges:
  - Read — Computers
  - Read — Smart Computer Groups
  - Read — Static Computer Groups
  - Send Computer Remote Wipe Commands — Wipe Computer

  Create this under **Jamf Pro → Settings → API Roles and Clients**.

## ⚠️ Where this script must — and must not — run

This script embeds an OAuth **Client ID and Client Secret** directly in its configuration block.

- ✅ Run it **only** from a trusted admin workstation or a secured automation environment (e.g. a locked-down CI runner) that only admins can access.
- ❌ **Never** deploy this as a Jamf Pro **Policy** script, put it in Self Service, or run it on managed client devices.
  - Any device the policy is scoped to would receive a copy of the script, including the plaintext credentials.
  - Jamf policies run scripts non-interactively (no terminal), which is incompatible with how this script is designed to be confirmed — see [Safety Model](#safety-model) below.

If credentials for this API Client are ever exposed (committed to a repo, distributed via a policy, etc.), **rotate the Client Secret immediately** in Jamf Pro (Settings → API Roles and Clients).

## Setup

1. Clone or download this script.
2. Open `wipe_computers_group.sh` and edit the configuration block at the top:

   | Variable | Description |
   |---|---|
   | `JAMF_PRO_URL` | Your Jamf Pro server URL, no trailing slash (e.g. `https://yourorg.jamfcloud.com`) |
   | `CLIENT_ID` | OAuth API Client ID from Jamf Pro |
   | `CLIENT_SECRET` | OAuth API Client Secret from Jamf Pro |
   | `GROUP_ID` | The numeric Jamf Pro ID of the computer group to target (found in the group's URL) |
   | `WIPE_PIN` | Optional 6-digit Find My PIN. Leave `""` for none. Not required on Apple Silicon/T2 Macs. |
   | `DRY_RUN` | `"true"` to only list computers (no wipe sent). `"false"` to perform a real wipe. |
   | `CONFIRM_WIPE` | Must be manually set to exactly `"YES"` for a live run to proceed. See below. |

3. Make it executable:
   ```bash
   chmod +x wipe_computers_group.sh
   ```

## Usage

```bash
./wipe_computers_group.sh
```

Always test first:

```bash
DRY_RUN="true"
```

This lists every computer that *would* be wiped, without sending any command. Review the list carefully before doing a live run.

## Safety model

This script does **not** use an interactive confirmation prompt (e.g. "type WIPE to continue"). That approach was deliberately removed because it hangs indefinitely when the script runs without a terminal attached — for example under cron or in a CI pipeline.

Instead, a real (non-dry-run) execution requires **both**:

```bash
DRY_RUN="false"
CONFIRM_WIPE="YES"
```

If `DRY_RUN="false"` and `CONFIRM_WIPE` is anything other than `"YES"`, the script refuses to run and exits immediately. This means confirmation must be made deliberately by a human editing the file beforehand — treat that edit with the same seriousness as the old prompt. It is a guard rail, not a guarantee; nothing prevents someone from setting both values carelessly, so review the printed computer list every time before flipping `CONFIRM_WIPE` to `"YES"`.

**Recommended practice:** test against a Static Group containing a single non-critical Mac first. Confirm the wipe command appears in that computer's **Management History** in Jamf Pro before running against a larger group.

## What happens on a live run

- Every computer currently in the target group receives a real `POST` to the Jamf Pro erase endpoint — this is the same as **Erase All Content and Settings**.
- The action is **irreversible**. All data on each device is erased.
- Devices are **not** removed from Jamf Pro inventory after wiping.
- If a Smart Group's membership changes between when you review it and when you run the live pass, the device set may differ — re-check membership immediately before a live run.
- The script waits 0.5 seconds between each wipe request to avoid overwhelming the API.

## Risks and precautions

- **Activation Lock:** Ensure iCloud is signed out on each device beforehand, or wiped Apple Silicon/T2 Macs may come back Activation Locked.
- **Re-enrollment:** If devices need to re-enroll after wiping, make sure they're assigned to a PreStage Enrollment in Apple Business Manager / Apple School Manager.
- **Offline devices:** If a device is offline, the erase command queues and is delivered on next check-in — it does not simply fail silently.
- **No per-device confirmation:** Once a live run starts, it proceeds through the entire group; there is no pause between individual devices.

## Security

- Do **not** commit real credentials to this repository. The version tracked here should only ever contain placeholder values (`API Client ID`, `API Client Secret`, etc.).
- Consider loading `CLIENT_ID` / `CLIENT_SECRET` from environment variables or a local secrets manager instead of hardcoding them, especially if this script will live in a shared repo.
- Restrict the API Client's privileges to only what's listed in [Prerequisites](#prerequisites) — avoid granting broader scopes than necessary.
- Rotate the Client Secret periodically and immediately after any suspected exposure.

## Disclaimer

This script sends irreversible remote wipe commands to real devices. Test thoroughly on non-critical hardware before any production use. Use at your own risk.
