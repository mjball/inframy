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

✅ Matt's TV: `api_version` → error `-9`; `get_api_version` → `"2.03"`. Skip straight to `get_api_version` for this TV,
but keep the fallback order for robustness.

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

Probe run 2026-10-22 with samsungtvws 3.0.6, read-only calls only. Raw traffic from `tools/probe.py --debug`.

### The TV

| | |
|---|---|
| Model | `QN55LS03TAFXZA` (REST `model`: `20_NIKEM_FRAME`), Tizen, `resolution` `3840x2160` |
| REST API `version` | `2.0.25` (`remote: "1.0"`), `TokenAuthSupport: "true"`, `firmwareVersion: "Unknown"` |
| **Art API version** | **`2.03`** → newer protocol family (d2d socket transfers), not the 0.97 WebSocket-binary path |
| Network | Wi-Fi, static `192.168.5.86/22` (main eero network "Mordor"), gateway set to its own IP so it has **no internet**. eero reservation on the same IP. |
| Wi-Fi MAC (for Wake-on-LAN) | `5C:C1:D7:62:D2:12` |
| Device id | `uuid:94b159b8-52d6-4f07-b584-eae44c5817c6` (stable; use it to recognise the TV, not the IP) |
| `get_device_info` | `tv_flash_size: "8"`, `support_myshelf: "FALSE"`, `support_motion_sensor: "TRUE"`, `support_brightness_sensor: "TRUE"`, `support_color_tone: "TRUE"`, `current_rotation_status: 1` |

### Discovery ✅

- **Bonjour works** (use this first): service `_samsungmsf._tcp`, instance name = device id, port 8001. TXT record:
  `id=uuid:94b1… remote=1.0 ve=2.0.25 md=Samsung Smart TV fn=[TV] The Frame se=http://192.168.5.86:8001/api/v2/`.
- **SSDP stopped working** once the TV's gateway was set to its own IP: it answered M-SEARCH
  (`urn:samsung.com:device:RemoteControlReceiver:1` / DIAL) while on DHCP, but not after. Keep SSDP only as a fallback.
- Confirm with `GET http://<ip>:8001/api/v2/` → `device.FrameTVSupport == "true"`.

### Connection and pairing ✅ (surprise)

- `wss://<ip>:8002/api/v2/channels/com.samsung.art-app?name=SW5mcmFteQ%3D%3D` (base64 "Inframy"), **no token**.
- The TV answered with `ms.channel.connect` **without a `token` field**, then `ms.channel.ready`, and served every
  art request. No token was issued, so nothing was saved. Whether an Allow prompt appeared on the TV: _ask Matt_.
  The art channel on this TV apparently doesn't require pairing; the remote-control channel probably still does.

```json
{"event":"ms.channel.connect","data":{"id":"fc8f6b80-…","clients":[
  {"id":"c9136dd5-…","isHost":true,"deviceName":"Smart Device","attributes":{"name":null},"connectTime":1792711830975},
  {"id":"fc8f6b80-…","isHost":false,"deviceName":"SW5mcmFteQ==","attributes":{"name":"SW5mcmFteQ=="},"connectTime":1792713899319}]}}
{"event":"ms.channel.ready","data":{}}
```

### Envelope ✅

Request and response shapes match the section above. Example (`get_api_version`):

```json
→ {"method":"ms.channel.emit","params":{"event":"art_app_request","to":"host",
   "data":"{\"request\": \"get_api_version\", \"id\": \"6fe5c223-…\", \"request_id\": \"6fe5c223-…\"}"}}
← {"event":"d2d_service_message","from":"c9136dd5-…",
   "data":"{\n  \"id\": \"6fe5c223-…\",\n  \"event\": \"api_version\",\n  \"version\": \"2.03\",\n  \"target_client_id\": \"fc8f6b80-…\"\n}"}
```

Errors: sub-event `error` with `error_code` as a **string** and the original request echoed in `request_data`.
**`-9` = request name not supported on this TV.**

```json
{"id":"9d78c679-…","event":"error","error_code":"-9",
 "request_data":"{\"request\": \"api_version\", …}","target_client_id":"fc8f6b80-…"}
```

### Requests

| Request | Result on Matt's TV |
|---|---|
| `get_api_version` | ✅ `"2.03"` |
| `api_version` | ❌ `-9` |
| `get_device_info` | ✅ (fields above) |
| `get_artmode_status` | ✅ `"off"` (TV was showing regular TV) |
| `get_current_artwork` | ✅ `{"content_id":"SAM-F0103","matte_id":"none","portrait_matte_id":"flexible_polar"}` |
| `get_content_list` | ✅ Whole TV holds **1 item**; `MY-C0002` is empty. See below. |
| `get_matte_list` | ✅ `matte_type_list`: none, myshelf, modernthin, modern, modernwide, flexible, shadowbox, panoramic, triptych, mix, squares. `matte_color_list`: black, neutral, antique, warm, polar, sand, seafoam, sage, burgandy (sic), navy, apricot, byzantine, lavender, redorange, skyblue, turquoise (each with R/G/B). |
| **`get_auto_rotation_status`** | ✅ **works** (older slideshow naming, as expected for 2020) |
| `get_slideshow_status` | ❌ `-9` (newer naming not supported) |
| `get_artmode_settings` | ❌ `-9` |
| `get_photo_filter_list` | ✅ None, Aqua, ArtDeco, Ink, Wash, Pastel, Feuve |
| `get_thumbnail` (d2d socket) | ✅ `SAM-F0103` → 33,041-byte JPEG |

Slideshow status (raw):

```json
{"id":"6ba9fc7e-…","event":"auto_rotation_status","value":"off","category_id":"","sub_category_id":"",
 "current_content_id":"","type":"","content_list":"","target_client_id":"fc8f6b80-…"}
```

Content list (everything on the TV):

```json
[{"content_id":"SAM-F0103","category_id":"M0002","matte_id":"none","portrait_matte_id":"shadowbox_polar",
  "width":3840,"height":2160,"image_date":"","content_type":"preinstall"}]
```

Note the category id is `M0002` here, not `MY-C…`. No personal (`MY-…`) content exists yet, so the uploaded-id
format is still unknown.

### Upload ✅ (d2d socket, matte none)

2026-10-22, with Matt's OK: one 3840×2160 test JPEG (269,878 bytes) → **`MY_F0001`** (underscore form).

```json
→ data: {"request":"send_image","id":"1759868b-…","request_id":"1759868b-…","file_type":"jpg","file_size":269878,
         "image_date":"2026:10:22 20:08:24","matte_id":"none","portrait_matte_id":"none",
         "conn_info":{"d2d_mode":"socket","connection_id":4134151049,"id":"1759868b-…"}}
← {"id":"1759868b-…","event":"ready_to_use",
   "conn_info":"{\"contentInfo\":\"{…\\\"id\\\":\\\"1759868b-…\\\"}\",\"event\":\"get_d2d_connection\",
                \"ip\":\"192.168.5.86\",\"port\":\"58006\",\"key\":\"<redacted>\",\"stat\":\"ok\",\"mode\":\"socket\"}"}
   (then: plain TCP to ip:port, 4-byte BE header length + header JSON with secKey=key + JPEG bytes)
← {"id":"1759868b-…","event":"image_added","content_id":"MY_F0001","matte_id":"none","portrait_matte_id":"none",
   "width":"3840","height":"2160","target_client_id":"…"}
← {"event":"image_added","content_id":"MY_F0001","category_id":"MY-C0002","matte_id":"none",
   "portrait_matte_id":"none","width":"3840","height":"2160"}          (second copy: broadcast, no id)
```

Notes:
- `ready_to_use.conn_info` is a JSON string containing **another** JSON string (`contentInfo`). `port` is a string.
  There is **no `secured` field**, so the socket is plain TCP on this TV.
- `image_added` arrives twice: once correlated by `id`, once as a broadcast with `category_id`. Dedupe by `content_id`.
- In `image_added`, `width`/`height` are **strings**; in `get_content_list` they're **numbers**.
- The new item in `get_content_list`:
  `{"content_id":"MY_F0001","category_id":"MY-C0002","matte_id":"none","portrait_matte_id":"none","width":3840,
  "height":2160,"image_date":"2026:10:22 20:08:24","content_type":"mobile"}`
- Uploading doesn't display the image or change art mode (`get_current_artwork` unchanged afterwards).

### Select / display ✅

2026-10-22, with Matt's OK. TV was in regular TV mode (`artmode_status` `off`).

```json
→ data: {"request":"select_image","category_id":"MY-C0002","content_id":"MY_F0001","show":true,"id":"e6620c46-…","request_id":"e6620c46-…"}
← {"id":"e6620c46-…","event":"image_selected","content_id":"MY_F0001","category_id":"MY-C0002","sub_category_id":null,
   "matte_id":"none","portrait_matte_id":"none","is_shown":"Yes","target_client_id":"…"}
← {"event":"image_selected","content_id":"MY_F0001","matte_id":"none","portrait_matte_id":"none","is_shown":"Yes"}   (broadcast copy)
```

- With `show: true`, the TV **switched itself into art mode** (`get_artmode_status` → `on` 3 s later).
- `get_current_artwork` → `MY_F0001`, `matte_id` `none`.
- Like `image_added`, `image_selected` arrives twice (correlated + broadcast).
- Visual check: the image showed with a thin off-white border that looked like a mat. **That border was in the
  test image itself** (a 12 px white outline the probe drew as a cropping check, ≈4 mm on a 55" panel). The TV's
  API and its own menu both report **no mat**, which is consistent with matte `none` working on upload.
  The probe now uses colored corner triangles instead.
- ✅ **Verified 2026-10-23:** border-free test image uploaded with matte `none` → `MY_F0002`, displayed with
  `select_image` (`show: true`). Matt confirmed: **full-screen, no mat, all four corner triangles visible** (no
  cropping). So an exact 3840×2160 JPEG uploaded with `matte_id: "none"` needs no follow-up `change_matte`.

### Matte changes

| Request | Result |
|---|---|
| `change_matte` `{content_id, matte_id:"none", portrait_matte_id:"none"}` | ❌ error **`-7`**: this TV rejects `portrait_matte_id` here. |
| `change_matte` `{content_id, matte_id:"none"}` | ✅ `{"event":"matte_changed","matte_id":"none"}` |
| `change_matte` `{content_id, matte_id:"modern_polar"}` | ✅ `matte_changed` (`type_color` format accepted) |

`get_current_artwork` and `get_content_list` reflect the stored matte. The TV's menu (remote → Mat) agreed ("No mat").

Other event seen while listening: `{"event":"go_to_standby"}` (broadcast, `d2d_service_message`) when the TV slept.

### Slideshow (shuffle) ✅

2026-10-23, with Matt's OK, while `MY_F0001` and `MY_F0002` were on the TV. Slideshow was `off` before and was
set back to `off` after.

```json
→ data: {"request":"set_auto_rotation_status","value":"15","category_id":"MY-C0002","type":"shuffleslideshow","id":"…","request_id":"…"}
← {"id":"…","event":"auto_rotation_changed","value":"15","category_id":"MY-C0002","sub_category_id":null,"type":"shuffleslideshow"}
→ data: {"request":"get_auto_rotation_status","id":"…","request_id":"…"}
← {"id":"…","event":"auto_rotation_status","value":"15","category_id":"MY-C0002","sub_category_id":"",
   "current_content_id":"MY_F0002","type":"shuffleslideshow",
   "content_list":"[{\"content_id\":\"MY_F0002\",\"category_id\":\"MY-C0002\",\"sub_category_id\":\"\",\"matte_id\":\"none\",\"portrait_matte_id\":\"none\",\"width\":3840,\"height\":2160}, …]"}
```

- `value` is minutes as a string, or `"off"`. **Every value tried was accepted and echoed back: 3, 15, 60, 720,
  1440, and also 7.** The TV doesn't validate intervals, so whether an odd value like 7 is actually honoured is
  unverified. Stick to values the TV's own menu offers.
- `value:"off"` → `auto_rotation_changed` `off`; status then reads back with empty `category_id`, `type`, `content_list`.
- Status includes the slideshow's `content_list` (JSON string) and `current_content_id`.
- `type: "shuffleslideshow"` (shuffle) or `"slideshow"` (in order, untested).

### Delete ✅

2026-10-23, with Matt's OK: deleted the two test images.

```json
→ data: {"request":"delete_image_list","content_id_list":[{"content_id":"MY_F0001"},{"content_id":"MY_F0002"}],"id":"a7dc8f7b-…","request_id":"a7dc8f7b-…"}
← {"event":"image_deleted","content_id":"MY_F0001"}                      (broadcast, one per item)
← {"event":"image_deleted","content_id":"MY_F0002"}
← {"id":"a7dc8f7b-…","event":"image_list_deleted","content_id_list":"[{\"content_id\":\"MY_F0001\"},{\"content_id\":\"MY_F0002\"}]"}
```

- Final response is `image_list_deleted`; its `content_id_list` is a JSON **string** (pretty-printed, with newlines).
- Deleting the displayed image made the TV fall back to `SAM-F0103`. TV now holds only `SAM-F0103` again.

### Broadcast copies arrive first

Several changes are announced twice: a broadcast without `id` and a reply with our `id`. For
`set_auto_rotation_status` the TV sent the **broadcast first**, then the reply. Correlate by `id` and ignore
the extra copy (InframyKit routes unclaimed messages to a broadcast stream).

### Thumbnail (Swift client) ✅

`inframy-cli thumbs` fetched `SAM-F0103` (33,041 bytes) via `get_thumbnail` with `conn_info` → first reply with
our `id` carries `conn_info` → read 4-byte header length + header JSON (`fileLength`, `fileID`, `fileType`,
`num`, `total`) + bytes from the d2d socket.

### Certificate

The TV's TLS certificate (port 8002) SHA-256: `0426ac7f01afe6494c5c6c008070cb1daaa3c7abf8fcf0738fd52c333362ea8a`.
InframyKit pins it after `pair`.

### Swift client on the real TV ✅

2026-10-23, with Matt's OK, all through `inframy-cli`: upload of a HEIC photo (rendered to 3840×2160 sRGB JPEG)
→ `MY_F0003` (`content_type` `mobile`, `matte_id` `none`), `select_image` → art mode on and showing,
`set_auto_rotation_status` 15 / `shuffleslideshow` / `MY-C0002` → status reads back on.

### Art service stalls ⚠️

2026-10-23, after a cold boot (TV back on DHCP, so with internet): the WebSocket still connects
(`ms.channel.connect` + `ready`) and REST answers, but the art service intermittently **ignores every request**:
no reply, no error, for 45 s+. The whole TV was laggy at the time. Unsupported names (`api_version`) were also
ignored instead of getting `-9`. **Fix that worked:** remote power button → TV mode → back to Art mode; replies
returned at ~0.1 s. Clients should use short timeouts and tell the user about this remedy.

### Single-photo slideshow wedges the TV ⚠️

2026-10-23. Shuffle was turned on (15 min, `MY-C0002`) at 10:49 with **one** photo in My Photos. From then on:
the whole TV was laggy (remote included), and after every restart the art service answered for ~1 min and
then stopped replying. Turning the slideshow **off** (sent during a responsive window right after a cold boot)
fixed it: replies at 0.02 s for 7½ min until the screen slept. Network changes (DNS block, no route) did not
fix it. **Inframy never enables shuffle with fewer than 2 photos.** Untested: shuffle with ≥ 2 photos.

### Motion sensor = off the network

When the motion sensor turns the screen off (nobody in the room), the TV drops off Wi-Fi entirely: no ping,
REST, Bonjour or art channel. It rejoins when someone walks in and the screen wakes. Background jobs can only
run while the screen is on, or after Wake-on-LAN (untested from this state).

### Sleep and Wake-on-LAN (2026-10-24)

- With the motion sensor's screen-off (no one in the room for ~6 min), the TV **leaves the network entirely**
  (no ping/REST/Bonjour), even with *Power On with Mobile* on. Monitor: reachable 13:05–13:13, Matt left 13:07.
- **Wake-on-LAN works:** from a full power-off (long-press power), the TV was back on the network **3 s** after
  the magic packet (`PowerState: on`). But it powered on **into the last input** (Apple TV, HDMI 1), not Art mode,
  and the art channel then accepts the WebSocket but never sends `ms.channel.ready` (2½ min+). So WOL from full
  off is not useful for background jobs. *Untested:* WOL from the motion-sensor sleep.
- Inframy's "Wake the TV to rotate" stays off by default.

### Storage (2026-10-24)

The art API has no storage query, but the TV shows it under **Settings → Support → Device Care → Manage Storage**:
2.19 GB used, **1.63 GB free** (before Matt removed unneeded apps). A detailed 3840×2160 render at JPEG quality 0.9
is ~2.9 MB, so roughly 500+ photos fit. Inframy uploads everything and stops with a "probably full" message if the
TV refuses an upload.

### Network setup that works (2026-10-23)

Manual IP `192.168.5.86/22` (eero reservation on the same IP), **gateway and DNS = the Pi-hole (`192.168.4.70`)**.
The Pi forwards packets in general (`ip_forward=1`, not Docker), so it has iptables `FORWARD` REJECT rules for
the TV (`tcp-reset` for TCP, `icmp-host-unreachable` otherwise; REJECT, not DROP, so the TV fails fast instead of
hanging) and `send_redirects=0`. Pi-hole denies all DNS for the TV's client. TV reports "connected, no internet".
Notes: Samsung's manual-IP screen defaults the mask to `255.255.255.0` (wrong for this /22); after changing
IP settings a **cold boot** (unplug ~30 s) is needed, and the TV can take 10+ minutes to rejoin Wi-Fi.

### Content list duplicates

Unfiltered `get_content_list` lists each personal photo **twice**: once with `category_id` `MY-C0002` and once
with `M0002` (the category the preinstalled `SAM-F0103` is in; probably "recent"). Always filter by
`MY-C0002` or dedupe by `content_id`.

### Still to verify

- Whether a `token` ever appears (e.g. if the TV's Access Notification setting changes).
- Whether odd slideshow intervals (e.g. 7 min) are honoured; which intervals the TV menu offers.
- Upload capacity limit and its error (Phase 4 concern).
