# Dragon Wallet

Dragonchain 主网钱包，优先支持 Android，保留 iOS 工程与 Web 预览。
界面默认英文，支持切换中文。

## 功能

- 本地生成钱包，导入 WIF 私钥或助记词，管理地址名称与观察地址。
- 展示收款二维码、链上余额、UTXO 和分页交易历史。
- 在 Android 本机完成 Falcon-512 签名，通过 Wallet API 广播转账。
- 从主网入口进入独立交易页面；交易页面网址: [http://mobile.dragonchain.cc/](http://mobile.dragonchain.cc/)

私钥和助记词使用 Android Keystore 加密保存在本机。请妥善备份，
不要通过卸载或清除应用数据测试升级。助记词采用本钱包固定恢复规则，
不支持 Bitcoin 私钥或 BIP32 HD 派生。

原生实现见 [Native Core](native/dragon_wallet_core/README.md)，
助记词恢复规则见 [MNEMONIC.md](native/dragon_wallet_core/MNEMONIC.md)。

