#include <unknwnbase.h>
#include "internal.h"

Context* createContext() {
    auto ctx = new Context();

    if (D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &ctx->factory) != S_OK) {
        destroyContext(ctx);
        return nullptr;
    }

    if (DWriteCreateFactory(
        DWRITE_FACTORY_TYPE_SHARED,
        __uuidof(IDWriteFactory),
        (IUnknown**)&ctx->text_factory
    ) != S_OK) {
        destroyContext(ctx);
        return nullptr;
    }

    return ctx;
}

void destroyContext(Context* ctx) {
    RELEASE(ctx->text_factory);
    RELEASE(ctx->factory);
    delete ctx;
}
