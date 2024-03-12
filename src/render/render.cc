#include <vector>
#include <d2d1.h>
#include "render.h"

#define RELEASE(pp) \
    if (pp) { \
        pp->Release(); \
        pp = NULL; \
    }

#define COLOR_CHAN_BITS 0xFF
#define COLOR_CHAN_R_SHIFT 24
#define COLOR_CHAN_G_SHIFT 16
#define COLOR_CHAN_B_SHIFT 8
#define COLOR_CHAN_R_MASK COLOR_CHAN_BITS << COLOR_CHAN_R_SHIFT
#define COLOR_CHAN_G_MASK COLOR_CHAN_BITS << COLOR_CHAN_G_SHIFT
#define COLOR_CHAN_B_MASK COLOR_CHAN_BITS << COLOR_CHAN_B_SHIFT
#define COLOR_CHAN_A_MASK COLOR_CHAN_BITS
#define COLOR_CHAN_R(c) (c & COLOR_CHAN_R_MASK) >> COLOR_CHAN_R_SHIFT
#define COLOR_CHAN_G(c) (c & COLOR_CHAN_G_MASK) >> COLOR_CHAN_G_SHIFT
#define COLOR_CHAN_B(c) (c & COLOR_CHAN_B_MASK) >> COLOR_CHAN_B_SHIFT
#define COLOR_CHAN_A(c) (c & COLOR_CHAN_A_MASK)

D2D1_COLOR_F colorToD2D(Color color) {
    D2D1_COLOR_F color_f;
    color_f.r = static_cast<FLOAT>(COLOR_CHAN_R(color)) / 255.f;
    color_f.g = static_cast<FLOAT>(COLOR_CHAN_G(color)) / 255.f;
    color_f.b = static_cast<FLOAT>(COLOR_CHAN_B(color)) / 255.f;
    color_f.a = static_cast<FLOAT>(COLOR_CHAN_A(color)) / 255.f;
    return color_f;
}

D2D1_RECT_F rectToD2D(Rect r) {
    D2D1_RECT_F rect;
    rect.left = r.offset.dx;
    rect.top = r.offset.dy;
    rect.right = r.offset.dx + r.size.width;
    rect.bottom = r.offset.dy + r.size.height;
    return rect;
}

D2D1_ROUNDED_RECT rrectToD2D(RRect rr) {
    D2D1_ROUNDED_RECT rrect;
    rrect.rect = rectToD2D(rr.rect);
    rrect.radiusX = (FLOAT) rr.rx;
    rrect.radiusY = (FLOAT) rr.ry;
    return rrect;
}

struct RenderContext {
    ID2D1Factory* factory;
    ID2D1HwndRenderTarget* target;
};

RenderContext* createRenderContext(HWND hwnd, u32 width, u32 height) {
    RenderContext* context = new RenderContext();

    if (D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &context->factory) != S_OK) {
        destroyRenderContext(context);
        return nullptr;
    }

    if (context->factory->CreateHwndRenderTarget(
        D2D1::RenderTargetProperties(),
        D2D1::HwndRenderTargetProperties(hwnd, D2D1::SizeU(width, height)),
        &context->target
    ) != S_OK) {
        destroyRenderContext(context);
        return nullptr;
    }

    return context;
}

void destroyRenderContext(RenderContext* context) {
    RELEASE(context->target);
    RELEASE(context->factory);
    delete context;
}

void beginFrame(RenderContext* context) {
    context->target->BeginDraw();
}

bool endFrame(RenderContext* context) {
    return context->target->EndDraw() == S_OK;
}

struct RenderTarget {
    ID2D1BitmapRenderTarget* bitmap;
};

ID2D1SolidColorBrush* createFillBrush(RenderTarget* target, Color color) {
    D2D1_COLOR_F brush_color = colorToD2D(color);

    D2D1_BRUSH_PROPERTIES brush_properties;
    brush_properties.opacity = 1.0;

    ID2D1SolidColorBrush* brush;
    target->bitmap->CreateSolidColorBrush(
        &brush_color,
        &brush_properties,
        &brush
    );
    return brush;
}

RenderTarget* createRenderTarget(RenderContext* context, u32 width, u32 height) {
    D2D1_SIZE_F size;
    size.width = (float) width;
    size.height = (float) height;

    ID2D1BitmapRenderTarget* bitmap;
    context->target->CreateCompatibleRenderTarget(
        &size,
        nullptr,
        nullptr,
        D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS_NONE,
        &bitmap
    );

    RenderTarget* target = new RenderTarget();
    target->bitmap = bitmap;
    return target;
}

void destroyRenderTarget(RenderTarget* target) {
    RELEASE(target->bitmap);
    delete target;
}

void beginDraw(RenderTarget* target) {
    target->bitmap->BeginDraw();
}

bool endDraw(RenderTarget* target) {
    return target->bitmap->EndDraw() == S_OK;
}

void drawRect(RenderTarget* target, Rect r, Color c) {
    D2D1_RECT_F rect = rectToD2D(r);
    ID2D1SolidColorBrush* color_brush = createFillBrush(target, c);
    target->bitmap->DrawRectangle(rect, color_brush);
    RELEASE(color_brush);
}

void drawRRect(RenderTarget* target, RRect rr, Color color) {
    D2D1_ROUNDED_RECT rrect = rrectToD2D(rr);
    ID2D1SolidColorBrush* color_brush = createFillBrush(target, color);
    target->bitmap->DrawRoundedRectangle(rrect, color_brush);
    RELEASE(color_brush);
}
