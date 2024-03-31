#include "internal.h"

Object* createObject(Window* wnd, Size size) {
    auto obj = new Object();

    auto size_d2d = sizeToD2D(size);
    wnd->target->CreateCompatibleRenderTarget(
        &size_d2d,
        nullptr,
        nullptr,
        D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS_NONE,
        &obj->target
    );

    return obj;
}

void destroyObject(Object* obj) {
    RELEASE(obj->target);
    delete obj;
}

void beginDraw(Object* obj) {
    obj->target->BeginDraw();
}

bool endDraw(Object* obj) {
    return obj->target->EndDraw() == S_OK;
}

void drawRect(Object* obj, Rect rect, Color c) {
    auto color_brush = createFillBrush(obj, c);
    obj->target->DrawRectangle(rectToD2D(rect), color_brush);
    RELEASE(color_brush);
}

void drawRRect(Object* obj, RRect rrect, Color color) {
    auto color_brush = createFillBrush(obj, color);
    obj->target->DrawRoundedRectangle(rrectToD2D(rrect), color_brush);
    RELEASE(color_brush);
}

void drawOval(Object* obj, Oval oval, Color color) {
    auto color_brush = createFillBrush(obj, color);
    obj->target->DrawEllipse(ovalToD2D(oval), color_brush);
    RELEASE(color_brush);
}

void drawText(Object* obj, Text* text, Offset offset) {
    auto fill_brush = createFillBrush(obj, 0xFF);
    obj->target->DrawTextLayout(
        offsetToD2D(offset),
        text->layout,
        fill_brush,
        D2D1_DRAW_TEXT_OPTIONS_NONE
    );
    RELEASE(fill_brush);
}
