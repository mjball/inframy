# The Frame art-mode protocol

Status: **secondhand.** Everything below comes from open-source reverse-engineering, mainly
`samsungtvws/art.py` in NickWaterton/samsung-tv-ws-api and ha-samsungtv-smart issues #307/#311.
Mark each item ✅ once verified against Matt's TV (2020 55" LS03T) and paste the raw exchange
(tokens redacted) under "Verified on Matt's TV" at the bottom.

## Transport

- REST device info: `http://<ip>:8001/api/v2/` (JSON; `device.FrameTVSupport == "true"` on Frames; includes
  the TV's MAC for Wake-on-LAN).
- WebSocket: port **8002** (TLS, self-signed cert) or 8001 (plain). Art channel endpoint name:
  `com.samsung.art-app`. In samsungtvws the URL has the form
  `wss://<ip>:8002/api/v2/channels/com.samsung.art-app?name=<base64 client name>&token=<token>` (verify).
- First connection shows an Allow prompt on the TV. The token arrives in the connect event and must be reused
  on later connections (verify the exact field when pairing in Phase 0).
- After connecting, wait for the `ms.channel.ready` event before sending requests.

## Request / response envelope

Request (text frame):

```json
{
  "method": "ms.channel.emit",
  "params": {
    "event": "art_app_request",
    "to": "host",
    "data": "{\"request\": \"get_content_list\", \"category\": \"MY-C0002\", \"id\": \"<uuid>\", \"request_id\": \"<uuid>\"}"
  }
}
```

Notes:
- `data` is a **JSON-encoded string**, not an object.
- Send both `id` (older API) and `request_id` (newer API) with the same UUID.
- Responses arrive as events named `d2d_service_message`; their `data` is again a JSON string. Match on
  `request_id` or `id`. A sub-`event` of `"error"` carries `error_code` (e.g. `-1` = SYSTEM_FAIL).
- Some requests produce an intermediate event before the final one (uploads: `ready_to_use`, then `image_added`).

## Version negotiation

1. Send `{"request": "api_version"}`. Newer TVs answer; older ones return an error.
2. On error, send `{"request": "get_api_version"}`.
3. Response field: `version`. A 2019 Frame reports `"0.97"`.

## Requests (newer naming unless noted)

| Purpose | Request | Key params / response |
|---|---|---|
| List content | `get_content_list` | `category` (optional). Response `content_list` is a JSON string array; filter on `category_id`. |
| Current artwork | `get_current_artwork` | |
| Select image | `select_image` | `content_id`, `category_id`, `show` (bool) |
| Delete | `delete_image_list` | `content_id_list: [{"content_id": "..."}]`; response echoes the list |
| Thumbnail | `get_thumbnail` / `get_thumbnail_list` | d2d socket on newer TVs; binary WS frame on 0.97 (#311) |
| Matte list | `get_matte_list` | `matte_type_list`, `matte_color_list` (JSON strings) |
| Change matte | `change_matte` | `content_id`, `matte_id` (`"none"` or `type_color` like `modern_apricot`), optional `portrait_matte_id`. Not every matte works at every image size. |
| Favourite | `change_favorite` | `content_id`, `status: on/off`; waits for `favorite_changed` |
| Art mode | `get_artmode_status` / `set_artmode_status` | `value: on/off` |
| Slideshow (newer) | `get_slideshow_status` / `set_slideshow_status` | `value`: minutes as string or `"off"`; `category_id`; `type`: `shuffleslideshow` or `slideshow` |
| Slideshow (older) | `get_auto_rotation_status` / `set_auto_rotation_status` | same params. Samsung renamed these in 2022 firmware; expect the **older** names on a 2020 TV. |
| Settings | `get_artmode_settings`, `set_brightness` ("0"–"10"), `set_color_temperature` ("-5"–"5"), `set_motion_timer`, `set_motion_sensitivity`, `set_brightness_sensor_setting` | |

Categories: `MY-C0002` = my photos (uploads land here), `MY-C0004` = favourites, `MY-C0008` = store.
Uploaded content ids look like `MY-F0020` or `MY_F0096` depending on firmware.

Allowed slideshow intervals are fixed by firmware (one tool documents 3m, 15m, 1h, 12h, 24h). Verify.

## Upload, newer TVs (d2d socket)

1. Send `send_image` with: `file_type` (`jpg`), `id`, `request_id`, `conn_info: {"d2d_mode": "socket",
   "connection_id": <random u32>, "id": <uuid>}`, `image_date` (`"YYYY:MM:DD HH:MM:SS"`), `matte_id`,
   `portrait_matte_id`, `file_size`.
2. Wait for sub-event `ready_to_use`. Its `conn_info` (JSON string) has `ip`, `port`, `key`, `secured`.
3. Open TCP to `ip:port` (wrap in TLS if `secured`). Send a 4-byte big-endian header length, then the header
   JSON `{"num":0,"total":1,"fileLength":<n>,"fileName":"dummy","fileType":"jpg","secKey":<key>,"version":"0.0.1"}`,
   then the image bytes.
4. Wait for `image_added` on the WebSocket. Response contains `content_id`.

A 2019 Frame (API 0.97) rejects step 1 with `SYSTEM_FAIL (-1)`.

## Upload, API 0.97 (WebSocket binary)

From ha-samsungtv-smart #307 (verified on a 2019 QN55LS03RAFXZC, returned `MY_F0096`):

- Inner request: `{"request": "send_image", "file_type": "JPEG", "matte_id": "none", "id": "<uuid>"}`.
- Wrap it in the usual `ms.channel.emit` envelope, serialize compactly to UTF-8.
- Send **one binary frame**: 2-byte big-endian length of the envelope, the envelope bytes, then the raw image
  bytes.
- Wait for the response matching the id; it contains `content_id`.

Thumbnails on 0.97 also come back as binary WebSocket frames (#311). Inspect the frame layout during Phase 0.

## Thumbnails, newer TVs (d2d socket)

Same handshake as upload but reversed: request includes `conn_info`, response gives `ip`/`port`/`secured`;
read a 4-byte big-endian header length, a JSON header (`fileLength`, `fileID`, `fileType`, `num`, `total`), then
`fileLength` bytes. `get_thumbnail_list` repeats header+data for `total` items.

## Verified on Matt's TV

_Nothing yet. Phase 0 fills this in._
