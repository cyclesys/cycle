#include "internal.h"

RenderText* createRenderText(RenderContext* context, Size max_size, Slice chars, f32 font_size) {
    RenderText* text = new RenderText();

    text->chars = new wchar_t[chars.len];
    text->chars_len = MultiByteToWideChar(
        CP_UTF8,
        0,
        reinterpret_cast<char*>(chars.ptr),
        chars.len,
        text->chars,
        chars.len
    );

    if (context->text_factory->CreateTextFormat(
            L"Segoe UI",
            nullptr,
            DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            font_size,
            L"en-us",
            &text->format
    ) != S_OK) {
        destroyRenderText(text);
        return nullptr;
    }


    if (context->text_factory->CreateTextLayout(
        text->chars,
        text->chars_len,
        text->format,
        max_size.width,
        max_size.height,
        &text->layout
    ) != S_OK) {
        destroyRenderText(text);
        return nullptr;
    }

    return text;
}

void destroyRenderText(RenderText* text) {
    RELEASE(text->layout);
    RELEASE(text->format);
    delete[] text->chars;
    text->chars = nullptr;
    delete text;
}

bool resizeText(RenderText* text, Size size) {
    return text->layout->SetMaxWidth(size.width) == S_OK &&
           text->layout->SetMaxHeight(size.height) == S_OK;
}

Rect getTextRect(RenderText* text) {
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
