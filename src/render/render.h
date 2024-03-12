#ifndef CYCLE_RENDER
#define CYCLE_RENDER

#include <windef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned int u32;
typedef float f32;
typedef u32 Color;

struct Offset {
    u32 dx;
    u32 dy;
};

struct Size {
    u32 width;
    u32 height;
};

struct Rect {
    Offset offset;
    Size size;
};

struct RRect {
    Rect rect;
    u32 rx;
    u32 ry;
};

struct RenderContext;

RenderContext* createRenderContext(HWND hwnd, u32 width, u32 height);

void destroyRenderContext(RenderContext* context);

void beginFrame(RenderContext* context);

bool endFrame(RenderContext* context);

struct RenderTarget;

RenderTarget* createRenderTarget(RenderContext* context, u32 width, u32 height);

void destroyRenderTarget(RenderTarget* target);

void drawRect(RenderTarget* target, Rect rect, Color color);

void drawRRect(RenderTarget* target, RRect rrect, Color color);

#ifdef __cplusplus
}
#endif
#endif
