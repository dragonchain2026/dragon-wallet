#include "dragon_wallet_core.h"
int dragon_wallet_sign(const uint8_t *transaction, size_t transaction_len,
                       uint8_t *signature, size_t *signature_len) {
    (void)transaction; (void)transaction_len; (void)signature; (void)signature_len;
    return DRAGON_WALLET_ERR_UNIMPLEMENTED;
}
