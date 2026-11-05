"""Print the current TOTP code for each hash algorithm, to compare with the authenticator app.

Reads CITRIX_TOTP_* from the .env file given as argument. Never prints the secret.
"""
import base64, hashlib, hmac, struct, sys, time


def load_env(path):
    env = {}
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def totp(secret, algorithm, digits, period, now):
    key = base64.b32decode(secret.replace(" ", "").upper() + "=" * (-len(secret.replace(" ", "")) % 8))
    counter = struct.pack(">Q", int(now // period))
    mac = hmac.new(key, counter, getattr(hashlib, algorithm.lower())).digest()
    offset = mac[-1] & 0x0F
    code = (struct.unpack(">I", mac[offset:offset + 4])[0] & 0x7FFFFFFF) % 10 ** digits
    return str(code).zfill(digits)


env = load_env(sys.argv[1])
secret = env.get("CITRIX_TOTP_SECRET", "")
if not secret:
    sys.exit("CITRIX_TOTP_SECRET is empty")
digits = int(env.get("CITRIX_TOTP_DIGITS") or 6)
period = int(env.get("CITRIX_TOTP_PERIOD") or 30)
now = time.time()
print(f"secret length {len(secret)} chars, {digits} digits, {period}s period, "
      f"{period - int(now) % period}s left in this window")
for algorithm in ("SHA1", "SHA256", "SHA512"):
    print(f"{algorithm:7} {totp(secret, algorithm, digits, period, now)}")
