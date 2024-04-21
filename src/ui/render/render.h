#ifndef CYCLE_RENDER
#define CYCLE_RENDER

#include <stdbool.h>
#include "zig_types.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef u32 Color;

typedef struct Offset {
    f32 dx;
    f32 dy;
} Offset;

typedef struct Size {
    f32 width;
    f32 height;
} Size;

typedef struct Rect {
    Offset offset;
    Size size;
} Rect;

typedef struct RRect {
    Rect rect;
    f32 rx;
    f32 ry;
} RRect;

typedef struct Oval {
    Offset offset;
    f32 rx;
    f32 ry;
} Oval;

typedef struct Context Context;

typedef struct Window Window;

typedef struct Object Object;

typedef struct Text Text;

Context* createContext();

void destroyContext(Context* ctx);

Window* createWindow(Context* ctx, void* hwnd, u32 width, u32 height);

void destroyWindow(Window* wnd);

void resizeWindow(Window* wnd, u32 width, u32 height);

void beginFrame(Window* wnd);

bool endFrame(Window* wnd);

void drawObject(Window* wnd, Object* obj, Rect pos);

Object* createObject(Window* wnd, Size size);

void destroyObject(Object* obj);

void beginDraw(Object* obj);

bool endDraw(Object* obj);

void drawRect(Object* obj, Rect rect, Color color);

void drawRRect(Object* obj, RRect rrect, Color color);

void drawOval(Object* obj, Oval oval, Color color);

void drawText(Object* obj, Text* text, Offset offset);

Text* createText(Context* ctx, Size max_size, ConstSlice chars, f32 font_size);

void destroyText(Text* text);

bool resizeText(Text* text, Size size);

Rect getTextRect(Text* text);

#ifdef __cplusplus
}
#endif
#endif
