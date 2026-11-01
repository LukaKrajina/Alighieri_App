//! 时间与日期工具
//! --------------
//! 不引 chrono：这里只要「毫秒 <-> ISO-8601」的双向转换，
//! 为这点活儿拉一个日期库进来不划算。而且它必须是纯函数（不读时区），
//! 否则归约结果会随设备环境变化。

/// 毫秒 -> ISO-8601（UTC）
pub fn iso_of_ms(ms: u64) -> String {
    let secs = ms / 1000;
    let millis = ms % 1000;
    let days = (secs / 86_400) as i64;
    let time_of_day = secs % 86_400;
    let (y, m, d) = civil_from_days(days);
    let hh = time_of_day / 3600;
    let mm = (time_of_day % 3600) / 60;
    let ss = time_of_day % 60;
    format!("{y:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}.{millis:03}Z")
}

/// 天数 -> 公历年月日（Howard Hinnant 的算法，1970-01-01 = day 0）
pub fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as i64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// ISO-8601 -> 毫秒。解析不出就返回 None —— 脏数据可以难住解析器，不能难住界面。
pub fn parse_iso_ms(s: &str) -> Option<u64> {
    let b = s.as_bytes();
    if b.len() < 19 {
        return None;
    }
    if b.get(4) != Some(&b'-') || b.get(7) != Some(&b'-') || b.get(10) != Some(&b'T') {
        return None;
    }
    let y: i64 = s[0..4].parse().ok()?;
    let m: i64 = s[5..7].parse().ok()?;
    let d: i64 = s[8..10].parse().ok()?;
    let hh: i64 = s[11..13].parse().ok()?;
    let mm: i64 = s[14..16].parse().ok()?;
    let ss: i64 = s[17..19].parse().ok()?;
    // 越界的日期一律视为脏数据，而不是静默算出一个「合法」的错误时间
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) || hh > 23 || mm > 59 || ss > 60 {
        return None;
    }
    // 小数秒（可选）：跳过 `.` 后取连续数字
    let mut frac = 0u64;
    if let Some(rest) = s.get(19..) {
        let rest = rest.trim_start_matches(['.', ',']);
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        if !digits.is_empty() {
            let v: u64 = digits.parse().ok()?;
            let div = 10u64.pow(digits.len() as u32);
            frac = v * 1000 / div;
        }
    }
    let days = days_from_civil(y, m, d);
    let secs = days * 86_400 + hh * 3600 + mm * 60 + ss;
    if secs < 0 {
        return None;
    }
    Some((secs as u64) * 1000 + frac)
}

/// 公历年月日 -> 天数（1970-01-01 = day 0）
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// 相对时间的档位（界面用它选 RelativeTimeFormat / 本地化单位）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelativeUnit {
    JustNow,
    Minute,
    Hour,
    Day,
    Month,
    Year,
}

impl RelativeUnit {
    pub fn as_str(&self) -> &'static str {
        match self {
            RelativeUnit::JustNow => "justNow",
            RelativeUnit::Minute => "minute",
            RelativeUnit::Hour => "hour",
            RelativeUnit::Day => "day",
            RelativeUnit::Month => "month",
            RelativeUnit::Year => "year",
        }
    }
}

/// 相对时间的（数值，单位）。
///
/// 定单位时**向下取整到单位边界**，这样「59分59秒」显示成「59分钟前」
/// 而不是「1分钟前」—— 少一秒就跳一档的话，界面读起来像在乱蹦。
pub fn relative_parts(ms: u64, now_ms: u64) -> (i64, RelativeUnit) {
    let diff = now_ms as i64 - ms as i64;
    let sec = (diff.abs() + 500) / 1000;
    let min = sec / 60;
    let hour = min / 60;
    let day = hour / 24;
    let month = day / 30;
    let year = month / 12;
    let (value, unit) = if year >= 1 {
        (year, RelativeUnit::Year)
    } else if month >= 1 {
        (month, RelativeUnit::Month)
    } else if day >= 1 {
        (day, RelativeUnit::Day)
    } else if hour >= 1 {
        (hour, RelativeUnit::Hour)
    } else if min >= 1 {
        (min, RelativeUnit::Minute)
    } else {
        (0, RelativeUnit::JustNow)
    };
    (if diff >= 0 { value } else { -value }, unit)
}

/// 剩余天数，用于截稿倒计时；已过期返回负数
pub fn days_left(deadline: &str, now_ms: u64) -> i64 {
    match parse_iso_ms(deadline) {
        Some(t) => {
            let d = t as i64 - now_ms as i64;
            // 向上取整：还剩 1 小时也算「还剩 1 天」
            (d + 86_400_000 - 1) / 86_400_000
        }
        None => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_roundtrip() {
        for ms in [0u64, 1, 999, 86_400_000, 1_700_000_000_000, 9_999_999_999_999] {
            let s = iso_of_ms(ms);
            assert_eq!(parse_iso_ms(&s), Some(ms), "roundtrip failed {ms} -> {s}");
        }
    }

    #[test]
    fn epoch_is_1970() {
        assert_eq!(iso_of_ms(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(parse_iso_ms("1970-01-01T00:00:00.000Z"), Some(0));
    }

    #[test]
    fn garbage_does_not_panic() {
        assert_eq!(parse_iso_ms(""), None);
        assert_eq!(parse_iso_ms("not a date"), None);
        assert_eq!(parse_iso_ms("2026-13-99T99:99:99.000Z"), None);
    }

    #[test]
    fn relative_units_floor_to_boundary() {
        let now = 1_000_000_000u64;
        // 59 分 59 秒前 -> 59 分钟前
        let (v, u) = relative_parts(now - 59 * 60_000 - 59_000, now);
        assert_eq!((v, u), (59, RelativeUnit::Minute));
        let (v, u) = relative_parts(now - 3 * 86_400_000, now);
        assert_eq!((v, u), (3, RelativeUnit::Day));
    }
}