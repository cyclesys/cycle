#ifndef CYCLE_RENDER
#define CYCLE_RENDER

#include <windef.h>
#include "zig_types.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef u32 Color;

struct Offset {
    f32 dx;
    f32 dy;
};

struct Size {
    f32 width;
    f32 height;
};

struct Rect {
    Offset offset;
    Size size;
};

struct RRect {
    Rect rect;
    f32 rx;
    f32 ry;
};

struct RenderContext;

struct RenderTarget;

struct RenderText;

RenderContext* createRenderContext(HWND hwnd, u32 width, u32 height);

void destroyRenderContext(RenderContext* context);

void beginFrame(RenderContext* context);

bool endFrame(RenderContext* context);

void drawTarget(RenderContext* context, RenderTarget* target);

RenderTarget* createRenderTarget(RenderContext* context, u32 width, u32 height);

void destroyRenderTarget(RenderTarget* target);

void beginDraw(RenderTarget* target);

bool endDraw(RenderTarget* target);

void drawRect(RenderTarget* target, Rect rect, Color color);

void drawRRect(RenderTarget* target, RRect rrect, Color color);

void drawText(RenderTarget* target, RenderText* text);

RenderText* createRenderText(RenderTarget* target, Size size, Slice text, f32 text_size);

void destroyRenderText(RenderText* text);

bool resizeText(RenderText* text, Size size);

Rect getTextRect(RenderText* text);

#ifdef __cplusplus
}
#endif
#endif
