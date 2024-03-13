#ifndef CYCLE_RENDER_INTERNAL
#define CYCLE_RENDER_INTERNAL

#include <d2d1_3.h>
#include <dwrite_3.h>
#include "render.h"

#define RELEASE(pp) \
    if (pp) { \
        pp->Release(); \
        pp = NULL; \
    }

#ifdef __cplusplus
extern "C" {
#endif

struct RenderContext {
    ID2D1Factory* factory;
    ID2D1HwndRenderTarget* target;
    IDWriteFactory* text_factory;
};

struct RenderTarget {
    ID2D1BitmapRenderTarget* bitmap;
};

struct RenderText {
    wchar_t* chars;
    usize chars_len;
    IDWriteTextFormat* format;
    IDWriteTextLayout* layout;
};

D2D1_COLOR_F colorToD2D(Color color);

D2D1_RECT_F rectToD2D(Rect r);

D2D1_ROUNDED_RECT rrectToD2D(RRect rr);

ID2D1SolidColorBrush* createFillBrush(RenderTarget* target, Color color);

#ifdef __cplusplus
}
#endif
#endif
