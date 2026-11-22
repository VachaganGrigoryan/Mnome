use super::*;

const MAIN: DisplayId = 1;
const SIDE: DisplayId = 2;
const MAIN_WORK: Rect = Rect::new(0, 32, 1280, 768);
const SIDE_WORK: Rect = Rect::new(1280, 0, 1920, 1080);
const FREE: Rect = Rect::new(100, 100, 400, 300);

fn displays() -> Vec<Display> {
    vec![
        Display {
            id: MAIN,
            frame: Rect::new(0, 0, 1280, 800),
            work: MAIN_WORK,
        },
        Display {
            id: SIDE,
            frame: SIDE_WORK,
            work: SIDE_WORK,
        },
    ]
}
fn wm() -> Wm {
    let mut wm = Wm::default();
    go(
        &mut wm,
        Event::Displays {
            displays: displays(),
            main: MAIN,
        },
    );
    wm
}
fn go(wm: &mut Wm, event: Event) -> Vec<Op> {
    wm.reduce(event).expect("valid event")
}
fn open_at(wm: &mut Wm, id: Id, rect: Rect) -> Vec<Op> {
    go(
        wm,
        Event::Opened {
            id,
            app: format!("app{id}"),
            rect,
            minimized: false,
            fullscreen: false,
        },
    )
}
fn open(wm: &mut Wm, id: Id) {
    open_at(wm, id, FREE);
    go(wm, Event::Focused { id });
}
fn get(wm: &Wm, id: Id) -> &Window {
    wm.window(id).expect("window")
}
fn presence(wm: &Wm, id: Id) -> Presence {
    wm.presence(get(wm, id))
}
fn snap(wm: &mut Wm, id: Id, to: Snap) -> Vec<Op> {
    go(wm, Event::Snap { id, to })
}
fn key(workspace: WorkspaceId, display: DisplayId) -> GroupKey {
    GroupKey { workspace, display }
}
fn cells(wm: &Wm, k: GroupKey) -> Vec<Rect> {
    let g = wm.group(k).expect("group");
    (0..g.occupants.len())
        .filter_map(|i| g.rect(wm.work_area(k.display), i))
        .collect()
}

#[test]
fn maximize_restores_the_free_frame_and_restoring_again_does_nothing() {
    let mut w = wm();
    open(&mut w, 1);
    open(&mut w, 2);
    assert_eq!(
        go(&mut w, Event::ToggleMaximize { id: 1 }),
        [
            Op::Place {
                window: 1,
                rect: MAIN_WORK
            },
            Op::Focus { window: 1 }
        ]
    );
    go(&mut w, Event::Restore { id: 1 });
    assert_eq!(get(&w, 1).rect, FREE);
    assert!(go(&mut w, Event::Restore { id: 1 }).is_empty());
    let ops = go(&mut w, Event::Minimize { id: 1 });
    assert_eq!(ops, [Op::Focus { window: 2 }, Op::Minimize { window: 1 }]);
    assert_eq!(presence(&w, 1), Presence::Minimized);
}

#[test]
fn halves_share_a_boundary_and_minimizing_vacates_the_cell() {
    let mut w = wm();
    open(&mut w, 1);
    open(&mut w, 2);
    snap(&mut w, 1, Snap::Left);
    snap(&mut w, 2, Snap::Right);
    assert_eq!(get(&w, 1).rect.right(), get(&w, 2).rect.x);
    go(
        &mut w,
        Event::DragBorder {
            key: key(1, MAIN),
            border: Border::Column { boundary: 1 },
            coordinate: 800,
        },
    );
    assert_eq!(get(&w, 1).rect.w, 800);
    assert_eq!(get(&w, 2).rect.x, 800);
    go(&mut w, Event::Minimize { id: 1 });
    assert_eq!(get(&w, 1).placement, Placement::Free);
    open(&mut w, 3);
    snap(&mut w, 3, Snap::Left);
    go(&mut w, Event::Activate { id: 1 });
    assert_eq!(get(&w, 1).rect, FREE);
    assert!(matches!(get(&w, 3).placement, Placement::Tiled { .. }));
}

#[test]
fn tiling_to_the_same_half_again_restores() {
    let mut w = wm();
    open(&mut w, 1);
    open(&mut w, 2);
    snap(&mut w, 1, Snap::Left);
    snap(&mut w, 2, Snap::Right);
    snap(&mut w, 1, Snap::Left);
    assert_eq!(get(&w, 1).rect, FREE);
    assert!(matches!(get(&w, 2).placement, Placement::Tiled { .. }));
    // From a quarter, the half is a step up, not a toggle.
    snap(&mut w, 1, Snap::TopLeft);
    snap(&mut w, 1, Snap::Left);
    assert_eq!(get(&w, 1).rect, Rect::new(0, 32, 640, 768));
}

#[test]
fn corner_split_preserves_the_other_half_and_rounding() {
    let mut w = wm();
    let mut odd = displays();
    odd[0].work = Rect::new(3, 17, 1001, 701);
    go(
        &mut w,
        Event::Displays {
            displays: odd,
            main: MAIN,
        },
    );
    for id in 1..=4 {
        open(&mut w, id);
    }
    snap(&mut w, 1, Snap::Left);
    snap(&mut w, 2, Snap::Right);
    snap(&mut w, 3, Snap::TopLeft);
    snap(&mut w, 4, Snap::BottomLeft);
    assert_eq!(get(&w, 2).rect.h, 701);
    let c = cells(&w, key(1, MAIN));
    assert_eq!(c.len(), 3);
    assert_eq!(c[0].bottom(), c[1].y);
    assert_eq!(c[0].right(), c[2].x);
    assert_eq!(c[1].bottom(), 718);
    assert_eq!(c[2].right(), 1004);
    assert_eq!(get(&w, 1).placement, Placement::Free);
    // Back to a full half: the second row disappears and its window is freed.
    snap(&mut w, 3, Snap::Left);
    assert_eq!(get(&w, 3).rect.h, 701);
    assert_eq!(get(&w, 4).placement, Placement::Free);
    assert_eq!(get(&w, 2).rect, cells(&w, key(1, MAIN))[1]);
}

#[test]
fn all_layouts_partition_the_work_area_without_holes() {
    for layout in [
        Layout::Columns,
        Layout::WideNarrow,
        Layout::OneAndTwo,
        Layout::Quarters,
        Layout::Thirds,
    ] {
        let mut w = wm();
        open(&mut w, 1);
        go(
            &mut w,
            Event::Tile {
                id: 1,
                layout,
                cell: 0,
            },
        );
        let c = cells(&w, key(1, MAIN));
        assert_eq!(c.len(), layout.cells());
        let covered: i64 = c.iter().map(|r| i64::from(r.w) * i64::from(r.h)).sum();
        assert_eq!(covered, 1280 * 768);
        for (i, a) in c.iter().enumerate() {
            assert!(c[i + 1..].iter().all(|b| !a.intersects(*b)));
        }
    }
}

#[test]
fn displaced_window_keeps_its_free_frame_and_drag_away_keeps_the_grip() {
    let mut w = wm();
    open(&mut w, 1);
    open(&mut w, 2);
    snap(&mut w, 1, Snap::Left);
    snap(&mut w, 2, Snap::Left);
    assert_eq!(get(&w, 1).rect, FREE);
    go(
        &mut w,
        Event::DragAway {
            id: 2,
            x: 320,
            y: 50,
            header: 10,
        },
    );
    assert_eq!(get(&w, 2).rect, Rect::new(120, 40, 400, 300));
}

#[test]
fn workspaces_keep_one_empty_trailer_and_never_fall_below_two() {
    let mut w = wm();
    assert_eq!(w.workspaces, [1, 2]);
    go(&mut w, Event::StepWorkspace { delta: 1 });
    assert_eq!(w.workspaces, [2, 3]); // the empty first one went, a trailer came
    let mut w = wm();
    open(&mut w, 1);
    assert_eq!(w.workspaces, [1, 2]);
    go(&mut w, Event::SetWorkspace { workspace: 2 });
    open(&mut w, 2);
    assert_eq!(w.workspaces, [1, 2, 3]);
    snap(&mut w, 2, Snap::Left);
    go(
        &mut w,
        Event::ToWorkspace {
            id: 2,
            workspace: 3,
        },
    );
    assert_eq!(get(&w, 2).placement, Placement::Free);
    go(&mut w, Event::StepWorkspace { delta: 1 });
    assert_eq!(w.workspaces, [1, 3, 4]);
    assert_eq!(presence(&w, 1), Presence::Parked);
    assert_eq!(presence(&w, 2), Presence::Shown);
    go(&mut w, Event::Closed { id: 2 });
    go(&mut w, Event::SetWorkspace { workspace: 1 });
    assert_eq!(w.workspaces, [1, 4]);
    go(&mut w, Event::Closed { id: 1 });
    assert_eq!(w.workspaces, [1, 4]);
    go(&mut w, Event::StepWorkspace { delta: -1 });
    assert_eq!(w.current, 1);
}

#[test]
fn switching_shows_then_focuses_then_parks() {
    let mut w = wm();
    open(&mut w, 1);
    go(&mut w, Event::SetWorkspace { workspace: 2 });
    open(&mut w, 2);
    assert_eq!(
        go(&mut w, Event::SetWorkspace { workspace: 1 }),
        [
            Op::Unpark {
                window: 1,
                rect: FREE
            },
            Op::Focus { window: 1 },
            Op::Park { window: 2 },
        ]
    );
}

#[test]
fn observing_focus_on_a_parked_window_follows_it_without_a_focus_command() {
    let mut w = wm();
    open(&mut w, 1);
    go(&mut w, Event::SetWorkspace { workspace: 2 });
    open(&mut w, 2);
    let ops = go(&mut w, Event::Focused { id: 1 });
    assert_eq!(
        ops,
        [
            Op::Unpark {
                window: 1,
                rect: FREE
            },
            Op::Park { window: 2 }
        ]
    );
    assert_eq!(w.current, 1);
}

#[test]
fn hidden_windows_are_never_placed_and_their_frames_are_never_recorded() {
    let mut w = wm();
    open(&mut w, 1);
    go(&mut w, Event::ToggleMaximize { id: 1 });
    go(&mut w, Event::SetWorkspace { workspace: 2 });
    let parked = Rect::new(-1279, 768, 1280, 768);
    assert!(
        go(
            &mut w,
            Event::Moved {
                id: 1,
                rect: parked
            }
        )
        .is_empty()
    );
    let mut taller = displays();
    taller[0].work = Rect::new(0, 40, 1280, 760);
    assert!(
        go(
            &mut w,
            Event::Displays {
                displays: taller,
                main: MAIN
            }
        )
        .is_empty()
    );
    let ops = go(&mut w, Event::SetWorkspace { workspace: 1 });
    assert_eq!(
        ops[0],
        Op::Unpark {
            window: 1,
            rect: Rect::new(0, 40, 1280, 760)
        }
    );
}

#[test]
fn user_minimized_and_parked_stay_distinct() {
    let mut w = wm();
    open(&mut w, 1);
    go(&mut w, Event::Minimized { id: 1, on: true });
    assert!(go(&mut w, Event::SetWorkspace { workspace: 2 }).is_empty());
    assert!(go(&mut w, Event::SetWorkspace { workspace: 1 }).is_empty());
    assert_eq!(presence(&w, 1), Presence::Minimized);
    // Minimized while parked, then brought back: it must be placed, not left in the corner.
    go(&mut w, Event::Minimized { id: 1, on: false });
    go(&mut w, Event::SetWorkspace { workspace: 2 });
    go(&mut w, Event::Minimized { id: 1, on: true });
    let ops = go(&mut w, Event::Activate { id: 1 });
    assert!(ops.contains(&Op::Place {
        window: 1,
        rect: FREE
    }));
}

#[test]
fn secondary_display_ignores_workspaces_and_tiles_on_its_own() {
    let mut w = wm();
    open(&mut w, 1);
    open_at(&mut w, 2, Rect::new(1400, 100, 400, 300));
    assert_eq!(get(&w, 2).display, SIDE);
    snap(&mut w, 1, Snap::Left);
    snap(&mut w, 2, Snap::Left);
    assert_eq!(get(&w, 2).rect, Rect::new(1280, 0, 960, 1080));
    assert!(matches!(get(&w, 1).placement, Placement::Tiled { .. }));
    go(&mut w, Event::SetWorkspace { workspace: 2 });
    assert_eq!(presence(&w, 1), Presence::Parked);
    assert_eq!(presence(&w, 2), Presence::Shown);
    assert_eq!(
        w.hit(2240, 500).1,
        Some((key(0, SIDE), Border::Column { boundary: 1 }))
    );
    assert_eq!(w.hit(640, 400).1, None); // workspace 2 has no tiles
    go(
        &mut w,
        Event::ToWorkspace {
            id: 2,
            workspace: 1,
        },
    );
    assert_eq!(presence(&w, 2), Presence::Shown);
}

#[test]
fn border_hits_follow_a_dragged_grid() {
    let mut w = wm();
    open(&mut w, 1);
    go(
        &mut w,
        Event::Tile {
            id: 1,
            layout: Layout::OneAndTwo,
            cell: 0,
        },
    );
    let at = |w: &Wm, x, y| w.hit(x, y).1.map(|(_, b)| b);
    assert_eq!(at(&w, 640, 300), Some(Border::Column { boundary: 1 }));
    assert_eq!(
        at(&w, 900, 416),
        Some(Border::Row {
            column: 1,
            boundary: 1
        })
    );
    assert_eq!(at(&w, 200, 416), None);
    go(
        &mut w,
        Event::DragBorder {
            key: key(1, MAIN),
            border: Border::Column { boundary: 1 },
            coordinate: 800,
        },
    );
    assert_eq!(at(&w, 640, 300), None);
    assert_eq!(at(&w, 800, 300), Some(Border::Column { boundary: 1 }));
}

#[test]
fn moving_between_displays_keeps_size_position_and_maximized() {
    let mut w = wm();
    open(&mut w, 1);
    let right = || Event::ToDisplay {
        id: 1,
        direction: Direction::Right,
    };
    go(&mut w, right());
    assert_eq!(get(&w, 1).display, SIDE);
    assert_eq!((get(&w, 1).rect.w, get(&w, 1).rect.h), (400, 300));
    assert!(go(&mut w, right()).is_empty());
    go(&mut w, Event::ToggleMaximize { id: 1 });
    go(
        &mut w,
        Event::ToDisplay {
            id: 1,
            direction: Direction::Left,
        },
    );
    assert_eq!(get(&w, 1).rect, MAIN_WORK);
    assert_eq!(get(&w, 1).placement, Placement::Maximized);
    // A window brought to the main display joins the workspace on screen.
    go(&mut w, right());
    go(&mut w, Event::SetWorkspace { workspace: 2 });
    go(
        &mut w,
        Event::Moved {
            id: 1,
            rect: Rect::new(10, 50, 400, 300),
        },
    );
    assert_eq!(get(&w, 1).workspace, 2);
}

#[test]
fn unplugging_a_display_rehomes_its_windows() {
    let mut w = wm();
    open(&mut w, 1);
    open_at(&mut w, 2, Rect::new(2800, 900, 400, 300));
    go(&mut w, Event::SetWorkspace { workspace: 2 });
    let ops = go(
        &mut w,
        Event::Displays {
            displays: vec![displays()[0]],
            main: MAIN,
        },
    );
    assert_eq!(get(&w, 2).workspace, 2);
    assert_eq!(get(&w, 2).rect, Rect::new(880, 500, 400, 300));
    assert!(matches!(ops[..], [Op::Place { window: 2, .. }]));
    assert_eq!(presence(&w, 1), Presence::Parked);
}

#[test]
fn changing_the_main_display_unparks_the_old_and_adopts_the_new() {
    let mut w = wm();
    open(&mut w, 1);
    open_at(&mut w, 2, Rect::new(1400, 100, 400, 300));
    snap(&mut w, 2, Snap::Left);
    go(&mut w, Event::SetWorkspace { workspace: 2 });
    let ops = go(
        &mut w,
        Event::Displays {
            displays: displays(),
            main: SIDE,
        },
    );
    assert_eq!(
        ops,
        [Op::Unpark {
            window: 1,
            rect: FREE
        }]
    );
    assert_eq!(get(&w, 2).workspace, 2);
    assert_eq!(get(&w, 2).placement, Placement::Free);
    // The main display itself disappears: its windows keep their workspaces.
    go(&mut w, Event::StepWorkspace { delta: 1 });
    let was = get(&w, 2).workspace;
    go(
        &mut w,
        Event::Displays {
            displays: vec![displays()[0]],
            main: MAIN,
        },
    );
    assert_eq!(get(&w, 2).workspace, was);
    assert_eq!(get(&w, 1).workspace, w.current);
}

#[test]
fn unknown_main_display_is_rejected() {
    let mut w = wm();
    assert!(
        w.reduce(Event::Displays {
            displays: displays(),
            main: 9
        })
        .is_err()
    );
}

#[test]
fn sticky_and_fullscreen_windows_are_never_parked() {
    let mut w = wm();
    open(&mut w, 1);
    open(&mut w, 2);
    go(&mut w, Event::Sticky { id: 1, on: true });
    go(&mut w, Event::Fullscreen { id: 2, on: true });
    assert!(go(&mut w, Event::SetWorkspace { workspace: 2 }).is_empty());
    // Leaving full screen on another workspace parks it.
    assert_eq!(
        go(&mut w, Event::Fullscreen { id: 2, on: false }),
        [Op::Park { window: 2 }]
    );
    // A window that refused to park is reported sticky and simply shown again.
    assert_eq!(
        go(&mut w, Event::Sticky { id: 2, on: true }),
        [Op::Unpark {
            window: 2,
            rect: FREE
        }]
    );
}

#[test]
fn show_desktop_round_trip_keeps_tiles() {
    let mut w = wm();
    open(&mut w, 1);
    open(&mut w, 2);
    snap(&mut w, 1, Snap::Left);
    let tiled = get(&w, 1).rect;
    let ops = go(&mut w, Event::ShowDesktop);
    assert_eq!(
        ops,
        [Op::Minimize { window: 1 }, Op::Minimize { window: 2 }]
    );
    go(&mut w, Event::ShowDesktop);
    assert_eq!(get(&w, 1).rect, tiled);
    assert_eq!(presence(&w, 2), Presence::Shown);
}

#[test]
fn cycling_visits_only_shown_windows() {
    let mut w = wm();
    for id in 1..=3 {
        open(&mut w, id);
    }
    go(&mut w, Event::Minimize { id: 2 });
    go(&mut w, Event::Cycle { backwards: false });
    assert_eq!(w.focus, Some(1));
    go(&mut w, Event::Cycle { backwards: true });
    assert_eq!(w.focus, Some(3));
}

#[test]
fn centre_and_resize_stay_inside_the_work_area() {
    let mut w = wm();
    open(&mut w, 1);
    go(&mut w, Event::Center { id: 1 });
    assert_eq!(get(&w, 1).rect, Rect::new(440, 266, 400, 300));
    go(
        &mut w,
        Event::Resize {
            id: 1,
            dw: 5000,
            dh: -5000,
        },
    );
    assert_eq!(get(&w, 1).rect, Rect::new(0, 266, 1280, 160));
}

#[test]
fn stale_commands_do_nothing_and_extremes_stay_bounded() {
    let mut w = wm();
    for event in [
        Event::Activate { id: 99 },
        Event::Closed { id: 99 },
        Event::SetWorkspace { workspace: 50 },
        Event::Tile {
            id: 99,
            layout: Layout::Columns,
            cell: 0,
        },
    ] {
        assert!(go(&mut w, event).is_empty());
    }
    let mut tiny = displays();
    tiny[0].work = Rect::new(0, 0, 101, 51);
    go(
        &mut w,
        Event::Displays {
            displays: tiny,
            main: MAIN,
        },
    );
    open(&mut w, 1);
    go(
        &mut w,
        Event::Tile {
            id: 1,
            layout: Layout::Quarters,
            cell: 0,
        },
    );
    for (border, coordinate) in [
        (Border::Column { boundary: 1 }, i32::MAX),
        (
            Border::Row {
                column: 0,
                boundary: 1,
            },
            i32::MIN,
        ),
        (Border::Column { boundary: 7 }, 5),
    ] {
        go(
            &mut w,
            Event::DragBorder {
                key: key(1, MAIN),
                border,
                coordinate,
            },
        );
    }
    let c = cells(&w, key(1, MAIN));
    assert_eq!(c.iter().map(|r| r.w * r.h).sum::<i32>(), 101 * 51);
    assert!(c.iter().all(|r| r.w >= 0 && r.h >= 0));
    go(
        &mut w,
        Event::DragAway {
            id: 1,
            x: i32::MIN,
            y: i32::MAX,
            header: 10,
        },
    );
    assert!(get(&w, 1).rect.w > 0);
}

#[test]
fn an_observed_move_is_never_sent_back() {
    let mut w = wm();
    open(&mut w, 1);
    for x in [120, 180, 260] {
        let rect = Rect::new(x, 100, 400, 300);
        assert!(go(&mut w, Event::Moved { id: 1, rect }).is_empty());
        assert_eq!(get(&w, 1).rect, rect);
    }
}

#[test]
fn closing_a_window_never_commands_focus() {
    let mut w = wm();
    open(&mut w, 1);
    open(&mut w, 2);
    assert!(go(&mut w, Event::Closed { id: 2 }).is_empty());
    assert_eq!(w.focus, Some(1));
}

#[test]
fn state_survives_json_and_other_schemas_are_refused() {
    let mut w = wm();
    open(&mut w, 1);
    snap(&mut w, 1, Snap::TopLeft);
    let mut json = serde_json::to_value(&w).expect("serializes");
    assert_eq!(
        serde_json::from_value::<Wm>(json.clone()).expect("parses"),
        w
    );
    json["schema"] = 99.into();
    let other: Wm = serde_json::from_value(json).expect("parses");
    assert!(other.check().is_err());
}
