#include "internal.h"

Window* createWindow(Context* ctx, void* hwnd, u32 width, u32 height) {
    auto wnd = new Window();

    if (ctx->factory->CreateHwndRenderTarget(
        D2D1::RenderTargetProperties(),
        D2D1::HwndRenderTargetProperties(reinterpret_cast<HWND>(hwnd), D2D_SIZE_U{ width, height }),
        &wnd->target
    ) != S_OK) {
        destroyWindow(wnd);
        return nullptr;
    }

    return wnd;
}

void destroyWindow(Window* wnd) {
    RELEASE(wnd->target);
    delete wnd;
}

void resizeWindow(Window* wnd, u32 width, u32 height) {
    wnd->target->Resize(D2D_SIZE_U{ width, height });
}

void beginFrame(Window* wnd) {
    wnd->target->BeginDraw();
    wnd->target->Clear(colorToD2D(0xFFFFFFFF));
}

bool endFrame(Window* wnd) {
    return wnd->target->EndDraw() == S_OK;
}

void drawObject(Window* wnd, Object* obj, Rect pos) {
    ID2D1Bitmap* bitmap;
    obj->target->GetBitmap(&bitmap);
    wnd->target->DrawBitmap(
        bitmap,
        rectToD2D(pos),
        1.0,
        D2D1_BITMAP_INTERPOLATION_MODE_LINEAR
    );
}
