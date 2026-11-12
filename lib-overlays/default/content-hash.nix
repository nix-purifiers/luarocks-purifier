# SPDX-License-Identifier: MIT
#
# The content hash of a lockfile: the SHA-256, as an SRI hash, of the
# lockfile without its `contentHash` field, written as JSON with sorted keys
# and no whitespace. `luarocks-purifier lock` computes the same text with
# Python's json.dumps (see content_hash in bin/luarocks-purifier), so an
# edit by hand to any field of the lockfile changes the hash.
lock:
builtins.convertHash {
  hash = builtins.hashString "sha256" (builtins.toJSON (removeAttrs lock [ "contentHash" ]));
  hashAlgo = "sha256";
  toHashFormat = "sri";
}
