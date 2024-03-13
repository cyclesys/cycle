#include "internal.h"

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

void drawTarget(RenderContext* context, RenderTarget* target, Rect dest) {
    ID2D1Bitmap* bitmap;
    target->bitmap->GetBitmap(&bitmap);
    context->target->DrawBitmap(
        bitmap,
        rectToD2D(dest),
        1.0,
        D2D1_BITMAP_INTERPOLATION_MODE_LINEAR
    );
}
