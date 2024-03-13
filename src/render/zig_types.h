#ifndef CYCLE_ZIG_TYPES
#define CYCLE_ZIG_TYPES

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t u32;
typedef uint16_t u16;
typedef uint8_t u8;
typedef uintptr_t usize;
typedef float f32;

struct Slice {
    void* ptr;
    usize len;
};

#ifdef __cplusplus
}
#endif
#endif
