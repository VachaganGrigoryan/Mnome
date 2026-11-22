//! Integer geometry in top-left, point coordinates. Adapted from HayOS `hay-wm`.
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    #[cfg(test)]
    pub const fn new(x: i32, y: i32, w: i32, h: i32) -> Self {
        Self { x, y, w, h }
    }
    pub fn right(self) -> i32 {
        self.x.saturating_add(self.w.max(0))
    }
    pub fn bottom(self) -> i32 {
        self.y.saturating_add(self.h.max(0))
    }
    pub fn center(self) -> (i32, i32) {
        (
            self.x.saturating_add(self.w / 2),
            self.y.saturating_add(self.h / 2),
        )
    }
    pub fn contains(self, x: i32, y: i32) -> bool {
        x >= self.x && x < self.right() && y >= self.y && y < self.bottom()
    }
    #[cfg(test)]
    pub fn intersects(self, other: Self) -> bool {
        self.x < other.right()
            && other.x < self.right()
            && self.y < other.bottom()
            && other.y < self.bottom()
    }
    pub fn normalized(self) -> Self {
        Self {
            w: self.w.max(0),
            h: self.h.max(0),
            ..self
        }
    }
    /// Shrinks to fit `area`, then shifts inside it.
    pub fn clamped_into(self, area: Self) -> Self {
        let (w, h) = (self.w.min(area.w).max(1), self.h.min(area.h).max(1));
        Self {
            x: self.x.min(area.right().saturating_sub(w)).max(area.x),
            y: self.y.min(area.bottom().saturating_sub(h)).max(area.y),
            w,
            h,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Layout {
    Columns,
    WideNarrow,
    OneAndTwo,
    Quarters,
    Thirds,
}

impl Layout {
    pub fn cells(self) -> usize {
        match self {
            Self::Columns | Self::WideNarrow => 2,
            Self::OneAndTwo | Self::Thirds => 3,
            Self::Quarters => 4,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Snap {
    Left,
    Right,
    TopLeft,
    BottomLeft,
    TopRight,
    BottomRight,
    Maximize,
}

/// Corner zones win over side zones. Points outside the work area are clamped
/// so a physical screen edge still snaps with an inset work area.
pub(crate) fn snap_zone(area: Rect, x: i32, y: i32) -> Option<Snap> {
    if area.w <= 0 || area.h <= 0 {
        return None;
    }
    let edge = 28.min(area.w / 4);
    let corner = 72.min(area.h / 4);
    let top = y < area.y.saturating_add(corner);
    let bottom = y >= area.bottom().saturating_sub(corner);
    if x <= area.x.saturating_add(edge) {
        Some(match (top, bottom) {
            (true, _) => Snap::TopLeft,
            (_, true) => Snap::BottomLeft,
            _ => Snap::Left,
        })
    } else if x >= area.right().saturating_sub(edge) {
        Some(match (top, bottom) {
            (true, _) => Snap::TopRight,
            (_, true) => Snap::BottomRight,
            _ => Snap::Right,
        })
    } else if y <= area.y.saturating_add(6) {
        Some(Snap::Maximize)
    } else {
        None
    }
}

/// Integer boundary partitions. Every point belongs to precisely one cell.
pub(crate) fn fraction(length: i32, numerator: i32, denominator: i32) -> i32 {
    let value = i64::from(length.max(0)) * i64::from(numerator) / i64::from(denominator);
    i32::try_from(value).unwrap_or(i32::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snap_zones_prefer_corners_and_accept_points_beyond_the_area() {
        let area = Rect::new(0, 32, 1280, 768);
        assert_eq!(snap_zone(area, 0, 400), Some(Snap::Left));
        assert_eq!(snap_zone(area, 0, 40), Some(Snap::TopLeft));
        assert_eq!(snap_zone(area, -5, 799), Some(Snap::BottomLeft));
        assert_eq!(snap_zone(area, 1279, 400), Some(Snap::Right));
        assert_eq!(snap_zone(area, 1400, 0), Some(Snap::TopRight));
        assert_eq!(snap_zone(area, 640, 0), Some(Snap::Maximize));
        assert_eq!(snap_zone(area, 640, 400), None);
        assert_eq!(snap_zone(Rect::default(), 0, 0), None);
    }

    #[test]
    fn clamping_shrinks_then_shifts() {
        let area = Rect::new(100, 50, 800, 600);
        assert_eq!(
            Rect::new(0, 0, 2000, 100).clamped_into(area),
            Rect::new(100, 50, 800, 100)
        );
        assert_eq!(
            Rect::new(850, 640, 200, 200).clamped_into(area),
            Rect::new(700, 450, 200, 200)
        );
    }
}
