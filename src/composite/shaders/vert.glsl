#version 460

layout (location = 0) in vec2 pos;
layout (location = 1) in vec4 color;

layout (location = 0) out vec4 out_color;

void main() {
    out_color = color;
    gl_Position = vec4(pos.x, pos.y, 1.0, 1.0);
}
