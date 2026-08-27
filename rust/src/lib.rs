//! Native activity semantics shared by the Windows, macOS, and Linux runners.
//!
//! The OS layer observes the foreground application and idle duration. This
//! crate applies the privacy boundary before an event can cross into Flutter:
//! excluded applications and Amadeus itself are rejected, while idle samples
//! are assigned their own state. The API deliberately accepts no window title,
//! path, screenshot, audio, or typed content.

use std::ffi::{c_char, CStr};

pub const DECISION_ACTIVE: i32 = 0;
pub const DECISION_IDLE: i32 = 1;
pub const DECISION_EXCLUDED: i32 = 2;

const SELF_APPS: &[&str] = &[
    "timepet",
    "timepet.exe",
    "amadeus",
    "amadeus.exe",
    "amadeus-desktop",
    "amadeus-desktop.exe",
];

/// Returns the stable ABI version exposed to the native runners.
#[no_mangle]
pub extern "C" fn amadeus_core_version() -> u32 {
    1
}

/// Classifies one activity sample before it enters the local append-only log.
///
/// `excluded_apps` is a newline-separated UTF-8 list. Invalid pointers or
/// invalid UTF-8 fail closed and return `DECISION_EXCLUDED`.
///
/// # Safety
///
/// `app_name` and `excluded_apps` must either be null or point to valid,
/// NUL-terminated byte sequences for the duration of this call. The function
/// does not retain either pointer and fails closed when UTF-8 decoding fails.
#[no_mangle]
pub unsafe extern "C" fn amadeus_activity_classify(
    app_name: *const c_char,
    idle_seconds: u64,
    idle_threshold: u64,
    excluded_apps: *const c_char,
) -> i32 {
    let Some(app_name) = read_utf8(app_name) else {
        return DECISION_EXCLUDED;
    };
    let exclusions = read_utf8(excluded_apps).unwrap_or_default();
    classify(app_name, idle_seconds, idle_threshold, exclusions)
}

/// A deterministic 0-100 focus score for overview projections.
///
/// It is intentionally a presentation aid, not a judgment about the user.
#[no_mangle]
pub extern "C" fn amadeus_focus_score(
    active_seconds: u64,
    idle_seconds: u64,
    switches: u32,
) -> u32 {
    if active_seconds == 0 {
        return 0;
    }
    let total = active_seconds.saturating_add(idle_seconds).max(1);
    let active_ratio = active_seconds.saturating_mul(100) / total;
    let switch_penalty = switches.saturating_sub(12).min(40);
    active_ratio.saturating_sub(u64::from(switch_penalty)) as u32
}

fn classify(app_name: &str, idle_seconds: u64, idle_threshold: u64, excluded_apps: &str) -> i32 {
    let normalized = app_name.trim().to_lowercase();
    if normalized.is_empty() || SELF_APPS.contains(&normalized.as_str()) {
        return DECISION_EXCLUDED;
    }

    let excluded = excluded_apps.lines().any(|entry| {
        let candidate = entry.trim().to_lowercase();
        !candidate.is_empty() && (normalized == candidate || normalized.contains(&candidate))
    });
    if excluded {
        return DECISION_EXCLUDED;
    }

    if idle_seconds >= idle_threshold.max(1) {
        DECISION_IDLE
    } else {
        DECISION_ACTIVE
    }
}

unsafe fn read_utf8<'a>(value: *const c_char) -> Option<&'a str> {
    if value.is_null() {
        return None;
    }
    CStr::from_ptr(value).to_str().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn excludes_self_and_user_selected_apps() {
        assert_eq!(classify("Amadeus.exe", 0, 300, ""), DECISION_EXCLUDED);
        assert_eq!(
            classify("1Password", 0, 300, "1Password\nBitwarden"),
            DECISION_EXCLUDED
        );
        assert_eq!(
            classify("Bank Secure Client", 0, 300, "secure"),
            DECISION_EXCLUDED
        );
    }

    #[test]
    fn distinguishes_active_and_idle_samples() {
        assert_eq!(classify("Code.exe", 10, 300, ""), DECISION_ACTIVE);
        assert_eq!(classify("Code.exe", 300, 300, ""), DECISION_IDLE);
    }

    #[test]
    fn focus_score_is_bounded_and_penalizes_switching() {
        assert_eq!(amadeus_focus_score(0, 0, 0), 0);
        assert_eq!(amadeus_focus_score(3600, 0, 5), 100);
        assert!(amadeus_focus_score(3600, 0, 40) < 100);
        assert!(amadeus_focus_score(1800, 1800, 0) <= 50);
    }
}
