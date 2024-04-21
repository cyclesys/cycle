#include "internal.h"

Text* createText(Context* ctx, Size max_size, ConstSlice chars, f32 font_size) {
    auto text = new Text();

    text->chars = new wchar_t[chars.len];
    text->chars_len = MultiByteToWideChar(
        CP_UTF8,
        0,
        reinterpret_cast<const char*>(chars.ptr),
        chars.len,
        text->chars,
        chars.len
    );

    if (ctx->text_factory->CreateTextFormat(
            L"Segoe UI",
            nullptr,
            DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            font_size,
            L"en-us",
            &text->format
    ) != S_OK) {
        destroyText(text);
        return nullptr;
    }


    if (ctx->text_factory->CreateTextLayout(
        text->chars,
        text->chars_len,
        text->format,
        max_size.width,
        max_size.height,
        &text->layout
    ) != S_OK) {
        destroyText(text);
        return nullptr;
    }

    return text;
}

void destroyText(Text* text) {
    RELEASE(text->layout);
    RELEASE(text->format);
    delete[] text->chars;
    text->chars = nullptr;
    delete text;
}

bool resizeText(Text* text, Size size) {
    return text->layout->SetMaxWidth(size.width) == S_OK &&
           text->layout->SetMaxHeight(size.height) == S_OK;
}

Rect getTextRect(Text* text) {
    DWRITE_TEXT_METRICS metrics;
    text->layout->GetMetrics(&metrics);
    return Rect{
        Offset{
            metrics.left,
            metrics.top
        },
        Size{
            metrics.width,
            metrics.height,
        },
    };
}
