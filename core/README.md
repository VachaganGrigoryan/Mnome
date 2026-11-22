# Mnome core

Stateless Rust search and layout engine, linked as `libmnome_core.a`.

ABI v1 accepts borrowed UTF-8 JSON bytes and returns owned UTF-8 JSON bytes.
Copy the response before calling `mnome_free` exactly once. Never modify the
returned pointer/length, free it with another allocator, or retain pointers
after freeing. Invalid non-null input pointers cannot be validated by Rust:
the caller must provide a live readable allocation. Null input and requests
over 16 MiB are rejected. Rust panics during dispatch are contained; allocation
failure may still abort the process, as with ordinary native allocation.

Requests:

```json
{"version":1,"op":"search","query":"term","apps":[{"id":"path","name":"Terminal"}]}
{"version":1,"op":"layout","width":1280,"height":720,"windows":[{"id":1,"width":800,"height":600}]}
```

Responses contain `ok:true` with `apps` or `cards`; errors contain `ok:false`
and `error`. Card positions use a top-left origin in viewport-local logical
coordinates. Layout preserves input order and aspect ratio. Search is
case-insensitive with exact, prefix, then substring ranking and deterministic
name/ID tie-breaking. Window IDs are opaque JSON values and remain in Swift's
enumeration scope; no platform objects or image data cross the ABI.

Validation: `cargo fmt --check`, `cargo test --offline`,
`cargo clippy --offline -- -D warnings`, `cargo build --offline --release`.

## Dock operation

ABI v1 accepts `{"version":1,"op":"dock","favorites":[{"id":"app.id","name":"App"}],"running":[]}` and returns `{"ok":true,"items":[{"id":"app.id","name":"App","pinned":true,"running":false}]}`. Swift supplies resolved favorite applications and ordinary running applications, using one stable identity per application. Unavailable favorites are retained in Swift storage but omitted from this input. Favorites keep their first occurrence and saved order; running-only entries are deduplicated and sorted by lowercase name and identity. Native application objects remain in Swift.

## HIG overview layout and navigation

`layout` accepts optional nonnegative `min_card_width`, `min_card_height` and `caption_height` (default zero). Cards expose full interaction bounds in `x/y/width/height` and an aspect-preserving `preview` rectangle in absolute content coordinates. `content_height` defines the scroll extent. A viewport narrower than the requested minimum uses one width-constrained column. Card height reserves the caption independently of the preview aspect ratio.

`navigate` accepts `cards` containing IDs and rectangle coordinates, `selected`, and `direction` (`left`, `right`, `up`, `down`). It returns `selected`: the closest center in that directional half-plane, with stable input-order ties. Edges retain selection; an unknown selection starts at the first card, and an empty list returns null. Swift scopes navigation to the focused display/content and remains responsible for focus and scrolling.

## Window policy

`{"version":1,"op":"wm","state":null,"event":{"type":"displays","main":1,"displays":[{"id":1,"frame":{"x":0,"y":0,"w":1280,"h":800},"work":{"x":0,"y":32,"w":1280,"h":768}}]}}` returns `{"ok":true,"revision":1,"state":{...},"ops":[]}`. The core keeps nothing: pass the returned `state` back unchanged with the next event, and `null` to start afresh. State of another `schema`, unknown events and unknown fields are refused. Coordinates are whole points with a top-left origin.

Events are observations (`displays`, `opened`, `closed`, `focused`, `moved`, `minimized`, `fullscreen`, `sticky`) or commands (`activate`, `minimize`, `toggle_maximize`, `restore`, `snap`, `tile`, `center`, `resize`, `to_display`, `drag_away`, `drag_border`, `set_workspace`, `step_workspace`, `to_workspace`, `show_desktop`, `cycle`). Only commands ask for focus. `ops` are in execution order: `unminimize`, `unpark` and `place`, then `focus`, then `park` and `minimize`. A window is `minimized` only when the person did that and parked only by us; hidden windows are never placed and their frames never recorded. Workspaces exist on the main display; other displays always show their windows. `{"op":"wm_hit","state":...,"x":0,"y":0}` returns the snap zone and tile border under a point.

`geometry.rs` and `model.rs` are adapted from the HayOS `hay-wm` crate, by the same author, which is under the draft Azat License. Mnome has no license file yet: settle the terms before distributing it.
