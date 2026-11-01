//! 配色引擎
//! --------
//! 站点不再写死某一种绿色。所有颜色都由「主色相 + 饱和度」推导出一整套设计令牌 ——
//! 换句话说，换个色相，整套界面会自己换衣服。
//!
//! 这样做的好处是可配置得很彻底：
//!   - 用户可以任选主色，页面所有强调色、边框都会自动协调；
//!   - 明暗两套只差一组亮度参数，不存在「某个色在暗色模式下看不见」；
//!   - 调色板是纯函数，可以脱离界面测试，也便于做预设。
//!
//! 之所以在 Rust 里算 hex 而不是直接用色彩空间函数：
//! 数值确定、可快照测试，三个平台（Linux / Windows / Android）渲染一致。

/// 品牌色：色相 0-360，饱和度 0-100
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BrandColor {
    pub hue: i32,
    pub sat: i32,
}

/// 强调色相对主色的色相偏移，保证评分星 / 徽章始终有对比
pub const ACCENT_OFFSET: i32 = 42;

pub const DEFAULT_BRAND: BrandColor = BrandColor { hue: 152, sat: 64 };

fn clamp(v: f64, min: f64, max: f64) -> f64 {
    v.clamp(min, max)
}

/// HSL -> `#rrggbb`（或带 alpha 时 `#rrggbbaa`）
pub fn hsl(h: f64, s: f64, l: f64, a: Option<f64>) -> String {
    let hh = ((h % 360.0) + 360.0) % 360.0;
    let ss = clamp(s, 0.0, 100.0);
    let ll = clamp(l, 0.0, 100.0);
    let hex = hsl_to_hex(hh, ss, ll);
    match a {
        None => hex,
        Some(alpha) => {
            let v = (clamp(alpha, 0.0, 1.0) * 255.0).round() as u32;
            format!("{hex}{v:02x}")
        }
    }
}

fn hsl_to_hex(h: f64, s: f64, l: f64) -> String {
    let s = s / 100.0;
    let l = l / 100.0;
    let k = |n: f64| (n + h / 30.0) % 12.0;
    let a = s * l.min(1.0 - l);
    let f = |n: f64| l - a * (-1f64).max((k(n) - 3.0).min((9.0 - k(n)).min(1.0)));
    let to = |x: f64| format!("{:02x}", (255.0 * x).round() as u32);
    format!("#{}{}{}", to(f(0.0)), to(f(8.0)), to(f(4.0)))
}

/// `#rrggbb` -> 品牌色（用于「从当前主题反推色相」的取色器）
pub fn hex_to_hsl(hex: &str) -> BrandColor {
    let s = hex.trim().trim_start_matches('#');
    if s.len() != 6 {
        return DEFAULT_BRAND;
    }
    let Ok(int) = i64::from_str_radix(&s[..6], 16) else {
        return DEFAULT_BRAND;
    };
    let r = ((int >> 16) & 255) as f64 / 255.0;
    let g = ((int >> 8) & 255) as f64 / 255.0;
    let b = (int & 255) as f64 / 255.0;
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let l = (max + min) / 2.0;
    let d = max - min;
    if d == 0.0 {
        return BrandColor { hue: 0, sat: 0 };
    }
    let sat = if l > 0.5 { d / (2.0 - max - min) } else { d / (max + min) };
    let h = if max == r {
        ((g - b) / d + if g < b { 6.0 } else { 0.0 }) * 60.0
    } else if max == g {
        ((b - r) / d + 2.0) * 60.0
    } else {
        ((r - g) / d + 4.0) * 60.0
    };
    BrandColor { hue: h.round() as i32, sat: (sat * 100.0).round() as i32 }
}

/// 派生出的整套设计令牌
#[derive(Debug, Clone, Default)]
pub struct Palette {
    pub background: String,
    pub foreground: String,
    pub surface: String,
    pub surface2: String,
    pub surface3: String,
    pub border: String,
    pub border_strong: String,
    pub muted: String,
    pub muted_strong: String,
    pub primary: String,
    pub primary_hover: String,
    pub primary_strong: String,
    pub primary_soft: String,
    pub primary_soft2: String,
    pub primary_ring: String,
    pub accent: String,
    pub accent_soft: String,
    pub danger: String,
    pub info: String,
    pub header_bg: String,
    /// Liquid Glass 三色：染色 / 暗边 / 高光。
    /// 玻璃之所以能读出深度，靠的就是这一暗一亮 —— 只调透明度是糊，不是玻璃。
    pub glass_tint: String,
    pub glass_edge: String,
    pub glass_spec: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThemeMode {
    Light,
    Dark,
}

impl ThemeMode {
    pub fn parse(s: &str) -> Self {
        if s == "dark" {
            ThemeMode::Dark
        } else {
            ThemeMode::Light
        }
    }
    pub fn as_str(&self) -> &'static str {
        match self {
            ThemeMode::Light => "light",
            ThemeMode::Dark => "dark",
        }
    }
}

fn light_palette(c: BrandColor) -> Palette {
    let hue = c.hue as f64;
    let s = c.sat as f64;
    let accent = hue + ACCENT_OFFSET as f64;
    Palette {
        background: hsl(hue, 18.0, 100.0, None),
        foreground: hsl(hue, 24.0, 12.0, None),
        surface: hsl(hue, 30.0, 97.0, None),
        surface2: hsl(hue, 26.0, 94.0, None),
        surface3: hsl(hue, 24.0, 89.0, None),
        border: hsl(hue, 20.0, 89.0, None),
        border_strong: hsl(hue, 17.0, 77.0, None),
        muted: hsl(hue, 12.0, 46.0, None),
        muted_strong: hsl(hue, 16.0, 32.0, None),
        primary: hsl(hue, s, 37.0, None),
        primary_hover: hsl(hue, s, 31.0, None),
        primary_strong: hsl(hue, s, 23.0, None),
        primary_soft: hsl(hue, s.min(70.0) * 0.55, 94.0, None),
        primary_soft2: hsl(hue, s.min(70.0) * 0.6, 86.0, None),
        primary_ring: hsl(hue, s, 37.0, Some(0.35)),
        accent: hsl(accent, clamp(s + 8.0, 45.0, 92.0), 45.0, None),
        accent_soft: hsl(accent, clamp(s + 8.0, 45.0, 92.0) * 0.5, 94.0, None),
        danger: hsl(354.0, 68.0, 47.0, None),
        info: hsl(205.0, 72.0, 48.0, None),
        header_bg: hsl(hue, 30.0, 100.0, Some(0.86)),
        glass_tint: hsl(hue, clamp(s, 26.0, 92.0), 86.0, None),
        glass_edge: hsl(hue, clamp(s, 26.0, 92.0) * 0.55, 72.0, Some(0.55)),
        glass_spec: hsl(hue, 34.0, 100.0, Some(0.95)),
    }
}

fn dark_palette(c: BrandColor) -> Palette {
    let hue = c.hue as f64;
    let s = c.sat as f64;
    let accent = hue + ACCENT_OFFSET as f64;
    // 暗色下主色要更亮，否则正文里的 primary 文字会糊掉
    let ps = clamp(s, 40.0, 90.0);
    Palette {
        background: hsl(hue, 16.0, 5.0, None),
        foreground: hsl(hue, 14.0, 89.0, None),
        surface: hsl(hue, 15.0, 8.0, None),
        surface2: hsl(hue, 14.0, 11.0, None),
        surface3: hsl(hue, 13.0, 15.0, None),
        border: hsl(hue, 13.0, 18.0, None),
        border_strong: hsl(hue, 12.0, 27.0, None),
        muted: hsl(hue, 9.0, 55.0, None),
        muted_strong: hsl(hue, 11.0, 73.0, None),
        primary: hsl(hue, ps, 58.0, None),
        primary_hover: hsl(hue, ps, 66.0, None),
        primary_strong: hsl(hue, ps, 78.0, None),
        primary_soft: hsl(hue, ps * 0.35, 11.0, None),
        primary_soft2: hsl(hue, ps * 0.4, 17.0, None),
        primary_ring: hsl(hue, ps, 58.0, Some(0.4)),
        accent: hsl(accent, clamp(s + 10.0, 50.0, 95.0), 62.0, None),
        accent_soft: hsl(accent, clamp(s + 10.0, 50.0, 95.0) * 0.35, 16.0, None),
        danger: hsl(354.0, 82.0, 68.0, None),
        info: hsl(205.0, 78.0, 66.0, None),
        header_bg: hsl(hue, 16.0, 5.0, Some(0.84)),
        // 暗色下的玻璃：染色更沉、边缘更黑、高光更收敛，
        // 否则深色界面上的「亮边」会亮得像一条划痕。
        glass_tint: hsl(hue, clamp(s, 26.0, 92.0) * 0.42, 19.0, None),
        glass_edge: hsl(hue, 16.0, 3.0, Some(0.72)),
        glass_spec: hsl(hue, 40.0, 92.0, Some(0.16)),
    }
}

pub fn build_palette(c: BrandColor, mode: ThemeMode) -> Palette {
    match mode {
        ThemeMode::Dark => dark_palette(c),
        ThemeMode::Light => light_palette(c),
    }
}

/// 预设色。`name_key` 是字典键而不是名字本身 —— 色名是用户会读的字。
pub struct Preset {
    pub name_key: &'static str,
    pub brand: BrandColor,
}

pub const PRESETS: [Preset; 8] = [
    Preset { name_key: "set.preset.moss", brand: BrandColor { hue: 152, sat: 64 } },
    Preset { name_key: "set.preset.sea", brand: BrandColor { hue: 205, sat: 72 } },
    Preset { name_key: "set.preset.dusk", brand: BrandColor { hue: 272, sat: 58 } },
    Preset { name_key: "set.preset.sakura", brand: BrandColor { hue: 338, sat: 66 } },
    Preset { name_key: "set.preset.amber", brand: BrandColor { hue: 36, sat: 78 } },
    Preset { name_key: "set.preset.vermilion", brand: BrandColor { hue: 8, sat: 70 } },
    Preset { name_key: "set.preset.frost", brand: BrandColor { hue: 188, sat: 62 } },
    Preset { name_key: "set.preset.ink", brand: BrandColor { hue: 220, sat: 12 } },
];

/// 输入清洗：色相取模到 0-360，饱和度夹到 0-100
pub fn sanitize_brand(hue: i32, sat: i32) -> BrandColor {
    BrandColor {
        hue: ((hue % 360) + 360) % 360,
        sat: sat.clamp(0, 100),
    }
}

/// 相对亮度（WCAG）—— 校验正文对比度用
pub fn relative_luminance(hex: &str) -> f64 {
    let s = hex.trim().trim_start_matches('#');
    let rgb: Vec<f64> = (0..3)
        .map(|i| {
            let Ok(v) = i64::from_str_radix(&s[i * 2..i * 2 + 2], 16) else {
                return 0.0;
            };
            let c = v as f64 / 255.0;
            if c <= 0.03928 {
                c / 12.92
            } else {
                ((c + 0.055) / 1.055).powf(2.4)
            }
        })
        .collect();
    0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
}

/// 对比度（WCAG）
pub fn contrast_ratio(a: &str, b: &str) -> f64 {
    let la = relative_luminance(a);
    let lb = relative_luminance(b);
    let (hi, lo) = (la.max(lb), la.min(lb));
    (hi + 0.05) / (lo + 0.05)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// README 里写明的硬指标：360° 全色相下正文对比度均 ≥ 7:1（WCAG AAA）
    #[test]
    fn body_contrast_is_aaa_for_every_hue() {
        for hue in (0..360).step_by(5) {
            for mode in [ThemeMode::Light, ThemeMode::Dark] {
                let p = build_palette(BrandColor { hue, sat: 64 }, mode);
                let ratio = contrast_ratio(&p.foreground, &p.background);
                assert!(
                    ratio >= 7.0,
                    "hue={hue} mode={:?} 对比度只有 {ratio:.2}",
                    mode
                );
                // 玻璃底上的正文同样要能读
                let on_glass = contrast_ratio(&p.foreground, &p.surface);
                assert!(
                    on_glass >= 7.0,
                    "hue={hue} mode={:?} 玻璃底对比度只有 {on_glass:.2}",
                    mode
                );
            }
        }
    }

    /// 默认绿的实际取值。
    ///
    /// ⚠️ 与 Web 版 `app/globals.css` 里硬编码的 `--primary: #16a06a` **对不上**：
    /// 那个值反推出来是 h≈156.5 / s≈76% / l≈35.7%，而 `DEFAULT_BRAND` 是 152/64，
    /// 按同一套公式算出的是 #229b62。也就是说 CSS 里那份是先于配色引擎手写的、
    /// 引擎接手后没跟着更新的残留值。本移植以 `palette.ts` 的公式为准（它是引擎），
    /// 并在 README 里记下这处不一致。
    #[test]
    fn default_brand_matches_the_palette_engine() {
        let p = build_palette(DEFAULT_BRAND, ThemeMode::Light);
        assert_eq!(p.primary, "#229b62");
        assert_eq!(p.background, "#ffffff");
        assert_eq!(p.accent, hsl(152.0 + ACCENT_OFFSET as f64, 72.0, 45.0, None));
        let d = build_palette(DEFAULT_BRAND, ThemeMode::Dark);
        assert_eq!(d.primary, hsl(152.0, 64.0, 58.0, None));
        // 暗色主色必须比亮色更亮，否则正文里的 primary 文字会糊掉
        assert!(relative_luminance(&d.primary) > relative_luminance(&p.primary));
    }

    #[test]
    fn hex_roundtrip() {
        let b = BrandColor { hue: 205, sat: 72 };
        let hex = hsl(b.hue as f64, b.sat as f64, 45.0, None);
        let back = hex_to_hsl(&hex);
        assert!((back.hue - b.hue).abs() <= 2, "{:?} -> {hex} -> {:?}", b, back);
    }
}