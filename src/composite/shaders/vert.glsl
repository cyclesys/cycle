#version 460

layout (location = 0) in uvec2 pos;
layout (location = 1) in uint idx;

layout (location = 0) out uvec2 out_pos;
layout (location = 1) out uint out_idx;

void main() {
    out_pos = pos;
    out_idx = idx;
    gl_Position = vec4(float(pos.x), float(pos.y), 1.0, 1.0);
}
