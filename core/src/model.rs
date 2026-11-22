//! Window policy as a pure state machine, adapted from HayOS `hay-wm` for macOS:
//! several displays, an explicit reason for every hidden window, no stacking
//! order (macOS cannot set one) and no window families (it does not expose them).
//! Workspaces exist on the main display only; other displays always show theirs.
use crate::geometry::{Layout, Rect, Snap, fraction, snap_zone};
use serde::{Deserialize, Serialize};

pub(crate) type Id = u64;
pub(crate) type DisplayId = u64;
pub(crate) type WorkspaceId = u64;

/// Group key for windows that do not belong to a workspace. Workspace ids start at 1.
const NO_WORKSPACE: WorkspaceId = 0;
pub(crate) const SCHEMA: u32 = 2;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Display {
    pub id: DisplayId,
    pub frame: Rect,
    pub work: Rect,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Placement {
    #[default]
    Free,
    Maximized,
    Tiled {
        cell: usize,
    },
}

/// Where a window should be. `Minimized` and `Hidden` (its app, with Cmd+H) are always the person's choice,
/// `Parked` always ours. A hidden window may be anywhere: nobody sees it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Presence {
    Shown,
    Minimized,
    Hidden,
    Parked,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Window {
    pub id: Id,
    pub app: String,
    pub display: DisplayId,
    pub workspace: WorkspaceId,
    pub placement: Placement,
    pub minimized: bool,
    pub hidden: bool,
    /// Native full screen: left alone until it ends.
    pub fullscreen: bool,
    /// Cannot be parked, so it stays visible on every workspace.
    pub sticky: bool,
    pub rect: Rect,
    /// Free frame to return to from a tile or from maximized.
    pub restore: Rect,
}

/// Work for the platform, already in execution order: show, focus, then hide.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub(crate) enum Op {
    Unminimize { window: Id },
    Unpark { window: Id, rect: Rect },
    Place { window: Id, rect: Rect },
    Focus { window: Id },
    Park { window: Id },
    Minimize { window: Id },
}

impl Op {
    fn rank(&self) -> u8 {
        match self {
            Self::Unminimize { .. } => 0,
            Self::Unpark { .. } | Self::Place { .. } => 1,
            Self::Focus { .. } => 2,
            Self::Park { .. } | Self::Minimize { .. } => 3,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct GroupKey {
    pub workspace: WorkspaceId,
    pub display: DisplayId,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Border {
    Column { boundary: usize },
    Row { column: usize, boundary: usize },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Direction {
    Left,
    Right,
    Up,
    Down,
}

/// Boundaries are ten-thousandths of the work area, including 0 and 10000.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Group {
    key: GroupKey,
    columns: Vec<i32>,
    rows: Vec<Vec<i32>>,
    occupants: Vec<Option<Id>>,
}

impl Group {
    fn new(key: GroupKey, layout: Layout) -> Self {
        let (columns, rows) = match layout {
            Layout::Columns => (vec![0, 5000, 10000], vec![vec![0, 10000]; 2]),
            Layout::WideNarrow => (vec![0, 6200, 10000], vec![vec![0, 10000]; 2]),
            Layout::OneAndTwo => (
                vec![0, 5000, 10000],
                vec![vec![0, 10000], vec![0, 5000, 10000]],
            ),
            Layout::Quarters => (vec![0, 5000, 10000], vec![vec![0, 5000, 10000]; 2]),
            Layout::Thirds => (vec![0, 3333, 6666, 10000], vec![vec![0, 10000]; 3]),
        };
        Self {
            key,
            columns,
            rows,
            occupants: vec![None; layout.cells()],
        }
    }
    fn first_cell(&self, column: usize) -> usize {
        self.rows[..column].iter().map(|v| v.len() - 1).sum()
    }
    fn rect(&self, area: Rect, cell: usize) -> Option<Rect> {
        let column = (0..self.rows.len())
            .rfind(|c| self.first_cell(*c) <= cell && !self.rows[*c].is_empty())?;
        let row = cell - self.first_cell(column);
        let (top, bottom) = (
            *self.rows[column].get(row)?,
            *self.rows[column].get(row + 1)?,
        );
        let (left, right) = (*self.columns.get(column)?, *self.columns.get(column + 1)?);
        let (x, x2) = (
            fraction(area.w, left, 10000),
            fraction(area.w, right, 10000),
        );
        let (y, y2) = (
            fraction(area.h, top, 10000),
            fraction(area.h, bottom, 10000),
        );
        Some(Rect {
            x: area.x.saturating_add(x),
            y: area.y.saturating_add(y),
            w: x2 - x,
            h: y2 - y,
        })
    }
}

#[derive(Clone, Copy)]
struct Before {
    id: Id,
    rect: Rect,
    presence: Presence,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Wm {
    schema: u32,
    revision: u64,
    displays: Vec<Display>,
    main: DisplayId,
    windows: Vec<Window>,
    mru: Vec<Id>,
    workspaces: Vec<WorkspaceId>,
    current: WorkspaceId,
    next_workspace: WorkspaceId,
    /// Off: every window is shown, and each keeps its workspace for later.
    workspaces_on: bool,
    groups: Vec<Group>,
    focus: Option<Id>,
    /// Windows hidden by "show desktop", to bring back together.
    desktop: Vec<Id>,
}

impl Default for Wm {
    fn default() -> Self {
        Self {
            schema: SCHEMA,
            revision: 0,
            displays: Vec::new(),
            main: 0,
            windows: Vec::new(),
            mru: Vec::new(),
            workspaces: vec![1, 2],
            current: 1,
            next_workspace: 3,
            workspaces_on: true,
            groups: Vec::new(),
            focus: None,
            desktop: Vec::new(),
        }
    }
}

/// Everything that can happen. Observations report what macOS or the person already did.
#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Event {
    // Observations
    Displays {
        displays: Vec<Display>,
        main: DisplayId,
    },
    Opened {
        id: Id,
        app: String,
        rect: Rect,
        minimized: bool,
        fullscreen: bool,
    },
    Closed {
        id: Id,
    },
    Focused {
        id: Id,
    },
    Moved {
        id: Id,
        rect: Rect,
        /// macOS moved it because the displays changed, so it keeps its workspace.
        #[serde(default)]
        by_system: bool,
    },
    Minimized {
        id: Id,
        on: bool,
    },
    Hidden {
        id: Id,
        on: bool,
    },
    Fullscreen {
        id: Id,
        on: bool,
    },
    Sticky {
        id: Id,
        on: bool,
    },
    /// The switch, or something that makes parking impossible.
    WorkspacesOn {
        on: bool,
    },
    // Commands
    Activate {
        id: Id,
    },
    Minimize {
        id: Id,
    },
    ToggleMaximize {
        id: Id,
    },
    Restore {
        id: Id,
    },
    Snap {
        id: Id,
        to: Snap,
    },
    Tile {
        id: Id,
        layout: Layout,
        cell: usize,
    },
    Center {
        id: Id,
    },
    Resize {
        id: Id,
        dw: i32,
        dh: i32,
    },
    ToDisplay {
        id: Id,
        direction: Direction,
    },
    DragAway {
        id: Id,
        x: i32,
        y: i32,
        header: i32,
    },
    DragBorder {
        key: GroupKey,
        border: Border,
        coordinate: i32,
    },
    SetWorkspace {
        workspace: WorkspaceId,
    },
    StepWorkspace {
        delta: i32,
    },
    ToWorkspace {
        id: Id,
        workspace: WorkspaceId,
    },
    /// Moves the window to a neighbouring workspace and goes along.
    CarryWindow {
        id: Id,
        delta: i32,
    },
    ShowDesktop,
    Cycle {
        backwards: bool,
    },
}

impl Event {
    /// Focus follows commands only: after an observation macOS has already chosen it.
    fn is_observation(&self) -> bool {
        matches!(
            self,
            Self::Displays { .. }
                | Self::Opened { .. }
                | Self::Closed { .. }
                | Self::Focused { .. }
                | Self::Moved { .. }
                | Self::Minimized { .. }
                | Self::Hidden { .. }
                | Self::Fullscreen { .. }
                | Self::Sticky { .. }
                | Self::WorkspacesOn { .. }
        )
    }
}

impl Wm {
    /// Rejects state written by another schema, so the caller starts afresh.
    pub fn check(&self) -> Result<(), String> {
        if self.schema == SCHEMA {
            Ok(())
        } else {
            Err(format!("unsupported window state schema {}", self.schema))
        }
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// Applies one event. Stale or invalid commands change nothing.
    pub fn reduce(&mut self, event: Event) -> Result<Vec<Op>, String> {
        let observed = event.is_observation();
        let focus = self.focus;
        // The person's own move is already done; placing the window again would fight the drag.
        let reported = match &event {
            Event::Moved { id, rect, .. } => Some((*id, rect.normalized())),
            _ => None,
        };
        let before: Vec<Before> = self
            .windows
            .iter()
            .map(|w| Before {
                id: w.id,
                rect: w.rect,
                presence: self.presence(w),
            })
            .collect();
        self.dispatch(event)?;
        self.tidy();
        self.reflow();
        self.revision = self.revision.wrapping_add(1);

        let mut ops = Vec::new();
        for w in &self.windows {
            let id = w.id;
            let presence = self.presence(w);
            let Some(old) = before.iter().find(|b| b.id == id) else {
                // A new window is already where it is unless it must be hidden.
                if presence == Presence::Parked {
                    ops.push(Op::Park { window: id });
                }
                continue;
            };
            let rect = w.rect;
            match (old.presence, presence) {
                (Presence::Shown, Presence::Shown)
                    if old.rect != rect && !w.fullscreen && reported != Some((id, rect)) =>
                {
                    ops.push(Op::Place { window: id, rect });
                }
                // A full-screen window is placed by macOS.
                (Presence::Parked | Presence::Hidden, Presence::Shown) if !w.fullscreen => {
                    ops.push(Op::Unpark { window: id, rect });
                }
                (Presence::Minimized, Presence::Shown) => {
                    ops.push(Op::Unminimize { window: id });
                    // It may have been minimized while parked, so always place it.
                    if !w.fullscreen {
                        ops.push(Op::Place { window: id, rect });
                    }
                }
                (Presence::Shown | Presence::Minimized | Presence::Hidden, Presence::Parked) => {
                    ops.push(Op::Park { window: id });
                }
                (Presence::Shown | Presence::Parked | Presence::Hidden, Presence::Minimized) => {
                    ops.push(Op::Minimize { window: id });
                }
                _ => {}
            }
        }
        if !observed
            && self.focus != focus
            && let Some(window) = self.focus
        {
            ops.push(Op::Focus { window });
        }
        ops.sort_by_key(Op::rank);
        Ok(ops)
    }

    fn dispatch(&mut self, event: Event) -> Result<(), String> {
        match event {
            Event::Displays { displays, main } => return self.set_displays(displays, main),
            Event::Opened {
                id,
                app,
                rect,
                minimized,
                fullscreen,
            } => self.open(id, app, rect.normalized(), minimized, fullscreen),
            Event::Closed { id } => self.close(id),
            Event::Focused { id } | Event::Activate { id } => self.activate(id),
            Event::Moved {
                id,
                rect,
                by_system,
            } => self.moved(id, rect.normalized(), by_system),
            Event::Hidden { id, on } => self.update(id, |w| w.hidden = on),
            Event::WorkspacesOn { on } => self.workspaces_on = on,
            Event::Minimized { id, on } => self.minimized(id, on),
            Event::Minimize { id } => self.minimize(id),
            Event::Fullscreen { id, on } => {
                // Whoever leaves full screen is looking at it.
                let current = self.current;
                self.update(id, |w| {
                    if w.fullscreen && !on {
                        w.workspace = current;
                    }
                    w.fullscreen = on;
                });
            }
            Event::Sticky { id, on } => {
                self.detach(id);
                let current = self.current;
                self.update(id, |w| {
                    w.sticky = on;
                    w.workspace = current;
                });
            }
            Event::ToggleMaximize { id } => self.toggle_maximize(id),
            Event::Restore { id } => self.restore(id),
            Event::Snap { id, to } => self.snap(id, to),
            Event::Tile { id, layout, cell } => self.tile(id, layout, cell),
            Event::Center { id } => self.center(id),
            Event::Resize { id, dw, dh } => self.resize(id, dw, dh),
            Event::ToDisplay { id, direction } => self.move_to_display(id, direction),
            Event::DragAway { id, x, y, header } => self.drag_away(id, x, y, header),
            Event::DragBorder {
                key,
                border,
                coordinate,
            } => self.drag_border(key, border, coordinate),
            Event::SetWorkspace { workspace } => self.set_workspace(workspace),
            Event::StepWorkspace { delta } => self.step_workspace(delta),
            Event::ToWorkspace { id, workspace } => self.move_to_workspace(id, workspace),
            Event::CarryWindow { id, delta } => self.carry_window(id, delta),
            Event::ShowDesktop => self.show_desktop(),
            Event::Cycle { backwards } => self.cycle(backwards),
        }
        Ok(())
    }

    // Lookups

    fn index(&self, id: Id) -> Option<usize> {
        self.windows.iter().position(|w| w.id == id)
    }
    fn window(&self, id: Id) -> Option<&Window> {
        self.windows.iter().find(|w| w.id == id)
    }
    fn update(&mut self, id: Id, change: impl FnOnce(&mut Window)) {
        if let Some(i) = self.index(id) {
            change(&mut self.windows[i]);
        }
    }
    fn display(&self, id: DisplayId) -> Option<&Display> {
        self.displays.iter().find(|d| d.id == id)
    }
    fn work_area(&self, id: DisplayId) -> Rect {
        self.display(id).map(|d| d.work).unwrap_or_default()
    }
    /// The display under a frame's centre, else the nearest one.
    fn display_at(&self, rect: Rect) -> DisplayId {
        let (x, y) = rect.center();
        let distance = |d: &Display| {
            let gap = |v: i32, low: i32, high: i32| {
                (i64::from(low) - i64::from(v))
                    .max(i64::from(v) - i64::from(high))
                    .max(0)
            };
            gap(x, d.frame.x, d.frame.right()) + gap(y, d.frame.y, d.frame.bottom())
        };
        self.displays
            .iter()
            .find(|d| d.frame.contains(x, y))
            .or_else(|| self.displays.iter().min_by_key(|d| distance(d)))
            .map_or(self.main, |d| d.id)
    }
    fn has_workspace(&self, w: &Window) -> bool {
        w.display == self.main && !w.sticky
    }
    fn presence(&self, w: &Window) -> Presence {
        if w.minimized {
            Presence::Minimized
        } else if w.hidden {
            Presence::Hidden
        } else if w.fullscreen
            || !self.workspaces_on
            || !self.has_workspace(w)
            || w.workspace == self.current
        {
            Presence::Shown
        } else {
            Presence::Parked
        }
    }
    fn is_shown(&self, id: Id) -> bool {
        self.window(id)
            .is_some_and(|w| self.presence(w) == Presence::Shown)
    }
    fn key(&self, w: &Window) -> GroupKey {
        GroupKey {
            workspace: if self.has_workspace(w) {
                w.workspace
            } else {
                NO_WORKSPACE
            },
            display: w.display,
        }
    }
    fn group(&self, key: GroupKey) -> Option<&Group> {
        self.groups.iter().find(|g| g.key == key)
    }

    /// Tile border and snap zone under a point, for dragging.
    pub fn hit(&self, x: i32, y: i32) -> (Option<Snap>, Option<(GroupKey, Border)>) {
        let Some(display) = self.displays.iter().find(|d| d.frame.contains(x, y)) else {
            return (None, None);
        };
        let key = GroupKey {
            workspace: if display.id == self.main {
                self.current
            } else {
                NO_WORKSPACE
            },
            display: display.id,
        };
        let border = self.border_at(key, display.work, x, y);
        (snap_zone(display.work, x, y), border.map(|b| (key, b)))
    }
    fn border_at(&self, key: GroupKey, area: Rect, x: i32, y: i32) -> Option<Border> {
        let g = self.group(key)?;
        if !area.contains(x, y) {
            return None;
        }
        let near = |a: i32, b: i32| (i64::from(a) - i64::from(b)).abs() <= 5;
        let at = |value: i32| area.x + fraction(area.w, value, 10000);
        let last = g.columns.len().saturating_sub(1);
        if let Some(boundary) = (1..last).find(|i| near(x, at(g.columns[*i]))) {
            return Some(Border::Column { boundary });
        }
        for (column, rows) in g.rows.iter().enumerate() {
            if x < at(g.columns[column]) || x >= at(g.columns[column + 1]) {
                continue;
            }
            let last = rows.len().saturating_sub(1);
            let hit = (1..last).find(|i| near(y, area.y + fraction(area.h, rows[*i], 10000)));
            if let Some(boundary) = hit {
                return Some(Border::Row { column, boundary });
            }
        }
        None
    }

    // Upkeep after every event

    /// One empty workspace at the end, at least two in all, no other empty one but the current.
    fn tidy(&mut self) {
        let occupied: Vec<WorkspaceId> = self
            .windows
            .iter()
            .filter(|w| self.has_workspace(w))
            .map(|w| w.workspace)
            .collect();
        let last = self.workspaces.last().copied();
        let current = self.current;
        self.workspaces
            .retain(|ws| *ws == current || Some(*ws) == last || occupied.contains(ws));
        while self.workspaces.len() < 2
            || self
                .workspaces
                .last()
                .is_some_and(|ws| occupied.contains(ws))
        {
            let Some(next) = self.next_workspace.checked_add(1) else {
                break;
            };
            self.workspaces.push(self.next_workspace);
            self.next_workspace = next;
        }
        let (workspaces, displays) = (&self.workspaces, &self.displays);
        self.groups.retain(|g| {
            (g.key.workspace == NO_WORKSPACE || workspaces.contains(&g.key.workspace))
                && displays.iter().any(|d| d.id == g.key.display)
                && g.occupants.iter().any(Option::is_some)
        });
        if self.focus.is_some_and(|id| !self.is_shown(id)) {
            self.focus_next();
        }
    }
    fn reflow(&mut self) {
        for i in 0..self.windows.len() {
            let w = &self.windows[i];
            let area = self.work_area(w.display);
            let rect = match w.placement {
                Placement::Free => w.rect,
                Placement::Maximized if area.w > 0 && area.h > 0 => area,
                Placement::Maximized => w.rect,
                Placement::Tiled { cell } => self
                    .group(self.key(w))
                    .and_then(|g| g.rect(area, cell))
                    .unwrap_or(w.restore),
            };
            self.windows[i].rect = rect;
        }
    }
    /// The most recent shown window, but a full-screen one only when there is no other: reaching it leaves the desktop.
    fn focus_next(&mut self) {
        self.focus = self.most_recent(|w| !w.fullscreen).or_else(|| {
            let current = self.current;
            self.most_recent(|w| w.workspace == current)
        });
    }
    fn most_recent(&self, wanted: impl Fn(&Window) -> bool) -> Option<Id> {
        self.mru.iter().copied().find(|id| {
            self.window(*id)
                .is_some_and(|w| self.presence(w) == Presence::Shown && wanted(w))
        })
    }
    /// Windows hidden by "show desktop" belong to the workspace it was used on.
    fn switch_to(&mut self, workspace: WorkspaceId) {
        if self.current != workspace {
            self.current = workspace;
            self.desktop.clear();
        }
    }
    fn detach(&mut self, id: Id) {
        for occupant in self.groups.iter_mut().flat_map(|g| &mut g.occupants) {
            if *occupant == Some(id) {
                *occupant = None;
            }
        }
        self.update(id, |w| {
            if matches!(w.placement, Placement::Tiled { .. }) {
                w.placement = Placement::Free;
                w.rect = w.restore;
            }
        });
    }

    // Observations

    fn set_displays(&mut self, displays: Vec<Display>, main: DisplayId) -> Result<(), String> {
        if !displays.iter().any(|d| d.id == main) {
            return Err("the main display is not among the displays".into());
        }
        let old_main = self.main;
        let main_changed = main != old_main;
        self.displays = displays;
        if main_changed {
            // Tile groups are keyed by what was the main display; keep the windows where they are.
            self.groups.clear();
            for w in &mut self.windows {
                if matches!(w.placement, Placement::Tiled { .. }) {
                    w.placement = Placement::Free;
                }
            }
        }
        self.main = main;
        for i in 0..self.windows.len() {
            let id = self.windows[i].id;
            if self.display(self.windows[i].display).is_none() {
                self.detach(id);
                let area = self.work_area(main);
                let current = self.current;
                let w = &mut self.windows[i];
                // Windows of a vanished main display keep their workspace; others join this one.
                if w.display != old_main {
                    w.workspace = current;
                }
                w.display = main;
                w.rect = w.rect.clamped_into(area);
                w.restore = w.restore.clamped_into(area);
            } else if main_changed && self.windows[i].display == main {
                self.windows[i].workspace = self.current;
            }
        }
        Ok(())
    }
    fn open(&mut self, id: Id, app: String, rect: Rect, minimized: bool, fullscreen: bool) {
        if self.window(id).is_some() {
            return;
        }
        self.windows.push(Window {
            id,
            app,
            display: self.display_at(rect),
            workspace: self.current,
            placement: Placement::Free,
            minimized,
            hidden: false,
            fullscreen,
            sticky: false,
            rect,
            restore: rect,
        });
        self.mru.push(id);
    }
    fn close(&mut self, id: Id) {
        self.detach(id);
        self.windows.retain(|w| w.id != id);
        self.mru.retain(|v| *v != id);
        self.desktop.retain(|v| *v != id);
        if self.focus == Some(id) {
            self.focus_next();
        }
    }
    /// The person moved or resized it. Frames of hidden windows are ours and never recorded.
    fn moved(&mut self, id: Id, rect: Rect, by_system: bool) {
        let Some(w) = self.window(id) else { return };
        if w.rect == rect || w.fullscreen || self.presence(w) != Presence::Shown {
            return;
        }
        let workspace = w.workspace;
        self.place_free(id, rect);
        if by_system && self.window(id).is_some_and(|w| self.has_workspace(w)) {
            // It may have been dropped as empty while its display was away. Ids are in order.
            if let Err(at) = self.workspaces.binary_search(&workspace) {
                self.workspaces.insert(at, workspace);
            }
            self.update(id, |w| w.workspace = workspace);
        }
    }
    fn place_free(&mut self, id: Id, rect: Rect) {
        self.detach(id);
        let display = self.display_at(rect);
        let joins_main = display == self.main;
        let current = self.current;
        self.update(id, |w| {
            if joins_main && w.display != display {
                w.workspace = current;
            }
            w.display = display;
            w.placement = Placement::Free;
            w.rect = rect;
            w.restore = rect;
        });
    }
    fn minimized(&mut self, id: Id, on: bool) {
        if on {
            self.minimize(id);
            return;
        }
        let Some(w) = self.window(id).filter(|w| w.minimized) else {
            return;
        };
        let workspace = self.has_workspace(w).then_some(w.workspace);
        self.update(id, |w| w.minimized = false);
        self.desktop.retain(|v| *v != id);
        // From the Dock, say: whoever asked for it wants to see it.
        if let Some(workspace) = workspace.filter(|_| self.workspaces_on) {
            self.switch_to(workspace);
        }
    }

    // Commands

    fn activate(&mut self, id: Id) {
        let Some(i) = self.index(id) else { return };
        self.windows[i].minimized = false;
        self.windows[i].hidden = false;
        let w = &self.windows[i];
        // A full-screen window is seen without its workspace.
        if self.has_workspace(w) && !w.fullscreen {
            self.switch_to(w.workspace);
        }
        self.mru.retain(|v| *v != id);
        self.mru.insert(0, id);
        self.focus = Some(id);
    }
    fn minimize(&mut self, id: Id) {
        if self.window(id).is_none_or(|w| w.minimized) {
            return;
        }
        self.detach(id);
        self.update(id, |w| w.minimized = true);
    }
    fn toggle_maximize(&mut self, id: Id) {
        let Some(w) = self.window(id) else { return };
        let old = w.placement;
        self.detach(id);
        self.update(id, |w| {
            if old == Placement::Maximized {
                w.placement = Placement::Free;
                w.rect = w.restore;
            } else {
                if old == Placement::Free {
                    w.restore = w.rect;
                }
                w.placement = Placement::Maximized;
            }
        });
        self.activate(id);
    }
    /// Back to the free frame. A free window stays as it is, as in GNOME.
    fn restore(&mut self, id: Id) {
        if self
            .window(id)
            .is_none_or(|w| w.placement == Placement::Free)
        {
            return;
        }
        self.detach(id);
        self.update(id, |w| {
            w.placement = Placement::Free;
            w.rect = w.restore;
        });
    }
    fn center(&mut self, id: Id) {
        let Some(w) = self.window(id) else { return };
        let area = self.work_area(w.display);
        let size = w.rect.clamped_into(area);
        let rect = Rect {
            x: area.x + (area.w - size.w) / 2,
            y: area.y + (area.h - size.h) / 2,
            ..size
        };
        self.place_free(id, rect);
    }
    /// Grows or shrinks from the top-left corner.
    fn resize(&mut self, id: Id, dw: i32, dh: i32) {
        let Some(w) = self.window(id) else { return };
        let rect = Rect {
            w: w.rect.w.saturating_add(dw).max(240),
            h: w.rect.h.saturating_add(dh).max(160),
            ..w.rect
        };
        let rect = rect.clamped_into(self.work_area(w.display));
        self.place_free(id, rect);
    }
    /// Keeps the size where it fits, and the relative position.
    fn move_to_display(&mut self, id: Id, direction: Direction) {
        let Some(w) = self.window(id) else { return };
        let Some(source) = self.display(w.display).copied() else {
            return;
        };
        let (ox, oy) = source.frame.center();
        let target = self
            .displays
            .iter()
            .filter_map(|d| {
                let (x, y) = d.frame.center();
                let (dx, dy) = (i64::from(x) - i64::from(ox), i64::from(y) - i64::from(oy));
                let (forward, side) = match direction {
                    Direction::Left => (-dx, dy),
                    Direction::Right => (dx, dy),
                    Direction::Up => (-dy, dx),
                    Direction::Down => (dy, dx),
                };
                // Mostly in that direction, so a display beside is not "up" by a few points.
                (forward > 0 && forward >= side.abs()).then_some((forward + side.abs(), *d))
            })
            .min_by_key(|(distance, _)| *distance)
            .map(|(_, d)| d);
        let Some(target) = target else { return };
        let maximized = w.placement == Placement::Maximized;
        let from = if matches!(w.placement, Placement::Free) {
            w.rect
        } else {
            w.restore
        };
        let shift = |v: i32, a: i32, alen: i32, b: i32, blen: i32| {
            let from = i64::from(alen.max(1));
            let moved = (i64::from(v) - i64::from(a)) * i64::from(blen);
            // To the nearest point, so there and back ends where it began.
            i32::try_from(i64::from(b) + (moved + from / 2).div_euclid(from)).unwrap_or(b)
        };
        let rect = Rect {
            x: shift(
                from.x,
                source.work.x,
                source.work.w,
                target.work.x,
                target.work.w,
            ),
            y: shift(
                from.y,
                source.work.y,
                source.work.h,
                target.work.y,
                target.work.h,
            ),
            ..from
        }
        .clamped_into(target.work);
        self.place_free(id, rect);
        if maximized {
            self.update(id, |w| w.placement = Placement::Maximized);
        }
    }
    /// Restore under the pointer, preserving its horizontal share of the old header.
    fn drag_away(&mut self, id: Id, x: i32, y: i32, header: i32) {
        let Some(w) = self.window(id) else { return };
        let width = i64::from(w.rect.w.max(1));
        let share = (i64::from(x) - i64::from(w.rect.x)).clamp(0, width);
        let dx = i32::try_from(share * i64::from(w.restore.w) / width).unwrap_or(0);
        let rect = Rect {
            x: x.saturating_sub(dx),
            y: y.saturating_sub(header.max(0)),
            ..w.restore
        };
        self.place_free(id, rect);
    }
    fn set_workspace(&mut self, workspace: WorkspaceId) {
        if !self.workspaces_on || !self.workspaces.contains(&workspace) || workspace == self.current
        {
            return;
        }
        self.switch_to(workspace);
        // Its own windows before more recent ones on other displays.
        let own = self
            .most_recent(|w| self.has_workspace(w) && w.workspace == workspace && !w.fullscreen);
        self.focus_next();
        self.focus = own.or(self.focus);
    }
    fn neighbour(&self, workspace: WorkspaceId, delta: i32) -> Option<WorkspaceId> {
        let i = self.workspaces.iter().position(|ws| *ws == workspace)?;
        let target = if delta < 0 {
            i.checked_sub(1)
        } else {
            i.checked_add(1)
        };
        target.and_then(|i| self.workspaces.get(i)).copied()
    }
    fn step_workspace(&mut self, delta: i32) {
        if let Some(workspace) = self.neighbour(self.current, delta) {
            self.set_workspace(workspace);
        }
    }
    fn carry_window(&mut self, id: Id, delta: i32) {
        let Some(w) = self.window(id).filter(|w| !w.fullscreen) else {
            return;
        };
        if !self.workspaces_on || !self.has_workspace(w) {
            return;
        }
        if let Some(workspace) = self.neighbour(w.workspace, delta) {
            self.move_to_workspace(id, workspace);
            self.activate(id);
        }
    }
    fn move_to_workspace(&mut self, id: Id, workspace: WorkspaceId) {
        let movable = self.window(id).is_some_and(|w| self.has_workspace(w));
        if !movable || !self.workspaces.contains(&workspace) {
            return;
        }
        self.detach(id);
        self.update(id, |w| w.workspace = workspace);
    }
    /// Tiles keep their cells, so a second call puts everything back as it was.
    fn show_desktop(&mut self) {
        let ids = std::mem::take(&mut self.desktop);
        if ids.is_empty() {
            let shown: Vec<Id> = self
                .windows
                .iter()
                .filter(|w| !w.fullscreen && self.presence(w) == Presence::Shown)
                .map(|w| w.id)
                .collect();
            for id in &shown {
                self.update(*id, |w| w.minimized = true);
            }
            self.desktop = shown;
        } else {
            for id in ids {
                self.update(id, |w| w.minimized = false);
                // Hidden or moved elsewhere meanwhile: it stays in the Dock.
                if !self.is_shown(id) {
                    self.update(id, |w| w.minimized = true);
                }
            }
            self.focus_next();
        }
    }
    fn cycle(&mut self, backwards: bool) {
        let shown: Vec<Id> = self
            .windows
            .iter()
            .filter(|w| self.presence(w) == Presence::Shown)
            .map(|w| w.id)
            .collect();
        let n = shown.len();
        if n == 0 {
            return;
        }
        let at = self
            .focus
            .and_then(|f| shown.iter().position(|id| *id == f));
        let next = match (at, backwards) {
            (Some(i), false) => (i + 1) % n,
            (Some(i), true) => (i + n - 1) % n,
            (None, _) => 0,
        };
        self.activate(shown[next]);
    }

    // Tiling

    fn replace_group(&mut self, key: GroupKey, layout: Layout) {
        let old: Vec<Id> = self
            .group(key)
            .map(|g| g.occupants.iter().flatten().copied().collect())
            .unwrap_or_default();
        for id in &old {
            self.detach(*id);
        }
        self.groups.retain(|g| g.key != key);
        let mut group = Group::new(key, layout);
        for (cell, id) in old.into_iter().take(layout.cells()).enumerate() {
            group.occupants[cell] = Some(id);
            self.update(id, |w| w.placement = Placement::Tiled { cell });
        }
        self.groups.push(group);
    }
    fn assign_cell(&mut self, id: Id, key: GroupKey, cell: usize) {
        let displaced = self
            .group(key)
            .and_then(|g| g.occupants.get(cell))
            .copied()
            .flatten();
        if let Some(other) = displaced {
            self.detach(other);
        }
        let was_free = self
            .window(id)
            .and_then(|w| (w.placement == Placement::Free).then_some(w.rect));
        self.detach(id);
        self.update(id, |w| {
            if let Some(rect) = was_free {
                w.restore = rect;
            }
            w.placement = Placement::Tiled { cell };
        });
        if let Some(slot) = self
            .groups
            .iter_mut()
            .find(|g| g.key == key)
            .and_then(|g| g.occupants.get_mut(cell))
        {
            *slot = Some(id);
        }
    }
    fn tile(&mut self, id: Id, layout: Layout, cell: usize) {
        let Some(key) = self.window(id).map(|w| self.key(w)) else {
            return;
        };
        if cell >= layout.cells() {
            return;
        }
        self.replace_group(key, layout);
        self.assign_cell(id, key, cell);
        self.activate(id);
    }
    /// Left and right start with two full-height columns. A corner splits only
    /// its column, preserving the other half and its shared x boundary.
    fn snap(&mut self, id: Id, to: Snap) {
        let Some(w) = self.window(id) else { return };
        let key = self.key(w);
        let (column, bottom, split) = match to {
            Snap::Maximize => {
                if w.placement != Placement::Maximized {
                    self.toggle_maximize(id);
                }
                return;
            }
            Snap::Left => (0, false, false),
            Snap::TopLeft => (0, false, true),
            Snap::BottomLeft => (0, true, true),
            Snap::Right => (1, false, false),
            Snap::TopRight => (1, false, true),
            Snap::BottomRight => (1, true, true),
        };
        // Tiling to the half it already fills puts it back, as in GNOME.
        if !split
            && self.group(key).is_some_and(|g| {
                g.columns.len() == 3
                    && g.rows[column].len() == 2
                    && g.occupants.get(g.first_cell(column)) == Some(&Some(id))
            })
        {
            self.restore(id);
            return;
        }
        if self.group(key).is_none_or(|g| g.columns.len() != 3) {
            self.replace_group(key, Layout::Columns);
        }
        let Some(gi) = self.groups.iter().position(|g| g.key == key) else {
            return;
        };
        let first = self.groups[gi].first_cell(column);
        let rows = self.groups[gi].rows[column].len() - 1;
        if split && rows == 1 {
            self.groups[gi].rows[column] = vec![0, 5000, 10000];
            self.groups[gi].occupants.insert(first + 1, None);
        } else if !split && rows == 2 {
            if let Some(other) = self.groups[gi].occupants[first + 1] {
                self.detach(other);
            }
            self.groups[gi].occupants.remove(first + 1);
            self.groups[gi].rows[column] = vec![0, 10000];
        }
        // Re-index surviving placements after a column's row count changed.
        for (cell, occupant) in self.groups[gi].occupants.clone().into_iter().enumerate() {
            if let Some(other) = occupant {
                self.update(other, |w| w.placement = Placement::Tiled { cell });
            }
        }
        self.assign_cell(id, key, first + usize::from(bottom));
        self.activate(id);
    }
    /// Drag an internal boundary to a work-area coordinate. Minimum tile sizes
    /// shrink proportionally on tiny screens, preserving a noncrossing grid.
    fn drag_border(&mut self, key: GroupKey, border: Border, coordinate: i32) {
        let area = self.work_area(key.display);
        let Some(g) = self.groups.iter_mut().find(|g| g.key == key) else {
            return;
        };
        let (values, boundary, length, origin, minimum) = match border {
            Border::Column { boundary } => (&mut g.columns, boundary, area.w, area.x, 220),
            Border::Row { column, boundary } => match g.rows.get_mut(column) {
                Some(rows) => (rows, boundary, area.h, area.y, 150),
                None => return,
            },
        };
        if length <= 0 || boundary == 0 || boundary + 1 >= values.len() {
            return;
        }
        let (low, high) = (values[boundary - 1], values[boundary + 1]);
        let minimum = ((minimum * 10000 + i64::from(length) - 1) / i64::from(length))
            .min(i64::from((high - low) / 2));
        let desired = (i64::from(coordinate) - i64::from(origin)) * 10000 / i64::from(length);
        let value = desired.clamp(i64::from(low) + minimum, i64::from(high) - minimum);
        values[boundary] = i32::try_from(value).unwrap_or(values[boundary]);
    }
}

#[cfg(test)]
#[path = "model_tests.rs"]
mod tests;
