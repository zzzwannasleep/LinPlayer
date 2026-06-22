// LinPlayer 备份「加密给设备」(sealed) 格式 —— C 语言参考实现 (libsodium + cJSON)
// =============================================================================
// 这是给「想适配 LinPlayer 导入/导出」的第三方客户端的可编译范例,演示:
//   1. 生成/编码/解析设备公钥串 (LPKEY1) 与指纹
//   2. lp_seal()  —— 把明文 payload「加密给」某设备公钥 + Ed25519 签名
//   3. lp_open()  —— 用本设备私钥解封并验签
//
// 与 LinPlayer (Dart `cryptography` 包) 完全互通,算法见 docs/BACKUP_FORMAT.md:
//   ss  = X25519(ephemeral_sk, recipient_x25519_pub)
//   key = HKDF-SHA256(ikm=ss, salt=空, info="lpseal1"||epk||recipient_x25519_pub, 32B)
//   cipher,mac = AES-256-GCM(key, nonce/*12B*/).encrypt(明文 UTF-8 JSON)
//   sig = Ed25519.sign(sender_sk, epk||nonce||cipher||mac)
//
// 三个易踩坑(已在本文件正确处理):
//   * 信封里 epk/nonce/cipher/mac/sig 用「标准 base64」;LPKEY1 公钥串用「base64url」。
//   * GCM 的 16 字节认证标签是「独立字段 mac」,不是拼在密文尾部。
//   * HKDF 的 salt 为空,info 必须逐字节一致(顺序: 7字节"lpseal1" + epk + 收件人X25519公钥)。
//
// 编译:
//   gcc lp_backup_interop.c cJSON.c -lsodium -o lp_demo && ./lp_demo
//   (cJSON: https://github.com/DaveGamble/cJSON —— 把 cJSON.c / cJSON.h 放同目录)
//   (libsodium >= 1.0.18,需带 crypto_kdf_hkdf_sha256_*;AES-256-GCM 需 CPU AES-NI 支持)

#include <sodium.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cJSON.h"

// ---- base64 小工具 ----------------------------------------------------------

static char *b64_enc(const unsigned char *in, size_t n, int variant) {
  size_t cap = sodium_base64_encoded_len(n, variant);
  char *out = (char *)malloc(cap);
  sodium_bin2base64(out, cap, in, n, variant);
  return out; // 含 '\0'
}

// 返回 malloc 的字节,*outlen 为长度;失败返回 NULL。
static unsigned char *b64_dec(const char *s, size_t *outlen, int variant) {
  size_t cap = strlen(s) + 1;
  unsigned char *out = (unsigned char *)malloc(cap ? cap : 1);
  if (sodium_base642bin(out, cap, s, strlen(s), NULL, outlen, NULL, variant) != 0) {
    free(out);
    return NULL;
  }
  return out;
}

static void add_b64(cJSON *o, const char *key, const unsigned char *bin, size_t n) {
  char *s = b64_enc(bin, n, sodium_base64_VARIANT_ORIGINAL); // 标准 base64
  cJSON_AddStringToObject(o, key, s);
  free(s);
}

// ---- 设备公钥: 编码 / 指纹 ---------------------------------------------------

#define LP_X 32 // X25519 公钥/私钥
#define LP_E 32 // Ed25519 公钥
#define LP_NONCE crypto_aead_aes256gcm_NPUBBYTES // 12
#define LP_MAC crypto_aead_aes256gcm_ABYTES      // 16
#define LP_SIG crypto_sign_BYTES                 // 64

// "LPKEY1:" + base64url( x25519_pub(32) || ed25519_pub(32) )
static void lpkey_encode(const unsigned char x[LP_X], const unsigned char e[LP_E],
                         char *out, size_t outsz) {
  unsigned char buf[LP_X + LP_E];
  memcpy(buf, x, LP_X);
  memcpy(buf + LP_X, e, LP_E);
  char *b = b64_enc(buf, sizeof buf, sodium_base64_VARIANT_URLSAFE); // base64url(含 '=')
  snprintf(out, outsz, "LPKEY1:%s", b);
  free(b);
}

static int lpkey_decode(const char *token, unsigned char x[LP_X], unsigned char e[LP_E]) {
  const char *p = token;
  if (strncmp(p, "LPKEY1:", 7) == 0) p += 7;
  size_t n = 0;
  unsigned char *raw = b64_dec(p, &n, sodium_base64_VARIANT_URLSAFE);
  if (!raw || n != LP_X + LP_E) {
    free(raw);
    return -1;
  }
  memcpy(x, raw, LP_X);
  memcpy(e, raw + LP_X, LP_E);
  free(raw);
  return 0;
}

// 指纹 = SHA-256(x||e) 前 5 字节,大写十六进制,排版成 "A1B2-C3D4-E5"。
static void lpkey_fingerprint(const unsigned char x[LP_X], const unsigned char e[LP_E],
                              char out[16]) {
  unsigned char buf[LP_X + LP_E], h[crypto_hash_sha256_BYTES];
  memcpy(buf, x, LP_X);
  memcpy(buf + LP_X, e, LP_E);
  crypto_hash_sha256(h, buf, sizeof buf);
  char hex[11];
  for (int i = 0; i < 5; i++) sprintf(hex + i * 2, "%02X", h[i]);
  snprintf(out, 16, "%c%c%c%c-%c%c%c%c-%c%c", hex[0], hex[1], hex[2], hex[3],
           hex[4], hex[5], hex[6], hex[7], hex[8], hex[9]);
}

// 派生对称密钥: HKDF-SHA256(ss, salt=空, info="lpseal1"||epk||recip_x).
static int derive_key(const unsigned char ss[32], const unsigned char epk[LP_X],
                      const unsigned char recip_x[LP_X], unsigned char key[32]) {
  unsigned char prk[crypto_kdf_hkdf_sha256_KEYBYTES];
  if (crypto_kdf_hkdf_sha256_extract(prk, NULL, 0, ss, 32) != 0) return -1; // 空 salt
  unsigned char info[7 + LP_X + LP_X];
  memcpy(info, "lpseal1", 7);
  memcpy(info + 7, epk, LP_X);
  memcpy(info + 7 + LP_X, recip_x, LP_X);
  int r = crypto_kdf_hkdf_sha256_expand(key, 32, (const char *)info, sizeof info, prk);
  sodium_memzero(prk, sizeof prk);
  return r;
}

// 签名/验签覆盖的字节: epk||nonce||cipher||mac。
static unsigned char *signed_bytes(const unsigned char *epk, const unsigned char *nonce,
                                   const unsigned char *cipher, size_t clen,
                                   const unsigned char *mac, size_t *outlen) {
  *outlen = LP_X + LP_NONCE + clen + LP_MAC;
  unsigned char *b = (unsigned char *)malloc(*outlen);
  size_t o = 0;
  memcpy(b + o, epk, LP_X);        o += LP_X;
  memcpy(b + o, nonce, LP_NONCE);  o += LP_NONCE;
  memcpy(b + o, cipher, clen);     o += clen;
  memcpy(b + o, mac, LP_MAC);
  return b;
}

// ---- 封装: 把明文加密给收件人公钥 -------------------------------------------

// 返回 malloc 的信封 JSON 字符串(调用方 free);失败返回 NULL。
// recip_x/recip_e: 收件人公钥(从其 LPKEY1 解出);
// sender_ed_sk(64B): 发送方 Ed25519 私钥(crypto_sign 用);
// sender_x/sender_e: 发送方公钥(写入 sender_pub,供收件人验签/识别)。
static char *lp_seal(const char *plaintext, const unsigned char recip_x[LP_X],
                     const unsigned char recip_e[LP_E], const unsigned char sender_ed_sk[64],
                     const unsigned char sender_x[LP_X], const unsigned char sender_e[LP_E]) {
  size_t mlen = strlen(plaintext);

  // 1) 一次性临时 X25519 密钥对
  unsigned char epk[LP_X], esk[LP_X];
  crypto_box_keypair(epk, esk);

  // 2) ECDH
  unsigned char ss[32];
  if (crypto_scalarmult(ss, esk, recip_x) != 0) return NULL;

  // 3) HKDF -> key
  unsigned char key[32];
  if (derive_key(ss, epk, recip_x, key) != 0) return NULL;
  sodium_memzero(ss, sizeof ss);
  sodium_memzero(esk, sizeof esk);

  // 4) AES-256-GCM(detached: 密文与 16B tag 分开)
  unsigned char nonce[LP_NONCE], mac[LP_MAC];
  randombytes_buf(nonce, sizeof nonce);
  unsigned char *cipher = (unsigned char *)malloc(mlen ? mlen : 1);
  unsigned long long maclen = 0;
  if (crypto_aead_aes256gcm_encrypt_detached(cipher, mac, &maclen,
        (const unsigned char *)plaintext, mlen, NULL, 0, NULL, nonce, key) != 0) {
    free(cipher);
    return NULL;
  }
  sodium_memzero(key, sizeof key);

  // 5) 签名 epk||nonce||cipher||mac
  size_t slen;
  unsigned char *sbuf = signed_bytes(epk, nonce, cipher, mlen, mac, &slen);
  unsigned char sig[LP_SIG];
  crypto_sign_detached(sig, NULL, sbuf, slen, sender_ed_sk);
  free(sbuf);

  char fp[16], sender_tok[128];
  lpkey_fingerprint(recip_x, recip_e, fp);
  lpkey_encode(sender_x, sender_e, sender_tok, sizeof sender_tok);

  cJSON *o = cJSON_CreateObject();
  cJSON_AddNumberToObject(o, "linplayer_sealed_backup", 1);
  cJSON_AddStringToObject(o, "alg", "x25519-hkdf-sha256-aes256gcm");
  cJSON_AddStringToObject(o, "sig_alg", "ed25519");
  cJSON_AddStringToObject(o, "from", "ThirdPartyClient");
  cJSON_AddStringToObject(o, "version", "2.0");
  cJSON_AddNumberToObject(o, "export_time", (double)time(NULL));
  add_b64(o, "epk", epk, LP_X);
  cJSON_AddStringToObject(o, "recipient_fp", fp);
  add_b64(o, "nonce", nonce, LP_NONCE);
  add_b64(o, "cipher", cipher, mlen);
  add_b64(o, "mac", mac, LP_MAC);
  cJSON_AddStringToObject(o, "sender_pub", sender_tok);
  add_b64(o, "sig", sig, LP_SIG);

  char *out = cJSON_PrintUnformatted(o);
  cJSON_Delete(o);
  free(cipher);
  return out;
}

// ---- 解封: 用本设备私钥解密并验签 -------------------------------------------

// 返回 malloc 的明文(调用方 free);*sig_ok = 签名是否通过。失败返回 NULL。
static char *lp_open(const char *env_json, const unsigned char recip_x_sk[LP_X],
                     const unsigned char recip_x_pk[LP_X], const unsigned char recip_e_pk[LP_E],
                     int *sig_ok) {
  *sig_ok = 0;
  char *out = NULL;
  cJSON *o = cJSON_Parse(env_json);
  if (!o) return NULL;
  unsigned char *epk = NULL, *nonce = NULL, *cipher = NULL, *mac = NULL, *sig = NULL;
  size_t clen = 0, n;

  const cJSON *alg = cJSON_GetObjectItemCaseSensitive(o, "alg");
  if (!cJSON_IsString(alg) || strcmp(alg->valuestring, "x25519-hkdf-sha256-aes256gcm")) goto done;

  // 早判断「是否发给本设备」
  char myfp[16];
  lpkey_fingerprint(recip_x_pk, recip_e_pk, myfp);
  const cJSON *rfp = cJSON_GetObjectItemCaseSensitive(o, "recipient_fp");
  if (cJSON_IsString(rfp) && rfp->valuestring[0] && strcmp(rfp->valuestring, myfp)) {
    fprintf(stderr, "[lp_open] 此备份不是加密给当前设备的(指纹不匹配)\n");
    goto done;
  }

#define GET(name, var)                                                            \
  do {                                                                            \
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, name);                  \
    if (!cJSON_IsString(it)) goto done;                                           \
    (var) = b64_dec(it->valuestring, &n, sodium_base64_VARIANT_ORIGINAL);         \
  } while (0)

  GET("epk", epk);
  GET("nonce", nonce);
  GET("cipher", cipher); clen = n;
  GET("mac", mac);
  GET("sig", sig);
  if (!epk || !nonce || !cipher || !mac || !sig) goto done;
#undef GET

  // 验签(用 sender_pub 里的 Ed25519 公钥)
  const cJSON *spub = cJSON_GetObjectItemCaseSensitive(o, "sender_pub");
  if (cJSON_IsString(spub)) {
    unsigned char sx[LP_X], se[LP_E];
    if (lpkey_decode(spub->valuestring, sx, se) == 0) {
      size_t slen;
      unsigned char *sbuf = signed_bytes(epk, nonce, cipher, clen, mac, &slen);
      *sig_ok = (crypto_sign_verify_detached(sig, sbuf, slen, se) == 0);
      free(sbuf);
    }
  }

  // ECDH + HKDF + 解密
  unsigned char ss[32], key[32];
  if (crypto_scalarmult(ss, recip_x_sk, epk) != 0) goto done;
  if (derive_key(ss, epk, recip_x_pk, key) != 0) goto done;
  sodium_memzero(ss, sizeof ss);

  unsigned char *plain = (unsigned char *)malloc(clen + 1);
  if (crypto_aead_aes256gcm_decrypt_detached(plain, NULL, cipher, clen, mac, NULL, 0,
                                             nonce, key) != 0) {
    fprintf(stderr, "[lp_open] 解密失败(密钥不符或数据被篡改)\n");
    free(plain);
    sodium_memzero(key, sizeof key);
    goto done;
  }
  sodium_memzero(key, sizeof key);
  plain[clen] = '\0';
  out = (char *)plain;

done:
  free(epk); free(nonce); free(cipher); free(mac); free(sig);
  cJSON_Delete(o);
  return out;
}

// ---- 演示 -------------------------------------------------------------------

int main(void) {
  if (sodium_init() < 0) {
    fprintf(stderr, "libsodium 初始化失败\n");
    return 1;
  }
  if (!crypto_aead_aes256gcm_is_available()) {
    fprintf(stderr, "本机 CPU 不支持 AES-NI,libsodium 无法做 AES-256-GCM\n");
    return 1;
  }

  // === 收件人(对方设备,例如一台 LinPlayer)===
  // 实际场景: 收件人持久化自己的密钥对,把下面的 LPKEY1 公钥串/二维码给你。
  unsigned char recip_x_pk[LP_X], recip_x_sk[LP_X];
  crypto_box_keypair(recip_x_pk, recip_x_sk);
  unsigned char recip_seed[32], recip_e_pk[LP_E], recip_e_sk[64];
  randombytes_buf(recip_seed, sizeof recip_seed);
  crypto_sign_seed_keypair(recip_e_pk, recip_e_sk, recip_seed); // 32B seed -> 密钥对

  char recip_tok[128], recip_fp[16];
  lpkey_encode(recip_x_pk, recip_e_pk, recip_tok, sizeof recip_tok);
  lpkey_fingerprint(recip_x_pk, recip_e_pk, recip_fp);
  printf("收件人公钥串(对方给你的): %s\n", recip_tok);
  printf("收件人指纹(口头核对):     %s\n\n", recip_fp);

  // === 发送方(本客户端)===
  unsigned char send_x_pk[LP_X], send_x_sk[LP_X];
  crypto_box_keypair(send_x_pk, send_x_sk);
  unsigned char send_seed[32], send_e_pk[LP_E], send_e_sk[64];
  randombytes_buf(send_seed, sizeof send_seed);
  crypto_sign_seed_keypair(send_e_pk, send_e_sk, send_seed);

  // 要导出的明文 payload(数据契约,详见 docs/BACKUP_FORMAT.md)
  const char *payload =
      "{\"version\":\"1.0.0\",\"timestamp\":\"2026-06-22T00:00:00Z\","
      "\"servers\":[{\"id\":\"srv-1\",\"name\":\"我的Emby\",\"baseUrl\":\"https://emby.example.com\","
      "\"username\":\"alice\",\"userId\":\"u123\",\"authToken\":\"TOKEN-ABC\",\"password\":\"p@ss\","
      "\"lines\":[],\"activeLineIndex\":0,\"allowInsecureTls\":false}],\"settings\":{}}";

  // 解析收件人公钥串 -> 封装
  unsigned char rx[LP_X], re[LP_E];
  if (lpkey_decode(recip_tok, rx, re) != 0) {
    fprintf(stderr, "公钥串解析失败\n");
    return 1;
  }
  char *envelope = lp_seal(payload, rx, re, send_e_sk, send_x_pk, send_e_pk);
  if (!envelope) {
    fprintf(stderr, "封装失败\n");
    return 1;
  }
  printf("生成的加密备份(发给收件人):\n%s\n\n", envelope);

  // 收件人侧解封
  int sig_ok = 0;
  char *recovered = lp_open(envelope, recip_x_sk, recip_x_pk, recip_e_pk, &sig_ok);
  if (!recovered) {
    fprintf(stderr, "解封失败\n");
    free(envelope);
    return 1;
  }
  printf("解封成功 · 签名%s\n", sig_ok ? "已验证 ✓" : "未通过 ⚠");
  printf("还原明文:\n%s\n", recovered);
  printf("\n往返一致: %s\n", strcmp(recovered, payload) == 0 ? "是 ✓" : "否 ✗");

  free(recovered);
  free(envelope);
  return 0;
}

// =============================================================================
// 关于「密码模式」(linplayer_encrypted_backup):
//   外层 = PBKDF2-HMAC-SHA256(password, salt, 120000, 32B) -> AES-256-GCM。
//   libsodium 不含 PBKDF2(只有 Argon2/scrypt),如需密码模式请用 OpenSSL:
//     PKCS5_PBKDF2_HMAC(pass, plen, salt, 16, 120000, EVP_sha256(), 32, key);
//   再走 EVP_aes_256_gcm 加解密。明文 payload 契约与上面完全相同。
// =============================================================================
