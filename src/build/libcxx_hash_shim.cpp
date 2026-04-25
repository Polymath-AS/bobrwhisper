// Zig 0.16's bundled libc++ headers (LLVM 21) declare std::__hash_memory as an
// exported dylib symbol, but macOS's system libc++ does not provide it yet.
// This shim supplies the missing definition using the same cityhash algorithm
// that libc++ uses for 64-bit platforms.
//
// The implementation is adapted from libc++'s __functional/hash.h which uses
// CityHash64 on 64-bit targets.

#include <cstddef>
#include <cstring>

namespace std { inline namespace __1 {

// Cityhash constants
static const size_t __k0 = 0xc3a5c85c97cb3127ULL;
static const size_t __k1 = 0xb492b66fbe98f273ULL;
static const size_t __k2 = 0x9ae16a3b2f90404fULL;
static const size_t __k3 = 0xc949d7c7509e6557ULL;

static inline size_t __rotate(size_t val, int shift) {
    return shift == 0 ? val : ((val >> shift) | (val << (64 - shift)));
}

static inline size_t __rotate_by_at_least_1(size_t val, int shift) {
    return (val >> shift) | (val << (64 - shift));
}

static inline size_t __shift_mix(size_t val) {
    return val ^ (val >> 47);
}

static inline size_t __load8(const void* p) {
    size_t r;
    memcpy(&r, p, sizeof(r));
    return r;
}

static inline unsigned __load4(const void* p) {
    unsigned r;
    memcpy(&r, p, sizeof(r));
    return r;
}

static inline size_t __hash_len_16(size_t u, size_t v) {
    const size_t mul = 0x9ddfea08eb382d69ULL;
    size_t a = (u ^ v) * mul;
    a ^= (a >> 47);
    size_t b = (v ^ a) * mul;
    b ^= (b >> 47);
    b *= mul;
    return b;
}

static inline size_t __hash_len_0_to_16(const char* s, size_t len) {
    if (len > 8) {
        size_t a = __load8(s);
        size_t b = __load8(s + len - 8);
        return __hash_len_16(a, __rotate_by_at_least_1(b + len, static_cast<int>(len))) ^ b;
    }
    if (len >= 4) {
        size_t a = __load4(s);
        return __hash_len_16(len + (a << 3), __load4(s + len - 4));
    }
    if (len > 0) {
        unsigned char a = static_cast<unsigned char>(s[0]);
        unsigned char b = static_cast<unsigned char>(s[len >> 1]);
        unsigned char c = static_cast<unsigned char>(s[len - 1]);
        unsigned y = static_cast<unsigned>(a) + (static_cast<unsigned>(b) << 8);
        unsigned z = static_cast<unsigned>(len) + (static_cast<unsigned>(c) << 2);
        return __shift_mix(y * __k2 ^ z * __k3) * __k2;
    }
    return __k2;
}

static inline size_t __hash_len_17_to_32(const char* s, size_t len) {
    size_t a = __load8(s) * __k1;
    size_t b = __load8(s + 8);
    size_t c = __load8(s + len - 8) * __k2;
    size_t d = __load8(s + len - 16) * __k0;
    return __hash_len_16(
        __rotate(a - b, 43) + __rotate(c, 30) + d,
        a + __rotate(b ^ __k3, 20) - c + len
    );
}

static inline size_t __hash_len_33_to_64(const char* s, size_t len) {
    size_t z = __load8(s + 24);
    size_t a = __load8(s) + (len + __load8(s + len - 16)) * __k0;
    size_t b = __rotate(a + z, 52);
    size_t c = __rotate(a, 37);
    a += __load8(s + 8);
    c += __rotate(a, 7);
    a += __load8(s + 16);
    size_t vf = a + z;
    size_t vs = b + __rotate(a, 31) + c;
    a = __load8(s + 16) + __load8(s + len - 32);
    z += __load8(s + len - 8);
    b = __rotate(a + z, 52);
    c = __rotate(a, 37);
    a += __load8(s + len - 24);
    c += __rotate(a, 7);
    a += __load8(s + len - 16);
    size_t wf = a + z;
    size_t ws = b + __rotate(a, 31) + c;
    size_t r = __shift_mix((vf + ws) * __k2 + (wf + vs) * __k0);
    return __shift_mix(r * __k0 + vs) * __k2;
}

__attribute__((visibility("default")))
size_t __hash_memory(const void* __ptr, size_t __len) noexcept {
    const char* s = static_cast<const char*>(__ptr);
    if (__len <= 32) {
        if (__len <= 16) {
            return __hash_len_0_to_16(s, __len);
        } else {
            return __hash_len_17_to_32(s, __len);
        }
    } else if (__len <= 64) {
        return __hash_len_33_to_64(s, __len);
    }

    // For longer inputs, use the full CityHash64 algorithm
    size_t x = __load8(s + __len - 40);
    size_t y = __load8(s + __len - 16) + __load8(s + __len - 56);
    size_t z = __hash_len_16(__load8(s + __len - 48) + __len, __load8(s + __len - 24));

    size_t v0 = 0, v1 = 0, w0 = 0, w1 = 0;

    // weak_hash_len_32_with_seeds for v
    {
        size_t a1 = __len, b1 = z;
        size_t w_local = __load8(s + __len - 64);
        size_t x_local = __load8(s + __len - 64 + 8);
        size_t y_local = __load8(s + __len - 64 + 16);
        size_t z_local = __load8(s + __len - 64 + 24);
        a1 += w_local;
        b1 = __rotate(b1 + a1 + z_local, 21);
        size_t c1 = a1;
        a1 += x_local;
        a1 += y_local;
        b1 += __rotate(a1, 44);
        v0 = a1 + z_local;
        v1 = b1 + c1;
    }

    // weak_hash_len_32_with_seeds for w
    {
        size_t a1 = __len * __k1, b1 = x;
        size_t w_local = __load8(s + __len - 32);
        size_t x_local = __load8(s + __len - 32 + 8);
        size_t y_local = __load8(s + __len - 32 + 16);
        size_t z_local = __load8(s + __len - 32 + 24);
        a1 += w_local;
        b1 = __rotate(b1 + a1 + z_local, 21);
        size_t c1 = a1;
        a1 += x_local;
        a1 += y_local;
        b1 += __rotate(a1, 44);
        w0 = a1 + z_local;
        w1 = b1 + c1;
    }

    x = x * __k1 + __load8(s);

    size_t len_remaining = (__len - 1) & ~static_cast<size_t>(63);
    size_t offset = 0;
    do {
        x = __rotate(x + y + v0 + __load8(s + offset + 8), 37) * __k1;
        y = __rotate(y + v1 + __load8(s + offset + 48), 42) * __k1;
        x ^= w1;
        y += v0 + __load8(s + offset + 40);
        z = __rotate(z + w0, 33) * __k1;

        {
            size_t a1 = v1 * __k1, b1 = x + w0;
            size_t wl = __load8(s + offset);
            size_t xl = __load8(s + offset + 8);
            size_t yl = __load8(s + offset + 16);
            size_t zl = __load8(s + offset + 24);
            a1 += wl;
            b1 = __rotate(b1 + a1 + zl, 21);
            size_t c1 = a1;
            a1 += xl;
            a1 += yl;
            b1 += __rotate(a1, 44);
            v0 = a1 + zl;
            v1 = b1 + c1;
        }

        {
            size_t a1 = z + w1, b1 = y + __load8(s + offset + 16);
            size_t wl = __load8(s + offset + 32);
            size_t xl = __load8(s + offset + 32 + 8);
            size_t yl = __load8(s + offset + 32 + 16);
            size_t zl = __load8(s + offset + 32 + 24);
            a1 += wl;
            b1 = __rotate(b1 + a1 + zl, 21);
            size_t c1 = a1;
            a1 += xl;
            a1 += yl;
            b1 += __rotate(a1, 44);
            w0 = a1 + zl;
            w1 = b1 + c1;
        }

        size_t tmp = z;
        z = x;
        x = tmp;
        offset += 64;
        len_remaining -= 64;
    } while (len_remaining != 0);

    return __hash_len_16(
        __hash_len_16(v0, w0) + __shift_mix(y) * __k1 + z,
        __hash_len_16(v1, w1) + x
    );
}

}}
