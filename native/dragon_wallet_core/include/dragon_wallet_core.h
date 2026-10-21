#ifndef DRAGON_WALLET_CORE_H
#define DRAGON_WALLET_CORE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ABI placeholder: deliberately refuses signing until chain compatibility is tested. */
#define DRAGON_WALLET_ERR_UNIMPLEMENTED (-100)
int dragon_wallet_sign(const uint8_t *transaction, size_t transaction_len,
                       uint8_t *signature, size_t *signature_len);
#ifdef __cplusplus
}
#endif
#endif
