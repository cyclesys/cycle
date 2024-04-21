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

struct Context {
    ID2D1Factory* factory;
    IDWriteFactory* text_factory;
};

struct Window {
    ID2D1HwndRenderTarget* target;
};

struct Object {
    ID2D1BitmapRenderTarget* target;
};

struct Text {
    wchar_t* chars;
    usize chars_len;
    IDWriteTextFormat* format;
    IDWriteTextLayout* layout;
};

D2D1_COLOR_F colorToD2D(Color color);

D2D1_POINT_2F offsetToD2D(Offset offset);

D2D1_SIZE_F sizeToD2D(Size size);

D2D1_RECT_F rectToD2D(Rect r);

D2D1_ROUNDED_RECT rrectToD2D(RRect rr);

D2D1_ELLIPSE ovalToD2D(Oval o);

ID2D1SolidColorBrush* createFillBrush(Object* obj, Color color);

#ifdef __cplusplus
}
#endif
#endif
