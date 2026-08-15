// Copyright (c) 2026 Paul Butcher. All rights reserved.
// Released under Apache 2.0 license as described in the file LICENSE.
//
// FFI shim exposing AES-256-GCM (via OpenSSL's libcrypto EVP API) to Lean as
// two functions, `lean_aes256_gcm_seal`/`lean_aes256_gcm_open`. Both operate
// on raw `ByteArray`s (Lean's `lean_sarray_*` scalar-array representation)
// and assume, rather than validate for a hostile caller, that `key`/`nonce`
// are exactly 32/12 bytes -- the only caller is `Middleware.CookieStore`,
// which always generates them at that size itself.

#include <lean/lean.h>

#include <openssl/evp.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

static const size_t kKeyLen = 32;
static const size_t kNonceLen = 12;
static const size_t kTagLen = 16;

static lean_obj_res mk_byte_array(const unsigned char *data, size_t size) {
    lean_object *arr = lean_alloc_sarray(1, size, size);
    if (size > 0) {
        memcpy(lean_sarray_cptr(arr), data, size);
    }
    return arr;
}

static lean_obj_res mk_none(void) {
    return lean_box(0);
}

static lean_obj_res mk_some(lean_obj_arg value) {
    lean_object *r = lean_alloc_ctor(1, 1, 0);
    lean_ctor_set(r, 0, value);
    return r;
}

LEAN_EXPORT lean_obj_res lean_aes256_gcm_seal(
    b_lean_obj_arg key, b_lean_obj_arg nonce, b_lean_obj_arg plaintext) {
    if (lean_sarray_size(key) != kKeyLen || lean_sarray_size(nonce) != kNonceLen) {
        return mk_byte_array(NULL, 0);
    }
    size_t ptLen = lean_sarray_size(plaintext);

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) {
        return mk_byte_array(NULL, 0);
    }

    unsigned char *out = (unsigned char *)malloc(ptLen + kTagLen);
    int outl = 0;
    int tmplen = 0;
    bool ok = EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) == 1;
    ok = ok && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, (int)kNonceLen, NULL) == 1;
    ok = ok && EVP_EncryptInit_ex(ctx, NULL, NULL, lean_sarray_cptr(key), lean_sarray_cptr(nonce)) == 1;
    ok = ok && EVP_EncryptUpdate(ctx, out, &outl, lean_sarray_cptr(plaintext), (int)ptLen) == 1;
    ok = ok && EVP_EncryptFinal_ex(ctx, out + outl, &tmplen) == 1;
    if (ok) {
        outl += tmplen;
        ok = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, (int)kTagLen, out + outl) == 1;
        if (ok) {
            outl += (int)kTagLen;
        }
    }
    EVP_CIPHER_CTX_free(ctx);

    lean_obj_res result = mk_byte_array(ok ? out : NULL, ok ? (size_t)outl : 0);
    free(out);
    return result;
}

LEAN_EXPORT lean_obj_res lean_aes256_gcm_open(
    b_lean_obj_arg key, b_lean_obj_arg nonce, b_lean_obj_arg sealed) {
    size_t sealedLen = lean_sarray_size(sealed);
    if (lean_sarray_size(key) != kKeyLen || lean_sarray_size(nonce) != kNonceLen ||
        sealedLen < kTagLen) {
        return mk_none();
    }
    size_t ctLen = sealedLen - kTagLen;
    unsigned char *sealedPtr = lean_sarray_cptr(sealed);
    unsigned char *tagPtr = sealedPtr + ctLen;

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) {
        return mk_none();
    }

    unsigned char *out = (unsigned char *)malloc(ctLen == 0 ? 1 : ctLen);
    int outl = 0;
    int tmplen = 0;
    bool ok = EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) == 1;
    ok = ok && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, (int)kNonceLen, NULL) == 1;
    ok = ok && EVP_DecryptInit_ex(ctx, NULL, NULL, lean_sarray_cptr(key), lean_sarray_cptr(nonce)) == 1;
    ok = ok && EVP_DecryptUpdate(ctx, out, &outl, sealedPtr, (int)ctLen) == 1;
    ok = ok && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, (int)kTagLen, tagPtr) == 1;
    ok = ok && EVP_DecryptFinal_ex(ctx, out + outl, &tmplen) == 1;
    if (ok) {
        outl += tmplen;
    }
    EVP_CIPHER_CTX_free(ctx);

    lean_obj_res result = ok ? mk_some(mk_byte_array(out, (size_t)outl)) : mk_none();
    free(out);
    return result;
}
