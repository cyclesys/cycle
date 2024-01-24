#version 460
#extension GL_EXT_nonuniform_qualifier : enable

layout (location = 0) in flat uvec2 pos;
layout (location = 1) in flat uint idx;

layout (origin_upper_left) in vec4 gl_FragCoord;

layout (binding = 0) uniform sampler2D textures[];

layout (location = 0) out vec4 out_color;

void main() {
    int coord_x = int(floor(gl_FragCoord.x)) - int(pos.x);
    int coord_y = int(floor(gl_FragCoord.y)) - int(pos.y);
    out_color = texelFetch(textures[idx], ivec2(coord_x, coord_y), 0);
}
