# SPDX-License-Identifier: MIT
#
# The content hash of an elm-purifier lockfile, which the lockfile records
# as `contentHash`: the SRI SHA-256 of the lock without that field, as
# builtins.toJSON writes it (keys sorted, no whitespace). `content_hash`
# in bin/elm-purifier computes the same hash, and a lockfile whose
# recorded hash differs was edited after `elm-purifier lock` wrote it.
lock:
builtins.convertHash {
  hash = builtins.hashString "sha256" (builtins.toJSON (removeAttrs lock [ "contentHash" ]));
  hashAlgo = "sha256";
  toHashFormat = "sri";
}
