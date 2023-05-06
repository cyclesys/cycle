pub const Text = struct {
    text: []const u8,
    color: Color,
};

pub const Rect = struct {
    width: u16,
    height: u16,
    color: Color,
};

pub const Color = packed struct {
    a: u8,
    r: u8,
    g: u8,
    b: u8,

    pub const black = Color{
        .a = 255,
        .r = 0,
        .g = 0,
        .b = 0,
    };
};
