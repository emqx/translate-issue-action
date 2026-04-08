#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -euo pipefail

# Function for logging to stderr
log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" >&2
}

# --- Input Validation & Setup ---
GH_REPO=${1:-}
ISSUE_NUMBER=${2:-}
GH_TOKEN="${GH_TOKEN:-}"
MODEL="${MODEL:-openai/gpt-4o}"

if [ -z "$GH_REPO" ]; then log "Error: Repository missing."; exit 1; fi
if [ -z "$ISSUE_NUMBER" ]; then log "Error: Issue number missing."; exit 1; fi
if [ -z "$GH_TOKEN" ]; then log "Error: GH_TOKEN missing."; exit 1; fi
if ! command -v gh &> /dev/null; then log "Error: 'gh' not found."; exit 1; fi
if ! command -v jq &> /dev/null; then log "Error: 'jq' not found."; exit 1; fi

TMP_DIR=$(mktemp -d)
trap 'log "Cleaning up temporary directory $TMP_DIR..."; rm -rf "$TMP_DIR"' EXIT

# --- Fetch Issue Details ---
log "Fetching issue $ISSUE_NUMBER from $GH_REPO..."
ISSUE_DATA=$(gh issue view "$ISSUE_NUMBER" --json title,body --repo "$GH_REPO")
ISSUE_TITLE=$(echo "$ISSUE_DATA" | jq -r '.title // ""')
ISSUE_BODY=$(echo "$ISSUE_DATA" | jq -r '.body // ""')

if [ -z "$ISSUE_TITLE" ] && [ -z "$ISSUE_BODY" ]; then
    log "Error: Could not fetch title or body for issue $ISSUE_NUMBER."
    exit 1
fi

log "Issue Title: $ISSUE_TITLE"

# --- Translate Text ---
log "Translating issue text using $MODEL..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TEXT_TRANSLATION=$(gh models run "$MODEL" \
    --file "$SCRIPT_DIR/translate.prompt.yml" \
    --var "title=$ISSUE_TITLE" \
    --var "body=$ISSUE_BODY" \
    2>"$TMP_DIR/llm_stderr.log") || {
    log "Text translation failed."
    log "$(cat "$TMP_DIR/llm_stderr.log")"
    echo "Error: Translation failed"
    exit 1
}

if [[ "$TEXT_TRANSLATION" == Error:* ]]; then
    log "Text translation failed."
    echo "$TEXT_TRANSLATION"
    exit 1
fi

SCREENSHOT_TRANSLATIONS=""
if [ "${TRANSLATE_ATTACHMENTS:-false}" = true ]; then
    # --- Find & Translate Images ---
    log "Searching for images in the issue body..."

    if ! command -v curl &> /dev/null; then log "Error: 'curl' not found (needed for attachments)."; exit 1; fi
    if ! command -v grep &> /dev/null; then log "Error: 'grep' not found."; exit 1; fi
    if ! command -v file &> /dev/null; then log "Error: 'file' not found."; exit 1; fi
    if ! command -v base64 &> /dev/null; then log "Error: 'base64' not found."; exit 1; fi

    # GitHub Models API for vision (gh models run doesn't support image input)
    VISION_MODEL="${VISION_MODEL:-gpt-4o}"
    API_URL="https://models.github.ai/inference/chat/completions"

    call_vision_api() {
        local payload_file="$1"
        local response
        local curl_exit
        local http_code
        local response_body
        local error_msg

        set +e
        response=$(curl -sS -L -w $'\n%{http_code}' -H 'Content-Type: application/json' -H "Authorization: Bearer $GH_TOKEN" -X POST "$API_URL" -d "@$payload_file" 2>&1)
        curl_exit=$?
        set -e

        if [ "$curl_exit" -ne 0 ]; then
            log "Error: curl command failed (exit $curl_exit)."
            echo "Error: API call failed"
            return 1
        fi

        http_code="${response##*$'\n'}"
        response_body="${response%$'\n'*}"

        if [[ ! "$http_code" =~ ^[0-9]{3}$ ]] || [ "$http_code" -ge 400 ]; then
            error_msg=$(echo "$response_body" | jq -r '.error.message // .message // empty' 2>/dev/null || true)
            log "Error: Vision API call failed (HTTP ${http_code}) - ${error_msg:-$response_body}"
            echo "Error: Vision API call failed"
            return 1
        fi

        echo "$response_body" | jq -r '.choices[0].message.content // ""'
    }

    # Define individual regex patterns for GitHub image URLs
    IMG_PAT_USER_IMAGES="https?://user-images\.githubusercontent\.com/[^?[:space:]]+\.(png|jpe?g|gif|bmp|svg|webp)(\?[^[:space:]]*)?"
    IMG_PAT_USER_ATTACHMENTS="https?://github\.com/user-attachments/assets/[a-f0-9-]+(\?[^[:space:]]*)?"
    IMG_PAT_REPO_ASSETS="https?://github\.com/${GH_REPO}/assets/[0-9]+/[a-fA-F0-9-]+(\?[^[:space:]]*)?"
    COMBINED_IMAGE_URL_PATTERNS="(${IMG_PAT_USER_IMAGES}|${IMG_PAT_USER_ATTACHMENTS}|${IMG_PAT_REPO_ASSETS})"

    IMAGE_URLS=$(echo "$ISSUE_BODY" | grep -oE "!\[[^]]*\]\((${COMBINED_IMAGE_URL_PATTERNS})\)" | sed -E 's/^!\[[^]]*\]\((.*)\)$/\1/' || true)

    IMG_COUNT=0
    MAX_IMG_SIZE=524288

    if [ -n "$IMAGE_URLS" ]; then
        log "Found image URLs. Processing..."
        while IFS= read -r URL; do
            if [ -z "$URL" ]; then continue; fi
            URL=$(echo "$URL" | sed 's/[)]*$//')
            IMG_COUNT=$((IMG_COUNT + 1))
            IMG_FILENAME="$TMP_DIR/image_$IMG_COUNT"
            log "Processing Image $IMG_COUNT: $URL"

            if ! curl -sL --fail -o "$IMG_FILENAME" "$URL"; then
                log "Warning: Failed to download image $IMG_COUNT ($URL). Skipping."
                continue
            fi

            IMG_SIZE=$(wc -c < "$IMG_FILENAME" | tr -d ' ')
            if [ "$IMG_SIZE" -gt "$MAX_IMG_SIZE" ]; then
                log "Error: Image '$IMG_FILENAME' ($IMG_SIZE bytes) exceeds limit ($MAX_IMG_SIZE bytes). Skipping."
                rm "$IMG_FILENAME"
                continue
            fi

            MIME_TYPE=$(file --mime-type -b "$IMG_FILENAME")
            if [[ ! "$MIME_TYPE" == image/* ]]; then
                log "Warning: File for image $IMG_COUNT is not an image ($MIME_TYPE). Skipping."
                rm "$IMG_FILENAME"
                continue
            fi

            base64 < "$IMG_FILENAME" | tr -d '\n' > "$TMP_DIR/b64_data.txt"

            IMG_PROMPT="Translate any Chinese text in this image to English. If no Chinese text is found, respond *only* with 'NO_CHINESE_TEXT_FOUND'."
            IMG_PAYLOAD=$(jq -n \
                            --arg model "$VISION_MODEL" \
                            --arg prompt "$IMG_PROMPT" \
                            --arg mime "$MIME_TYPE" \
                            --rawfile data "$TMP_DIR/b64_data.txt" \
                            '{ "model": $model, "messages": [ { "role": "user", "content": [ { "type": "text", "text": $prompt }, { "type": "image_url", "image_url": { "url": ("data:" + $mime + ";base64," + $data) } } ] } ] }')

            if [ -z "$IMG_PAYLOAD" ]; then
                log "Error: Failed to create JSON payload for image $IMG_COUNT. Skipping."
                rm "$IMG_FILENAME"
                continue
            fi

            echo "$IMG_PAYLOAD" > "$TMP_DIR/vision_payload.json"
            IMG_TRANS=$(call_vision_api "$TMP_DIR/vision_payload.json" || echo '')

            if [[ "$IMG_TRANS" != "NO_CHINESE_TEXT_FOUND" && "$IMG_TRANS" != Error:* && -n "$IMG_TRANS" ]]; then
                log "Image $IMG_COUNT: Translation found."
                SCREENSHOT_TRANSLATIONS+=$'\n\n'"**Screenshot $IMG_COUNT Translation:**"$'\n'"${IMG_TRANS}"
            else
                log "Image $IMG_COUNT: No Chinese text found or translation failed ('$IMG_TRANS')."
            fi
            rm "$IMG_FILENAME"

        done <<< "$IMAGE_URLS"
    fi
fi

# --- Combine & Output ---
if [[ "$TEXT_TRANSLATION" == "NO_TRANSLATION_NEEDED" && -z "$SCREENSHOT_TRANSLATIONS" ]]; then
    log "No translation needed for text or images."
    echo "NO_TRANSLATION_NEEDED"
else
    if [[ "$TEXT_TRANSLATION" == "NO_TRANSLATION_NEEDED" ]]; then
        FINAL_OUTPUT="$ISSUE_TITLE\n$ISSUE_BODY"
    else
        FINAL_OUTPUT="$TEXT_TRANSLATION"
    fi

    if [ -n "$SCREENSHOT_TRANSLATIONS" ]; then
        FINAL_OUTPUT+="\n\n---\n## Translated Screenshots$SCREENSHOT_TRANSLATIONS"
    fi

    echo -e "$FINAL_OUTPUT"
fi

log "Script finished."
