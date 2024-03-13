#include "internal.h"

RenderTarget* createRenderTarget(RenderContext* context, u32 width, u32 height) {
    RenderTarget* target = new RenderTarget();

    D2D1_SIZE_F size;
    size.width = (float) width;
    size.height = (float) height;
    context->target->CreateCompatibleRenderTarget(
        &size,
        nullptr,
        nullptr,
        D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS_NONE,
        &target->bitmap
    );

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

void drawText(RenderTarget* target, RenderText* text, Offset offset) {
    D2D1_POINT_2F origin;
    origin.x = (FLOAT) offset.dx;
    origin.y = (FLOAT) offset.dy;

    ID2D1SolidColorBrush* fill_brush = createFillBrush(target, 0xFF);
    target->bitmap->DrawTextLayout(
        origin,
        text->layout,
        fill_brush,
        D2D1_DRAW_TEXT_OPTIONS_NONE
    );
    RELEASE(fill_brush);
}
