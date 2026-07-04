// ---- Spacing (from Caelestia tokens.hpp) ----
pub const SPACE_XS: f32 = 4.0;
pub const SPACE_MD: f32 = 12.0;

// ---- Padding (from Caelestia tokens.hpp) ----
pub const PAD_SM: f32 = 8.0;
pub const PAD_MD: f32 = 12.0;

// ---- Rounding (from Caelestia tokens.hpp) ----
pub const RADIUS_SM: f32 = 8.0;
pub const RADIUS_LG: f32 = 16.0;
pub const RADIUS_FULL: f32 = 999.0;

// ---- Font Sizes (from Caelestia appearanceconfig.hpp) ----
pub const FONT_SMALL: f32 = 11.0;
pub const FONT_SMALLER: f32 = 12.0;
pub const FONT_NORMAL: f32 = 13.0;

// ---- Bar sizing (from Caelestia BarTokens) ----
pub const BAR_INNER_W: f32 = 44.0;
pub const BAR_TOTAL_W: f32 = BAR_INNER_W;

// ---- Bar layout (from Caelestia Bar.qml) ----
pub const BAR_MODULE_SPACING: f32 = SPACE_MD;
pub const BAR_SHOWN_WORKSPACES: usize = 5;

// ---- Workspace sizing ----
pub const WS_ITEM_H: f32 = BAR_INNER_W - PAD_SM;
pub const WS_SPACING: f32 = SPACE_XS;
pub const WS_INDICATOR_W: f32 = BAR_INNER_W - PAD_SM;
pub const WS_LABEL_SIZE: f32 = 10.0;
// Must be >= BAR_INNER_W / 2 so the first item clears the parent's RADIUS_FULL curve
pub const WS_PILL_PAD_V: f32 = BAR_INNER_W / 2.0;

// ---- Clock sizing ----
pub const CLOCK_SPACING: f32 = SPACE_XS;
pub const CLOCK_TIME_SIZE: f32 = 8.0;
pub const CLOCK_DATE_SIZE: f32 = 7.0;

// ---- StatusIcons sizing ----
pub const STATUS_ICON_SIZE: f32 = 12.0;
pub const STATUS_SPACING: f32 = SPACE_XS;

// ---- M3 Dark Palette (from Caelestia Colours.qml) ----
pub const C_M3_SURFACE_CONTAINER: (u8, u8, u8, u8) = (0x26, 0x1D, 0x20, 0xFF);
pub const C_M3_ON_SURFACE_VARIANT: (u8, u8, u8, u8) = (0xD5, 0xC2, 0xC6, 0xFF);
pub const C_M3_PRIMARY: (u8, u8, u8, u8) = (0xFF, 0xB0, 0xCA, 0xFF);
pub const C_M3_ON_PRIMARY: (u8, u8, u8, u8) = (0x54, 0x1D, 0x34, 0xFF);
pub const C_M3_SECONDARY: (u8, u8, u8, u8) = (0xE2, 0xBD, 0xC7, 0xFF);
pub const C_M3_TERTIARY: (u8, u8, u8, u8) = (0xF0, 0xBC, 0x95, 0xFF);
pub const C_M3_ERROR: (u8, u8, u8, u8) = (0xFF, 0xB4, 0xAB, 0xFF);

// ---- Semantic Aliases ----
pub const C_MODULE_BG: (u8, u8, u8, u8) = C_M3_SURFACE_CONTAINER;
pub const C_WS_ACTIVE_BG: (u8, u8, u8, u8) = C_M3_PRIMARY;
pub const C_WS_ACTIVE_TEXT: (u8, u8, u8, u8) = C_M3_ON_PRIMARY;
pub const C_WS_INACTIVE_TEXT: (u8, u8, u8, u8) = (0xEF, 0xDF, 0xE2, 0xFF);
pub const C_WS_UNOCCUPIED_TEXT: (u8, u8, u8, u8) = (0x83, 0x73, 0x77, 0xFF);
pub const C_STATUS_ON: (u8, u8, u8, u8) = C_M3_SECONDARY;
pub const C_STATUS_OFF: (u8, u8, u8, u8) = C_M3_ON_SURFACE_VARIANT;
pub const C_CLOCK: (u8, u8, u8, u8) = C_M3_TERTIARY;
pub const C_POWER: (u8, u8, u8, u8) = C_M3_ERROR;
