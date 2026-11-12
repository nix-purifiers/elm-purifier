# SPDX-License-Identifier: MIT
#
# The `elm-purifier` library namespace:
#
#   readLock  the lock in memory of the purifier contract, from the lockfile
#             and elm.json of a project (lib-overlays/default/lock.nix):
#             readLock { src, subdirectory ? ".", lockFile ? ... }
{ ... }:
{

  overlay = final: prev: {
    elm-purifier = (prev.elm-purifier or { }) // {
      readLock =
        {
          src,
          subdirectory ? ".",
          lockFile ? src + "/${subdirectory}/elm-purifier.lock.json",
        }:
        (import ./lock.nix {
          inherit lockFile;
          elmJsonFile = src + "/${subdirectory}/elm.json";
        }).lock;
    };
  };

}
