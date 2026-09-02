#!/bin/bash
# ==============================================================================
# Script Name: mac-devices-bulk-erase-script
# Author     : Janeesh Jaleel
# ==============================================================================
# DISCLAIMER & TERMS OF USE:
# This script is provided "AS IS", without warranty of any kind, express or
# implied, including but not limited to the warranties of merchantability,
# fitness for a particular purpose, and non-infringement.
# By using this script, you acknowledge and agree that you do so at your own risk.
# In no event shall the author(s) or associated organizations be held liable for
# any direct, indirect, incidental, consequential, special, or exemplary damages,
# or any loss of data, profits, or business interruption arising from the use of
# or inability to use this script, even if advised of the possibility of such
# damages.
#
# If you do not agree to these terms, please do not run or use this script.
# ==============================================================================
# Description:
#   Authenticates with Jamf Pro using OAuth 2.0 client credentials, retrieves
#   all computers in a specified Smart/Static Group, and sends the Wipe Computer
#   (Erase All Content and Settings) command to each one via the Jamf Pro API.
#
# Prerequisites:
#   - An API Client (OAuth 2.0) configured in Jamf Pro with the following
#     privileges:
#       * Read - Computers
#       * Read - smart Computer Groups
#       * Read - static Computer Groups
#       * Send Computer Remote wipe Commands - Wipe Computer
#   - curl and jq must be installed on the machine running this script.
#     Install jq via Homebrew: brew install jq
#
# ⚠️  WARNING — ADMIN/SERVER-SIDE SCRIPT ONLY:
#   This script contains credential logic (OAuth client ID and secret).
#   It MUST NOT be deployed as a Jamf Pro policy script or run on managed
#   client devices. Run it only from a trusted admin workstation or
#   secure automation environment.
#
# ⚠️  NON-INTERACTIVE NOTICE:
#   This script no longer uses an interactive "type WIPE to confirm" prompt.
#   That was removed because it hangs forever when run non-interactively
#   (e.g. from a Jamf policy, cron, or CI), since there is no terminal to
#   read input from. Confirmation is now done via the CONFIRM_WIPE variable
#   below, which must be edited by a human BEFORE each run. This is a
#   convenience, not a safety net — treat DRY_RUN and CONFIRM_WIPE with
#   the same care you'd give the old prompt.
#
# Testing Recommendation:
#   - Test against a Static Group containing a SINGLE non-critical test Mac
#     before running against your full group.
#   - Verify the wipe command is queued in the computer's Management History
#     in Jamf Pro before proceeding with the full group.
#
# Risks:
#   - This action is IRREVERSIBLE. Wiped computers will lose all data.
#   - Ensure iCloud is signed out on each device beforehand to avoid
#     Activation Lock.
#   - Devices will NOT be removed from Jamf Pro inventory after wiping.
#   - If devices need to re-enroll, ensure they are assigned to a PreStage
#     in Apple Business Manager / Apple School Manager.
#
# Usage:
#   chmod +x wipe_computers_group.sh
#   ./wipe_computers_group.sh
# =============================================================================

# -----------------------------------------------------------------------------
# CONFIGURATION — Edit these values before running
# -----------------------------------------------------------------------------

# Your Jamf Pro server URL (no trailing slash)
JAMF_PRO_URL="Jamf Instance URL"

# OAuth 2.0 API Client credentials
# Create an API Client in Jamf Pro under Settings > API Roles and Clients
# Enable the client secret
CLIENT_ID="API Client ID"
CLIENT_SECRET="API Client Secret"

# The Jamf Pro ID of the computer group to wipe
# Give the Smart Group ID" = Example 45 | the group ID can fetch from the smart group URL
GROUP_ID="number"

# Optional: 6-digit PIN for Find My (leave empty to send no PIN)
# Note: On Apple Silicon and T2 Macs, no PIN is required — the device
# will erase regardless. On older Intel Macs, the PIN is used to lock
# the device before erasure.
WIPE_PIN=""  # e.g., "123456" or leave as ""

# Set to "true" to do a dry run (lists computers but does NOT send wipe command) | "false" to run the wipe 
DRY_RUN="true"

# Must be set to exactly "YES" (by a human, in this file) for a real run
# (DRY_RUN="false") to proceed. This replaces the old interactive prompt so
# the script no longer hangs when run non-interactively (e.g. via a Jamf
# policy). Leave this as "NO" unless you intend to wipe the group right now.
CONFIRM_WIPE="YES"

# -----------------------------------------------------------------------------
# DO NOT EDIT BELOW THIS LINE
# -----------------------------------------------------------------------------

# Colour output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Colour

echo ""
echo "=============================================="
echo "  Jamf Pro — Bulk Wipe Computer Script"
echo "=============================================="
echo ""

# Validate required tools
for tool in curl jq; do
    if ! command -v "$tool" &>/dev/null; then
        echo -e "${RED}ERROR: '$tool' is not installed. Please install it and retry.${NC}"
        exit 1
    fi
done

# Validate configuration
if [[ "$CLIENT_ID" == "your-client-id-here" || -z "$CLIENT_ID" ]]; then
    echo -e "${RED}ERROR: CLIENT_ID is not set. Please edit the script configuration.${NC}"
    exit 1
fi
if [[ "$CLIENT_SECRET" == "your-client-secret-here" || -z "$CLIENT_SECRET" ]]; then
    echo -e "${RED}ERROR: CLIENT_SECRET is not set. Please edit the script configuration.${NC}"
    exit 1
fi

# Dry run notice
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}⚠️  DRY RUN MODE — No wipe commands will be sent.${NC}"
    echo -e "${YELLOW}   Set DRY_RUN=\"false\" to send actual wipe commands.${NC}"
    echo ""
else
    # Real run requested — require explicit human confirmation via CONFIRM_WIPE.
    # No interactive prompt: this must already be set to "YES" in the file.
    if [[ "$CONFIRM_WIPE" != "YES" ]]; then
        echo -e "${RED}ERROR: DRY_RUN is \"false\" but CONFIRM_WIPE is not \"YES\".${NC}"
        echo -e "${RED}       Refusing to run. Edit the script and set CONFIRM_WIPE=\"YES\"${NC}"
        echo -e "${RED}       only if you intend to wipe every device in group ${GROUP_ID} right now.${NC}"
        exit 1
    fi
    echo -e "${RED}⚠️  LIVE RUN — CONFIRM_WIPE=\"YES\". Wipe commands WILL be sent.${NC}"
    echo ""
fi

# -----------------------------------------------------------------------------
# Step 1: Obtain an OAuth 2.0 Bearer Token
# -----------------------------------------------------------------------------
echo "→ Authenticating with Jamf Pro..."

TOKEN_RESPONSE=$(curl --silent --request POST \
    --url "${JAMF_PRO_URL}/api/oauth/token" \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "client_secret=${CLIENT_SECRET}")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')

if [[ -z "$ACCESS_TOKEN" ]]; then
    echo -e "${RED}ERROR: Failed to obtain access token. Check your CLIENT_ID and CLIENT_SECRET.${NC}"
    echo "Response: $TOKEN_RESPONSE"
    exit 1
fi

echo -e "${GREEN}✓ Authentication successful.${NC}"
echo ""

# -----------------------------------------------------------------------------
# Step 2: Get all computers in the group (Classic API — group membership)
# -----------------------------------------------------------------------------
echo "→ Fetching computers in group ID: ${GROUP_ID}..."

GROUP_RESPONSE=$(curl --silent --request GET \
    --url "${JAMF_PRO_URL}/JSSResource/computergroups/id/${GROUP_ID}" \
    --header "Authorization: Bearer ${ACCESS_TOKEN}" \
    --header "Accept: application/json")

# Extract computer IDs and names from the group
COMPUTER_COUNT=$(echo "$GROUP_RESPONSE" | jq '.computer_group.computers | length')

if [[ -z "$COMPUTER_COUNT" || "$COMPUTER_COUNT" == "null" || "$COMPUTER_COUNT" -eq 0 ]]; then
    echo -e "${YELLOW}WARNING: No computers found in group ID ${GROUP_ID}. Exiting.${NC}"
    exit 0
fi

echo -e "${GREEN}✓ Found ${COMPUTER_COUNT} computer(s) in the group.${NC}"
echo ""

# Print the list of computers
echo "Computers to be wiped:"
echo "----------------------------------------------"
echo "$GROUP_RESPONSE" | jq -r '.computer_group.computers[] | "  ID: \(.id)  |  Name: \(.name)  |  Serial: \(.serial_number)"'
echo "----------------------------------------------"
echo ""

# -----------------------------------------------------------------------------
# Step 3: Send Wipe command to each computer
# -----------------------------------------------------------------------------
SUCCESS_COUNT=0
FAIL_COUNT=0

# Build the JSON body — include PIN only if set
if [[ -n "$WIPE_PIN" ]]; then
    REQUEST_BODY="{\"pin\": \"${WIPE_PIN}\"}"
else
    REQUEST_BODY="{}"
fi

# Loop through each computer in the group
while IFS= read -r COMPUTER_ID; do
    COMPUTER_NAME=$(echo "$GROUP_RESPONSE" | jq -r --arg id "$COMPUTER_ID" '.computer_group.computers[] | select(.id == ($id | tonumber)) | .name')

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  [DRY RUN] Would wipe: ${COMPUTER_NAME} (ID: ${COMPUTER_ID})"
        ((SUCCESS_COUNT++))
        continue
    fi

    echo -n "  Wiping: ${COMPUTER_NAME} (ID: ${COMPUTER_ID})... "

    HTTP_STATUS=$(curl --silent --output /dev/null --write-out "%{http_code}" \
        --request POST \
        --url "${JAMF_PRO_URL}/api/v4/computers-inventory/${COMPUTER_ID}/erase" \
        --header "Authorization: Bearer ${ACCESS_TOKEN}" \
        --header "Content-Type: application/json" \
        --data "$REQUEST_BODY")

    if [[ "$HTTP_STATUS" == "200" ]]; then
        echo -e "${GREEN}✓ Queued${NC}"
        ((SUCCESS_COUNT++))
    else
        echo -e "${RED}✗ Failed (HTTP ${HTTP_STATUS})${NC}"
        ((FAIL_COUNT++))
    fi

    # Small delay to avoid overwhelming the API
    sleep 0.5

done < <(echo "$GROUP_RESPONSE" | jq -r '.computer_group.computers[].id')

# -----------------------------------------------------------------------------
# Step 4: Invalidate the Bearer Token
# -----------------------------------------------------------------------------
curl --silent --request POST \
    --url "${JAMF_PRO_URL}/api/v1/auth/invalidate-token" \
    --header "Authorization: Bearer ${ACCESS_TOKEN}" > /dev/null

echo ""
echo "=============================================="
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "  DRY RUN complete. ${SUCCESS_COUNT} computer(s) would be wiped."
else
    echo -e "  Done. ${GREEN}${SUCCESS_COUNT} succeeded${NC} | ${RED}${FAIL_COUNT} failed${NC}."
fi
echo "=============================================="
echo ""
