//! Stateless search/layout engine. All platform objects remain in Swift.
mod geometry;
mod model;

use std::collections::HashSet;

use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
struct App {
    id: String,
    name: String,
}
#[derive(Deserialize)]
struct Window {
    id: Value,
    width: f64,
    height: f64,
}

fn process(input: &[u8]) -> Result<Value, String> {
    let value: Value = serde_json::from_slice(input).map_err(|e| e.to_string())?;
    if value.get("version").and_then(Value::as_u64).unwrap_or(1) != 1 {
        return Err("unsupported ABI version".into());
    }
    match value["op"].as_str() {
        Some("search") => {
            let apps: Vec<App> =
                serde_json::from_value(value["apps"].clone()).map_err(|e| e.to_string())?;
            let query = value["query"].as_str().unwrap_or("").trim().to_lowercase();
            let mut found: Vec<_> = apps
                .into_iter()
                .filter_map(|a| {
                    let name = a.name.to_lowercase();
                    let rank = if name == query {
                        0
                    } else if name.starts_with(&query) {
                        1
                    } else if name.contains(&query) {
                        2
                    } else {
                        return None;
                    };
                    Some((rank, name, a))
                })
                .collect();
            found.sort_by(|a, b| (&a.0, &a.1, &a.2.id).cmp(&(&b.0, &b.1, &b.2.id)));
            Ok(
                json!({"apps": found.into_iter().map(|(_,_,a)| json!({"id":a.id,"name":a.name})).collect::<Vec<_>>()}),
            )
        }
        Some("dock") => {
            let favorites: Vec<App> =
                serde_json::from_value(value["favorites"].clone()).map_err(|e| e.to_string())?;
            let mut running: Vec<App> =
                serde_json::from_value(value["running"].clone()).map_err(|e| e.to_string())?;
            let running_ids: HashSet<_> = running.iter().map(|app| app.id.clone()).collect();
            let mut seen = HashSet::new();
            let mut items = Vec::new();
            for app in favorites {
                if seen.insert(app.id.clone()) {
                    items.push(json!({"id":app.id,"name":app.name,"pinned":true,"running":running_ids.contains(&app.id)}));
                }
            }
            running.sort_by(|a, b| {
                (a.name.to_lowercase(), &a.id, &a.name).cmp(&(
                    b.name.to_lowercase(),
                    &b.id,
                    &b.name,
                ))
            });
            for app in running {
                if seen.insert(app.id.clone()) {
                    items.push(json!({"id":app.id,"name":app.name,"pinned":false,"running":true}));
                }
            }
            Ok(json!({"items":items}))
        }
        Some("layout") => {
            let windows: Vec<Window> =
                serde_json::from_value(value["windows"].clone()).map_err(|e| e.to_string())?;
            let width = value["width"].as_f64().unwrap_or(0.0);
            let height = value["height"].as_f64().unwrap_or(0.0);
            if width <= 0.0
                || height <= 0.0
                || !width.is_finite()
                || !height.is_finite()
                || windows.iter().any(|w| {
                    !w.width.is_finite()
                        || !w.height.is_finite()
                        || w.width <= 0.0
                        || w.height <= 0.0
                })
            {
                return Err("dimensions must be finite and positive".into());
            }
            let min_width = value["min_card_width"].as_f64().unwrap_or(0.0);
            let min_height = value["min_card_height"].as_f64().unwrap_or(0.0);
            let caption = value["caption_height"].as_f64().unwrap_or(0.0);
            if [min_width, min_height, caption]
                .iter()
                .any(|n| !n.is_finite() || *n < 0.0)
            {
                return Err("card requirements must be finite and nonnegative".into());
            }
            if windows.is_empty() {
                return Ok(json!({"cards":[],"content_height":height}));
            }
            let ideal_cols = ((windows.len() as f64 * width / height).sqrt().ceil() as usize)
                .clamp(1, windows.len());
            let cols = if min_width > 0.0 {
                ideal_cols.min((width / min_width).floor().max(1.0) as usize)
            } else {
                ideal_cols
            };
            let rows = windows.len().div_ceil(cols);
            let cw = width / cols as f64;
            let ch = (height / rows as f64).max(min_height).max(caption + 1.0);
            let content_height = (rows as f64 * ch).max(height);
            if !content_height.is_finite() {
                return Err("layout extent overflow".into());
            }
            let cards: Vec<_> = windows
                .into_iter()
                .enumerate()
                .map(|(i, w)| {
                    let x = (i % cols) as f64 * cw;
                    let y = (i / cols) as f64 * ch;
                    let scale = (cw * 0.9 / w.width).min((ch - caption) * 0.9 / w.height);
                    let (ww, hh) = (w.width * scale, w.height * scale);
                    let preview =
                        json!({"x":x+(cw-ww)/2.0,"y":y+(ch-caption-hh)/2.0,"width":ww,"height":hh});
                    json!({"id":w.id,"x":x,"y":y,"width":cw,"height":ch,"preview":preview})
                })
                .collect();
            Ok(json!({"cards":cards,"content_height":content_height}))
        }
        Some("navigate") => {
            #[derive(Deserialize)]
            struct Card {
                id: Value,
                x: f64,
                y: f64,
                width: f64,
                height: f64,
            }
            let cards: Vec<Card> =
                serde_json::from_value(value["cards"].clone()).map_err(|e| e.to_string())?;
            if cards.iter().any(|c| {
                ![c.x, c.y, c.width, c.height].iter().all(|n| n.is_finite())
                    || c.width <= 0.0
                    || c.height <= 0.0
            }) {
                return Err("invalid navigation geometry".into());
            }
            let direction = value["direction"].as_str().unwrap_or("");
            if !["left", "right", "up", "down"].contains(&direction) {
                return Err("invalid direction".into());
            }
            let Some(origin) = cards.iter().find(|c| c.id == value["selected"]) else {
                return Ok(json!({"selected":cards.first().map(|c| &c.id)}));
            };
            let center = |c: &Card| (c.x + c.width / 2.0, c.y + c.height / 2.0);
            let (ox, oy) = center(origin);
            let selected = cards
                .iter()
                .enumerate()
                .filter_map(|(index, c)| {
                    let (x, y) = center(c);
                    let (dx, dy) = (x - ox, y - oy);
                    let (forward, side) = match direction {
                        "left" => (-dx, dy),
                        "right" => (dx, dy),
                        "up" => (-dy, dx),
                        _ => (dy, dx),
                    };
                    (forward > 0.0).then_some((forward.hypot(side), side.abs(), index, c))
                })
                .min_by(|a, b| {
                    a.0.total_cmp(&b.0)
                        .then(a.1.total_cmp(&b.1))
                        .then(a.2.cmp(&b.2))
                })
                .map(|(_, _, _, c)| &c.id)
                .unwrap_or(&origin.id);
            Ok(json!({"selected":selected}))
        }
        Some("wm") => {
            let mut wm = window_state(&value["state"])?;
            let event: model::Event =
                serde_json::from_value(value["event"].clone()).map_err(|e| e.to_string())?;
            let ops = wm.reduce(event)?;
            Ok(json!({"revision": wm.revision(), "state": wm, "ops": ops}))
        }
        Some("wm_hit") => {
            let wm = window_state(&value["state"])?;
            let coordinate = |key: &str| {
                value[key]
                    .as_i64()
                    .and_then(|n| i32::try_from(n).ok())
                    .ok_or_else(|| format!("{key} must be a 32-bit integer"))
            };
            let (snap, border) = wm.hit(coordinate("x")?, coordinate("y")?);
            let border = border.map(|(key, border)| json!({"key": key, "border": border}));
            Ok(json!({"snap": snap, "border": border}))
        }
        _ => Err("unknown operation".into()),
    }
}

/// Null means a fresh start.
fn window_state(value: &Value) -> Result<model::Wm, String> {
    if value.is_null() {
        return Ok(model::Wm::default());
    }
    let wm: model::Wm = serde_json::from_value(value.clone()).map_err(|e| e.to_string())?;
    wm.check()?;
    Ok(wm)
}

#[repr(C)]
pub struct MnomeBuffer {
    pub ptr: *mut u8,
    pub len: usize,
}

/// Execute ABI v1 request. Returns JSON with `ok` and either result fields or `error`.
/// # Safety
/// Non-null input must reference `len` readable bytes throughout this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mnome_request(input: *const u8, len: usize) -> MnomeBuffer {
    let result = std::panic::catch_unwind(|| {
        if input.is_null() || len > 16 * 1024 * 1024 {
            return Err("invalid input buffer".into());
        }
        // SAFETY: caller guarantees readable storage; size is bounded above.
        process(unsafe { std::slice::from_raw_parts(input, len) })
    })
    .unwrap_or_else(|_| Err("internal core failure".into()));
    let response = match result {
        Ok(mut v) => {
            v["ok"] = json!(true);
            v
        }
        Err(e) => json!({"ok":false,"error":e}),
    };
    let bytes = response.to_string().into_bytes().into_boxed_slice();
    let len = bytes.len();
    MnomeBuffer {
        ptr: Box::into_raw(bytes).cast::<u8>(),
        len,
    }
}

/// Release a returned response exactly once.
/// # Safety
/// Buffer must be an unmodified, not-yet-freed result of `mnome_request`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mnome_free(buffer: MnomeBuffer) {
    if !buffer.ptr.is_null() {
        // SAFETY: the ABI contract requires the original boxed-slice pointer/length.
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(buffer.ptr, buffer.len)) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ranks_exact_before_prefix_and_substring() {
        let v=process(br#"{"op":"search","query":"term","apps":[{"id":"1","name":"Xterm"},{"id":"2","name":"Terminal"},{"id":"3","name":"Term"}]}"#).unwrap();
        assert_eq!(v["apps"][0]["id"], "3");
        assert_eq!(v["apps"][1]["id"], "2");
    }
    #[test]
    fn layout_stays_in_viewport() {
        let windows: Vec<_> = (0..17)
            .map(|i| json!({"id":i,"width":1000,"height":300}))
            .collect();
        let v = process(
            json!({"op":"layout","width":640,"height":400,"windows":windows})
                .to_string()
                .as_bytes(),
        )
        .unwrap();
        for c in v["cards"].as_array().unwrap() {
            assert!(c["x"].as_f64().unwrap() + c["width"].as_f64().unwrap() <= 640.0);
            assert!(c["y"].as_f64().unwrap() + c["height"].as_f64().unwrap() <= 400.0);
        }
    }
    #[test]
    fn rejects_invalid_dimensions_and_version() {
        assert!(process(br#"{"op":"layout","width":0,"height":4,"windows":[]}"#).is_err());
        assert!(process(br#"{"version":2,"op":"search","apps":[]}"#).is_err());
    }
    #[test]
    fn dock_preserves_favorites_and_deduplicates_running_apps() {
        let result = process(json!({"version":1,"op":"dock",
            "favorites":[{"id":"z","name":"Pinned Z"},{"id":"a","name":"Pinned A"},{"id":"z","name":"Duplicate"}],
            "running":[{"id":"a","name":"Running A"},{"id":"c","name":"Zulu"},{"id":"b","name":"alpha"},{"id":"b","name":"alpha"}]
        }).to_string().as_bytes()).unwrap();
        assert_eq!(
            result["items"],
            json!([
                {"id":"z","name":"Pinned Z","pinned":true,"running":false},
                {"id":"a","name":"Pinned A","pinned":true,"running":true},
                {"id":"b","name":"alpha","pinned":false,"running":true},
                {"id":"c","name":"Zulu","pinned":false,"running":true}
            ])
        );
    }
    #[test]
    fn dock_empty_and_running_order_are_deterministic() {
        assert_eq!(
            process(br#"{"op":"dock","favorites":[],"running":[]}"#).unwrap()["items"],
            json!([])
        );
        let result = process(br#"{"op":"dock","favorites":[],"running":[{"id":"z","name":"App"},{"id":"a","name":"app"}]}"#).unwrap();
        assert_eq!(result["items"][0]["id"], "a");
        assert!(process(br#"{"op":"dock","favorites":[],"running":[{"name":"No ID"}]}"#).is_err());
    }
    #[test]
    fn minimum_cards_scroll_and_reserve_caption() {
        let windows: Vec<_> = (0..12)
            .map(|id| json!({"id":id,"width":20,"height":1000}))
            .collect();
        let result=process(json!({"op":"layout","windows":windows,"width":320,"height":200,"min_card_width":160,"min_card_height":128,"caption_height":32}).to_string().as_bytes()).unwrap();
        assert!(result["content_height"].as_f64().unwrap() > 200.0);
        for card in result["cards"].as_array().unwrap() {
            assert!(card["width"].as_f64().unwrap() >= 160.0);
            assert!(card["height"].as_f64().unwrap() >= 128.0);
            let preview = &card["preview"];
            assert!(
                preview["y"].as_f64().unwrap() + preview["height"].as_f64().unwrap()
                    <= card["y"].as_f64().unwrap() + card["height"].as_f64().unwrap() - 32.0
            );
        }
        let replacement=process(br#"{"op":"layout","width":320,"height":200,"windows":[{"id":"replacement","width":200,"height":100}]}"#).unwrap();
        assert_eq!(replacement["cards"][0]["id"], "replacement");
    }
    #[test]
    fn spatial_navigation_and_edges_are_deterministic() {
        let cards = json!([
            {"id":"a","x":0,"y":0,"width":100,"height":100},
            {"id":"b","x":100,"y":0,"width":100,"height":100},
            {"id":"c","x":0,"y":100,"width":100,"height":100}
        ]);
        for (selected, direction, expected) in [
            ("a", "right", "b"),
            ("a", "down", "c"),
            ("b", "left", "a"),
            ("a", "up", "a"),
            ("missing", "left", "a"),
        ] {
            let result = process(
                json!({"op":"navigate","cards":cards,"selected":selected,"direction":direction})
                    .to_string()
                    .as_bytes(),
            )
            .unwrap();
            assert_eq!(result["selected"], expected);
        }
        assert!(process(br#"{"op":"navigate","cards":[],"direction":"diagonal"}"#).is_err());
        assert!(
            process(br#"{"op":"navigate","cards":[],"direction":"left"}"#).unwrap()["selected"]
                .is_null()
        );
    }
    #[test]
    fn ffi_roundtrip_and_invalid_input() {
        for input in [b"invalid".as_slice(), br#"{"op":"search","apps":[]}"#] {
            // SAFETY: input is a live slice and output is released once after copying.
            unsafe {
                let b = mnome_request(input.as_ptr(), input.len());
                let v: Value =
                    serde_json::from_slice(std::slice::from_raw_parts(b.ptr, b.len)).unwrap();
                assert!(v["ok"].is_boolean());
                mnome_free(b);
            }
        }
    }

    #[test]
    fn window_operations_round_trip_through_the_abi() {
        let displays = json!({"type":"displays","main":7,"displays":[{"id":7,"frame":{"x":0,"y":0,"w":1280,"h":800},"work":{"x":0,"y":32,"w":1280,"h":768}}]});
        let step = |state: &Value, event: Value| {
            process(
                json!({"version":1,"op":"wm","state":state,"event":event})
                    .to_string()
                    .as_bytes(),
            )
        };
        let state = step(&Value::Null, displays).unwrap()["state"].clone();
        let opened = json!({"type":"opened","id":4294967295u64,"app":"a","rect":{"x":10,"y":50,"w":300,"h":200},"minimized":false,"fullscreen":false});
        let out = step(&state, opened).unwrap();
        assert_eq!(out["ops"], json!([]));
        assert_eq!(out["revision"], 2);
        let out = step(
            &out["state"],
            json!({"type":"snap","id":4294967295u64,"to":"left"}),
        )
        .unwrap();
        assert_eq!(
            out["ops"],
            json!([{"op":"place","window":4294967295u64,"rect":{"x":0,"y":32,"w":640,"h":768}},{"op":"focus","window":4294967295u64}])
        );
        let hit = process(
            json!({"op":"wm_hit","state":out["state"],"x":640,"y":400})
                .to_string()
                .as_bytes(),
        )
        .unwrap();
        assert_eq!(hit["border"]["border"], json!({"column":{"boundary":1}}));
        assert!(step(&out["state"], json!({"type":"nonsense"})).is_err());
        assert!(step(&out["state"], json!({"type":"closed","id":1,"extra":true})).is_err());
        let mut old = out["state"].clone();
        old["schema"] = json!(0);
        assert!(step(&old, json!({"type":"show_desktop"})).is_err());
    }
}
